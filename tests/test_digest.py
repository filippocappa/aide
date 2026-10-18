import asyncio
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide import digest as digest_mod
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.digest import DEFAULT_SETTINGS, DigestService, latest_slot, period, to_text
from aide.habits import HabitStore
from aide.icloud import CalEvent
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from test_api import AUTH, TOKEN, FakeClient, done

ROME = ZoneInfo("Europe/Rome")


class Calendar:
    def __init__(self, events=(), fail=False):
        self._events, self.fail = list(events), fail

    def events(self, start, end):
        if self.fail:
            raise ConnectionError("iCloud down")
        return [e for e in self._events if start <= digest_mod.event_start(e, ROME) < end]


class Mail:
    async def search(self, query, max_results):
        assert query == "is:unread in:inbox"
        return [{"id": "m1", "threadId": "t1", "internalDate": "1792321200000", "snippet": "See you Tuesday",
                 "labelIds": ["INBOX", "UNREAD"],
                 "payload": {"headers": [{"name": "From", "value": "Dr. Rossi <rossi@example.com>"},
                                         {"name": "Subject", "value": "Appointment"}]}}]


@pytest.fixture
def env():
    db = Database(":memory:")
    store, habits = ReminderStore(db.conn), HabitStore(db.conn, ROME)

    def make(responses=(), calendar=None, mail=None):
        client = FakeClient(responses)
        client.requests = []
        create = client.beta.messages.create

        async def spy(**kwargs):
            client.requests.append(kwargs)
            return await create(**kwargs)
        client.beta.messages.create = spy
        service = DigestService(db.conn, client, "m", ROME, store, habits, calendar, mail)
        agent = Agent(client, db, ToolRegistry([]), model="m", tz=ROME)
        app = create_app(agent, store, calendar, ROME, TOKEN, habits, service)
        return TestClient(app), service, client
    yield make, store, habits
    db.close()


def late_in_period():
    """23:30 on the day the daily digest covers right now, so the test passes at any hour."""
    start = period("daily", datetime.now(ROME)).start
    return datetime.combine(start, datetime.min.time(), ROME) + timedelta(hours=23, minutes=30)


def test_digest_sections_are_data_and_the_model_writes_only_greeting_and_ahead(env):
    make, store, habits = env
    late = late_in_period()
    ev = CalEvent("e1", "Home", "Dentist", late - timedelta(minutes=20), late)
    after = CalEvent("e2", "Work", "Board meeting", late + timedelta(days=2), late + timedelta(days=2, hours=1))
    client, service, fake = make([done("Good morning. One dentist and one mail.\n---\n- Prepare for the board meeting")],
                                 Calendar([ev, after]), Mail())
    store.create("Call mum", late)
    habits.add("Gym", 3)

    assert client.get("/v1/digest", headers=AUTH).status_code == 404
    body = client.post("/v1/digest/run", json={"kind": "daily"}, headers=AUTH).json()
    assert body["kind"] == "daily" and body["greeting"] == "Good morning. One dentist and one mail."
    types = [s["type"] for s in body["sections"]]
    assert types == ["calendar", "mail", "reminders", "habits", "text"]
    cal, mail, rem, hab, text = body["sections"]
    assert [e["title"] for e in cal["events"]] == ["Dentist"]  # the board meeting is after the period
    assert cal["events"][0]["calendar"] == "Home" and cal["title"] in ("Today", "Tomorrow")
    assert mail["items"] == [{"id": "m1", "from": "Dr. Rossi", "subject": "Appointment", "preview": "See you Tuesday",
                              "received_at": mail["items"][0]["received_at"], "unread": True}]
    assert [r["title"] for r in rem["reminders"]] == ["Call mum"]
    assert hab["habits"][0]["name"] == "Gym" and hab["habits"][0]["cadence"] == {"type": "weekly", "per_week": 3}
    assert text == {"type": "text", "title": "Looking ahead", "text": "- Prepare for the board meeting"}

    prompt = fake.requests[0]["messages"][0]["content"]
    assert "Dentist" in prompt and "Appointment" in prompt and "Board meeting" in prompt
    assert client.get("/v1/digest?kind=daily", headers=AUTH).json() == body
    assert client.get("/v1/digest?kind=weekly", headers=AUTH).status_code == 404


def test_digest_survives_a_failing_model_and_calendar(env):
    make, store, _ = env
    client, _, _ = make([], Calendar(fail=True))  # no scripted response: the model call fails
    store.create("Overdue thing", datetime.now(ROME) - timedelta(days=1))
    body = client.post("/v1/digest/run", json={}, headers=AUTH).json()
    assert body["greeting"].startswith("Good ") and "1 reminder" in body["greeting"]
    assert [s["type"] for s in body["sections"]] == ["reminders"]


def test_weekly_and_monthly_periods():
    sunday_evening = datetime(2026, 10, 18, 18, tzinfo=ROME)
    w = period("weekly", sunday_evening)
    assert (w.start, w.end) == (date(2026, 10, 19), date(2026, 10, 26))
    assert period("daily", sunday_evening).calendar_title == "Tomorrow"
    m = period("monthly", datetime(2026, 11, 1, 9, tzinfo=ROME))
    assert (m.start, m.end, m.calendar_title) == (date(2026, 11, 1), date(2026, 12, 1), "November")
    assert period("monthly", datetime(2026, 12, 31, 20, tzinfo=ROME)).start == date(2027, 1, 1)


def test_latest_slot():
    now = datetime(2026, 10, 18, 12, tzinfo=ROME)  # Sunday noon
    assert latest_slot("daily", {"time": "08:00"}, now) == datetime(2026, 10, 18, 8, tzinfo=ROME)
    assert latest_slot("daily", {"time": "13:00"}, now) == datetime(2026, 10, 17, 13, tzinfo=ROME)
    assert latest_slot("weekly", {"weekday": 7, "time": "18:00"}, now) == datetime(2026, 10, 11, 18, tzinfo=ROME)
    assert latest_slot("weekly", {"weekday": 1, "time": "08:00"}, now) == datetime(2026, 10, 12, 8, tzinfo=ROME)
    assert latest_slot("monthly", {"day": 1, "time": "09:00"}, now) == datetime(2026, 10, 1, 9, tzinfo=ROME)
    assert latest_slot("monthly", {"day": 31, "time": "09:00"}, now) == datetime(2026, 9, 30, 9, tzinfo=ROME)


def test_settings(env):
    make, _, _ = env
    client, _, _ = make()
    assert client.get("/v1/digest/settings", headers=AUTH).json() == DEFAULT_SETTINGS
    new = {**DEFAULT_SETTINGS, "weekly": {"enabled": False, "weekday": 1, "time": "07:30"}, "discord": False}
    assert client.put("/v1/digest/settings", json=new, headers=AUTH).json() == new
    assert client.get("/v1/digest/settings", headers=AUTH).json() == new
    for bad in ({**new, "daily": {"enabled": True, "time": "8am"}},
                {**new, "weekly": {"enabled": True, "weekday": 0, "time": "08:00"}},
                {k: v for k, v in new.items() if k != "monthly"}):
        r = client.put("/v1/digest/settings", json=bad, headers=AUTH)
        assert r.status_code == 400 and "error" in r.json()
    assert client.get("/v1/digest?kind=yearly", headers=AUTH).status_code == 400


async def test_schedule_generates_once_and_sends_to_discord(env, monkeypatch):
    make, _, _ = env
    _, service, _ = make([done("Hello.\n---\n- ahead"), done("unused")])
    now = datetime.now(ROME)
    off = {"enabled": False, "time": "00:00"}
    service.save_settings({"daily": {"enabled": True, "time": f"{now - timedelta(minutes=1):%H:%M}"},
                           "weekly": {**off, "weekday": 1}, "monthly": {**off, "day": 1}, "discord": True})
    sent = []

    async def notify(text):
        sent.append(text)
        return True

    monkeypatch.setattr(digest_mod, "TICK", 0)
    task = asyncio.create_task(digest_mod.digest_schedule(service, notify))
    for _ in range(50):
        await asyncio.sleep(0)
    task.cancel()
    assert len(sent) == 1 and sent[0].startswith("**Hello.**") and "**Looking ahead**\n- ahead" in sent[0]
    assert service.latest("daily")["greeting"] == "Hello."


def test_discord_text():
    sections = [
        {"type": "calendar", "title": "Today", "events": []},
        {"type": "mail", "title": "Mail", "items": [{"from": "Ann", "subject": "Hi"}]},
        {"type": "habits", "title": "Habits", "habits": [
            {"name": "Read", "cadence": {"type": "daily"}, "streak": 1, "done_today": True}]},
        {"type": "unknown", "title": "?"},
    ]
    assert to_text("Hi.", sections, ROME) == (
        "**Hi.**\n\n**Today**\n• Nothing scheduled.\n\n**Mail**\n• Ann: Hi\n\n**Habits**\n• Read: streak 1 day ✓ today")
