# Huddle

Huddle is a decentralized-style video calling app prototype built with:

- A Python WebSocket signaling hub (`server.py`)
- A Flutter mobile client (`client/`) using WebRTC (`flutter_webrtc`)

This README documents the current implementation status in detail.

## Current Product Scope

What Huddle does today:

- Lets users start or join a room by 6-digit code.
- Requests camera + microphone permissions on device.
- Connects peers through a signaling server and performs WebRTC SDP/ICE exchange.
- Shows local video and one remote video feed in-call.
- Encrypts peer signaling payloads (offer/answer/ice/peer_left) with a shared AES key.

What Huddle does not fully do yet:

- No TURN server integration yet (only STUN is configured).
- Client UI/engine is effectively 1-on-1, while server supports up to 4 participants.
- No authentication/user accounts.
- No persistent room history, recording, chat, or moderation controls.

## Architecture Overview

### High-level flow

1. User opens app and picks a room code.
2. App requests camera/mic access.
3. App connects to signaling endpoint (`SIGNALING_URL`) with:
   - `room=<code>`
   - `clientId=<uuid>`
4. Server emits `peer_joined` / `peer_left` events as plain JSON.
5. Peers exchange offer/answer/ice via server relay.
6. Peer payloads are encrypted by the client before sending.
7. WebRTC connection is established and media flows peer-to-peer.

### Repo layout

- `server.py`: signaling relay and room lifecycle management
- `requirements.txt`: Python dependency (`websockets`)
- `client/lib/ui/`: home and call screens
- `client/lib/signaling/`: websocket signaling + AES envelope handling
- `client/lib/webrtc/`: peer connection lifecycle
- `client/.env`: runtime config for signaling URL + PSK

## Implemented Features

### 1) Signaling server (Python)

Server behavior currently implemented:

- Room capacity limit: 4 participants max per room
- Message relay: broadcasts incoming peer message to all other peers in same room
- Rate limiting: max 10 messages/sec per client (sliding 1-second window)
- Idle room cleanup: deletes idle rooms after 2 hours
- Input validation:
  - `room` required
  - `clientId` required
  - bounded lengths for safety
- Metadata-only logging:
  - room and timestamps/events are logged
  - message contents are not logged

Server-generated events:

- `peer_joined`
- `peer_left`
- `error` (e.g. `room_full`, `bad_request`, `rate_limited`)

### 2) Mobile app (Flutter)

Home screen features:

- Generate random 6-digit room code (`Start a New Call`)
- Join via manually entered code
- Camera/mic permission request flow with fallback to app settings

Call screen features:

- Local preview (picture-in-picture)
- Remote full-screen video placeholder until stream arrives
- WebRTC handshake wiring via signaling callbacks
- Handles remote peer leaving by resetting connection state

### 3) Signaling security model (current)

Implemented:

- Peer signaling envelopes are AES-encrypted in client code.
- Per-message random IV is prepended to ciphertext and base64 encoded.
- Decryption is attempted on incoming non-server messages.

Current caveats:

- Uses pre-shared symmetric key (`PSK`) from `.env`.
- If `PSK` is not configured, code has a default fallback key (not suitable for production).
- Server events (`peer_joined`, `peer_left`, server `error`) are plain JSON by design.

## WebRTC / Networking Notes

### ICE configuration in app

Configured now:

- STUN: `stun:stun.l.google.com:19302`

Not configured yet:

- TURN server

Impact:

- Same-network tests usually work.
- Cross-city/carrier-NAT scenarios may fail intermittently or completely without TURN.

### Signaling URL configuration

`client/.env` currently supports:

```env
PSK=THIS_IS_A_32_CHAR_PSK_1234567890
SIGNALING_URL=ws://127.0.0.1:8080
```

For physical devices, `SIGNALING_URL` must point to reachable host:

- LAN test: `ws://<laptop_lan_ip>:8080`
- Internet test: `wss://<public-tunnel-domain>`

## Platform Configuration Status

### Android

Configured in manifest:

- `INTERNET`
- `CAMERA`
- `RECORD_AUDIO`
- `MODIFY_AUDIO_SETTINGS`
- `usesCleartextTraffic=true` (allows `ws://` over HTTP transport when needed)

### iOS

Configured in `Info.plist`:

- `NSCameraUsageDescription`
- `NSMicrophoneUsageDescription`
- `NSAppTransportSecurity -> NSAllowsArbitraryLoads=true` (allows non-HTTPS endpoints)

## Local Development Setup

### Prerequisites

- Python 3.x
- Flutter SDK
- Android Studio / Xcode toolchains as needed

### Server setup

```bash
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
python server.py --host 0.0.0.0 --port 8080
```

### Client setup

```bash
cd client
flutter pub get
flutter run
```

## Testing Scenarios

### A) Same Wi-Fi test (recommended first)

1. Run server on laptop with `--host 0.0.0.0`.
2. Set `SIGNALING_URL=ws://<laptop_lan_ip>:8080` in `client/.env`.
3. Install/run app on two phones on same network.
4. Start call on phone A, join room on phone B.

### B) Cross-city / different network test

1. Keep server running locally.
2. Expose server using Cloudflare tunnel:
   ```bash
   cloudflared tunnel --url http://localhost:8080
   ```
3. Set `SIGNALING_URL` to tunnel domain using `wss://...`.
4. Build app for both users with same `.env` values.
5. Test call.

Important:

- Signaling can work over tunnel, but media reliability still depends on TURN.

## Signaling Protocol (Current)

### Server event payloads (plain JSON)

`peer_joined`:

```json
{
  "type": "peer_joined",
  "senderId": "server",
  "targetId": "*",
  "payload": {
    "peerId": "<client-id>",
    "ts": "<iso-timestamp>"
  }
}
```

`peer_left`:

```json
{
  "type": "peer_left",
  "senderId": "server",
  "targetId": "*",
  "payload": {
    "peerId": "<client-id>",
    "ts": "<iso-timestamp>"
  }
}
```

### Peer envelope (encrypted before send)

Logical JSON before encryption:

```json
{
  "type": "offer|answer|ice_candidate|peer_left",
  "senderId": "<uuid>",
  "targetId": "<peer-id-or-*>",
  "payload": {}
}
```

Transmitted value:

- Base64 string of `[16-byte IV][ciphertext]`.

## Known Limitations

- Multi-party signaling exists server-side (up to 4), but client currently renders one remote stream.
- No TURN support yet, so NAT traversal can fail across strict networks.
- `.env`-based PSK is static and shared manually.
- No user identity or authorization.
- No production hardening for secrets management, key rotation, or abuse controls.

## Troubleshooting

### "Waiting for someone to join..." forever

- Check both clients use same room code.
- Check both clients use same `PSK`.
- Check `SIGNALING_URL` is reachable from both devices.
- Confirm server terminal shows both clients joined.

### Works locally but not on physical phones

- Avoid `127.0.0.1` in device builds.
- Use LAN IP or tunnel URL.
- Open firewall for TCP 8080.

### Cross-city call connects signaling but no media

- This is expected on some networks without TURN.
- Next technical step is TURN server integration in ICE config.

## Suggested Next Milestones

1. Add TURN servers via `.env` and load into ICE config.
2. Extend client from 1-on-1 to true 4-party experience.
3. Replace static PSK with session keys / authenticated signaling.
4. Add call diagnostics UI (connection state, ICE state, errors).
5. Add automated integration tests for signaling and handshake paths.
