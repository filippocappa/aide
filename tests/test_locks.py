import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.agents import AGENTS, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.locks import LockStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.locks import lock_tools
from test_agents import AUTH, ROME, FakeClient


def at(text: str) -> datetime:
    """A Rome wall-clock time, as UTC."""
    return datetime.fromisoformat(text).replace(tzinfo=ROME).astimezone(timezone.utc)


@pytest.fixture
def store():
    db = Database(":memory:")
    yield LockStore(db.conn, ROME)
    db.close()


def test_overnight_schedule_on_its_days(store):
    # 2026-10-27 is a Tuesday. Bedtime starts on weeknights (Sun–Thu) and ends the next morning.
    lock = store.schedule("Bedtime", "23:00", "07:00", [7, 1, 2, 3, 4], now=at("2026-10-27T12:00"))
    assert store.locked_until(lock, at("2026-10-27T22:59")) is None
    assert store.locked_until(lock, at("2026-10-27T23:30")) == at("2026-10-28T07:00")
    assert store.locked_until(lock, at("2026-10-28T06:59")) == at("2026-10-28T07:00")  # Tuesday night's, on Wednesday
    assert store.locked_until(lock, at("2026-10-28T07:00")) is None
    # Friday night isn't one of them, but Thursday night still runs into Friday morning.
    assert store.locked_until(lock, at("2026-10-30T06:00")) == at("2026-10-30T07:00")
    assert store.locked_until(lock, at("2026-10-30T23:30")) is None
    assert store.next_start(lock, at("2026-10-30T12:00")) == at("2026-11-01T23:00")  # Sunday


def test_one_off_lengths(store):
    now = at("2026-10-27T15:00")
    with pytest.raises(ValueError, match="15 minutes"):
        store.lock_for("Focus", minutes=10, now=now)
    with pytest.raises(ValueError, match="24 hours"):
        store.lock_for("Focus", minutes=25 * 60, now=now)
    with pytest.raises(ValueError, match="15 minutes"):
        store.schedule("Nap", "14:00", "14:10")
    with pytest.raises(ValueError, match="same time"):
        store.schedule("Always", "14:00", "14:00")
    lock = store.lock_for("Focus", minutes=60, now=now)
    assert store.locked_until(lock, now) == at("2026-10-27T16:00")
    assert store.as_json(lock, now)["locked"] is True
    assert store.all(at("2026-10-27T16:00")) == []  # gone once over


def test_unlock_needs_a_reason_and_opens_until_the_end(store):
    lock = store.schedule("Bedtime", "23:00", "07:00", [])
    night = at("2026-10-27T23:30")
    with pytest.raises(ValueError, match="reason"):
        store.unlock(lock["id"], "  ", now=night)
    with pytest.raises(ValueError, match="isn't on"):
        store.unlock(lock["id"], "call", now=at("2026-10-27T20:00"))
    opened = store.unlock(lock["id"], "a call with my sister", now=night)
    assert store.locked_until(opened, night) is None
    assert store.as_json(opened, night)["open_until"] == "2026-10-28T07:00:00+01:00"
    assert store.locked_until(opened, at("2026-10-28T23:30")) is not None  # back the next night
    assert [u["reason"] for u in store.unlocks(night - timedelta(days=1))] == ["a call with my sister"]

    once = store.lock_for("Focus", minutes=60, now=night)
    assert store.unlock(once["id"], "done early", now=night) is None
    assert [lock["title"] for lock in store.all(night)] == ["Bedtime"]


def test_a_lock_on_now_cant_be_moved_or_turned_off(store):
    lock = store.schedule("Bedtime", "23:00", "07:00", [])
    night = at("2026-10-27T23:30")
    with pytest.raises(ValueError, match="on now"):
        store.update(lock["id"], now=night, enabled=False)
    with pytest.raises(ValueError, match="on now"):
        store.update(lock["id"], now=night, start_time="01:00")
    assert store.update(lock["id"], now=night, title="Sleep")["title"] == "Sleep"
    assert store.update(lock["id"], now=at("2026-10-27T12:00"), start_time="22:30")["start_time"] == "22:30"


def test_changes_ask_for_a_sync(store):
    synced = []
    store.on_change.append(lambda: synced.append(1))
    lock = store.schedule("Bedtime", "23:00", "07:00", [])
    store.update(lock["id"], title="Sleep")
    store.delete(lock["id"])
    assert len(synced) == 3


def test_tools_queue_ending_and_deleting(store):
    tools = {t.name: t for t in lock_tools(store, ROME)}
    assert tools["end_lock"].confirm and tools["delete_lock"].confirm
    assert not tools["lock_now"].confirm
    assert set(tools) <= set(AGENTS["coach"].tools)
    screen = next(c for c in connectors(list(AGENTS["coach"].tools)) if c["id"] == "screen_time")
    assert not screen["read_only"]

    text = asyncio.run(tools["lock_now"].handler(title="Focus", minutes=45))
    assert text.startswith("Locked: [1] Focus") and "on now" in text and "set by Coach" in text
    listed = asyncio.run(tools["list_locks"].handler())
    assert "hasn't allowed Screen Time" in listed
    summary = asyncio.run(tools["end_lock"].describe(lock_id=1, reason="done"))
    assert "End 'Focus' early" in summary and "Reason: done" in summary


@pytest.fixture
def client():
    db = Database(":memory:")
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    yield TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t"))
    db.close()


def test_api(client):
    made = client.post("/v1/locks", json={"title": "Focus", "minutes": 30}, headers=AUTH).json()
    assert made["once"] and made["locked"] and made["until"]
    bed = client.post("/v1/locks", json={"title": "Bedtime", "start": "23:00", "end": "07:00", "days": []},
                      headers=AUTH).json()
    assert bed["summary"] == "Every day 23:00–07:00" and bed["start"] == "23:00" and not bed["once"]
    assert client.post("/v1/locks", json={"title": "x"}, headers=AUTH).status_code == 400

    assert client.patch(f"/v1/locks/{bed['id']}", json={"days": [1, 2, 3, 4, 5]},
                        headers=AUTH).json()["summary"] == "Mon–Fri 23:00–07:00"
    assert client.post(f"/v1/locks/{made['id']}/unlock", json={"reason": "finished"},
                       headers=AUTH).json() == {"lock": None}

    client.put("/v1/locks/device", json={"authorized": True, "allowed_apps": 3}, headers=AUTH)
    got = client.get("/v1/locks", headers=AUTH).json()
    assert [lock["title"] for lock in got["locks"]] == ["Bedtime"]
    assert got["device"]["authorized"] and got["device"]["allowed_apps"] == 3
    feed = client.get("/v1/activity", headers=AUTH).json()
    assert any(item["title"] == "You unlocked 'Focus' early" for item in feed["items"])

    assert client.delete(f"/v1/locks/{bed['id']}", headers=AUTH).json() == {"ok": True}
    assert client.delete(f"/v1/locks/{bed['id']}", headers=AUTH).status_code == 404
