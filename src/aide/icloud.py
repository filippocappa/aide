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
from caldav.elements.ical import CalendarColor
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
    color: str = ""  # the calendar's colour as #RRGGBB, when iCloud gives one

    @property
    def all_day(self) -> bool:
        return not isinstance(self.start, datetime)


class RecurringEventError(Exception):
    pass


class Events(list):
    """A listing of events, with the calendars that couldn't be read this time (`unread`). A caller that tells
    "not in the calendar" from what's missing should check it: those calendars' events aren't absent, just unknown."""

    def __init__(self, events=(), unread=()):
        super().__init__(events)
        self.unread = frozenset(unread)


def unread(found) -> frozenset[str]:
    """The calendars a listing couldn't read (none for backends that don't say)."""
    return getattr(found, "unread", frozenset())


class CalendarBackend(Protocol):
    def calendars(self) -> list[str]: ...
    def events(self, start: datetime, end: datetime) -> list[CalEvent]: ...
    def get(self, uid: str) -> CalEvent | None: ...
    def create(self, calendar: str, title: str, start: date | datetime, end: date | datetime,
               location: str = "", notes: str = "") -> CalEvent: ...
    def update(self, uid: str, *, start: date | datetime | None = None, end: date | datetime | None = None,
               calendar: str | None = None, title: str | None = None, location: str | None = None,
               notes: str | None = None) -> CalEvent: ...
    def delete(self, uid: str) -> None: ...


def _event_from_component(comp, calendar: str, color: str = "") -> CalEvent:
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
        color=color,
    )


def _hex(color) -> str:
    """iCloud's calendar-color (#RRGGBBAA) as #RRGGBB; "" when it isn't one."""
    s = str(color or "").strip()
    return s[:7].upper() if len(s) in (7, 9) and s.startswith("#") else ""


class ICloudCalendar:
    def __init__(self, email: str, app_password: str):
        self.client = caldav.DAVClient(url=ICLOUD_URL, username=email, password=app_password, features="icloud")
        # niquests tries HTTP/3 (QUIC over UDP) with iCloud, and receiving fails on this host with
        # "OSError: [Errno 90] Message too long". Plain HTTPS over TCP works everywhere.
        self.client.session = niquests.Session(multiplexed=self.client.session.multiplexed, disable_http3=True)
        self._calendars: dict[str, caldav.Calendar] | None = None
        self._colors: dict[str, str] = {}
        # The first request logs in: iCloud answers 401 and caldav retries with the password. Two threads doing that
        # at once fail the second one (the password is set by then, so it doesn't retry), as at every startup.
        self._first = threading.Lock()
        # uid -> (calendar name, URL), remembered from listings. iCloud rejects lookups by UID
        # (412 on the REPORT that event_by_uid sends), so events are fetched by URL instead.
        self._where: dict[str, tuple[str, str]] = {}
        self._failing: set[str] = set()  # calendars whose last read failed, logged once until they work again

    def _cals(self) -> dict[str, caldav.Calendar]:
        # Cached for the process lifetime; restart Aide after adding a calendar.
        with self._first:
            if self._calendars is None:
                self._calendars = self._discover()
        return self._calendars

    def _discover(self) -> dict[str, caldav.Calendar]:
        def describe(cal):
            # Reminders lists are calendars too; keep only those that hold events.
            try:
                color = _hex(cal.get_property(CalendarColor()))
            except Exception:  # the colour is only for the app's cards
                color = ""
            return cal.get_display_name(), "VEVENT" in cal.get_supported_components(), color

        cals = self.client.principal().calendars()
        with ThreadPoolExecutor(max_workers=8) as pool:
            info = list(pool.map(describe, cals))
        found = {name: cal for (name, events, _), cal in zip(info, cals) if events}
        self._colors = {name: color for name, events, color in info if events and color}
        log.info("iCloud calendars: %s", ", ".join(found))
        return found

    def calendars(self) -> list[str]:
        return list(self._cals())

    def color(self, calendar: str) -> str:
        self._cals()
        return self._colors.get(calendar, "")

    def _ev(self, comp, calendar: str) -> CalEvent:
        return _event_from_component(comp, calendar, self._colors.get(calendar, ""))

    def events(self, start: datetime, end: datetime) -> Events:
        """Every calendar's events in the window. One calendar iCloud won't answer for (gone, moved: a 404) doesn't
        fail the rest: it's left out and named in `unread`, and the calendar list is found again next time. Raises
        only when no calendar could be read."""
        def one(name: str, cal: caldav.Calendar) -> list[CalEvent] | caldav.error.DAVError:
            try:
                found = cal.search(event=True, start=start, end=end, expand=True)
            except caldav.error.DAVError as e:
                return e
            events = [self._ev(obj.icalendar_component, name) for obj in found]
            for ev, obj in zip(events, found):
                self._where[ev.uid] = (name, str(obj.url))
            return events

        cals = self._cals()
        # One request per calendar; in parallel, since iCloud users often have a dozen.
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = dict(zip(cals, pool.map(lambda item: one(*item), cals.items())))
        failed = {name: r for name, r in results.items() if isinstance(r, caldav.error.DAVError)}
        for name, err in failed.items():
            if name not in self._failing:
                log.warning("calendar %r couldn't be read (%s: %s); the others' events still come back",
                            name, type(err).__name__, err)
        self._failing = set(failed)
        if any(isinstance(e, caldav.error.NotFoundError) for e in failed.values()):
            with self._first:
                if self._calendars is cals:
                    self._calendars = None  # gone or moved in iCloud: discover them again on the next read
        if failed and len(failed) == len(results):
            raise next(iter(failed.values()))
        return Events((ev for r in results.values() if not isinstance(r, caldav.error.DAVError) for ev in r),
                      unread=failed)

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
        return self._ev(found[1].icalendar_component, found[0]) if found else None

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
        created = self._ev(ev, calendar)
        self._where[created.uid] = (calendar, str(obj.url))
        return created

    def update(self, uid, *, start=None, end=None, calendar=None, title=None, location=None, notes=None) -> CalEvent:
        """Change what's given and leave the rest. A new calendar moves the event there, keeping its UID."""
        found = self._find(uid)
        if not found:
            raise KeyError(f"no event with id {uid}")
        name, obj = found
        if self._ev(obj.icalendar_component, name).recurring:
            raise RecurringEventError("recurring events can't be changed by Aide yet")
        cals = self._cals()
        if calendar is not None and calendar not in cals:
            raise KeyError(f"no calendar named {calendar!r}; available: {', '.join(cals)}")
        original = obj.icalendar_instance.to_ical().decode()
        with obj.edit_icalendar_component() as comp:
            if start is not None:
                for key in ("DTSTART", "DTEND", "DURATION"):
                    comp.pop(key, None)
                comp.add("dtstart", start)
                comp.add("dtend", end)
            for key, value in (("SUMMARY", title), ("LOCATION", location), ("DESCRIPTION", notes)):
                if value is not None:
                    comp.pop(key, None)
                    if value:
                        comp.add(key.lower(), value)
            comp["SEQUENCE"] = int(comp.get("SEQUENCE", 0)) + 1
        with obj.edit_icalendar_instance() as cal:
            cal.add_missing_timezones()
        if calendar is None or calendar == name:
            obj.save()
            return self._ev(obj.icalendar_component, name)
        # CalDAV has no "change calendar": the event is written into the new one under the same UID. The old copy
        # goes first, so the UID is never in two calendars at once, and comes back if the new one can't be written.
        data = obj.icalendar_instance.to_ical().decode()
        obj.delete()
        try:
            new = cals[calendar].add_event(data)
        except Exception:
            cals[name].add_event(original)
            raise
        self._where[uid] = (calendar, str(new.url))
        return self._ev(obj.icalendar_component, calendar)

    def delete(self, uid) -> None:
        found = self._find(uid)
        if not found:
            raise KeyError(f"no event with id {uid}")
        name, obj = found
        if self._ev(obj.icalendar_component, name).recurring:
            raise RecurringEventError("recurring events can't be deleted by Aide yet")
        obj.delete()
