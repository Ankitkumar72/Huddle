import os
import sqlite3
import time
import base64
import json
import logging
from typing import Optional, Dict
from pydantic import BaseModel
from fastapi import FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from webauthn import generate_registration_options, verify_registration_response, generate_authentication_options, verify_authentication_response
from webauthn.helpers.structs import RegistrationCredential, AuthenticationCredential, AuthenticatorSelectionCriteria, UserVerificationRequirement
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.backends import default_backend

# Setup Logging
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("auth_server")

app = FastAPI(title="Huddle Auth Server")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"], # Update this in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Configuration
RP_ID = "localhost" # Update this for production
RP_NAME = "Huddle"
ORIGIN = os.environ.get("WEBAUTHN_ORIGIN", "http://localhost") 

JWT_EXPIRY_SECONDS = 8 * 60 * 60 # 8 hours

DB_FILE = "auth.db"

# JWT Key Pair Generation (In-memory for simplicity in this example, but should be persisted in production)
# For this implementation, we will generate a new pair on startup. In reality, you'd load this from a secure vault or file.
private_key = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
    backend=default_backend()
)
public_key = private_key.public_key()

PRIVATE_KEY_PEM = private_key.private_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PrivateFormat.PKCS8,
    encryption_algorithm=serialization.NoEncryption()
)
PUBLIC_KEY_PEM = public_key.public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo
)

# --- Database Setup ---
def get_db():
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT UNIQUE,
            display_name TEXT,
            tokens_valid_after INTEGER DEFAULT 0
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS passkey_creds (
            id TEXT PRIMARY KEY,
            user_id TEXT,
            public_key TEXT,
            sign_count INTEGER,
            transports TEXT,
            device_fingerprint TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
    """)
    cursor.execute("""
        CREATE TABLE IF NOT EXISTS revoked_jtis (
            jti TEXT PRIMARY KEY,
            revoked_at INTEGER
        )
    """)
    conn.commit()
    conn.close()

init_db()

# --- In-Memory Challenge Store ---
# In production, use Redis or DB with TTL
registration_challenges: Dict[str, str] = {} # user_id -> challenge
authentication_challenges: Dict[str, str] = {} # user_id -> challenge

# --- Pydantic Models ---
class RegisterBeginRequest(BaseModel):
    username: str
    display_name: str

class RegisterCompleteRequest(BaseModel):
    user_id: str
    device_fingerprint: str
    credential: dict

class LoginBeginRequest(BaseModel):
    username: str

class LoginCompleteRequest(BaseModel):
    username: str
    device_fingerprint: str
    credential: dict

class RevokeRequest(BaseModel):
    user_id: str

# --- Endpoints ---

@app.get("/public_key")
def get_public_key():
    """Endpoint for server.py to fetch the public key to verify JWTs."""
    return {"public_key": PUBLIC_KEY_PEM.decode('utf-8')}

@app.post("/register/begin")
def register_begin(req: RegisterBeginRequest):
    conn = get_db()
    cursor = conn.cursor()
    
    # Check if user exists, if not create dummy user id
    cursor.execute("SELECT id FROM users WHERE username = ?", (req.username,))
    row = cursor.fetchone()
    
    if row:
        user_id = row['id']
    else:
        user_id = base64.urlsafe_b64encode(os.urandom(32)).decode('utf-8').rstrip('=')
        cursor.execute("INSERT INTO users (id, username, display_name) VALUES (?, ?, ?)", 
                       (user_id, req.username, req.display_name))
        conn.commit()
        
    conn.close()

    options = generate_registration_options(
        rp_id=RP_ID,
        rp_name=RP_NAME,
        user_id=user_id.encode('utf-8'),
        user_name=req.username,
        user_display_name=req.display_name,
        authenticator_selection=AuthenticatorSelectionCriteria(
            user_verification=UserVerificationRequirement.PREFERRED
        )
    )
    
    # Store challenge
    registration_challenges[user_id] = options.challenge
    
    return {"options": json.loads(options.json()), "user_id": user_id}

@app.post("/register/complete")
def register_complete(req: RegisterCompleteRequest):
    user_id = req.user_id
    challenge = registration_challenges.get(user_id)
    
    if not challenge:
        raise HTTPException(status_code=400, detail="Challenge not found or expired")

    try:
        verification = verify_registration_response(
            credential=req.credential,
            expected_challenge=challenge.encode('utf-8'),
            expected_origin=ORIGIN,
            expected_rp_id=RP_ID,
            require_user_verification=False # Set to True if you want stricter checks
        )
        
        # Save credential
        conn = get_db()
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO passkey_creds (id, user_id, public_key, sign_count, transports, device_fingerprint)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (
            verification.credential_id.hex(), # store bytes as hex
            user_id,
            verification.credential_public_key.hex(), # store bytes as hex
            verification.sign_count,
            json.dumps([]), # ignored transports for now
            req.device_fingerprint
        ))
        conn.commit()
        conn.close()
        
        del registration_challenges[user_id]
        return {"status": "ok"}
        
    except Exception as e:
        logger.error(f"Registration failed: {e}")
        raise HTTPException(status_code=400, detail=str(e))

@app.post("/login/begin")
def login_begin(req: LoginBeginRequest):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ?", (req.username,))
    row = cursor.fetchone()
    conn.close()
    
    if not row:
        raise HTTPException(status_code=404, detail="User not found")
        
    user_id = row['id']
    
    options = generate_authentication_options(
        rp_id=RP_ID,
        user_verification=UserVerificationRequirement.PREFERRED
    )
    
    authentication_challenges[user_id] = options.challenge
    return {"options": json.loads(options.json()), "user_id": user_id}

@app.post("/login/complete")
def login_complete(req: LoginCompleteRequest):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ?", (req.username,))
    user_row = cursor.fetchone()
    
    if not user_row:
        conn.close()
        raise HTTPException(status_code=404, detail="User not found")
        
    user_id = user_row['id']
    challenge = authentication_challenges.get(user_id)
    
    if not challenge:
        conn.close()
        raise HTTPException(status_code=400, detail="Challenge not found or expired")
        
    # Get the credential ID from the request to look up the public key
    client_credential_id = req.credential.get("id")
    
    cursor.execute("SELECT public_key, sign_count, device_fingerprint FROM passkey_creds WHERE id = ? AND user_id = ?", 
                   (client_credential_id, user_id))
    cred_row = cursor.fetchone()
    
    if not cred_row:
        conn.close()
        raise HTTPException(status_code=401, detail="Credential not registered for this user")
        
    db_device_fingerprint = cred_row['device_fingerprint']
    
    # Enforce Device Binding
    if db_device_fingerprint != req.device_fingerprint:
        conn.close()
        logger.warning(f"Device fingerprint mismatch for user {user_id}. Expected {db_device_fingerprint}, got {req.device_fingerprint}")
        raise HTTPException(status_code=403, detail="Device verification failed. Please register this device.")

    try:
        # Convert hex string back to bytes
        public_key_bytes = bytes.fromhex(cred_row['public_key'])
        
        verification = verify_authentication_response(
            credential=req.credential,
            expected_challenge=challenge.encode('utf-8'),
            expected_origin=ORIGIN,
            expected_rp_id=RP_ID,
            credential_public_key=public_key_bytes,
            credential_current_sign_count=cred_row['sign_count'],
            require_user_verification=False
        )
        
        # Update sign count
        cursor.execute("UPDATE passkey_creds SET sign_count = ? WHERE id = ?", 
                       (verification.new_sign_count, client_credential_id))
        conn.commit()
        conn.close()
        
        del authentication_challenges[user_id]
        
        # Issue JWT
        jti = base64.urlsafe_b64encode(os.urandom(16)).decode('utf-8').rstrip('=')
        now = int(time.time())
        
        payload = {
            "sub": user_id,
            "device": req.device_fingerprint,
            "iat": now,
            "exp": now + JWT_EXPIRY_SECONDS,
            "jti": jti,
            "username": req.username
        }
        
        token = jwt.encode(payload, PRIVATE_KEY_PEM, algorithm="RS256")
        
        return {"token": token}
        
    except Exception as e:
        conn.close()
        logger.error(f"Login failed: {e}")
        raise HTTPException(status_code=401, detail=str(e))

@app.post("/revoke")
def revoke_tokens(req: RevokeRequest):
    conn = get_db()
    cursor = conn.cursor()
    
    now = int(time.time())
    cursor.execute("UPDATE users SET tokens_valid_after = ? WHERE id = ?", (now, req.user_id))
    conn.commit()
    conn.close()
    
    return {"status": "User sessions revoked"}

@app.get("/user/{username}")
def get_user_id(username: str):
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()
    conn.close()
    if row:
        return {"user_id": row['id']}
    raise HTTPException(status_code=404, detail="Not found")

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8081)
