import asyncio
import sqlite3
import time as wallclock
from datetime import date, datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from aide import wake as wake_mod
from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.digest import DEFAULT_SETTINGS, DigestService, to_text
from aide.habits import HabitStore
from aide.health import HealthStore, recovery
from aide.icloud import CalEvent
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.health import health_tools
from aide.transit import Location
from aide.wake import WakeService
from test_api import AUTH, ROME, TOKEN, FakeClient, done
from test_digest import Calendar

TODAY = datetime.now(ROME).date()
MORNING = datetime.combine(TODAY, datetime.min.time(), ROME).replace(hour=8)


def night(d: date, asleep=420, wake_hour=7, **extra) -> dict:
    """A health day for `d` whose sleep ended at wake_hour that morning."""
    wake = datetime.combine(d, datetime.min.time(), ROME).replace(hour=wake_hour)
    return {"date": d.isoformat(), "sleep": {"bedtime": (wake - timedelta(minutes=asleep + 20)).isoformat(),
                                             "wake": wake.isoformat(), "asleep_min": asleep, "deep_min": None},
            **extra}


def workout(id, type="strength", minutes=52, day=TODAY):
    start = datetime.combine(day, datetime.min.time(), ROME).replace(hour=6)
    return {"id": id, "type": type, "start": start.isoformat(),
            "end": (start + timedelta(minutes=minutes)).isoformat(), "minutes": minutes, "kcal": 310}


class Push:
    def __init__(self):
        self.sent = []

    async def send_digest(self, kind, greeting, month=None):
        self.sent.append((kind, greeting))
        return True


class Maps:
    """Minutes per travel mode; transit rides a tram."""

    def __init__(self, walk=25, transit=15):
        self.minutes, self.bodies = {"WALK": walk, "TRANSIT": transit}, []

    async def route(self, body):
        self.bodies.append(body)
        out = {"duration": f"{self.minutes[body['travelMode']] * 60}s"}
        if body["travelMode"] == "TRANSIT":
            out["legs"] = [{"steps": [{}, {"transitDetails": {"transitLine": {"vehicle": {"name": {"text": "Tram"}}}}}]}]
        return out


@pytest.fixture
def world():
    db = Database(":memory:")
    store, habits, health = ReminderStore(db.conn), HabitStore(db.conn, ROME), HealthStore(db.conn, ROME)

    def make(responses=(), events=(), maps=None, clock=lambda: MORNING):
        client = FakeClient(responses)
        client.requests = []
        create = client.beta.messages.create

        async def spy(**kwargs):
            client.requests.append(kwargs)
            return await create(**kwargs)
        client.beta.messages.create = spy
        cal = Calendar(events)
        digest = DigestService(db.conn, client, "m", ROME, store, habits, cal, None, health, maps,
                               "Via Roma 1, Milano" if maps else None)
        push = Push()
        wake = WakeService(digest, health, ROME, push, clock)
        agent = Agent(client, db, ToolRegistry([]), model="m", tz=ROME)
        app = create_app(agent, store, cal, ROME, TOKEN, habits, digest, health=health, wake=wake)
        return SimpleNamespace(db=db, http=TestClient(app), app=app, digest=digest, wake=wake, push=push, model=client,
                               health=health, habits=habits)
    yield make
    db.close()


# -- storage -------------------------------------------------------------------


def test_upload_replaces_by_date_and_drops_nulls(world):
    w = world()
    day = {"date": TODAY.isoformat(), "steps": 100, "resting_hr": None, "sleep": None, "workouts": []}
    r = w.http.post("/v1/health/days", json={"days": [day]}, headers=AUTH).json()
    assert r == {"ok": True, "saved": 1, "checked": []}
    w.http.post("/v1/health/days", json={"days": [{**day, "steps": 8432}]}, headers=AUTH)
    assert w.http.get("/v1/health/days", headers=AUTH).json() == {
        "days": [{"date": TODAY.isoformat(), "steps": 8432, "workouts": []}]}


def test_get_range_newest_first_and_limits(world):
    w = world()
    days = [{"date": (TODAY - timedelta(days=i)).isoformat(), "steps": i} for i in range(40)]
    assert w.http.post("/v1/health/days", json={"days": days}, headers=AUTH).json()["saved"] == 40
    default = w.http.get("/v1/health/days", headers=AUTH).json()["days"]
    assert len(default) == 30 and default[0]["steps"] == 0 and default[-1]["steps"] == 29
    span = w.http.get(f"/v1/health/days?from={TODAY - timedelta(days=12)}&to={TODAY - timedelta(days=10)}",
                      headers=AUTH).json()["days"]
    assert [d["steps"] for d in span] == [10, 11, 12]
    too_many = [{"date": (TODAY - timedelta(days=i)).isoformat()} for i in range(91)]
    for bad in ({"days": too_many}, {"days": [{"date": "yesterday"}]}, {"days": [{"date": "2026-10-19", "workouts": [{}]}]}):
        r = w.http.post("/v1/health/days", json=bad, headers=AUTH)
        assert r.status_code == 400 and "error" in r.json()
    assert w.http.get("/v1/health").json()["ok"] is True  # liveness, no token
    assert w.http.get("/v1/health/days").status_code == 401


# -- habits and workouts -------------------------------------------------------


def test_habit_workouts_create_and_patch(world):
    w = world()
    gym = w.http.post("/v1/habits", json={"name": "Gym", "cadence": {"type": "weekly", "per_week": 3},
                                          "workouts": ["Strength", "hiit", "strength"]}, headers=AUTH).json()
    assert gym["workouts"] == ["strength", "hiit"]
    w.http.post("/v1/habits", json={"name": "Read"}, headers=AUTH)
    r = w.http.patch(f"/v1/habits/{gym['id']}", json={"workouts": ["any"]}, headers=AUTH).json()
    assert r["workouts"] == ["any"] and r["name"] == "Gym" and r["cadence"] == {"type": "weekly", "per_week": 3}
    r = w.http.patch(f"/v1/habits/{gym['id']}", json={"name": "Train", "cadence": {"type": "daily"}}, headers=AUTH).json()
    assert (r["name"], r["cadence"], r["workouts"]) == ("Train", {"type": "daily"}, ["any"])
    assert w.http.patch(f"/v1/habits/{gym['id']}", json={"name": "read"}, headers=AUTH).status_code == 400
    assert w.http.patch(f"/v1/habits/{gym['id']}", json={"cadence": {"type": "weekly"}}, headers=AUTH).status_code == 400
    assert w.http.patch("/v1/habits/99", json={"name": "X"}, headers=AUTH).status_code == 404


def test_workouts_check_habits_once(world):
    w = world()
    gym = w.habits.add("Gym", 3, ["strength"])
    move = w.habits.add("Move", None, ["any"])
    odd = w.habits.add("Odd", None, ["other"])
    w.habits.add("Read")
    yesterday = TODAY - timedelta(days=1)
    day = {"date": yesterday.isoformat(), "workouts": [workout("W1", day=yesterday), workout("W2", "run", 9, yesterday),
                                                       workout("W3", "padel", 30, yesterday)]}
    r = w.http.post("/v1/health/days", json={"days": [day]}, headers=AUTH).json()
    assert sorted(h["name"] for h in r["checked"]) == ["Gym", "Move", "Odd"]
    assert w.habits.get(gym.id).last_done == yesterday
    w.http.post(f"/v1/habits/{gym.id}/check", json={"date": yesterday.isoformat(), "done": False}, headers=AUTH)
    r = w.http.post("/v1/health/days", json={"days": [day]}, headers=AUTH).json()
    assert r["checked"] == [] and w.habits.get(gym.id).last_done is None  # the undo stays
    assert w.habits.get(move.id).last_done == w.habits.get(odd.id).last_done == yesterday


def test_habits_table_gets_workouts_column():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE TABLE habits (id INTEGER PRIMARY KEY, name TEXT NOT NULL, per_week INTEGER, "
                 "created_at TEXT NOT NULL)")
    conn.execute("INSERT INTO habits VALUES (1, 'Gym', NULL, '2026-10-01T00:00:00+00:00')")
    assert HabitStore(conn, ROME).get(1).workouts == ()


# -- sleep and recovery --------------------------------------------------------


def history(health, n, hrv=55.0, rhr=54, asleep=438):
    health.save([night(TODAY - timedelta(days=i), asleep, hrv_ms=hrv, resting_hr=rhr) for i in range(1, n + 1)])


def test_recovery_levels():
    assert recovery(61.5, 55, 52, 54) == ("good", "HRV above your usual, resting heart rate below your usual.")
    assert recovery(55, 55, 54, 54) == ("good", "HRV about your usual, resting heart rate normal for you.")
    assert recovery(50, 55, 54, 54)[0] == "normal"
    assert recovery(56, 55, 56, 54)[0] == "normal"
    assert recovery(46, 55, 54, 54) == ("low", "HRV well below your usual, resting heart rate normal for you.")
    assert recovery(60, 55, 59, 54)[0] == "low"


def test_sleep_and_recovery_sections(world):
    w = world()
    health = w.health
    health.save([night(TODAY, 400, hrv_ms=61.5, resting_hr=52)])
    assert health.sleep_section(TODAY)["usual_asleep_min"] is None and health.recovery_section(TODAY) is None
    history(health, 7)
    assert health.sleep_section(TODAY)["usual_asleep_min"] == 438
    assert health.recovery_section(TODAY) is None  # under 14 days
    history(health, 14, hrv=55.0, rhr=54)
    rec = health.recovery_section(TODAY)
    assert rec == {"type": "recovery", "title": "Recovery", "level": "good",
                   "summary": "HRV above your usual, resting heart rate below your usual.",
                   "hrv_ms": 61.5, "hrv_usual_ms": 55.0, "resting_hr": 52, "resting_hr_usual": 54}
    health.save([{"date": (TODAY - timedelta(days=31)).isoformat(), "hrv_ms": 1, "resting_hr": 200}])  # outside
    assert health.recovery_section(TODAY) == rec


async def test_daily_has_sleep_and_recovery_first(world):
    w = world([done("Hi.\n---\n- ahead")])
    history(w.health, 14)
    w.health.save([night(TODAY, 400, hrv_ms=40.0, resting_hr=60)])
    d = await w.digest.generate("daily", MORNING)
    assert [s["type"] for s in d["sections"]][:3] == ["sleep", "recovery", "calendar"]
    assert d["sections"][1]["level"] == "low"
    text = to_text(None, d["sections"], ROME)
    assert "**Last night**\n• Asleep 6h40 (usual 7h18), 00:00–07:00" in text
    assert "**Recovery**\n• HRV well below your usual, resting heart rate well above your usual." in text
    view = await w.digest.view("daily")
    assert view["sections"][0]["type"] == "sleep"


# -- settings --------------------------------------------------------------------


def test_wake_setting(world):
    w = world()
    assert w.http.get("/v1/digest/settings", headers=AUTH).json()["wake"] == {"enabled": True}
    off = {**DEFAULT_SETTINGS, "wake": {"enabled": False}}
    assert w.http.put("/v1/digest/settings", json=off, headers=AUTH).json()["wake"] == {"enabled": False}
    old_app = {k: v for k, v in DEFAULT_SETTINGS.items() if k not in ("wake", "evening")}
    assert w.http.put("/v1/digest/settings", json=old_app, headers=AUTH).json()["wake"] == {"enabled": False}
    assert list(w.http.get("/v1/digest/settings", headers=AUTH).json()) == [
        "daily", "wake", "evening", "weekly", "monthly"]


# -- the wake-up briefing ----------------------------------------------------------


async def settle(w, rounds=200):
    for _ in range(rounds):
        await asyncio.sleep(0)
        if w.wake._task and w.wake._task.done():
            return


async def test_wake_signal_rules(world):
    w = world([done("Morning.\n---\n- x")])
    w.health.save([night(TODAY)])
    assert w.wake.signal(MORNING.replace(hour=2)) == (False, "outside_hours")
    assert w.wake.signal(MORNING.replace(hour=15)) == (False, "outside_hours")
    assert w.wake.signal(MORNING) == (True, None)
    assert w.wake.signal(MORNING) == (False, "already")  # while it's being made
    await settle(w)
    assert w.wake.signal(MORNING.replace(hour=9)) == (False, "already")  # done today
    w.digest.save_settings({**w.digest.settings(), "wake": {"enabled": False}})
    assert w.wake.signal(MORNING) == (False, "off")
    assert w.push.sent == [("wake", "Morning.")]
    assert w.digest.latest("wake")["greeting"] == "Morning."


async def test_wake_greeting_knows_time_sleep_and_when_to_leave(world):
    lecture = MORNING.replace(hour=9, minute=30)
    maps = Maps(walk=23, transit=15)
    w = world([done("Morning.\n---\n- x")], [CalEvent("e1", "Uni", "Lecture", lecture, lecture + timedelta(hours=2),
                                                      "Città Studi")], maps)
    history(w.health, 14)
    w.health.save([night(TODAY, 400, hrv_ms=61.5, resting_hr=52)])
    assert w.wake.signal(MORNING.replace(minute=10))[0]
    await settle(w)
    prompt = w.model.requests[0]["messages"][0]["content"]
    assert "They got up at 08:10." in prompt
    assert ("Next: Lecture at 09:30 at Città Studi. To be there 10 min early, from home: "
            "walk: leave by 8:55 (23 min), tram: leave by 9:05 (15 min).") in prompt
    assert "Asleep 6h40 (usual 7h18)" in prompt and "HRV above your usual" in prompt
    assert "wake-up briefing" in w.model.requests[0]["system"] and "medical" in w.model.requests[0]["system"]
    walk, transit = sorted(maps.bodies, key=lambda b: b["travelMode"], reverse=True)
    assert walk == {"origin": {"address": "Via Roma 1, Milano"}, "destination": {"address": "Città Studi"},
                    "travelMode": "WALK"}
    arrive = datetime.fromisoformat(transit["arrivalTime"].replace("Z", "+00:00")).astimezone(ROME)
    assert transit["travelMode"] == "TRANSIT" and arrive == lecture - timedelta(minutes=10)
    assert w.push.sent == [("wake", "Morning.")]
    d = w.digest.latest("wake")
    assert [s["type"] for s in d["sections"]][:2] == ["sleep", "recovery"]


async def leave_line(world, maps, responses=(), memories=(), agent=None, phone=None):
    """The leave-by line the wake greeting's model is given, for a 9:30 lecture at Città Studi. `phone`: where the
    phone slept, (lat, lon)."""
    lecture = MORNING.replace(hour=9, minute=30)
    w = world([*responses, done("Morning.")], [CalEvent("e1", "Uni", "Lecture", lecture,
                                                        lecture + timedelta(hours=2), "Città Studi")], maps)
    if phone:
        w.digest.whereabouts = Where(w.db)
        w.digest.whereabouts.location.save(*phone, 20, MORNING - timedelta(hours=8))
    for m in memories:
        w.db.add_memory(m, agent)
    await w.digest.generate("wake", MORNING)
    prompt = w.model.requests[-1]["messages"][0]["content"]
    return next(line for line in prompt.splitlines() if line.startswith("Next:")), w


async def test_long_walk_means_transit_only(world):
    line, _ = await leave_line(world, Maps(walk=50, transit=20))
    assert line.endswith("from home: tram: leave by 9:00 (20 min).")


async def test_memory_gives_home_and_mode(world):
    maps = Maps(walk=12)
    plan = done('{"home": "Via Verdi 5, Milano", "mode": "walk"}')
    line, w = await leave_line(world, maps, [plan], ["Home is Via Verdi 5, Milano", "I always walk to uni"])
    assert line.endswith("from home: walk: leave by 9:05 (12 min).")
    assert [b["travelMode"] for b in maps.bodies] == ["WALK"]
    assert maps.bodies[0]["origin"] == {"address": "Via Verdi 5, Milano"}
    ask = w.model.requests[0]["messages"][0]["content"]
    assert "I always walk to uni" in ask and "Città Studi" in ask and "JSON" in w.model.requests[0]["system"]


async def test_memory_says_where_an_event_with_no_place_is(world):
    lecture = MORNING.replace(hour=9, minute=30)
    maps = Maps(walk=50, transit=20)
    w = world([done('{"home": null, "mode": null, "place": "Città Studi", "lines": ["10"]}'), done("Morning.")],
              [CalEvent("e1", "Uni", "Lecture", lecture, lecture + timedelta(hours=2), "")], maps)
    w.db.add_memory("Lectures are at Città Studi")
    await w.digest.generate("wake", MORNING)
    prompt = w.model.requests[-1]["messages"][0]["content"]
    line = next(line for line in prompt.splitlines() if line.startswith("Next:"))
    assert line == ("Next: Lecture at 09:30 at Città Studi (from their notes). To be there 10 min early, from home: "
                    "tram: leave by 9:00 (20 min).")
    assert "Place: none given" in w.model.requests[0]["messages"][0]["content"]


async def test_memory_from_secretary_reaches_the_briefing(world):
    _, w = await leave_line(world, Maps(walk=12), [done('{"home": null, "mode": "walk"}')],
                            ["I always walk to uni"], agent="secretary")
    assert "I always walk to uni" in w.model.requests[0]["messages"][0]["content"]


async def test_other_agents_memory_stays_out_of_the_briefing(world):
    _, w = await leave_line(world, Maps(), [], ["Runs to uni on Fridays"], agent="coach")
    assert len(w.model.requests) == 1  # Coach's notes aren't read: no travel lookup, only the greeting


async def test_memory_without_travel_facts_or_unreadable(world):
    for answer in ('{"home": null, "mode": null}', "no idea"):
        maps = Maps()
        line, _ = await leave_line(world, maps, [done(answer)], ["Likes sushi"])
        assert line.endswith("walk: leave by 8:55 (25 min), tram: leave by 9:05 (15 min).")
        assert {b["origin"]["address"] for b in maps.bodies} == {"Via Roma 1, Milano"}


class Where:
    """Whereabouts with a real Location and a fixed street."""

    def __init__(self, db):
        self.location = Location(db.conn)

    async def address(self, lat, lon):
        return "Piazza di Città 8, Ivrea"


class HomeMaps(Maps):
    """Home (Via Roma 1, Milano, in the fixture) is at 45.4642, 9.19."""

    async def locate(self, query, near=None):
        return {"name": query, "lat": 45.4642, "lon": 9.19}


async def test_far_from_home_means_probably_not_going(world):
    maps = HomeMaps()
    line, _ = await leave_line(world, maps, phone=(45.4669, 7.8763))
    assert "Their phone is near Piazza di Città 8, Ivrea, 102 km from Via Roma 1, Milano" in line
    assert "probably not going" in line and "leave by" not in line
    assert maps.bodies == []  # no travel times looked up


class PlaceMaps(Maps):
    """Home (Via Roma 1, Milano) is in Milan; every other place is in Ivrea, where the phone is."""

    async def locate(self, query, near=None):
        return {"name": query, "lat": 45.4642, "lon": 9.19} if "Milano" in query else \
            {"name": query, "lat": 45.4670, "lon": 7.8760}


async def test_away_from_home_but_near_the_place_leaves_from_the_phone(world):
    maps = PlaceMaps()
    line, _ = await leave_line(world, maps, phone=(45.4669, 7.8763))
    assert "probably not going" not in line
    assert line.endswith("from where their phone is: walk: leave by 8:55 (25 min), tram: leave by 9:05 (15 min).")
    assert maps.bodies[0]["origin"] == {"location": {"latLng": {"latitude": 45.4669, "longitude": 7.8763}}}


async def test_near_home_the_leave_by_stays(world):
    line, _ = await leave_line(world, HomeMaps(), phone=(45.4700, 9.19))
    assert line.endswith("walk: leave by 8:55 (25 min), tram: leave by 9:05 (15 min).")


async def test_wake_waits_for_sleep_then_goes_ahead(world, monkeypatch):
    monkeypatch.setattr(wake_mod, "WAIT", 0.2)
    w = world([done("Up."), done("Up again.")])
    assert w.wake.signal(MORNING)[0]
    await asyncio.sleep(0.05)
    assert w.model.requests == []  # still waiting
    w.health.save([night(TODAY)])
    w.wake.uploaded([night(TODAY, wake_hour=4)])  # too old to be a signal itself; ends the wait
    await settle(w)
    assert len(w.model.requests) == 1 and "No sleep data" not in w.model.requests[0]["messages"][0]["content"]

    tomorrow = MORNING + timedelta(days=1)
    w.wake.now = lambda: tomorrow
    assert w.wake.signal(tomorrow)[0]
    start = wallclock.monotonic()
    await w.wake._task
    assert 0.15 < wallclock.monotonic() - start < 1
    assert "No sleep data for last night yet." in w.model.requests[1]["messages"][0]["content"]


async def test_upload_with_fresh_wake_is_a_signal(world):
    w = world([done("Morning.")])
    w.wake.uploaded(w.health.save([night(TODAY - timedelta(days=1)), night(TODAY, wake_hour=4)]))
    assert w.wake._task is None  # 4 hours ago
    w.wake.uploaded(w.health.save([night(TODAY, wake_hour=7)]))
    await settle(w)
    assert w.push.sent == [("wake", "Morning.")]


def test_wake_endpoint(world):
    w = world([done("Morning.")])
    with w.http as http:  # one event loop for the requests and the briefing behind them
        r = http.post("/v1/wake", json={"at": MORNING.isoformat(), "source": "shortcut",
                                        "day": {**night(TODAY), "workouts": [workout("W9")]}}, headers=AUTH)
        assert r.json() == {"started": True}
        assert http.post("/v1/wake", json={"at": MORNING.isoformat()}, headers=AUTH).json() == {
            "started": False, "reason": "already"}
        assert http.post("/v1/wake", json={"at": MORNING.replace(hour=22).isoformat()}, headers=AUTH).json() == {
            "started": False, "reason": "outside_hours"}
        for _ in range(100):
            if w.digest.latest("wake"):
                break
            wallclock.sleep(0.01)
    assert w.health.get(TODAY)["workouts"][0]["id"] == "W9"
    assert w.digest.latest("wake")["greeting"] == "Morning." and w.push.sent == [("wake", "Morning.")]


def test_wake_test_run_and_opening(world):
    w = world([done("Daily hello."), done("Test wake."), done("unused")])
    assert w.http.get("/v1/digest?kind=wake", headers=AUTH).status_code == 404
    # No wake today: a new chat with the wake digest behaves like daily.
    c = w.http.post("/v1/conversations", json={"digest": "wake"}, headers=AUTH).json()
    assert c["preview"].startswith("Daily hello.")
    r = w.http.post("/v1/digest/run", json={"kind": "wake"}, headers=AUTH).json()
    assert r["kind"] == "wake" and r["greeting"] == "Test wake."
    assert w.push.sent == [] and w.wake._done_day() is None  # a test run: no push, doesn't count
    c = w.http.post("/v1/conversations", json={"digest": "wake"}, headers=AUTH).json()
    assert c["preview"].startswith("Test wake.")
    assert w.http.get("/v1/digest?kind=wake", headers=AUTH).json()["greeting"] == "Test wake."


# -- the assistant's tool ----------------------------------------------------------


async def test_health_tool(world):
    w = world()
    w.health.save([night(TODAY - timedelta(days=1), 400, resting_hr=52, hrv_ms=60, steps=8000,
                         workouts=[workout("W1", day=TODAY - timedelta(days=1))],
                         naps=[{"start": f"{TODAY - timedelta(days=1)}T10:30:00+01:00",
                                "end": f"{TODAY - timedelta(days=1)}T12:40:00+01:00", "asleep_min": 130}]),
                   night(TODAY - timedelta(days=2), 440, resting_hr=54, steps=4000)])
    [tool] = health_tools(w.health, ROME)
    assert not tool.confirm
    out = await tool.handler()
    assert "· slept 6h40 (00:00–07:00) · nap 2h10 (10:30–12:40) · resting HR 52 bpm · HRV 60 ms · 8000 steps · workout: strength 52 min" in out
    assert "- sleep: 7h00 (over 2 days)" in out and "- resting HR: 53 bpm (over 2 days)" in out
    assert "- HRV: 60 ms (over 1 days)" in out and "- workouts: 1 in 2 days with data" in out
    old = await tool.handler(from_date="2020-01-01", to_date="2020-01-07")
    assert old == "No health data from Wed 01 Jan to Tue 07 Jan."
    with pytest.raises(ValueError):
        await tool.handler(from_date="2026-10-19", to_date="2026-10-01")
