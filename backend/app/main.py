"""Qasynda — сервер переводов «рядом» (Bluetooth + GPS). Учебный прототип, деньги синтетические."""
from __future__ import annotations

import asyncio
import hmac
import os
import time
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import db, nearby

# Лимит одного перевода в тиынах. Близость по Bluetooth подделать труднее, чем координаты,
# поэтому перевод только по GPS ограничен жёстче.
LIMIT_BLUETOOTH = 500_000_00
LIMIT_GPS = 50_000_00

LOGIN_ATTEMPTS = 5
LOGIN_WINDOW = 300.0
_login_failures: dict[str, list[float]] = {}

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
    note: str | None = Field(default=None, max_length=140)


class Hub:
    """Открытые WebSocket-соединения по пользователям: мгновенное уведомление о переводе."""

    def __init__(self) -> None:
        self._sockets: dict[int, set[WebSocket]] = {}

    def add(self, user_id: int, sock: WebSocket) -> None:
        self._sockets.setdefault(user_id, set()).add(sock)

    def remove(self, user_id: int, sock: WebSocket) -> None:
        sockets = self._sockets.get(user_id)
        if sockets:
            sockets.discard(sock)
            if not sockets:
                del self._sockets[user_id]

    async def send(self, user_id: int, event: dict) -> None:
        for sock in list(self._sockets.get(user_id, ())):
            try:
                await sock.send_json(event)
            except Exception:
                self.remove(user_id, sock)


hub = Hub()


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


def short_name(full_name: str) -> str:
    """«Айгерим Касымова» → «Айгерим К.»: посторонний рядом не видит фамилию целиком."""
    parts = full_name.split()
    return parts[0] if len(parts) < 2 else f"{parts[0]} {parts[1][0]}."


def profile(user: dict) -> dict:
    return {
        "name": user["full_name"], "phone": user["phone"], "balance": user["balance"],
        "is_merchant": bool(user["is_merchant"]), "business_name": user["business_name"],
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
def login(body: LoginIn) -> dict:
    now = time.monotonic()
    recent = [t for t in _login_failures.get(body.phone, []) if now - t < LOGIN_WINDOW]
    if len(recent) >= LOGIN_ATTEMPTS:
        raise fail(429, "too_many_attempts")
    token = db.login(body.phone, body.pin)
    if not token:
        _login_failures[body.phone] = recent + [now]
        raise fail(401, "invalid_credentials")
    _login_failures.pop(body.phone, None)
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
    loc = body.location
    beacon = nearby.upsert(user["id"], loc.lat if loc else None, loc.lon if loc else None,
                           loc.accuracy if loc else None)
    return {"public_id": beacon.public_id, "ble_id": beacon.ble_id, "ttl": nearby.BEACON_TTL}


@app.delete("/nearby/beacon")
def beacon_off(user: User) -> dict:
    nearby.remove(user["id"])
    return {"ok": True}


@app.post("/nearby/discover")
def discover(body: DiscoverIn, user: User) -> dict:
    """Кто рядом принимает перевод. Найденные по Bluetooth идут первыми и помечены как подтверждённые."""
    found: dict[int, dict] = {}
    for beacon in nearby.by_ble(body.ble_ids):
        found[beacon.user_id] = {"public_id": beacon.public_id, "method": "bluetooth", "distance_m": None}
    if body.location:
        loc = body.location
        for beacon, distance in nearby.near_by_gps(loc.lat, loc.lon, loc.accuracy):
            # Расстояние округляем до 10 м: точное положение человека не раскрываем.
            found.setdefault(beacon.user_id, {"public_id": beacon.public_id, "method": "gps",
                                              "distance_m": int(round(distance, -1))})
    found.pop(user["id"], None)

    people = []
    for user_id, entry in found.items():
        other = db.user_by_id(user_id)
        if other:
            limit = LIMIT_BLUETOOTH if entry["method"] == "bluetooth" else LIMIT_GPS
            people.append({**entry, **public_card(other), "limit": limit})
    return {"people": people}


@app.post("/transfers")
async def transfer(body: TransferIn, user: User) -> dict:
    beacon = nearby.by_public(body.public_id)
    if not beacon:
        raise fail(404, "recipient_not_available")
    if beacon.user_id == user["id"]:
        raise fail(400, "self_transfer")

    # Способ подтверждения близости определяет сервер, а не клиент.
    # Клиент присылает все маяки, которые сейчас слышит по Bluetooth; какой из них чей, знает только сервер.
    if any(hmac.compare_digest(seen, beacon.ble_id) for seen in body.ble_ids):
        method, limit = "bluetooth", LIMIT_BLUETOOTH
    elif body.location and nearby.gps_distance(
            beacon, body.location.lat, body.location.lon, body.location.accuracy) is not None:
        method, limit = "gps", LIMIT_GPS
    else:
        raise fail(403, "not_nearby")
    if body.amount > limit:
        raise fail(403, "limit_exceeded", limit=limit, method=method)

    try:
        result, created = db.make_transfer(user["id"], beacon.user_id, body.amount, method,
                                           body.note, body.idempotency_key)
    except db.TransferError as err:
        raise fail(409, err.code) from None

    recipient = db.user_by_id(beacon.user_id)
    sender = db.user_by_id(user["id"])
    receipt = {
        "id": result["id"], "amount": result["amount"], "method": result["method"],
        "note": result["note"], "created_at": result["created_at"],
        "recipient": public_card(recipient), "balance": sender["balance"],
    }
    if created:
        await hub.send(beacon.user_id, {
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


@app.websocket("/ws")
async def ws(sock: WebSocket) -> None:
    """Токен приходит первым сообщением, а не в адресе: адреса попадают в журналы."""
    await sock.accept()
    try:
        hello = await asyncio.wait_for(sock.receive_json(), timeout=5)
        token = hello.get("token", "") if isinstance(hello, dict) else ""
        user = db.user_by_token(token if isinstance(token, str) else "")
    except Exception:
        user = None
    if not user:
        await sock.close(code=4401)
        return

    hub.add(user["id"], sock)
    await sock.send_json({"type": "ready"})
    try:
        while True:
            await sock.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        hub.remove(user["id"], sock)
