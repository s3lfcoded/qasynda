"""Банковские карты пользователя и учебная виртуальная карта Qasynda.

Полный номер карты и CVV сервер не хранит (PCI DSS): номер приходит один раз, проверяется по Луну
и сроку, а в базу попадают только платёжная система, последние 4 цифры, срок и имя держателя.
Повтор карты узнаётся по этим же полям: даже хеш номера можно перебрать, зная BIN и последние цифры.
"""
from __future__ import annotations

import hashlib
import hmac
import os
import time

MAX_CARDS = 5

# Префикс учебной карты начинается с 0: ISO/IEC 7812 не выдаёт такие номера банкам,
# поэтому номер не совпадёт с настоящей картой ни одного эмитента.
VIRTUAL_PREFIX = "000777"
VIRTUAL_BRAND = "qasynda"


class CardError(Exception):
    def __init__(self, code: str, status: int = 422):
        super().__init__(code)
        self.code, self.status = code, status


def digits(number: str) -> str:
    return "".join(ch for ch in number if ch != " ")


def luhn_ok(number: str) -> bool:
    if not number.isdigit():
        return False
    total = 0
    for i, ch in enumerate(reversed(number)):
        d = int(ch)
        if i % 2:
            d = d * 2 - 9 if d > 4 else d * 2
        total += d
    return total % 10 == 0


def brand(number: str) -> str:
    """Платёжная система по BIN: Visa — 4, Mastercard — 51–55 и 2221–2720, UnionPay — 62 и 81."""
    if number.startswith("4"):
        return "visa"
    two, four = int(number[:2]), int(number[:4])
    if 51 <= two <= 55 or 2221 <= four <= 2720:
        return "mastercard"
    if two in (62, 81):
        return "unionpay"
    return "other"


def expired(expiry: str, now: float | None = None) -> bool:
    """Карта действует до последнего дня месяца, указанного на ней."""
    month, year = int(expiry[:2]), 2000 + int(expiry[3:])
    t = time.gmtime(time.time() if now is None else now)
    return (year, month) < (t.tm_year, t.tm_mon)


def normalize_holder(holder: str) -> str:
    return " ".join(holder.split()).upper()


def check(number: str, expiry: str) -> tuple[str, str]:
    """Проверка новой карты. Возвращает (платёжная система, последние 4 цифры) — больше от номера ничего не остаётся."""
    pan = digits(number)
    if not 12 <= len(pan) <= 19 or not luhn_ok(pan):
        raise CardError("invalid_card_number")
    if expired(expiry):
        raise CardError("card_expired")
    return brand(pan), pan[-4:]


def _virtual_key() -> bytes:
    # Учебные данные: ключ можно задать на сервере, иначе берётся постоянный, чтобы карта не менялась после перезапуска.
    return os.environ.get("QASYNDA_VIRTUAL_KEY", "qasynda-virtual-demo").encode()


def virtual(user_id: int, last4: str, holder: str) -> dict:
    """Учебная виртуальная карта: одна на пользователя, детерминированно из его id.
    Последние 4 цифры совпадают с картой в профиле, контрольная цифра Луна — перед ними."""
    h = hmac.new(_virtual_key(), f"card:{user_id}".encode(), hashlib.sha256).digest()
    middle = "".join(str(b % 10) for b in h[:5])
    head = VIRTUAL_PREFIX + middle
    for d in "0123456789":
        number = head + d + last4
        if luhn_ok(number):
            break
    month, year = 1 + h[5] % 12, 30 + h[6] % 3
    cvv = f"{int.from_bytes(h[7:10], 'big') % 1000:03d}"
    return {"brand": VIRTUAL_BRAND, "number": number, "last4": last4, "expiry": f"{month:02d}/{year:02d}",
            "cvv": cvv, "holder": holder}
