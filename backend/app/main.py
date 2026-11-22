"""Qasynda — сервер переводов «рядом» (Bluetooth + GPS). Учебный прототип, деньги синтетические."""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import os
import re
import secrets
import time
import unicodedata
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import db, guard, nearby

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

# Вход: 5 неудачных попыток на номер за 5 минут и 15 за сутки. С 4-значным PIN это больше года
# перебора на один номер. Попытка записывается до проверки PIN — параллельные запросы лимит не обходят.
LOGIN_ATTEMPTS = 5
_login_short = guard.Window(LOGIN_ATTEMPTS, 300)
_login_long = guard.Window(15, 24 * 3600)
# Перебор одного PIN по многим номерам ограничивается по адресу клиента — если сервер знает его настоящий адрес.
_login_ip = guard.Window(50, 600)
IP_HEADER = os.environ.get("QASYNDA_IP_HEADER", "").strip().lower()

_discover_rate = guard.Window(40, 60)        # приложение спрашивает раз в 2 секунды — 30 в минуту
_beacon_rate = guard.Window(12, 60)          # приложение продлевает маяк раз в 15 секунд
_gps_people = guard.Distinct(30, 3600)       # столько разных людей по GPS можно увидеть за час
_transfer_rate = guard.Window(10, 60)
_pair_rate = guard.Window(3, 600)            # одному и тому же получателю

HexId = Annotated[str, Field(pattern=r"^[0-9a-f]{16}$")]


class Location(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)
    accuracy: float = Field(ge=0, le=10_000)


class LoginIn(BaseModel):
    phone: str = Field(pattern=r"^\+7\d{10}$")
    pin: str = Field(pattern=r"^\d{4,6}$")


class BeaconIn(BaseModel):
    location: Location | None = None


class DiscoverIn(BaseModel):
    location: Location | None = None
    ble_ids: list[HexId] = Field(default_factory=list, max_length=50)


class TransferIn(BaseModel):
    public_id: HexId
    ble_ids: list[HexId] = Field(default_factory=list, max_length=50)
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
    """Открытые WebSocket-соединения по пользователям: мгновенное уведомление о переводе."""

    MAX_PER_USER = 3
    SEND_TIMEOUT = 2.0

    def __init__(self) -> None:
        self._sockets: dict[int, list[WebSocket]] = {}
        self._tasks: set[asyncio.Task] = set()

    def add(self, user_id: int, sock: WebSocket) -> None:
        sockets = self._sockets.setdefault(user_id, [])
        sockets.append(sock)
        while len(sockets) > self.MAX_PER_USER:
            self._spawn(self._close(sockets.pop(0)))

    def remove(self, user_id: int, sock: WebSocket) -> None:
        sockets = self._sockets.get(user_id)
        if sockets and sock in sockets:
            sockets.remove(sock)
            if not sockets:
                del self._sockets[user_id]

    def notify(self, user_id: int, event: dict) -> None:
        """Отправляет в фоне: медленный получатель не задерживает ответ отправителю."""
        for sock in list(self._sockets.get(user_id, ())):
            self._spawn(self._send(user_id, sock, event))

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

# Одноразовые пропуска для WebSocket: выдаются по токену сессии, живут 30 секунд, хранятся хешами.
TICKET_TTL = 30.0
_tickets: dict[str, tuple[int, float]] = {}


def _ticket_hash(ticket: str) -> str:
    return hashlib.sha256(ticket.encode()).hexdigest()


def issue_ticket(user_id: int) -> str:
    now = time.monotonic()
    for h in [h for h, (_, exp) in _tickets.items() if exp <= now]:
        _tickets.pop(h, None)
    ticket = secrets.token_urlsafe(24)
    _tickets[_ticket_hash(ticket)] = (user_id, now + TICKET_TTL)
    return ticket


def redeem_ticket(ticket: str) -> int | None:
    entry = _tickets.pop(_ticket_hash(ticket), None) if ticket else None
    if entry is None or entry[1] <= time.monotonic():
        return None
    return entry[0]


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.init()
    if os.environ.get("QASYNDA_SEED_DEMO") == "1":
        db.seed_demo()
    yield


app = FastAPI(title="Qasynda", lifespan=lifespan)

_origins = [o.strip() for o in os.environ.get("QASYNDA_CORS_ORIGINS", "").split(",") if o.strip()]
if _origins:
    app.add_middleware(CORSMiddleware, allow_origins=_origins,
                       allow_methods=["GET", "POST", "DELETE"],
                       allow_headers=["Authorization", "Content-Type"])


def fail(status: int, code: str, **extra) -> HTTPException:
    return HTTPException(status, detail={"code": code, **extra})


def slow_down(wait: float) -> HTTPException:
    return HTTPException(429, detail={"code": "slow_down", "retry_after": int(wait) + 1},
                         headers={"Retry-After": str(int(wait) + 1)})


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


def client_ip(request: Request) -> str | None:
    """Адрес клиента для ограничения входа. За прокси сокет показывает адрес прокси, а X-Forwarded-For
    клиент может подделать, поэтому заголовок с настоящим адресом задаётся явно (QASYNDA_IP_HEADER)."""
    if IP_HEADER:
        value = request.headers.get(IP_HEADER, "").split(",")[0].strip()
        return value or None
    return request.client.host if request.client else None


def trusted_location(user_id: int, loc: Location | None) -> tuple[Location | None, str]:
    if loc is None:
        return None, "off"
    if not nearby.plausible(user_id, loc.lat, loc.lon, loc.accuracy):
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
    gates: list[tuple[guard.Window, object]] = [(_login_short, body.phone), (_login_long, body.phone)]
    ip = client_ip(request)
    if ip:
        gates.append((_login_ip, ip))
    wait = guard.take_all(gates)
    if wait:
        raise HTTPException(429, detail={"code": "too_many_attempts", "retry_after": int(wait) + 1},
                            headers={"Retry-After": str(int(wait) + 1)})
    token = db.login(body.phone, body.pin)
    if not token:
        raise fail(401, "invalid_credentials")
    _login_short.clear(body.phone)
    _login_long.refund(body.phone)
    if ip:
        _login_ip.refund(ip)
    return {"token": token}


@app.post("/auth/logout")
def logout(user: User, authorization: Annotated[str | None, Header()] = None) -> dict:
    nearby.remove(user["id"])
    db.logout(_bearer(authorization))
    return {"ok": True}


@app.get("/me")
def me(user: User) -> dict:
    return profile(user)


@app.post("/nearby/beacon")
def beacon_on(body: BeaconIn, user: User) -> dict:
    """Экран «Принять рядом» открыт. Клиент повторяет запрос каждые ~15 секунд, пока экран открыт."""
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
def discover(body: DiscoverIn, user: User) -> dict:
    """Кто рядом принимает перевод. Найденные по Bluetooth идут первыми и помечены как подтверждённые."""
    if wait := guard.take_all([(_discover_rate, user["id"])]):
        raise slow_down(wait)
    found: dict[int, dict] = {}
    for beacon in nearby.by_ble(body.ble_ids):
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
async def transfer(body: TransferIn, user: User) -> dict:
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
    if any(hmac.compare_digest(seen, beacon.ble_id) for seen in body.ble_ids):
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
def transfers(user: User, limit: Annotated[int, Query(ge=1, le=100)] = 30) -> dict:
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
    return {"ticket": issue_ticket(user["id"]), "ttl": TICKET_TTL}


@app.websocket("/ws")
async def ws(sock: WebSocket, ticket: str = "") -> None:
    """Пропуск проверяется до того, как соединение принято: без него сервер сразу отвечает отказом
    и не держит открытым ни одного чужого соединения. Пропуск одноразовый и живёт 30 секунд,
    поэтому его появление в журналах адресов ничего не даёт."""
    user_id = redeem_ticket(ticket)
    if user_id is None:
        await sock.close(code=4401)
        return
    await sock.accept()
    hub.add(user_id, sock)
    await sock.send_json({"type": "ready"})
    try:
        while True:
            await sock.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        hub.remove(user_id, sock)
