"""Leave-now alerts for the calendar. The contract is docs/API.md, "Transit (GTT)", "Leaving for an event".

A timed event with a place, in the next few hours: from where the phone is, Maps gives ways there by transit, to be
there 10 minutes early. Of those whose first ride is a GTT line, the one leaving latest on a line memory says the
user prefers there ("I take the 10 to uni"; the first named, of a few) wins; else on a frequent line (at least FREQUENT an hour at that stop),
so a missed tram isn't a long wait (Maps' first pick is often a rare extra-urban bus); else the latest. Once leaving for it is under COMMIT away, it becomes a
one-off tram alert around that departure. The tram alert watcher does the rest from the live times: the
walk from the phone, "Tram 4 in 7 min: leave now", the Live Activity. Until then the way is looked up again every
REPLAN (sooner after a move), since the phone and the trams move.

One alert per event: deleting it in the app is final. An event that moves or goes takes its alert with it.
An event with no place gets one from memory when the notes say where such events are (a lecture: the uni).
Nothing is set when the phone is already at the place, or far from it (not going); when a note in memory says the
user walks, drives or cycles there; when the first ride isn't GTT's (a train); or when the user's own alert for
that line already covers the time.
"""

import asyncio
import json
import logging
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from .db import utcnow
from .digest import ARRIVE_EARLY, AWAY, Travel
from .transit import (BUFFER, FIX_AGE, FIX_USABLE, WINDOW, AlertStore, Location, Walks, line_key, metres)

log = logging.getLogger(__name__)

TICK = 60  # seconds between checks
AHEAD = timedelta(hours=3)  # events this far ahead are looked at
EVENTS_EVERY = timedelta(minutes=10)  # the calendar is read at most this often
REPLAN = timedelta(minutes=10)  # the way there is looked up again after this long
MOVED = 300  # metres: or after a move this big
COMMIT = timedelta(minutes=45)  # the tram alert is set once leaving is this close
THERE = 500  # metres: the phone this close to the place is already there
STOP_NEAR = 150  # metres between the stop Maps names and GTT's
FREQUENT = 4  # departures an hour (around the one taken) that make a line frequent

SCHEMA = """
CREATE TABLE IF NOT EXISTS leave_plans (
    event    TEXT NOT NULL,     -- the calendar event's uid
    starts   TEXT NOT NULL,     -- its start, UTC: a moved event is a new plan
    state    TEXT NOT NULL,     -- alert (set), or skipped: why not (walks, no_place, no_ride, not_gtt, covered)
    alert    INTEGER,           -- the tram alert it set
    at       TEXT NOT NULL,     -- UTC
    PRIMARY KEY (event, starts)
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


class LeaveWatcher:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, cal, maps, alerts: AlertStore, location: Location,
                 walks: Walks, travel_plan: Callable[[dict], Awaitable[Travel]] | None = None):
        """`travel_plan(event)`: how the user gets there, from memory, as the wake briefing reads it; a mode other
        than transit means no alert, `place` is where an event with no place is, `lines` the lines they prefer."""
        self.conn, self.tz, self.cal, self.maps = conn, tz, cal, maps
        self.alerts, self.timetable, self.location, self.walks = alerts, alerts.timetable, location, walks
        self.travel_plan = travel_plan
        self.conn.executescript(SCHEMA)
        self._events: tuple[datetime, list[dict]] | None = None
        self._routes: dict[tuple[str, str], tuple[datetime, tuple[float, float], list[dict]]] = {}
        self._spots: dict[str, tuple[float, float] | None] = {}
        self._plans: dict[tuple[str, str], Travel] = {}

    # -- the setting ------------------------------------------------------------------------------------------

    def settings(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'leave_alerts'").fetchone()
        return {"calendar": True, **(json.loads(row["value"]) if row else {})}

    def update_settings(self, calendar: bool) -> dict:
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('leave_alerts', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps({"calendar": calendar}),))
        return self.settings()

    # -- the loop ---------------------------------------------------------------------------------------------

    async def run(self) -> None:
        while True:
            await asyncio.sleep(TICK)
            if not self.timetable.ready:
                continue
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("leave-now tick failed")

    async def tick(self, now: datetime) -> None:
        if not self.settings()["calendar"]:
            return
        events = await self._upcoming(now)
        if events is None:
            return
        self._drop_moved(events, now)
        done = {(r["event"], r["starts"]) for r in self.conn.execute("SELECT event, starts FROM leave_plans")}
        todo = [e for e in events if self._key(e) not in done]
        if not todo:
            return
        fix = self.location.latest()
        if fix is None or now - fix["at"] > FIX_AGE:
            await self.location.request(now)  # for the next tick
        if fix is None or now - fix["at"] > FIX_USABLE:
            return
        for e in todo:
            try:
                await self.plan(e, fix, now)
            except Exception:
                log.exception("leave-now plan for %r failed", e["title"])

    async def _upcoming(self, now: datetime) -> list[dict] | None:
        """Timed events starting in the next AHEAD, with a place (or memory to find one in); None when the
        calendar can't be read."""
        if self._events is None or now - self._events[0] >= EVENTS_EVERY:
            try:
                found = await asyncio.to_thread(self.cal.events, now, now + AHEAD)
            except Exception:
                log.warning("leave-now: couldn't read the calendar", exc_info=True)
                return None
            self._events = (now, [{"uid": e.uid, "title": e.title, "calendar": e.calendar,
                                   "location": e.location.strip(), "start": e.start.astimezone(timezone.utc)}
                                  for e in found if not e.all_day and (e.location.strip() or self.travel_plan)])
        return [e for e in self._events[1] if now < e["start"] <= now + AHEAD]

    @staticmethod
    def _key(e: dict) -> tuple[str, str]:
        return e["uid"], e["start"].isoformat()

    def _mark(self, e: dict, state: str, now: datetime, alert: int | None = None) -> None:
        self.conn.execute("INSERT OR REPLACE INTO leave_plans (event, starts, state, alert, at) VALUES (?, ?, ?, ?, ?)",
                          (*self._key(e), state, alert, now.isoformat()))
        if state != "alert":
            log.info("leave-now: no alert for %r (%s)", e["title"], state)

    def _drop_moved(self, events: list[dict], now: datetime) -> None:
        """An event that moved or went: its alert goes too. Plans for events long past are forgotten."""
        keys = {self._key(e) for e in events}
        for r in self.conn.execute("SELECT * FROM leave_plans WHERE starts > ?", (now.isoformat(),)).fetchall():
            if (r["event"], r["starts"]) in keys:
                continue
            if r["alert"] is not None:
                self.alerts.delete(r["alert"])
                log.info("leave-now: event %s moved or went, its tram alert %s too", r["event"], r["alert"])
            self.conn.execute("DELETE FROM leave_plans WHERE event = ? AND starts = ?", (r["event"], r["starts"]))
        self.conn.execute("DELETE FROM leave_plans WHERE starts < ?", ((now - timedelta(days=2)).isoformat(),))

    # -- one event --------------------------------------------------------------------------------------------

    async def plan(self, e: dict, fix: dict, now: datetime) -> None:
        here = (fix["lat"], fix["lon"])
        travel = await self._plan(e)
        if travel.mode not in (None, "transit"):
            return self._mark(e, "walks", now)
        place = e["location"] or travel.place
        there = await self._spot(place, here) if place else None
        if there is None:
            return self._mark(e, "no_place", now)
        distance = metres(*here, *there)
        if distance < THERE or distance > AWAY:
            return  # already there, or not going (not yet, at least): looked at again later
        routes = await self._ways(e, place, here, now)
        if routes is None:
            return
        rides = [ride for route in routes
                 if (ride := next((s["transitDetails"] for leg in route.get("legs", []) for s in leg.get("steps", [])
                                   if s.get("transitDetails")), None))]
        if not rides:
            return self._mark(e, "no_ride", now)
        preferred = [line_key(l) for l in travel.lines]  # best first
        rank = lambda line: len(preferred) - preferred.index(line_key(line)) if line_key(line) in preferred else 0  # noqa: E731
        options = []
        for ride in rides:
            if found := self._gtt(ride):
                departs = datetime.fromisoformat(ride["stopDetails"]["departureTime"].replace("Z", "+00:00"))
                options.append((rank(found[1]), self._frequent(found[0]["id"], found[1], departs),
                                departs, *found))
        if not options:
            return self._mark(e, "not_gtt", now)
        *_, departs, stop, line = max(options, key=lambda o: o[:3])
        walk = await self.walks.seconds(*here, stop)
        if departs - timedelta(seconds=walk + BUFFER) - now > COMMIT:
            return  # not yet: the way may change
        if self._covered(line, departs):
            return self._mark(e, "covered", now)
        local = e["start"].astimezone(self.tz)
        a = self.alerts.create(stop["id"], line, f"{departs.astimezone(self.tz):%H:%M}", now=now,
                               event=f"{e['title']} at {local:%H:%M}")
        self._mark(e, "alert", now, a["id"])
        log.info("leave-now: %s", self.alerts.describe(a))

    async def _spot(self, place: str, near: tuple[float, float]) -> tuple[float, float] | None:
        if place not in self._spots:
            try:
                found = await self.maps.locate(place, near)
            except Exception:
                log.warning("leave-now: couldn't find %r on Maps", place, exc_info=True)
                return None  # not cached: tried again next time
            self._spots[place] = (found["lat"], found["lon"]) if found else None
        return self._spots[place]

    async def _plan(self, e: dict) -> Travel:
        """How the user gets there, from memory, once per event."""
        key = self._key(e)
        if key not in self._plans:
            self._plans[key] = await self.travel_plan(e) if self.travel_plan else Travel(None)
        return self._plans[key]

    async def _ways(self, e: dict, place: str, here: tuple[float, float], now: datetime) -> list[dict] | None:
        key = self._key(e)
        cached = self._routes.get(key)
        if cached and now - cached[0] < REPLAN and metres(*cached[1], *here) < MOVED:
            return cached[2]
        body = {"origin": {"location": {"latLng": {"latitude": here[0], "longitude": here[1]}}},
                "destination": {"address": place}, "travelMode": "TRANSIT", "computeAlternativeRoutes": True,
                "arrivalTime": (e["start"] - ARRIVE_EARLY).strftime("%Y-%m-%dT%H:%M:%SZ")}
        try:
            routes = await self.maps.routes(body)
        except Exception:
            log.warning("leave-now: transit routes to %r failed", place, exc_info=True)
            return None
        self._routes[key] = (now, here, routes)
        return routes

    def _frequent(self, stop: str, line: str, departs: datetime) -> bool:
        routes = [r["id"] for r in self.timetable.routes(line)]
        half = timedelta(minutes=30)
        return len(self.timetable.scheduled([stop], departs - half, departs + half, routes)) >= FREQUENT

    def _gtt(self, ride: dict) -> tuple[dict, str] | None:
        """The GTT stop and line for Maps' first ride: a stop near the one Maps names where the line stops, the one
        going the way Maps says when both sides of the road are near."""
        named = ride.get("transitLine", {})
        want = line_key(named.get("nameShort") or named.get("name") or "")
        point = ride.get("stopDetails", {}).get("departureStop", {}).get("location", {}).get("latLng")
        if not want or not point:
            return None
        headsign = (ride.get("headsign") or "").lower()
        candidates = []
        for stop, distance in self.timetable.near(point["latitude"], point["longitude"], STOP_NEAR):
            line = next((l for l in self.timetable.lines(stop["id"]) if line_key(l["name"]) == want), None)
            if line:
                way = bool(headsign) and any(h.lower() in headsign or headsign in h.lower() for h in line["headsigns"])
                candidates.append((not way, distance, stop, line["name"]))
        if not candidates:
            return None
        _, _, stop, name = min(candidates, key=lambda c: c[:2])
        return stop, name

    def _covered(self, line: str, departs: datetime) -> bool:
        """The user's own alert for this line already watches around this departure (any side of the road)."""
        local = departs.astimezone(self.tz)
        for a in self.alerts.all():
            if not a["enabled"] or a["line"] != line:
                continue
            if a["days"] is not None:
                if a["days"] and local.isoweekday() not in a["days"]:
                    continue
                hh, mm = map(int, a["time"].split(":"))
                at = local.replace(hour=hh, minute=mm, second=0, microsecond=0)
                if abs(at - local) <= WINDOW:
                    return True
            elif datetime.fromisoformat(a["starts_at"]) <= departs <= datetime.fromisoformat(a["ends_at"]):
                return True
        return False
