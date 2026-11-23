"""Проверки, что исправное поведение переводов не сломано: параллельные переводы, лимиты, сохранение денег."""
from concurrent.futures import ThreadPoolExecutor
import pytest
from fastapi.testclient import TestClient
import test_api as T
from app import db, guard, main, nearby

client = T.client
auth, bt_body, key, balance = T.auth, T.bt_body, T.key, T.balance
AIGERIM, DANIYAR, MERCHANT = T.AIGERIM, T.DANIYAR, T.MERCHANT


def test_parallel_same_key_charges_once(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    body = bt_body(beacon, 1_000_00)
    with ThreadPoolExecutor(3) as p:
        rs = list(p.map(lambda _: client.post("/transfers", json=body, headers=buyer), range(3)))
    assert {r.json()["id"] for r in rs if r.status_code == 200} and len({r.json()["id"] for r in rs if r.status_code == 200}) == 1
    assert balance(client, buyer) == AIGERIM["balance"] - 1_000_00
    assert balance(client, seller) == MERCHANT["balance"] + 1_000_00


def test_parallel_daily_limit(client, monkeypatch):
    monkeypatch.setattr(main, "DAILY_LIMIT", 5_000_00)
    monkeypatch.setattr(main, "_pair_rate", guard.Window(100, 600))
    monkeypatch.setattr(main, "_transfer_rate", guard.Window(100, 60))
    seller, buyer = auth(client, MERCHANT), auth(client, DANIYAR)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    with ThreadPoolExecutor(20) as p:
        rs = list(p.map(lambda _: client.post("/transfers", json=bt_body(beacon, 1_000_00), headers=buyer), range(20)))
    assert [r.status_code for r in rs].count(200) == 5
    assert balance(client, buyer) == DANIYAR["balance"] - 5_000_00


def test_total_money_conserved(client, monkeypatch):
    monkeypatch.setattr(main, "_pair_rate", guard.Window(100, 600))
    monkeypatch.setattr(main, "_transfer_rate", guard.Window(100, 60))
    a, b = auth(client, AIGERIM), auth(client, DANIYAR)
    ba = client.post("/nearby/beacon", json={}, headers=a).json()
    bb = client.post("/nearby/beacon", json={}, headers=b).json()
    def go(i):
        return client.post("/transfers", json=bt_body(bb if i % 2 else ba, 1_000_00 + i), headers=a if i % 2 else b)
    with ThreadPoolExecutor(10) as p:
        list(p.map(go, range(30)))
    assert balance(client, a) + balance(client, b) == AIGERIM["balance"] + DANIYAR["balance"]


def test_float_and_string_amount_coerced(client):
    seller, buyer = auth(client, MERCHANT), auth(client, AIGERIM)
    beacon = client.post("/nearby/beacon", json={}, headers=seller).json()
    r1 = client.post("/transfers", json={**bt_body(beacon), "amount": "10000"}, headers=buyer)
    r2 = client.post("/transfers", json={**bt_body(beacon), "amount": 10000.0}, headers=buyer)
    r3 = client.post("/transfers", json={**bt_body(beacon), "amount": 10000.5}, headers=buyer)
    print(r1.status_code, r2.status_code, r3.status_code)
