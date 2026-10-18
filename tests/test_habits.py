from datetime import date, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.habits import HabitStore, streak
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.habits import habit_tools
from test_api import AUTH, TOKEN, Block, FakeCalendar, FakeClient, call, done

ROME = ZoneInfo("Europe/Rome")
SUN = date(2026, 10, 18)  # a Sunday


def days(*offsets):
    return {SUN - timedelta(days=o) for o in offsets}


def test_daily_streak_counts_back_and_today_in_progress_does_not_break_it():
    assert streak(days(0, 1, 2), None, SUN) == 3
    assert streak(days(1, 2), None, SUN) == 2  # today not done yet
    assert streak(days(2, 3), None, SUN) == 0  # yesterday missed
    assert streak(set(), None, SUN) == 0


def test_weekly_streak_needs_enough_checks_per_week():
    # Weeks: this one (Mon 12–Sun 18), last (5–11), the one before (28 Sep–4 Oct).
    this, last, before = days(0, 2), days(7, 8, 9), days(14, 15)
    assert streak(this | last | before, 2, SUN) == 3
    assert streak(last | before, 2, SUN) == 2  # this week still in progress
    assert streak(days(0) | last | before, 3, SUN) == 1  # only last week reached 3
    assert streak(days(0) | last, 3, SUN - timedelta(days=6)) == 1  # Monday: last week counts


@pytest.fixture
def api():
    db = Database(":memory:")
    habits = HabitStore(db.conn, ROME)
    def make(responses=()):
        agent = Agent(FakeClient(responses), db, ToolRegistry(habit_tools(habits)), model="m", tz=ROME)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, habits)
        return TestClient(app), agent, habits
    yield make
    db.close()


def test_habit_endpoints(api):
    client, _, habits = api()
    gym = client.post("/v1/habits", json={"name": "Gym", "cadence": {"type": "weekly", "per_week": 3}},
                      headers=AUTH).json()
    assert gym == {"id": 1, "name": "Gym", "cadence": {"type": "weekly", "per_week": 3}, "streak": 0,
                   "done_today": False, "last_done": None}
    read = client.post("/v1/habits", json={"name": "Read"}, headers=AUTH).json()
    assert read["cadence"] == {"type": "daily"}

    today = habits.today()
    checked = client.post(f"/v1/habits/{read['id']}/check", headers=AUTH).json()
    assert checked["done_today"] and checked["streak"] == 1 and checked["last_done"] == today.isoformat()
    yesterday = (today - timedelta(days=1)).isoformat()
    assert client.post(f"/v1/habits/{read['id']}/check", json={"date": yesterday}, headers=AUTH).json()["streak"] == 2
    undone = client.post(f"/v1/habits/{read['id']}/check", json={"done": False}, headers=AUTH).json()
    assert not undone["done_today"] and undone["streak"] == 1 and undone["last_done"] == yesterday

    assert [h["name"] for h in client.get("/v1/habits", headers=AUTH).json()["habits"]] == ["Gym", "Read"]
    assert client.delete(f"/v1/habits/{gym['id']}", headers=AUTH).json() == {"ok": True}
    assert client.delete(f"/v1/habits/{gym['id']}", headers=AUTH).status_code == 404
    assert client.post(f"/v1/habits/{gym['id']}/check", headers=AUTH).status_code == 404


@pytest.mark.parametrize("body", [
    {"name": " "}, {"name": "X", "cadence": {"type": "weekly"}}, {"name": "X", "cadence": {"type": "monthly"}},
    {"name": "X", "cadence": {"type": "weekly", "per_week": 8}},
])
def test_bad_habits_are_400(api, body):
    client, _, _ = api()
    r = client.post("/v1/habits", json=body, headers=AUTH)
    assert r.status_code == 400 and "error" in r.json()


def test_duplicate_name_and_future_check_are_400(api):
    client, _, habits = api()
    client.post("/v1/habits", json={"name": "Gym"}, headers=AUTH)
    assert client.post("/v1/habits", json={"name": "gym"}, headers=AUTH).status_code == 400
    tomorrow = (habits.today() + timedelta(days=1)).isoformat()
    assert client.post("/v1/habits/1/check", json={"date": tomorrow}, headers=AUTH).status_code == 400


def test_assistant_adds_and_checks_now_but_delete_is_queued(api):
    client, agent, habits = api([("tool_use", [Block(type="tool_use", id="t1", name="add_habit", input={"name": "Gym", "per_week": 3})]), done("Added."),
                                 call("check_habit", habit_id=1), done("Nice."),
                                 call("delete_habit", habit_id=1), done("Queued.")])
    client.post("/v1/chat", json={"text": "track gym 3 times a week"}, headers=AUTH)
    client.post("/v1/chat", json={"text": "went to the gym"}, headers=AUTH)
    assert habits.find(1).done_today
    body = client.post("/v1/chat", json={"text": "stop tracking gym"}, headers=AUTH).json()
    assert body["pending"][0]["summary"] == "Delete habit 'Gym' and its 0-week streak"
    assert habits.get(1) is not None  # not yet
    assert client.post("/v1/confirm", json={}, headers=AUTH).json()["result"] == "✓ Deleted habit: Gym"
    assert habits.all() == [] and agent.pending(CONVERSATION) == []


async def test_list_tool_shows_progress():
    db = Database(":memory:")
    habits = HabitStore(db.conn, ROME)
    habits.add("Gym", 3)
    habits.check(1)
    list_habits = next(t for t in habit_tools(habits) if t.name == "list_habits").handler
    assert await list_habits() == "[1] Gym · 3×/week, 1 done this week · streak 0 weeks · done today"
