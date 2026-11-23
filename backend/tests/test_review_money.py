"""Ошибки переводов и поиска рядом, найденные ревью кода: каждый тест падал до исправления."""
import pytest
from fastapi.testclient import TestClient

import test_api as T
from app import db, guard, main, nearby

client = T.client
auth, bt_body, key, balance = T.auth, T.bt_body, T.key, T.balance
AIGERIM, DANIYAR, MERCHANT = T.AIGERIM, T.DANIYAR, T.MERCHANT
HERE = T.HERE

M_PER_DEG_LAT = 6_371_000.0 * 3.141592653589793 / 180


def lat_m(m):
    return m / M_PER_DEG_LAT


# --- 1. note cleaning: contact details slip through ---

@pytest.mark.parametrize("note", [
    "пиши в т.me/scam",                      # Cyrillic "т" homoglyph, renders as t.me
    "пиши в ｔ．ｍｅ/scam",                    # fullwidth letters + fullwidth dot
    "zabiray．site/podarok",                 # fullwidth full stop
    "верните на сайт.рф/vozvrat",            # Cyrillic (IDN) domain
    "верните 8/701/000/00/01",               # slash separators
    "верните 8\u034f7\u034f0\u034f1\u034f0\u034f0\u034f0\u034f0\u034f0\u034f0\u034f1",  # CGJ (invisible, Mn)
    "верните 8\u3164701\u31640000001",       # Hangul filler (invisible, Lo)
])
def test_note_contact_details_bypass_filter(client, note):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, note=note), headers=buyer)
    assert r.status_code == 422, (r.status_code, r.json().get("note"))


@pytest.mark.parametrize("ch", ["\u034f", "\u3164", "\ufe00", "\u180b"])
def test_note_default_ignorable_chars_are_not_removed(client, ch):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, note=f"за{ch}яблоки"), headers=buyer)
    assert r.status_code == 200
    assert r.json()["note"] in ("заяблоки", "за яблоки"), repr(r.json()["note"])


# --- 2. GPS plausibility: slack is per request, not per second ---

def test_speed_check_bypassed_by_many_small_jumps(client, monkeypatch):
    t0 = nearby.clock()
    monkeypatch.setattr(nearby, "clock", lambda: t0)        # all requests within the same instant
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    target = {"lat": HERE["lat"] + lat_m(3400), "lon": HERE["lon"], "accuracy": 100}
    assert client.post("/nearby/beacon", json={"location": target}, headers=seller).json()["gps"] == "ok"

    assert client.post("/nearby/discover", json={"location": {**HERE, "accuracy": 100}},
                       headers=buyer).json()["gps"] == "ok"
    for step in range(1, 11):
        loc = {"lat": HERE["lat"] + lat_m(340 * step), "lon": HERE["lon"], "accuracy": 100}
        r = client.post("/nearby/discover", json={"location": loc}, headers=buyer).json()
    # 3.4 km in 0 seconds (allowed by the README rule: 30 m/s) — the last position must be ignored.
    assert r["gps"] == "ignored" and r["people"] == [], r


# --- 3. proximity buckets + free movement = exact location of the recipient ---

def test_close_near_buckets_reveal_exact_position(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    secret = {"lat": HERE["lat"] + 0.0000657, "lon": HERE["lon"] - 0.0000503, "accuracy": 5}  # ~7.3 m N, 4.1 m W
    client.post("/nearby/beacon", json={"location": secret}, headers=seller)
    m_lon = M_PER_DEG_LAT * 0.7325
    p = {"lat": HERE["lat"], "lon": HERE["lon"], "accuracy": 5}
    calls = [0]

    def close(lat, lon):
        # Меток «ближе / дальше» для GPS больше нет; остаётся только «виден / не виден».
        calls[0] += 1
        r = client.post("/nearby/discover", json={"location": {"lat": lat, "lon": lon, "accuracy": 5}},
                        headers=buyer)
        assert r.status_code == 200, r.text
        return bool(r.json()["people"])

    def edge(move):
        lo, hi = 0.0, 150.0
        for _ in range(9):
            mid = (lo + hi) / 2
            lo, hi = (mid, hi) if close(*move(mid)) else (lo, mid)
        return (lo + hi) / 2

    assert close(p["lat"], p["lon"])
    north = edge(lambda d: (p["lat"] + lat_m(d), p["lon"]))
    south = edge(lambda d: (p["lat"] - lat_m(d), p["lon"]))
    east = edge(lambda d: (p["lat"], p["lon"] + d / m_lon))
    west = edge(lambda d: (p["lat"], p["lon"] - d / m_lon))
    est_lat = p["lat"] + lat_m((north - south) / 2)
    est_lon = p["lon"] + ((east - west) / 2) / m_lon
    err = nearby._haversine_m(est_lat, est_lon, secret["lat"], secret["lon"])
    # Comment in discover(): exact distance is hidden so the position cannot be computed.
    assert err > 10, f"recipient located to {err:.2f} m with {calls[0]} discover calls"


# --- 4. idempotent replay is not honored before proximity / rate checks ---

def test_retry_with_same_key_after_recipient_closed_screen(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    body = bt_body(beacon, 1_000_00)
    first = client.post("/transfers", json=body, headers=buyer)
    assert first.status_code == 200
    client.delete("/nearby/beacon", headers=seller)
    retry = client.post("/transfers", json=body, headers=buyer)   # e.g. response lost, client retries
    assert balance(client, buyer) == AIGERIM["balance"] - 1_000_00   # money did move
    assert retry.status_code == 200 and retry.json()["id"] == first.json()["id"], (retry.status_code, retry.text)


def test_retries_with_same_key_consume_pair_limit(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    body = bt_body(beacon, 1_000_00)
    codes = [client.post("/transfers", json=body, headers=buyer).status_code for _ in range(4)]
    assert balance(client, buyer) == AIGERIM["balance"] - 1_000_00
    assert codes == [200, 200, 200, 200], codes


def test_rejected_transfers_consume_pair_limit(client):
    seller, buyer = auth(client, DANIYAR), auth(client, MERCHANT)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    for _ in range(3):
        r = client.post("/transfers", json=bt_body(beacon, MERCHANT["balance"] + 1), headers=buyer)
        assert r.json()["detail"]["code"] == "insufficient_funds"
    r = client.post("/transfers", json=bt_body(beacon, 1_000_00), headers=buyer)
    assert r.status_code == 200, r.text   # README: "одному получателю — 3 [перевода] за 10 минут"


# --- 5. coordinates outlive the beacon ---

def test_coordinates_are_forgotten_after_beacon_off_and_logout(client):
    seller = auth(client, MERCHANT)
    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)
    client.delete("/nearby/beacon", headers=seller)
    client.post("/auth/logout", headers=seller)
    uid = db.user_by_phone(MERCHANT["phone"])["id"]
    track = nearby._tracks.get(uid)
    # Точные координаты стёрты; остаётся только квадрат ~1 км, чтобы повторный вход не позволял «телепорт».
    assert track is None or (track.last is None and track.window is None), track


# --- 6. unhandled exceptions -> 500 ---

@pytest.mark.parametrize("path,raw", [
    ("/nearby/discover", '{"location": {"lat": 1e999, "lon": 71.3, "accuracy": 10}}'),
    ("/nearby/discover", '{"location": {"lat": 42.9, "lon": 71.3, "accuracy": NaN}}'),
    ("/transfers", '{"public_id": "%s", "amount": 10000, "idempotency_key": "abcdefgh", "note": "\\ud800"}'),
    ("/transfers", '{"public_id": "%s", "amount": 10000, "idempotency_key": "abcdefgh\\ud800"}'),
])
def test_malformed_json_values_give_422_not_500(client, path, raw):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    if "%s" in raw:
        raw = raw % beacon["public_id"]
    c = TestClient(main.app, raise_server_exceptions=False)
    r = c.post(path, content=raw, headers={**buyer, "Content-Type": "application/json"})
    assert r.status_code == 422, r.status_code


def test_locked_db_gives_500_on_transfer(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    blocker = db.connect()
    blocker.execute("BEGIN IMMEDIATE")          # another writer holding the SQLite write lock > 5 s
    try:
        c = TestClient(main.app, raise_server_exceptions=False)
        r = c.post("/transfers", json=bt_body(beacon), headers=buyer)
    finally:
        blocker.execute("ROLLBACK")
        blocker.close()
    assert r.status_code != 500, r.status_code
