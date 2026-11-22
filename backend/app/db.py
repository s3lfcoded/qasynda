"""SQLite-хранилище: пользователи, устройства, сессии, переводы. Суммы — целые тиыны."""
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
DAY = 24 * 3600

SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
    id INTEGER PRIMARY KEY,
    phone TEXT UNIQUE NOT NULL,
    pin_hash TEXT NOT NULL,
    pin_salt TEXT NOT NULL,
    full_name TEXT NOT NULL,
    balance INTEGER NOT NULL CHECK(balance >= 0),
    is_merchant INTEGER NOT NULL DEFAULT 0,
    business_name TEXT,
    card_last4 TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices(
    id TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    secret_hash TEXT NOT NULL,
    name TEXT NOT NULL,
    created_at REAL NOT NULL,
    last_seen REAL NOT NULL,
    UNIQUE(user_id, secret_hash)
);
CREATE TABLE IF NOT EXISTS sessions(
    token_hash TEXT PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES users(id),
    expires_at REAL NOT NULL,
    device_id TEXT REFERENCES devices(id)
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
CREATE INDEX IF NOT EXISTS transfers_sender_time ON transfers(sender_id, created_at);
"""

# Учебные пользователи. Только для демо: включается переменной QASYNDA_SEED_DEMO=1.
DEMO_USERS = [
    {"phone": "+77010000001", "pin": "1111", "full_name": "Айгерим Касымова",
     "balance": 250_000_00, "is_merchant": 0, "business_name": None, "card_last4": "4417"},
    {"phone": "+77010000002", "pin": "2222", "full_name": "Данияр Ахметов",
     "balance": 1_200_000_00, "is_merchant": 0, "business_name": None, "card_last4": "8052"},
    {"phone": "+77010000003", "pin": "3333", "full_name": "Нурлан Сейтов",
     "balance": 80_000_00, "is_merchant": 1, "business_name": "ИП Сейтов · Жеміс-жидек", "card_last4": "1906"},
]


class TransferError(Exception):
    def __init__(self, code: str, status: int = 409, **extra):
        super().__init__(code)
        self.code, self.status, self.extra = code, status, extra


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
        # База, созданная до привязки устройств: у старых сессий устройства нет, они просто истекут.
        if "device_id" not in {r["name"] for r in c.execute("PRAGMA table_info(sessions)")}:
            c.execute("ALTER TABLE sessions ADD COLUMN device_id TEXT REFERENCES devices(id)")


def _hash_pin(pin: str, salt: str) -> str:
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt), PBKDF2_ROUNDS).hex()


def _sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def seed_demo() -> None:
    with closing(connect()) as c:
        if c.execute("SELECT COUNT(*) FROM users").fetchone()[0]:
            return
        for u in DEMO_USERS:
            salt = secrets.token_hex(16)
            c.execute(
                "INSERT INTO users(phone, pin_hash, pin_salt, full_name, balance, is_merchant, business_name, card_last4)"
                " VALUES(?,?,?,?,?,?,?,?)",
                (u["phone"], _hash_pin(u["pin"], salt), salt, u["full_name"],
                 u["balance"], u["is_merchant"], u["business_name"], u["card_last4"]),
            )


def user_by_phone(phone: str) -> dict | None:
    with closing(connect()) as c:
        row = c.execute("SELECT * FROM users WHERE phone=?", (phone,)).fetchone()
        return dict(row) if row else None


def check_pin(user: dict | None, pin: str) -> bool:
    """Хеш считается и для несуществующего клиента, чтобы время ответа не выдавало, есть ли он."""
    salt = user["pin_salt"] if user else "00" * 16
    candidate = _hash_pin(pin, salt)
    return bool(user) and hmac.compare_digest(candidate, user["pin_hash"])


def device_of(user_id: int, secret: str) -> dict | None:
    with closing(connect()) as c:
        row = c.execute("SELECT * FROM devices WHERE user_id=? AND secret_hash=?",
                        (user_id, _sha(secret))).fetchone()
        return dict(row) if row else None


def add_device(user_id: int, secret: str, name: str) -> str:
    now = time.time()
    device_id = secrets.token_hex(8)
    with closing(connect()) as c:
        c.execute("INSERT OR IGNORE INTO devices(id, user_id, secret_hash, name, created_at, last_seen)"
                  " VALUES(?,?,?,?,?,?)", (device_id, user_id, _sha(secret), name, now, now))
        return c.execute("SELECT id FROM devices WHERE user_id=? AND secret_hash=?",
                         (user_id, _sha(secret))).fetchone()["id"]


def create_session(user_id: int, device_id: str) -> str:
    """Возвращает токен сессии. В базе хранится только хеш токена."""
    token = secrets.token_urlsafe(32)
    now = time.time()
    with closing(connect()) as c:
        c.execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
        c.execute("INSERT INTO sessions(token_hash, user_id, expires_at, device_id) VALUES(?,?,?,?)",
                  (_sha(token), user_id, now + SESSION_TTL, device_id))
        c.execute("UPDATE devices SET last_seen=? WHERE id=?", (now, device_id))
    return token


def logout(token: str) -> None:
    with closing(connect()) as c:
        c.execute("DELETE FROM sessions WHERE token_hash=?", (_sha(token),))


def user_by_token(token: str) -> dict | None:
    """Пользователь сессии; в поле session_device — устройство, с которого она открыта."""
    if not token:
        return None
    now = time.time()
    with closing(connect()) as c:
        row = c.execute(
            "SELECT u.*, s.device_id AS session_device FROM sessions s JOIN users u ON u.id = s.user_id"
            " WHERE s.token_hash=? AND s.expires_at > ?",
            (_sha(token), now),
        ).fetchone()
        if row and row["session_device"]:
            c.execute("UPDATE devices SET last_seen=? WHERE id=? AND last_seen < ?",
                      (now, row["session_device"], now - 60))
        return dict(row) if row else None


def user_by_id(user_id: int) -> dict | None:
    with closing(connect()) as c:
        row = c.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
        return dict(row) if row else None


def devices(user_id: int) -> list[dict]:
    with closing(connect()) as c:
        rows = c.execute("SELECT id, name, created_at, last_seen FROM devices WHERE user_id=?"
                         " ORDER BY last_seen DESC", (user_id,)).fetchall()
        return [dict(r) for r in rows]


def remove_devices(user_id: int, device_ids: list[str]) -> list[str]:
    """Отвязывает устройства и закрывает их сессии. Возвращает, какие устройства действительно удалены."""
    removed = []
    with closing(connect()) as c:
        c.execute("BEGIN IMMEDIATE")
        for device_id in device_ids:
            c.execute("DELETE FROM sessions WHERE user_id=? AND device_id=?", (user_id, device_id))
            if c.execute("DELETE FROM devices WHERE user_id=? AND id=?", (user_id, device_id)).rowcount:
                removed.append(device_id)
        c.execute("COMMIT")
    return removed


def make_transfer(sender_id: int, recipient_id: int, amount: int, method: str,
                  note: str | None, idempotency_key: str,
                  daily_limits: dict[str | None, int] | None = None) -> tuple[dict, bool]:
    """Атомарный перевод. Возвращает (перевод, создан_ли_сейчас).

    Повтор с тем же ключом возвращает исходный перевод и не списывает деньги второй раз.
    daily_limits — сколько отправитель может перевести за последние 24 часа:
    ключ None — всего, ключ-способ ("gps") — только этим способом.
    Суммы считаются внутри той же транзакции, поэтому параллельные переводы лимит не обойдут.
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

            since = time.time() - DAY
            for scope, limit in (daily_limits or {}).items():
                spent = c.execute(
                    "SELECT COALESCE(SUM(amount), 0) FROM transfers WHERE sender_id=? AND created_at>?"
                    + ("" if scope is None else " AND method=?"),
                    (sender_id, since) if scope is None else (sender_id, since, scope),
                ).fetchone()[0]
                if spent + amount > limit:
                    raise TransferError("daily_limit_exceeded", 403, limit=limit, left=max(0, limit - spent),
                                        method=scope)

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
