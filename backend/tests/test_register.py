"""Регистрация нового номера после верного кода из SMS."""
import pytest

from app import cards, guard, main
from test_api import AIGERIM, auth, client, code, confirm, device, login, start  # noqa: F401

NEW = {"phone": "+77050000001", "pin": "2580", "full_name": "Ерлан Сейткали"}


def verified(client, user=NEW, secret=None, **kw):
    pending = start(client, user, secret=secret, **kw).json()
    assert pending["next"] == "sms"
    return pending, code(client, pending).json()


def register(client, pending, name=NEW["full_name"], pin=NEW["pin"], **kw):
    return client.post("/auth/register", json={"challenge": pending["challenge"], "name": name, "pin": pin}, **kw)


def test_code_tells_whether_number_is_registered_only_after_right_code(client):
    pending, reply = verified(client)
    assert reply == {"ok": True, "registered": False}
    _, reply = verified(client, AIGERIM)
    assert reply == {"ok": True, "registered": True}
    # До верного кода ответ одинаковый для любого номера.
    other = start(client, NEW, secret=device(NEW, 1)).json()
    wrong = "000000" if other["demo_code"] != "000000" else "111111"
    assert code(client, other, wrong).json()["detail"]["code"] == "invalid_code"


def test_register_creates_account_and_binds_phone(client):
    pending, _ = verified(client)
    r = register(client, pending, name="  Ерлан   Сейткали ")
    assert r.status_code == 200, r.text
    headers = {"Authorization": f"Bearer {r.json()['token']}"}
    me = client.get("/me", headers=headers).json()
    assert me["name"] == "Ерлан Сейткали" and me["phone"] == NEW["phone"] and me["balance"] == 0
    assert me["is_merchant"] is False and len(me["card_last4"]) == 4
    virtual = client.get("/cards/virtual/secret", headers=headers).json()
    assert virtual["number"].endswith(me["card_last4"]) and cards.luhn_ok(virtual["number"])
    # телефон привязан: дальше вход по PIN без SMS
    assert start(client, NEW).json() == {"next": "pin"}
    assert "token" in login(client, NEW).json()
    # тем же запросом второй раз не зарегистрироваться и не войти
    assert register(client, pending).json()["detail"]["code"] == "challenge_expired"
    assert confirm(client, pending, NEW["pin"]).json()["detail"]["code"] == "challenge_expired"


def test_register_needs_verified_code_and_free_number(client):
    pending = start(client, NEW).json()
    r = register(client, pending)
    assert r.status_code == 401 and r.json()["detail"]["code"] == "code_required"
    assert register(client, {"challenge": "x" * 24}).json()["detail"]["code"] == "challenge_expired"
    taken, _ = verified(client, AIGERIM, secret=device(AIGERIM, 3))
    r = register(client, taken)
    assert r.status_code == 409 and r.json()["detail"]["code"] == "already_registered"
    # учебный аккаунт не изменился
    assert "token" in confirm(client, taken, AIGERIM["pin"]).json()


@pytest.mark.parametrize("pin", ["0000", "1111", "9999", "1234", "4321", "0123", "6789", "9876", "3210", "1212"])
def test_weak_pins_are_refused(client, pin):
    pending, _ = verified(client)
    r = register(client, pending, pin=pin)
    assert r.status_code == 422 and r.json()["detail"]["code"] == "weak_pin"
    # запрос не сгорел: с нормальным PIN регистрация проходит
    assert register(client, pending).status_code == 200


@pytest.mark.parametrize("pin", ["123", "12345", "12a4", ""])
def test_pin_is_exactly_four_digits(client, pin):
    pending, _ = verified(client)
    assert register(client, pending, pin=pin).json()["detail"]["code"] == "invalid_request"


@pytest.mark.parametrize("name,ok", [
    ("Анна-Мария", True), ("Aigerim Kassymova", True), ("Әйгерім Қасымова", True), ("Ли", True),
    ("А", False), ("Ivan2", False), ("<b>Ivan</b>", False), ("Анна--Мария", False), ("-Анна", False),
    ("   ", False), ("а" * 61, False), ("Иван_Петров", False),
])
def test_name_rules(client, name, ok):
    pending, _ = verified(client)
    r = register(client, pending, name=name)
    if ok:
        assert r.status_code == 200, r.text
    else:
        assert r.status_code == 422 and r.json()["detail"]["code"] == "invalid_name", r.text


def test_number_registered_meanwhile_logs_in_on_other_phone(client):
    # Второй телефон начал вход, пока номер ещё не был зарегистрирован.
    other = start(client, NEW, secret=device(NEW, 1)).json()
    pending, _ = verified(client)
    assert register(client, pending).status_code == 200
    assert code(client, other).json() == {"ok": True, "registered": True}
    assert "token" in confirm(client, other, NEW["pin"]).json()


def test_registration_rate_limits(client, monkeypatch):
    monkeypatch.setattr(main, "_register_all", guard.Window(2, 3600))
    phones = [f"+7706000000{i}" for i in range(4)]
    pendings = [verified(client, {"phone": p}, secret=device({"phone": p}))[0] for p in phones]
    # отказ по слабому PIN лимит не тратит
    assert register(client, pendings[0], pin="0000").status_code == 422
    assert register(client, pendings[0]).status_code == 200
    assert register(client, pendings[1]).status_code == 200
    r = register(client, pendings[2])
    assert r.status_code == 429 and r.json()["detail"]["code"] == "slow_down"

    monkeypatch.setattr(main, "_register_all", guard.Window(100, 3600))
    monkeypatch.setattr(main, "IP_HEADER", "x-real-ip")
    monkeypatch.setattr(main, "_register_ip", guard.Window(1, 3600))
    assert register(client, pendings[2], headers={"X-Real-IP": "203.0.113.5"}).status_code == 200
    assert register(client, pendings[3], headers={"X-Real-IP": "203.0.113.5"}).status_code == 429
    assert register(client, pendings[3], headers={"X-Real-IP": "203.0.113.6"}).status_code == 200


def test_demo_accounts_still_log_in(client):
    assert client.get("/me", headers=auth(client, AIGERIM)).json()["balance"] == AIGERIM["balance"]
