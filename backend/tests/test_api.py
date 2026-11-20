import uuid

import pytest
from fastapi.testclient import TestClient

from app import db, main, nearby

AIGERIM, DANIYAR, MERCHANT = db.DEMO_USERS
HERE = {"lat": 42.9000, "lon": 71.3667, "accuracy": 10}
CLOSE = {"lat": 42.9002, "lon": 71.3667, "accuracy": 10}     # ~22 м
FAR = {"lat": 42.9100, "lon": 71.3667, "accuracy": 10}       # ~1,1 км


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("QASYNDA_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("QASYNDA_SEED_DEMO", "1")
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 1000)
    nearby.reset()
    main._login_failures.clear()
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


def test_login_rejects_wrong_pin_and_throttles(client):
    bad = {"phone": AIGERIM["phone"], "pin": "9999"}
    for _ in range(main.LOGIN_ATTEMPTS):
        assert client.post("/auth/login", json=bad).status_code == 401
    assert client.post("/auth/login", json=bad).status_code == 429
    good = {"phone": AIGERIM["phone"], "pin": AIGERIM["pin"]}
    assert client.post("/auth/login", json=good).status_code == 429


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
    assert person["method"] == "gps" and person["distance_m"] == 20
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
    body = {"public_id": beacon["public_id"], "ble_ids": [beacon["ble_id"]],
            "amount": main.LIMIT_GPS + 1, "idempotency_key": key()}
    r = client.post("/transfers", json=body, headers=buyer)
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
    body = {"public_id": beacon["public_id"], "ble_ids": [beacon["ble_id"]], "amount": 100, "idempotency_key": key()}
    assert client.post("/transfers", json=body, headers=me).status_code == 400
    body["public_id"] = "f" * 16
    assert client.post("/transfers", json=body, headers=me).status_code == 404


def test_insufficient_funds(client):
    seller, buyer = auth(client, DANIYAR), auth(client, MERCHANT)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    body = {"public_id": beacon["public_id"], "ble_ids": [beacon["ble_id"]],
            "amount": MERCHANT["balance"] + 1, "idempotency_key": key()}
    r = client.post("/transfers", json=body, headers=buyer)
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
    body = {"public_id": beacon["public_id"], "location": CLOSE, "amount": 100, "idempotency_key": key()}

    real_clock = nearby.clock
    now = real_clock()
    monkeypatch.setattr(nearby, "clock", lambda: now + nearby.BEACON_TTL + 1)
    assert client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"] == []
    assert client.post("/transfers", json=body, headers=buyer).status_code == 404
    monkeypatch.setattr(nearby, "clock", real_clock)

    client.post("/nearby/beacon", json={"location": HERE}, headers=seller)
    client.delete("/nearby/beacon", headers=seller)
    assert client.post("/nearby/discover", json={"location": CLOSE}, headers=buyer).json()["people"] == []


def test_history_and_realtime_notification(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={"location": HERE}, headers=seller).json()

    with client.websocket_connect("/ws") as sock:
        sock.send_json({"token": seller["Authorization"][7:]})
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


def test_websocket_rejects_bad_token(client):
    with client.websocket_connect("/ws") as sock:
        sock.send_json({"token": "nope"})
        with pytest.raises(Exception):
            sock.receive_json()
