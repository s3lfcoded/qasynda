"""Отправка SMS. Настоящего шлюза в прототипе нет.

QASYNDA_SMS_DEMO=1 — учебный режим: код возвращается в ответе сервера, и приложение показывает его
плашкой «Учебное SMS». Без этой настройки код пишется в журнал сервера. Чтобы подключить настоящий шлюз,
достаточно заменить send().
"""
from __future__ import annotations

import logging
import os

log = logging.getLogger("qasynda.sms")


def demo() -> bool:
    return os.environ.get("QASYNDA_SMS_DEMO") == "1"


def send(phone: str, text: str) -> None:
    log.warning("SMS на %s…%s: %s", phone[:4], phone[-2:], text)
