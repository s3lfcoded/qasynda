"""Ошибки входа и сессий, найденные ревью кода: каждый тест падал до исправления."""
import sqlite3
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import db, guard, main, nearby
from test_api import (AIGERIM, DANIYAR, MERCHANT, auth, bt_body, client, code, confirm, device, login,  # noqa: F401
                      start, wrong_code, ws_url)


# --- unlock window ---

def test_lock_is_not_undone_by_request_in_flight(client, monkeypatch):
    me = auth(client, AIGERIM)
    real_time = time.time
    monkeypatch.setattr(main.time, "time", lambda: real_time() + 60)
    real_by_token = db.user_by_token
    read, go, calls = threading.Event(), threading.Event(), []

    def slow(token):
        user = real_by_token(token)
        if not calls:
            calls.append(1)
            read.set()
            go.wait(5)
        return user

    monkeypatch.setattr(db, "user_by_token", slow)
    with ThreadPoolExecutor(1) as pool:
        poll = pool.submit(client.get, "/me", headers=me)
        assert read.wait(5)
        assert client.post("/auth/lock", headers=me).status_code == 200
        go.set()
        poll.result()
    r = client.get("/me", headers=me)
    assert r.status_code == 403, f"session unlocked again after /auth/lock: {r.status_code}"


def test_fresh_pin_login_resets_unlock_attempts(client):
    me = auth(client, AIGERIM)
    for _ in range(main.LOGIN_ATTEMPTS - 1):
        assert client.post("/auth/unlock", json={"pin": "9999"}, headers=me).status_code == 403
    client.post("/auth/logout", headers=me)
    me = auth(client, AIGERIM)
    client.post("/auth/lock", headers=me)
    codes = [client.post("/auth/unlock", json={"pin": "9999"}, headers=me).status_code for _ in range(2)]
    assert codes == [403, 403], f"new PIN-verified session closed after 2 typos: {codes}"


# --- WebSocket after logout / device removal ---

def test_logout_closes_websocket_of_that_session(client):
    a = auth(client, MERCHANT)
    b = auth(client, MERCHANT, secret=device(MERCHANT, 1))
    buyer = auth(client, AIGERIM)
    with client.websocket_connect(ws_url(client, a)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        assert client.post("/auth/logout", headers=a).status_code == 200
        beacon = client.post("/nearby/beacon", json={}, headers=b).json()
        assert client.post("/transfers", json=bt_body(beacon), headers=buyer).status_code == 200
        with pytest.raises(WebSocketDisconnect):
            event = sock.receive_json()
            pytest.fail(f"socket of logged-out session still receives: {event}")


def test_ticket_issued_before_logout_is_void(client):
    me = auth(client, MERCHANT)
    url = ws_url(client, me)
    assert client.post("/auth/logout", headers=me).status_code == 200
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(url) as sock:
            pytest.fail(f"ticket accepted after logout: {sock.receive_json()}")


def test_ticket_of_removed_device_is_void(client):
    mine = auth(client, MERCHANT)
    thief = auth(client, MERCHANT, secret=device(MERCHANT, 1))
    buyer = auth(client, AIGERIM)
    url = ws_url(client, thief)
    other = next(d for d in client.get("/devices", headers=mine).json()["items"] if not d["current"])
    assert client.delete(f"/devices/{other['id']}", headers=mine).status_code == 200
    assert client.get("/me", headers=thief).status_code == 401
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(url) as sock:
            sock.receive_json()
            beacon = client.post("/nearby/beacon", json={}, headers=mine).json()
            client.post("/transfers", json=bt_body(beacon), headers=buyer)
            pytest.fail(f"removed device connected and got: {sock.receive_json()}")


# --- shared counters ---

def test_stranger_cannot_lock_owner_out_of_new_phone_login(client, monkeypatch):
    real = guard.clock
    shift = [0.0]
    monkeypatch.setattr(guard, "clock", lambda: real() + shift[0])
    for i in range(3):
        pending = start(client, AIGERIM, secret=f"stranger-phone-{i:026d}").json()
        for _ in range(main.SMS_ATTEMPTS):
            code(client, pending, wrong_code(pending))
            confirm(client, pending, "0000")
        shift[0] += 301
    shift[0] += 3600
    pending = start(client, AIGERIM, secret=device(AIGERIM, 5)).json()
    assert pending["next"] == "sms", pending
    assert code(client, pending).status_code == 200
    r = confirm(client, pending, AIGERIM["pin"])
    assert r.status_code == 200, f"owner with the right SMS code and PIN: {r.status_code} {r.json()}"


def test_strangers_new_phone_logins_do_not_block_owner_login(client, monkeypatch):
    auth(client, DANIYAR)
    real = db.device_of
    started, go = threading.Semaphore(0), threading.Event()

    def slow(user_id, secret):
        if secret.startswith("stranger"):
            started.release()
            go.wait(5)
        return real(user_id, secret)

    monkeypatch.setattr(db, "device_of", slow)
    n = main.LOGIN_ATTEMPTS
    with ThreadPoolExecutor(n) as pool:
        futs = [pool.submit(login, client, DANIYAR, "0000", f"stranger-{i:030d}") for i in range(n)]
        for _ in range(n):
            assert started.acquire(timeout=5)
        r = login(client, DANIYAR)
        go.set()
        [f.result() for f in futs]
    assert r.status_code == 200 and "token" in r.json(), f"owner on own phone, right PIN: {r.status_code} {r.json()}"


def test_failures_on_bound_phone_do_not_change_new_phone_reply(client):
    auth(client, DANIYAR)
    for _ in range(main.LOGIN_ATTEMPTS):
        login(client, DANIYAR, pin="9999")
    r = start(client, DANIYAR, secret=device(DANIYAR, 3))
    nobody = start(client, DANIYAR, secret=device(DANIYAR, 4), phone="+77000000099")
    assert r.status_code == nobody.status_code == 200, (r.status_code, r.json(), nobody.status_code)
    assert set(r.json()) == set(nobody.json()) and r.json()["next"] == nobody.json()["next"] == "sms"
    assert code(client, r.json()).status_code == code(client, nobody.json()).status_code == 200
    a, b = confirm(client, r.json(), "9999"), confirm(client, nobody.json(), "9999")
    assert (a.status_code, a.json()) == (b.status_code, b.json()) == (401, {"detail": {"code": "invalid_credentials"}})


def test_flood_of_other_numbers_does_not_reset_pin_limit(client, monkeypatch):
    # In production max_keys is 100_000; shrunk so the test is fast. Nothing limits the flood without QASYNDA_IP_HEADER.
    for w in (main._login_short, main._login_long):
        monkeypatch.setattr(w, "max_keys", 50)
    auth(client, DANIYAR)
    for _ in range(main.LOGIN_ATTEMPTS):
        assert login(client, DANIYAR, pin="9999").status_code == 401
    assert login(client, DANIYAR, pin="9999").status_code == 429
    for i in range(50):
        pending = start(client, AIGERIM, secret=device(AIGERIM, i), phone=f"+7700{i:07d}").json()
        code(client, pending)
        confirm(client, pending, "1111")
    r = login(client, DANIYAR, pin="9999")
    assert r.status_code == 429, f"PIN guessing reopened by a flood of unrelated numbers: {r.status_code}"


# --- races that end in 500 ---

def test_device_removed_during_login_is_not_500(client, monkeypatch):
    mine = auth(client, AIGERIM)
    auth(client, AIGERIM, secret=device(AIGERIM, 1))
    other = next(d for d in client.get("/devices", headers=mine).json()["items"] if not d["current"])
    real = db.device_of

    def racing(user_id, secret):
        found = real(user_id, secret)
        db.remove_devices(user_id, [other["id"]])
        return found

    monkeypatch.setattr(db, "device_of", racing)
    plain = TestClient(main.app, raise_server_exceptions=False)
    r = login(plain, AIGERIM, secret=device(AIGERIM, 1))
    assert r.status_code < 500, f"{r.status_code} {r.text}"


# --- existing database ---

SCHEMA_6d24990 = """
CREATE TABLE users(id INTEGER PRIMARY KEY, phone TEXT UNIQUE NOT NULL, pin_hash TEXT NOT NULL, pin_salt TEXT NOT NULL,
    full_name TEXT NOT NULL, balance INTEGER NOT NULL CHECK(balance >= 0), is_merchant INTEGER NOT NULL DEFAULT 0,
    business_name TEXT, card_last4 TEXT NOT NULL);
CREATE TABLE sessions(token_hash TEXT PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), expires_at REAL NOT NULL);
CREATE TABLE transfers(id TEXT PRIMARY KEY, sender_id INTEGER NOT NULL REFERENCES users(id),
    recipient_id INTEGER NOT NULL REFERENCES users(id), amount INTEGER NOT NULL CHECK(amount > 0), method TEXT NOT NULL,
    note TEXT, created_at REAL NOT NULL, idempotency_key TEXT NOT NULL, UNIQUE(sender_id, idempotency_key));
"""
SCHEMA_d8276a4 = SCHEMA_6d24990.replace(", card_last4 TEXT NOT NULL", "")


def old_db(tmp_path, monkeypatch, schema):
    path = tmp_path / "old.db"
    monkeypatch.setenv("QASYNDA_DB", str(path))
    monkeypatch.setenv("QASYNDA_SEED_DEMO", "1")
    monkeypatch.setenv("QASYNDA_SMS_DEMO", "1")
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 1000)
    nearby.reset()
    guard.reset()
    main._tickets.clear()
    main._challenges.clear()
    salt = "ab" * 16
    token = "legacy-session-token-0123456789abcdef"
    conn = sqlite3.connect(path)
    conn.executescript(schema)
    cols = "phone, pin_hash, pin_salt, full_name, balance"
    vals = [AIGERIM["phone"], db._hash_pin(AIGERIM["pin"], salt), salt, AIGERIM["full_name"], AIGERIM["balance"]]
    if "card_last4" in schema:
        cols += ", card_last4"
        vals.append(AIGERIM["card_last4"])
    conn.execute(f"INSERT INTO users({cols}) VALUES({','.join('?' * len(vals))})", vals)
    conn.execute("INSERT INTO sessions VALUES(?,?,?)", (db._sha(token), 1, time.time() + db.SESSION_TTL))
    conn.commit()
    conn.close()
    return {"Authorization": f"Bearer {token}"}


def test_logout_others_also_closes_sessions_from_before_devices(tmp_path, monkeypatch):
    legacy = old_db(tmp_path, monkeypatch, SCHEMA_6d24990)
    with TestClient(main.app) as c:
        # Сессии без устройства закрываются уже при миграции: их нельзя ни увидеть, ни закрыть из списка.
        assert c.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=legacy).status_code == 401
        assert c.get("/me", headers=legacy).status_code == 401
        mine = auth(c, AIGERIM)
        assert c.post("/devices/logout-others", headers=mine).json() == {"removed": 0}


def test_db_from_first_version_is_migrated(tmp_path, monkeypatch):
    old_db(tmp_path, monkeypatch, SCHEMA_d8276a4)
    with TestClient(main.app, raise_server_exceptions=False) as c:
        me = auth(c, AIGERIM)
        r = c.get("/me", headers=me)
        assert r.status_code == 200, f"{r.status_code} {r.text}"
