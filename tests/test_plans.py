from datetime import date, datetime, timedelta

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent, _merge
from aide.channels.api import create_app
from aide.db import Database
from aide.icloud import CalEvent
from aide.plans import PlanStore
from aide.reminders import ReminderStore
from aide.reviews import ReviewStore
from aide.tools import ToolRegistry
from aide.tools.calendar import calendar_tools
from aide.tools.plans import plan_tools
from test_api import AUTH, TOKEN, FakeClient, call, done
from test_calendar import FakeCalendar
from test_notebook import nb  # noqa: F401 (the fixture)
from test_quiz import notebook_with_questions
from test_study import ROME


def tomorrow(hour: int) -> datetime:
    return (datetime.now(ROME) + timedelta(days=1)).replace(hour=hour, minute=0, second=0, microsecond=0)


def local(dt: datetime) -> str:
    return f"{dt:%Y-%m-%dT%H:%M}"


@pytest.fixture
def app():
    """The API with a plan-proposing agent: its replies are given per test."""
    db = Database(":memory:")
    cal = FakeCalendar([CalEvent("r1", "Work", "Standup", tomorrow(9), tomorrow(9) + timedelta(minutes=15),
                                 recurring=True)])
    cal.color = lambda name: "#1BADF8" if name == "Work" else ""  # as iCloud's backend knows it
    plans = PlanStore(db.conn, ROME, cal)

    def make(responses=()):
        tools = ToolRegistry(calendar_tools(cal, ROME) + plan_tools(plans, None, None, lambda: (None, "secretary")))
        agent = Agent(FakeClient(responses), db, tools, model="m", delegate=False, tz=ROME)
        client = TestClient(create_app(agent, ReminderStore(db.conn), cal, ROME, TOKEN, plans=plans))
        return client, agent, cal
    yield make
    db.close()


def test_a_plan_is_proposed_and_added_with_a_tap(app):
    start = tomorrow(15)
    plan = [{"title": "Macro: IS-LM", "start": local(start), "end": local(start + timedelta(hours=2)),
             "calendar": "Work"},
            {"title": "Business law", "start": local(start + timedelta(days=1)),
             "end": local(start + timedelta(days=1, hours=1)), "calendar": "Home", "location": "Library"}]
    client, agent, cal = app([call("propose_events", events=plan), done("Two sessions proposed.")])
    reply = client.post("/v1/chat", json={"text": "plan my study"}, headers=AUTH).json()
    (card,) = reply["attachments"]
    first, second = card["events"]
    assert card["type"] == "events" and len(cal.store) == 1  # nothing in the calendar yet
    assert (first["title"], first["change"], first["status"], first["event"]) == ("Macro: IS-LM", "proposed",
                                                                                  "proposed", None)
    assert first["start"] == start.isoformat() and second["location"] == "Library"
    assert (first["color"], second["color"]) == ("#1BADF8", None)
    plan_id = first["plan"]

    r = client.post(f"/v1/plans/{plan_id}/add", json={"items": [first["id"]]}, headers=AUTH)
    assert [e["status"] for e in r.json()["events"]] == ["added", "proposed"]
    new = cal.store[r.json()["events"][0]["event"]]
    assert (new.title, new.calendar, new.start) == ("Macro: IS-LM", "Work", start)

    r = client.post(f"/v1/plans/{plan_id}/drop", headers=AUTH)  # the rest
    assert [e["status"] for e in r.json()["events"]] == ["added", "dropped"]
    assert client.post(f"/v1/plans/{plan_id}/add", headers=AUTH).json()["events"][1]["status"] == "dropped"
    assert len(cal.store) == 2

    # The card in the history shows what happened since, and the model was told.
    messages = client.get("/v1/history", headers=AUTH).json()["messages"]
    (m,) = [m for m in messages if m["role"] == "assistant"]
    assert [m["text"] for m in messages if m["role"] == "user"] == ["plan my study"]  # the taps' notes aren't shown
    assert [e["status"] for e in m["attachments"][0]["events"]] == ["added", "dropped"]
    notes = [msg["content"] for msg in agent.db.history(agent._resolve(CONVERSATION, None))
             if msg["role"] == "user" and isinstance(msg["content"], str)]
    assert any(n.startswith(f"[The user tapped Add on plan {plan_id}:\n- Macro: IS-LM") for n in notes)
    assert any(n.startswith(f"[The user tapped Remove on plan {plan_id}:\n- Business law") for n in notes)

    assert client.post("/v1/plans/ep_000000000000/add", headers=AUTH).status_code == 404
    assert client.post(f"/v1/plans/{plan_id}/add", json={"items": ["x"]}, headers=AUTH).status_code == 404


async def test_a_bad_item_fails_before_it_is_shown(app):
    client, agent, cal = app()
    tool = agent.tools.get("propose_events")
    start = tomorrow(15)
    with pytest.raises(ValueError, match="no calendar named 'Gym'"):
        await tool.handler(events=[{"title": "Run", "start": local(start), "end": local(start), "calendar": "Gym"}])
    with pytest.raises(ValueError, match="ends before it starts"):
        await tool.handler(events=[{"title": "Run", "start": local(start), "end": local(start - timedelta(hours=1)),
                                    "calendar": "Home"}])


async def test_an_all_day_item_ends_on_its_last_day(app):
    client, agent, cal = app()
    out = await agent.tools.get("propose_events").handler(
        events=[{"title": "Trip", "start": "2030-05-01", "end": "2030-05-03", "calendar": "Home"}])
    (item,) = out.attachment["events"]
    assert (item["all_day"], item["start"], item["end"]) == (True, "2030-05-01", "2030-05-04")  # as the calendar's
    added = client.post(f"/v1/plans/{item['plan']}/add", headers=AUTH).json()["events"][0]
    ev = cal.store[added["event"]]
    assert (ev.start, ev.end) == (date(2030, 5, 1), date(2030, 5, 4))


async def test_a_review_item_becomes_a_review_session(nb):
    notebook_with_questions(nb)
    cal = FakeCalendar()
    reviews = ReviewStore(nb.db.conn, ROME, cal, nb.study)
    plans = PlanStore(nb.db.conn, ROME, cal, reviews)
    (tool,) = plan_tools(plans, nb.study, nb.notebook, lambda: ("c_1", "professor"))
    start = tomorrow(10)
    out = await tool.handler(events=[{"title": "anything", "start": local(start),
                                      "end": local(start + timedelta(minutes=90)), "course": "macroeconomics",
                                      "topics": ["the is-lm model"]}])
    (item,) = out.attachment["events"]
    assert (item["title"], item["calendar"]) == ("Review: Macroeconomics", "Work")
    assert "Proposed 1 event(s)" in out and cal.store == {}

    plan, added = await plans.add(item["plan"])
    (s,) = reviews.upcoming()  # followed by Professor like one it added itself
    assert (s["minutes"], s["topics"], s["event_uid"]) == (90, ["The IS-LM model"], added[0]["event"])
    assert plan["conversation"] == "c_1" and plan["agent"] == "professor"


def test_events_listed_then_created_make_one_card_in_time_order():
    later = {"id": "a", "start": "2026-11-04T08:00:00+01:00", "title": "Exam"}
    sooner = {"id": "b", "start": "2026-11-02T11:00:00+01:00", "title": "Midterm"}
    all_day = {"id": "c", "start": "2026-11-02", "title": "Holiday"}
    merged = _merge([{"type": "events", "events": [later, sooner]},
                     {"type": "events", "events": [{**later, "change": "found"}, all_day]},
                     {"type": "events", "events": [{**sooner, "change": "created"}]},
                     {"type": "events", "events": [later]}])  # listed again: still found
    (card,) = merged
    assert [(e["id"], e.get("change")) for e in card["events"]] == [("c", None), ("b", "created"), ("a", "found")]


def test_the_week_card_reads_moves_and_deletes_events(app):
    client, agent, cal = app()
    start = tomorrow(15)
    ev = cal.create("Home", "Dentist", start, start + timedelta(hours=1), "", "Bring the X-ray")

    r = client.get(f"/v1/events?from={start.date()}&days=1", headers=AUTH).json()
    assert r["from"] == start.date().isoformat() and r["days"] == 1
    assert [(e["title"], e["notes"]) for e in r["events"]] == [("Standup", ""), ("Dentist", "Bring the X-ray")]
    assert client.get("/v1/events?days=100", headers=AUTH).json()["days"] == 42

    later = start + timedelta(days=1, hours=1)
    r = client.patch(f"/v1/events/{ev.uid}", json={"start": local(later), "end": local(later + timedelta(hours=1))},
                     headers=AUTH)
    assert r.status_code == 200 and r.json()["start"] == later.isoformat() and cal.store[ev.uid].start == later
    assert client.patch(f"/v1/events/{ev.uid}", json={"start": local(later), "end": local(later)},
                        headers=AUTH).status_code == 400
    assert client.patch("/v1/events/r1", json={"start": local(later), "end": local(later + timedelta(hours=1))},
                        headers=AUTH).status_code == 409  # recurring
    assert client.delete("/v1/events/r1", headers=AUTH).status_code == 409
    assert client.delete(f"/v1/events/{ev.uid}", headers=AUTH).json() == {"ok": True} and ev.uid not in cal.store
    assert client.delete(f"/v1/events/{ev.uid}", headers=AUTH).status_code == 404
    titles = [a["title"] for a in client.get("/v1/activity", headers=AUTH).json()["items"]]
    assert titles[:2] == ["Deleted Dentist (in the app)", "Moved Dentist (in the app)"]


async def test_created_and_found_events_are_marked_on_the_card(app):
    client, agent, cal = app()
    start = tomorrow(18)
    out = await agent.tools.get("create_event").handler(title="Gym", start=local(start),
                                                       end=local(start + timedelta(hours=1)), calendar="Home")
    assert out.startswith("Created: [") and out.attachment["events"][0]["change"] == "created"
    found = await agent.tools.get("search_events").handler(query="gym")
    assert [e["change"] for e in found.attachment["events"]] == ["found"]
