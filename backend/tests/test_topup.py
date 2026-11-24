"""Учебное пополнение баланса с привязанной карты."""
from concurrent.futures import ThreadPoolExecutor

from app import guard, main
from test_api import AIGERIM, DANIYAR, auth, balance, client  # noqa: F401
from test_cards import MASTERCARD, add


def topup(client, headers, card, amount):
    return client.post("/topup", json={"card_id": card["id"], "amount": amount}, headers=headers)


def test_topup_raises_balance_and_shows_in_history(client):
    me = auth(client, AIGERIM)
    card = add(client, me).json()
    r = topup(client, me, card, 25_000_00)
    assert r.status_code == 200, r.text
    reply = r.json()
    assert set(reply) == {"balance", "id", "amount"}
    assert reply["amount"] == 25_000_00 and reply["balance"] == AIGERIM["balance"] + 25_000_00
    assert balance(client, me) == reply["balance"]

    item = client.get("/transfers", headers=me).json()["items"][0]
    assert item == {"id": reply["id"], "direction": "in", "counterparty": "Пополнение с Visa •• 1111",
                    "is_merchant": False, "amount": 25_000_00, "method": "topup", "note": None,
                    "created_at": item["created_at"]}
    # карту удалили — запись в истории осталась
    assert client.delete(f"/cards/{card['id']}", headers=me).status_code == 200
    assert client.get("/transfers", headers=me).json()["items"][0]["counterparty"] == "Пополнение с Visa •• 1111"


def test_history_mixes_topups_and_transfers_newest_first(client):
    me = auth(client, AIGERIM)
    seller = auth(client, DANIYAR)
    mc = add(client, me, number=MASTERCARD).json()
    topup(client, me, mc, 1_000_00)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    body = {"public_id": beacon["public_id"], "ble_ids": [beacon["ble_id"]], "amount": 500_00, "idempotency_key": "k" * 16}
    assert client.post("/transfers", json=body, headers=me).status_code == 200
    topup(client, me, mc, 2_000_00)
    items = client.get("/transfers", headers=me).json()["items"]
    assert [(i["method"], i["direction"], i["amount"]) for i in items] == [
        ("topup", "in", 2_000_00), ("bluetooth", "out", 500_00), ("topup", "in", 1_000_00)]
    assert items[0]["counterparty"] == "Пополнение с Mastercard •• 4444"
    assert len(client.get("/transfers?limit=2", headers=me).json()["items"]) == 2
    # пополнения видны только владельцу
    assert all(i["method"] != "topup" for i in client.get("/transfers", headers=seller).json()["items"])


def test_only_own_card(client):
    me, other = auth(client, AIGERIM), auth(client, DANIYAR)
    theirs = add(client, other, number=MASTERCARD).json()
    r = topup(client, me, theirs, 1_000_00)
    assert r.status_code == 404 and r.json()["detail"]["code"] == "card_not_found"
    assert topup(client, me, {"id": "0" * 16}, 1_000_00).json()["detail"]["code"] == "card_not_found"
    assert topup(client, me, {"id": "nope"}, 1_000_00).status_code == 422
    assert balance(client, me) == AIGERIM["balance"]
    assert balance(client, other) == DANIYAR["balance"]


def test_amount_bounds_and_daily_limit(client):
    me = auth(client, AIGERIM)
    card = add(client, me).json()
    r = topup(client, me, card, main.TOPUP_MIN - 1)
    assert r.status_code == 422 and r.json()["detail"] == {"code": "amount_too_small", "min": main.TOPUP_MIN}
    r = topup(client, me, card, main.TOPUP_MAX + 1)
    assert r.status_code == 422 and r.json()["detail"] == {"code": "limit_exceeded", "limit": main.TOPUP_MAX}
    assert topup(client, me, card, main.TOPUP_MAX).status_code == 200
    assert topup(client, me, card, 400_000_00).status_code == 200
    r = topup(client, me, card, 200_000_00)
    assert r.status_code == 403
    assert r.json()["detail"] == {"code": "topup_limit_exceeded", "limit": main.TOPUP_DAILY, "left": 100_000_00}
    assert topup(client, me, card, 100_000_00).status_code == 200
    assert topup(client, me, card, main.TOPUP_MIN).json()["detail"]["left"] == 0
    assert balance(client, me) == AIGERIM["balance"] + main.TOPUP_DAILY


def test_parallel_topups_do_not_bypass_daily_limit(client, monkeypatch):
    monkeypatch.setattr(main, "_topup_rate", guard.Window(100, 60))
    me = auth(client, AIGERIM)
    card = add(client, me).json()
    with ThreadPoolExecutor(8) as pool:
        codes = list(pool.map(lambda _: topup(client, me, card, 300_000_00).status_code, range(8)))
    assert codes.count(200) == 3 and codes.count(403) == 5
    assert balance(client, me) == AIGERIM["balance"] + 900_000_00


def test_topup_needs_unlocked_session(client):
    me = auth(client, AIGERIM)
    card = add(client, me).json()
    client.post("/auth/lock", headers=me)
    r = topup(client, me, card, 1_000_00)
    assert r.status_code == 403 and r.json()["detail"]["code"] == "locked"
    assert client.post("/topup", json={"card_id": card["id"], "amount": 1_000_00}).status_code == 401
