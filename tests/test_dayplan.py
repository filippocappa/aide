from datetime import datetime, time, timedelta, timezone

from aide.dayplan import DayPlanner, dayplan_tools
from aide.plans import PlanStore
from aide.reminders import ReminderStore
from test_examplan import ROME, TODAY, exam_in, overlaps

TOMORROW = TODAY + timedelta(days=1)


def evening(hour: int, minute: int = 0) -> datetime:
    return datetime.combine(TODAY, time(hour, minute), ROME).astimezone(timezone.utc)


class Agent_:
    def __init__(self, db):
        self.db, self.posts = db, []

    async def post(self, chat, note, text, attachments=None):
        self.posts.append((chat, note, text, attachments))


class Push:
    def __init__(self):
        self.sent = []

    async def send_message(self, chat, title, body):
        self.sent.append((chat, title, body))


async def setup(tmp_path, events=()):
    db, study, notebook, quizzes, plan, macro = await exam_in(tmp_path, 10)
    plans = PlanStore(db.conn, ROME, study.calendar)
    reminders = ReminderStore(db.conn)
    reminders.create("Call the bank", datetime.combine(TOMORROW, time(10), ROME))

    async def calendar(start, end):
        return [e for e in events if e["start"] < end.isoformat() and e["end"] > start.isoformat()]

    agent, push = Agent_(db), Push()
    planner = DayPlanner(plan, plans, agent, push, reminders, calendar, "Home")
    return db, study, plan, plans, planner, agent, push


def local(value: str) -> datetime:
    return datetime.fromisoformat(value)


async def test_it_asks_once_in_the_evening_then_falls_back(tmp_path):
    run = {"id": "r", "title": "Easy run", "calendar": "Run", "all_day": False, "notes": "",
           "start": datetime.combine(TOMORROW, time(13), ROME).isoformat(),
           "end": datetime.combine(TOMORROW, time(13, 30), ROME).isoformat()}
    db, study, plan, plans, planner, agent, push = await setup(tmp_path, [run])
    assert await planner.tick(evening(20, 55)) is None and not agent.posts
    assert await planner.tick(evening(21, 5)) == "asked"
    chat, note, text, cards = agent.posts[0]
    assert text.startswith(f"Tomorrow, {TOMORROW:%a %d %b}:") and "13:00–13:30 Easy run" in text
    assert "Call the bank (10:00)" in text and "Study from the exam plan: Macroeconomics" in text
    assert "Anything else you have to do tomorrow?" in text and "plan_tomorrow" in note and cards is None
    assert push.sent[0][1] == "Secretary · Tomorrow"
    row = db.app_conversation(chat)
    assert row["title"] == "Tomorrow" and row["agent"] == "secretary"
    assert await planner.tick(evening(21, 30)) is None and len(agent.posts) == 1  # once an evening
    assert await planner.tick(evening(22, 40)) == "fallback"  # no answer in 90 minutes
    _, _, said, cards = agent.posts[1]
    assert said.startswith("No answer") and cards[0]["type"] == "events"
    assert all(e["title"] == "Review: Macroeconomics" for e in cards[0]["events"])
    assert await planner.tick(evening(23)) is None and len(agent.posts) == 2


async def test_their_things_first_then_the_study_around_them(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    tool = dayplan_tools(planner, lambda: ("c_tomorrow", "secretary"))[0]
    assert tool.name == "plan_tomorrow"
    out = await tool.handler(items=[
        {"title": "Dentist", "start": "10:00", "end": "11:00"},
        {"title": "Groceries", "minutes": 45, "part": "afternoon"},
    ])
    events = out.attachment["events"]
    mine = {e["title"]: e for e in events if not e["title"].startswith("Review: ")}
    study_items = [e for e in events if e["title"].startswith("Review: ")]
    assert set(mine) == {"Dentist", "Groceries"} and all(e["calendar"] == "Home" for e in mine.values())
    assert local(mine["Dentist"]["start"]).hour == 10
    groceries = local(mine["Groceries"]["start"])
    assert 13 <= groceries.hour < 18 and local(mine["Groceries"]["end"]) - groceries == timedelta(minutes=45)
    assert study_items and all(e["calendar"] == study.study_calendar for e in study_items)
    for s in study_items:
        s0, e0 = local(s["start"]), local(s["end"])
        assert s0.date() == TOMORROW
        for m in mine.values():
            assert not overlaps(s0, e0, local(m["start"]), local(m["end"]))
    assert "Not in the calendar until the user taps Add" in out
    # Answered: no fallback card later that evening.
    planner._mark("day_asked", TOMORROW)  # asked earlier that evening
    assert await planner.tick(evening(23)) is None
    assert not any(said.startswith("No answer") for _, _, said, _ in agent.posts)


async def test_what_doesnt_fit_is_said(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    tool = dayplan_tools(planner, lambda: ("c_tomorrow", "secretary"))[0]
    out = await tool.handler(items=[{"title": "Long trip", "minutes": 600, "part": "morning"}])
    assert "Not placed (say so, and ask when): Long trip" in out


async def test_no_question_without_study_tomorrow(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    plan.update_caps(day_plan=False)
    assert await planner.tick(evening(21, 5)) is None and not agent.posts
    assert plan.caps()["day_plan"] is False and plan.update_caps(day_plan_at="21:30")["day_plan_at"] == "21:30"
