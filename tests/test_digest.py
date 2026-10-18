import asyncio
import json
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


def mail(id, received, subject="Appointment"):
    return {"id": id, "threadId": "t1", "internalDate": str(int(received.timestamp() * 1000)),
            "snippet": "See you Tuesday", "labelIds": ["INBOX", "UNREAD"],
            "payload": {"headers": [{"name": "From", "value": "Dr. Rossi <rossi@example.com>"},
                                    {"name": "Subject", "value": subject}]}}


class Mail:
    def __init__(self, messages=None):
        self.messages = messages if messages is not None else [mail("m1", datetime.now(ROME) - timedelta(seconds=1))]
        self.queries = []

    async def search(self, query, max_results):
        assert query.startswith("in:inbox after:")
        self.queries.append(query)
        return self.messages


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
    now = datetime.now(ROME)
    store.create("Overdue thing", max(datetime.combine(now.date(), datetime.min.time(), ROME), now - timedelta(hours=1)))
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
    service.save_settings({"daily": {"enabled": True, "time": f"{now - timedelta(minutes=1):%H:%M}"}, "evening": off,
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


# -- evening -------------------------------------------------------------------


def test_evening_is_always_about_tomorrow():
    for hour in (7, 12, 22, 23):
        p = period("evening", datetime(2026, 10, 18, hour, tzinfo=ROME))
        assert (p.start, p.end, p.calendar_title, p.reminders_title) == (
            date(2026, 10, 19), date(2026, 10, 20), "Tomorrow", "Due tomorrow")
    now = datetime(2026, 10, 18, 21, tzinfo=ROME)
    assert latest_slot("evening", {"time": "22:00"}, now) == datetime(2026, 10, 17, 22, tzinfo=ROME)


def test_evening_digest_has_tomorrow_open_habits_todays_mail_and_a_wrap_up(env):
    make, store, habits = env
    now = datetime.now(ROME)
    tomorrow = datetime.combine(now.date() + timedelta(days=1), datetime.min.time(), ROME)
    ev = CalEvent("e1", "Uni", "Exam", tomorrow + timedelta(hours=9), tomorrow + timedelta(hours=11))
    today_ev = CalEvent("e0", "Uni", "Lecture", tomorrow - timedelta(hours=1), tomorrow - timedelta(minutes=30))
    midnight = tomorrow - timedelta(days=1)
    inbox = Mail([mail("new", max(midnight, now - timedelta(minutes=5)), "Today's"),
                  mail("old", midnight - timedelta(hours=3), "Yesterday's")])
    client, _, fake = make([done("Good evening. Exam at 9.\n---\n- Pack your calculator")], Calendar([ev, today_ev]),
                           inbox)
    store.create("Print notes", tomorrow + timedelta(hours=8))
    store.create("Next week", tomorrow + timedelta(days=7))
    habits.add("Gym")
    habits.add("Read")
    habits.check(2)

    body = client.post("/v1/digest/run", json={"kind": "evening"}, headers=AUTH).json()
    assert body["kind"] == "evening" and body["greeting"] == "Good evening. Exam at 9."
    sections = {s["type"]: s for s in body["sections"]}
    assert list(sections) == ["calendar", "mail", "reminders", "habits", "text"]
    assert sections["calendar"]["title"] == "Tomorrow"
    assert [e["title"] for e in sections["calendar"]["events"]] == ["Exam"]
    assert [m["id"] for m in sections["mail"]["items"]] == ["new"]
    assert inbox.queries == [f"in:inbox after:{int(midnight.timestamp())}"]
    assert [r["title"] for r in sections["reminders"]["reminders"]] == ["Print notes"]
    assert sections["reminders"]["title"] == "Due tomorrow"
    assert [h["name"] for h in sections["habits"]["habits"]] == ["Gym"]  # Read is done today
    assert sections["text"] == {"type": "text", "title": "Wrap-up", "text": "- Pack your calculator"}
    assert "Wrap-up" in fake.requests[0]["system"] and "before bed" in fake.requests[0]["system"]

    assert client.get("/v1/digest?kind=evening", headers=AUTH).json() == body
    assert client.get("/v1/digest", headers=AUTH).status_code == 404  # daily (morning) is separate


def test_evening_settings_and_older_clients_that_leave_it_out(env):
    make, _, _ = env
    client, service, _ = make()
    assert client.get("/v1/digest/settings", headers=AUTH).json()["evening"] == {"enabled": True, "time": "22:00"}
    settings = {**DEFAULT_SETTINGS, "evening": {"enabled": False, "time": "21:30"}}
    assert client.put("/v1/digest/settings", json=settings, headers=AUTH).json()["evening"] == settings["evening"]

    old_client = {k: v for k, v in DEFAULT_SETTINGS.items() if k != "evening"}
    old_client["daily"] = {"enabled": True, "time": "07:00"}
    saved = client.put("/v1/digest/settings", json=old_client, headers=AUTH).json()
    assert saved["daily"]["time"] == "07:00" and saved["evening"] == {"enabled": False, "time": "21:30"}
    bad = {**settings, "evening": {"enabled": True, "time": "25"}}
    assert client.put("/v1/digest/settings", json=bad, headers=AUTH).status_code == 400

    # Settings saved before evening existed read back with its default.
    service.conn.execute("UPDATE settings SET value = ? WHERE key = 'digest'", (json.dumps(old_client),))
    assert client.get("/v1/digest/settings", headers=AUTH).json()["evening"] == {"enabled": True, "time": "22:00"}


# -- v2: live sections, 48 h overdue, mail from today, digest as a chat's first message ------------------------


def test_get_rebuilds_the_data_sections_but_keeps_the_stored_greeting(env):
    make, store, habits = env
    late = late_in_period()
    client, service, fake = make([done("Hi.\n---\n- ahead")], Calendar([]), Mail([]))
    done_later = store.create("Pay the bill", late)
    store.create("Call Marco", late - timedelta(minutes=5))
    habits.add("Read")
    made = client.post("/v1/digest/run", json={"kind": "daily"}, headers=AUTH).json()

    store.update(done_later.id, completed=True)
    store.delete(store.open()[0].id)
    habits.check(1)
    service.gmail = Mail([mail("m9", datetime.now(ROME) - timedelta(seconds=1), "New one")])
    live = client.get("/v1/digest", headers=AUTH).json()
    assert live["greeting"] == "Hi." and live["generated_at"] == made["generated_at"]
    types = [s["type"] for s in live["sections"]]
    assert types == ["calendar", "mail", "habits", "text"]  # both reminders gone: done and deleted
    assert live["sections"][1]["items"][0]["subject"] == "New one"
    assert live["sections"][2]["habits"][0]["done_today"] is True
    assert live["sections"][-1] == {"type": "text", "title": "Looking ahead", "text": "- ahead"}
    assert len(fake.requests) == 1  # reading doesn't call the model


def test_reminders_cover_the_period_and_only_todays_overdue(env):
    make, store, _ = env
    now = datetime.now(ROME)
    midnight = datetime.combine(now.date(), datetime.min.time(), ROME)
    client, _, _ = make([], Calendar([]))
    store.create("Ancient", now - timedelta(days=5))
    store.create("Yesterday", midnight - timedelta(minutes=1))
    store.create("Earlier today", max(midnight, now - timedelta(hours=3)))
    store.create("Later", late_in_period())
    store.create("Next month", now + timedelta(days=40))
    store.create("No time")
    body = client.post("/v1/digest/run", json={"kind": "daily"}, headers=AUTH).json()
    rem = next(s for s in body["sections"] if s["type"] == "reminders")["reminders"]
    assert [(r["title"], r["overdue"]) for r in rem] == [("Earlier today", True), ("Later", False)]


def test_mail_is_everything_that_came_in_today_newest_first(env):
    make, _, _ = env
    now = datetime(2026, 10, 19, 12, tzinfo=ROME)
    client, service, _ = make()
    p = period("daily", now)
    assert service.mail_since("daily", p, now) == datetime(2026, 10, 18, 22, tzinfo=ROME)  # since last evening
    assert service.mail_since("evening", period("evening", now), now) == datetime(2026, 10, 19, tzinfo=ROME)
    assert service.mail_since("weekly", period("weekly", now), now) == datetime(2026, 10, 19, tzinfo=ROME)

    t = datetime.now(ROME)
    read = mail("read", t - timedelta(seconds=2), "Read one")
    read["labelIds"] = ["INBOX"]
    service.gmail = Mail([read, mail("unread", t - timedelta(seconds=1), "Unread one")])
    items = asyncio.run(service._mail(t - timedelta(minutes=1)))
    assert [(m["id"], m["unread"]) for m in items] == [("unread", True), ("read", False)]


def test_greeting_prompt_asks_for_a_spoken_note(env):
    make, _, _ = env
    client, _, fake = make([done("Tomorrow is light.\n---\n- x")], Calendar([]), Mail())
    client.post("/v1/digest/run", json={"kind": "evening"}, headers=AUTH)
    system = fake.requests[0]["system"]
    assert "No lists" in system and "wants an answer" in system
    assert "See you Tuesday" in fake.requests[0]["messages"][0]["content"]  # the model sees what mail says


def test_new_conversation_can_open_with_the_digest_greeting(env):
    make, _, _ = env
    client, service, fake = make([done("Tomorrow is light: gym at 19:00.\n---\n- x"),
                                  done("Moved in your head, at least."), done("Gym tomorrow")], Calendar([]))
    client.post("/v1/digest/run", json={"kind": "evening"}, headers=AUTH)

    new = client.post("/v1/conversations", json={"digest": "evening"}, headers=AUTH).json()
    assert new["preview"] == "Tomorrow is light: gym at 19:00." and new["title"] is None
    history = client.get(f"/v1/history?conversation_id={new['id']}", headers=AUTH).json()["messages"]
    assert [(m["role"], m["text"]) for m in history] == [("assistant", "Tomorrow is light: gym at 19:00.")]
    assert len(fake.requests) == 1  # today's stored evening greeting was reused

    client.post("/v1/chat", json={"text": "make gym 20:00", "conversation_id": new["id"]}, headers=AUTH)
    sent = fake.requests[1]["messages"]
    assert sent[0]["role"] == "user" and sent[1]["role"] == "assistant"
    assert sent[1]["content"][0]["text"] == "Tomorrow is light: gym at 19:00."  # the model knows it said it
    rows = client.get("/v1/conversations", headers=AUTH).json()["conversations"]
    assert next(r for r in rows if r["id"] == new["id"])["title"] == "Gym tomorrow"

    plain = client.post("/v1/conversations", json={}, headers=AUTH).json()
    assert plain["preview"] is None
    assert client.get(f"/v1/history?conversation_id={plain['id']}", headers=AUTH).json()["messages"] == []
    assert client.post("/v1/conversations", json={"digest": "yearly"}, headers=AUTH).status_code == 400


def test_opening_makes_a_fresh_digest_when_the_stored_one_is_stale(env):
    make, _, _ = env
    client, service, fake = make([done("Fresh one.\n---\n- x")], Calendar([]))
    stale = {"kind": "daily", "generated_at": "2026-01-01T08:00:00+01:00", "greeting": "Old news.", "sections": []}
    service._store("daily", datetime(2026, 1, 1, 7, tzinfo=ROME), stale)
    new = client.post("/v1/conversations", json={"digest": "daily"}, headers=AUTH).json()
    assert new["preview"] == "Fresh one." and len(fake.requests) == 1
