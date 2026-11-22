"""Отправка SMS. Настоящего шлюза в прототипе нет.

QASYNDA_SMS_DEMO=1 — учебный режим: код возвращается в ответе сервера, и приложение показывает его
плашкой «Учебное SMS». Без этой настройки и без шлюза SMS никуда не уходит. Код в журнал не пишется
никогда: журналы хостинга читают не только владельцы аккаунтов. Чтобы подключить настоящий шлюз
(Mobizon, SMSC, Telegram Gateway), достаточно заменить send().
"""
from __future__ import annotations

import logging
import os

log = logging.getLogger("qasynda.sms")


def demo() -> bool:
    return os.environ.get("QASYNDA_SMS_DEMO") == "1"


def send(phone: str, text: str) -> None:
    log.warning("SMS на %s…%s не отправлено: шлюз не подключён", phone[:4], phone[-2:])
