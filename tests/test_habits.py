from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.food import FoodStore
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
        agent = Agent(FakeClient(responses), db, ToolRegistry(habit_tools(habits)), model="m", delegate=False, tz=ROME)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, habits)
        return TestClient(app), agent, habits
    yield make
    db.close()


def test_habit_endpoints(api):
    client, _, habits = api()
    gym = client.post("/v1/habits", json={"name": "Gym", "cadence": {"type": "weekly", "per_week": 3}},
                      headers=AUTH).json()
    assert gym == {"id": 1, "name": "Gym", "cadence": {"type": "weekly", "per_week": 3}, "streak": 0,
                   "done_today": False, "last_done": None, "history": [], "workouts": [], "food": None,
                   "count": None, "counts": {}, "health": None}
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


def test_history_lists_the_last_26_weeks_of_checks_newest_first(api):
    client, _, habits = api()
    read = habits.add("Read")
    today = habits.today()
    for back in (0, 3, 181, 182, 400):
        habits.conn.execute("INSERT INTO habit_checks (habit_id, day) VALUES (?, ?)",
                            (read.id, (today - timedelta(days=back)).isoformat()))
    expected = [(today - timedelta(days=b)).isoformat() for b in (0, 3, 181)]  # day 182 back is the 27th week
    assert client.get("/v1/habits", headers=AUTH).json()["habits"][0]["history"] == expected
    after = client.post(f"/v1/habits/{read.id}/check", json={"date": (today - timedelta(days=1)).isoformat()},
                        headers=AUTH).json()
    assert after["history"] == [expected[0], (today - timedelta(days=1)).isoformat(), *expected[1:]]


# -- limit habits -----------------------------------------------------------------------


def test_limit_habit_counts_and_settles_at_midnight(api):
    client, _, habits = api()
    coffee = client.post("/v1/habits", json={"name": "Coffee", "cadence": {"type": "limit", "max": 5}},
                        headers=AUTH).json()
    assert coffee["cadence"] == {"type": "limit", "max": 5} and coffee["count"] == 0 and coffee["counts"] == {}
    assert coffee["done_today"] and coffee["streak"] == 0 and coffee["history"] == []  # today isn't over yet
    today = habits.today()
    two = [client.post(f"/v1/habits/{coffee['id']}/count", headers=AUTH).json() for _ in range(2)][-1]
    assert two["count"] == 2 and two["counts"] == {today.isoformat(): 2} and two["done_today"]
    back = client.post(f"/v1/habits/{coffee['id']}/count", json={"add": -5}, headers=AUTH).json()
    assert back["count"] == 0 and back["counts"] == {}  # never below 0
    assert client.post(f"/v1/habits/{coffee['id']}/check", headers=AUTH).status_code == 400
    tomorrow = (today + timedelta(days=1)).isoformat()
    assert client.post(f"/v1/habits/{coffee['id']}/count", json={"date": tomorrow}, headers=AUTH).status_code == 400
    read = habits.add("Read")
    assert client.post(f"/v1/habits/{read.id}/count", headers=AUTH).status_code == 400
    assert client.post("/v1/habits/99/count", headers=AUTH).status_code == 404


def test_limit_habit_streak_and_history_count_days_within_the_limit(api):
    _, _, habits = api()
    today = habits.today()
    h = habits.add("Coffee", max_count=5)
    habits.conn.execute("UPDATE habits SET since = ? WHERE id = ?", ((today - timedelta(days=5)).isoformat(), h.id))
    for back, n in ((1, 3), (2, 5), (3, 7), (4, 1)):  # 3 days back was over the limit
        habits.count(h.id, n, today - timedelta(days=back))
    h = habits.find(h.id)
    # Done: 5 back (nothing logged), 4, 2, 1; not 3 (over), not today (still going).
    assert h.history == tuple(today - timedelta(days=b) for b in (1, 2, 4, 5))
    assert h.streak == 2 and h.last_done == today - timedelta(days=1) and h.done_today
    over = habits.count(h.id, 6)
    assert over.count == 6 and not over.done_today and over.streak == 0  # broken today already
    assert habits.done_days(h.id, today - timedelta(days=6), today) == set(h.history)


def test_becoming_a_limit_habit_counts_from_that_day(api):
    client, _, habits = api()
    h = habits.add("Snacks")
    habits.check(h.id, habits.today() - timedelta(days=3))
    patched = client.patch(f"/v1/habits/{h.id}", json={"cadence": {"type": "limit", "max": 2}}, headers=AUTH).json()
    assert patched["cadence"] == {"type": "limit", "max": 2} and patched["history"] == []
    daily = client.patch(f"/v1/habits/{h.id}", json={"cadence": {"type": "daily"}}, headers=AUTH).json()
    assert daily["cadence"] == {"type": "daily"} and daily["count"] is None and len(daily["history"]) == 1


def test_limit_habit_counts_from_apple_health_too(api):
    client, _, habits = api()
    today = habits.today()
    coffee = client.post("/v1/habits", json={"name": "Coffee", "cadence": {"type": "limit", "max": 5},
                                            "health": "inhaler_usage"}, headers=AUTH).json()
    assert coffee["health"] == "inhaler_usage" and coffee["count"] == 0
    days = [{"date": (today - timedelta(days=1)).isoformat(), "inhaler_usage": 7},
            {"date": today.isoformat(), "inhaler_usage": 3, "steps": 900}]
    client.post("/v1/health/days", json={"days": days}, headers=AUTH)
    h = client.get("/v1/habits", headers=AUTH).json()["habits"][0]
    assert h["count"] == 3 and h["counts"][(today - timedelta(days=1)).isoformat()] == 7
    # One logged here goes on top of Health's 3; the same one logged in Health later counts once.
    assert client.post(f"/v1/habits/{coffee['id']}/count", headers=AUTH).json()["count"] == 4
    client.post("/v1/health/days", json={"days": [{"date": today.isoformat(), "inhaler_usage": 4}]}, headers=AUTH)
    assert habits.find(coffee["id"]).count == 4
    client.post("/v1/health/days", json={"days": [{"date": today.isoformat(), "inhaler_usage": 6}]}, headers=AUTH)
    over = habits.find(coffee["id"])
    assert over.count == 6 and not over.done_today
    assert client.post("/v1/habits", json={"name": "Y", "health": "inhaler_usage"}, headers=AUTH).status_code == 400
    off = client.patch(f"/v1/habits/{coffee['id']}", json={"health": None}, headers=AUTH).json()
    assert off["health"] is None and off["count"] == 4  # what was logged here


def test_what_is_logged_here_is_written_to_health(api):
    client, _, habits = api()
    today = habits.today()
    coffee = habits.add("Coffee", max_count=5, health="inhaler_usage")
    pushes = []
    habits.on_health_count.append(lambda: pushes.append(1))
    client.post("/v1/health/days", json={"days": [{"date": today.isoformat(), "inhaler_usage": 2}]}, headers=AUTH)
    assert client.get("/v1/habits", headers=AUTH).json()["habits"][0]["health_logged"] == {}
    # Two logged here, on top of Health's 2: the phone writes those two to Health, and is told to.
    client.post(f"/v1/habits/{coffee.id}/count", json={"add": 2}, headers=AUTH)
    h = client.get("/v1/habits", headers=AUTH).json()["habits"][0]
    assert h["count"] == 4 and h["health_logged"] == {today.isoformat(): 2} and len(pushes) == 1
    # Health catches up (2 of the user's own + the phone's 2): still 4. Taking one back takes back one of Aide's.
    client.post("/v1/health/days", json={"days": [{"date": today.isoformat(), "inhaler_usage": 4}]}, headers=AUTH)
    after = client.post(f"/v1/habits/{coffee.id}/count", json={"add": -1}, headers=AUTH).json()
    assert after["health_logged"] == {today.isoformat(): 1}
    habits.count(coffee.id, -5)
    assert habits.find(coffee.id).health_logged == ()
    plain = habits.add("Coffee", max_count=3)
    habits.count(plain.id)
    assert "health_logged" not in plain.as_json() and len(pushes) == 3


async def test_a_month_of_history_goes_in_at_once():
    db = Database(":memory:")
    habits = HabitStore(db.conn, ROME)
    today = habits.today()
    coffee = habits.add("Coffee", max_count=5, health="inhaler_usage")
    habits.count(coffee.id, 2, today - timedelta(days=1))
    pushes = []
    habits.on_health_count.append(lambda: pushes.append(1))
    tools = {t.name: t.handler for t in habit_tools(habits)}
    month = [{"date": (today - timedelta(days=b)).isoformat(), "count": 6 if b % 7 == 0 else 4} for b in range(1, 31)]
    out = await tools["fill_habit_days"](habit_id=coffee.id, days=month)
    assert out.startswith("Filled in 30 days: [1] Coffee")
    h = habits.find(coffee.id)
    # Totals, not added: yesterday's 2 became 4. The habit now counts from 30 days back, the 6s over the limit.
    counts = dict(h.counts)
    assert counts[today - timedelta(days=1)] == 4 and counts[today - timedelta(days=7)] == 6 and len(counts) == 30
    assert len(h.history) == 30 - 4 and h.streak == 6
    assert dict(h.health_logged)[today - timedelta(days=30)] == 4 and len(h.health_logged) == 30 and pushes
    again = await tools["fill_habit_days"](habit_id=coffee.id, days=[{"date": month[0]["date"], "count": 0}])
    assert "Filled in 1 day:" in again and today - timedelta(days=1) not in dict(habits.find(coffee.id).counts)

    gym = habits.add("Gym")
    mondays = [{"date": (today - timedelta(days=b)).isoformat(), "done": True} for b in (3, 10, 17)]
    await tools["fill_habit_days"](habit_id=gym.id, days=mondays)
    assert len(habits.find(gym.id).history) == 3
    with pytest.raises(ValueError):
        await tools["fill_habit_days"](habit_id=gym.id, days=[{"date": today.isoformat(), "count": 2}])
    with pytest.raises(ValueError):
        await tools["fill_habit_days"](habit_id=coffee.id, days=[{"date": (today + timedelta(days=1)).isoformat(),
                                                                "count": 1}])


@pytest.mark.parametrize("body", [
    {"name": "X", "cadence": {"type": "limit"}}, {"name": "X", "cadence": {"type": "limit", "max": 0}},
    {"name": "X", "cadence": {"type": "limit", "max": 101}}, {"name": "X", "food": "pizza"},
    {"name": "X", "cadence": {"type": "limit", "max": 3}, "food": "logged"},
    {"name": "X", "cadence": {"type": "limit", "max": 3}, "health": "steps"},
])
def test_bad_limit_and_food_habits_are_400(api, body):
    client, _, _ = api()
    assert client.post("/v1/habits", json=body, headers=AUTH).status_code == 400


async def test_tools_count_and_list_a_limit_habit():
    db = Database(":memory:")
    habits = HabitStore(db.conn, ROME)
    h = habits.add("Coffee", max_count=5)
    tools = {t.name: t.handler for t in habit_tools(habits)}
    assert (await tools["count_habit"](habit_id=h.id)).startswith("Counted: [1] Coffee · at most 5 a day · 1 today")
    assert "last 7 days, oldest first: 0, 0, 0, 0, 0, 0, 0" in await tools["list_habits"]()
    added = await tools["add_habit"](name="Beer", max=2)
    assert "at most 2 a day" in added
    with pytest.raises(ValueError):
        await tools["check_habit"](habit_id=h.id)


# -- food habits ------------------------------------------------------------------------


def test_food_habit_ticks_itself_from_the_food_log(api):
    client, _, habits = api()
    food = FoodStore(habits.conn, ROME)
    habits.food = food
    healthy = client.post("/v1/habits", json={"name": "Eat healthy", "food": "logged"}, headers=AUTH).json()
    assert healthy["food"] == "logged" and not healthy["done_today"]
    today = habits.today()
    food.add("Salad", 400, 20, 30, 10)
    two_back = datetime.combine(today - timedelta(days=2), datetime.min.time().replace(hour=13), ROME)
    food.add("Soup", 300, 10, 30, 10, eaten_at=two_back)
    h = client.get("/v1/habits", headers=AUTH).json()["habits"][0]
    assert h["done_today"] and h["streak"] == 1
    assert h["history"] == [today.isoformat(), (today - timedelta(days=2)).isoformat()]
    client.post(f"/v1/habits/{healthy['id']}/check", json={"date": (today - timedelta(days=1)).isoformat()},
                headers=AUTH)  # a check by hand still counts
    assert client.get("/v1/habits", headers=AUTH).json()["habits"][0]["streak"] == 3
    protein = client.patch(f"/v1/habits/{healthy['id']}", json={"food": "protein_g"}, headers=AUTH).json()
    assert protein["food"] == "protein_g" and not protein["done_today"]  # no protein goal set
    food.set_goals({"protein_g": 15})
    assert client.get("/v1/habits", headers=AUTH).json()["habits"][0]["done_today"]
    off = client.patch(f"/v1/habits/{healthy['id']}", json={"food": None}, headers=AUTH).json()
    assert off["food"] is None and off["history"] == [(today - timedelta(days=1)).isoformat()]
