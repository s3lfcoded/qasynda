"""Qasynda — сервер переводов «рядом» (Bluetooth + GPS). Учебный прототип, деньги синтетические."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import os
import re
import secrets
import threading
import time
import unicodedata
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Path, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import db, guard, nearby, sms

# Лимит одного перевода в тиынах. Близость по Bluetooth подделать труднее, чем координаты,
# поэтому перевод только по GPS ограничен жёстче.
LIMIT_BLUETOOTH = 500_000_00
LIMIT_GPS = 50_000_00
# Минимальный перевод — как у Банка ЦентрКредит по номеру телефона (100 ₸): переводы на 1 тиын
# с комментарием иначе превращаются в бесплатную рассылку сообщений незнакомым людям.
MIN_AMOUNT = 100_00
# Сколько можно отправить за последние 24 часа. Всего — как суточный лимит Kaspi между своими
# клиентами (2 млн ₸); по GPS — три полных перевода, иначе лимит одного перевода ничего не ограничивает.
DAILY_LIMIT = 2_000_000_00
DAILY_LIMIT_GPS = 150_000_00

# PIN: 5 неудачных попыток на номер за 5 минут и 15 за сутки. Попытка записывается до проверки PIN —
# параллельные запросы лимит не обходят. Счётчики раздельные для входа с привязанного телефона,
# для подтверждения нового телефона и для разблокировки приложения: чужие попытки с нового телефона
# не должны закрывать вход владельцу.
LOGIN_ATTEMPTS = 5
_login_short = guard.Window(LOGIN_ATTEMPTS, 300)
_login_long = guard.Window(15, 24 * 3600)
_unlock_rate = guard.Window(LOGIN_ATTEMPTS, 900)
# Перебор одного PIN по многим номерам ограничивается по адресу клиента — если сервер знает его настоящий адрес.
_login_ip = guard.Window(50, 600)
IP_HEADER = os.environ.get("QASYNDA_IP_HEADER", "").strip().lower()

# Вход с нового телефона подтверждается кодом из SMS. SMS стоят денег и ими можно засыпать человека,
# поэтому их число ограничено и по номеру, и по адресу.
SMS_TTL = 300.0
SMS_ATTEMPTS = 5
_sms_phone = guard.Window(3, 3600)
_sms_ip = guard.Window(20, 3600)

_discover_rate = guard.Window(40, 60)        # приложение спрашивает раз в 2 секунды — 30 в минуту
_beacon_rate = guard.Window(12, 60)          # приложение продлевает маяк раз в 15 секунд
_gps_people = guard.Distinct(30, 3600)       # столько разных людей по GPS можно увидеть за час
_transfer_rate = guard.Window(10, 60)
_pair_rate = guard.Window(3, 600)            # одному и тому же получателю

HexId = Annotated[str, Field(pattern=r"^[0-9a-f]{16}$")]
# Сколько услышанных меток учитывается. Остальные отбрасываются: иначе передатчик, рассылающий сотни
# поддельных меток, ломал бы оплату всем вокруг. Приложение присылает сначала самые сильные сигналы.
MAX_BLE_IDS = 64
DeviceSecret = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{32,128}$")]


class Location(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    accuracy: float = Field(ge=0, le=10_000)
    # Android сам помечает координаты из программ подмены местоположения.
    mocked: bool = False


class LoginIn(BaseModel):
    phone: str = Field(pattern=r"^\+7\d{10}$")
    pin: str = Field(pattern=r"^\d{4,6}$")
    device_secret: DeviceSecret
    device_name: str = Field(default="Телефон", min_length=1, max_length=60)


class ConfirmIn(BaseModel):
    challenge: str = Field(pattern=r"^[A-Za-z0-9_-]{16,64}$")
    code: str = Field(pattern=r"^\d{6}$")
    pin: str = Field(pattern=r"^\d{4,6}$")


class UnlockIn(BaseModel):
    """PIN или секрет из хранилища под биометрией — одно из двух."""
    pin: str | None = Field(default=None, pattern=r"^\d{4,6}$")
    bio_secret: str | None = Field(default=None, pattern=r"^[A-Za-z0-9_-]{32,128}$")


class BeaconIn(BaseModel):
    location: Location | None = None


class DiscoverIn(BaseModel):
    location: Location | None = None
    ble_ids: list[HexId] = Field(default_factory=list, max_length=500)


class TransferIn(BaseModel):
    public_id: HexId
    ble_ids: list[HexId] = Field(default_factory=list, max_length=500)
    location: Location | None = None
    amount: int = Field(gt=0, le=LIMIT_BLUETOOTH)
    idempotency_key: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    # 140 символов — как поле назначения платежа в стандарте ISO 20022, на котором работают платёжные системы.
    note: str | None = Field(default=None, max_length=140)


# Комментарий к переводу — канал связи с незнакомым человеком. Ссылки и номера телефонов в нём —
# основа схемы «я ошибочно перевёл, верните вот сюда», поэтому они запрещены.
_LINK = re.compile(r"(https?://|www\.|\b(t|wa)\.me\b|\b[a-z0-9-]+\.[a-z]{2,}(/|\b))", re.IGNORECASE)
_PHONE = re.compile(r"(?:\+?\d[\s\-().]*){10,}")


def clean_note(note: str | None) -> str | None:
    """Убирает невидимые и управляющие символы (в том числе разворот текста), схлопывает пробелы."""
    if note is None:
        return None
    text = "".join(ch if unicodedata.category(ch)[0] not in "CZ" else " " for ch in note)
    text = " ".join(text.split())
    if not text:
        return None
    if _LINK.search(text) or _PHONE.search(text):
        raise fail(422, "note_not_allowed")
    return text


class Hub:
    """Открытые WebSocket-соединения: мгновенное уведомление о переводе и закрытие при выходе с устройства.

    Обычные (не async) обработчики работают в пуле потоков, поэтому отправка всегда передаётся
    в цикл событий сервера через loop.call_soon_threadsafe."""

    MAX_PER_USER = 3
    SEND_TIMEOUT = 2.0

    def __init__(self) -> None:
        self._sockets: dict[int, list[tuple[WebSocket, str | None]]] = {}
        self._tasks: set[asyncio.Task] = set()
        self.loop: asyncio.AbstractEventLoop | None = None

    def add(self, user_id: int, device_id: str | None, sock: WebSocket) -> None:
        sockets = self._sockets.setdefault(user_id, [])
        sockets.append((sock, device_id))
        while len(sockets) > self.MAX_PER_USER:
            self._run(self._close(sockets.pop(0)[0]))

    def remove(self, user_id: int, sock: WebSocket) -> None:
        sockets = self._sockets.get(user_id)
        if sockets:
            sockets[:] = [entry for entry in sockets if entry[0] is not sock]
            if not sockets:
                del self._sockets[user_id]

    def notify(self, user_id: int, event: dict, skip_device: str | None = None) -> None:
        """Отправляет в фоне: медленный получатель не задерживает ответ отправителю."""
        for sock, device_id in list(self._sockets.get(user_id, ())):
            if skip_device is None or device_id != skip_device:
                self._run(self._send(user_id, sock, event))

    def kick(self, user_id: int, device_ids: list[str]) -> None:
        """Закрывает соединения устройств, с которых пользователь вышел или которые отвязал."""
        for sock, device_id in list(self._sockets.get(user_id, ())):
            if device_id in device_ids:
                self.remove(user_id, sock)
                self._run(self._close(sock))

    def _run(self, coro) -> None:
        try:
            asyncio.get_running_loop()
        except RuntimeError:
            if self.loop is None:
                coro.close()
                return
            self.loop.call_soon_threadsafe(self._spawn, coro)
            return
        self._spawn(coro)

    def _spawn(self, coro) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _send(self, user_id: int, sock: WebSocket, event: dict) -> None:
        try:
            await asyncio.wait_for(sock.send_json(event), self.SEND_TIMEOUT)
        except Exception:
            self.remove(user_id, sock)
            await self._close(sock)

    @staticmethod
    async def _close(sock: WebSocket) -> None:
        try:
            await sock.close(code=4408)
        except Exception:
            pass


hub = Hub()


def _sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class _Expiring:
    """Короткоживущие одноразовые записи в памяти (пропуска WebSocket, SMS-запросы), хранятся по хешу ключа."""

    def __init__(self, ttl: float, max_items: int = 50_000) -> None:
        self.ttl, self.max_items = ttl, max_items
        self._items: dict[str, tuple[float, dict]] = {}
        self._lock = threading.Lock()

    def clear(self) -> None:
        with self._lock:
            self._items.clear()

    def put(self, value: dict) -> str:
        key = secrets.token_urlsafe(24)
        now = time.monotonic()
        with self._lock:
            for h in [h for h, (exp, _) in self._items.items() if exp <= now]:
                del self._items[h]
            while len(self._items) >= self.max_items:
                del self._items[next(iter(self._items))]
            self._items[_sha(key)] = (now + self.ttl, value)
        return key

    def get(self, key: str) -> dict | None:
        with self._lock:
            entry = self._items.get(_sha(key))
            if entry is None or entry[0] <= time.monotonic():
                self._items.pop(_sha(key), None)
                return None
            return entry[1]

    def pop(self, key: str) -> dict | None:
        with self._lock:
            entry = self._items.pop(_sha(key), None)
        return entry[1] if entry and entry[0] > time.monotonic() else None


# Одноразовые пропуска для WebSocket: выдаются по токену сессии и живут 30 секунд.
TICKET_TTL = 30.0
_tickets = _Expiring(TICKET_TTL)
_challenges = _Expiring(SMS_TTL)


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.init()
    if os.environ.get("QASYNDA_SEED_DEMO") == "1":
        db.seed_demo()
    hub.loop = asyncio.get_running_loop()
    yield
    hub.loop = None


app = FastAPI(title="Qasynda", lifespan=lifespan)

_origins = [o.strip() for o in os.environ.get("QASYNDA_CORS_ORIGINS", "").split(",") if o.strip()]
if _origins:
    app.add_middleware(CORSMiddleware, allow_origins=_origins,
                       allow_methods=["GET", "POST", "DELETE"],
                       allow_headers=["Authorization", "Content-Type"])


def fail(status: int, code: str, **extra) -> HTTPException:
    return HTTPException(status, detail={"code": code, **extra})


def wait_error(code: str, wait: float) -> HTTPException:
    seconds = int(wait) + 1
    return HTTPException(429, detail={"code": code, "retry_after": seconds}, headers={"Retry-After": str(seconds)})


def slow_down(wait: float) -> HTTPException:
    return wait_error("slow_down", wait)


def _bearer(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise fail(401, "unauthorized")
    return authorization[7:]


def current_user(authorization: Annotated[str | None, Header()] = None) -> dict:
    user = db.user_by_token(_bearer(authorization))
    if not user:
        raise fail(401, "unauthorized")
    return user


User = Annotated[dict, Depends(current_user)]


def unlocked_user(user: User, authorization: Annotated[str | None, Header()] = None) -> dict:
    """Пользователь, чья сессия разблокирована PIN или биометрией не дольше UNLOCK_TTL назад.
    Без этого токен сессии сам по себе открывал бы переводы, и блокировка приложения была бы
    только картинкой: любой, кто добрался до токена или до экрана в обход блокировки, переводил бы деньги."""
    now = time.time()
    until = user.get("session_unlocked_until") or 0
    if until <= now:
        raise fail(403, "locked")
    if until - now < db.UNLOCK_TTL - 30:
        db.set_unlocked(_bearer(authorization), now + db.UNLOCK_TTL)
    return user


Unlocked = Annotated[dict, Depends(unlocked_user)]


def client_ip(request: Request) -> str | None:
    """Адрес клиента для ограничений, только если задан QASYNDA_IP_HEADER — заголовок, который прокси
    заполняет сам. Адрес соединения не годится: за прокси хостинга он у всех пользователей один,
    и любой мог бы исчерпать общий лимит и закрыть вход всем. X-Forwarded-For клиент может подделать."""
    if not IP_HEADER:
        return None
    value = request.headers.get(IP_HEADER, "").split(",")[0].strip()
    return value or None


def pin_gate(key: object, ip: str | None) -> list[tuple[guard.Window, object]]:
    gates: list[tuple[guard.Window, object]] = [(_login_short, key), (_login_long, key)]
    if ip:
        gates.append((_login_ip, ip))
    if wait := guard.take_all(gates):
        raise wait_error("too_many_attempts", wait)
    return gates


def pin_passed(key: object, gates: list[tuple[guard.Window, object]]) -> None:
    """PIN верный: короткое окно обнуляется, а эта попытка не засчитывается в суточный лимит и лимит адреса."""
    _login_short.clear(key)
    for window, key in gates[1:]:
        window.refund(key)


def trusted_location(user_id: int, loc: Location | None) -> tuple[Location | None, str]:
    if loc is None:
        return None, "off"
    if loc.mocked or not nearby.plausible(user_id, loc.lat, loc.lon, loc.accuracy):
        return None, "ignored"
    return loc, "ok"


def short_name(full_name: str) -> str:
    """«Айгерим Касымова» → «Айгерим К.»: посторонний рядом не видит фамилию целиком."""
    parts = full_name.split()
    return parts[0] if len(parts) < 2 else f"{parts[0]} {parts[1][0]}."


def profile(user: dict) -> dict:
    return {
        "name": user["full_name"], "phone": user["phone"], "balance": user["balance"],
        "is_merchant": bool(user["is_merchant"]), "business_name": user["business_name"],
        "card_last4": user["card_last4"],
    }


def public_card(user: dict) -> dict:
    return {
        "name": short_name(user["full_name"]),
        "is_merchant": bool(user["is_merchant"]),
        "business_name": user["business_name"] if user["is_merchant"] else None,
    }


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.post("/auth/login")
def login(body: LoginIn, request: Request) -> dict:
    """Вход. С привязанного телефона — по PIN. С нового телефона PIN даже не проверяется, пока не введён
    код из SMS: иначе перебор PIN с чужого устройства продолжал бы работать, а ответ «нужно SMS»
    подсказывал бы, что PIN угадан. Ответ для несуществующего номера такой же, как для настоящего."""
    ip = client_ip(request)
    gates = pin_gate(body.phone, ip)
    user = db.user_by_phone(body.phone)
    device = db.device_of(user["id"], body.device_secret) if user else None
    if device:
        if not db.check_pin(user, body.pin):
            raise fail(401, "invalid_credentials")
        pin_passed(body.phone, gates)
        return {"token": db.create_session(user["id"], device["id"])}

    for window, key in gates:
        window.refund(key)
    sms_gates: list[tuple[guard.Window, object]] = [(_sms_phone, body.phone)]
    if ip:
        sms_gates.append((_sms_ip, ip))
    if wait := guard.take_all(sms_gates):
        raise wait_error("too_many_sms", wait)
    code = f"{secrets.randbelow(10**6):06d}"
    challenge = _challenges.put({
        "phone": body.phone, "user_id": user["id"] if user else None, "code": _sha(code),
        "device_secret": body.device_secret, "device_name": body.device_name, "attempts": 0,
    })
    if user:
        sms.send(body.phone, f"Qasynda: код входа с нового телефона {code}. Никому его не сообщайте.")
    reply = {"sms_required": True, "challenge": challenge, "ttl": SMS_TTL}
    if sms.demo():
        reply["demo_code"] = code
    return reply


@app.post("/auth/confirm")
def confirm(body: ConfirmIn, request: Request) -> dict:
    """Второй шаг входа с нового телефона: код из SMS и PIN вместе. Ошибка одна на оба поля,
    чтобы по ответу нельзя было понять, что из них верно."""
    pending = _challenges.get(body.challenge)
    if pending is None:
        raise fail(401, "challenge_expired")
    key = ("new_device", pending["phone"])
    gates = pin_gate(key, client_ip(request))
    pending["attempts"] += 1
    user = db.user_by_id(pending["user_id"]) if pending["user_id"] else None
    code_ok = hmac.compare_digest(_sha(body.code), pending["code"])
    pin_ok = db.check_pin(user, body.pin)
    if not (code_ok and pin_ok and user):
        if pending["attempts"] >= SMS_ATTEMPTS:
            _challenges.pop(body.challenge)
            raise fail(401, "challenge_expired")
        raise fail(401, "invalid_credentials")
    if _challenges.pop(body.challenge) is None:
        raise fail(401, "challenge_expired")
    pin_passed(key, gates)
    device_id = db.add_device(user["id"], pending["device_secret"], pending["device_name"])
    hub.notify(user["id"], {"type": "new_device", "name": pending["device_name"]}, skip_device=device_id)
    return {"token": db.create_session(user["id"], device_id)}


@app.post("/auth/unlock")
def unlock(body: UnlockIn, user: User, authorization: Annotated[str | None, Header()] = None) -> dict:
    """Разблокировка: PIN или секрет, который приложение достаёт из хранилища только после Face ID
    или отпечатка владельца. Код телефона его не открывает. Пять ошибок за 15 минут — сессия закрыта."""
    if (body.pin is None) == (body.bio_secret is None):
        raise fail(422, "pin_or_bio_required")
    key = ("unlock", user["id"], user["session_device"])
    token = _bearer(authorization)
    if not _unlock_rate.take(key):
        db.logout(token)
        _unlock_rate.clear(key)
        raise fail(401, "unauthorized")
    ok = db.check_pin(user, body.pin) if body.pin is not None else db.check_bio(user["session_device"], body.bio_secret)
    if not ok:
        raise fail(403, "invalid_pin" if body.pin is not None else "invalid_bio")
    _unlock_rate.clear(key)
    db.set_unlocked(token, time.time() + db.UNLOCK_TTL)
    return {"ok": True, "ttl": db.UNLOCK_TTL}


@app.post("/auth/lock")
def lock(user: User, authorization: Annotated[str | None, Header()] = None) -> dict:
    """Приложение заблокировалось — сервер тоже перестаёт пускать к переводам."""
    db.set_unlocked(_bearer(authorization), 0)
    return {"ok": True}


@app.post("/auth/bio-key")
def bio_key(user: Unlocked) -> dict:
    """Новый секрет для биометрии этого устройства. Только из разблокированной сессии:
    иначе вор с заблокированным телефоном привязал бы своё лицо."""
    if not user["session_device"]:
        raise fail(400, "device_required")
    secret = secrets.token_urlsafe(32)
    db.set_bio(user["session_device"], secret)
    return {"bio_secret": secret}


@app.delete("/auth/bio-key")
def bio_key_off(user: User) -> dict:
    if user["session_device"]:
        db.set_bio(user["session_device"], None)
    return {"ok": True}


@app.post("/auth/logout")
def logout(user: User, authorization: Annotated[str | None, Header()] = None) -> dict:
    nearby.remove(user["id"])
    db.logout(_bearer(authorization))
    return {"ok": True}


@app.get("/devices")
def devices(user: Unlocked) -> dict:
    return {"items": [{**d, "current": d["id"] == user["session_device"]} for d in db.devices(user["id"])]}


@app.delete("/devices/{device_id}")
def remove_device(device_id: Annotated[str, Path(pattern=r"^[0-9a-f]{16}$")], user: Unlocked) -> dict:
    """Отвязать устройство: его сессии закрываются, а вход с него снова потребует SMS."""
    removed = db.remove_devices(user["id"], [device_id])
    if not removed:
        raise fail(404, "device_not_found")
    hub.kick(user["id"], removed)
    return {"ok": True}


@app.post("/devices/logout-others")
def logout_others(user: Unlocked) -> dict:
    others = [d["id"] for d in db.devices(user["id"]) if d["id"] != user["session_device"]]
    removed = db.remove_devices(user["id"], others)
    hub.kick(user["id"], removed)
    return {"removed": len(removed)}


@app.get("/me")
def me(user: Unlocked) -> dict:
    return profile(user)


@app.post("/nearby/beacon")
def beacon_on(body: BeaconIn, user: Unlocked) -> dict:
    """Экран «Принять рядом» открыт. Клиент повторяет запрос каждые ~15 секунд, пока экран открыт;
    Bluetooth-метка в ответе периодически меняется, и приложение начинает транслировать новую."""
    if wait := guard.take_all([(_beacon_rate, user["id"])]):
        raise slow_down(wait)
    loc, gps = trusted_location(user["id"], body.location)
    beacon = nearby.upsert(user["id"], loc.lat if loc else None, loc.lon if loc else None,
                           loc.accuracy if loc else None)
    return {"public_id": beacon.public_id, "ble_id": beacon.ble_id, "ttl": nearby.BEACON_TTL, "gps": gps}


@app.delete("/nearby/beacon")
def beacon_off(user: User) -> dict:
    nearby.remove(user["id"])
    return {"ok": True}


@app.post("/nearby/discover")
def discover(body: DiscoverIn, user: Unlocked) -> dict:
    """Кто рядом принимает перевод. Найденные по Bluetooth идут первыми и помечены как подтверждённые."""
    if wait := guard.take_all([(_discover_rate, user["id"])]):
        raise slow_down(wait)
    found: dict[int, dict] = {}
    for beacon in nearby.by_ble(body.ble_ids[:MAX_BLE_IDS]):
        found[beacon.user_id] = {"public_id": beacon.public_id, "method": "bluetooth", "proximity": "close"}
    loc, gps = trusted_location(user["id"], body.location)
    if loc:
        for beacon, distance in nearby.near_by_gps(loc.lat, loc.lon, loc.accuracy):
            if beacon.user_id in found or beacon.user_id == user["id"]:
                continue
            if not _gps_people.allow(user["id"], beacon.user_id):
                continue
            # Точное расстояние не отдаём: по трём замерам из разных точек оно выдаёт, где стоит человек.
            found[beacon.user_id] = {"public_id": beacon.public_id, "method": "gps",
                                     "proximity": "close" if distance <= 25 else "near"}
    found.pop(user["id"], None)

    people = []
    for user_id, entry in found.items():
        other = db.user_by_id(user_id)
        if other:
            limit = LIMIT_BLUETOOTH if entry["method"] == "bluetooth" else LIMIT_GPS
            people.append({**entry, **public_card(other), "limit": limit})
    return {"people": people, "gps": gps, "min_amount": MIN_AMOUNT}


@app.post("/transfers")
async def transfer(body: TransferIn, user: Unlocked) -> dict:
    beacon = nearby.by_public(body.public_id)
    if not beacon:
        raise fail(404, "recipient_not_available")
    if beacon.user_id == user["id"]:
        raise fail(400, "self_transfer")
    if body.amount < MIN_AMOUNT:
        raise fail(422, "amount_too_small", min=MIN_AMOUNT)
    note = clean_note(body.note)

    # Способ подтверждения близости определяет сервер, а не клиент.
    # Клиент присылает все маяки, которые сейчас слышит по Bluetooth; какой из них чей, знает только сервер.
    loc, _ = trusted_location(user["id"], body.location)
    valid = beacon.ble_ids(nearby.clock())
    if any(hmac.compare_digest(seen, ble) for seen in body.ble_ids[:MAX_BLE_IDS] for ble in valid):
        method, limit = "bluetooth", LIMIT_BLUETOOTH
    elif loc and nearby.gps_distance(beacon, loc.lat, loc.lon, loc.accuracy) is not None:
        method, limit = "gps", LIMIT_GPS
    else:
        raise fail(403, "not_nearby")
    if body.amount > limit:
        raise fail(403, "limit_exceeded", limit=limit, method=method)

    if wait := guard.take_all([(_transfer_rate, user["id"]), (_pair_rate, (user["id"], beacon.user_id))]):
        raise slow_down(wait)

    daily = {None: DAILY_LIMIT, "gps": DAILY_LIMIT_GPS} if method == "gps" else {None: DAILY_LIMIT}
    try:
        result, created = db.make_transfer(user["id"], beacon.user_id, body.amount, method,
                                           note, body.idempotency_key, daily)
    except db.TransferError as err:
        raise fail(err.status, err.code, **err.extra) from None

    recipient = db.user_by_id(beacon.user_id)
    sender = db.user_by_id(user["id"])
    receipt = {
        "id": result["id"], "amount": result["amount"], "method": result["method"],
        "note": result["note"], "created_at": result["created_at"],
        "recipient": public_card(recipient), "balance": sender["balance"],
    }
    if created:
        hub.notify(beacon.user_id, {
            "type": "transfer_received", "id": result["id"], "amount": result["amount"],
            "method": result["method"], "note": result["note"],
            "sender": short_name(sender["full_name"]), "balance": recipient["balance"],
        })
    return receipt


@app.get("/transfers")
def transfers(user: Unlocked, limit: Annotated[int, Query(ge=1, le=100)] = 30) -> dict:
    items = []
    for row in db.history(user["id"], limit):
        outgoing = row["sender_id"] == user["id"]
        if outgoing:
            business = row["recipient_business"] if row["recipient_is_merchant"] else None
            counterparty = business or short_name(row["recipient_name"])
        else:
            counterparty = short_name(row["sender_name"])
        items.append({
            "id": row["id"], "direction": "out" if outgoing else "in", "counterparty": counterparty,
            "amount": row["amount"], "method": row["method"], "note": row["note"],
            "created_at": row["created_at"],
        })
    return {"items": items}


@app.post("/ws/ticket")
def ws_ticket(user: User) -> dict:
    return {"ticket": _tickets.put({"user_id": user["id"], "device_id": user["session_device"]}),
            "ttl": TICKET_TTL}


@app.websocket("/ws")
async def ws(sock: WebSocket, ticket: str = "") -> None:
    """Пропуск проверяется до того, как соединение принято: без него сервер сразу отвечает отказом
    и не держит открытым ни одного чужого соединения. Пропуск одноразовый и живёт 30 секунд,
    поэтому его появление в журналах адресов ничего не даёт."""
    entry = _tickets.pop(ticket) if ticket else None
    if entry is None:
        await sock.close(code=4401)
        return
    await sock.accept()
    hub.add(entry["user_id"], entry["device_id"], sock)
    await sock.send_json({"type": "ready"})
    try:
        while True:
            await sock.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        hub.remove(entry["user_id"], sock)
