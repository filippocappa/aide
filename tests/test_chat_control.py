"""Driving the app from chat: the tools that do what only the app's pages did (daily limits, habit edits, food
targets, course dates, settings) and the `open` card that sends the user to a page."""

import asyncio
from urllib.parse import parse_qs, urlparse

import pytest

from aide.agent import _merge
from aide.agents import AGENTS, COMMON_TOOLS, WRITES
from aide.db import Database, utcnow
from aide.digest import DigestService
from aide.engine import Engine
from aide.food import FoodStore
from aide.habits import HabitStore
from aide.live import LiveActivities
from aide.locks import LockStore
from aide.photos import PhotoStore
from aide.push import Push
from aide.reminders import ReminderStore
from aide.tools import ToolOutput
from aide.tools.food import food_tools
from aide.tools.habits import habit_tools
from aide.tools.locks import lock_tools
from aide.tools.pages import PAGES, page_tools
from aide.tools.settings import settings_tools
from aide.tools.study import study_tools
from test_notebook import nb  # noqa: F401 (the fixture)
from test_study import ROME


def run(coro):
    return asyncio.run(coro)


def tools_by_name(tools) -> dict:
    return {t.name: t for t in tools}


@pytest.fixture
def db():
    d = Database(":memory:")
    yield d
    d.close()


def test_every_new_tool_belongs_to_an_agent_and_writes_are_marked():
    owners = {
        "coach": ("add_limit", "update_limit", "end_limit", "delete_limit", "update_habit", "food_targets"),
        "professor": ("course_dates", "add_course_date", "edit_course_date", "hide_course_date"),
        "aide": ("settings", "change_setting", "run_digest"),
        "finance": ("card_owed",),
    }
    for agent, names in owners.items():
        assert set(names) <= set(AGENTS[agent].tools), agent
    assert "open_page" in COMMON_TOOLS  # every agent gets these besides its own
    for name in ("add_limit", "update_limit", "update_habit", "food_targets", "add_course_date", "edit_course_date",
                 "hide_course_date", "change_setting", "run_digest", "card_owed", "save_food", "update_food",
                 "set_subscription", "quiz_me", "quiz_answer", "end_quiz"):
        assert name in WRITES, name
    assert "settings" not in WRITES and "course_dates" not in WRITES


def test_limits_from_chat(db):
    store = LockStore(db.conn, ROME)
    tools = tools_by_name(lock_tools(store, ROME))
    assert tools["end_limit"].confirm and tools["delete_limit"].confirm
    assert not tools["add_limit"].confirm and not tools["update_limit"].confirm

    out = run(tools["add_limit"].handler(title="Social", minutes=30))
    assert isinstance(out, ToolOutput) and "Social" in out and "picks its apps" in out
    assert out.attachment["type"] == "open" and out.attachment["open"][0]["url"] == "aide://settings/screentime"
    limit = store.limits()[0]
    assert limit["minutes"] == 30

    assert "45 min" in run(tools["update_limit"].handler(limit_id=limit["id"], minutes=45))
    assert store.get_limit(limit["id"])["minutes"] == 45 and store.get_limit(limit["id"])["title"] == "Social"
    with pytest.raises(ValueError, match="isn't reached"):
        run(tools["end_limit"].describe(limit_id=limit["id"], reason="a call"))
    assert "Delete the limit 'Social'" in run(tools["delete_limit"].describe(limit_id=limit["id"]))
    run(tools["delete_limit"].handler(limit_id=limit["id"]))
    with pytest.raises(Exception):
        store.get_limit(limit["id"])


def test_a_reached_limit_ends_with_a_reason_but_not_a_strict_one(db):
    store = LockStore(db.conn, ROME)
    tools = tools_by_name(lock_tools(store, ROME))
    today = utcnow().astimezone(ROME).date().isoformat()
    social = store.add_limit("Social", 30, [])
    exam = store.add_limit("Exams", 20, [], strict=True)
    for limit in (social, exam):
        store.limit_reached(limit["id"], today, None)
    assert "Reason: sending a photo" in run(tools["end_limit"].describe(limit_id=social["id"],
                                                                         reason="sending a photo"))
    with pytest.raises(ValueError, match="needs the user's reason"):
        run(tools["end_limit"].describe(limit_id=social["id"], reason="  "))
    with pytest.raises(ValueError, match="emergency pass"):
        run(tools["end_limit"].describe(limit_id=exam["id"], reason="please"))
    with pytest.raises(ValueError, match="deleted tomorrow"):
        run(tools["delete_limit"].describe(limit_id=exam["id"]))
    run(tools["end_limit"].handler(limit_id=social["id"], reason="sending a photo"))
    assert not store.reached(store.get_limit(social["id"]), utcnow())


def test_update_habit_changes_only_whats_given(db):
    store = HabitStore(db.conn, ROME)
    tools = tools_by_name(habit_tools(store))
    coffee = store.add("Coffee", None, max_count=5)
    assert "at most 3 a day" in run(tools["update_habit"].handler(habit_id=coffee.id, max=3))
    assert store.find(coffee.id).name == "Coffee"
    out = run(tools["update_habit"].handler(habit_id=coffee.id, name="Espresso"))
    assert "Espresso" in out and store.find(coffee.id).max_count == 3

    gym = store.add("Gym", 3)
    assert "daily" in run(tools["update_habit"].handler(habit_id=gym.id, per_week=0))
    assert store.find(gym.id).per_week is None
    run(tools["update_habit"].handler(habit_id=gym.id, workouts=["strength"]))
    assert store.find(gym.id).per_week is None  # the cadence stayed
    # An ordinary habit becomes a limit habit, and back.
    run(tools["update_habit"].handler(habit_id=gym.id, max=2))
    assert store.find(gym.id).max_count == 2
    run(tools["update_habit"].handler(habit_id=gym.id, per_week=4))
    assert store.find(gym.id).max_count is None and store.find(gym.id).per_week == 4
    with pytest.raises(ValueError, match="nothing to change"):
        run(tools["update_habit"].handler(habit_id=gym.id))


def test_food_targets_read_and_change(db, tmp_path):
    food = FoodStore(db.conn, ROME)
    tools = tools_by_name(food_tools(food, PhotoStore(tmp_path), ROME))
    text = run(tools["food_targets"].handler())
    assert "Rest-day base: none" in text and "add 100% of the Watch's workout kcal, 80% of it as carbs" in text
    out = run(tools["food_targets"].handler(workout_share=0.5, goal="perform", note="Marathon in April"))
    assert isinstance(out, ToolOutput) and out.attachment["open"][0]["url"] == "aide://settings/nutrition"
    assert "add 50% of the Watch's workout kcal" in out and "goal perform" in out
    assert "Marathon in April" in run(tools["food_targets"].handler())
    out = run(tools["food_targets"].handler(workouts_on=False))
    assert "Workouts: add nothing" in out
    with pytest.raises(ValueError):
        run(tools["food_targets"].handler(workout_share=3))


async def test_course_dates_from_chat(nb):  # noqa: F811
    tools = tools_by_name(study_tools(nb.study, ROME, None, nb.notebook))
    assert "No dates" in await tools["course_dates"].handler(course="macroeconomics")
    out = await tools["add_course_date"].handler(course="macroeconomics", what="1st mid-term", date="2099-03-02",
                                                 kind="mid-term", time="11:00", end="13:00", room="Aula 5")
    assert out.startswith("Added: [d_") and "Mon 02 Mar 2099, 11:00-13:00: 1st mid-term" in out and "Aula 5" in out
    date_id = out.split("[", 1)[1].split("]", 1)[0]
    listed = await tools["course_dates"].handler(course="macroeconomics")
    assert f"[{date_id}]" in listed and "· yours" in listed

    out = await tools["edit_course_date"].handler(course="macroeconomics", date_id=date_id, date="2099-03-03",
                                                  time="")
    assert "Tue 03 Mar 2099: 1st mid-term" in out  # all day now
    d = nb.notebook.find_date(nb.macro["id"], date_id)
    assert d["time"] is None and d["end"] is None and d["room"] == "Aula 5"

    assert "Removed: 1st mid-term" in await tools["hide_course_date"].handler(course="macroeconomics",
                                                                              date_id=date_id)
    assert "No dates" in await tools["course_dates"].handler(course="macroeconomics")
    with pytest.raises(ValueError, match="no course"):
        await tools["course_dates"].handler(course="astrology")


@pytest.fixture
def services(db):
    digest = DigestService(db.conn, None, "m", ROME, ReminderStore(db.conn), HabitStore(db.conn, ROME))
    live = LiveActivities(db.conn, Push(db.conn))
    engine = Engine(db.conn, None, "fast", "smart", claude="/usr/bin/claude")
    return digest, live, engine


def test_settings_round_trip(services):
    digest, live, engine = services
    leave = type("Leave", (), {"value": True, "settings": lambda self: {"calendar": self.value},
                               "update_settings": lambda self, calendar: setattr(self, "value", calendar)})()
    tools = tools_by_name(settings_tools(lambda: digest, live, lambda: leave, engine))
    listing = run(tools["settings"].handler())
    for key in ("digest.evening.time", "digest.weekly.weekday", "digest.monthly.day", "live.events", "live.locks",
                "leave.calendar", "writer.engine", "background.engine", "voice.language"):
        assert key in listing, key

    assert "21:30" in run(tools["change_setting"].handler(key="digest.evening.time", value="21:30"))
    assert digest.settings()["evening"]["time"] == "21:30"
    run(tools["change_setting"].handler(key="digest.weekly.weekday", value="Sunday"))
    assert digest.settings()["weekly"]["weekday"] == 7
    run(tools["change_setting"].handler(key="digest.wake.enabled", value="off"))
    assert digest.settings()["wake"]["enabled"] is False
    with pytest.raises(ValueError):
        run(tools["change_setting"].handler(key="digest.evening.time", value="25:00"))

    assert "on → off" in run(tools["change_setting"].handler(key="live.events", value="off"))
    assert live.settings()["events"] is False
    run(tools["change_setting"].handler(key="leave.calendar", value="no"))
    assert leave.value is False
    run(tools["change_setting"].handler(key="writer.engine", value="claude"))
    assert engine.engine == "claude"
    with pytest.raises(ValueError, match="one of"):
        run(tools["change_setting"].handler(key="background.engine", value="gpt"))
    with pytest.raises(ValueError, match="no setting"):
        run(tools["change_setting"].handler(key="theme", value="dark"))

    out = run(tools["change_setting"].handler(key="voice.language", value="it"))
    assert isinstance(out, ToolOutput) and "kept on the phone" in out
    assert out.attachment["open"][0]["url"] == "aide://settings/voice"


def test_settings_without_leave_now(services):
    digest, live, engine = services
    tools = tools_by_name(settings_tools(lambda: digest, live, lambda: None, engine))
    assert "leave.calendar" not in run(tools["settings"].handler())


async def test_open_page_cards(nb):  # noqa: F811
    tools = tools_by_name(page_tools(nb.study, nb.notebook))
    out = await tools["open_page"].handler(page="screen")
    assert out.attachment == {"type": "open", "open": [{"id": "aide://screen", "title": "Screen time",
                                                        "subtitle": None, "url": "aide://screen"}]}
    cid = nb.macro["id"]
    out = await tools["open_page"].handler(page="practice_exam", course="macroeconomics")
    item = out.attachment["open"][0]
    assert item["url"] == f"aide://study/{cid}/practice" and item["subtitle"] == nb.macro["name"]
    out = await tools["open_page"].handler(page="course", course="macroeconomics", note="Its dates")
    assert out.attachment["open"][0]["title"] == nb.macro["name"]
    assert out.attachment["open"][0]["subtitle"] == "Its dates"
    with pytest.raises(ValueError, match="needs the course"):
        await tools["open_page"].handler(page="lesson")
    with pytest.raises(ValueError, match="needs the topic"):
        await tools["open_page"].handler(page="lesson", course="macroeconomics")
    with pytest.raises(ValueError, match="no page"):
        await tools["open_page"].handler(page="nowhere")
    assert all(url.startswith("aide://") for _, url in PAGES.values())


async def test_a_lesson_card_carries_the_topic(nb, monkeypatch):  # noqa: F811
    monkeypatch.setattr(nb.notebook, "find_topic", lambda topic, course_id: {"public_id": "t_abc",
                                                                             "title": "IS-LM & money"})
    tools = tools_by_name(page_tools(nb.study, nb.notebook))
    out = await tools["open_page"].handler(page="lesson", course="macroeconomics", topic="IS-LM")
    url = urlparse(out.attachment["open"][0]["url"])
    assert url.path == f"/{nb.macro['id']}/lesson" and url.netloc == "study"
    assert parse_qs(url.query) == {"topic": ["t_abc"], "title": ["IS-LM & money"]}


def test_open_cards_merge_into_one():
    a = {"type": "open", "open": [{"id": "aide://screen", "title": "Screen time", "subtitle": None,
                                   "url": "aide://screen"}]}
    b = {"type": "open", "open": [{"id": "aide://settings/voice", "title": "Voice", "subtitle": None,
                                   "url": "aide://settings/voice"}]}
    merged = _merge([a, b, a])
    assert merged == [{"type": "open", "open": [a["open"][0], b["open"][0]]}]
