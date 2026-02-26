import jwt
import time
from auth_server import load_or_create_jwt_keys

priv, pub = load_or_create_jwt_keys()
payload = {'sub': 'test', 'iat': int(time.time()), 'exp': int(time.time()) + 3600}
token = jwt.encode(payload, priv, algorithm='RS256')
print('Generated token:', token)
try:
    decoded = jwt.decode(token, pub, algorithms=['RS256'])
    print('Decoded:', decoded)
except Exception as e:
    print('Error:', e)
