"""Маяки «я принимаю перевод рядом».

Координаты живут только в памяти. У маяка хранится не настоящая точка, а сдвинутая на BLUR_M метров
в случайную сторону (сдвиг выбирается один раз на весь сеанс приёма): по ответам «рядом / нет»
из разных точек иначе можно было бы вычислить, где стоит человек, с точностью до сантиметров.
Маяк исчезает через BEACON_TTL секунд без обновления или сразу при закрытии экрана.

У маяка два одноразовых идентификатора:
- ble_id     — телефон получателя транслирует его по Bluetooth; сервер никому его не выдаёт,
               поэтому знать его может только тот, кто физически рядом. Меняется каждые BLE_ROTATE
               секунд: по неизменной метке телефон можно было бы отслеживать, а услышанную однажды —
               предъявлять потом откуда угодно;
- public_id  — сервер отдаёт его в результатах поиска, по нему отправляется перевод. Меняется вместе
               с ble_id: иначе по нему можно было бы связать все сменяющиеся метки в одного человека.
               Прежний принимается для перевода ещё PUBLIC_GRACE секунд — пока отправитель вводит сумму.

Для проверки правдоподобия координат (plausible) сервер помнит, где человек был: точную точку —
не дольше LAST_TTL, а на сутки — только квадрат около километра (CELL_DEG).
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
PUBLIC_GRACE = 600.0       # сколько принимается прежний public_id: пока отправитель вводит сумму
GPS_RADIUS_M = 75.0        # дальше этого (от сдвинутой точки маяка) по GPS «рядом» не считается
BLUR_M = 30.0              # на сколько сдвигается точка маяка
MAX_ACCURACY_M = 100.0     # координаты с худшей точностью для поиска не используются
MAX_SPEED_MPS = 30.0       # быстрее этого человек не перемещается: иначе координаты подставные
JUMP_SLACK_M = 150.0       # запас на скачки GPS
ACCURACY_CAP_M = 50.0      # больше этого заявленная точность к запасу не добавляет
WINDOW_S = 60.0            # запас на скачок даётся один раз на это окно, а не на каждый запрос
LAST_TTL = 120.0           # сколько помнится точная последняя точка
CELL_DEG = 0.01            # размер квадрата, который помнится сутки (~1 км)
CELL_SLACK_M = 1600.0      # половина диагонали квадрата с запасом
CELL_TTL = 24 * 3600.0


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
    blur_bearing: float = 0.0

    def ble_ids(self, now: float) -> list[str]:
        """Метки, которые сейчас подтверждают близость: текущая и, недолго после смены, прежняя."""
        return [self.ble_id] + ([self.prev_ble_id] if self.prev_ble_id and now < self.prev_until else [])


@dataclass
class _Track:
    last: tuple[float, float, float, float] | None = None      # lat, lon, accuracy, t — точная, LAST_TTL
    window: tuple[float, float, float] | None = None           # lat, lon, t — начало текущего окна
    cell: tuple[float, float, float] | None = None             # центр квадрата, t — на сутки


_lock = threading.Lock()
_by_user: dict[int, Beacon] = {}
# Где человек был (по id, а не по сессии: новый вход проверку не сбрасывает).
_tracks: dict[int, _Track] = {}


def clock() -> float:
    return time.monotonic()


def reset() -> None:
    with _lock:
        _by_user.clear()
        _tracks.clear()


def _purge(now: float) -> None:
    for uid in [uid for uid, b in _by_user.items() if b.expires <= now]:
        del _by_user[uid]


def _shift(lat: float, lon: float, bearing: float, meters: float) -> tuple[float, float]:
    d_lat = meters * math.cos(bearing) / 111_320.0
    d_lon = meters * math.sin(bearing) / (111_320.0 * max(math.cos(math.radians(lat)), 0.01))
    return max(-90.0, min(90.0, lat + d_lat)), ((lon + d_lon + 180.0) % 360.0) - 180.0


def upsert(user_id: int, lat: float | None, lon: float | None, accuracy: float | None) -> Beacon:
    """Создаёт маяк или продлевает существующий. Идентификаторы меняются каждые BLE_ROTATE секунд."""
    now = clock()
    with _lock:
        _purge(now)
        beacon = _by_user.get(user_id)
        if beacon is None:
            beacon = Beacon(user_id, secrets.token_hex(8), secrets.token_hex(8), None, None, None, 0.0, now,
                            blur_bearing=secrets.randbelow(360_000) / 360_000 * 2 * math.pi)
            _by_user[user_id] = beacon
        elif now - beacon.rotated_at >= BLE_ROTATE:
            beacon.prev_ble_id, beacon.prev_until = beacon.ble_id, now + BLE_GRACE
            beacon.ble_id, beacon.rotated_at = secrets.token_hex(8), now
            beacon.old_public = [(p, t) for p, t in beacon.old_public if t > now] + [(beacon.public_id, now + PUBLIC_GRACE)]
            beacon.public_id = secrets.token_hex(8)
        if lat is not None and lon is not None:
            beacon.lat, beacon.lon = _shift(lat, lon, beacon.blur_bearing, BLUR_M)
        else:
            beacon.lat = beacon.lon = None
        beacon.accuracy = accuracy
        beacon.expires = now + BEACON_TTL
        return beacon


def remove(user_id: int) -> None:
    with _lock:
        _by_user.pop(user_id, None)


def forget(user_id: int) -> None:
    """Выход из аккаунта: маяк гаснет, точные координаты стираются. Остаётся только квадрат ~1 км на сутки,
    чтобы повторный вход не позволял «телепортироваться»."""
    with _lock:
        _by_user.pop(user_id, None)
        track = _tracks.get(user_id)
        if track:
            track.last = track.window = None


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
    return 2 * r * math.asin(math.sqrt(min(1.0, a)))


def _cell(lat: float, lon: float) -> tuple[float, float]:
    return (math.floor(lat / CELL_DEG) + 0.5) * CELL_DEG, (math.floor(lon / CELL_DEG) + 0.5) * CELL_DEG


def plausible(user_id: int, lat: float, lon: float, accuracy: float) -> bool:
    """Можно ли верить координатам: человек не мог оказаться здесь быстрее, чем позволяет скорость.

    Координаты присылает телефон, и подставить любые несложно. Без этой проверки можно было бы
    «встать» в любой точке города и узнать, кто там открыл приём, или выставить свой маяк у чужого магазина.
    Проверка идёт от трёх точек отсчёта: последней точки, начала текущей минуты (запас на скачок GPS
    даётся раз в минуту, а не на каждый запрос — иначе мелкими прыжками можно «проехать» город за секунду)
    и квадрата, где человек был в последние сутки. Отвергнутые координаты точки отсчёта не сдвигают.
    """
    if accuracy > MAX_ACCURACY_M:
        return False
    acc = min(accuracy, ACCURACY_CAP_M)
    now = clock()
    with _lock:
        if len(_tracks) > 10_000:
            for uid in [uid for uid, t in _tracks.items() if not t.cell or now - t.cell[2] > CELL_TTL]:
                del _tracks[uid]
        track = _tracks.setdefault(user_id, _Track())
        if track.last and now - track.last[3] > LAST_TTL:
            track.last = None
        if track.window and now - track.window[2] > WINDOW_S:
            track.window = None
        if track.cell and now - track.cell[2] > CELL_TTL:
            track.cell = None

        if track.last:
            p_lat, p_lon, p_acc, p_at = track.last
            if _haversine_m(p_lat, p_lon, lat, lon) > MAX_SPEED_MPS * (now - p_at) + p_acc + acc + JUMP_SLACK_M:
                return False
        if track.window:
            w_lat, w_lon, w_at = track.window
            if _haversine_m(w_lat, w_lon, lat, lon) > MAX_SPEED_MPS * (now - w_at) + 2 * ACCURACY_CAP_M + JUMP_SLACK_M:
                return False
        if track.cell:
            c_lat, c_lon, c_at = track.cell
            if _haversine_m(c_lat, c_lon, lat, lon) > MAX_SPEED_MPS * (now - c_at) + CELL_SLACK_M + JUMP_SLACK_M:
                return False

        track.last = (lat, lon, acc, now)
        if track.window is None:
            track.window = (lat, lon, now)
        c_lat, c_lon = _cell(lat, lon)
        track.cell = (c_lat, c_lon, now)
        return True


def gps_distance(beacon: Beacon, lat: float, lon: float, accuracy: float) -> float | None:
    """Расстояние до сдвинутой точки маяка, если обе точки достаточно точны и в пределах радиуса; иначе None."""
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
