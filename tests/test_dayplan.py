from datetime import datetime, time, timedelta, timezone

from aide.dayplan import DayPlanner, dayplan_tools
from aide.icloud import CalEvent
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
    assert len(push.sent) == 2 and push.sent[1][1] == "Secretary · Tomorrow"
    assert push.sent[1][2].startswith("Tomorrow's plan is ready: ") and "Tap Add" in push.sent[1][2]
    assert await planner.tick(evening(23)) is None and len(agent.posts) == 2 and len(push.sent) == 2


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
    assert "Say so (and ask when for anything not placed): Long trip" in out


async def test_no_question_without_study_tomorrow(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    plan.update_caps(day_plan=False)
    assert await planner.tick(evening(21, 5)) is None and not agent.posts
    assert plan.caps()["day_plan"] is False and plan.update_caps(day_plan_at="21:30")["day_plan_at"] == "21:30"


async def test_with_the_evening_digest_its_one_message_and_one_push(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    planner.digest_at = lambda: time(21)
    assert await planner.tick(evening(21, 5)) is None and not agent.posts  # the digest asks, when it's made
    greeting = "Tomorrow is light. Leave by 8:50 for the lecture, tram 4."
    assert await planner.with_digest({"greeting": greeting}, evening(21, 2)) is True
    chat, note, text, cards = agent.posts[0]
    assert text.startswith(greeting + "\n\nTomorrow, ") and text.endswith("Or just say that's all.")
    assert "plan_tomorrow" in note and cards is None
    assert push.sent == [(chat, push.sent[0][1], greeting)]
    assert push.sent[0][1].startswith("Tomorrow · Anything else tomorrow besides ") and "of study?" in push.sent[0][1]
    assert await planner.with_digest({"greeting": greeting}, evening(21, 3)) is False  # once an evening
    assert await planner.tick(evening(21, 30)) is None and len(agent.posts) == 1
    assert await planner.tick(evening(22, 40)) == "fallback" and len(push.sent) == 2


async def test_the_question_goes_alone_when_the_digest_is_late_or_far(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    planner.digest_at = lambda: time(21)
    assert await planner.tick(evening(21, 10)) is None
    assert await planner.tick(evening(21, 16)) == "asked" and push.sent[0][1] == "Secretary · Tomorrow"
    assert await planner.with_digest({"greeting": "Hi."}, evening(21, 20)) is False  # it pushes by itself
    assert not agent.posts[0][2].startswith("Hi.")

    db, study, plan, plans, planner, agent, push = await setup(tmp_path / "far")
    planner.digest_at = lambda: time(22)  # an hour apart: each on its own
    assert await planner.tick(evening(21, 5)) == "asked"
    assert await planner.with_digest({"greeting": "Hi."}, evening(22)) is False


async def test_a_newer_plan_for_the_day_drops_the_older_card(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    tool = dayplan_tools(planner, lambda: ("c_tomorrow", "secretary"))[0]
    first = (await tool.handler()).attachment["events"][0]["plan"]
    out = await tool.handler(items=[{"title": "Dentist", "start": "10:00", "end": "11:00"}])
    second = out.attachment["events"][0]["plan"]
    assert first != second
    assert {i["status"] for i in plans.get(first)["items"]} == {"dropped"}
    assert {i["status"] for i in plans.get(second)["items"]} == {"proposed"}


async def test_a_thing_on_top_of_study_already_added_is_said(tmp_path):
    db, study, plan, plans, planner, agent, push = await setup(tmp_path)
    tool = dayplan_tools(planner, lambda: ("c_tomorrow", "secretary"))[0]
    first = (await tool.handler()).attachment["events"]
    block = next(e for e in first if e["title"].startswith("Review: "))
    s0, e0 = local(block["start"]), local(block["end"])
    study.calendar._events.append(CalEvent("r1", "Work", block["title"], s0, e0))  # the fallback card, added
    plan.invalidate()
    out = await tool.handler(items=[{"title": "Gym", "start": f"{s0:%H:%M}", "minutes": 30}])
    assert f"Gym clashes with study already in the calendar (Macroeconomics, {s0:%H:%M}–{e0:%H:%M})" in out
    assert not any(e["title"].startswith("Review: ") for e in out.attachment["events"])  # the study is there
