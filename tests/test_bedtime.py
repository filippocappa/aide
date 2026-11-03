from datetime import date, datetime, timedelta, timezone

import httpx
import pytest

from aide.bedtime import Bedtime, bedtime_tools, usual_wake
from aide.db import Database
from aide.health import HealthStore
from aide.live import LiveActivities
from aide.locks import LockStore
from aide.push import Push
from test_push import APNs, key  # noqa: F401: the key fixture

ROME = __import__("zoneinfo").ZoneInfo("Europe/Rome")
WED = date(2026, 11, 4)  # the morning tonight's plan is for (Tuesday night)
START = "c3" * 32
ACTIVITY = "d4" * 32


def night(d: date, asleep_at="23:30", wake="07:30", awake=20) -> dict:
    """A health day for the morning `d`: asleep at `asleep_at` the evening before, up at `wake`."""
    h, m = map(int, asleep_at.split(":"))
    start = datetime.combine(d - timedelta(days=1 if h >= 12 else 0), datetime.min.time(), ROME).replace(hour=h, minute=m)
    wh, wm = map(int, wake.split(":"))
    end = datetime.combine(d, datetime.min.time(), ROME).replace(hour=wh, minute=wm)
    in_bed = round((end - start).total_seconds() / 60)
    return {"date": d.isoformat(), "sleep": {"bedtime": start.isoformat(), "wake": end.isoformat(),
                                             "asleep_min": in_bed - awake, "in_bed_min": in_bed, "awake_min": awake,
                                             "deep_min": 70, "rem_min": 100}}


def nights(n=28, weekday="07:15", weekend="09:00", asleep=450) -> list[dict]:
    out = []
    for i in range(1, n + 1):
        d = WED - timedelta(days=i)
        wake = weekend if d.weekday() >= 5 else weekday
        wh, wm = map(int, wake.split(":"))
        asleep_at = datetime.combine(d, datetime.min.time(), ROME).replace(hour=wh, minute=wm) - timedelta(
            minutes=asleep + 20)
        out.append(night(d, f"{asleep_at:%H:%M}", wake))
    return out


class Calendar:
    def __init__(self, events=()):
        self.found = list(events)

    async def __call__(self, start, end):
        return [e for e in self.found if start.isoformat() <= e["start"] < end.isoformat()]


def event(title, at: datetime, all_day=False):
    return {"id": title, "title": title, "start": at.isoformat(), "end": (at + timedelta(hours=1)).isoformat(),
            "all_day": all_day, "location": "Politecnico", "calendar": "Work"}


@pytest.fixture
def env(key):  # noqa: F811
    db = Database(":memory:")
    apns = APNs()
    push = Push(db.conn, key[0], "KEY123", "TEAM456", "com.filippocappa.aide", httpx.MockTransport(apns.handle))
    health = HealthStore(db.conn, ROME)
    health.save(nights())
    yield db, health, push, LiveActivities(db.conn, push), apns
    db.close()


def make(env, events=(), leave=None):
    db, health, push, live, _ = env

    async def leave_at(e):
        return leave
    return Bedtime(db.conn, ROME, health, push, live, LockStore(db.conn, ROME), Calendar(events), leave_at)


def local(value: str) -> str:
    return f"{datetime.fromisoformat(value).astimezone(ROME):%H:%M}"


def aps(apns):
    return [p["aps"] for p in apns.payloads()]


def test_the_usual_wake_is_learnt_weekdays_and_weekends_apart(env):
    days = env[1]._window(WED, WED)
    assert usual_wake(days, WED, ROME) == "07:15"
    assert usual_wake(days, date(2026, 11, 7), ROME) == "09:00"
    assert usual_wake({}, WED, ROME) is None
    assert make(env).usual(datetime(2026, 11, 3, 20, 0, tzinfo=ROME)) == {"weekdays": "07:15", "weekends": "09:00"}


async def test_tonights_bedtime_is_the_wake_less_the_need_awake_and_falling_asleep(env):
    b = make(env)
    plan = await b.plan(WED)
    assert (local(plan["wake"]), plan["wake_source"], plan["earlier_min"]) == ("07:15", "learnt", 0)
    # 7h30 need, 20 min awake in the night, 15 to fall asleep: 7:15 − 8h05 = 23:10
    assert (plan["need_min"], plan["awake_min"], local(plan["bedtime"]), local(plan["asleep_by"])) == \
        (450, 20, "23:10", "23:25")
    assert local(plan["nudge_at"]) == "22:25"
    assert plan["why"] == "In bed by 23:10 to get 7h30 asleep, up at 7:15 as usual."


async def test_an_early_start_moves_the_wake_only_when_it_has_to(env):
    nine = datetime(2026, 11, 4, 9, 0, tzinfo=ROME)
    b = make(env, [event("Lecture", nine)], (nine - timedelta(minutes=35), "tram, 25 min"))
    plan = await b.plan(WED)
    assert local(plan["wake"]) == "07:15" and plan["earlier_min"] == 0  # 8:25 − 45 min = 7:40: no need
    assert plan["why"] == "In bed by 23:10 to get 7h30 asleep before 9:00 Lecture, up at 7:15 as usual."
    eight = datetime(2026, 11, 4, 8, 0, tzinfo=ROME)
    b = make(env, [event("Exam", eight)], (eight - timedelta(minutes=40), "tram, 30 min"))
    plan = await b.plan(WED)
    assert (local(plan["wake"]), plan["earlier_min"], local(plan["bedtime"])) == ("06:35", 40, "22:30")
    assert plan["event"] == {"title": "Exam", "start": eight.isoformat(),
                             "leave": (eight - timedelta(minutes=40)).isoformat(), "how": "tram, 30 min"}
    assert plan["why"] == ("In bed by 22:30 to get 7h30 asleep before 8:00 Exam: up at 6:35, 40 min earlier than "
                           "usual.")


async def test_a_set_wake_wins_and_an_all_day_or_afternoon_event_doesnt_count(env):
    b = make(env, [event("Holiday", datetime(2026, 11, 4, 0, 0, tzinfo=ROME), all_day=True),
                   event("Gym", datetime(2026, 11, 4, 15, 0, tzinfo=ROME))])
    b.update_settings(wake_weekdays="07:00")
    plan = await b.plan(WED)
    assert (local(plan["wake"]), plan["wake_source"], plan["event"]) == ("07:00", "set", None)
    with pytest.raises(ValueError):
        b.update_settings(wake_weekdays="7am")
    with pytest.raises(ValueError):
        b.update_settings(snooze=True)


async def test_the_evening_nudge_starts_a_countdown_once(env):
    db, health, push, live, apns = env
    b = make(env)
    live.set_start_token("bedtime", START, "sandbox")
    tue = datetime(2026, 11, 3, 22, 0, tzinfo=ROME)
    await b.tick(tue.astimezone(timezone.utc))
    assert apns.requests == []  # 22:25 not yet
    await b.tick((tue + timedelta(minutes=26)).astimezone(timezone.utc))
    [start] = aps(apns)
    assert start["attributes-type"] == "BedtimeActivityAttributes"
    assert start["attributes"] == {"key": "bedtime:2026-11-04", "title": "Bedtime"}
    bed = datetime(2026, 11, 3, 23, 10, tzinfo=ROME)
    assert start["content-state"]["bedtime"] == int(bed.timestamp()) and start["content-state"]["over"] is False
    assert start["alert"] == {"title": "Bedtime at 23:10", "body": "In bed by 23:10 to get 7h30 asleep, up at 7:15 as usual."}
    await b.tick((tue + timedelta(minutes=40)).astimezone(timezone.utc))
    assert len(apns.requests) == 1
    live.register("bedtime:2026-11-04", ACTIVITY, "sandbox")
    await b.tick((bed + timedelta(minutes=1)).astimezone(timezone.utc))
    end = aps(apns)[-1]
    assert end["event"] == "end" and end["content-state"]["over"] is True
    await b.tick((bed + timedelta(minutes=5)).astimezone(timezone.utc))
    assert len(apns.requests) == 2


async def test_without_a_start_token_a_plain_push_and_the_wind_down_lock(env):
    db, health, push, live, apns = env
    push.register("ab" * 32, "sandbox")
    b = make(env)
    b.update_settings(wind_down=True)
    nudge = datetime(2026, 11, 3, 22, 26, tzinfo=ROME).astimezone(timezone.utc)
    await b.tick(nudge)
    [p] = apns.payloads()
    assert p["aide"] == {"kind": "bedtime", "date": "2026-11-04"} and p["aps"]["alert"]["title"] == "Bedtime at 23:10"
    [lock] = b.locks.all(nudge)
    assert lock["title"] == "Bedtime" and local(lock["starts_at"]) == "23:10" and local(lock["ends_at"]) == "07:15"
    assert b._row(WED)["lock"] == lock["id"]


async def test_a_nudge_missed_by_a_long_way_isnt_sent(env):
    db, health, push, live, apns = env
    push.register("ab" * 32, "sandbox")
    b = make(env)
    await b.tick(datetime(2026, 11, 4, 1, 0, tzinfo=ROME).astimezone(timezone.utc))
    assert apns.requests == [] and b._row(WED)["nudged"]


async def test_the_morning_after_says_how_close_they_got(env):
    db, health, *_ = env
    b = make(env)
    await b.tonight(datetime(2026, 11, 3, 20, 0, tzinfo=ROME).astimezone(timezone.utc))
    health.save([night(WED, "23:50", "07:20")])
    r = b.review(WED)
    assert (r["asleep_off_min"], r["wake_off_min"]) == (25, 5)
    line = b.review_line(WED)
    assert line.startswith("Last night's bedtime plan: asleep by 23:25, up at 7:15. They fell asleep at 23:50 "
                           "(25 min late) and got up at 7:20 (on time).")
    assert "Tonight" not in b.week_text(datetime(2026, 11, 4, 9, 0, tzinfo=ROME).astimezone(timezone.utc))
    assert "- Wed 04 Nov: asleep 23:50 (25 min late), up 7:20 (on time)" in b.week_text(
        datetime(2026, 11, 4, 9, 0, tzinfo=ROME).astimezone(timezone.utc))


async def test_a_plan_made_after_the_bedtime_isnt_judged(env):
    db, health, *_ = env
    b = make(env)
    await b.tonight(datetime(2026, 11, 4, 1, 0, tzinfo=ROME).astimezone(timezone.utc))
    health.save([night(WED, "23:50", "07:20")])
    assert b.review(WED) is None


async def test_coachs_tools(env):
    b = make(env)
    read, change = bedtime_tools(b)
    assert "Tonight: In bed by" in await read.handler() or "Bedtime plan: on" in await read.handler()
    out = await change.handler(enabled=None, wake_weekdays="06:45", wake_weekends="learn", ready_min=None,
                               lead_min=30, wind_down=None)
    assert out.startswith("Saved.") and b.settings()["wake_weekdays"] == "06:45" and b.settings()["lead_min"] == 30
    assert b.settings()["wake_weekends"] is None


def test_the_digest_card_and_its_text(env):
    from aide.digest import to_text
    plan = {"why": "In bed by 23:10 to get 7h30 asleep, up at 7:15 as usual."}
    s = make(env).section(plan)
    assert s == {"type": "bedtime", "title": "Tonight", "bedtime": plan}
    assert to_text(None, [s], ROME) == "**Tonight**\n• In bed by 23:10 to get 7h30 asleep, up at 7:15 as usual."
