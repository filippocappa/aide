import asyncio
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from aide.db import Database
from aide.locks import LockStore
from aide.nudges import Nudges, bedtime_steps
from test_api import AUTH, ROME, env  # noqa: F401: the API fixture

NOW = datetime(2026, 11, 23, 22, 30, tzinfo=ROME)  # Monday evening
BED = datetime(2026, 11, 24, 0, 0, tzinfo=ROME)


class Bedtime:
    def __init__(self, bed=BED, wake=BED + timedelta(hours=8)):
        self.plan = {"date": wake.date().isoformat(), "bedtime": bed.isoformat(), "wake": wake.isoformat()}

    async def tonight(self, now=None):
        return self.plan


class Calendar:
    def __init__(self, *events):
        self.found = list(events)

    async def __call__(self, start, end):
        return [e for e in self.found if e["start"] < end.isoformat() and e["end"] > start.isoformat()]


def event(title, start: datetime, minutes=120, calendar="Work", notes="", all_day=False):
    return {"id": title, "title": title, "calendar": calendar, "start": start.isoformat(),
            "end": (start + timedelta(minutes=minutes)).isoformat(), "all_day": all_day, "notes": notes}


class Focus:
    def __init__(self, on=False):
        self.on = on

    def current(self, now=None):
        return {"public_id": "f_1"} if self.on else None


@pytest.fixture
def db():
    db = Database(":memory:")
    db.conn.executescript("CREATE TABLE IF NOT EXISTS courses (id INTEGER PRIMARY KEY, name TEXT UNIQUE);")
    db.conn.executemany("INSERT INTO courses (id, name) VALUES (?, ?)",
                        [(1, "Macroeconomics"), (2, "Business law"), (3, "Mathematics II")])
    yield db
    db.close()


def nudges(db, *events, bed=True, focus=False) -> Nudges:
    return Nudges(db.conn, ROME, Bedtime() if bed else None, Calendar(*events), "Work", LockStore(db.conn, ROME),
                  Focus(focus))


def test_the_steps_get_firmer_and_repeat_after_bedtime():
    steps = bedtime_steps(BED)
    assert [s["step"] for s in steps[:4]] == ["hour", "half", "now", "late"]
    assert [datetime.fromisoformat(s["at"]).strftime("%H:%M") for s in steps[:5]] == [
        "23:00", "23:30", "23:50", "00:00", "00:10"]
    assert steps[0]["body"] == "Start wrapping up: in bed by 0:00."
    assert steps[2]["body"] == "It's time to sleep: stop what you're doing."
    assert steps[4]["body"] == "It's 0:10, 10 min past bedtime: stop what you're doing."
    # Each runs until the next; the last ten minutes after three hours past bedtime.
    assert all(a["until"] == b["at"] for a, b in zip(steps, steps[1:]))
    assert datetime.fromisoformat(steps[-1]["at"]) == BED + timedelta(hours=3)
    assert len(steps) == 3 + 19


def test_the_plan_has_tonights_steps_the_events_and_the_work_list(db):
    lecture = event("Macroeconomics", NOW.replace(hour=9), calendar="Work")
    review = event("Review: Business law", NOW + timedelta(hours=12))
    asked = event("Write the essay #focus", NOW + timedelta(minutes=10), calendar="Personal")
    tagged = event("Thesis", NOW + timedelta(hours=1), calendar="Personal", notes="deep work #Focus")
    movie = event("Movie with Marta", NOW - timedelta(minutes=30), calendar="Personal")
    whole = event("Holiday", NOW.replace(hour=0), minutes=1440, calendar="Personal", all_day=True)
    n = nudges(db, lecture, review, asked, tagged, movie, whole)
    plan = asyncio.run(n.plan(NOW.astimezone(timezone.utc)))
    assert plan["bedtime"]["date"] == "2026-11-24" and plan["bedtime"]["steps"][0]["step"] == "hour"
    kinds = {e["title"]: (e["kind"], e["course"]) for e in plan["events"]}
    assert "Macroeconomics" not in kinds  # over this morning
    assert "Holiday" not in kinds  # all day
    assert kinds["Review: Business law"] == ("study", {"id": 2, "name": "Business law"})
    assert kinds["Write the essay"] == ("asked", None)
    assert kinds["Thesis"] == ("asked", None)
    assert kinds["Movie with Marta"] == ("other", None)
    assert plan["list"]["name"] == "Work" and plan["focus"] is False


def test_no_bedtime_steps_long_after_bedtime_or_without_a_plan(db):
    n = nudges(db)
    late = (BED + timedelta(hours=3, minutes=11)).astimezone(timezone.utc)
    assert asyncio.run(n.plan(late))["bedtime"] is None
    assert asyncio.run(nudges(db, bed=False).plan(NOW))["bedtime"] is None


def test_a_focus_session_on_now_is_said(db):
    assert asyncio.run(nudges(db, focus=True).plan(NOW))["focus"] is True


def test_courses_from_event_titles(db):
    n = nudges(db)
    assert n.course_for("Macroeconomics")["id"] == 1
    assert n.course_for("Study Macro")["id"] == 1
    assert n.course_for("Review: Mathematics II")["id"] == 3
    assert n.course_for("Business law (2nd mid-term)")["id"] == 2
    assert n.course_for("Gym") is None
    assert n.course_for("Study") is None


def test_a_nudge_and_its_answer_are_one_row(db):
    n = nudges(db)
    shown = {"key": "mac-bed-2026-11-24-half", "device": "mac", "kind": "bedtime", "step": "half",
             "at": "2026-11-23T22:31:00Z", "night": "2026-11-24", "app": "Xcode"}
    row = n.log(shown, NOW)
    assert row["answer"] is None and row["at"] == "2026-11-23T22:31:00+00:00"
    row = n.log({**shown, "answer": "snooze"}, NOW + timedelta(minutes=1))
    assert row["answer"] == "snooze" and row["answered_at"]
    row = n.log(shown, NOW + timedelta(minutes=2))  # sent again without the answer: kept
    assert row["answer"] == "snooze"
    assert db.conn.execute("SELECT COUNT(*) FROM nudges").fetchone()[0] == 1


@pytest.mark.parametrize("body", [
    {"device": "mac", "kind": "bedtime", "step": "half"},  # no key
    {"key": "k", "device": "mac", "kind": "nap", "step": "half"},
    {"key": "k", "device": "mac", "kind": "bedtime", "step": "first"},
    {"key": "k", "device": "watch", "kind": "bedtime", "step": "half"},
    {"key": "k", "device": "mac", "kind": "offtask", "step": "first", "answer": "snooze"},
])
def test_bad_nudges_are_refused(db, body):
    with pytest.raises(ValueError):
        nudges(db).log(body, NOW)


def test_the_agents_see_what_happened(db):
    n = nudges(db)
    for key, step, at, answer in (("a", "hour", "22:00", None), ("b", "half", "22:30", "snooze"),
                                  ("c", "late", "23:20", "going")):
        n.log({"key": key, "device": "mac", "kind": "bedtime", "step": step, "at": f"2026-11-23T{at}:00Z",
               "night": "2026-11-24", "app": "Xcode", "answer": answer}, NOW)
    n.log({"key": "p", "device": "phone", "kind": "bedtime", "step": "now", "at": "2026-11-23T22:52:00Z",
           "night": "2026-11-24"}, NOW)
    line = n.night_line("2026-11-24")
    assert line.startswith("4 bedtime nudges while still active: Mac 23:00 on Xcode, 23:30 (snoozed) on Xcode")
    assert "phone 23:52" in line and line.endswith("the last at 0:20.")

    study = {"device": "mac", "kind": "offtask", "event": "Study Macro", "event_start": "2026-11-24T14:00:00Z",
             "event_end": "2026-11-24T16:00:00Z", "course_id": 1}
    n.log({**study, "key": "o1", "step": "first", "at": "2026-11-24T14:20:00Z", "app": "youtube.com",
           "answer": "back"}, NOW)
    n.log({**study, "key": "o2", "step": "again", "at": "2026-11-24T14:41:00Z", "app": "youtube.com"}, NOW)
    evening = datetime(2026, 11, 24, 22, 0, tzinfo=ROME)
    lines = n.evening_lines(evening)
    assert lines[0] == ("Tue 24 Nov, Study Macro 15:00–17:00: on youtube.com at 15:20 on the mac (went back to it); "
                        "again on youtube.com at 15:41 on the mac (no answer).")
    assert lines[1].startswith("Last night: 4 bedtime nudges")
    assert "Study Macro" in n.study_text(evening, course_id=1)
    assert n.study_text(evening, course_id=2) is None
    assert n.week_nights(["2026-11-24", "2026-11-23"]) == ["- Tue 24 Nov: " + line]


def test_the_api_gives_the_plan_and_keeps_nudges(env):  # noqa: F811
    client, agent, _ = env()
    LockStore(agent.db.conn, ROME)  # the lists, seeded
    plan = client.get("/v1/nudges", headers=AUTH).json()
    assert plan["bedtime"] is None and plan["events"] == [] and plan["list"]["name"] == "Work"
    body = {"key": "mac-1", "device": "mac", "kind": "offtask", "step": "first", "event": "Study Macro"}
    assert client.post("/v1/nudges", json=body, headers=AUTH).json()["key"] == "mac-1"
    r = client.post("/v1/nudges", json={**body, "answer": "back"}, headers=AUTH)
    assert r.json()["answer"] == "back"
    assert client.post("/v1/nudges", json={**body, "answer": "maybe"}, headers=AUTH).status_code == 422


def test_the_third_off_task_step_locks_the_work_list_once_per_event(db):
    n = nudges(db)
    work = n._list()
    study = {"kind": "offtask", "step": "lock", "event": "Review: Business law",
             "event_start": "2026-11-23T21:00:00Z", "event_end": "2026-11-23T23:00:00Z", "course_id": 2,
             "app": "youtube.com"}
    now = NOW.astimezone(timezone.utc)
    row = n.log({**study, "key": "mac-lock", "device": "mac", "at": now.isoformat()}, now)
    lock = row["lock"]
    assert lock["title"] == "Off task: Review: Business law" and lock["list_id"] == work["id"]
    assert lock["agent"] == "coach" and not lock["strict"]
    assert datetime.fromisoformat(lock["ends_at"]) - datetime.fromisoformat(lock["starts_at"]) == timedelta(minutes=15)
    # the same device again (a retry), then the phone for the same event: no second lock
    assert n.log({**study, "key": "mac-lock", "device": "mac", "at": now.isoformat()}, now)["lock"] is None
    later = now + timedelta(minutes=20)  # the Mac's lock is over by now
    assert n.log({**study, "key": "phone-lock", "device": "phone", "at": later.isoformat()}, later)["lock"] is None
    assert len([l for l in n.locks.all(now) if l["title"].startswith("Off task")]) == 1
    assert "locked for 15 min at 22:30 (mac)" in n.offtask_lines(now - timedelta(hours=1))[0]


def test_no_off_task_lock_during_a_focus_session(db):
    n = nudges(db, focus=True)
    row = n.log({"key": "k", "device": "mac", "kind": "offtask", "step": "lock", "event": "Study Macro"},
                NOW.astimezone(timezone.utc))
    assert row["lock"] is None
    assert not any(l["title"].startswith("Off task") for l in n.locks.all(NOW))
