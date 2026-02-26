import urllib.request
import json
import jwt

AUTH_SERVER_URL = "http://127.0.0.1:8081"

def get_dev_token():
    try:
        req = urllib.request.Request(f"{AUTH_SERVER_URL}/dev/session/register", data=b'{"username":"du","display_name":"du","device_fingerprint":"test_fp"}', headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req)
        
        req = urllib.request.Request(f"{AUTH_SERVER_URL}/dev/session/login", data=b'{"username":"du","device_fingerprint":"test_fp"}', headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode())["token"]
    except Exception as e:
        print("Error getting dev token:", e)
        return None

token = get_dev_token()

if token:
    try:
        req = urllib.request.Request(f"{AUTH_SERVER_URL}/public_key")
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            pub_key = data.get("public_key")
            print("Got pub key successfully.")
            
            try:
                payload = jwt.decode(token, pub_key, algorithms=["RS256"])
                print("Payload decoded successfully:", payload)
            except Exception as e:
                print("Decode Error:", e)
    except Exception as e:
        print("Fetch Error:", e)
else:
    print("Could not obtain token.")
