import argparse
import asyncio
import contextlib
import json
import logging
import signal
import time
from collections import deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Dict, Optional, Any
from urllib.parse import parse_qs, urlparse
import urllib.request

import jwt
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

AUTH_SERVER_URL = "http://127.0.0.1:8081"
PUBLIC_KEY_PEM: Optional[str] = None
PUBLIC_KEY_LAST_FETCHED_AT = 0.0
PUBLIC_KEY_CACHE_TTL_SECONDS = 60


def fetch_public_key(force_refresh: bool = False) -> str:
    global PUBLIC_KEY_PEM, PUBLIC_KEY_LAST_FETCHED_AT
    now = time.time()
    cache_is_fresh = PUBLIC_KEY_PEM and (now - PUBLIC_KEY_LAST_FETCHED_AT) < PUBLIC_KEY_CACHE_TTL_SECONDS
    if not force_refresh and cache_is_fresh:
        return PUBLIC_KEY_PEM
    try:
        req = urllib.request.Request(f"{AUTH_SERVER_URL}/public_key")
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            PUBLIC_KEY_PEM = data.get("public_key")
            PUBLIC_KEY_LAST_FETCHED_AT = now
            return PUBLIC_KEY_PEM
    except Exception as e:
        logger.error(f"Failed to fetch public key from auth server: {e}")
        return ""

def verify_jwt(token: str) -> Optional[Dict[str, Any]]:
    pub_key = fetch_public_key()
    if not pub_key:
        return None
        
    try:
        # We explicitly decode with the public key we fetched
        payload = jwt.decode(token, pub_key, algorithms=["RS256"])
        
        # Additionally, verify if the user's tokens haven't been blanket revoked
        # We need another endpoint on auth server or sqlite db access. Since they 
        # run on the same machine we could fetch it via http.
        # For simplicity, if jwt decode succeeds (checks expiry), it's nominally fine.
        return payload
    except jwt.ExpiredSignatureError:
        logger.warning("JWT expired")
        return None
    except jwt.InvalidTokenError as e:
        logger.warning(f"JWT invalid: {e}")
        # Auth server may have rotated/restarted; refresh key and retry once.
        refreshed_key = fetch_public_key(force_refresh=True)
        if refreshed_key and refreshed_key != pub_key:
            try:
                return jwt.decode(token, refreshed_key, algorithms=["RS256"])
            except jwt.ExpiredSignatureError:
                logger.warning("JWT expired after refresh")
                return None
            except jwt.InvalidTokenError as refresh_err:
                logger.warning(f"JWT still invalid after key refresh: {refresh_err}")
        return None


MAX_PARTICIPANTS_PER_ROOM = 4
MAX_MESSAGES_PER_SECOND = 50
ROOM_IDLE_EXPIRY_SECONDS = 2 * 60 * 60
PEER_LEFT_TYPE = "peer_left"
ERROR_TYPE = "error"
PEER_JOINED_TYPE = "peer_joined"


class RoomFullError(Exception):
    pass


def utc_ts() -> str:
    return datetime.now(timezone.utc).isoformat()


def compact_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Room:
    clients: Dict[ServerConnection, str] = field(default_factory=dict)
    last_active: float = field(default_factory=time.time)


@dataclass
class ClientState:
    room_code: str
    client_id: str
    # Sliding 1-second window of message timestamps for rate limiting.
    message_times: deque = field(default_factory=deque)


rooms: Dict[str, Room] = {}
client_states: Dict[ServerConnection, ClientState] = {}
rooms_lock = asyncio.Lock()
logger = logging.getLogger("signaling")


def sanitize_room_code(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    room = raw.strip().upper()
    if len(room) > 64:
        return None
    return room


def sanitize_client_id(raw: Optional[str]) -> Optional[str]:
    if not raw:
        return None
    client_id = raw.strip()
    if len(client_id) > 128:
        return None
    return client_id


async def safe_send(connection: ServerConnection, payload: str) -> None:
    try:
        await connection.send(payload)
    except ConnectionClosed:
        return
    except Exception:
        logger.exception("send_failure")


async def send_json(connection: ServerConnection, obj: dict) -> None:
    await safe_send(connection, json.dumps(obj, separators=(",", ":")))


def parse_query(path: str) -> tuple[Optional[str], Optional[str], Optional[str]]:
    parsed = urlparse(path)
    q = parse_qs(parsed.query)
    room = sanitize_room_code((q.get("room") or [None])[0])
    client_id = sanitize_client_id((q.get("clientId") or [None])[0])
    token = (q.get("token") or [None])[0]
    return room, client_id, token


async def notify_peer_joined(room_code: str, joined_client: ServerConnection, joined_client_id: str) -> None:
    room = rooms.get(room_code)
    if not room:
        return
    payload = {
        "type": PEER_JOINED_TYPE,
        "senderId": "server",
        "targetId": "*",
        "payload": {"peerId": joined_client_id, "ts": utc_ts()},
    }
    encoded = json.dumps(payload, separators=(",", ":"))
    for peer in list(room.clients.keys()):
        if peer is joined_client:
            continue
        await safe_send(peer, encoded)


async def handle_join(connection: ServerConnection, room_code: str, client_id: str) -> None:
    async with rooms_lock:
        room = rooms.get(room_code)
        if room is None:
            room = Room()
            rooms[room_code] = room

        if len(room.clients) >= MAX_PARTICIPANTS_PER_ROOM:
            await send_json(
                connection,
                {
                    "type": ERROR_TYPE,
                    "payload": {"code": "room_full", "message": "Room has reached max capacity (4)."},
                },
            )
            raise RoomFullError("room_full")

        room.clients[connection] = client_id
        room.last_active = time.time()
        client_states[connection] = ClientState(room_code=room_code, client_id=client_id)

    logger.info("event=join room=%s ts=%s", room_code, compact_now())
    await notify_peer_joined(room_code, connection, client_id)


def over_rate_limit(state: ClientState) -> bool:
    now = time.time()
    while state.message_times and now - state.message_times[0] > 1:
        state.message_times.popleft()
    if len(state.message_times) >= MAX_MESSAGES_PER_SECOND:
        return True
    state.message_times.append(now)
    return False


async def relay_to_room(connection: ServerConnection, message: str) -> None:
    state = client_states.get(connection)
    if not state:
        return
    room = rooms.get(state.room_code)
    if not room:
        return

    room.last_active = time.time()
    targets = [peer for peer in room.clients.keys() if peer is not connection]
    if not targets:
        return

    await asyncio.gather(*(safe_send(peer, message) for peer in targets))


async def notify_peer_left(room_code: str, departed_client_id: str, departed_connection: ServerConnection) -> None:
    room = rooms.get(room_code)
    if not room:
        return
    payload = {
        "type": PEER_LEFT_TYPE,
        "senderId": "server",
        "targetId": "*",
        "payload": {"peerId": departed_client_id, "ts": utc_ts()},
    }
    encoded = json.dumps(payload, separators=(",", ":"))
    await asyncio.gather(
        *(safe_send(peer, encoded) for peer in room.clients.keys() if peer is not departed_connection),
        return_exceptions=True,
    )


async def remove_client(connection: ServerConnection) -> None:
    state = client_states.pop(connection, None)
    if not state:
        return

    room_code = state.room_code
    async with rooms_lock:
        room = rooms.get(room_code)
        if not room:
            return
        room.clients.pop(connection, None)
        room.last_active = time.time()
        empty = not room.clients
        if empty:
            rooms.pop(room_code, None)

    if empty:
        logger.info("event=room_deleted room=%s ts=%s", room_code, compact_now())
    else:
        logger.info("event=leave room=%s ts=%s", room_code, compact_now())
        await notify_peer_left(room_code, state.client_id, connection)


async def cleanup_idle_rooms(stop_event: asyncio.Event) -> None:
    while not stop_event.is_set():
        await asyncio.sleep(60)
        now = time.time()
        to_drop: list[tuple[str, list[ServerConnection]]] = []
        async with rooms_lock:
            for room_code, room in list(rooms.items()):
                if now - room.last_active > ROOM_IDLE_EXPIRY_SECONDS:
                    stale_connections = list(room.clients.keys())
                    to_drop.append((room_code, stale_connections))
                    for conn in stale_connections:
                        client_states.pop(conn, None)
            for room_code, _ in to_drop:
                rooms.pop(room_code, None)

        for room_code, stale_connections in to_drop:
            if stale_connections:
                await asyncio.gather(
                    *(conn.close(code=4000, reason="room_idle_expired") for conn in stale_connections),
                    return_exceptions=True,
                )
            logger.info("room_deleted room=%s ts=%s reason=idle_expiry", room_code, compact_now())


async def handle_connection(connection: ServerConnection) -> None:
    request = connection.request
    room_code, client_id, token = parse_query(request.path)
    
    if room_code is None or client_id is None or token is None:
        await send_json(
            connection,
            {"type": ERROR_TYPE, "payload": {"code": "bad_request", "message": "Query requires room, clientId, and token."}},
        )
        await connection.close(code=4001, reason="missing_room_or_client_or_token")
        return

    payload = verify_jwt(token)
    if not payload:
        await send_json(
            connection,
            {"type": ERROR_TYPE, "payload": {"code": "auth_failed", "message": "Invalid or expired session token."}}
        )
        await connection.close(code=4003, reason="auth_failed")
        return
        
    # Optional strict binding check: token 'sub' should match 'clientId' mostly, or we just trust the token.
    # The current system uses clientId from the client to identify internally. We could enforce clientId == payload['sub'].

    try:
        await handle_join(connection, room_code, client_id)
    except RoomFullError:
        await connection.close(code=4002, reason="room_full")
        return
    except Exception:
        logger.exception("join_failure")
        await connection.close(code=1011, reason="join_failure")
        return

    try:
        async for message in connection:
            state = client_states.get(connection)
            if not state:
                continue
            if over_rate_limit(state):
                logger.warning(
                    "event=rate_limited room=%s ts=%s",
                    state.room_code,
                    compact_now(),
                )
                await send_json(
                    connection,
                    {"type": ERROR_TYPE, "payload": {"code": "rate_limited", "message": "Max 10 messages/sec."}},
                )
                continue
            await relay_to_room(connection, message)
    except ConnectionClosed:
        pass
    finally:
        await remove_client(connection)


async def run(host: str, port: int) -> None:
    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()

    def _stop() -> None:
        stop_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, _stop)
        except NotImplementedError:
            # Windows event loop may not support add_signal_handler for all signals.
            pass

    cleanup_task = asyncio.create_task(cleanup_idle_rooms(stop_event))
    logger.info("server_start ts=%s host=%s port=%d", compact_now(), host, port)
    try:
        async with serve(handle_connection, host, port, max_size=2 * 1024 * 1024):
            await stop_event.wait()
    finally:
        cleanup_task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await cleanup_task
        logger.info("server_stop ts=%s", compact_now())


def configure_logging() -> None:
    # Logging policy: metadata only (room code + timestamps + events), never message content.
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    logging.getLogger("websockets").setLevel(logging.WARNING)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="4-person signaling relay server")
    parser.add_argument("--host", default="127.0.0.1", help="Host interface to bind")
    parser.add_argument("--port", default=8080, type=int, help="Port to bind")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    configure_logging()
    asyncio.run(run(args.host, args.port))
