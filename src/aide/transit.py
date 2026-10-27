"""GTT, Turin's buses, trams and metro: stops, live arrivals and tram alerts. The contract is docs/API.md, "Transit".

The timetable is GTT's GTFS, rebuilt every night into its own SQLite file (data/gtt.db). Live times come from its
GTFS-Realtime trip updates: each running trip's delay at its next few stops. A delay carries on to the stops after
it, so a stop further along gets the latest delay before it; a trip whose next stop is already past ours has gone by.
A trip with no live data runs on the timetable. Where a followed tram is (the stops it has left before yours) comes
from the same: the feed's next stop for it, else its timetable shifted by its delay.

The phone sends its location (only the latest fix is kept): it gives the walk to the stop, so an alert can say
"leave now" a few minutes before you need to go, timed to have you at the stop a little before the tram. When an alert needs a fresher fix, the server asks the
phone for one with a silent push.
"""

import asyncio
import csv
import io
import json
import logging
import math
import os
import re
import sqlite3
import zipfile
from dataclasses import dataclass, replace
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path
from typing import TYPE_CHECKING
from zoneinfo import ZoneInfo

import httpx

from .db import utcnow
from .push import Push
from .routines import check_days, check_time, days_text

if TYPE_CHECKING:
    from .live import LiveActivities

log = logging.getLogger(__name__)

GTFS_URL = "https://www.gtt.to.it/open_data/gtt_gtfs.zip"
LIVE_URL = "https://percorsieorari.gtt.to.it/das_gtfsrt/trip_update.aspx"
REBUILD_AT = 4  # local hour from which the nightly rebuild runs (GTT publishes the day's feed around 03:10)
SERVICE_DAYS = 8  # service days kept, from yesterday
LIVE_TTL = 20  # seconds: a live feed older than this is refreshed in the background when read
WAIT_AFTER = 90  # seconds: older than this, a read waits for the refresh
STALE = 600  # seconds: older than this, the live feed isn't used (a delay changes slowly, so a late one still helps)
FETCH_TIMEOUT = 90  # seconds: GTT takes about 20 to answer, and over 45 at rush hour some days
READ_WAIT = 45  # seconds a read waits for a fetch at most
LATE = timedelta(minutes=40)  # a scheduled arrival this far back may still be coming, running late
VEHICLES = {"0": "Tram", "1": "Metro", "2": "Train", "3": "Bus"}

TICK = 30  # seconds between alert checks
WINDOW = timedelta(minutes=30)  # a timed alert watches from this long before its time to this long after
EARLY = timedelta(minutes=5)  # a timed alert's tram can come this much before the time
ONCE_FOR = timedelta(hours=2)  # how long an untimed one-off alert waits for its tram
AT_STOP = 120  # seconds: "leave" has you at the stop this long before the tram
HEADS_UP = 180  # seconds: a leave-now alert comes this long before it's time to leave
BUFFER = AT_STOP + HEADS_UP  # on top of the walk: leave-now alerts fire when the tram is the walk plus this away
DEFAULT_WALK = 5 * 60  # seconds, when there's no location to work it out from
FIX_AGE = timedelta(minutes=10)  # a leave-now alert wants a fix younger than this
FIX_EVERY = timedelta(minutes=5)  # at most one location request per this long
FIX_USABLE = timedelta(hours=2)  # older than this, the fix says nothing about where the user is
NEAR = 400  # metres: "stops near me"
TURIN = (45.0703, 7.6869)  # where a place named for a destination is looked for first
WALK_SHOWN = 2000  # metres: a stop closer than this to the phone gets its walk on the departures card
BOARD_TIMES = 4  # arrivals per line and direction on a departures card
WALK_SPEED = 1.25  # m/s, for the straight-line estimate without Maps
DETOUR = 1.3  # streets are longer than the straight line
LIVE_MOVE = 30  # seconds: a tram's Live Activity is updated when its expected time moves this much
LIVE_GONE = timedelta(minutes=1)  # this long past its time, the tram has left: its Live Activity ends
LIVE_STALE = timedelta(minutes=2)  # after its time, the countdown is stale; and the ended one goes after this
LIVE_FOR = timedelta(hours=2)  # a tram followed longer than this is let go
NEARBY = 2  # stops on the departures widget

GTFS_SCHEMA = """
CREATE TABLE stops (id TEXT PRIMARY KEY, code TEXT NOT NULL, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL);
CREATE TABLE routes (id TEXT PRIMARY KEY, name TEXT NOT NULL, type TEXT NOT NULL);
CREATE TABLE trips (id TEXT PRIMARY KEY, route TEXT NOT NULL, service TEXT NOT NULL, headsign TEXT NOT NULL);
-- at: seconds from the service day's midnight (over 24 h for trips past midnight)
CREATE TABLE stop_times (trip TEXT NOT NULL, seq INTEGER NOT NULL, stop TEXT NOT NULL, at INTEGER NOT NULL);
CREATE TABLE service_days (service TEXT NOT NULL, day TEXT NOT NULL);
CREATE TABLE stop_lines (stop TEXT NOT NULL, route TEXT NOT NULL, headsign TEXT NOT NULL);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

GTFS_INDEXES = """
CREATE INDEX stop_times_stop ON stop_times(stop, at);
CREATE INDEX stop_times_trip ON stop_times(trip, seq);
CREATE INDEX service_days_day ON service_days(service, day);
CREATE INDEX stops_code ON stops(code);
CREATE INDEX stop_lines_stop ON stop_lines(stop);
"""

ALERTS_SCHEMA = """
CREATE TABLE IF NOT EXISTS transit_alerts (
    id         INTEGER PRIMARY KEY,
    stop       TEXT NOT NULL,     -- GTFS stop_id
    line       TEXT NOT NULL,     -- the line's short name, e.g. 4
    time       TEXT,              -- HH:MM local: catch the first tram from about then; null: the next one
    days       TEXT,              -- JSON ISO weekdays, [] every day: a commute; null: a one-off
    minutes    INTEGER,           -- alert when the tram is this many minutes away; null: when it's time to leave
    enabled    INTEGER NOT NULL DEFAULT 1,
    starts_at  TEXT,              -- UTC, one-offs: when it starts watching
    ends_at    TEXT,              -- UTC, one-offs: when it gives up
    last_alert TEXT,              -- UTC
    created_at TEXT NOT NULL,
    event      TEXT               -- set for a calendar event ("Macroeconomics at 09:30"), by leave.py
);
CREATE TABLE IF NOT EXISTS location (
    id       INTEGER PRIMARY KEY CHECK (id = 1),  -- only the latest fix is kept
    lat      REAL NOT NULL,
    lon      REAL NOT NULL,
    accuracy REAL,                                -- metres
    at       TEXT NOT NULL                        -- UTC
);
"""

_SMALL = {"di", "del", "della", "dei", "degli", "delle", "da", "dal", "per", "la", "le", "il", "lo", "e", "a", "al",
          "alla", "in", "sul", "sulla"}
_KEEP = re.compile(r"[IVXLC]+|[A-Z]+\d+\w*|\d\S*|S\.P\.A\.?|[A-Z]\.")


def pretty(name: str) -> str:
    """GTT's capitals as a name: 'VITTORIO EMANUELE II CAP' -> 'Vittorio Emanuele II Cap'."""
    words = []
    for i, word in enumerate(name.split()):
        if _KEEP.fullmatch(word):
            words.append(word)
        elif i and word.lower() in _SMALL:
            words.append(word.lower())
        else:
            words.append("-".join(w[:1].upper() + w[1:].lower() for w in word.split("-")))
    return " ".join(words)


def stop_name(raw: str) -> str:
    """'Fermata 252 - PORTA NUOVA' -> 'Porta Nuova'."""
    return pretty(re.sub(r"^Fermata\s+\S+\s*-\s*", "", raw.strip()))


def _seconds(clock: str) -> int:
    h, m, s = clock.strip().split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def metres(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(a))


def line_key(line: str) -> str:
    """What the user calls a line, as GTT names it: 'tram 4' -> '4', 'the metro' -> 'M1'."""
    key = re.sub(r"^(the|il|la|lo)\s+", "", line.strip(), flags=re.I)
    key = re.sub(r"^(tram|bus|linea|line|number|n\.?)\s*", "", key, flags=re.I).strip()
    return "M1" if key.lower() in ("metro", "metropolitana", "m1") else key.upper()


# -- the timetable --------------------------------------------------------------------------


def build(zip_path: Path, out: Path, today: date) -> None:
    """GTT's GTFS zip into a fresh SQLite file at `out` (replaced in one go, so readers never see half of it)."""
    tmp = out.with_name(out.name + ".tmp")
    tmp.unlink(missing_ok=True)
    conn = sqlite3.connect(tmp)
    try:
        conn.execute("PRAGMA journal_mode=OFF")
        conn.execute("PRAGMA synchronous=OFF")
        conn.executescript(GTFS_SCHEMA)
        with zipfile.ZipFile(zip_path) as z:
            def rows(name: str):
                with z.open(name) as f:
                    yield from csv.DictReader(io.TextIOWrapper(f, "utf-8-sig", newline=""))

            conn.executemany("INSERT INTO stops VALUES (?, ?, ?, ?, ?)", (
                (r["stop_id"], r["stop_code"] or r["stop_id"], stop_name(r["stop_name"]), float(r["stop_lat"]),
                 float(r["stop_lon"]))
                for r in rows("stops.txt") if r.get("location_type", "") in ("", "0")))
            conn.executemany("INSERT INTO routes VALUES (?, ?, ?)", (
                (r["route_id"], r["route_short_name"] or r["route_id"], r["route_type"]) for r in rows("routes.txt")))
            conn.executemany("INSERT INTO trips VALUES (?, ?, ?, ?)", (
                (r["trip_id"], r["route_id"], r["service_id"], pretty(r.get("trip_headsign", "")))
                for r in rows("trips.txt")))
            conn.executemany("INSERT INTO stop_times VALUES (?, ?, ?, ?)", (
                (r["trip_id"], int(r["stop_sequence"]), r["stop_id"], _seconds(r["arrival_time"] or r["departure_time"]))
                for r in rows("stop_times.txt") if r["arrival_time"] or r["departure_time"]))

            days = [today + timedelta(days=i) for i in range(-1, SERVICE_DAYS - 1)]
            running: set[tuple[str, date]] = set()
            names = set(z.namelist())
            if "calendar.txt" in names:
                weekdays = ("monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday")
                for r in rows("calendar.txt"):
                    start, end = (datetime.strptime(r[k], "%Y%m%d").date() for k in ("start_date", "end_date"))
                    running |= {(r["service_id"], d) for d in days
                                if start <= d <= end and r[weekdays[d.weekday()]] == "1"}
            if "calendar_dates.txt" in names:
                for r in rows("calendar_dates.txt"):
                    d = datetime.strptime(r["date"], "%Y%m%d").date()
                    if d in days:
                        (running.add if r["exception_type"] == "1" else running.discard)((r["service_id"], d))
            conn.executemany("INSERT INTO service_days VALUES (?, ?)", ((s, d.isoformat()) for s, d in running))

        conn.executescript(GTFS_INDEXES)
        conn.execute("INSERT INTO stop_lines SELECT DISTINCT st.stop, t.route, t.headsign "
                     "FROM stop_times st JOIN trips t ON t.id = st.trip")
        conn.execute("INSERT INTO meta VALUES ('built', ?)", (today.isoformat(),))
        conn.commit()
    finally:
        conn.close()
    os.replace(tmp, out)


class Timetable:
    """The static timetable, read from its own SQLite file. Not ready until the first build."""

    def __init__(self, path: Path, tz: ZoneInfo, http: httpx.AsyncClient | None = None, url: str = GTFS_URL):
        self.path, self.tz, self.url = Path(path), tz, url
        self._http = http
        self._conn: sqlite3.Connection | None = None
        if self.path.exists():
            self._open()

    def _open(self) -> None:
        old = self._conn
        self._conn = sqlite3.connect(f"file:{self.path}?mode=ro", uri=True, check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        if old:
            old.close()

    @property
    def ready(self) -> bool:
        return self._conn is not None

    @property
    def conn(self) -> sqlite3.Connection:
        if self._conn is None:
            raise RuntimeError("GTT's timetable isn't loaded yet (it downloads on the first start); try again in a "
                               "minute")
        return self._conn

    def built(self) -> date | None:
        if not self.ready:
            return None
        row = self.conn.execute("SELECT value FROM meta WHERE key = 'built'").fetchone()
        return date.fromisoformat(row[0]) if row else None

    async def refresh(self) -> None:
        """Download GTT's feed and rebuild. The old timetable serves until the new one is in place."""
        http = self._http or httpx.AsyncClient(timeout=120, follow_redirects=True)
        zip_path = self.path.with_name(self.path.stem + ".zip")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            async with http.stream("GET", self.url) as r:
                r.raise_for_status()
                with open(zip_path, "wb") as f:
                    async for chunk in r.aiter_bytes():
                        f.write(chunk)
        finally:
            if self._http is None:
                await http.aclose()
        await asyncio.to_thread(build, zip_path, self.path, datetime.now(self.tz).date())
        zip_path.unlink(missing_ok=True)
        self._open()

    async def run(self) -> None:
        """Build now if there's no timetable, then again every night after REBUILD_AT. A failure retries in an hour."""
        while True:
            now = datetime.now(self.tz)
            built = self.built()
            if built is None or (built < now.date() and now.hour >= REBUILD_AT):
                try:
                    await self.refresh()
                    log.info("GTT timetable rebuilt (%d stops)", self.conn.execute("SELECT count(*) FROM stops")
                             .fetchone()[0])
                except Exception:
                    log.exception("GTT timetable rebuild failed; trying again in an hour")
                    await asyncio.sleep(3600)
                    continue
            await asyncio.sleep(600)

    # -- reading -----------------------------------------------------------

    def stop(self, stop_id: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM stops WHERE id = ?", (stop_id,)).fetchone()
        return dict(row) if row else None

    def find(self, query: str) -> list[dict]:
        """Stops by the number on the sign, or by name (several: each side of the road is its own stop)."""
        q = query.strip()
        q = re.sub(r"^(fermata|stop|palina)\s*", "", q, flags=re.I).strip()
        if q.isdigit():
            rows = self.conn.execute("SELECT * FROM stops WHERE code = ?", (q,)).fetchall()
        else:
            rows = self.conn.execute("SELECT * FROM stops WHERE name LIKE ? ORDER BY name, code LIMIT 30",
                                     (f"%{q}%",)).fetchall()
        return [dict(r) for r in rows]

    def near(self, lat: float, lon: float, radius: float = NEAR, limit: int = 8) -> list[tuple[dict, float]]:
        dlat = radius / 111_000
        dlon = radius / (111_000 * max(math.cos(math.radians(lat)), 0.1))
        rows = self.conn.execute("SELECT * FROM stops WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
                                 (lat - dlat, lat + dlat, lon - dlon, lon + dlon)).fetchall()
        found = sorted(((dict(r), metres(lat, lon, r["lat"], r["lon"])) for r in rows), key=lambda x: x[1])
        return [f for f in found if f[1] <= radius][:limit]

    def lines(self, stop_id: str) -> list[dict]:
        """The lines that stop here, each with where it's going from here: [{name, vehicle, headsigns}]."""
        rows = self.conn.execute("SELECT r.name, r.type, sl.headsign FROM stop_lines sl JOIN routes r ON r.id = sl.route "
                                 "WHERE sl.stop = ?", (stop_id,)).fetchall()
        out: dict[str, dict] = {}
        for r in rows:
            line = out.setdefault(r["name"], {"name": r["name"], "vehicle": VEHICLES.get(r["type"], "Bus"),
                                              "headsigns": []})
            if r["headsign"] and r["headsign"] not in line["headsigns"]:
                line["headsigns"].append(r["headsign"])
        return sorted(out.values(), key=lambda l: (len(l["name"]), l["name"]))

    def routes(self, line: str) -> list[dict]:
        rows = self.conn.execute("SELECT * FROM routes WHERE upper(name) = ?", (line_key(line),)).fetchall()
        return [dict(r) for r in rows]

    def scheduled(self, stops: list[str], start: datetime, end: datetime, routes: list[str] | None = None) -> list[dict]:
        """Timetabled arrivals at these stops between start and end: trip, seq, stop, day, at, line, vehicle,
        headsign. A service day's trips can run past midnight, so yesterday's late ones are in too."""
        start, end = start.astimezone(self.tz), end.astimezone(self.tz)
        out = []
        for offset in (-1, 0, 1):
            day = start.date() + timedelta(days=offset)
            midnight = datetime.combine(day, time(), self.tz)
            lo, hi = int((start - midnight).total_seconds()), int((end - midnight).total_seconds())
            if hi < 0:
                continue
            marks = ",".join("?" * len(stops))
            sql = (f"SELECT st.trip, st.seq, st.stop, st.at, t.headsign, r.name, r.type FROM stop_times st "
                   f"JOIN trips t ON t.id = st.trip JOIN routes r ON r.id = t.route "
                   f"JOIN service_days s ON s.service = t.service AND s.day = ? "
                   f"WHERE st.stop IN ({marks}) AND st.at BETWEEN ? AND ?")
            args: list = [day.isoformat(), *stops, lo, hi]
            if routes is not None:
                sql += f" AND t.route IN ({','.join('?' * len(routes))})"
                args += routes
            for r in self.conn.execute(sql, args):
                out.append({"trip": r["trip"], "seq": r["seq"], "stop": r["stop"], "day": day,
                            "at": midnight + timedelta(seconds=r["at"]), "line": r["name"],
                            "vehicle": VEHICLES.get(r["type"], "Bus"), "headsign": r["headsign"]})
        return sorted(out, key=lambda a: a["at"])


    def trip_stops(self, trip: str) -> list[dict]:
        """A trip's stops in order: seq, name, at (seconds from its service day's midnight)."""
        rows = self.conn.execute("SELECT st.seq, s.name, st.at FROM stop_times st JOIN stops s ON s.id = st.stop "
                                 "WHERE st.trip = ? ORDER BY st.seq", (trip,)).fetchall()
        return [dict(r) for r in rows]

    def reaches(self, trips: list[tuple[str, int]], to: list[str]) -> dict[str, tuple[str, int]]:
        """Which of these trips (id, the stop_sequence they're at) go on to one of the `to` stops later:
        {trip: (stop, seconds from the service day's midnight)}, the first such stop."""
        if not trips or not to:
            return {}
        out: dict[str, tuple[str, int, int]] = {}
        after = dict(trips)
        for chunk in range(0, len(trips), 400):
            ids = [t for t, _ in trips[chunk:chunk + 400]]
            rows = self.conn.execute(
                f"SELECT trip, seq, stop, at FROM stop_times WHERE trip IN ({','.join('?' * len(ids))}) "
                f"AND stop IN ({','.join('?' * len(to))})", [*ids, *to])
            for r in rows:
                if r["seq"] > after[r["trip"]] and (r["trip"] not in out or r["seq"] < out[r["trip"]][2]):
                    out[r["trip"]] = (r["stop"], r["at"], r["seq"])
        return {trip: (stop, at) for trip, (stop, at, _) in out.items()}


# -- live times -----------------------------------------------------------------------------

CANCELLED = None  # a trip the feed says won't run


class Live:
    """GTT's GTFS-Realtime trip updates: {(trip_id, YYYYMMDD): [(stop_sequence, delay seconds)] or CANCELLED}.

    GTT takes about 20 seconds to answer, so the latest feed is kept and, while someone is reading it, refreshed in
    the background. A read waits for a fetch only when what's kept is older than `wait_after`; a feed older than
    STALE is dropped, and everything runs on the timetable until a fetch works again (`down`)."""

    down = False  # the last read had no feed fresh enough to use: GTT's live data isn't coming through

    def __init__(self, http: httpx.AsyncClient | None = None, url: str = LIVE_URL):
        self._http = http or httpx.AsyncClient(timeout=FETCH_TIMEOUT)
        self.url = url
        self._trips: dict = {}
        self._at: float | None = None  # loop time of the last good fetch
        self._task: asyncio.Task | None = None

    async def _fetch(self) -> None:
        try:
            r = await self._http.get(self.url)
            r.raise_for_status()
            self._trips = parse_live(r.content)
            self._at = asyncio.get_running_loop().time()
        except Exception as e:  # noqa: BLE001: the timetable still works
            log.warning("GTT live feed unavailable (%s): timetable only", type(e).__name__ if not str(e) else e)

    async def trips(self, wait_after: float = WAIT_AFTER) -> dict:
        now = asyncio.get_running_loop().time()
        age = now - self._at if self._at is not None else math.inf
        if age > LIVE_TTL and (self._task is None or self._task.done()):
            self._task = asyncio.create_task(self._fetch())
        if age > wait_after and self._task and not self._task.done():
            try:
                await asyncio.wait_for(asyncio.shield(self._task), READ_WAIT)
            except TimeoutError:
                pass
            age = asyncio.get_running_loop().time() - self._at if self._at is not None else math.inf
        self.down = age > STALE
        return self._trips if age <= STALE else {}


def parse_live(data: bytes) -> dict:
    from google.transit import gtfs_realtime_pb2 as rt

    feed = rt.FeedMessage()
    feed.ParseFromString(data)
    trips: dict = {}
    for e in feed.entity:
        if not e.HasField("trip_update"):
            continue
        tu = e.trip_update
        key = (tu.trip.trip_id, tu.trip.start_date)
        if tu.trip.schedule_relationship == rt.TripDescriptor.CANCELED:
            trips[key] = CANCELLED
            continue
        updates = []
        for u in tu.stop_time_update:
            event = u.arrival if u.HasField("arrival") else u.departure if u.HasField("departure") else None
            if event is not None and event.HasField("delay"):
                updates.append((u.stop_sequence, event.delay))
        trips[key] = sorted(updates)
    return trips


@dataclass(frozen=True)
class Arrival:
    line: str
    vehicle: str
    headsign: str
    stop: str
    at: datetime  # expected, with the live delay
    scheduled: datetime
    live: bool
    trip: str
    seq: int = 0
    day: date | None = None  # the trip's service day
    to_stop: str | None = None  # where the user is going, when asked: the stop it gets there
    to_at: datetime | None = None  # and when, with the same delay

    @property
    def delay(self) -> int | None:
        """Seconds late (negative: early), when live."""
        return round((self.at - self.scheduled).total_seconds()) if self.live else None

    def seconds(self, now: datetime) -> float:
        return (self.at - now).total_seconds()

    def minutes(self, now: datetime) -> int:
        return max(0, round(self.seconds(now) / 60))

    def name(self) -> str:
        return f"{self.vehicle} {self.line}"


class Transit:
    def __init__(self, timetable: Timetable, live: Live):
        self.timetable, self.live = timetable, live

    async def arrivals(self, stops: list[str], line: str | None = None, now: datetime | None = None,
                       within: timedelta = timedelta(minutes=60), to: list[str] | None = None) -> list[Arrival]:
        """What's coming to these stops in the next `within`, soonest first, live where GTT has it. With `to`
        (stop ids), only the trips that go on to one of them, with when they get there."""
        now = now or utcnow()
        routes = None
        if line:
            routes = [r["id"] for r in self.timetable.routes(line)]
            if not routes:
                raise ValueError(f"GTT has no line {line!r}")
        rows = self.timetable.scheduled(stops, now - LATE, now + within, routes)
        live = await self.live.trips() if rows else {}
        out = []
        for r in rows:
            key = (r["trip"], r["day"].strftime("%Y%m%d"))
            at, is_live = r["at"], False
            if key in live:
                updates = live[key]
                if updates is CANCELLED:
                    continue
                before = [delay for seq, delay in updates if seq <= r["seq"]]
                if updates and not before:
                    continue  # its next stop is past this one: it has gone by
                if before:
                    at, is_live = r["at"] + timedelta(seconds=before[-1]), True
            if at < now - timedelta(seconds=30) or at > now + within:
                continue
            out.append(Arrival(r["line"], r["vehicle"], r["headsign"], r["stop"], at, r["at"], is_live, r["trip"],
                               r["seq"], r["day"]))
        if to is not None:
            reach = self.timetable.reaches([(a.trip, a.seq) for a in out], to)
            out = [replace(a, to_stop=reach[a.trip][0],
                           to_at=datetime.combine(a.day, time(), self.timetable.tz)
                           + timedelta(seconds=reach[a.trip][1]) + (a.at - a.scheduled))
                   for a in out if a.trip in reach]
        return sorted(out, key=lambda a: a.at)

    async def position(self, a: Arrival, now: datetime) -> dict:
        """Where a's trip is now: `stops`, how many it has still to reach before a's stop (0: that's its next one);
        `near`, the stop it's at or has just left; `starts`, when it leaves its first stop, if it hasn't yet.
        With live data, the feed's next stop for it; else its timetable shifted by its delay."""
        stops = [s for s in self.timetable.trip_stops(a.trip) if s["seq"] <= a.seq]
        if not stops or a.day is None:
            return {"stops": None, "near": None, "starts": None}
        midnight = datetime.combine(a.day, time(), self.timetable.tz)
        updates = (await self.live.trips()).get((a.trip, a.day.strftime("%Y%m%d"))) if a.live else None

        def expected(s: dict) -> datetime:
            if not updates:
                return midnight + timedelta(seconds=s["at"]) + (a.at - a.scheduled)
            known = [delay for seq, delay in updates if seq <= s["seq"]]
            return midnight + timedelta(seconds=s["at"] + (known[-1] if known else updates[0][1]))

        if updates:
            heading = updates[0][0]
        else:
            heading = next((s["seq"] for s in stops if expected(s) > now), a.seq)
        first = stops[0]
        if heading <= first["seq"] and expected(first) > now:
            return {"stops": len(stops) - 1, "near": first["name"], "starts": int(expected(first).timestamp())}
        left = [s for s in stops if s["seq"] < heading]
        return {"stops": len(stops) - len(left) - 1, "near": (left[-1] if left else first)["name"], "starts": None}


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


class Boards:
    """Departure cards (docs/API.md, "Transit (GTT)", the `departures` attachment): a stop's next trams and buses by
    line and direction, live or timetable, late or early, the walk from the phone, and when asked, where the user is
    going. Chat shows them from the tools; the app refreshes them through GET /v1/transit/departures."""

    def __init__(self, transit: Transit, location: "Location", walks: "Walks"):
        self.transit, self.location, self.walks = transit, location, walks

    async def destination(self, to: str) -> dict:
        """Where the user is going, as {"name", "stops": [ids]}: the stops by that name, or (with Maps) the stops
        within NEAR of the place. A ValueError when neither finds anything."""
        found = self.transit.timetable.find(to)
        if found:
            names = {s["name"] for s in found}
            return {"name": found[0]["name"] if len(names) == 1 else to.strip(), "stops": [s["id"] for s in found]}
        maps = self.walks.maps
        place = None
        if maps is not None:
            try:
                place = await maps.locate(f"{to.strip()}, Torino", near=TURIN)
            except Exception as e:  # noqa: BLE001: said below
                log.warning("finding %r on Maps failed: %s", to, e)
        if place:
            near = self.transit.timetable.near(place["lat"], place["lon"], limit=20)
            if near:
                return {"name": place["name"], "stops": [s["id"] for s, _ in near]}
            raise ValueError(f"{place['name']} has no GTT stop within {NEAR} m")
        raise ValueError(f"no GTT stop matches {to!r}" + ("" if maps else " (and Maps is off, so places can't be "
                                                                         "looked up): ask for the stop's name"))

    async def board(self, stop: dict, line: str | None = None, to: dict | None = None, now: datetime | None = None,
                    arrivals: list[Arrival] | None = None) -> dict:
        """`to`: {"name", "stops": [ids]}. `arrivals`: already fetched for this stop (else fetched here)."""
        now = now or utcnow()
        if arrivals is None:
            arrivals = await self.transit.arrivals([stop["id"]], line, now, to=to["stops"] if to else None)
        groups: dict[tuple, list[Arrival]] = {}
        for a in arrivals:
            if a.stop == stop["id"]:
                groups.setdefault((a.line, a.headsign), []).append(a)
        distance = walk = None
        fix = self.location.latest()
        if fix and now - fix["at"] <= FIX_USABLE:
            d = metres(fix["lat"], fix["lon"], stop["lat"], stop["lon"])
            if d <= WALK_SHOWN:
                distance, walk = round(d), await self.walks.seconds(fix["lat"], fix["lon"], stop)
        names = {}
        if to:
            names = {s: self.transit.timetable.stop(s) for s in {a.to_stop for a in arrivals if a.to_stop}}
        return {
            "id": f"{stop['id']}:{line_key(line) if line else ''}:{to['name'] if to else ''}",
            "stop": {"id": stop["id"], "code": stop["code"], "name": stop["name"]},
            "at": _iso(now), "distance": distance, "walk": walk,
            "line": line_key(line) if line else None,
            "to": {"name": to["name"], "stops": to["stops"]} if to else None,
            "lines": [{
                "line": times[0].line, "vehicle": times[0].vehicle, "towards": times[0].headsign,
                "arrivals": [{"at": _iso(a.at), "scheduled": _iso(a.scheduled), "live": a.live, "delay": a.delay,
                              **({"to_at": _iso(a.to_at), "to_stop": (names.get(a.to_stop) or {}).get("code")}
                                 if a.to_at else {})}
                             for a in times[:BOARD_TIMES]],
            } for (_, _), times in groups.items()],
        }


    async def nearby(self, now: datetime | None = None) -> tuple[list[dict], datetime | None]:
        """The departures widget: boards for the NEARBY stops closest to the phone's fix (under FIX_USABLE old,
        within NEAR) with something in the next hour, nearest first; and the fix's time (None without one)."""
        now = now or utcnow()
        fix = self.location.latest()
        if fix is None:
            return [], None
        if now - fix["at"] > FIX_USABLE:
            return [], fix["at"]
        out = []
        for stop, _ in self.transit.timetable.near(fix["lat"], fix["lon"], limit=8):
            arrivals = await self.transit.arrivals([stop["id"]], now=now)
            if not arrivals:
                continue
            out.append(await self.board(stop, now=now, arrivals=arrivals))
            if len(out) == NEARBY:
                break
        return out, fix["at"]


# -- where the phone is ---------------------------------------------------------------------


class Location:
    """The phone's latest fix. `request` asks the phone for a fresh one (a silent push), `fresh` waits for it."""

    def __init__(self, conn: sqlite3.Connection, push: Push | None = None):
        self.conn, self.push = conn, push
        self.conn.executescript(ALERTS_SCHEMA)
        self._asked: datetime | None = None
        self._arrived = asyncio.Event()

    def save(self, lat: float, lon: float, accuracy: float | None = None, at: datetime | None = None) -> None:
        if not (-90 <= lat <= 90 and -180 <= lon <= 180):
            raise ValueError("lat and lon are out of range")
        at = (at or utcnow()).astimezone(timezone.utc)
        latest = self.latest()
        if latest and latest["at"] > at:
            return  # an older fix that arrived late
        self.conn.execute("INSERT INTO location (id, lat, lon, accuracy, at) VALUES (1, ?, ?, ?, ?) "
                          "ON CONFLICT(id) DO UPDATE SET lat = excluded.lat, lon = excluded.lon, "
                          "accuracy = excluded.accuracy, at = excluded.at", (lat, lon, accuracy, at.isoformat()))
        self._arrived.set()

    def latest(self) -> dict | None:
        row = self.conn.execute("SELECT * FROM location WHERE id = 1").fetchone()
        return {**dict(row), "at": datetime.fromisoformat(row["at"])} if row else None

    async def request(self, now: datetime | None = None) -> bool:
        """Ask the phone for a fix, at most once per FIX_EVERY. True if a push went out."""
        now = now or utcnow()
        if not (self.push and self.push.enabled) or (self._asked and now - self._asked < FIX_EVERY):
            return False
        self._asked = now
        self._arrived.clear()
        return await self.push.request_location()

    async def fresh(self, max_age: timedelta = FIX_AGE, wait: float = 12) -> dict | None:
        """A fix younger than max_age if the phone answers within `wait` seconds, else the latest one there is."""
        latest = self.latest()
        if latest and utcnow() - latest["at"] <= max_age:
            return latest
        if await self.request():
            try:
                await asyncio.wait_for(self._arrived.wait(), wait)
            except TimeoutError:
                pass
        return self.latest()

    async def here(self) -> tuple[float, float] | None:
        """Where the phone is, as (lat, lon), asking it for a fresh fix first; None when no fix is under FIX_USABLE."""
        fix = await self.fresh()
        if fix is None or utcnow() - fix["at"] > FIX_USABLE:
            return None
        return fix["lat"], fix["lon"]


class Whereabouts:
    """Where the phone is, in words, for the stamp on each message ("phone near Piazza Castello 34, Torino,
    5 min ago"): the address near the latest fix, looked up again only after a move of MOVED metres."""

    MOVED = 150
    TIMEOUT = 5  # seconds a message waits for the lookup

    def __init__(self, location: Location, maps):
        self.location, self.maps = location, maps
        self._known: tuple[float, float, str] | None = None

    async def describe(self, now: datetime | None = None) -> str | None:
        fix = self.location.latest()
        now = now or utcnow()
        if fix is None or now - fix["at"] > FIX_USABLE:
            return None
        address = await self.address(fix["lat"], fix["lon"])
        if not address:
            return None
        minutes = int((now - fix["at"]).total_seconds() // 60)
        age = "just now" if minutes < 2 else f"{minutes} min ago" if minutes < 60 else f"{minutes // 60} h ago"
        return f"phone near {address}, {age}"

    async def address(self, lat: float, lon: float) -> str | None:
        """The street near a point, kept until the next point is over MOVED away; None if Maps can't say."""
        known = self._known
        if known is None or metres(known[0], known[1], lat, lon) > self.MOVED:
            try:
                address = await asyncio.wait_for(self.maps.address_near(lat, lon), self.TIMEOUT)
            except Exception as e:  # noqa: BLE001: the message goes without it
                log.warning("no address near the phone: %s", e)
                return None
            if not address:
                return None
            known = self._known = (lat, lon, address)
        return known[2]


class Walks:
    """Walking time to a stop: Google Maps when it's set up, else the straight line stretched for streets."""

    def __init__(self, maps=None):
        self.maps = maps
        self._cache: dict[tuple, int] = {}

    async def seconds(self, lat: float, lon: float, stop: dict) -> int:
        key = (round(lat, 3), round(lon, 3), stop["id"])  # about 100 m
        if key in self._cache:
            return self._cache[key]
        straight = metres(lat, lon, stop["lat"], stop["lon"])
        walk = round(straight * DETOUR / WALK_SPEED)
        if self.maps is not None and straight > 50:
            try:
                point = lambda la, lo: {"location": {"latLng": {"latitude": la, "longitude": lo}}}  # noqa: E731
                route = await self.maps.route({"origin": point(lat, lon), "destination": point(stop["lat"], stop["lon"]),
                                               "travelMode": "WALK"})
                if route and route.get("duration"):
                    walk = int(float(route["duration"].rstrip("s")))
            except Exception as e:  # noqa: BLE001: the estimate will do
                log.warning("walk time from Maps failed (%s): using the straight line", e)
        self._cache[key] = walk
        return walk


# -- alerts -----------------------------------------------------------------------------------


class AlertStore:
    """Tram alerts: commutes (days and a time, every week) and one-offs (the next tram, or one around a time)."""

    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, timetable: Timetable):
        self.conn, self.tz, self.timetable = conn, tz, timetable
        self.conn.executescript(ALERTS_SCHEMA)
        if "event" not in {r["name"] for r in self.conn.execute("PRAGMA table_info(transit_alerts)")}:
            self.conn.execute("ALTER TABLE transit_alerts ADD COLUMN event TEXT")  # from before leave-now for events

    def _row(self, row) -> dict:
        a = dict(row)
        a["days"] = json.loads(a["days"]) if a["days"] is not None else None
        a["enabled"] = bool(a["enabled"])
        return a

    def all(self) -> list[dict]:
        return [self._row(r) for r in self.conn.execute("SELECT * FROM transit_alerts ORDER BY id")]

    def get(self, alert_id: int) -> dict:
        row = self.conn.execute("SELECT * FROM transit_alerts WHERE id = ?", (alert_id,)).fetchone()
        if row is None:
            raise ValueError(f"no tram alert {alert_id}")
        return self._row(row)

    def _check(self, stop: str, line: str, minutes: int | None) -> tuple[str, str]:
        if self.timetable.stop(stop) is None:
            raise ValueError(f"no GTT stop {stop!r}")
        routes = {r["name"] for r in self.timetable.routes(line)}
        if not routes:
            raise ValueError(f"GTT has no line {line!r}")
        if not routes & {l["name"] for l in self.timetable.lines(stop)}:
            raise ValueError(f"line {line_key(line)} doesn't stop at stop {self.timetable.stop(stop)['code']}")
        if minutes is not None and not 1 <= minutes <= 60:
            raise ValueError("minutes must be 1 to 60")
        return stop, routes.pop()

    def _window(self, time_: str | None, now: datetime, day: date | None = None) -> tuple[datetime, datetime]:
        """A one-off's start and end: around its time (on `day`; else today, or tomorrow if that's gone), else from
        now."""
        if time_ is None:
            return now, now + ONCE_FOR
        hh, mm = map(int, time_.split(":"))
        local = now.astimezone(self.tz)
        at = datetime.combine(day or local.date(), time(hh, mm), self.tz)
        if day is None and at + WINDOW < local:
            at += timedelta(days=1)
        return (at - WINDOW).astimezone(timezone.utc), (at + WINDOW).astimezone(timezone.utc)

    def create(self, stop: str, line: str, time_: str | None = None, days: list[int] | None = None,
               minutes: int | None = None, now: datetime | None = None, event: str | None = None,
               day: date | None = None) -> dict:
        now = now or utcnow()
        stop, line = self._check(stop, line, minutes)
        if time_ is not None:
            time_ = check_time(time_)
        if days is not None:
            if time_ is None:
                raise ValueError("a commute needs a time")
            days = check_days(days)
            starts = ends = None
        else:
            starts, ends = (t.isoformat() for t in self._window(time_, now, day))
        cur = self.conn.execute(
            "INSERT INTO transit_alerts (stop, line, time, days, minutes, starts_at, ends_at, created_at, event) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (stop, line, time_, json.dumps(days) if days is not None else None, minutes, starts, ends, now.isoformat(),
             event))
        return self.get(cur.lastrowid)

    def update(self, alert_id: int, now: datetime | None = None, **changes) -> dict:
        a = self.get(alert_id)
        now = now or utcnow()
        a.update({k: v for k, v in changes.items() if v is not None})
        if "minutes" in changes and changes["minutes"] == 0:
            a["minutes"] = None  # 0: back to "when it's time to leave"
        a["stop"], a["line"] = self._check(a["stop"], a["line"], a["minutes"])
        if a["time"] is not None:
            a["time"] = check_time(a["time"])
        if a["days"] is not None:
            if a["time"] is None:
                raise ValueError("a commute needs a time")
            a["days"] = check_days(a["days"])
        elif {"time", "enabled"} & {k for k, v in changes.items() if v is not None}:
            a["starts_at"], a["ends_at"] = (t.isoformat() for t in self._window(a["time"], now))
        self.conn.execute(
            "UPDATE transit_alerts SET stop = ?, line = ?, time = ?, days = ?, minutes = ?, enabled = ?, starts_at = ?, "
            "ends_at = ? WHERE id = ?",
            (a["stop"], a["line"], a["time"], json.dumps(a["days"]) if a["days"] is not None else None, a["minutes"],
             int(bool(a["enabled"])), a["starts_at"], a["ends_at"], alert_id))
        return self.get(alert_id)

    def delete(self, alert_id: int) -> None:
        self.conn.execute("DELETE FROM transit_alerts WHERE id = ?", (alert_id,))

    def alerted(self, a: dict, now: datetime) -> None:
        if a["days"] is None:
            self.delete(a["id"])  # a one-off is done
        else:
            self.conn.execute("UPDATE transit_alerts SET last_alert = ? WHERE id = ?", (now.isoformat(), a["id"]))

    def active(self, now: datetime) -> list[tuple[dict, datetime | None]]:
        """The alerts watching now, each with the earliest its tram can come (None: any). One-offs past their end
        are dropped."""
        out = []
        local = now.astimezone(self.tz)
        for a in self.all():
            if not a["enabled"]:
                continue
            if a["days"] is None:
                starts, ends = datetime.fromisoformat(a["starts_at"]), datetime.fromisoformat(a["ends_at"])
                if now > ends:
                    log.info("tram alert %s ended without its tram", a["id"])
                    self.delete(a["id"])
                elif now >= starts:
                    out.append((a, starts + WINDOW - EARLY if a["time"] else None))
                continue
            if a["days"] and local.isoweekday() not in a["days"]:
                continue
            hh, mm = map(int, a["time"].split(":"))
            at = datetime.combine(local.date(), time(hh, mm), self.tz)
            if not at - WINDOW <= local <= at + WINDOW:
                continue
            if a["last_alert"] and datetime.fromisoformat(a["last_alert"]) >= at - WINDOW:
                continue  # already told today
            out.append((a, at - EARLY))
        return out

    def describe(self, a: dict) -> str:
        """'Tram 4 at Porta Nuova (stop 252), towards Falchera: Mon–Fri around 08:10, when it's time to leave'."""
        stop = self.timetable.stop(a["stop"]) if self.timetable.ready else None
        lines = {l["name"]: l for l in self.timetable.lines(a["stop"])} if stop else {}
        line = lines.get(a["line"])
        text = f"{line['vehicle'] if line else 'Line'} {a['line']}"
        text += f" at {stop['name']} (stop {stop['code']})" if stop else f" at stop {a['stop']}"
        if line and line["headsigns"]:
            text += f", towards {' / '.join(line['headsigns'][:2])}"
        if a["days"] is not None:
            text += f": {days_text(a['days'])} around {a['time']}"
        elif a["time"]:
            start = datetime.fromisoformat(a["starts_at"]).astimezone(self.tz) + WINDOW
            today = start.date() == datetime.now(self.tz).date()
            text += f": once, around {a['time']}" + ("" if today else f" on {start:%a %d %b}")
        else:
            text += ": once, the next one"
        text += f", when it's {a['minutes']} min away" if a["minutes"] else ", when it's time to leave"
        if a["event"]:
            text += f", for {a['event']}"
        return text + ("" if a["enabled"] else " (off)")

    def as_json(self, a: dict) -> dict:
        stop = self.timetable.stop(a["stop"]) if self.timetable.ready else None
        line = next((l for l in self.timetable.lines(a["stop"]) if l["name"] == a["line"]), None) if stop else None
        return {"id": a["id"], "line": a["line"], "vehicle": line["vehicle"] if line else None,
                "towards": line["headsigns"][:2] if line else [],
                "stop": {"id": a["stop"], "code": stop["code"], "name": stop["name"]} if stop else
                {"id": a["stop"], "code": None, "name": None},
                "time": a["time"], "days": a["days"], "once": a["days"] is None, "minutes": a["minutes"],
                "enabled": a["enabled"], "event": a["event"], "summary": self.describe(a)}


class AlertWatcher:
    """Checks the active alerts every TICK and sends the push when it's time."""

    def __init__(self, store: AlertStore, transit: Transit, location: Location, walks: Walks, push: Push | None,
                 live: "LiveActivities | None" = None):
        self.store, self.transit, self.location, self.walks, self.push = store, transit, location, walks, push
        self.live = live
        # Trams with a Live Activity, by its key: {"trip", "day", "stop", "line", "leave_by", "state", "started"}.
        self.following: dict[str, dict] = {}

    async def run(self) -> None:
        while True:
            await asyncio.sleep(TICK)
            if not self.transit.timetable.ready:
                continue
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("tram alert tick failed")

    async def tick(self, now: datetime) -> None:
        for a, earliest in self.store.active(now):
            try:
                await self.check(a, earliest, now)
            except Exception:
                log.exception("tram alert %s failed", a["id"])
        for key in list(self.following):
            try:
                await self.follow(key, now)
            except Exception:
                log.exception("tram Live Activity %s failed", key)

    async def walk(self, stop: dict, now: datetime) -> int | None:
        """Seconds from where the phone is to the stop; None if it's not known."""
        here = self.location.latest()
        if here is None or now - here["at"] > FIX_USABLE:
            return None
        return await self.walks.seconds(here["lat"], here["lon"], stop)

    async def check(self, a: dict, earliest: datetime | None, now: datetime) -> None:
        stop = self.transit.timetable.stop(a["stop"])
        if stop is None:
            return
        leave = a["minutes"] is None
        if leave:
            here = self.location.latest()
            if here is None or now - here["at"] > FIX_AGE:
                await self.location.request(now)
        walk = await self.walk(stop, now)
        arrivals = await self.transit.arrivals([a["stop"]], a["line"], now, within=timedelta(minutes=90))
        need = walk if walk is not None else DEFAULT_WALK if leave else 0
        catchable = [x for x in arrivals if x.seconds(now) >= need and (earliest is None or x.at >= earliest)]
        if not catchable:
            return
        tram = catchable[0]
        lead = a["minutes"] * 60 if not leave else (walk if walk is not None else DEFAULT_WALK) + BUFFER
        if tram.seconds(now) > lead:
            return
        after = catchable[1] if len(catchable) > 1 else None
        where = await self.transit.position(tram, now)
        title, body = alert_text(tram, after, stop, walk, leave, now, a["event"], where, self.transit.live.down)
        if await self.start_live(a, tram, after, stop, walk, leave, title, body, now, where):
            log.info("tram alert %s: Live Activity started", a["id"])
        elif not (self.push and await self.push.send_transit(a["id"], title, body)):
            log.warning("tram alert %s: push didn't go out", a["id"])
        log.info("tram alert %s: %s", a["id"], title)
        self.store.alerted(a, now)


    # -- the Live Activity (docs/API.md, "Live Activities", tram) -----------------------------------------------

    def live_state(self, tram: Arrival, after: Arrival | None, leave_by: int | None, walk: int | None,
                   where: dict, gone: bool = False) -> dict:
        at = int(tram.at.timestamp())
        return {"at": at, "leave": at - leave_by if leave_by is not None else None, "walk": walk, "live": tram.live,
                "delay": tram.delay, "next": int(after.at.timestamp()) if after else None, "gone": gone, **where,
                "feed_down": self.transit.live.down}

    async def start_live(self, a: dict, tram: Arrival, after: Arrival | None, stop: dict, walk: int | None,
                         leave: bool, title: str, body: str, now: datetime, where: dict) -> bool:
        """Push-start the tram's countdown instead of the plain push. False if there's no start token."""
        if not (self.live and self.live.start_token("tram")):
            return False
        key = f"tram:{a['id']}:{tram.trip}:{tram.day:%Y%m%d}" if tram.day else f"tram:{a['id']}:{tram.trip}"
        leave_by = (walk if walk is not None else DEFAULT_WALK) + AT_STOP if leave else None
        state = self.live_state(tram, after, leave_by, walk, where)
        attributes = {"key": key, "line": tram.line, "vehicle": tram.vehicle, "stop": stop["name"],
                      "code": stop["code"], "towards": tram.headsign or None, "alert": a["id"]}
        try:
            ok = await self.live.start("tram", attributes, state,
                                       {"title": title, "body": body, "sound": "default"}, stale=tram.at + LIVE_STALE)
        except Exception:
            log.exception("tram alert %s: Live Activity didn't start", a["id"])
            return False
        if ok:
            self.following[key] = {"trip": tram.trip, "day": tram.day, "stop": tram.stop, "line": a["line"],
                                   "leave_by": leave_by, "walk": walk, "state": state, "started": now}
        return ok

    async def follow(self, key: str, now: datetime) -> None:
        """Keep a started tram's countdown live; end it once the tram has left (or won't come)."""
        f = self.following[key]
        if now - f["started"] > LIVE_FOR:
            del self.following[key]
            return
        arrivals = await self.transit.arrivals([f["stop"]], f["line"], now, within=timedelta(minutes=90))
        mine = next((x for x in arrivals if x.trip == f["trip"] and x.day == f["day"]), None)
        if mine is None or now - mine.at >= LIVE_GONE:
            del self.following[key]
            await self.live.end(key, {**f["state"], "gone": True}, now + LIVE_STALE)
            return
        after = next((x for x in arrivals if x.at > mine.at and x.trip != mine.trip), None)
        state = self.live_state(mine, after, f["leave_by"], f["walk"], await self.transit.position(mine, now))
        same = ("next", "live", "stops", "near", "starts", "feed_down")
        if abs(state["at"] - f["state"]["at"]) < LIVE_MOVE and all(state[k] == f["state"].get(k) for k in same):
            return
        if await self.live.update(key, state, stale=mine.at + LIVE_STALE):
            f["state"] = state  # not sent (no token yet): compared with what the phone shows, so tried again


def alert_text(tram: Arrival, after: Arrival | None, stop: dict, walk: int | None, leave: bool,
               now: datetime, event: str | None = None, where: dict | None = None,
               feed_down: bool = False) -> tuple[str, str]:
    m = tram.minutes(now)
    when = "now" if m == 0 else f"in {m} min"
    go = round((tram.seconds(now) - (walk if walk is not None else DEFAULT_WALK) - AT_STOP) / 60)
    title = f"{tram.name()} {when}" + ((": leave now" if go <= 1 else f": leave in {go} min") if leave else "")
    body = f"{stop['name']} (stop {stop['code']})" + (f", towards {tram.headsign}" if tram.headsign else "") + "."
    if leave:
        body += (f" {max(1, round(walk / 60))} min walk from where you are." if walk is not None
                 else " Your location isn't known, so this assumes a 5 min walk.")
    if where and where.get("starts"):
        body += f" It leaves {where['near']} at {datetime.fromtimestamp(where['starts'], tram.at.tzinfo):%H:%M}."
    elif where and where.get("stops") is not None:
        body += (" Your stop is its next." if where["stops"] == 0
                 else f" {where['stops']} stop{'s' if where['stops'] > 1 else ''} away, near {where['near']}.")
    if not tram.live:
        body += (" From the timetable: GTT's live times aren't coming through." if feed_down
                 else " From the timetable (no live data for it).")
    if after:
        body += f" Next one in {after.minutes(now)} min."
    if event:
        body += f" For {event}."
    return title, body
