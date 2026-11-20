"""SQLite-хранилище: пользователи, сессии, переводы. Суммы — целые тиыны."""
from __future__ import annotations

import hashlib
import hmac
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import closing

SESSION_TTL = 12 * 3600
PBKDF2_ROUNDS = 100_000

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
    id INTEGER PRIMARY KEY,
    phone TEXT UNIQUE NOT NULL,
    pin_hash TEXT NOT NULL,
    pin_salt TEXT NOT NULL,
    full_name TEXT NOT NULL,
    balance INTEGER NOT NULL CHECK(balance >= 0),
    is_merchant INTEGER NOT NULL DEFAULT 0,
    business_name TEXT
);
CREATE TABLE IF NOT EXISTS sessions(
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    expires_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS transfers(
    id TEXT PRIMARY KEY,
    sender_id INTEGER NOT NULL REFERENCES users(id),
    recipient_id INTEGER NOT NULL REFERENCES users(id),
    amount INTEGER NOT NULL CHECK(amount > 0),
    method TEXT NOT NULL,
    note TEXT,
    created_at REAL NOT NULL,
    idempotency_key TEXT NOT NULL,
    UNIQUE(sender_id, idempotency_key)
);
"""

# Учебные пользователи. Только для демо: включается переменной QASYNDA_SEED_DEMO=1.
DEMO_USERS = [
    {"phone": "+77010000001", "pin": "1111", "full_name": "Айгерим Касымова",
     "balance": 250_000_00, "is_merchant": 0, "business_name": None},
    {"phone": "+77010000002", "pin": "2222", "full_name": "Данияр Ахметов",
     "balance": 1_200_000_00, "is_merchant": 0, "business_name": None},
    {"phone": "+77010000003", "pin": "3333", "full_name": "Нурлан Сейтов",
     "balance": 80_000_00, "is_merchant": 1, "business_name": "ИП Сейтов · Жеміс-жидек"},
]


class TransferError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _path() -> str:
    return os.environ.get("QASYNDA_DB", "qasynda.db")


def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(_path(), isolation_level=None, timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init() -> None:
    with closing(connect()) as c:
        c.execute("PRAGMA journal_mode=WAL")
        c.executescript(SCHEMA)


def _hash_pin(pin: str, salt: str) -> str:
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt), PBKDF2_ROUNDS).hex()


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def seed_demo() -> None:
    with closing(connect()) as c:
        if c.execute("SELECT COUNT(*) FROM users").fetchone()[0]:
            return
        for u in DEMO_USERS:
            salt = secrets.token_hex(16)
            c.execute(
                "INSERT INTO users(phone, pin_hash, pin_salt, full_name, balance, is_merchant, business_name)"
                " VALUES(?,?,?,?,?,?,?)",
                (u["phone"], _hash_pin(u["pin"], salt), salt, u["full_name"],
                 u["balance"], u["is_merchant"], u["business_name"]),
            )


def login(phone: str, pin: str) -> str | None:
    """Возвращает токен сессии или None. В базе хранится только хеш токена."""
    with closing(connect()) as c:
        row = c.execute("SELECT id, pin_hash, pin_salt FROM users WHERE phone=?", (phone,)).fetchone()
        # Считаем хеш и для несуществующего номера, чтобы время ответа не выдавало, есть ли клиент.
        salt = row["pin_salt"] if row else "00" * 16
        candidate = _hash_pin(pin, salt)
        if not row or not hmac.compare_digest(candidate, row["pin_hash"]):
            return None
        token = secrets.token_urlsafe(32)
        now = time.time()
        c.execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
        c.execute("INSERT INTO sessions(token_hash, user_id, expires_at) VALUES(?,?,?)",
                  (_hash_token(token), row["id"], now + SESSION_TTL))
        return token


def logout(token: str) -> None:
    with closing(connect()) as c:
        c.execute("DELETE FROM sessions WHERE token_hash=?", (_hash_token(token),))


def user_by_token(token: str) -> dict | None:
    if not token:
        return None
    with closing(connect()) as c:
        row = c.execute(
            "SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id"
            " WHERE s.token_hash=? AND s.expires_at > ?",
            (_hash_token(token), time.time()),
        ).fetchone()
        return dict(row) if row else None


def user_by_id(user_id: int) -> dict | None:
    with closing(connect()) as c:
        row = c.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        return dict(row) if row else None


def make_transfer(sender_id: int, recipient_id: int, amount: int, method: str,
                  note: str | None, idempotency_key: str) -> tuple[dict, bool]:
    """Атомарный перевод. Возвращает (перевод, создан_ли_сейчас).

    Повтор с тем же ключом возвращает исходный перевод и не списывает деньги второй раз.
    """
    with closing(connect()) as c:
        c.execute("BEGIN IMMEDIATE")
        try:
            existing = c.execute(
                "SELECT * FROM transfers WHERE sender_id=? AND idempotency_key=?",
                (sender_id, idempotency_key),
            ).fetchone()
            if existing:
                if existing["recipient_id"] != recipient_id or existing["amount"] != amount:
                    raise TransferError("idempotency_conflict")
                c.execute("ROLLBACK")
                return dict(existing), False

            debited = c.execute(
                "UPDATE users SET balance = balance - ? WHERE id=? AND balance >= ?",
                (amount, sender_id, amount),
            )
            if debited.rowcount != 1:
                raise TransferError("insufficient_funds")
            credited = c.execute("UPDATE users SET balance = balance + ? WHERE id=?", (amount, recipient_id))
            if credited.rowcount != 1:
                raise TransferError("recipient_not_found")

            transfer = {
                "id": uuid.uuid4().hex, "sender_id": sender_id, "recipient_id": recipient_id,
                "amount": amount, "method": method, "note": note,
                "created_at": time.time(), "idempotency_key": idempotency_key,
            }
            c.execute(
                "INSERT INTO transfers(id, sender_id, recipient_id, amount, method, note, created_at, idempotency_key)"
                " VALUES(:id, :sender_id, :recipient_id, :amount, :method, :note, :created_at, :idempotency_key)",
                transfer,
            )
            c.execute("COMMIT")
            return transfer, True
        except BaseException:
            if c.in_transaction:
                c.execute("ROLLBACK")
            raise


def history(user_id: int, limit: int) -> list[dict]:
    with closing(connect()) as c:
        rows = c.execute(
            "SELECT t.id, t.amount, t.method, t.note, t.created_at, t.sender_id,"
            " s.full_name AS sender_name, r.full_name AS recipient_name,"
            " r.is_merchant AS recipient_is_merchant, r.business_name AS recipient_business"
            " FROM transfers t JOIN users s ON s.id = t.sender_id JOIN users r ON r.id = t.recipient_id"
            " WHERE t.sender_id=? OR t.recipient_id=? ORDER BY t.created_at DESC LIMIT ?",
            (user_id, user_id, limit),
        ).fetchall()
        return [dict(r) for r in rows]
