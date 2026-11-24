"""Учебные боты для проверки переводов в одиночку. Работают только при QASYNDA_SEED_DEMO=1.

«Кофейня Qasynda» принимает деньги и оставляет их себе. «Алия Бот» через несколько секунд возвращает
отправителю ту же сумму и по просьбе (POST /demo/request) присылает деньги сама. Боты «рядом» со всеми:
в поиске они идут последними с method "demo", их public_id постоянный.
"""
from __future__ import annotations

import hashlib
import os

from . import db

COFFEE = "bot:coffee"
ALIYA = "bot:aliya"


def enabled() -> bool:
    return os.environ.get("QASYNDA_SEED_DEMO") == "1"


def public_id(bot: dict) -> str:
    return hashlib.sha256(f"qasynda-bot:{bot['full_name']}".encode()).hexdigest()[:16]


def bots() -> list[dict]:
    return db.bots() if enabled() else []


def by_public(value: str) -> dict | None:
    return next((b for b in bots() if public_id(b) == value), None)


def by_phone(phone: str) -> dict | None:
    return next((b for b in bots() if b["phone"] == phone), None)
