from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.icloud import CalEvent
from aide.leave import LeaveWatcher
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.transit import AlertWatcher, Transit, Walks
from test_api import AUTH, ROME, TOKEN, FakeClient
from test_transit import FakeLive, at, env, timetable  # noqa: F401 (fixtures)

UNI = (45.1200, 7.7100)  # out at Falchera, the 4's last stop
HOME = (45.0650, 7.6756)  # about 270 m north of Porta Nuova (stop 252)


class FakeCal:
    def __init__(self, *events: CalEvent):
        self.list = list(events)
        self.reads = 0

    def events(self, start, end):
        self.reads += 1
        return [e for e in self.list if start <= e.start <= end]


class FakeMaps:
    def __init__(self, ride: dict | None):
        self.ride, self.routes = ride, []

    async def locate(self, query, near=None):
        return {"name": query, "lat": UNI[0], "lon": UNI[1]} if query == "Politecnico" else None

    async def route(self, body):
        self.routes.append(body)
        steps = [{"transitDetails": self.ride}] if self.ride else [{}]
        return {"duration": "1800s", "legs": [{"steps": steps}]}


def ride(line="4", departs=at(8, 15), stop=(45.06254, 7.67561), headsign="Falchera") -> dict:
    """Maps' transit step: the 4 from Porta Nuova at 08:15."""
    return {"stopDetails": {"departureStop": {"name": "Porta Nuova",
                                              "location": {"latLng": {"latitude": stop[0], "longitude": stop[1]}}},
                            "departureTime": departs.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")},
            "headsign": headsign, "transitLine": {"nameShort": line, "vehicle": {"type": "TRAM"}}}


def lecture(start=at(9, 0), place="Politecnico", uid="lec") -> CalEvent:
    return CalEvent(uid, "Timetable", "Macroeconomics", start, start + timedelta(hours=2), place)


def utc(dt: datetime) -> datetime:
    return dt.astimezone(timezone.utc)


@pytest.fixture
def leave(env):  # noqa: F811
    db, timetable, location, alerts, push = env

    def make(cal: FakeCal, maps: FakeMaps, mode: str | None = None) -> LeaveWatcher:
        async def travel_plan(event):
            return None, mode
        return LeaveWatcher(db.conn, ROME, cal, maps, alerts, location, Walks(), travel_plan)
    return make, env


async def test_an_event_with_a_tram_ride_becomes_a_tram_alert_that_says_leave_now(leave):
    make, (db, timetable, location, alerts, push) = leave
    maps = FakeMaps(ride())
    w = make(FakeCal(lecture()), maps)
    location.save(*HOME, 10, at(7, 15))
    await w.tick(utc(at(7, 20)))  # leaving at about 08:08: still 48 min away
    assert alerts.all() == [] and len(maps.routes) == 1
    assert maps.routes[0]["arrivalTime"] == "2026-10-22T06:50:00Z"  # there 10 min early
    await w.tick(utc(at(7, 22)))  # the way is looked up again only after 10 minutes
    assert alerts.all() == [] and len(maps.routes) == 1
    await w.tick(utc(at(7, 30)))  # leaving in 38 min
    (a,) = alerts.all()
    assert len(maps.routes) == 2
    assert (a["stop"], a["line"], a["time"], a["days"], a["event"]) == ("1", "4", "08:15", None, "Macroeconomics at 09:00")
    assert alerts.describe(a).endswith("when it's time to leave, for Macroeconomics at 09:00")
    await w.tick(utc(at(7, 40)))
    assert len(alerts.all()) == 1 and len(maps.routes) == 2  # one alert per event, and no more lookups

    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), push)
    location.save(*HOME, 10, at(8, 5))
    await watcher.tick(utc(at(8, 8, 40)))  # T2 at 08:15 (T5 at 08:07 is before it)
    (_, title, body), = push.alerts
    assert title == "Tram 4 in 6 min: leave now"
    assert body.endswith("For Macroeconomics at 09:00.")


async def test_no_alert_when_there_is_no_tram_to_take(leave):
    make, (db, timetable, location, alerts, push) = leave
    location.save(*HOME, 10, at(7, 25))
    alerts.create("2", "4", "08:10", [1, 2, 3, 4, 5])  # the user's own commute, the other side of the road
    for uid, place, maps, mode, state in [
        ("walks", "Politecnico", FakeMaps(ride()), "walk", "walks"),  # "I walk to uni"
        ("train", "Politecnico", FakeMaps(ride(line="SFM1")), None, "not_gtt"),  # not a GTT line
        ("near", "Politecnico", FakeMaps(None), None, "no_ride"),  # Maps says walk
        ("online", "Zoom", FakeMaps(ride()), None, "no_place"),
        ("commute", "Politecnico", FakeMaps(ride()), None, "covered"),
    ]:
        await make(FakeCal(lecture(uid=uid, place=place)), maps, mode).tick(utc(at(7, 30)))
        assert db.conn.execute("SELECT state FROM leave_plans WHERE event = ?", (uid,)).fetchone()[0] == state
    assert [a["event"] for a in alerts.all()] == [None]


async def test_not_while_there_or_far_away_and_not_without_a_fix(leave):
    make, (db, timetable, location, alerts, push) = leave
    maps = FakeMaps(ride())
    w = make(FakeCal(lecture()), maps)
    await w.tick(utc(at(7, 30)))  # no fix: asks the phone for one
    assert push.location_requests == 1 and maps.routes == []
    location.save(UNI[0] + 0.001, UNI[1], 10, at(7, 31))  # already at uni
    await w.tick(utc(at(7, 32)))
    location.save(45.4642, 9.19, 10, at(7, 33))  # in Milan: not going
    await w.tick(utc(at(7, 34)))
    assert maps.routes == [] and alerts.all() == []
    location.save(*HOME, 10, at(7, 35))  # home after all: it's still looked at
    await w.tick(utc(at(7, 36)))
    assert len(alerts.all()) == 1


async def test_an_event_that_moves_takes_its_alert_along_and_the_setting_turns_it_off(leave):
    make, (db, timetable, location, alerts, push) = leave
    cal = FakeCal(lecture())
    w = make(cal, FakeMaps(ride()))
    location.save(*HOME, 10, at(7, 25))
    await w.tick(utc(at(7, 30)))
    assert len(alerts.all()) == 1
    cal.list = [lecture(start=at(11, 0))]
    await w.tick(utc(at(7, 40)))  # the calendar is read again: the 09:00 alert goes
    assert alerts.all() == []
    w.update_settings(False)
    await w.tick(utc(at(7, 50)))
    assert cal.reads == 2 and w.settings() == {"calendar": False}


def test_settings_endpoint(leave):
    make, (db, *_) = leave
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, leave=make(FakeCal(), FakeMaps(None))))
    assert c.get("/v1/transit/settings", headers=AUTH).json() == {"calendar": True}
    assert c.patch("/v1/transit/settings", json={"calendar": False}, headers=AUTH).json() == {"calendar": False}
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN))
    assert c.get("/v1/transit/settings", headers=AUTH).status_code == 404
