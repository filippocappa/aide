"""iCloud Calendar over CalDAV. Synchronous: tools call it through asyncio.to_thread."""

import logging
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, datetime, timezone
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

    def _cals(self) -> dict[str, caldav.Calendar]:
        # Cached for the process lifetime; restart Aide after adding a calendar.
        if self._calendars is None:
            found = {}
            for cal in self.client.principal().calendars():
                if "VEVENT" in cal.get_supported_components():  # skip Reminders lists
                    found[cal.get_display_name()] = cal
            self._calendars = found
            log.info("iCloud calendars: %s", ", ".join(found))
        return self._calendars

    def calendars(self) -> list[str]:
        return list(self._cals())

    def events(self, start: datetime, end: datetime) -> list[CalEvent]:
        def one(name: str, cal: caldav.Calendar) -> list[CalEvent]:
            found = cal.search(event=True, start=start, end=end, expand=True)
            return [_event_from_component(obj.icalendar_component, name) for obj in found]

        # One request per calendar; in parallel, since iCloud users often have a dozen.
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = pool.map(lambda item: one(*item), self._cals().items())
            return [ev for evs in results for ev in evs]

    def _find(self, uid: str) -> tuple[str, caldav.Event] | None:
        for name, cal in self._cals().items():
            try:
                return name, cal.event_by_uid(uid)
            except caldav.error.NotFoundError:
                continue
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
        cals[calendar].add_event(cal.to_ical().decode())
        return _event_from_component(ev, calendar)

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
