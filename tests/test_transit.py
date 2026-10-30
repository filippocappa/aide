import asyncio
import zipfile
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient
from google.transit import gtfs_realtime_pb2 as rt

from aide.agent import Agent
from aide.agents import AGENTS, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.transit import transit_tools
from aide.transit import (AlertStore, AlertWatcher, Boards, Live, Location, Timetable, Transit, Walks, Whereabouts,
                          build, line_key, parse_live, pretty, stop_name)
from test_api import AUTH, ROME, TOKEN, FakeClient

DAY = date(2026, 10, 22)  # a Thursday


def at(hh: int, mm: int, ss: int = 0, day: date = DAY) -> datetime:
    return datetime(day.year, day.month, day.day, hh, mm, ss, tzinfo=ROME)


def csv_text(header: str, *rows: str) -> str:
    return header + "\n" + "\n".join(rows) + "\n"


def gtfs_zip(path) -> None:
    """A tiny GTT: the 4 to Falchera (stops 100 → 252 → 400) and back the other way at 253, the 33 at 252."""
    files = {
        "stops.txt": csv_text(
            '"stop_id","stop_code","stop_name","stop_desc","stop_lat","stop_lon","location_type","parent_station"',
            '"1","252","Fermata 252 - PORTA NUOVA","","45.06254","7.67561","",""',
            '"2","253","Fermata 253 - PORTA NUOVA","","45.06269","7.67753","",""',
            '"3","100","Fermata 100 - VITTORIO EMANUELE II CAP","","45.0700","7.6800","",""',
            '"4","400","Fermata 400 - FALCHERA","","45.1200","7.7100","",""',
            '"9","","STAZIONE","","45.0","7.6","1",""'),
        "routes.txt": csv_text(
            '"route_id","agency_id","route_short_name","route_long_name","route_desc","route_type"',
            '"4U","U","4","Falchera - Mirafiori","x, y","0"',
            '"33U","U","33","a","b","3"'),
        "trips.txt": csv_text(
            '"route_id","service_id","trip_id","trip_headsign","direction_id"',
            '"4U","S1","T1","FALCHERA","0"', '"4U","S1","T2","FALCHERA","0"', '"4U","S1","T0","FALCHERA","0"',
            '"4U","S1","T3","MIRAFIORI","1"', '"4U","S1","T5","FALCHERA","0"', '"33U","S2","B1","SASSI","0"',
            '"4U","S1","N1","FALCHERA","0"', '"4U","OFF","X1","FALCHERA","0"'),
        "stop_times.txt": csv_text(
            '"trip_id","arrival_time","departure_time","stop_id","stop_sequence"',
            '"T0","07:55:00","07:55:00","3","1"', '"T0","07:58:00","07:58:00","1","2"',
            '"T0","08:20:00","08:20:00","4","3"',
            '"T1","08:02:00","08:02:00","3","1"', '"T1","08:05:00","08:05:00","1","2"',
            '"T1","08:30:00","08:30:00","4","3"',
            '"T2","08:12:00","08:12:00","3","1"', '"T2","08:15:00","08:15:00","1","2"',
            '"T3","08:06:00","08:06:00","2","1"',
            '"T5","08:07:00","08:07:00","1","2"',
            '"B1","08:09:00","08:09:00","1","1"',
            '"N1","24:20:00","24:20:00","1","2"',
            '"X1","08:08:00","08:08:00","1","2"'),
        "calendar.txt": csv_text(
            '"service_id","monday","tuesday","wednesday","thursday","friday","saturday","sunday","start_date","end_date"',
            '"S1","1","1","1","1","1","1","1","20261001","20270131"',
            '"OFF","1","1","1","1","1","1","1","20261001","20270131"'),
        "calendar_dates.txt": csv_text('"service_id","date","exception_type"',
                                       '"S2","20261022","1"', '"OFF","20261022","2"'),
    }
    with zipfile.ZipFile(path, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)


def live_feed(*trips) -> bytes:
    """trips: (trip_id, [(seq, delay)]) or (trip_id, None) for a cancelled one, all on DAY."""
    feed = rt.FeedMessage()
    feed.header.gtfs_realtime_version = "2.0"
    for trip_id, updates in trips:
        e = feed.entity.add()
        e.id = trip_id
        e.trip_update.trip.trip_id = trip_id
        e.trip_update.trip.start_date = DAY.strftime("%Y%m%d")
        if updates is None:
            e.trip_update.trip.schedule_relationship = rt.TripDescriptor.CANCELED
        for seq, delay in updates or ():
            u = e.trip_update.stop_time_update.add()
            u.stop_sequence = seq
            u.arrival.delay = delay
    return feed.SerializeToString()


class FakeLive(Live):
    def __init__(self, data: bytes = b""):
        self.data = data

    async def trips(self):
        return parse_live(self.data)


class FakePush:
    enabled = True

    def __init__(self):
        self.alerts: list[tuple] = []
        self.location_requests = 0

    async def send_transit(self, alert_id, title, body):
        self.alerts.append((alert_id, title, body))
        return True

    async def request_location(self):
        self.location_requests += 1
        return True


@pytest.fixture
def timetable(tmp_path):
    gtfs_zip(tmp_path / "gtt.zip")
    build(tmp_path / "gtt.zip", tmp_path / "gtt.db", DAY)
    return Timetable(tmp_path / "gtt.db", ROME)


@pytest.fixture
def env(timetable):
    db = Database(":memory:")
    push = FakePush()
    location = Location(db.conn, push)
    alerts = AlertStore(db.conn, ROME, timetable)
    yield db, timetable, location, alerts, push
    db.close()


# -- names ----------------------------------------------------------------------------------


def test_names_read_like_names():
    assert stop_name("Fermata 1415 - VITTORIO EMANUELE II CAP") == "Vittorio Emanuele II Cap"
    assert pretty("CADUTI PER LA LIBERTÀ") == "Caduti per la Libertà"
    assert pretty("PORTA NUOVA - M1 - STAZIONE") == "Porta Nuova - M1 - Stazione"
    assert [line_key(x) for x in ("tram 4", "the 15", "Metro", "4", "linea 33")] == ["4", "15", "M1", "4", "33"]


# -- the timetable --------------------------------------------------------------------------


def test_build_keeps_stops_lines_and_the_days_services_run(timetable):
    assert timetable.built() == DAY
    assert [s["code"] for s in timetable.find("porta nuova")] == ["252", "253"]
    assert timetable.find("Fermata 252")[0]["name"] == "Porta Nuova"
    assert timetable.find("STAZIONE") == []  # a station, not a stop
    assert timetable.lines("1") == [{"name": "4", "vehicle": "Tram", "headsigns": ["Falchera"]},
                                    {"name": "33", "vehicle": "Bus", "headsigns": ["Sassi"]}]
    near = timetable.near(45.0626, 7.6760)
    assert [s["code"] for s, _ in near] == ["252", "253"] and near[0][1] < 50


def test_scheduled_follows_the_calendar_and_runs_past_midnight(timetable):
    rows = timetable.scheduled(["1"], at(8, 0), at(8, 10))
    assert [r["trip"] for r in rows] == ["T1", "T5", "B1"]  # X1's service is off today
    late = timetable.scheduled(["1"], at(0, 0, day=DAY + timedelta(days=1)), at(0, 30, day=DAY + timedelta(days=1)))
    assert [(r["trip"], r["at"]) for r in late] == [("N1", at(0, 20, day=DAY + timedelta(days=1)))]


# -- live arrivals --------------------------------------------------------------------------


async def test_arrivals_carry_the_live_delay_and_drop_trams_gone_or_cancelled(timetable):
    # T0 is past stop 252 (its next stop is 400); T1 runs 2 min late from stop 100; T5 is cancelled.
    feed = live_feed(("T0", [(3, 60)]), ("T1", [(1, 90), (2, 120)]), ("T5", None))
    now = at(8, 0)
    found = await Transit(timetable, FakeLive(feed)).arrivals(["1"], "tram 4", now)
    assert [(a.trip, a.at, a.live) for a in found] == [("T1", at(8, 7), True), ("T2", at(8, 15), False)]
    assert found[0].minutes(now) == 7 and found[0].name() == "Tram 4" and found[0].headsign == "Falchera"
    # A delay carries on to later stops: T1's last update is for stop 100 only.
    found = await Transit(timetable, FakeLive(live_feed(("T1", [(1, 300)])))).arrivals(["1"], "4", now)
    assert next(a.at for a in found if a.trip == "T1") == at(8, 10)


async def test_a_late_tram_scheduled_before_now_still_comes(timetable):
    found = await Transit(timetable, FakeLive(live_feed(("T0", [(2, 600)])))).arrivals(["1"], "4", at(8, 0))
    assert [(a.trip, a.at) for a in found][:3] == [("T1", at(8, 5)), ("T5", at(8, 7)), ("T0", at(8, 8))]


async def test_live_waits_for_the_first_fetch_then_refreshes_behind_the_scenes(monkeypatch):
    import httpx

    from aide import transit as transit_mod
    replies = [httpx.Response(200, content=live_feed(("T1", [(2, 60)]))), httpx.Response(503)]
    live = Live(httpx.AsyncClient(transport=httpx.MockTransport(lambda r: replies.pop(0))))
    assert ("T1", "20261022") in await live.trips()  # nothing kept yet: waits
    monkeypatch.setattr(transit_mod, "LIVE_TTL", -1)  # as if it were old
    assert ("T1", "20261022") in await live.trips()  # the refresh fails behind the scenes; the last feed stays
    await live._task
    assert not live.down
    monkeypatch.setattr(transit_mod, "STALE", -1)
    assert await live.trips() == {} and live.down  # too old to trust: GTT's live times aren't coming through


async def test_unknown_line_is_an_error(timetable):
    with pytest.raises(ValueError, match="no line"):
        await Transit(timetable, FakeLive()).arrivals(["1"], "99", at(8, 0))


# -- alerts ---------------------------------------------------------------------------------


def test_alerts_check_the_stop_and_line(env):
    _, _, _, alerts, _ = env
    with pytest.raises(ValueError, match="doesn't stop"):
        alerts.create("2", "33")
    with pytest.raises(ValueError, match="needs a time"):
        alerts.create("1", "4", days=[1])
    with pytest.raises(ValueError, match="no GTT stop"):
        alerts.create("nope", "4")


def test_a_commute_watches_around_its_time_on_its_days_once(env):
    _, _, _, alerts, _ = env
    a = alerts.create("1", "tram 4", "08:10", [1, 2, 3, 4, 5])
    assert a["line"] == "4" and a["days"] == [1, 2, 3, 4, 5]
    assert alerts.describe(a) == ("Tram 4 at Porta Nuova (stop 252), towards Falchera: Mon–Fri around 08:10, "
                                  "when it's time to leave")
    utc = lambda dt: dt.astimezone(timezone.utc)  # noqa: E731
    assert alerts.active(utc(at(7, 30))) == []
    assert alerts.active(utc(at(7, 45))) == [(a, at(8, 5))]
    assert alerts.active(utc(at(8, 0, day=date(2026, 10, 24)))) == []  # Saturday
    alerts.alerted(a, utc(at(8, 0)))
    assert alerts.active(utc(at(8, 1))) == []
    assert len(alerts.active(utc(at(7, 45, day=DAY + timedelta(days=1))))) == 1


def test_a_one_off_watches_from_now_or_around_its_time_and_ends(env):
    _, _, _, alerts, _ = env
    now = at(8, 0).astimezone(timezone.utc)
    nxt = alerts.create("1", "4", minutes=10, now=now)
    timed = alerts.create("1", "4", "18:30", now=now)
    assert "once, around 18:30" in alerts.describe(timed)
    assert alerts.describe(timed).endswith("when it's time to leave")
    assert [a["id"] for a, _ in alerts.active(now)] == [nxt["id"]]
    assert [(a["id"], e) for a, e in alerts.active(at(18, 10).astimezone(timezone.utc))] == [(timed["id"], at(18, 25))]
    assert [a["id"] for a in alerts.all()] == [timed["id"]]  # the untimed one gave up after two hours
    early = alerts.create("1", "4", "07:00", now=now)  # already gone today: tomorrow
    assert datetime.fromisoformat(early["starts_at"]) == at(6, 30, day=DAY + timedelta(days=1))


async def test_leave_now_fires_a_few_minutes_before_it_is_time_to_leave(env, monkeypatch):
    db, timetable, location, alerts, push = env
    a = alerts.create("1", "4", now=at(7, 50).astimezone(timezone.utc))
    feed = live_feed(("T1", [(2, 120)]), ("T5", None))
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive(feed)), location, Walks(), push)
    location.save(45.0650, 7.6756, 10, at(7, 55))  # about 270 m north of the stop: a 5 min walk
    await watcher.tick(at(7, 57))  # T1 comes at 08:07: 10 min away, more than 4.7 + 2 at the stop + 3 to get ready
    assert push.alerts == []
    await watcher.tick(at(7, 57, 30))
    (alert_id, title, body), = push.alerts
    assert (alert_id, title) == (a["id"], "Tram 4 in 10 min: leave in 3 min")
    assert body == ("Porta Nuova (stop 252), towards Falchera. 5 min walk from where you are. Your stop is its "
                    "next. Next one in 18 min.")
    assert alerts.all() == []  # a one-off is done


async def test_where_the_tram_is(env):
    db, timetable, *_ = env
    t1 = lambda feed: Transit(timetable, FakeLive(feed))  # noqa: E731
    [mine] = [x for x in await t1(b"").arrivals(["1"], "4", at(7, 59)) if x.trip == "T1"]
    # On the timetable: T1 leaves stop 100 at 08:02, so before then it hasn't started.
    assert await t1(b"").position(mine, at(7, 59)) == {
        "stops": 1, "near": "Vittorio Emanuele II Cap", "starts": int(at(8, 2).timestamp())}
    assert await t1(b"").position(mine, at(8, 3)) == {"stops": 0, "near": "Vittorio Emanuele II Cap", "starts": None}
    # Live: the feed's next stop for it, whatever the clock says.
    live = t1(live_feed(("T1", [(1, 240), (2, 120)])))
    [late] = [x for x in await live.arrivals(["1"], "4", at(8, 3)) if x.trip == "T1"]
    assert late.live and await live.position(late, at(8, 3)) == {
        "stops": 1, "near": "Vittorio Emanuele II Cap", "starts": int(at(8, 6).timestamp())}  # its own stop's delay


async def test_leave_now_skips_a_tram_too_close_to_catch_and_asks_for_a_location(env):
    db, timetable, location, alerts, push = env
    alerts.create("1", "4", now=at(8, 0).astimezone(timezone.utc))
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), push)
    await watcher.tick(at(8, 1))  # no fix: assumes 5 min, and asks the phone
    assert push.location_requests == 1
    (_, title, body), = push.alerts  # T1 at 08:05 is too close to catch: T5 at 08:07 is the one
    assert title == "Tram 4 in 6 min: leave now"
    assert "assumes a 5 min walk" in body and "From the timetable (no live data for it)" in body


async def test_fixed_minutes_and_a_commute_alert_once_a_day(env):
    db, timetable, location, alerts, push = env
    a = alerts.create("1", "4", "08:10", [4], minutes=10)
    watcher = AlertWatcher(alerts, Transit(timetable, FakeLive()), location, Walks(), push)
    await watcher.tick(at(7, 50))
    assert push.alerts == [] and push.location_requests == 0  # minutes alerts don't need the location
    await watcher.tick(at(7, 56))  # the first from 08:05 is T1: 9 min
    assert [t for _, t, _ in push.alerts] == ["Tram 4 in 9 min"]
    await watcher.tick(at(7, 57))
    assert len(push.alerts) == 1 and alerts.get(a["id"])["last_alert"]


# -- location ---------------------------------------------------------------------------------


async def test_location_keeps_the_latest_fix_and_asks_at_most_every_five_minutes(env):
    db, _, location, _, push = env
    location.save(45.0, 7.6, 20, at(8, 0))
    location.save(45.1, 7.7, 20, at(7, 0))  # older, arriving late: ignored
    assert location.latest()["lat"] == 45.0
    now = at(9, 0).astimezone(timezone.utc)
    assert await location.request(now) and not await location.request(now + timedelta(minutes=4))
    assert await location.request(now + timedelta(minutes=5)) and push.location_requests == 2
    with pytest.raises(ValueError):
        location.save(95, 7, None)


async def test_here_is_the_fix_while_it_says_where_the_user_is(env, monkeypatch):
    db, _, location, _, push = env
    assert await location.here() is None
    location.save(45.07, 7.68, 20, at(8, 0))
    monkeypatch.setattr("aide.transit.utcnow", lambda: at(8, 5).astimezone(timezone.utc))
    assert await location.here() == (45.07, 7.68)
    monkeypatch.setattr("aide.transit.utcnow", lambda: at(10, 30).astimezone(timezone.utc))
    monkeypatch.setattr(location, "request", lambda now=None: asyncio.sleep(0, result=False))
    assert await location.here() is None  # over two hours old, and the phone didn't answer


async def test_whereabouts_names_the_street_and_looks_up_again_only_after_a_move(env, monkeypatch):
    db, _, location, _, push = env

    class Maps:
        asked = []

        async def address_near(self, lat, lon):
            self.asked.append((lat, lon))
            return "Piazza Castello 34, Torino" if lat < 45.2 else "Piazza di Città 8, Ivrea"

    where = Whereabouts(location, Maps())
    now = at(8, 30).astimezone(timezone.utc)
    assert await where.describe(now) is None  # no fix yet
    location.save(45.0539, 7.6589, 20, at(8, 0))
    assert await where.describe(now) == "phone near Piazza Castello 34, Torino, 30 min ago"
    location.save(45.0545, 7.6589, 20, at(8, 29))  # 70 m: the same address, not asked again
    assert await where.describe(now) == "phone near Piazza Castello 34, Torino, just now"
    assert len(Maps.asked) == 1
    location.save(45.4669, 7.8763, 20, at(10, 0))
    assert await where.describe(at(11, 30).astimezone(timezone.utc)) == "phone near Piazza di Città 8, Ivrea, 1 h ago"
    assert await where.describe(at(12, 30).astimezone(timezone.utc)) is None  # over two hours old


# -- tools ------------------------------------------------------------------------------------


@pytest.fixture
def tools(env, monkeypatch):
    db, timetable, location, alerts, push = env
    monkeypatch.setattr("aide.tools.transit.utcnow", lambda: at(8, 0).astimezone(timezone.utc))
    feed = live_feed(("T1", [(2, 120)]), ("T5", None))
    transit = Transit(timetable, FakeLive(feed))
    boards = Boards(transit, location, Walks())
    return {t.name: t for t in transit_tools(transit, alerts, location, boards)}, location


async def test_arrivals_tool_by_stop_and_near_the_phone(tools):
    t, location = tools
    out = await t["transit_arrivals"].handler(stop="252")
    assert out.startswith("Porta Nuova (stop 252):\n- Tram 4 → Falchera: 7 min (2 late), 15 min (timetable)\n"
                          "- Bus 33 → Sassi: 9 min (timetable)")
    card, = out.attachment["departures"]
    assert [(l["line"], l["vehicle"], l["towards"]) for l in card["lines"]] == [("4", "Tram", "Falchera"),
                                                                               ("33", "Bus", "Sassi")]
    assert card["lines"][0]["arrivals"][0] == {"at": "2026-10-22T06:07:00Z", "scheduled": "2026-10-22T06:05:00Z",
                                               "live": True, "delay": 120}
    assert card["lines"][0]["arrivals"][1]["delay"] is None and card["walk"] is None and card["to"] is None
    location.save(45.0626, 7.6760, 10)
    out = await t["transit_arrivals"].handler(line="4")
    assert "Porta Nuova (stop 252, " in out and "Porta Nuova (stop 253, " in out and "Mirafiori: 6 min" in out
    stops = await t["transit_stops"].handler()
    assert stops.startswith("GTT stops near the phone:\n- Porta Nuova (stop 252, ")


async def test_arrivals_to_a_destination_keep_the_lines_that_go_there(tools):
    t, location = tools
    location.save(45.0650, 7.6756, 10, at(7, 59))  # about 270 m from stop 252
    out = await t["transit_arrivals"].handler(stop="252", to="Falchera")
    assert out.startswith("Porta Nuova (stop 252):\n- Tram 4 → Falchera: 7 min (2 late); the first gets to Falchera "
                          "at 08:32")  # T2 ends before Falchera, the 33 doesn't go there
    card, = out.attachment["departures"]
    assert card["to"] == {"name": "Falchera", "stops": ["4"]}
    assert card["lines"][0]["arrivals"] == [{"at": "2026-10-22T06:07:00Z", "scheduled": "2026-10-22T06:05:00Z",
                                             "live": True, "delay": 120, "to_at": "2026-10-22T06:32:00Z",
                                             "to_stop": "400"}]
    assert 250 < card["distance"] < 290 and abs(card["walk"] - card["distance"] * 1.3 / 1.25) < 1  # seconds
    out = await t["transit_arrivals"].handler(stop="253", to="Falchera")
    assert "No direct line to Falchera" in out and out.attachment is None
    with pytest.raises(ValueError, match="no GTT stop matches 'Mars'"):
        await t["transit_arrivals"].handler(stop="252", to="Mars")


async def test_a_destination_can_be_a_place_found_on_maps(env):
    db, timetable, location, alerts, push = env

    class Maps:
        asked = []

        async def locate(self, query, near=None):
            self.asked.append(query)
            return {"name": "Barriera di Milano", "lat": 45.1201, "lon": 7.7101} if "Barriera" in query else None

    boards = Boards(Transit(timetable, FakeLive()), location, Walks(Maps()))
    assert await boards.destination("Barriera di Milano") == {"name": "Barriera di Milano", "stops": ["4"]}
    assert Maps.asked == ["Barriera di Milano, Torino"]
    assert (await boards.destination("porta nuova"))["stops"] == ["1", "2"]  # a stop's name: no Maps
    with pytest.raises(ValueError, match="no GTT stop matches 'Mars'$"):
        await boards.destination("Mars")


async def test_near_me_without_a_location_says_so(tools):
    t, location = tools
    location.push = None  # nobody to ask
    with pytest.raises(ValueError, match="hasn't shared its location"):
        await t["transit_arrivals"].handler()


async def test_alert_tools_ask_which_stop_when_a_name_matches_both_sides(tools):
    t, _ = tools
    with pytest.raises(ValueError, match="(?s)2 stops match.*stop 252.*Falchera.*stop 253.*Mirafiori"):
        await t["add_transit_alert"].handler(stop="Porta Nuova", line="4")
    out = await t["add_transit_alert"].handler(stop="252", line="4", time="08:10", days=[1, 2, 3, 4, 5])
    assert out.startswith("Set [1]: Tram 4 at Porta Nuova (stop 252)")
    out = await t["update_transit_alert"].handler(alert_id=1, minutes=10, enabled=False)
    assert out.endswith("when it's 10 min away (off).")
    assert t["delete_transit_alert"].confirm
    assert (await t["list_transit_alerts"].handler()).startswith("[1] Tram 4")


def test_aide_and_secretary_have_the_gtt_tools():
    assert "add_transit_alert" in AGENTS["aide"].tools and "transit_arrivals" in AGENTS["secretary"].tools
    assert "transit_arrivals" not in AGENTS["coach"].tools
    gtt, = [c for c in connectors(["transit_arrivals", "add_transit_alert"]) if c["id"] == "transit"]
    assert gtt["name"] == "GTT" and not gtt["read_only"]


# -- API --------------------------------------------------------------------------------------


@pytest.fixture
def client(env):
    db, timetable, location, alerts, push = env
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    boards = Boards(Transit(timetable, FakeLive(live_feed(("T1", [(2, 120)])))), location, Walks())
    app = create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN, location=location, transit_alerts=alerts,
                     boards=boards)
    return TestClient(app), location, alerts


def test_location_endpoint(client):
    c, location, _ = client
    r = c.post("/v1/location", json={"lat": 45.06, "lon": 7.67, "accuracy": 12, "at": "2026-10-22T08:00:00+02:00"},
               headers=AUTH)
    assert r.json() == {"ok": True}
    assert location.latest()["at"] == at(8, 0)
    assert c.post("/v1/location", json={"lat": 45, "lon": 7, "at": "2026-10-22T08:00:00"}, headers=AUTH).status_code == 400
    assert c.post("/v1/location", json={"lat": 200, "lon": 7}, headers=AUTH).status_code == 400


def test_alert_endpoints(client):
    c, _, alerts = client
    a = alerts.create("1", "4", "08:10", [1, 2, 3, 4, 5])
    got = c.get("/v1/transit/alerts", headers=AUTH).json()["alerts"]
    assert got == [{"id": a["id"], "line": "4", "vehicle": "Tram", "towards": ["Falchera"],
                    "stop": {"id": "1", "code": "252", "name": "Porta Nuova"}, "time": "08:10",
                    "days": [1, 2, 3, 4, 5], "once": False, "minutes": None, "enabled": True, "event": None,
                    "right_away": False, "summary": alerts.describe(a)}]
    r = c.patch(f"/v1/transit/alerts/{a['id']}", json={"minutes": 8, "time": "08:20"}, headers=AUTH).json()
    assert (r["minutes"], r["time"]) == (8, "08:20")
    r = c.patch(f"/v1/transit/alerts/{a['id']}", json={"minutes": None, "enabled": False}, headers=AUTH).json()
    assert (r["minutes"], r["enabled"]) == (None, False)
    assert c.patch(f"/v1/transit/alerts/{a['id']}", json={"time": "8"}, headers=AUTH).status_code == 400
    assert c.delete(f"/v1/transit/alerts/{a['id']}", headers=AUTH).json() == {"ok": True}
    assert c.delete(f"/v1/transit/alerts/{a['id']}", headers=AUTH).status_code == 404


def test_departures_endpoint_refreshes_a_card(client, monkeypatch):
    c, _, _ = client
    monkeypatch.setattr("aide.transit.utcnow", lambda: at(8, 0).astimezone(timezone.utc))
    card = c.get("/v1/transit/departures", params={"stop": "1", "to": "4", "to_name": "Falchera"}, headers=AUTH).json()
    assert card["stop"] == {"id": "1", "code": "252", "name": "Porta Nuova"} and card["at"] == "2026-10-22T06:00:00Z"
    assert [l["line"] for l in card["lines"]] == ["4"] and card["lines"][0]["arrivals"][0]["to_at"] == "2026-10-22T06:32:00Z"
    card = c.get("/v1/transit/departures", params={"stop": "1", "line": "33"}, headers=AUTH).json()
    assert [l["line"] for l in card["lines"]] == ["33"]
    assert c.get("/v1/transit/departures", params={"stop": "nope"}, headers=AUTH).status_code == 404
    assert c.get("/v1/transit/departures", params={"stop": "1", "line": "99"}, headers=AUTH).status_code == 400


def test_alerts_are_404_with_gtt_off(env):
    db = env[0]
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    c = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN))
    assert c.get("/v1/transit/alerts", headers=AUTH).status_code == 404


async def test_push_payloads():
    from aide.push import Push
    sent = []

    class P(Push):
        @property
        def enabled(self):
            return True

        async def send(self, payload, background=False, collapse=None):
            sent.append((payload, background))
            return 1, 0

    p = P(Database(":memory:").conn)
    await p.send_transit(3, "Tram 4 in 7 min: leave now", "Porta Nuova")
    await p.request_location()
    assert sent[0] == ({"aps": {"alert": {"title": "Tram 4 in 7 min: leave now", "body": "Porta Nuova"},
                                "sound": "default", "thread-id": "transit", "interruption-level": "time-sensitive"},
                        "aide": {"kind": "transit", "alert_id": 3}}, False)
    assert sent[1] == ({"aps": {"content-available": 1}, "aide": {"kind": "location"}}, True)
