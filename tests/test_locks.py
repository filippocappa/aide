import asyncio
from datetime import date, datetime, timedelta, timezone

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


def test_a_strict_lock_ends_only_with_a_pass(store):
    now = at("2026-10-27T23:30")
    bed = store.schedule("Bedtime", "23:00", "07:00", [], strict=True)
    assert store.as_json(bed, now)["strict"] and "strict" in store.line(bed, now)
    with pytest.raises(ValueError, match="only an emergency pass"):
        store.unlock(bed["id"], "bored", now=now)
    with pytest.raises(ValueError, match="is on now"):
        store.update(bed["id"], now=now, strict=False)  # loosening it is unlocking
    with pytest.raises(ValueError, match="strict and on now"):
        store.delete(bed["id"], now=now)

    # Three a month: the fourth is refused, and they come back on the 1st.
    for day in (27, 28, 29):
        night = at(f"2026-10-{day}T23:30")
        store.unlock(bed["id"], "my sister called", use_pass=True, now=night)
    passes = store.passes(at("2026-10-30T23:30"))
    assert passes["left"] == 0 and len(passes["used"]) == 3 and passes["renews"] == "2026-11-01"
    with pytest.raises(ValueError, match="no emergency passes left"):
        store.unlock(bed["id"], "again", use_pass=True, now=at("2026-10-30T23:30"))
    assert store.passes(at("2026-11-01T23:30"))["left"] == 3

    # A pass isn't spent on a lock that isn't strict; making one strict while it's on is fine.
    focus = store.lock_for("Focus", minutes=60, now=at("2026-11-02T15:00"))
    focus = store.update(focus["id"], now=at("2026-11-02T15:10"), strict=True)
    assert focus["strict"]
    other = store.lock_for("Study", minutes=60, now=at("2026-11-02T15:00"))
    store.unlock(other["id"], "done", use_pass=True, now=at("2026-11-02T15:20"))
    assert store.passes(at("2026-11-02T15:30"))["left"] == 3


def test_strict_locks_cant_be_ended_from_chat(store):
    tools = {t.name: t for t in lock_tools(store, ROME)}
    text = asyncio.run(tools["lock_now"].handler(title="Exam prep", minutes=60, strict=True))
    assert "strict" in text
    with pytest.raises(ValueError, match="can't be ended from chat"):
        asyncio.run(tools["end_lock"].describe(lock_id=1, reason="please"))
    with pytest.raises(ValueError, match="strict and on now"):
        asyncio.run(tools["delete_lock"].describe(lock_id=1))
    assert "3 of 3 left" in asyncio.run(tools["list_locks"].handler())


@pytest.fixture
def client():
    db = Database(":memory:")
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    yield TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t"))
    db.close()


def test_api(client):
    made = client.post("/v1/locks", json={"title": "Focus", "minutes": 30}, headers=AUTH).json()
    assert made["once"] and made["locked"] and made["until"]
    # Two hours from now, so it's never on while this runs (a lock that's on can't be edited).
    start = (datetime.now(ROME) + timedelta(hours=2)).strftime("%H:00")
    end = (datetime.now(ROME) + timedelta(hours=3)).strftime("%H:00")
    bed = client.post("/v1/locks", json={"title": "Bedtime", "start": start, "end": end, "days": []},
                      headers=AUTH).json()
    assert bed["summary"] == f"Every day {start}–{end}" and bed["start"] == start and not bed["once"]
    assert client.post("/v1/locks", json={"title": "x"}, headers=AUTH).status_code == 400

    assert client.patch(f"/v1/locks/{bed['id']}", json={"days": [1, 2, 3, 4, 5]},
                        headers=AUTH).json()["summary"] == f"Mon–Fri {start}–{end}"
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


def test_api_strict_and_passes(client):
    made = client.post("/v1/locks", json={"title": "Exam prep", "minutes": 30, "strict": True}, headers=AUTH).json()
    assert made["strict"] and made["locked"]
    assert client.post(f"/v1/locks/{made['id']}/unlock", json={"reason": "x"}, headers=AUTH).status_code == 400
    assert client.get("/v1/locks", headers=AUTH).json()["passes"]["left"] == 3
    assert client.post(f"/v1/locks/{made['id']}/unlock", json={"reason": "an emergency", "pass": True},
                       headers=AUTH).json() == {"lock": None}
    passes = client.get("/v1/locks", headers=AUTH).json()["passes"]
    assert passes["left"] == 2 and passes["used"][0]["reason"] == "an emergency"
    feed = client.get("/v1/activity", headers=AUTH).json()
    assert any(item["title"] == "You unlocked 'Exam prep' early with an emergency pass" for item in feed["items"])


def test_limits_reached_unlocked_and_strict(store):
    now = at("2026-11-02T15:00")  # a Monday
    with pytest.raises(ValueError, match="5 minutes"):
        store.add_limit("Social", 2)
    social = store.add_limit("Social", 30, [], now=now)
    assert store.limit_summary(social) == "30 min a day"
    assert store.limit_summary(store.add_limit("Games", 90, [1, 2, 3, 4, 5])) == "1 h 30 min on Mon–Fri"
    assert not store.reached(social, now)
    with pytest.raises(ValueError, match="isn't reached"):
        store.unlock_limit(social["id"], "a call", now=now)

    store.limit_reached(social["id"], "2026-11-02", at("2026-11-02T14:20"))
    social = store.get_limit(social["id"])
    assert store.reached(social, now)
    j = store.limit_json(social, now)
    assert j["reached_today"] and j["reached"].startswith("2026-11-02T14:20") and not j["open_today"]
    assert "reached at 14:20, locked until midnight" in store.limit_line(social, now)
    assert not store.reached(social, at("2026-11-03T09:00"))  # a new day

    store.unlock_limit(social["id"], "sending a photo", now=now)
    assert not store.reached(store.get_limit(social["id"]), now)
    assert store.limit_json(store.get_limit(social["id"]), now)["open_today"]
    assert store.passes(now)["left"] == 3  # not strict: no pass

    exam = store.add_limit("Exam week", 20, [], strict=True, now=now)
    store.limit_reached(exam["id"], "2026-11-02", None)
    for change in ({"minutes": 40}, {"enabled": False}, {"strict": False}, {"days": [2]}):
        with pytest.raises(ValueError, match="strict and reached"):
            store.update_limit(exam["id"], now=now, **change)
    with pytest.raises(ValueError, match="strict and reached"):
        store.delete_limit(exam["id"], now=now)
    assert store.update_limit(exam["id"], now=now, minutes=15, title="Exams")["minutes"] == 15  # tighter is fine
    with pytest.raises(ValueError, match="strict"):
        store.unlock_limit(exam["id"], "please", now=now)
    store.unlock_limit(exam["id"], "an emergency", use_pass=True, now=now)
    assert store.passes(now)["left"] == 2
    assert store.update_limit(exam["id"], now=at("2026-11-03T09:00"), minutes=60)["minutes"] == 60  # next day


def test_usage_only_goes_up(store):
    now = at("2026-11-02T21:00")
    assert "No screen time" in store.usage_text(now)
    store.record_usage([("2026-10-31", 200), ("2026-11-01", 165), ("2026-11-02", 90)], now=now)
    store.record_usage([("2026-11-02", 60), ("2026-11-01", 180)], now=now)  # an older count doesn't lower it
    assert [d["minutes"] for d in store.usage(date(2026, 10, 31))] == [200, 180, 90]
    text = store.usage_text(now)
    assert "Usual (average of 2 days): 3 h 10 min" in text and "Mon 02 Nov: 1 h 30 min so far" in text
    with pytest.raises(ValueError, match="out of range"):
        store.record_usage([("2026-11-05", 10)], now=now)


def test_api_limits_and_usage(client):
    social = client.post("/v1/limits", json={"title": "Social", "minutes": 30}, headers=AUTH).json()
    assert social["summary"] == "30 min a day" and not social["reached_today"]
    today = datetime.now(ROME).date().isoformat()
    assert client.post(f"/v1/limits/{social['id']}/unlock", json={"reason": "x"}, headers=AUTH).status_code == 400
    assert client.put("/v1/screen/usage", json={
        "days": [{"date": today, "minutes": 75}],
        "limits": [{"id": social["id"], "date": today, "at": datetime.now(ROME).isoformat()}, {"id": 999, "date": today}],
    }, headers=AUTH).json() == {"ok": True}
    got = client.get("/v1/locks", headers=AUTH).json()["limits"][0]
    assert got["reached_today"] and got["reached"]
    assert client.get("/v1/screen/usage", headers=AUTH).json()["days"][-1]["minutes"] == 75
    after = client.post(f"/v1/limits/{social['id']}/unlock", json={"reason": "a message"}, headers=AUTH).json()
    assert after["open_today"]
    assert client.patch(f"/v1/limits/{social['id']}", json={"minutes": 45}, headers=AUTH).json()["minutes"] == 45
    assert client.delete(f"/v1/limits/{social['id']}", headers=AUTH).json() == {"ok": True}
    assert client.patch(f"/v1/limits/{social['id']}", json={"minutes": 45}, headers=AUTH).status_code == 404


def test_coachs_screen_line_says_what_holds_or_comes_next(store):
    now = at("2026-11-02T15:00")  # a Monday
    assert store.coach_line(now).startswith("No locks or limits yet.")
    bedtime = store.schedule("Bedtime", "23:00", "07:00", [])
    assert store.coach_line(now) == "Bedtime starts at 23:00."
    assert store.coach_line(at("2026-11-02T23:30")) == "Bedtime is on until 07:00 tomorrow."
    store.update(bedtime["id"], enabled=False, now=now)
    assert store.coach_line(now) == "Bedtime is switched off, so nothing locks for now."
    social = store.add_limit("Social", 30, now=now)
    assert store.coach_line(now) == "Today's limits: Social, 30 min."
    store.limit_reached(social["id"], "2026-11-02", now)
    assert store.coach_line(now) == "Social is used up for today; it opens again at midnight."
    store.set_device(False, 0, now)
    assert store.coach_line(now).startswith("Screen Time isn't allowed on the phone")
    store.set_device(True, 3, now)
    # The week before at 2 h a day, the last one at 3 h: an hour more.
    store.record_usage([((date(2026, 11, 2) - timedelta(days=n)).isoformat(), 120 if n > 7 else 180)
                        for n in range(1, 15)], now)
    assert store.coach_line(now).endswith(" This week's about 1h00 a day more than the week before.")
