from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.icloud import CalEvent
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.reminders import reminder_tools

ROME = ZoneInfo("Europe/Rome")
TOKEN = "secret-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


class Block(SimpleNamespace):
    def to_dict(self):
        return dict(vars(self))


class FakeClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    async def _create(self, **kwargs):
        stop_reason, content = self.responses.pop(0)
        return SimpleNamespace(stop_reason=stop_reason, content=content)


class FakeCalendar:
    def __init__(self, events):
        self._events = events

    def events(self, start, end):
        return self._events


def done(text):
    return ("end_turn", [Block(type="text", text=text)])


def call(name, **input):
    return ("tool_use", [Block(type="tool_use", id="t1", name=name, input=input)])


@pytest.fixture
def env():
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    def make(responses=(), events=()):
        agent = Agent(FakeClient(responses), db, ToolRegistry(reminder_tools(store, ROME)), model="m", tz=ROME)
        app = create_app(agent, store, FakeCalendar(list(events)), ROME, TOKEN)
        return TestClient(app), agent, store
    yield make
    db.close()


def test_health_needs_no_token(env):
    client, _, _ = env()
    assert client.get("/v1/health").json() == {"ok": True, "version": "0.2.0"}


@pytest.mark.parametrize("headers", [{}, {"Authorization": "Bearer wrong"}, {"Authorization": TOKEN}])
def test_bad_token_is_rejected(env, headers):
    client, _, _ = env()
    r = client.post("/v1/chat", json={"text": "hi"}, headers=headers)
    assert r.status_code == 401 and r.json() == {"error": "missing or wrong token"}


def test_chat_returns_reply_and_pending(env):
    client, agent, store = env([call("create_reminder", title="Bins"), done("ok")])
    r = client.post("/v1/chat", json={"text": "remind me bins"}, headers=AUTH)
    assert r.json() == {"reply": "ok", "pending": []}
    rem = store.open()[0]

    client2, _, _ = env([call("delete_reminder", reminder_id=rem.id), done("queued")])
    body = client2.post("/v1/chat", json={"text": "delete it"}, headers=AUTH).json()
    assert body["pending"][0]["summary"] == "Delete reminder 'Bins'"

    r = client2.post("/v1/confirm", json={}, headers=AUTH).json()
    assert r == {"result": "✓ Deleted reminder: Bins", "pending": []}
    assert store.open() == []


def test_history_shows_only_visible_text(env):
    client, _, _ = env([call("create_reminder", title="Bins"), done("Added it.")])
    client.post("/v1/chat", json={"text": "remind me bins"}, headers=AUTH)
    msgs = client.get("/v1/history", headers=AUTH).json()["messages"]
    assert [(m["role"], m["text"]) for m in msgs] == [("user", "remind me bins"), ("assistant", "Added it.")]


def test_today_lists_events_and_due_reminders(env):
    ev = CalEvent("e1", "Home", "Dentist", datetime(2026, 10, 20, 15, tzinfo=ROME), datetime(2026, 10, 20, 16, tzinfo=ROME))
    client, _, store = env(events=[ev])
    store.create("Overdue", datetime(2026, 10, 19, 9, tzinfo=ROME))
    store.create("Today", datetime(2026, 10, 20, 17, tzinfo=ROME))
    store.create("Tomorrow", datetime(2026, 10, 21, 9, tzinfo=ROME))
    store.create("Someday")
    body = client.get("/v1/today?date=2026-10-20", headers=AUTH).json()
    assert body["events"][0] == {"id": "e1", "title": "Dentist", "calendar": "Home",
                                 "start": "2026-10-20T15:00:00+02:00", "end": "2026-10-20T16:00:00+02:00",
                                 "all_day": False, "location": "", "recurring": False}
    assert [r["title"] for r in body["reminders"]] == ["Overdue", "Today"]
    assert body["reminders"][1]["due_at"] == "2026-10-20T17:00:00+02:00"


def test_shared_conversation_with_discord_key(env):
    client, agent, _ = env([done("hi")])
    client.post("/v1/chat", json={"text": "hello"}, headers=AUTH)
    assert [m["text"] for m in agent.visible_history(CONVERSATION)] == ["hello", "hi"]


# -- sync ----------------------------------------------------------------------


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


def test_first_sync_sends_server_reminders(env):
    client, _, store = env()
    store.create("Call mum", datetime(2026, 10, 20, 17, tzinfo=ROME))
    body = client.post("/v1/reminders/sync", json={"cursor": None, "changes": []}, headers=AUTH).json()
    assert body["cursor"] == "1"
    assert [r["title"] for r in body["reminders"]] == ["Call mum"]
    assert body["reminders"][0]["apple_id"] is None


def test_phone_created_reminder_gets_an_id_and_retry_is_idempotent(env):
    client, _, store = env()
    change = {"id": None, "apple_id": "apple-1", "title": "Buy milk", "modified_at": "2026-10-18T11:26:10Z"}
    first = client.post("/v1/reminders/sync", json={"changes": [change]}, headers=AUTH).json()
    rid = first["reminders"][0]["id"]
    assert rid and first["reminders"][0]["apple_id"] == "apple-1"
    again = client.post("/v1/reminders/sync", json={"changes": [change]}, headers=AUTH).json()
    assert again["reminders"][0]["id"] == rid and len(store.open()) == 1


def test_phone_attaches_apple_id_then_server_stays_quiet(env):
    client, _, store = env()
    rem = store.create("Call mum", datetime.now(timezone.utc) - timedelta(minutes=1))
    assert [r.id for r in store.unsynced_due(datetime.now(timezone.utc))] == [rem.id]
    change = {"id": rem.id, "apple_id": "apple-9", "title": "Call mum", "due_at": iso(rem.due_at),
              "modified_at": iso(datetime.now(timezone.utc))}
    client.post("/v1/reminders/sync", json={"cursor": "1", "changes": [change]}, headers=AUTH)
    assert store.get(rem.id).apple_id == "apple-9"
    assert store.unsynced_due(datetime.now(timezone.utc)) == []  # Apple alerts now, not Discord


def test_newer_edit_wins_and_older_edit_loses(env):
    client, _, store = env()
    rem = store.create("Old title")
    newer = {"id": rem.id, "title": "Phone title", "modified_at": iso(rem.modified_at + timedelta(minutes=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [newer]}, headers=AUTH).json()
    assert body["reminders"][0]["title"] == "Phone title"
    older = {"id": rem.id, "title": "Stale title", "modified_at": iso(rem.modified_at - timedelta(minutes=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [older]}, headers=AUTH).json()
    assert body["reminders"][0]["title"] == "Phone title"  # final form sent back so the phone corrects itself


def test_deletion_beats_a_newer_edit(env):
    client, _, store = env()
    rem = store.create("x")
    store.delete(rem.id)
    edit = {"id": rem.id, "title": "edited later", "modified_at": iso(datetime.now(timezone.utc) + timedelta(hours=1))}
    body = client.post("/v1/reminders/sync", json={"changes": [edit]}, headers=AUTH).json()
    assert body["reminders"][0]["deleted"] is True


def test_cursor_only_returns_newer_changes(env):
    client, _, store = env()
    store.create("a")
    cursor = client.post("/v1/reminders/sync", json={}, headers=AUTH).json()["cursor"]
    store.create("b")
    body = client.post("/v1/reminders/sync", json={"cursor": cursor}, headers=AUTH).json()
    assert [r["title"] for r in body["reminders"]] == ["b"]


def test_bad_cursor_and_naive_time_are_400(env):
    client, _, _ = env()
    assert client.post("/v1/reminders/sync", json={"cursor": "abc"}, headers=AUTH).status_code == 400
    naive = {"id": None, "title": "x", "modified_at": "2026-10-18T11:00:00"}
    r = client.post("/v1/reminders/sync", json={"changes": [naive]}, headers=AUTH)
    assert r.status_code == 400 and "offset" in r.json()["error"]


# -- Discord fallback ----------------------------------------------------------


async def test_fallback_notifies_once_and_retries_failures(monkeypatch):
    import asyncio
    from aide import scheduler
    db = Database(":memory:")
    store = ReminderStore(db.conn)
    store.create("Pills", datetime.now(timezone.utc) - timedelta(hours=1))
    sent, results = [], [False, True]

    async def notify(text):
        sent.append(text)
        return results.pop(0) if results else True

    monkeypatch.setattr(scheduler, "TICK", 0)
    task = asyncio.create_task(scheduler.reminder_fallback(store, notify, ROME))
    for _ in range(20):
        await asyncio.sleep(0)
    task.cancel()
    assert len(sent) == 2  # first DM failed, retried once, then marked sent
    assert sent[0].startswith("⏰ Pills") and "late" in sent[0]
