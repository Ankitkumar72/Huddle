# Huddle Client Setup (Two Physical Devices)

## 1) Configure `client/.env`

Edit `client/.env`:

```env
PSK=THIS_IS_A_32_CHAR_PSK_1234567890
SIGNALING_URL=ws://<YOUR_PC_LAN_IP>:8080
AUTH_SERVER_URL=http://<YOUR_PC_LAN_IP>:8081
ENABLE_DEV_AUTH_FALLBACK=true
```

Example:

```env
SIGNALING_URL=ws://192.168.1.20:8080
AUTH_SERVER_URL=http://192.168.1.20:8081
```

Important:
- Both devices must use the exact same `PSK`.
- Both devices must point to the same `SIGNALING_URL` and `AUTH_SERVER_URL`.
- Restart the app after `.env` changes (not just hot reload).

## 2) Start backend services

From repo root `d:\Huddle`, in two terminals:

Terminal A (Auth):

```bash
$env:AUTH_HOST="0.0.0.0"
$env:AUTH_PORT="8081"
$env:ENABLE_DEV_AUTH_FALLBACK="true"
python auth_server.py
```

Terminal B (Signaling):

```bash
python server.py --host 0.0.0.0 --port 8080
```

## 3) Network checks

- Keep both phones on the same Wi-Fi as the PC.
- Allow inbound TCP `8080` and `8081` in Windows Firewall.
- Verify from PC:
  - `http://127.0.0.1:8081/health` returns JSON.

## 4) Run app on both devices

From `client/`:

```bash
flutter pub get
flutter run
```

Install/run on both phones.

## 5) Login/Register flow for dev testing

Because real mobile passkeys require associated domains, this project now supports a dev fallback (`ENABLE_DEV_AUTH_FALLBACK=true`):

1. On each device: tap `New device? Register first`.
2. Register with same username on both devices (or separate usernames).
3. Tap login.

The backend binds each device fingerprint to that user and returns a JWT used by signaling.

## 6) Call test flow

1. Device A taps `Start a New Call`.
2. Device B enters same room code and taps `Join Call`.
3. Grant camera and microphone permissions.
4. You should see local + remote streams.

## Troubleshooting

- Login/Register fails immediately:
  - Confirm `.env` has LAN IP, not `127.0.0.1`.
  - Confirm auth server is started with `AUTH_HOST=0.0.0.0`.
  - Check auth terminal for `POST /dev/session/register` and `POST /dev/session/login`.
- Stuck waiting for peer:
  - Check signaling terminal logs show both joins.
  - Check firewall for `8080`.
- Permission denied:
  - Re-enable camera/microphone in app settings.
