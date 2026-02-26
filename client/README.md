# Huddle Client Setup (Real Devices)

## 1) Configure `.env`

Edit `client/.env`:

```env
PSK=THIS_IS_A_32_CHAR_PSK_1234567890
SIGNALING_URL=ws://<SERVER_IP>:8080
```

Examples:
- Same Wi-Fi LAN: `SIGNALING_URL=ws://192.168.1.20:8080`
- Public tunnel: `SIGNALING_URL=wss://orange-forest-1234.trycloudflare.com`

Important:
- Both devices must use the same `PSK`.
- Both devices must use the same `SIGNALING_URL`.

## 2) Run signaling server

From repo root:

```bash
python server.py --host 0.0.0.0 --port 8080
```

Use `0.0.0.0` for real devices. `127.0.0.1` is only local machine loopback.

## 3) Put devices on same network

- For LAN mode, keep both devices on the same Wi-Fi as the machine running `server.py`.
- If that is not possible, use Cloudflare tunnel and set a `wss://...` URL.

## 4) Run app on both devices

From `client/`:

```bash
flutter pub get
flutter run
```

Grant camera + microphone permission when prompted.

## 5) Quick validation flow

1. Device A taps `Start a New Call`.
2. Device B enters same room code and taps `Join Call`.
3. Device A should receive offer/answer and both streams should appear.

## Troubleshooting

- Stuck on waiting screen:
  - Check `SIGNALING_URL` is not `127.0.0.1` on physical devices.
  - Check firewall allows inbound TCP 8080.
  - Check server logs show both clients joined same room.
- Permission denied:
  - Re-enable Camera and Microphone in app settings.
- Random disconnect:
  - Confirm both devices use identical `PSK`.
