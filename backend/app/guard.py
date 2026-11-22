"""Ограничители частоты: скользящие окна по ключу.

Все проверки и записи идут под одной блокировкой, поэтому параллельные запросы не могут
проскочить проверку до того, как первый из них запишет попытку. Память ограничена:
при переполнении вытесняются ключи, к которым дольше всего не обращались.
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
    def __init__(self, limit: int, period: float, max_keys: int = 100_000) -> None:
        self.limit, self.period, self.max_keys = limit, period, max_keys
        self._keys: OrderedDict[object, deque[float]] = OrderedDict()
        _all.append(self)

    def _events(self, key: object, now: float) -> deque[float]:
        events = self._keys.get(key)
        if events is None:
            events = self._keys[key] = deque()
            while len(self._keys) > self.max_keys:
                self._keys.popitem(last=False)
        else:
            self._keys.move_to_end(key)
        while events and now - events[0] >= self.period:
            events.popleft()
        return events

    def _full(self, key: object, now: float) -> bool:
        return len(self._events(key, now)) >= self.limit

    def _retry_after(self, key: object, now: float) -> float:
        events = self._events(key, now)
        return max(0.0, events[0] + self.period - now) if len(events) >= self.limit else 0.0

    def take(self, key: object) -> bool:
        return take_all([(self, key)]) == 0.0

    def refund(self, key: object) -> None:
        with _lock:
            events = self._keys.get(key)
            if events:
                events.pop()

    def clear(self, key: object) -> None:
        with _lock:
            self._keys.pop(key, None)


def take_all(pairs: list[tuple[Window, object]]) -> float:
    """Записывает событие во все окна, если ни одно не переполнено. Иначе ничего не пишет
    и возвращает, через сколько секунд можно повторить."""
    now = clock()
    with _lock:
        if any(w._full(k, now) for w, k in pairs):
            return max(1.0, max(w._retry_after(k, now) for w, k in pairs))
        for w, k in pairs:
            w._events(k, now).append(now)
        return 0.0


class Distinct:
    """Сколько разных объектов ключ может увидеть за период (например, разных людей в поиске)."""

    def __init__(self, limit: int, period: float, max_keys: int = 100_000) -> None:
        self.limit, self.period, self.max_keys = limit, period, max_keys
        self._keys: OrderedDict[object, dict[object, float]] = OrderedDict()
        _all.append(self)

    def allow(self, key: object, item: object) -> bool:
        now = clock()
        with _lock:
            seen = self._keys.get(key)
            if seen is None:
                seen = self._keys[key] = {}
                while len(self._keys) > self.max_keys:
                    self._keys.popitem(last=False)
            else:
                self._keys.move_to_end(key)
            for old in [i for i, at in seen.items() if now - at >= self.period]:
                del seen[old]
            if item in seen or len(seen) < self.limit:
                seen[item] = now
                return True
            return False
