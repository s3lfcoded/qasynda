"""Ограничители частоты: скользящие окна по ключу.

Все проверки и записи идут под одной блокировкой, поэтому параллельные запросы не могут
проскочить проверку до того, как первый из них запишет попытку. Память ограничена: при переполнении
вытесняются только ключи, все события которых уже устарели. Живые счётчики не вытесняются никогда —
иначе поток запросов с выдуманными ключами (номерами телефонов) обнулял бы чужие лимиты.
Если места нет, новый ключ не заводится и запрос получает отказ, пока старые события не устареют.
"""
from __future__ import annotations

import threading
import time
from collections import OrderedDict, deque

_lock = threading.Lock()
_all: list["Window | Distinct"] = []


def clock() -> float:
    return time.monotonic()


def reset() -> None:
    with _lock:
        for item in _all:
            item._keys.clear()


class Window:
    def __init__(self, limit: int, period: float, max_keys: int = 200_000) -> None:
        self.limit, self.period, self.max_keys = limit, period, max_keys
        self._keys: OrderedDict[object, deque[float]] = OrderedDict()
        _all.append(self)

    def _trim(self, events: deque[float], now: float) -> None:
        while events and now - events[0] >= self.period:
            events.popleft()

    def _get(self, key: object, now: float) -> deque[float] | None:
        events = self._keys.get(key)
        if events is not None:
            self._trim(events, now)
            self._keys.move_to_end(key)
        return events

    def _make_room(self, now: float) -> bool:
        if len(self._keys) < self.max_keys:
            return True
        for key in list(self._keys)[: max(64, self.max_keys // 100)]:
            events = self._keys[key]
            self._trim(events, now)
            if not events:
                del self._keys[key]
        return len(self._keys) < self.max_keys

    def _count(self, key: object, now: float) -> int:
        events = self._get(key, now)
        return len(events) if events else 0

    def _retry_after(self, key: object, now: float) -> float:
        events = self._get(key, now)
        if events is None:
            return self.period
        return max(0.0, events[0] + self.period - now) if len(events) >= self.limit else 0.0

    def take(self, key: object) -> bool:
        return take_all([(self, key)]) == 0.0

    def refund(self, key: object) -> None:
        with _lock:
            events = self._keys.get(key)
            if events:
                events.pop()
                if not events:
                    del self._keys[key]

    def clear(self, key: object) -> None:
        with _lock:
            self._keys.pop(key, None)


def take_all(pairs: list[tuple[Window, object]]) -> float:
    """Записывает событие во все окна, если ни одно не переполнено. Иначе ничего не пишет
    и возвращает, через сколько секунд можно повторить."""
    now = clock()
    with _lock:
        waits = []
        for w, k in pairs:
            if k not in w._keys and not w._make_room(now):
                waits.append(w.period)
            elif w._count(k, now) >= w.limit:
                waits.append(w._retry_after(k, now))
        if waits:
            return max(1.0, max(waits))
        for w, k in pairs:
            events = w._get(k, now)
            if events is None:
                events = w._keys[k] = deque()
            events.append(now)
        return 0.0


class Distinct:
    """Сколько разных объектов ключ может увидеть за период (например, разных людей в поиске)."""

    def __init__(self, limit: int, period: float, max_keys: int = 200_000) -> None:
        self.limit, self.period, self.max_keys = limit, period, max_keys
        self._keys: OrderedDict[object, dict[object, float]] = OrderedDict()
        _all.append(self)

    def allow(self, key: object, item: object) -> bool:
        now = clock()
        with _lock:
            seen = self._keys.get(key)
            if seen is None:
                if len(self._keys) >= self.max_keys:
                    for old in list(self._keys)[: max(64, self.max_keys // 100)]:
                        if all(now - at >= self.period for at in self._keys[old].values()):
                            del self._keys[old]
                    if len(self._keys) >= self.max_keys:
                        return False
                seen = self._keys[key] = {}
            else:
                self._keys.move_to_end(key)
            for old in [i for i, at in seen.items() if now - at >= self.period]:
                del seen[old]
            if item in seen or len(seen) < self.limit:
                seen[item] = now
                return True
            return False
