"""Привязанные карты и учебная виртуальная карта."""
import glob
import os
import sqlite3
import time
from concurrent.futures import ThreadPoolExecutor

import pytest

from app import cards, db, guard, main
from test_api import AIGERIM, DANIYAR, auth, client  # noqa: F401

VISA = "4111 1111 1111 1111"
MASTERCARD = "5555555555554444"
MASTERCARD_2 = "2223003122003222"
UNIONPAY = "6200000000000005"


def future(years=3):
    t = time.gmtime()
    return f"{t.tm_mon:02d}/{(t.tm_year + years) % 100:02d}"


def add(client, headers, number=VISA, expiry=None, holder="Aigerim Kassymova"):
    return client.post("/cards", json={"number": number, "expiry": expiry or future(), "holder": holder},
                       headers=headers)


def luhn_numbers(n, prefix="4000"):
    """n разных номеров Visa с верной контрольной цифрой."""
    out = []
    i = 0
    while len(out) < n:
        head = f"{prefix}{i:011d}"
        out.append(next(head + d for d in "0123456789" if cards.luhn_ok(head + d)))
        i += 1
    return out


# --- проверки номера и срока ---

@pytest.mark.parametrize("number,ok", [
    ("4111111111111111", True), ("5555555555554444", True), ("79927398713", True),
    ("4111111111111112", False), ("1234567812345678", False), ("0000000000000001", False),
])
def test_luhn(number, ok):
    assert cards.luhn_ok(number) is ok


@pytest.mark.parametrize("number,brand", [
    ("4111111111111111", "visa"), ("5555555555554444", "mastercard"), ("2223003122003222", "mastercard"),
    ("2721000000000000", "other"), ("6200000000000005", "unionpay"), ("8100000000000000", "unionpay"),
    ("3530111333300000", "other"),
])
def test_brand_by_bin(number, brand):
    assert cards.brand(number) == brand


def test_expiry_lasts_until_end_of_month():
    now = time.mktime((2026, 11, 30, 23, 0, 0, 0, 0, 0))
    assert not cards.expired("11/26", now)
    assert not cards.expired("12/26", now)
    assert cards.expired("10/26", now)
    assert cards.expired("12/25", now)


def test_bad_number_and_expired_card_are_refused(client):
    me = auth(client, AIGERIM)
    r = add(client, me, number="4111 1111 1111 1112")
    assert r.status_code == 422 and r.json()["detail"]["code"] == "invalid_card_number"
    r = add(client, me, number="4111111")
    assert r.status_code == 422
    t = time.gmtime()
    last_month = f"{12 if t.tm_mon == 1 else t.tm_mon - 1:02d}/{(t.tm_year - (t.tm_mon == 1)) % 100:02d}"
    r = add(client, me, expiry=last_month)
    assert r.status_code == 422 and r.json()["detail"]["code"] == "card_expired"
    this_month = f"{t.tm_mon:02d}/{t.tm_year % 100:02d}"
    assert add(client, me, expiry=this_month).status_code == 200
    for bad in ("13/30", "1/30", "01-30"):
        assert add(client, me, number=MASTERCARD, expiry=bad).json()["detail"]["code"] == "invalid_request"
    # Отказ не повторяет присланный номер.
    assert "4111" not in add(client, me, number="4111 1111 1111 1112").text


def test_card_is_stored_without_full_number(client):
    me = auth(client, AIGERIM)
    r = add(client, me, holder="  aigerim   kassymova ")
    assert r.status_code == 200, r.text
    card = r.json()
    assert card["brand"] == "visa" and card["last4"] == "1111" and card["holder"] == "AIGERIM KASSYMOVA"
    assert card["is_primary"] is True
    assert set(card) == {"id", "brand", "last4", "expiry", "holder", "is_primary", "created_at"}

    with sqlite3.connect(os.environ["QASYNDA_DB"]) as c:
        columns = [r[1] for r in c.execute("PRAGMA table_info(cards)")]
        assert columns == ["id", "user_id", "brand", "last4", "expiry", "holder", "is_primary", "created_at"]
        dump = "\n".join(c.iterdump())
    pan = VISA.replace(" ", "")
    assert pan not in dump and pan[:12] not in dump and VISA not in dump
    # и в самих файлах базы, включая журнал WAL
    for path in glob.glob(os.environ["QASYNDA_DB"] + "*"):
        raw = open(path, "rb").read()
        assert pan.encode() not in raw and pan[6:].encode() not in raw, path


def test_list_primary_and_delete_only_own_cards(client):
    me, other = auth(client, AIGERIM), auth(client, DANIYAR)
    first = add(client, me).json()
    second = add(client, me, number=MASTERCARD).json()
    theirs = add(client, other, number=UNIONPAY).json()
    assert second["is_primary"] is False and theirs["is_primary"] is True

    items = client.get("/cards", headers=me).json()
    assert items["max"] == cards.MAX_CARDS
    assert [(c["brand"], c["is_primary"]) for c in items["items"]] == [("visa", True), ("mastercard", False)]

    # чужую карту не удалить и не сделать основной
    assert client.delete(f"/cards/{theirs['id']}", headers=me).json()["detail"]["code"] == "card_not_found"
    assert client.post(f"/cards/{theirs['id']}/primary", headers=me).status_code == 404
    assert [c["id"] for c in client.get("/cards", headers=other).json()["items"]] == [theirs["id"]]

    assert client.post(f"/cards/{second['id']}/primary", headers=me).json() == {"ok": True}
    assert [c["is_primary"] for c in client.get("/cards", headers=me).json()["items"]] == [False, True]
    # удалили основную — основной становится оставшаяся
    assert client.delete(f"/cards/{second['id']}", headers=me).status_code == 200
    assert [(c["id"], c["is_primary"]) for c in client.get("/cards", headers=me).json()["items"]] == [(first["id"], True)]
    assert client.delete(f"/cards/{second['id']}", headers=me).status_code == 404
    assert client.delete("/cards/not-an-id", headers=me).status_code == 422


def test_same_card_twice_and_card_limit(client, monkeypatch):
    monkeypatch.setattr(main, "_card_add_rate", guard.Window(100, 3600))
    me = auth(client, AIGERIM)
    assert add(client, me).status_code == 200
    r = add(client, me, number=VISA.replace(" ", ""))
    assert r.status_code == 409 and r.json()["detail"]["code"] == "card_exists"
    for number in luhn_numbers(cards.MAX_CARDS - 1):
        assert add(client, me, number=number).status_code == 200
    r = add(client, me, number=MASTERCARD)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "too_many_cards"
    assert len(client.get("/cards", headers=me).json()["items"]) == cards.MAX_CARDS


def test_parallel_adds_do_not_bypass_card_limit(client, monkeypatch):
    monkeypatch.setattr(main, "_card_add_rate", guard.Window(100, 3600))
    me = auth(client, AIGERIM)
    with ThreadPoolExecutor(10) as pool:
        codes = list(pool.map(lambda n: add(client, me, number=n).status_code, luhn_numbers(12)))
    assert codes.count(200) == cards.MAX_CARDS
    with db.connect() as c:
        assert c.execute("SELECT COUNT(*) FROM cards").fetchone()[0] == cards.MAX_CARDS
        assert c.execute("SELECT COUNT(*) FROM cards WHERE is_primary=1").fetchone()[0] == 1


def test_add_rate_limit_counts_only_added_cards(client, monkeypatch):
    monkeypatch.setattr(main, "_card_add_rate", guard.Window(2, 3600))
    me = auth(client, AIGERIM)
    for _ in range(5):
        assert add(client, me, number="4111111111111112").status_code == 422
    assert add(client, me).status_code == 200
    assert add(client, me, number=MASTERCARD).status_code == 200
    r = add(client, me, number=MASTERCARD_2)
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down"


def test_cards_need_unlocked_session(client):
    me = auth(client, AIGERIM)
    card = add(client, me).json()
    client.post("/auth/lock", headers=me)
    for method, path in [("get", "/cards"), ("post", "/cards"), ("delete", f"/cards/{card['id']}"),
                         ("post", f"/cards/{card['id']}/primary"), ("get", "/cards/virtual"),
                         ("get", "/cards/virtual/secret")]:
        kw = {"json": {"number": MASTERCARD, "expiry": future(), "holder": "A B"}} if (method, path) == ("post", "/cards") else {}
        r = getattr(client, method)(path, headers=me, **kw)
        assert r.status_code == 403 and r.json()["detail"]["code"] == "locked", path
    assert client.get("/cards").status_code == 401


# --- виртуальная карта ---

def test_virtual_card_is_fake_valid_and_stable(client):
    me, other = auth(client, AIGERIM), auth(client, DANIYAR)
    masked = client.get("/cards/virtual", headers=me).json()
    assert masked == {"brand": "qasynda", "last4": AIGERIM["card_last4"], "holder": AIGERIM["full_name"], "virtual": True}

    r = client.get("/cards/virtual/secret", headers=me)
    assert r.status_code == 200 and r.headers["cache-control"] == "no-store"
    secret = r.json()
    number = secret["number"]
    assert len(number) == 16 and number.startswith(cards.VIRTUAL_PREFIX) and cards.luhn_ok(number)
    assert number.endswith(AIGERIM["card_last4"]) and len(secret["cvv"]) == 3
    assert not cards.expired(secret["expiry"])
    assert client.get("/cards/virtual/secret", headers=me).json() == secret
    theirs = client.get("/cards/virtual/secret", headers=other).json()
    assert theirs["number"] != number and cards.luhn_ok(theirs["number"])
    # учебную карту нельзя привязать как настоящую: начинается с 0, у банков таких номеров нет
    assert cards.brand(number) == "other"


def test_virtual_card_secret_is_rate_limited(client):
    me = auth(client, AIGERIM)
    for _ in range(10):
        assert client.get("/cards/virtual/secret", headers=me).status_code == 200
    r = client.get("/cards/virtual/secret", headers=me)
    assert r.status_code == 429 and "retry-after" in r.headers
    assert client.get("/cards/virtual", headers=me).status_code == 200
