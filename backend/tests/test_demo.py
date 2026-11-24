"""Учебные боты «Кофейня Qasynda» и «Алия Бот» (только при QASYNDA_SEED_DEMO=1)."""
import pytest
from fastapi.testclient import TestClient

from app import db, demo, guard, main, nearby
from test_api import AIGERIM, DANIYAR, auth, balance, key, ws_url
from test_register import NEW, register, verified


def _reset(tmp_path, monkeypatch, seed):
    monkeypatch.setenv("QASYNDA_DB", str(tmp_path / "test.db"))
    monkeypatch.setenv("QASYNDA_SMS_DEMO", "1")
    if seed:
        monkeypatch.setenv("QASYNDA_SEED_DEMO", "1")
    else:
        monkeypatch.delenv("QASYNDA_SEED_DEMO", raising=False)
    monkeypatch.setattr(db, "PBKDF2_ROUNDS", 1000)
    nearby.reset()
    guard.reset()
    main._tickets.clear()
    main._challenges.clear()


@pytest.fixture
def bots_client(tmp_path, monkeypatch):
    _reset(tmp_path, monkeypatch, seed=True)
    # Алия возвращает деньги сразу, а не через 3 секунды в отдельном потоке.
    monkeypatch.setattr(main, "later", lambda delay, action: action())
    with TestClient(main.app) as c:
        yield c


@pytest.fixture
def plain_client(tmp_path, monkeypatch):
    _reset(tmp_path, monkeypatch, seed=False)
    with TestClient(main.app) as c:
        yield c


def find_bots(client, headers):
    people = client.post("/nearby/discover", json={}, headers=headers).json()["people"]
    return {p["name"]: p for p in people if p["method"] == "demo"}, people


def pay(client, headers, person, amount=main.MIN_AMOUNT, **extra):
    return client.post("/transfers", json={"public_id": person["public_id"], "amount": amount,
                                           "idempotency_key": key(), **extra}, headers=headers)


def test_bots_are_nearby_for_everyone_at_the_end(bots_client):
    me, seller = auth(bots_client, AIGERIM), auth(bots_client, DANIYAR)
    beacon = bots_client.post("/nearby/beacon", json={}, headers=seller).json()
    people = bots_client.post("/nearby/discover", json={"ble_ids": [beacon["ble_id"]]}, headers=me).json()["people"]
    assert [p["method"] for p in people] == ["bluetooth", "demo", "demo"]
    coffee, aliya = people[1], people[2]
    assert coffee == {"public_id": coffee["public_id"], "method": "demo", "proximity": "demo", "name": "Кофейня Qasynda",
                      "is_merchant": True, "business_name": "Кофейня Qasynda · бот", "limit": main.LIMIT_GPS}
    assert aliya["name"] == "Алия Бот" and aliya["is_merchant"] is False and aliya["business_name"] is None
    for bot in (coffee, aliya):
        assert len(bot["public_id"]) == 16 and int(bot["public_id"], 16) >= 0
    again, _ = find_bots(bots_client, seller)
    assert again["Кофейня Qasynda"]["public_id"] == coffee["public_id"]
    assert again["Алия Бот"]["public_id"] == aliya["public_id"]


def test_coffee_keeps_the_money(bots_client):
    me = auth(bots_client, AIGERIM)
    bots, _ = find_bots(bots_client, me)
    r = pay(bots_client, me, bots["Кофейня Qasynda"], 1_500_00)
    assert r.status_code == 200, r.text
    assert r.json()["method"] == "demo" and r.json()["recipient"]["name"] == "Кофейня Qasynda"
    assert balance(bots_client, me) == AIGERIM["balance"] - 1_500_00
    item = bots_client.get("/transfers", headers=me).json()["items"][0]
    assert (item["direction"], item["counterparty"], item["is_merchant"], item["method"]) == (
        "out", "Кофейня Qasynda · бот", True, "demo")


def test_aliya_sends_the_money_back(bots_client):
    me = auth(bots_client, AIGERIM)
    bots, _ = find_bots(bots_client, me)
    with bots_client.websocket_connect(ws_url(bots_client, me)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        assert pay(bots_client, me, bots["Алия Бот"], 3_000_00).status_code == 200
        event = sock.receive_json()
    assert event["type"] == "transfer_received" and event["amount"] == 3_000_00
    assert event["sender"] == "Алия Бот" and event["method"] == "demo"
    assert event["balance"] == AIGERIM["balance"]
    items = bots_client.get("/transfers", headers=me).json()["items"]
    assert [(i["direction"], i["counterparty"], i["amount"]) for i in items[:2]] == [
        ("in", "Алия Бот", 3_000_00), ("out", "Алия Бот", 3_000_00)]
    assert balance(bots_client, me) == AIGERIM["balance"]


def test_bot_transfers_keep_gps_limits(bots_client, monkeypatch):
    monkeypatch.setattr(main, "DAILY_LIMIT_GPS", 2_000_00)
    me = auth(bots_client, AIGERIM)
    bots, _ = find_bots(bots_client, me)
    coffee = bots["Кофейня Qasynda"]
    r = pay(bots_client, me, coffee, main.LIMIT_GPS + 1)
    assert r.status_code == 403 and r.json()["detail"] == {"code": "limit_exceeded", "limit": main.LIMIT_GPS, "method": "demo"}
    assert pay(bots_client, me, coffee, 1_500_00).status_code == 200
    r = pay(bots_client, me, coffee, 1_000_00)
    assert r.status_code == 403 and r.json()["detail"]["code"] == "daily_limit_exceeded"
    assert r.json()["detail"]["left"] == 500_00 and r.json()["detail"]["method"] == "gps"
    assert pay(bots_client, me, coffee, 1).json()["detail"]["code"] == "amount_too_small"


def test_bot_transfers_keep_rate_limits(bots_client):
    me = auth(bots_client, AIGERIM)
    bots, _ = find_bots(bots_client, me)
    for _ in range(3):
        assert pay(bots_client, me, bots["Кофейня Qasynda"]).status_code == 200
    r = pay(bots_client, me, bots["Кофейня Qasynda"])
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down"
    assert pay(bots_client, me, bots["Алия Бот"]).status_code == 200


def test_ask_aliya_for_money(bots_client):
    me = auth(bots_client, AIGERIM)
    with bots_client.websocket_connect(ws_url(bots_client, me)) as sock:
        assert sock.receive_json() == {"type": "ready"}
        r = bots_client.post("/demo/request", json={"amount": 5_000_00}, headers=me)
        assert r.status_code == 200, r.text
        event = sock.receive_json()
    assert set(r.json()) == {"id", "amount", "balance"} and r.json()["balance"] == AIGERIM["balance"] + 5_000_00
    assert event["sender"] == "Алия Бот" and event["id"] == r.json()["id"]
    item = bots_client.get("/transfers", headers=me).json()["items"][0]
    assert (item["direction"], item["counterparty"], item["method"]) == ("in", "Алия Бот", "demo")

    r = bots_client.post("/demo/request", json={"amount": main.DEMO_REQUEST_MAX + 1}, headers=me)
    assert r.status_code == 422 and r.json()["detail"] == {"code": "limit_exceeded", "limit": main.DEMO_REQUEST_MAX}
    assert bots_client.post("/demo/request", json={"amount": 99_99}, headers=me).json()["detail"]["code"] == "amount_too_small"
    for _ in range(4):
        assert bots_client.post("/demo/request", json={"amount": 100_00}, headers=me).status_code == 200
    r = bots_client.post("/demo/request", json={"amount": 100_00}, headers=me)
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down"


def test_bots_cannot_sign_in(bots_client):
    for phone in (demo.COFFEE, demo.ALIYA):
        r = bots_client.post("/auth/start", json={"phone": phone, "device_secret": "b" * 40})
        assert r.status_code == 422
    bot_ids = {b["id"] for b in db.bots()}
    assert len(bot_ids) == 2
    with db.connect() as c:
        assert c.execute(f"SELECT COUNT(*) FROM sessions WHERE user_id IN ({','.join('?' * 2)})",
                         tuple(bot_ids)).fetchone()[0] == 0


def test_no_bots_without_demo_seed(plain_client):
    pending, reply = verified(plain_client)
    assert reply == {"ok": True, "registered": False}
    headers = {"Authorization": f"Bearer {register(plain_client, pending).json()['token']}"}
    bots, people = find_bots(plain_client, headers)
    assert bots == {} and people == []
    assert db.bots() == []
    coffee_id = demo.public_id({"full_name": "Кофейня Qasynda"})
    r = pay(plain_client, headers, {"public_id": coffee_id})
    assert r.status_code == 404 and r.json()["detail"]["code"] == "recipient_not_available"
    r = plain_client.post("/demo/request", json={"amount": 100_00}, headers=headers)
    assert r.status_code == 404 and r.json()["detail"]["code"] == "not_found"
    # даже если боты остались в базе со старого запуска, без настройки их не видно
    db.seed_bots()
    assert find_bots(plain_client, headers) == ({}, [])
    assert NEW["phone"] == plain_client.get("/me", headers=headers).json()["phone"]
