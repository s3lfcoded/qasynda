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
    monkeypatch.setenv("QASYNDA_SMS_DEMO", "1")
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 1000)
    nearby.reset()
    guard.reset()
    main._tickets.clear()
    main._challenges.clear()
    with TestClient(main.app) as c:
        yield c


def device(user, n=0):
    return f"test-device-{user['phone'][1:]}-{n:010d}"


def login(client, user, pin=None, secret=None, **kw):
    return client.post("/auth/login", json={"phone": user["phone"], "pin": pin or user["pin"],
                                            "device_secret": secret or device(user), "device_name": "Тест"}, **kw)


def auth(client, user, secret=None):
    """Вход: с нового устройства — через учебное SMS, с привязанного — сразу."""
    r = login(client, user, secret=secret)
    assert r.status_code == 200, r.text
    data = r.json()
    if data.get("sms_required"):
        r = client.post("/auth/confirm", json={"challenge": data["challenge"], "code": data["demo_code"],
                                               "pin": user["pin"]})
        assert r.status_code == 200, r.text
        data = r.json()
    return {"Authorization": f"Bearer {data['token']}"}


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
    auth(client, AIGERIM)
    for _ in range(main.LOGIN_ATTEMPTS):
        assert login(client, AIGERIM, pin="9999").status_code == 401
    assert login(client, AIGERIM, pin="9999").status_code == 429
    assert login(client, AIGERIM).status_code == 429


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
    assert person["method"] == "gps" and person["proximity"] == "near"
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
    auth(client, AIGERIM)
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 20_000)  # проверка PIN длится заметное время, как в жизни

    def attempt(i):
        return login(client, AIGERIM, pin=f"{9000 + i}").status_code

    with ThreadPoolExecutor(20) as pool:
        codes = list(pool.map(attempt, range(40)))
    assert codes.count(401) == main.LOGIN_ATTEMPTS
    assert codes.count(429) == 40 - main.LOGIN_ATTEMPTS


def test_login_daily_limit_and_retry_after(client, monkeypatch):
    auth(client, DANIYAR)
    real = guard.clock
    shift = [0.0]
    monkeypatch.setattr(guard, "clock", lambda: real() + shift[0])
    for round_ in range(3):
        for _ in range(main.LOGIN_ATTEMPTS):
            assert login(client, DANIYAR, pin="9999").status_code == 401
        r = login(client, DANIYAR, pin="9999")
        wait = r.json()["detail"]["retry_after"]
        assert r.status_code == 429 and r.headers["retry-after"] == str(wait)
        assert (0 < wait <= 301) if round_ < 2 else (wait > 23 * 3600), (round_, wait)
        shift[0] += 301
    # 15 неудач за сутки: короткое окно прошло, но вход всё равно закрыт
    assert login(client, DANIYAR, pin="9999").status_code == 429


def test_successful_login_clears_short_window(client):
    auth(client, DANIYAR)
    for _ in range(main.LOGIN_ATTEMPTS - 1):
        assert login(client, DANIYAR, pin="9999").status_code == 401
    auth(client, DANIYAR)
    for _ in range(main.LOGIN_ATTEMPTS):
        assert login(client, DANIYAR, pin="9999").status_code == 401


# --- привязка устройства и SMS ---

def confirm(client, pending, pin, code=None):
    return client.post("/auth/confirm", json={"challenge": pending["challenge"],
                                              "code": code or pending["demo_code"], "pin": pin})


def test_new_device_needs_sms_and_pin_is_not_checked_before_it(client, monkeypatch):
    sent = []
    monkeypatch.setattr(main.sms, "send", lambda phone, text: sent.append(phone))
    right = login(client, AIGERIM).json()
    wrong = login(client, AIGERIM, pin="9999", secret=device(AIGERIM, 1)).json()
    nobody = client.post("/auth/login", json={"phone": "+77000000000", "pin": "1111",
                                              "device_secret": device(AIGERIM, 2)}).json()
    # Верный PIN, неверный PIN и несуществующий номер выглядят одинаково: по ответу ничего не понять.
    for reply in (right, wrong, nobody):
        assert set(reply) == {"sms_required", "challenge", "ttl", "demo_code"}
    assert sent == [AIGERIM["phone"], AIGERIM["phone"]]

    r = confirm(client, nobody, "1111")
    assert r.status_code == 401 and r.json()["detail"]["code"] == "invalid_credentials"
    r = confirm(client, right, "9999")
    assert r.status_code == 401 and r.json()["detail"]["code"] == "invalid_credentials"
    r = confirm(client, right, AIGERIM["pin"])
    assert r.status_code == 200 and "token" in r.json()
    # тем же кодом второй раз не войти, а с привязанного телефона SMS больше не нужно
    r = confirm(client, right, AIGERIM["pin"])
    assert r.status_code == 401 and r.json()["detail"]["code"] == "challenge_expired"
    assert "token" in login(client, AIGERIM).json()


def test_sms_code_attempts_are_limited(client):
    pending = login(client, AIGERIM).json()
    wrong = "000000" if pending["demo_code"] != "000000" else "111111"
    for _ in range(main.SMS_ATTEMPTS - 1):
        assert confirm(client, pending, AIGERIM["pin"], wrong).json()["detail"]["code"] == "invalid_credentials"
    assert confirm(client, pending, AIGERIM["pin"], wrong).json()["detail"]["code"] == "challenge_expired"
    assert confirm(client, pending, AIGERIM["pin"]).json()["detail"]["code"] == "challenge_expired"


def test_sms_code_expires(client, monkeypatch):
    pending = login(client, AIGERIM).json()
    real = main.time.monotonic
    monkeypatch.setattr(main.time, "monotonic", lambda: real() + main.SMS_TTL + 1)
    assert confirm(client, pending, AIGERIM["pin"]).json()["detail"]["code"] == "challenge_expired"


def test_sms_are_limited_per_phone_and_address(client, monkeypatch):
    for i in range(3):
        assert login(client, AIGERIM, secret=device(AIGERIM, i)).status_code == 200
    r = login(client, AIGERIM, secret=device(AIGERIM, 9))
    assert r.status_code == 429 and r.json()["detail"]["code"] == "too_many_sms"

    monkeypatch.setattr(main, "IP_HEADER", "x-real-ip")
    monkeypatch.setattr(main, "_sms_ip", guard.Window(2, 3600))
    ip = {"X-Real-IP": "203.0.113.7"}
    assert login(client, DANIYAR, headers=ip).status_code == 200
    assert login(client, MERCHANT, headers=ip).status_code == 200
    assert login(client, DANIYAR, secret=device(DANIYAR, 5), headers=ip).status_code == 429
    assert login(client, DANIYAR, secret=device(DANIYAR, 5), headers={"X-Real-IP": "203.0.113.8"}).status_code == 200


def test_attempts_from_new_device_do_not_lock_owner(client):
    auth(client, AIGERIM)
    pending = login(client, AIGERIM, secret=device(AIGERIM, 7)).json()
    for _ in range(main.SMS_ATTEMPTS):
        confirm(client, pending, "9999", "123456")
    assert "token" in login(client, AIGERIM).json()


def test_owner_is_told_about_new_device(client):
    owner = auth(client, MERCHANT)
    with client.websocket_connect(ws_url(client, owner)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        auth(client, MERCHANT, secret=device(MERCHANT, 1))
        assert sock.receive_json() == {"type": "new_device", "name": "Тест"}


# --- устройства ---

def test_devices_list_and_kick(client):
    mine = auth(client, AIGERIM)
    thief = auth(client, AIGERIM, secret=device(AIGERIM, 1))
    items = client.get("/devices", headers=mine).json()["items"]
    assert len(items) == 2 and sum(d["current"] for d in items) == 1
    other = next(d for d in items if not d["current"])

    with client.websocket_connect(ws_url(client, thief)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        assert client.delete(f"/devices/{other['id']}", headers=mine).status_code == 200
        with pytest.raises(WebSocketDisconnect):
            sock.receive_json()
    assert client.get("/me", headers=thief).status_code == 401
    assert client.get("/me", headers=mine).status_code == 200
    # с отвязанного телефона снова нужен код из SMS
    assert login(client, AIGERIM, secret=device(AIGERIM, 1)).json().get("sms_required") is True
    assert client.delete(f"/devices/{other['id']}", headers=mine).status_code == 404


def test_cannot_kick_someone_elses_device(client):
    mine, stranger = auth(client, AIGERIM), auth(client, DANIYAR)
    their = client.get("/devices", headers=stranger).json()["items"][0]["id"]
    assert client.delete(f"/devices/{their}", headers=mine).status_code == 404
    assert client.get("/me", headers=stranger).status_code == 200


def test_logout_others(client):
    mine = auth(client, AIGERIM)
    others = [auth(client, AIGERIM, secret=device(AIGERIM, i)) for i in (1, 2)]
    assert client.post("/devices/logout-others", headers=mine).json() == {"removed": 2}
    assert [client.get("/me", headers=h).status_code for h in others] == [401, 401]
    assert len(client.get("/devices", headers=mine).json()["items"]) == 1


# --- разблокировка приложения кодом ---

def test_unlock_checks_pin_and_closes_session_after_too_many_tries(client):
    me = auth(client, AIGERIM)
    assert client.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=me).json()["ok"] is True
    for _ in range(main.LOGIN_ATTEMPTS):
        r = client.post("/auth/unlock", json={"pin": "9999"}, headers=me)
        assert r.status_code == 403 and r.json()["detail"]["code"] == "invalid_pin"
    assert client.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=me).status_code == 401
    assert client.get("/me", headers=me).status_code == 401
    assert "token" in login(client, AIGERIM).json()


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


def test_bluetooth_id_rotates_and_old_one_works_briefly(client, monkeypatch):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    first = client.post("/nearby/beacon", json={}, headers=seller).json()
    assert client.post("/nearby/beacon", json={}, headers=seller).json()["ble_id"] == first["ble_id"]

    real = nearby.clock
    monkeypatch.setattr(nearby, "clock", lambda: real() + nearby.BLE_ROTATE + 1)
    second = client.post("/nearby/beacon", json={}, headers=seller).json()
    assert second["ble_id"] != first["ble_id"] and second["public_id"] != first["public_id"]
    people = client.post("/nearby/discover", json={"ble_ids": [first["ble_id"]]}, headers=buyer).json()["people"]
    assert [p["method"] for p in people] == ["bluetooth"]
    assert client.post("/transfers", json=bt_body(first), headers=buyer).status_code == 200

    monkeypatch.setattr(nearby, "clock", lambda: real() + nearby.BLE_ROTATE + nearby.BLE_GRACE + 2)
    client.post("/nearby/beacon", json={}, headers=seller)
    assert client.post("/nearby/discover", json={"ble_ids": [first["ble_id"]]}, headers=buyer).json()["people"] == []
    assert client.post("/transfers", json=bt_body(first), headers=buyer).json()["detail"]["code"] == "not_nearby"


def test_mocked_location_is_ignored(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)
    r = client.post("/nearby/discover", json={"location": {**CLOSE, "mocked": True}}, headers=buyer).json()
    assert r["gps"] == "ignored" and r["people"] == []
    mocked = client.post("/nearby/beacon", json={"location": {**HERE, "mocked": True}}, headers=seller).json()
    assert mocked["gps"] == "ignored"


# --- проверка третьего агента: окно разблокировки, биометрия, адрес, метки ---

def test_locked_session_cannot_move_money_or_see_balance(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    assert client.post("/auth/lock", headers=buyer).json() == {"ok": True}
    for method, path, body in [("get", "/me", None), ("get", "/transfers", None), ("get", "/devices", None),
                               ("post", "/transfers", bt_body(beacon)), ("post", "/nearby/discover", {}),
                               ("post", "/nearby/beacon", {}), ("post", "/devices/logout-others", None),
                               ("post", "/auth/bio-key", None)]:
        r = getattr(client, method)(path, headers=buyer, **({"json": body} if body is not None else {}))
        assert r.status_code == 403 and r.json()["detail"]["code"] == "locked", path
    assert client.post("/ws/ticket", headers=buyer).status_code == 200
    assert client.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=buyer).status_code == 200
    assert client.post("/transfers", json=bt_body(beacon), headers=buyer).status_code == 200


def test_unlock_window_expires_and_slides(client, monkeypatch):
    me = auth(client, AIGERIM)
    real = db.time.time
    monkeypatch.setattr(main.time, "time", lambda: real() + db.UNLOCK_TTL - 10)
    assert client.get("/me", headers=me).status_code == 200      # действие продлевает окно
    monkeypatch.setattr(main.time, "time", lambda: real() + 2 * db.UNLOCK_TTL - 30)
    assert client.get("/me", headers=me).status_code == 200
    monkeypatch.setattr(main.time, "time", lambda: real() + 4 * db.UNLOCK_TTL)
    r = client.get("/me", headers=me)
    assert r.status_code == 403 and r.json()["detail"]["code"] == "locked"


def test_biometric_secret_unlocks_only_its_device(client):
    mine = auth(client, AIGERIM)
    other = auth(client, AIGERIM, secret=device(AIGERIM, 1))
    secret = client.post("/auth/bio-key", headers=mine).json()["bio_secret"]
    client.post("/auth/lock", headers=mine)
    client.post("/auth/lock", headers=other)
    assert client.post("/auth/unlock", json={"bio_secret": secret}, headers=other).json()["detail"]["code"] == "invalid_bio"
    assert client.post("/auth/unlock", json={"bio_secret": secret}, headers=mine).status_code == 200
    # новый ключ заменяет старый, отключение биометрии стирает его
    fresh = client.post("/auth/bio-key", headers=mine).json()["bio_secret"]
    client.post("/auth/lock", headers=mine)
    assert client.post("/auth/unlock", json={"bio_secret": secret}, headers=mine).status_code == 403
    assert client.post("/auth/unlock", json={"bio_secret": fresh}, headers=mine).status_code == 200
    # отключить биометрию можно только из разблокированной сессии: вор не выключит её владельцу
    client.post("/auth/lock", headers=mine)
    assert client.delete("/auth/bio-key", headers=mine).status_code == 403
    client.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=mine)
    assert client.delete("/auth/bio-key", headers=mine).status_code == 200
    client.post("/auth/lock", headers=mine)
    assert client.post("/auth/unlock", json={"bio_secret": fresh}, headers=mine).status_code == 403


def test_unlock_needs_exactly_one_proof(client):
    me = auth(client, AIGERIM)
    assert client.post("/auth/unlock", json={}, headers=me).json()["detail"]["code"] == "pin_or_bio_required"
    both = {"pin": AIGERIM["pin"], "bio_secret": "x" * 40}
    assert client.post("/auth/unlock", json=both, headers=me).json()["detail"]["code"] == "pin_or_bio_required"


def test_wrong_biometric_secrets_count_towards_session_revocation(client):
    me = auth(client, AIGERIM)
    for _ in range(main.LOGIN_ATTEMPTS):
        assert client.post("/auth/unlock", json={"bio_secret": "y" * 43}, headers=me).status_code == 403
    assert client.post("/auth/unlock", json={"pin": AIGERIM["pin"]}, headers=me).status_code == 401


def test_without_ip_header_one_client_cannot_exhaust_a_shared_limit(client):
    # За прокси хостинга у всех один адрес соединения: раньше 20 запросов закрывали SMS всем на час,
    # а 50 неудачных подтверждений закрывали вход по PIN всем на 10 минут.
    auth(client, DANIYAR)
    pending = []
    for i in range(25):
        r = client.post("/auth/login", json={"phone": f"+7700{i:07d}", "pin": "1111", "device_secret": device(AIGERIM, i)})
        assert r.status_code == 200, i
        pending.append(r.json())
    for p in pending:
        for _ in range(3):
            confirm(client, p, "1111", "123456")
    assert login(client, MERCHANT).json().get("sms_required") is True
    assert "token" in login(client, DANIYAR).json()


def test_flood_of_bluetooth_ids_does_not_break_payment(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    junk = [f"{i:016x}" for i in range(1, 200)]
    people = client.post("/nearby/discover", json={"ble_ids": [beacon["ble_id"]] + junk}, headers=buyer).json()["people"]
    assert [p["method"] for p in people] == ["bluetooth"]
    body = {**bt_body(beacon), "ble_ids": [beacon["ble_id"]] + junk}
    assert client.post("/transfers", json=body, headers=buyer).status_code == 200


def test_public_id_rotates_with_bluetooth_id_and_old_one_still_pays(client, monkeypatch):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    first = client.post("/nearby/beacon", json={}, headers=seller).json()
    real = nearby.clock
    monkeypatch.setattr(nearby, "clock", lambda: real() + nearby.BLE_ROTATE + 1)
    second = client.post("/nearby/beacon", json={}, headers=seller).json()
    assert second["public_id"] != first["public_id"]
    people = client.post("/nearby/discover", json={"ble_ids": [second["ble_id"]]}, headers=buyer).json()["people"]
    assert [p["public_id"] for p in people] == [second["public_id"]]
    # отправитель ещё вводил сумму по старому public_id
    assert client.post("/transfers", json={**bt_body(second), "public_id": first["public_id"]}, headers=buyer).status_code == 200
    monkeypatch.setattr(nearby, "clock", lambda: real() + nearby.BLE_ROTATE + nearby.PUBLIC_GRACE + 5)
    client.post("/nearby/beacon", json={}, headers=seller)
    r = client.post("/transfers", json={**bt_body(second), "public_id": first["public_id"]}, headers=buyer)
    assert r.status_code == 404


def test_sms_code_is_never_logged(client, caplog):
    import logging
    caplog.set_level(logging.DEBUG)
    code = login(client, AIGERIM).json()["demo_code"]
    assert code not in caplog.text
