"""Маяки «я принимаю перевод рядом».

Координаты живут только в памяти и только пока открыт экран приёма:
в базу они не пишутся и исчезают через BEACON_TTL секунд без обновления.

У маяка два одноразовых идентификатора:
- ble_id     — телефон получателя транслирует его по Bluetooth; сервер никому его не выдаёт,
               поэтому знать его может только тот, кто физически рядом;
- public_id  — сервер отдаёт его в результатах поиска, по нему отправляется перевод.
"""
from __future__ import annotations

import math
import secrets
import threading
import time
from dataclasses import dataclass

BEACON_TTL = 45.0          # секунд без обновления до исчезновения маяка
GPS_RADIUS_M = 75.0        # дальше этого по GPS «рядом» не считается
MAX_ACCURACY_M = 100.0     # координаты с худшей точностью для поиска не используются


@dataclass
class Beacon:
    user_id: int
    public_id: str
    ble_id: str
    lat: float | None
    lon: float | None
    accuracy: float | None
    expires: float


_lock = threading.Lock()
_by_user: dict[int, Beacon] = {}


def clock() -> float:
    return time.monotonic()


def reset() -> None:
    with _lock:
        _by_user.clear()


def _purge(now: float) -> None:
    for uid in [uid for uid, b in _by_user.items() if b.expires <= now]:
        del _by_user[uid]


def upsert(user_id: int, lat: float | None, lon: float | None, accuracy: float | None) -> Beacon:
    """Создаёт маяк или продлевает существующий. Идентификаторы живут, пока маяк не погас."""
    now = clock()
    with _lock:
        _purge(now)
        beacon = _by_user.get(user_id)
        if beacon is None:
            beacon = Beacon(user_id, secrets.token_hex(8), secrets.token_hex(8), None, None, None, 0.0)
            _by_user[user_id] = beacon
        beacon.lat, beacon.lon, beacon.accuracy = lat, lon, accuracy
        beacon.expires = now + BEACON_TTL
        return beacon


def remove(user_id: int) -> None:
    with _lock:
        _by_user.pop(user_id, None)


def by_public(public_id: str) -> Beacon | None:
    with _lock:
        _purge(clock())
        return next((b for b in _by_user.values() if b.public_id == public_id), None)


def by_ble(ble_ids: list[str]) -> list[Beacon]:
    wanted = set(ble_ids)
    with _lock:
        _purge(clock())
        return [b for b in _by_user.values() if b.ble_id in wanted]


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def gps_distance(beacon: Beacon, lat: float, lon: float, accuracy: float) -> float | None:
    """Расстояние в метрах, если обе точки достаточно точны и в пределах радиуса; иначе None."""
    if beacon.lat is None or beacon.lon is None or beacon.accuracy is None:
        return None
    if accuracy > MAX_ACCURACY_M or beacon.accuracy > MAX_ACCURACY_M:
        return None
    distance = _haversine_m(beacon.lat, beacon.lon, lat, lon)
    return distance if distance <= GPS_RADIUS_M else None


def near_by_gps(lat: float, lon: float, accuracy: float) -> list[tuple[Beacon, float]]:
    with _lock:
        _purge(clock())
        beacons = list(_by_user.values())
    found = [(b, d) for b in beacons if (d := gps_distance(b, lat, lon, accuracy)) is not None]
    return sorted(found, key=lambda pair: pair[1])
