"""Маяки «я принимаю перевод рядом».

Координаты живут только в памяти и только пока открыт экран приёма:
в базу они не пишутся и исчезают через BEACON_TTL секунд без обновления.

У маяка два одноразовых идентификатора:
- ble_id     — телефон получателя транслирует его по Bluetooth; сервер никому его не выдаёт,
               поэтому знать его может только тот, кто физически рядом. Меняется каждые BLE_ROTATE
               секунд: по неизменной метке телефон можно было бы отслеживать, а услышанную однажды —
               предъявлять потом откуда угодно;
- public_id  — сервер отдаёт его в результатах поиска, по нему отправляется перевод. Меняется вместе
               с ble_id: иначе по нему можно было бы связать все сменяющиеся метки в одного человека.
               Прежний принимается для перевода ещё PUBLIC_GRACE секунд — пока отправитель вводит сумму.
"""
from __future__ import annotations

import math
import secrets
import threading
import time
from dataclasses import dataclass, field

BEACON_TTL = 45.0          # секунд без обновления до исчезновения маяка
BLE_ROTATE = 30.0          # как часто меняется Bluetooth-метка
BLE_GRACE = 20.0           # сколько принимается прежняя метка: отправитель помнит услышанное 12 секунд
PUBLIC_GRACE = 180.0       # сколько принимается прежний public_id
GPS_RADIUS_M = 75.0        # дальше этого по GPS «рядом» не считается
MAX_ACCURACY_M = 100.0     # координаты с худшей точностью для поиска не используются
MAX_SPEED_MPS = 30.0       # быстрее этого человек не перемещается: иначе координаты подставные
JUMP_SLACK_M = 150.0       # запас на скачки GPS сверх заявленной точности
ANCHOR_TTL = 24 * 3600.0


@dataclass
class Beacon:
    user_id: int
    public_id: str
    ble_id: str
    lat: float | None
    lon: float | None
    accuracy: float | None
    expires: float
    rotated_at: float = 0.0
    prev_ble_id: str | None = None
    prev_until: float = 0.0
    old_public: list[tuple[str, float]] = field(default_factory=list)

    def ble_ids(self, now: float) -> list[str]:
        """Метки, которые сейчас подтверждают близость: текущая и, недолго после смены, прежняя."""
        return [self.ble_id] + ([self.prev_ble_id] if self.prev_ble_id and now < self.prev_until else [])


_lock = threading.Lock()
_by_user: dict[int, Beacon] = {}
# Последнее правдоподобное положение каждого пользователя (по id, а не по сессии: новый вход его не сбрасывает).
_anchors: dict[int, tuple[float, float, float, float]] = {}


def clock() -> float:
    return time.monotonic()


def reset() -> None:
    with _lock:
        _by_user.clear()
        _anchors.clear()


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
            beacon = Beacon(user_id, secrets.token_hex(8), secrets.token_hex(8), None, None, None, 0.0, now)
            _by_user[user_id] = beacon
        elif now - beacon.rotated_at >= BLE_ROTATE:
            beacon.prev_ble_id, beacon.prev_until = beacon.ble_id, now + BLE_GRACE
            beacon.ble_id, beacon.rotated_at = secrets.token_hex(8), now
            beacon.old_public = [(p, t) for p, t in beacon.old_public if t > now] + [(beacon.public_id, now + PUBLIC_GRACE)]
            beacon.public_id = secrets.token_hex(8)
        beacon.lat, beacon.lon, beacon.accuracy = lat, lon, accuracy
        beacon.expires = now + BEACON_TTL
        return beacon


def remove(user_id: int) -> None:
    with _lock:
        _by_user.pop(user_id, None)


def by_public(public_id: str) -> Beacon | None:
    with _lock:
        now = clock()
        _purge(now)
        return next((b for b in _by_user.values()
                     if b.public_id == public_id or any(p == public_id and t > now for p, t in b.old_public)), None)


def by_ble(ble_ids: list[str]) -> list[Beacon]:
    wanted = set(ble_ids)
    now = clock()
    with _lock:
        _purge(now)
        return [b for b in _by_user.values() if wanted.intersection(b.ble_ids(now))]


def _haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6_371_000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = (math.sin((p2 - p1) / 2) ** 2
         + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2)
    return 2 * r * math.asin(math.sqrt(a))


def plausible(user_id: int, lat: float, lon: float, accuracy: float) -> bool:
    """Можно ли верить координатам: человек не мог оказаться здесь быстрее, чем позволяет скорость.

    Координаты присылает телефон, и подставить любые несложно. Без этой проверки можно было бы
    «встать» в любой точке города и узнать, кто там открыл приём, или выставить свой маяк у чужого магазина.
    Отвергнутые координаты не сдвигают точку отсчёта.
    """
    if accuracy > MAX_ACCURACY_M:
        return False
    now = clock()
    with _lock:
        if len(_anchors) > 10_000:
            for uid in [uid for uid, a in _anchors.items() if now - a[3] > ANCHOR_TTL]:
                del _anchors[uid]
        prev = _anchors.get(user_id)
        if prev is not None:
            p_lat, p_lon, p_acc, p_at = prev
            allowed = MAX_SPEED_MPS * (now - p_at) + p_acc + accuracy + JUMP_SLACK_M
            if _haversine_m(p_lat, p_lon, lat, lon) > allowed:
                return False
        _anchors[user_id] = (lat, lon, accuracy, now)
        return True


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
