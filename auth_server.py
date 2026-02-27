import os
import sqlite3
import time
import base64
import json
import logging
from typing import Optional, Dict

from pydantic import BaseModel
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from webauthn import (
    generate_registration_options,
    verify_registration_response,
    generate_authentication_options,
    verify_authentication_response,
    options_to_json,
)
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria,
    UserVerificationRequirement,
)
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
    allow_origins=["*"],  # Update this in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# Configuration
def env_flag(name: str, default: str = "false") -> bool:
    return os.environ.get(name, default).strip().lower() in {"1", "true", "yes", "on"}


RP_ID = os.environ.get("WEBAUTHN_RP_ID", "localhost")
RP_NAME = os.environ.get("WEBAUTHN_RP_NAME", "Huddle")
ORIGIN = os.environ.get("WEBAUTHN_ORIGIN", "http://localhost")

AUTH_HOST = os.environ.get("AUTH_HOST", "0.0.0.0")
AUTH_PORT = int(os.environ.get("AUTH_PORT", "8081"))

ENABLE_DEV_AUTH_FALLBACK = env_flag("ENABLE_DEV_AUTH_FALLBACK", "true")
JWT_EXPIRY_SECONDS = 8 * 60 * 60  # 8 hours

DB_FILE = "auth.db"
PRIVATE_KEY_FILE = os.environ.get("JWT_PRIVATE_KEY_FILE", "auth_private_key.pem")
PUBLIC_KEY_FILE = os.environ.get("JWT_PUBLIC_KEY_FILE", "auth_public_key.pem")


def load_or_create_jwt_keys() -> tuple[bytes, bytes]:
    if os.path.exists(PRIVATE_KEY_FILE):
        with open(PRIVATE_KEY_FILE, "rb") as private_file:
            private_pem = private_file.read()
        loaded_private_key = serialization.load_pem_private_key(
            private_pem,
            password=None,
            backend=default_backend(),
        )
        loaded_public_key = loaded_private_key.public_key()
        public_pem = loaded_public_key.public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )

        # Keep public key file in sync for easier debugging/inspection.
        with open(PUBLIC_KEY_FILE, "wb") as public_file:
            public_file.write(public_pem)

        logger.info("Loaded persisted JWT key pair from disk.")
        return private_pem, public_pem

    generated_private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
        backend=default_backend(),
    )
    generated_public_key = generated_private_key.public_key()

    private_pem = generated_private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_pem = generated_public_key.public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )

    with open(PRIVATE_KEY_FILE, "wb") as private_file:
        private_file.write(private_pem)
    with open(PUBLIC_KEY_FILE, "wb") as public_file:
        public_file.write(public_pem)

    logger.info("Generated new JWT key pair and persisted it to disk.")
    return private_pem, public_pem


PRIVATE_KEY_PEM, PUBLIC_KEY_PEM = load_or_create_jwt_keys()


# --- Database Setup ---
def get_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_FILE)
    conn.row_factory = sqlite3.Row
    return conn


def init_db() -> None:
    conn = get_db()
    cursor = conn.cursor()
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            username TEXT UNIQUE,
            display_name TEXT,
            tokens_valid_after INTEGER DEFAULT 0
        )
    """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS passkey_creds (
            id TEXT PRIMARY KEY,
            user_id TEXT,
            public_key TEXT,
            sign_count INTEGER,
            transports TEXT,
            device_fingerprint TEXT,
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
    """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS device_bindings (
            user_id TEXT,
            device_fingerprint TEXT,
            created_at INTEGER,
            PRIMARY KEY(user_id, device_fingerprint),
            FOREIGN KEY(user_id) REFERENCES users(id)
        )
    """
    )
    cursor.execute(
        """
        CREATE TABLE IF NOT EXISTS revoked_jtis (
            jti TEXT PRIMARY KEY,
            revoked_at INTEGER
        )
    """
    )
    conn.commit()
    conn.close()


init_db()


# --- In-Memory Challenge Store ---
# In production, use Redis or DB with TTL
registration_challenges: Dict[str, str] = {}  # user_id -> challenge
authentication_challenges: Dict[str, str] = {}  # user_id -> challenge


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


class DevRegisterRequest(BaseModel):
    username: str
    display_name: str
    device_fingerprint: str


class DevLoginRequest(BaseModel):
    username: str
    device_fingerprint: str


class RevokeRequest(BaseModel):
    user_id: str


# --- Helpers ---
def normalize_username(username: str) -> str:
    return username.strip()


def create_user_id() -> str:
    return base64.urlsafe_b64encode(os.urandom(32)).decode("utf-8").rstrip("=")


def issue_token(user_id: str, username: str, device_fingerprint: str) -> str:
    jti = base64.urlsafe_b64encode(os.urandom(16)).decode("utf-8").rstrip("=")
    now = int(time.time())
    payload = {
        "sub": user_id,
        "device": device_fingerprint,
        "iat": now,
        "exp": now + JWT_EXPIRY_SECONDS,
        "jti": jti,
        "username": username,
    }
    return jwt.encode(payload, PRIVATE_KEY_PEM, algorithm="RS256")


def bind_device(cursor: sqlite3.Cursor, user_id: str, device_fingerprint: str) -> None:
    cursor.execute(
        """
        INSERT OR IGNORE INTO device_bindings (user_id, device_fingerprint, created_at)
        VALUES (?, ?, ?)
    """,
        (user_id, device_fingerprint, int(time.time())),
    )


# --- Endpoints ---
@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "rp_id": RP_ID,
        "origin": ORIGIN,
        "dev_auth_fallback": ENABLE_DEV_AUTH_FALLBACK,
    }


@app.get("/public_key")
def get_public_key() -> dict:
    """Endpoint for server.py to fetch the public key to verify JWTs."""
    return {"public_key": PUBLIC_KEY_PEM.decode("utf-8")}


@app.post("/register/begin")
def register_begin(req: RegisterBeginRequest):
    username = normalize_username(req.username)
    display_name = req.display_name.strip()

    conn = get_db()
    cursor = conn.cursor()

    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()

    if row:
        user_id = row["id"]
        if display_name:
            cursor.execute("UPDATE users SET display_name = ? WHERE id = ?", (display_name, user_id))
            conn.commit()
    else:
        user_id = create_user_id()
        cursor.execute(
            "INSERT INTO users (id, username, display_name) VALUES (?, ?, ?)",
            (user_id, username, display_name),
        )
        conn.commit()

    conn.close()

    options = generate_registration_options(
        rp_id=RP_ID,
        rp_name=RP_NAME,
        user_id=user_id.encode("utf-8"),
        user_name=username,
        user_display_name=display_name or username,
        authenticator_selection=AuthenticatorSelectionCriteria(
            user_verification=UserVerificationRequirement.PREFERRED
        ),
    )

    registration_challenges[user_id] = options.challenge
    return {"options": json.loads(options_to_json(options)), "user_id": user_id}


@app.post("/register/complete")
def register_complete(req: RegisterCompleteRequest):
    user_id = req.user_id
    challenge = registration_challenges.get(user_id)

    if not challenge:
        raise HTTPException(status_code=400, detail="Challenge not found or expired")

    try:
        verification = verify_registration_response(
            credential=req.credential,
            expected_challenge=challenge.encode("utf-8"),
            expected_origin=ORIGIN,
            expected_rp_id=RP_ID,
            require_user_verification=False,
        )

        conn = get_db()
        cursor = conn.cursor()
        cursor.execute(
            """
            INSERT INTO passkey_creds (id, user_id, public_key, sign_count, transports, device_fingerprint)
            VALUES (?, ?, ?, ?, ?, ?)
        """,
            (
                verification.credential_id.hex(),
                user_id,
                verification.credential_public_key.hex(),
                verification.sign_count,
                json.dumps([]),
                req.device_fingerprint,
            ),
        )
        bind_device(cursor, user_id, req.device_fingerprint)
        conn.commit()
        conn.close()

        del registration_challenges[user_id]
        return {"status": "ok"}

    except Exception as e:
        logger.error("Registration failed: %s", e)
        raise HTTPException(status_code=400, detail=str(e))


@app.post("/login/begin")
def login_begin(req: LoginBeginRequest):
    username = normalize_username(req.username)

    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()
    conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="User not found")

    user_id = row["id"]

    options = generate_authentication_options(
        rp_id=RP_ID,
        user_verification=UserVerificationRequirement.PREFERRED,
    )

    authentication_challenges[user_id] = options.challenge
    return {"options": json.loads(options_to_json(options)), "user_id": user_id}


@app.post("/login/complete")
def login_complete(req: LoginCompleteRequest):
    username = normalize_username(req.username)

    conn = get_db()
    cursor = conn.cursor()
    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    user_row = cursor.fetchone()

    if not user_row:
        conn.close()
        raise HTTPException(status_code=404, detail="User not found")

    user_id = user_row["id"]
    challenge = authentication_challenges.get(user_id)

    if not challenge:
        conn.close()
        raise HTTPException(status_code=400, detail="Challenge not found or expired")

    client_credential_id = req.credential.get("id")

    cursor.execute(
        "SELECT public_key, sign_count, device_fingerprint FROM passkey_creds WHERE id = ? AND user_id = ?",
        (client_credential_id, user_id),
    )
    cred_row = cursor.fetchone()

    if not cred_row:
        conn.close()
        raise HTTPException(status_code=401, detail="Credential not registered for this user")

    db_device_fingerprint = cred_row["device_fingerprint"]
    if db_device_fingerprint != req.device_fingerprint:
        conn.close()
        logger.warning(
            "Device fingerprint mismatch for user %s. Expected %s, got %s",
            user_id,
            db_device_fingerprint,
            req.device_fingerprint,
        )
        raise HTTPException(status_code=403, detail="Device verification failed. Please register this device.")

    try:
        public_key_bytes = bytes.fromhex(cred_row["public_key"])

        verification = verify_authentication_response(
            credential=req.credential,
            expected_challenge=challenge.encode("utf-8"),
            expected_origin=ORIGIN,
            expected_rp_id=RP_ID,
            credential_public_key=public_key_bytes,
            credential_current_sign_count=cred_row["sign_count"],
            require_user_verification=False,
        )

        cursor.execute(
            "UPDATE passkey_creds SET sign_count = ? WHERE id = ?",
            (verification.new_sign_count, client_credential_id),
        )
        bind_device(cursor, user_id, req.device_fingerprint)
        conn.commit()
        conn.close()

        del authentication_challenges[user_id]

        token = issue_token(user_id=user_id, username=username, device_fingerprint=req.device_fingerprint)
        return {"token": token}

    except Exception as e:
        conn.close()
        logger.error("Login failed: %s", e)
        raise HTTPException(status_code=401, detail=str(e))


@app.post("/dev/session/register")
def dev_register(req: DevRegisterRequest):
    if not ENABLE_DEV_AUTH_FALLBACK:
        raise HTTPException(status_code=404, detail="Not found")

    username = normalize_username(req.username)
    display_name = req.display_name.strip()
    device_fingerprint = req.device_fingerprint.strip()

    if not username or not device_fingerprint:
        raise HTTPException(status_code=400, detail="username and device_fingerprint are required")

    conn = get_db()
    cursor = conn.cursor()

    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()

    if row:
        user_id = row["id"]
        if display_name:
            cursor.execute("UPDATE users SET display_name = ? WHERE id = ?", (display_name, user_id))
    else:
        user_id = create_user_id()
        cursor.execute(
            "INSERT INTO users (id, username, display_name) VALUES (?, ?, ?)",
            (user_id, username, display_name or username),
        )

    bind_device(cursor, user_id, device_fingerprint)
    conn.commit()
    conn.close()

    logger.warning("DEV fallback registration used for username=%s", username)
    return {"status": "ok", "mode": "dev_fallback"}


@app.post("/dev/session/login")
def dev_login(req: DevLoginRequest):
    if not ENABLE_DEV_AUTH_FALLBACK:
        raise HTTPException(status_code=404, detail="Not found")

    username = normalize_username(req.username)
    device_fingerprint = req.device_fingerprint.strip()

    if not username or not device_fingerprint:
        raise HTTPException(status_code=400, detail="username and device_fingerprint are required")

    conn = get_db()
    cursor = conn.cursor()

    cursor.execute("SELECT id FROM users WHERE username = ?", (username,))
    row = cursor.fetchone()
    if not row:
        conn.close()
        raise HTTPException(status_code=404, detail="User not found")

    user_id = row["id"]
    cursor.execute(
        "SELECT 1 FROM device_bindings WHERE user_id = ? AND device_fingerprint = ?",
        (user_id, device_fingerprint),
    )
    binding = cursor.fetchone()
    conn.close()

    if not binding:
        raise HTTPException(status_code=403, detail="Device not registered. Please register this device first.")

    logger.warning("DEV fallback login used for username=%s", username)
    token = issue_token(user_id=user_id, username=username, device_fingerprint=device_fingerprint)
    return {"token": token, "mode": "dev_fallback"}


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
        return {"user_id": row["id"]}
    raise HTTPException(status_code=404, detail="Not found")


if __name__ == "__main__":
    import uvicorn

    logger.info(
        "Starting auth server host=%s port=%s rp_id=%s origin=%s dev_fallback=%s",
        AUTH_HOST,
        AUTH_PORT,
        RP_ID,
        ORIGIN,
        ENABLE_DEV_AUTH_FALLBACK,
    )
    uvicorn.run(app, host=AUTH_HOST, port=AUTH_PORT)
