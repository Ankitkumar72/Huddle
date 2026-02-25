# Phase 1: Private Signaling Hub

This server is a minimal WebSocket relay for a max 4-person room.

- It only routes messages to other peers in the same room.
- It never logs message content.
- It applies rate limiting (`10 msg/sec/client`).
- It expires rooms idle for more than 2 hours.

## 1) Setup

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

## 2) Run Server

```bash
python server.py --host 127.0.0.1 --port 8080
```

### Connection URL format

Each client must connect with:

`ws://127.0.0.1:8080/?room=123456&clientId=<uuid>`

## 3) Expose via Cloudflare Tunnel

```bash
cloudflared tunnel --url http://localhost:8080
```

Cloudflare will return a public endpoint like:

`https://orange-forest-1234.trycloudflare.com`

For WebSocket clients, use:

`wss://orange-forest-1234.trycloudflare.com/?room=123456&clientId=<uuid>`

## 4) Quick Validation with wscat

Install once:

```bash
npm i -g wscat
```

Open terminal 1:

```bash
wscat -c "ws://127.0.0.1:8080/?room=123456&clientId=A"
```

Open terminal 2:

```bash
wscat -c "ws://127.0.0.1:8080/?room=123456&clientId=B"
```

Type a message in terminal 1 and confirm terminal 2 receives it.

## 5) Behavior Notes

- 5th participant in same room is rejected with `room_full`.
- Invalid query (missing `room` or `clientId`) is rejected.
- On disconnect, remaining peers receive:
  - `{"type":"peer_left","senderId":"server","targetId":"*","payload":{"peerId":"...","ts":"..."}}`
- On join, existing peers receive:
  - `{"type":"peer_joined","senderId":"server","targetId":"*","payload":{"peerId":"...","ts":"..."}}`
