import asyncio
import json
from datetime import date, datetime, timedelta, timezone

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from aide import digest as digest_mod
from aide import push as push_mod
from aide import scheduler
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.digest import DigestService
from aide.habits import HabitStore
from aide.push import Push
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools
from test_api import AUTH, ROME, TOKEN, FakeClient, call, done

SANDBOX = "a1" * 32
PROD = "b2" * 32


class APNs:
    """Fake APNs: records every request and answers from `replies` (token -> (status, reason))."""

    def __init__(self):
        self.requests: list[httpx.Request] = []
        self.replies: dict[str, tuple[int, str]] = {}

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        status, reason = self.replies.get(request.url.path.rsplit("/", 1)[1], (200, ""))
        return httpx.Response(status, json={"reason": reason} if reason else None)

    def payloads(self) -> list[dict]:
        return [json.loads(r.content) for r in self.requests]


@pytest.fixture
def key(tmp_path):
    private = ec.generate_private_key(ec.SECP256R1())
    path = tmp_path / "AuthKey_TEST.p8"
    path.write_bytes(private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                           serialization.NoEncryption()))
    return path, private.public_key()


@pytest.fixture
def env(key):
    db = Database(":memory:")
    apns = APNs()
    push = Push(db.conn, key[0], "KEY123", "TEAM456", "com.filippocappa.aide", httpx.MockTransport(apns.handle))
    yield db, push, apns
    db.close()


async def test_headers_payload_and_jwt(env, key):
    _, push, apns = env
    push.register(SANDBOX, "sandbox", "Phone")
    assert await push.send_reminder("r1", "Bins")
    [r] = apns.requests
    assert str(r.url) == f"https://api.sandbox.push.apple.com/3/device/{SANDBOX}"
    assert (r.headers["apns-topic"], r.headers["apns-push-type"], r.headers["apns-priority"]) == (
        "com.filippocappa.aide", "alert", "10")
    scheme, _, token = r.headers["authorization"].partition(" ")
    assert scheme == "bearer"
    assert jwt.get_unverified_header(token) == {"alg": "ES256", "kid": "KEY123", "typ": "JWT"}
    assert jwt.decode(token, key[1], algorithms=["ES256"])["iss"] == "TEAM456"
    assert apns.payloads() == [{"aps": {"alert": {"title": "Bins", "body": ""}, "sound": "default",
                                        "thread-id": "reminder"}, "aide": {"kind": "reminder", "reminder_id": "r1"}}]
    assert push.devices()[0]["last_push_at"] is not None


async def test_jwt_is_reused_then_renewed(env, monkeypatch):
    _, push, apns = env
    push.register(SANDBOX, "sandbox")
    clock = [1_000_000.0]
    monkeypatch.setattr(push_mod.time, "time", lambda: clock[0])
    for _ in range(2):
        await push.send_test()
    clock[0] += push_mod.JWT_TTL + 1
    await push.send_test()
    tokens = [r.headers["authorization"] for r in apns.requests]
    assert tokens[0] == tokens[1] != tokens[2]


async def test_host_follows_each_devices_environment(env):
    _, push, apns = env
    push.register(SANDBOX, "sandbox")
    push.register(PROD.upper(), "production")
    assert await push.send_test() == (2, 0)
    assert {r.url.host for r in apns.requests} == {"api.sandbox.push.apple.com", "api.push.apple.com"}
    assert [r.url.path for r in apns.requests if r.url.host == "api.push.apple.com"] == [f"/3/device/{PROD}"]


async def test_invalid_tokens_are_removed(env):
    _, push, apns = env
    for t in (SANDBOX, PROD, "c3" * 32):
        push.register(t, "sandbox")
    apns.replies = {SANDBOX: (410, "Unregistered"), PROD: (400, "BadDeviceToken"), "c3" * 32: (429, "TooManyRequests")}
    assert await push.send_test() == (0, 3)
    # throttled, not invalid: kept; BadDeviceToken may only be the wrong APNs host for this build: kept
    assert [d["token"] for d in push.devices()] == [PROD, "c3" * 32]


async def test_digest_and_message_payloads(env):
    _, push, apns = env
    push.register(SANDBOX, "sandbox")
    await push.send_digest("daily", "Two meetings today.")
    await push.send_digest("weekly", "Busy week.")
    await push.send_digest("monthly", "New month.", date(2026, 11, 1))
    await push.send_message("c_1", "Leave now", "Traffic on the A4.")
    await push.send_message("c_2", "Coach · Weekly recap", "Good week.", routine=3)
    p = apns.payloads()
    assert p[0] == {"aps": {"alert": {"title": "Morning", "body": "Two meetings today."}, "sound": "default",
                            "thread-id": "digest"}, "aide": {"kind": "digest", "digest": "daily"}}
    assert [x["aps"]["alert"]["title"] for x in p] == ["Morning", "This week", "November", "Leave now",
                                                         "Coach · Weekly recap"]
    assert p[3]["aide"] == {"kind": "message", "conversation_id": "c_1"} and p[3]["aps"]["thread-id"] == "message"
    assert p[4]["aide"] == {"kind": "message", "conversation_id": "c_2", "routine": 3}


async def test_no_key_means_push_off(tmp_path):
    db = Database(":memory:")
    apns = APNs()
    push = Push(db.conn, None, None, None, "com.filippocappa.aide", httpx.MockTransport(apns.handle))
    push.register(SANDBOX, "sandbox")
    assert not push.enabled
    assert not await push.send_reminder("r1", "Bins")
    push.request_sync()
    assert await push.send_test() == (0, 1) and apns.requests == []
    missing = Push(db.conn, tmp_path / "nope.p8", "K", "T", "com.filippocappa.aide")
    assert not missing.enabled


async def test_sync_pushes_are_coalesced(env, monkeypatch):
    db, push, apns = env
    monkeypatch.setattr(push_mod, "SYNC_EVERY", 0.05)
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    store.on_change.append(push.request_sync)
    store.create("first")
    await asyncio.sleep(0.01)
    assert len(apns.requests) == 1  # the first change goes out at once
    for i in range(5):  # a burst within the quiet time
        store.create(f"r{i}")
    await asyncio.sleep(0.01)
    assert len(apns.requests) == 1
    r = apns.requests[0]
    assert (r.headers["apns-push-type"], r.headers["apns-priority"]) == ("background", "5")
    assert apns.payloads() == [{"aps": {"content-available": 1}, "aide": {"kind": "sync"}}]
    await asyncio.sleep(0.1)
    assert len(apns.requests) == 2  # the rest of the burst: one more, after the quiet time
    await asyncio.sleep(0.1)
    assert len(apns.requests) == 2


async def test_phone_sync_does_not_trigger_a_sync_push(env):
    db, push, apns = env
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    store.on_change.append(push.request_sync)
    now = datetime.now(timezone.utc).isoformat()
    store.sync(None, [{"apple_id": "A1", "title": "From phone", "modified_at": now}])
    await asyncio.sleep(0.01)
    assert apns.requests == []
    tools = {t.name: t for t in reminder_tools(store, ROME)}
    await tools["create_reminder"].handler(title="From chat")
    await asyncio.sleep(0.01)
    assert [p["aide"]["kind"] for p in apns.payloads()] == ["sync"]


# -- reminder fallback ---------------------------------------------------------


async def run_fallback(store, push, monkeypatch):
    monkeypatch.setattr(scheduler, "TICK", 0)
    task = asyncio.create_task(scheduler.reminder_fallback(store, ROME, push))
    for _ in range(20):
        await asyncio.sleep(0)
    task.cancel()


async def test_due_reminder_is_pushed(env, monkeypatch):
    db, push, apns = env
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    rem = store.create("Bins", datetime.now(timezone.utc) - timedelta(minutes=1))
    late = store.create("Pills", datetime(2026, 10, 19, 7, 30, tzinfo=timezone.utc))
    await run_fallback(store, push, monkeypatch)
    assert [p["aide"] for p in apns.payloads()] == [{"kind": "reminder", "reminder_id": late.id},
                                                    {"kind": "reminder", "reminder_id": rem.id}]
    assert [p["aps"]["alert"]["body"] for p in apns.payloads()] == ["Late: was due Mon 19 Oct 09:30", ""]
    assert store.unsynced_due(datetime.now(timezone.utc)) == []


async def test_a_push_that_fails_is_tried_once(env, monkeypatch):
    db, push, apns = env
    store = ReminderStore(db.conn)
    store.create("Bins", datetime.now(timezone.utc) - timedelta(minutes=1))
    await run_fallback(store, push, monkeypatch)  # no devices
    push.register(SANDBOX, "sandbox")
    apns.replies = {SANDBOX: (400, "BadDeviceToken")}
    store.create("Pills", datetime.now(timezone.utc) - timedelta(hours=1))
    await run_fallback(store, push, monkeypatch)
    assert len(apns.requests) == 1  # Bins was already given up on; Pills tried once
    assert store.unsynced_due(datetime.now(timezone.utc)) == []


async def test_a_push_that_can_pass_is_tried_again(env, monkeypatch):
    db, push, apns = env
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    rem = store.create("Bins", datetime.now(timezone.utc) - timedelta(minutes=1))
    apns.replies = {SANDBOX: (503, "ServiceUnavailable")}
    await run_fallback(store, push, monkeypatch)
    assert len(apns.requests) > 1  # every tick
    assert [r.id for r in store.unsynced_due(datetime.now(timezone.utc))] == [rem.id]
    apns.replies = {}
    await run_fallback(store, push, monkeypatch)
    assert apns.payloads()[-1]["aide"] == {"kind": "reminder", "reminder_id": rem.id}
    assert store.unsynced_due(datetime.now(timezone.utc)) == []


async def test_retries_stop_after_a_while(env, monkeypatch):
    db, push, apns = env
    monkeypatch.setattr(scheduler, "RETRY_FOR", timedelta(0))
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    store.create("Bins", datetime.now(timezone.utc) - timedelta(minutes=1))
    apns.replies = {SANDBOX: (429, "TooManyRequests")}
    await run_fallback(store, push, monkeypatch)
    assert len(apns.requests) == 1
    assert store.unsynced_due(datetime.now(timezone.utc)) == []


async def test_send_reminder_says_when_to_try_again(env):
    _, push, apns = env
    push.register(SANDBOX, "sandbox")
    push.register(PROD, "production")
    apns.replies = {SANDBOX: (500, ""), PROD: (429, "TooManyRequests")}
    assert await push.send_reminder("r1", "Bins") is None
    apns.replies = {SANDBOX: (500, ""), PROD: (400, "BadDeviceToken")}
    assert await push.send_reminder("r1", "Bins") is False  # one of them was refused for good
    apns.replies = {SANDBOX: (500, "")}
    assert await push.send_reminder("r1", "Bins") is True  # the other went out


# -- digest ----------------------------------------------------------------------


async def test_scheduled_digest_is_pushed(env, monkeypatch):
    db, push, apns = env
    push.register(SANDBOX, "sandbox")
    store = ReminderStore(db.conn)
    service = DigestService(db.conn, FakeClient([done("Hello.\n---\n- ahead")]), "m", ROME, store,
                            HabitStore(db.conn, ROME), None)
    now = datetime.now(ROME)
    off = {"enabled": False, "time": "00:00"}
    service.save_settings({"daily": {"enabled": True, "time": f"{now - timedelta(minutes=1):%H:%M}"}, "evening": off,
                           "weekly": {**off, "weekday": 1}, "monthly": {**off, "day": 1}})
    monkeypatch.setattr(digest_mod, "TICK", 0)
    task = asyncio.create_task(digest_mod.digest_schedule(service, push))
    for _ in range(50):
        await asyncio.sleep(0)
    task.cancel()
    assert apns.payloads() == [{"aps": {"alert": {"title": "Morning", "body": "Hello."}, "sound": "default",
                                        "thread-id": "digest"}, "aide": {"kind": "digest", "digest": "daily"}}]


# -- API -----------------------------------------------------------------------


def test_devices_api(env):
    db, push, apns = env
    store = ReminderStore(db.conn)
    agent = Agent(FakeClient([]), db, ToolRegistry(reminder_tools(store, ROME)), model="m", tz=ROME)
    client = TestClient(create_app(agent, store, None, ROME, TOKEN, push=push))
    body = {"token": SANDBOX.upper(), "environment": "sandbox", "name": "My iPhone"}
    assert client.post("/v1/devices", json=body, headers=AUTH).json() == {"ok": True}
    assert client.post("/v1/devices", json={**body, "name": "iPhone"}, headers=AUTH).json() == {"ok": True}
    [d] = client.get("/v1/devices", headers=AUTH).json()["devices"]
    assert (d["token"], d["environment"], d["name"], d["last_push_at"]) == (SANDBOX, "sandbox", "iPhone", None)
    assert d["registered_at"].endswith(("+01:00", "+02:00"))
    assert client.post("/v1/devices/test", json={}, headers=AUTH).json() == {"sent": 1, "failed": 0}
    assert apns.payloads()[0]["aide"] == {"kind": "test"}
    assert client.get("/v1/devices", headers=AUTH).json()["devices"][0]["last_push_at"] is not None
    for bad in ({**body, "environment": "dev"}, {**body, "token": "xyz"}, {"environment": "sandbox"}):
        assert client.post("/v1/devices", json=bad, headers=AUTH).status_code == 400
    assert client.delete(f"/v1/devices/{SANDBOX}", headers=AUTH).json() == {"ok": True}
    assert client.delete(f"/v1/devices/{SANDBOX}", headers=AUTH).json() == {"ok": True}
    assert client.get("/v1/devices", headers=AUTH).json() == {"devices": []}
    assert client.get("/v1/devices").status_code == 401
