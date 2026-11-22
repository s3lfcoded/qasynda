import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app import db, guard, main, nearby

AIGERIM, DANIYAR, MERCHANT = db.DEMO_USERS
HERE = {"lat": 42.9000, "lon": 71.3667, "accuracy": 10}
CLOSE = {"lat": 42.9002, "lon": 71.3667, "accuracy": 10}     # ~22 м
FAR = {"lat": 42.9100, "lon": 71.3667, "accuracy": 10}       # ~1,1 км
ASTANA = {"lat": 51.1280, "lon": 71.4300, "accuracy": 5}     # ~920 км от HERE


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("QASYNDA_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("QASYNDA_SEED_DEMO", "1")
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 1000)
    nearby.reset()
    guard.reset()
    main._tickets.clear()
    with TestClient(main.app) as c:
        yield c


def auth(client, user):
    r = client.post("/auth/login", json={"phone": user["phone"], "pin": user["pin"]})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def key():
    return uuid.uuid4().hex


def balance(client, headers):
    return client.get("/me", headers=headers).json()["balance"]


def bt_body(beacon, amount=main.MIN_AMOUNT, **extra):
    return {"public_id": beacon["public_id"], "ble_ids": [beacon["ble_id"]], "amount": amount,
            "idempotency_key": key(), **extra}


def ws_url(client, headers):
    ticket = client.post("/ws/ticket", headers=headers).json()["ticket"]
    return f"/ws?ticket={ticket}"


def test_login_rejects_wrong_pin_and_throttles(client):
    bad = {"phone": AIGERIM["phone"], "pin": "9999"}
    for _ in range(main.LOGIN_ATTEMPTS):
        assert client.post("/auth/login", json=bad).status_code == 401
    assert client.post("/auth/login", json=bad).status_code == 429
    good = {"phone": AIGERIM["phone"], "pin": AIGERIM["pin"]}
    assert client.post("/auth/login", json=good).status_code == 429


def test_profile_has_card_but_strangers_do_not_see_it(client):
    me = client.get("/me", headers=auth(client, AIGERIM)).json()
    assert me["card_last4"] == AIGERIM["card_last4"] and me["balance"] == AIGERIM["balance"]
    seller, buyer = auth(client, AIGERIM), auth(client, DANIYAR)
    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)
    person = client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"][0]
    assert "card_last4" not in person and "balance" not in person and "phone" not in person


def test_requires_auth(client):
    assert client.get("/me").status_code == 401
    assert client.post("/nearby/discover", json={}).status_code == 401
    assert client.get("/me", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_discover_by_gps_finds_close_and_hides_far(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)

    people = client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"]
    assert len(people) == 1
    person = people[0]
    assert person["method"] == "gps" and person["proximity"] == "close"
    assert "distance_m" not in person
    assert person["is_merchant"] is True and person["business_name"] == MERCHANT["business_name"]
    assert person["name"] == "Нурлан С."
    assert person["limit"] == main.LIMIT_GPS
    assert "ble_id" not in person

    assert client.post("/nearby/discover", json={"location": FAR}, headers=buyer).json()["people"] == []
    # сам себя получатель не видит
    assert client.post("/nearby/discover", json={"location": HERE}, headers=seller).json()["people"] == []


def test_discover_by_bluetooth_wins_over_gps(client):
    seller, buyer = auth(client, DANIYAR), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    people = client.post("/nearby/discover", json={"location": CLOSE, "ble_ids": [beacon["ble_id"]]},
                         headers=buyer).json()["people"]
    assert len(people) == 1
    assert people[0]["method"] == "bluetooth" and people[0]["limit"] == main.LIMIT_BLUETOOTH
    assert people[0]["business_name"] is None


def test_gps_transfer_moves_money_and_respects_limit(client):
    seller, buyer = auth(client, MERCHANT), auth(client, DANIYAR)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    before_buyer, before_seller = balance(client, buyer), balance(client, seller)

    body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": 3_500_00, "idempotency_key": key()}
    r = client.post("/transfers", json=body, headers=buyer)
    assert r.status_code == 200, r.text
    assert r.json()["method"] == "gps" and r.json()["balance"] == before_buyer - 3_500_00
    assert balance(client, seller) == before_seller + 3_500_00

    over = {**body, "amount": main.LIMIT_GPS + 1, "idempotency_key": key()}
    r = client.post("/transfers", json=over, headers=buyer)
    assert r.status_code == 403 and r.json()["detail"]["code"] == "limit_exceeded"
    assert balance(client, buyer) == before_buyer - 3_500_00


def test_bluetooth_proof_raises_limit(client):
    seller, buyer = auth(client, MERCHANT), auth(client, DANIYAR)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, main.LIMIT_GPS + 1), headers=buyer)
    assert r.status_code == 200 and r.json()["method"] == "bluetooth"


def test_not_nearby_is_refused(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    base = {"public_id": beacon["public_id"], "amount": 100_00}

    for extra in ({"location": FAR}, {}, {"ble_ids": ["0" * 16]},
                  {"location": {**CLOSE, "accuracy": 500}}):
        r = client.post("/transfers", json={**base, **extra, "idempotency_key": key()}, headers=buyer)
        assert r.status_code == 403 and r.json()["detail"]["code"] == "not_nearby", extra


def test_self_transfer_and_unknown_recipient(client):
    me = auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=me).json()
    body = bt_body(beacon)
    assert client.post("/transfers", json=body, headers=me).status_code == 400
    body["public_id"] = "f" * 16
    assert client.post("/transfers", json=body, headers=me).status_code == 404


def test_insufficient_funds(client):
    seller, buyer = auth(client, DANIYAR), auth(client, MERCHANT)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, MERCHANT["balance"] + 1), headers=buyer)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "insufficient_funds"
    assert balance(client, buyer) == MERCHANT["balance"]


def test_repeat_with_same_key_charges_once(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": 1_000_00, "idempotency_key": key()}
    first = client.post("/transfers", json=body, headers=buyer).json()
    second = client.post("/transfers", json=body, headers=buyer).json()
    assert first["id"] == second["id"]
    assert balance(client, buyer) == AIGERIM["balance"] - 1_000_00

    changed = client.post("/transfers", json={**body, "amount": 2_000_00}, headers=buyer)
    assert changed.status_code == 409 and changed.json()["detail"]["code"] == "idempotency_conflict"


def test_beacon_expires_and_can_be_switched_off(client, monkeypatch):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": main.MIN_AMOUNT, "idempotency_key": key()}

    real_clock = nearby.clock
    now = real_clock()
    monkeypatch.setattr(nearby, "clock", lambda: now + nearby.BEACON_TTL + 1)
    assert client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"] == []
    assert client.post("/transfers", json=body, headers=buyer).status_code == 404
    monkeypatch.setattr(nearby, "clock", real_clock)

    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)
    client.delete("/nearby/beacon", headers=seller)
    assert client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"] == []


# --- WebSocket ---

def test_history_and_realtime_notification(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()

    with client.websocket_connect(ws_url(client, seller)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": 700_00,
                "idempotency_key": key(), "note": "алма"}
        assert client.post("/transfers", json=body, headers=buyer).status_code == 200
        event = sock.receive_json()
    assert event["type"] == "transfer_received" and event["amount"] == 700_00
    assert event["sender"] == "Айгерим К." and event["balance"] == MERCHANT["balance"] + 700_00

    out = client.get("/transfers", headers=buyer).json()["items"][0]
    assert out["direction"] == "out" and out["counterparty"] == MERCHANT["business_name"]
    incoming = client.get("/transfers", headers=seller).json()["items"][0]
    assert incoming["direction"] == "in" and incoming["counterparty"] == "Айгерим К."


def test_websocket_refuses_before_accepting(client):
    for url in ("/ws", "/ws?ticket=nope"):
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect(url):
                pass
    assert client.post("/ws/ticket").status_code == 401


def test_websocket_ticket_is_single_use_and_expires(client, monkeypatch):
    seller = auth(client, MERCHANT)
    url = ws_url(client, seller)
    with client.websocket_connect(url) as sock:
        assert sock.receive_json() == {"type": "ready"}
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(url):
            pass

    url = ws_url(client, seller)
    real = main.time.monotonic
    monkeypatch.setattr(main.time, "monotonic", lambda: real() + main.TICKET_TTL + 1)
    with pytest.raises(WebSocketDisconnect):
        with client.websocket_connect(url):
            pass


def test_websocket_keeps_few_connections_per_user(client):
    seller = auth(client, MERCHANT)
    with ExitStack() as stack:
        socks = [stack.enter_context(client.websocket_connect(ws_url(client, seller)))
                 for _ in range(main.Hub.MAX_PER_USER + 1)]
        for s in socks:
            assert s.receive_json() == {"type": "ready"}
        with pytest.raises(WebSocketDisconnect):
            socks[0].receive_json()


# --- вход ---

def test_parallel_login_attempts_do_not_bypass_limit(client, monkeypatch):
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 20_000)  # проверка PIN длится заметное время, как в жизни

    def attempt(i):
        return client.post("/auth/login", json={"phone": AIGERIM["phone"], "pin": f"{9000 + i}"}).status_code

    with ThreadPoolExecutor(20) as pool:
        codes = list(pool.map(attempt, range(40)))
    assert codes.count(401) == main.LOGIN_ATTEMPTS
    assert codes.count(429) == 40 - main.LOGIN_ATTEMPTS


def test_login_daily_limit_and_retry_after(client, monkeypatch):
    bad = {"phone": DANIYAR["phone"], "pin": "9999"}
    real = guard.clock
    shift = [0.0]
    monkeypatch.setattr(guard, "clock", lambda: real() + shift[0])
    for round_ in range(3):
        for _ in range(main.LOGIN_ATTEMPTS):
            assert client.post("/auth/login", json=bad).status_code == 401
        r = client.post("/auth/login", json=bad)
        wait = r.json()["detail"]["retry_after"]
        assert r.status_code == 429 and r.headers["retry-after"] == str(wait)
        assert (0 < wait <= 301) if round_ < 2 else (wait > 23 * 3600), (round_, wait)
        shift[0] += 301
    # 15 неудач за сутки: короткое окно прошло, но вход всё равно закрыт
    assert client.post("/auth/login", json=bad).status_code == 429


def test_successful_login_clears_short_window(client):
    bad = {"phone": DANIYAR["phone"], "pin": "9999"}
    for _ in range(main.LOGIN_ATTEMPTS - 1):
        assert client.post("/auth/login", json=bad).status_code == 401
    auth(client, DANIYAR)
    for _ in range(main.LOGIN_ATTEMPTS):
        assert client.post("/auth/login", json=bad).status_code == 401


def test_login_limit_by_client_address(client, monkeypatch):
    monkeypatch.setattr(main, "IP_HEADER", "x-real-ip")
    monkeypatch.setattr(main, "_login_ip", guard.Window(3, 600))
    for i in range(3):
        r = client.post("/auth/login", json={"phone": f"+7700000000{i}", "pin": "1111"},
                        headers={"X-Real-IP": "203.0.113.7"})
        assert r.status_code == 401
    other = {"phone": "+77000000009", "pin": "1111"}
    assert client.post("/auth/login", json=other, headers={"X-Real-IP": "203.0.113.7"}).status_code == 429
    assert client.post("/auth/login", json=other, headers={"X-Real-IP": "203.0.113.8"}).status_code == 401


def test_login_memory_is_bounded():
    w = guard.Window(5, 300, max_keys=100)
    for i in range(1000):
        w.take(f"+7{i:010d}")
    assert len(w._keys) == 100


# --- GPS ---

def test_teleported_location_is_ignored(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    # Покупатель «был» в Астане, а через секунду заявляет, что стоит у продавца в Таразе.
    r = client.post("/nearby/discover", json={"location": ASTANA}, headers=buyer).json()
    assert r["gps"] == "ok" and r["people"] == []
    r = client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()
    assert r["gps"] == "ignored" and r["people"] == []
    body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": main.MIN_AMOUNT, "idempotency_key": key()}
    assert client.post("/transfers", json=body, headers=buyer).json()["detail"]["code"] == "not_nearby"
    # Bluetooth координат не требует и продолжает работать.
    r = client.post("/nearby/discover", json={"location": CLOSE, "ble_ids": [beacon["ble_id"]]}, headers=buyer).json()
    assert [p["method"] for p in r["people"]] == ["bluetooth"]


def test_teleported_beacon_is_not_visible_by_gps(client):
    fake, buyer = auth(client, DANIYAR), auth(client, AIGERIM)
    assert client.post("/nearby/beacon", json={"location": ASTANA}, headers=fake).json()["gps"] == "ok"
    assert client.post("/nearby/beacon", json={"location": HERE}, headers=fake).json()["gps"] == "ignored"
    assert client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"] == []


def test_walking_is_fine_and_relogin_does_not_reset(client, monkeypatch):
    buyer = auth(client, AIGERIM)
    real = nearby.clock
    assert client.post("/nearby/discover", json={"location": HERE}, headers=buyer).json()["gps"] == "ok"
    monkeypatch.setattr(nearby, "clock", lambda: real() + 60)
    assert client.post("/nearby/discover", json={"location": FAR}, headers=buyer).json()["gps"] == "ok"
    again = auth(client, AIGERIM)
    assert client.post("/nearby/discover", json={"location": ASTANA}, headers=again).json()["gps"] == "ignored"


def test_gps_reveals_limited_number_of_people(client, monkeypatch):
    monkeypatch.setattr(main, "_gps_people", guard.Distinct(1, 3600))
    a, b, buyer = auth(client, MERCHANT), auth(client, DANIYAR), auth(client, AIGERIM)
    client.post("/nearby/beacon", json={"location": HERE}, headers=a)
    client.post("/nearby/beacon", json={"location": HERE}, headers=b)
    for _ in range(3):
        people = client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"]
        assert len(people) == 1


def test_discover_rate_limit(client, monkeypatch):
    monkeypatch.setattr(main, "_discover_rate", guard.Window(3, 60))
    buyer = auth(client, AIGERIM)
    for _ in range(3):
        assert client.post("/nearby/discover", json={}, headers=buyer).status_code == 200
    r = client.post("/nearby/discover", json={}, headers=buyer)
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down" and "retry-after" in r.headers


# --- переводы ---

def test_minimum_amount(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, 1, note="привет"), headers=buyer)
    assert r.status_code == 422 and r.json()["detail"]["code"] == "amount_too_small"
    assert balance(client, buyer) == AIGERIM["balance"]


@pytest.mark.parametrize("note", [
    "верните на +7 701 000 00 01", "звоните 87010000001", "https://kaspi-bonus.top", "смотри www.x.kz",
    "пиши в t.me/scam", "zabiray.site/podarok",
])
def test_note_with_links_or_phones_is_refused(client, note):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, note=note), headers=buyer)
    assert r.status_code == 422 and r.json()["detail"]["code"] == "note_not_allowed"


@pytest.mark.parametrize("note", ["за 2 кг яблок", "Спасибо! 🍎", "долг за обед 12.11", "т.е. за вчера"])
def test_ordinary_notes_pass(client, note):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, note=note), headers=buyer)
    assert r.status_code == 200 and r.json()["note"] == note


def test_note_is_cleaned_of_invisible_characters(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r = client.post("/transfers", json=bt_body(beacon, note="за‮  яблоки\n​2 кг"), headers=buyer)
    assert r.status_code == 200 and r.json()["note"] == "за яблоки 2 кг"
    r = client.post("/transfers", json=bt_body(beacon, note="​ \t"), headers=buyer)
    assert r.status_code == 200 and r.json()["note"] is None


def test_same_recipient_rate_limit(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    for _ in range(3):
        assert client.post("/transfers", json=bt_body(beacon), headers=buyer).status_code == 200
    r = client.post("/transfers", json=bt_body(beacon), headers=buyer)
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down"
    assert balance(client, buyer) == AIGERIM["balance"] - 3 * main.MIN_AMOUNT


def test_daily_limits(client, monkeypatch):
    monkeypatch.setattr(main, "DAILY_LIMIT_GPS", 3_000_00)
    monkeypatch.setattr(main, "DAILY_LIMIT", 5_000_00)
    seller, buyer = auth(client, MERCHANT), auth(client, DANIYAR)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()
    gps = {"public_id": beacon["public_id"], "location": CLOSE}

    assert client.post("/transfers", json={**gps, "amount": 2_000_00, "idempotency_key": key()},
                       headers=buyer).status_code == 200
    r = client.post("/transfers", json={**gps, "amount": 2_000_00, "idempotency_key": key()}, headers=buyer)
    assert r.status_code == 403
    assert r.json()["detail"] == {"code": "daily_limit_exceeded", "limit": 3_000_00, "left": 1_000_00, "method": "gps"}

    # по Bluetooth действует только общий лимит
    assert client.post("/transfers", json=bt_body(beacon, 3_000_00), headers=buyer).status_code == 200
    guard.reset()
    r = client.post("/transfers", json=bt_body(beacon, 1_000_00), headers=buyer)
    assert r.status_code == 403 and r.json()["detail"]["method"] is None and r.json()["detail"]["left"] == 0


def test_daily_limit_window_is_24_hours(client, monkeypatch):
    monkeypatch.setattr(main, "DAILY_LIMIT", 1_000_00)
    seller, buyer = auth(client, MERCHANT), auth(client, DANIYAR)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    assert client.post("/transfers", json=bt_body(beacon, 1_000_00), headers=buyer).status_code == 200
    assert client.post("/transfers", json=bt_body(beacon), headers=buyer).status_code == 403
    with db.connect() as c:
        c.execute("UPDATE transfers SET created_at = created_at - ?", (db.DAY + 1,))
    assert client.post("/transfers", json=bt_body(beacon), headers=buyer).status_code == 200
