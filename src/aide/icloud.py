"""iCloud Calendar over CalDAV. Synchronous: tools call it through asyncio.to_thread."""

import logging
import threading
import uuid
from urllib.parse import quote
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from typing import Protocol

import caldav
import niquests
import icalendar

log = logging.getLogger(__name__)

ICLOUD_URL = "https://caldav.icloud.com/"


@dataclass(frozen=True)
class CalEvent:
    uid: str
    calendar: str
    title: str
    start: date | datetime  # date for all-day events
    end: date | datetime
    location: str = ""
    notes: str = ""
    recurring: bool = False

    @property
    def all_day(self) -> bool:
        return not isinstance(self.start, datetime)


class RecurringEventError(Exception):
    pass


class CalendarBackend(Protocol):
    def calendars(self) -> list[str]: ...
    def events(self, start: datetime, end: datetime) -> list[CalEvent]: ...
    def get(self, uid: str) -> CalEvent | None: ...
    def create(self, calendar: str, title: str, start: date | datetime, end: date | datetime,
               location: str = "", notes: str = "") -> CalEvent: ...
    def move(self, uid: str, start: date | datetime, end: date | datetime) -> CalEvent: ...
    def delete(self, uid: str) -> None: ...


def _event_from_component(comp, calendar: str) -> CalEvent:
    start = comp.decoded("DTSTART")
    if "DTEND" in comp:
        end = comp.decoded("DTEND")
    elif "DURATION" in comp:
        end = start + comp.decoded("DURATION")
    else:
        end = start
    return CalEvent(
        uid=str(comp.get("UID")),
        calendar=calendar,
        title=str(comp.get("SUMMARY", "(no title)")),
        start=start,
        end=end,
        location=str(comp.get("LOCATION", "")),
        notes=str(comp.get("DESCRIPTION", "")),
        recurring="RRULE" in comp or "RECURRENCE-ID" in comp,
    )


class ICloudCalendar:
    def __init__(self, email: str, app_password: str):
        self.client = caldav.DAVClient(url=ICLOUD_URL, username=email, password=app_password, features="icloud")
        # niquests tries HTTP/3 (QUIC over UDP) with iCloud, and receiving fails on this host with
        # "OSError: [Errno 90] Message too long". Plain HTTPS over TCP works everywhere.
        self.client.session = niquests.Session(multiplexed=self.client.session.multiplexed, disable_http3=True)
        self._calendars: dict[str, caldav.Calendar] | None = None
        # The first request logs in: iCloud answers 401 and caldav retries with the password. Two threads doing that
        # at once fail the second one (the password is set by then, so it doesn't retry), as at every startup.
        self._first = threading.Lock()
        # uid -> (calendar name, URL), remembered from listings. iCloud rejects lookups by UID
        # (412 on the REPORT that event_by_uid sends), so events are fetched by URL instead.
        self._where: dict[str, tuple[str, str]] = {}

    def _cals(self) -> dict[str, caldav.Calendar]:
        # Cached for the process lifetime; restart Aide after adding a calendar.
        with self._first:
            if self._calendars is None:
                self._calendars = self._discover()
        return self._calendars

    def _discover(self) -> dict[str, caldav.Calendar]:
        def describe(cal):
            # Reminders lists are calendars too; keep only those that hold events.
            return cal.get_display_name(), "VEVENT" in cal.get_supported_components()

        cals = self.client.principal().calendars()
        with ThreadPoolExecutor(max_workers=8) as pool:
            info = list(pool.map(describe, cals))
        found = {name: cal for (name, events), cal in zip(info, cals) if events}
        log.info("iCloud calendars: %s", ", ".join(found))
        return found

    def calendars(self) -> list[str]:
        return list(self._cals())

    def events(self, start: datetime, end: datetime) -> list[CalEvent]:
        def one(name: str, cal: caldav.Calendar) -> list[CalEvent]:
            found = cal.search(event=True, start=start, end=end, expand=True)
            events = [_event_from_component(obj.icalendar_component, name) for obj in found]
            for ev, obj in zip(events, found):
                self._where[ev.uid] = (name, str(obj.url))
            return events

        # One request per calendar; in parallel, since iCloud users often have a dozen.
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = pool.map(lambda item: one(*item), self._cals().items())
            return [ev for evs in results for ev in evs]

    def _fetch(self, name: str, url) -> caldav.Event | None:
        try:
            obj = self._cals()[name].event_by_url(url)
            obj.load()
            return obj
        except caldav.error.DAVError:  # 404 and friends
            return None

    def _find(self, uid: str) -> tuple[str, caldav.Event] | None:
        def matches(obj) -> bool:
            return obj is not None and str(obj.icalendar_component.get("UID")) == uid

        if uid in self._where:  # 1. where a recent listing saw it
            name, url = self._where[uid]
            if matches(obj := self._fetch(name, url)):
                return name, obj
        cals = self._cals()
        with ThreadPoolExecutor(max_workers=8) as pool:
            # 2. <uid>.ics, where Aide and most Apple clients store events
            guesses = pool.map(lambda n: (n, self._fetch(n, cals[n].url.join(quote(uid) + ".ics"))), cals)
            for name, obj in guesses:
                if matches(obj):
                    return name, obj
            # 3. scan a wide window (no expansion, so recurring masters come back whole)
            now = datetime.now(timezone.utc)
            def scan(name):
                found = cals[name].search(event=True, start=now - timedelta(days=365), end=now + timedelta(days=730))
                return [(name, o) for o in found if matches(o)]
            for hits in pool.map(scan, cals):
                if hits:
                    return hits[0]
        return None

    def get(self, uid: str) -> CalEvent | None:
        found = self._find(uid)
        return _event_from_component(found[1].icalendar_component, found[0]) if found else None

    def create(self, calendar, title, start, end, location="", notes="") -> CalEvent:
        cals = self._cals()
        if calendar not in cals:
            raise KeyError(f"no calendar named {calendar!r}; available: {', '.join(cals)}")
        ev = icalendar.Event()
        ev.add("uid", f"{uuid.uuid4()}@aide")
        ev.add("dtstamp", datetime.now(timezone.utc))
        ev.add("summary", title)
        ev.add("dtstart", start)
        ev.add("dtend", end)
        if location:
            ev.add("location", location)
        if notes:
            ev.add("description", notes)
        cal = icalendar.Calendar()
        cal.add("prodid", "-//Aide//EN")
        cal.add("version", "2.0")
        cal.add_component(ev)
        cal.add_missing_timezones()
        obj = cals[calendar].add_event(cal.to_ical().decode())
        created = _event_from_component(ev, calendar)
        self._where[created.uid] = (calendar, str(obj.url))
        return created

    def move(self, uid, start, end) -> CalEvent:
        found = self._find(uid)
        if not found:
            raise KeyError(f"no event with id {uid}")
        name, obj = found
        if _event_from_component(obj.icalendar_component, name).recurring:
            raise RecurringEventError("recurring events can't be changed by Aide yet")
        with obj.edit_icalendar_component() as comp:
            for key in ("DTSTART", "DTEND", "DURATION"):
                comp.pop(key, None)
            comp.add("dtstart", start)
            comp.add("dtend", end)
            comp["SEQUENCE"] = int(comp.get("SEQUENCE", 0)) + 1
        with obj.edit_icalendar_instance() as cal:
            cal.add_missing_timezones()
        obj.save()
        return _event_from_component(obj.icalendar_component, name)

    def delete(self, uid) -> None:
        found = self._find(uid)
        if not found:
            raise KeyError(f"no event with id {uid}")
        name, obj = found
        if _event_from_component(obj.icalendar_component, name).recurring:
            raise RecurringEventError("recurring events can't be deleted by Aide yet")
        obj.delete()
