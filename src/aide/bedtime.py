"""Bedtime from a steady wake time (docs/API.md, "Apple Health", "Bedtime"; #53).

Waking at about the same time every day counts as much as the hours (the sleep score's consistency part), so the
wake time is the anchor and the bedtime is what moves. The wake time is the user's own: the median of their last 4
weeks' wakes, weekdays and weekends apart, or one they set. An early start tomorrow (the first timed event before
noon: leaving for it, from the wake briefing's travel plan, less the time to get ready) moves it earlier only when
it has to; a late one never moves it later.

The bedtime is the wake time less the night's sleep need (scores.sleep_need: learnt from the nights, plus the day's
strain and recent shortfall), the usual time awake during the night and a quarter of an hour to fall asleep.

In the evening, LEAD before it: a `bedtime` push ("In bed by 23:40 to get 8h10 before tomorrow's 9:00 lecture") as
the start of a countdown Live Activity when the phone gave a token, and, if wind-down is on, a one-off Screen Time
lock from the bedtime to the wake time (lockwatch then counts that down). The plan for the night is kept, so the
wake briefing can say how close they got and Coach can see a drift over the week.
"""

import asyncio
import json
import logging
import re
import sqlite3
from datetime import date, datetime, time, timedelta, timezone
from statistics import median
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from . import scores
from .db import utcnow
from .scores import hm

log = logging.getLogger(__name__)

TICK = 60  # seconds between checks
REPLAN = timedelta(minutes=30)  # tonight's plan is worked out again this often, until the nudge
WAKE_NIGHTS, MIN_WAKE_NIGHTS = 28, 5  # nights the usual wake is the median of
WAKE_DEFAULT = "07:30"  # before there are enough nights
AWAKE_NIGHTS, AWAKE_DEFAULT, AWAKE_MAX = 30, 20, 60  # min awake during the night: the usual, before it's known, cap
FALL_ASLEEP = 15  # min from getting into bed to sleep (the Watch's bedtime is when sleep starts)
MORNING = time(12)  # events starting before this can move the wake time
MOST_EARLIER = timedelta(hours=3)  # an early start moves the wake by at most this (a 5:00 flight: say it, don't plan it)
LATE_NUDGE = timedelta(minutes=30)  # a nudge missed by more than this (the server was off) isn't sent
SHOWN = timedelta(minutes=15)  # the countdown stays up this long after the bedtime
DEFAULTS = {"enabled": True, "wake_weekdays": None, "wake_weekends": None, "ready_min": 45, "lead_min": 45,
            "wind_down": False}
TIME = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")

SCHEMA = """
CREATE TABLE IF NOT EXISTS bedtime_nights (
    day       TEXT PRIMARY KEY,  -- the morning the night ends on, local
    plan      TEXT NOT NULL,     -- the plan, JSON (as on GET /v1/health/bedtime)
    planned   TEXT NOT NULL,     -- when it was worked out, UTC
    nudged    TEXT,              -- when the push went out (or was skipped), UTC
    live      TEXT,              -- the countdown's key, while it's up
    lock      INTEGER            -- the wind-down lock it made
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def check_settings(changes: dict, current: dict) -> dict:
    out = dict(current)
    for key, value in changes.items():
        if key not in DEFAULTS:
            raise ValueError(f"unknown bedtime setting {key!r}")
        if key in ("enabled", "wind_down"):
            if not isinstance(value, bool):
                raise ValueError(f"{key} is true or false")
        elif key in ("wake_weekdays", "wake_weekends"):
            if value is not None and not (isinstance(value, str) and TIME.match(value)):
                raise ValueError(f"{key} is HH:MM, or null to learn it from your nights")
        elif key == "ready_min":
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 180:
                raise ValueError("ready_min is 0–180")
        elif key == "lead_min":
            if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 180:
                raise ValueError("lead_min is 0–180")
        out[key] = value
    return out


def weekend(day: date) -> bool:
    """The morning is a Saturday or a Sunday."""
    return day.weekday() >= 5


def _round_down(dt: datetime) -> datetime:
    return dt - timedelta(minutes=dt.minute % 5, seconds=dt.second, microseconds=dt.microsecond)


def _clock(dt: datetime) -> str:
    return f"{dt.hour}:{dt.minute:02d}"


def _local(value: str | None, tz: ZoneInfo) -> datetime | None:
    try:
        return datetime.fromisoformat(value).astimezone(tz) if value else None
    except (TypeError, ValueError):
        return None


def usual_wake(days: dict[str, dict], day: date, tz: ZoneInfo) -> str | None:
    """'07:25': the median wake of the last 4 weeks' mornings of the same kind (weekdays, weekends), else of all of
    them, to 5 minutes; None with fewer than 5."""
    wakes: dict[bool, list[int]] = {True: [], False: []}
    for i in range(1, WAKE_NIGHTS + 1):
        d = day - timedelta(days=i)
        at = _local(((days.get(d.isoformat()) or {}).get("sleep") or {}).get("wake"), tz)
        if at and at.hour < 14:  # a night shift's wake isn't the usual
            wakes[weekend(d)].append(at.hour * 60 + at.minute)
    same = wakes[weekend(day)]
    pool = same if len(same) >= MIN_WAKE_NIGHTS else same + wakes[not weekend(day)]
    if len(pool) < MIN_WAKE_NIGHTS:
        return None
    m = 5 * round(median(pool) / 5)
    return f"{m // 60:02d}:{m % 60:02d}"


def usual_awake(days: dict[str, dict], day: date) -> int:
    """Minutes awake during the night, usually (the median of the last 30 nights)."""
    found = [(d.get("sleep") or {}).get("awake_min") for d in scores._before(days, day, AWAKE_NIGHTS)]
    found = [a for a in found if isinstance(a, (int, float))]
    return round(min(AWAKE_MAX, median(found))) if len(found) >= MIN_WAKE_NIGHTS else AWAKE_DEFAULT


class Bedtime:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, health, push=None, live=None, locks=None,
                 events: Callable[[datetime, datetime], Awaitable[list[dict] | None]] | None = None,
                 leave_at: Callable[[dict], Awaitable[tuple[datetime, str] | None]] | None = None):
        """`events(start, end)`: the calendar's events as event_json, or None when it can't be read.
        `leave_at(event)`: when to leave for it and how ("tram, 25 min"), or None (digest.DigestService.leave_at)."""
        self.conn, self.tz, self.health, self.push, self.live, self.locks = conn, tz, health, push, live, locks
        self.events, self.leave_at = events, leave_at
        self.conn.executescript(SCHEMA)
        self._leaves: dict[tuple[str, str], tuple[datetime, str] | None] = {}  # (event id, start) -> leave_at

    # -- settings ------------------------------------------------------------------------------------------

    def settings(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'bedtime'").fetchone()
        return {**DEFAULTS, **(json.loads(row["value"]) if row else {})}

    def update_settings(self, **changes) -> dict:
        value = check_settings(changes, self.settings())
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('bedtime', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(value),))
        # Tonight's plan follows at once (unless the nudge is out: then it stands).
        self.conn.execute("UPDATE bedtime_nights SET planned = ? WHERE nudged IS NULL", (datetime.min.isoformat(),))
        return self.settings()

    def _days(self, day: date) -> dict[str, dict]:
        return self.health._window(day, day)

    def usual(self, now: datetime | None = None) -> dict:
        """The learnt wake times, weekdays and weekends ('07:25', or None while there are too few nights)."""
        today = (now or utcnow()).astimezone(self.tz).date()
        days = self._days(today)
        monday, saturday = (today + timedelta(days=(n - today.weekday()) % 7 or 7) for n in (0, 5))
        return {"weekdays": usual_wake(days, monday, self.tz), "weekends": usual_wake(days, saturday, self.tz)}

    # -- the plan -----------------------------------------------------------------------------------------

    @staticmethod
    def morning(now_local: datetime) -> date:
        """The morning tonight's plan is for: tomorrow from noon, today until then (still up at 1:00)."""
        return (now_local + timedelta(hours=12)).date()

    def anchor(self, day: date, days: dict[str, dict] | None = None) -> tuple[str, str]:
        """The usual wake for `day` and where it comes from: set, learnt or default."""
        s = self.settings()
        mine = s["wake_weekends" if weekend(day) else "wake_weekdays"]
        if mine:
            return mine, "set"
        learnt = usual_wake(days if days is not None else self._days(day), day, self.tz)
        return (learnt, "learnt") if learnt else (WAKE_DEFAULT, "default")

    async def _first(self, day: date) -> dict | None:
        """The first timed event that morning, before noon."""
        if self.events is None:
            return None
        start = datetime.combine(day, time.min, self.tz)
        found = await self.events(start, datetime.combine(day, MORNING, self.tz))
        timed = [e for e in found or [] if not e["all_day"] and datetime.fromisoformat(e["start"]) >= start]
        return min(timed, key=lambda e: e["start"], default=None)

    async def _leave(self, event: dict) -> tuple[datetime, str] | None:
        if self.leave_at is None:
            return None
        key = (event["id"], event["start"])
        if key not in self._leaves:
            try:
                self._leaves[key] = await self.leave_at(event)
            except Exception:
                log.warning("bedtime: no leave-by time for %r", event["title"], exc_info=True)
                return None  # not kept: tried again at the next plan
        return self._leaves[key]

    async def plan(self, day: date, now: datetime | None = None) -> dict:
        """The plan for the night ending on the morning of `day`."""
        s = self.settings()
        days = self._days(day)
        usual, source = self.anchor(day, days)
        wake = datetime.combine(day, time.fromisoformat(usual), self.tz)
        event, earlier, by = None, 0, None
        if first := await self._first(day):
            start = datetime.fromisoformat(first["start"]).astimezone(self.tz)
            leave = await self._leave(first)
            leave_at, how = leave if leave else (start, None)
            by = _round_down(leave_at.astimezone(self.tz) - timedelta(minutes=s["ready_min"]))
            event = {"title": first["title"], "start": start.isoformat(),
                     "leave": leave_at.astimezone(self.tz).isoformat() if leave else None, "how": how}
            if by < wake:
                by = max(by, wake - MOST_EARLIER)
                earlier = round((wake - by).total_seconds() / 60)
                wake = by
        need = scores.sleep_need(days, day, self.health.age())
        awake = usual_awake(days, day)
        bedtime = _round_down(wake - timedelta(minutes=need["need"] + awake + FALL_ASLEEP))
        nudge = bedtime - timedelta(minutes=s["lead_min"])
        plan = {
            "date": day.isoformat(),
            "bedtime": bedtime.isoformat(),
            "asleep_by": (bedtime + timedelta(minutes=FALL_ASLEEP)).isoformat(),
            "wake": wake.isoformat(),
            "usual_wake": usual,
            "wake_source": source,
            "earlier_min": earlier,
            "event": event,
            "need_min": need["need"],
            "need": need,
            "awake_min": awake,
            "nudge_at": nudge.isoformat(),
            "wind_down": s["wind_down"],
        }
        plan["why"] = self.why(plan)
        return plan

    def why(self, plan: dict) -> str:
        """'In bed by 23:40 to get 8h10 asleep before tomorrow's 9:00 Lecture: up at 7:20, 40 min earlier than
        usual.'"""
        bed, wake = _local(plan["bedtime"], self.tz), _local(plan["wake"], self.tz)
        text = f"In bed by {_clock(bed)} to get {hm(plan['need_min'])} asleep"
        e = plan["event"]
        if e:
            start = _local(e["start"], self.tz)
            text += f" before {_clock(start)} {e['title']}"
        if earlier := plan["earlier_min"]:
            text += f": up at {_clock(wake)}, {hm(earlier) if earlier >= 60 else f'{earlier} min'} earlier than usual"
        else:
            text += f", up at {_clock(wake)}" + (" as usual" if plan["wake_source"] != "default" else "")
        return text + "."

    # -- stored nights ----------------------------------------------------------------------------------

    def _row(self, day: date) -> dict | None:
        row = self.conn.execute("SELECT * FROM bedtime_nights WHERE day = ?", (day.isoformat(),)).fetchone()
        return dict(row) if row else None

    def stored(self, day: date) -> dict | None:
        row = self._row(day)
        return json.loads(row["plan"]) if row else None

    async def tonight(self, now: datetime | None = None) -> dict | None:
        """Tonight's plan (worked out now if there's none yet); None when bedtime is off."""
        if not self.settings()["enabled"]:
            return None
        now = now or utcnow()
        day = self.morning(now.astimezone(self.tz))
        row = self._row(day)
        if row and (row["nudged"] or now - datetime.fromisoformat(row["planned"]).replace(tzinfo=timezone.utc)
                    < REPLAN):
            return json.loads(row["plan"])
        return await self._replan(day, now, row)

    async def _replan(self, day: date, now: datetime, row: dict | None) -> dict:
        plan = await self.plan(day, now)
        if row:
            self.conn.execute("UPDATE bedtime_nights SET plan = ?, planned = ? WHERE day = ?",
                              (json.dumps(plan), now.isoformat(), day.isoformat()))
        else:
            self.conn.execute("INSERT INTO bedtime_nights (day, plan, planned) VALUES (?, ?, ?)",
                              (day.isoformat(), json.dumps(plan), now.isoformat()))
        return plan

    def review(self, day: date) -> dict | None:
        """How the night ending on `day` went against its plan: None without a plan or a night."""
        row = self._row(day)
        plan = json.loads(row["plan"]) if row else None
        sleep = (self.health.get(day) or {}).get("sleep") or {}
        if not plan or not sleep.get("bedtime") or not sleep.get("wake"):
            return None
        planned = datetime.fromisoformat(row["planned"])
        if planned.tzinfo and planned >= datetime.fromisoformat(plan["bedtime"]):
            return None  # worked out after the bedtime (the server was off): never shown, so not a plan to judge by
        asleep, up = _local(sleep["bedtime"], self.tz), _local(sleep["wake"], self.tz)
        planned_asleep, planned_up = _local(plan["asleep_by"], self.tz), _local(plan["wake"], self.tz)
        bed_off = round((asleep - planned_asleep).total_seconds() / 60)
        wake_off = round((up - planned_up).total_seconds() / 60)
        return {"date": day.isoformat(), "planned_bedtime": plan["bedtime"], "planned_asleep": plan["asleep_by"],
                "planned_wake": plan["wake"], "asleep": asleep.isoformat(), "wake": up.isoformat(),
                "asleep_off_min": bed_off, "wake_off_min": wake_off, "need_min": plan["need_min"],
                "asleep_min": sleep.get("asleep_min")}

    def nights(self, until: date, n: int = 7) -> list[dict]:
        """The last n nights' reviews up to the morning of `until`, newest first (nights without a plan left out)."""
        return [r for i in range(n) if (r := self.review(until - timedelta(days=i)))]

    @staticmethod
    def _off(minutes: int, late: str, early: str) -> str:
        if abs(minutes) < 15:
            return "on time"
        span = hm(abs(minutes)) if abs(minutes) >= 60 else f"{abs(minutes)} min"
        return f"{span} {late if minutes > 0 else early}"

    def review_line(self, day: date) -> str | None:
        """For the wake briefing: 'Last night's plan: asleep by 23:55, up at 7:30. They fell asleep at 0:20 (25 min
        late) and got up at 7:32 (on time).'"""
        r = self.review(day)
        if not r:
            return None
        tz = self.tz
        return (f"Last night's bedtime plan: asleep by {_clock(_local(r['planned_asleep'], tz))}, up at "
                f"{_clock(_local(r['planned_wake'], tz))}. They fell asleep at {_clock(_local(r['asleep'], tz))} "
                f"({self._off(r['asleep_off_min'], 'late', 'early')}) and got up at {_clock(_local(r['wake'], tz))} "
                f"({self._off(r['wake_off_min'], 'late', 'early')}). Say how close they got in a few words, kindly; "
                "only if they were well off.")

    def week_text(self, now: datetime | None = None) -> str:
        """For Coach: tonight's plan and the last week's nights against theirs."""
        now = now or utcnow()
        local = now.astimezone(self.tz)
        s = self.settings()
        lines = [f"Bedtime plan: {'on' if s['enabled'] else 'off'}; wake on weekdays "
                 f"{s['wake_weekdays'] or 'learnt'}, weekends {s['wake_weekends'] or 'learnt'} (learnt: "
                 f"{self.usual(now)['weekdays'] or 'not yet'} and {self.usual(now)['weekends'] or 'not yet'}); "
                 f"{s['ready_min']} min to get ready; nudge {s['lead_min']} min before; wind-down lock "
                 f"{'on' if s['wind_down'] else 'off'}."]
        plan = self.stored(self.morning(local))
        if plan and now < datetime.fromisoformat(plan["wake"]):  # not this morning's, once it's over
            lines.append("Tonight: " + plan["why"])
        reviews = self.nights(local.date() if local.time() >= time(4) else local.date() - timedelta(days=1))
        if reviews:
            lines.append("Last nights against the plan (asleep vs asleep-by, up vs planned wake):")
            for r in reviews:
                d = date.fromisoformat(r["date"])
                lines.append(f"- {d:%a %d %b}: asleep {_clock(_local(r['asleep'], self.tz))} "
                             f"({self._off(r['asleep_off_min'], 'late', 'early')}), up "
                             f"{_clock(_local(r['wake'], self.tz))} ({self._off(r['wake_off_min'], 'late', 'early')})")
        else:
            lines.append("No nights with a plan yet.")
        return "\n".join(lines)

    def section(self, plan: dict | None) -> dict | None:
        """The evening digest's card."""
        return {"type": "bedtime", "title": "Tonight", "bedtime": plan} if plan else None

    # -- the evening ------------------------------------------------------------------------------------

    async def run(self) -> None:
        while True:
            await asyncio.sleep(TICK)
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("bedtime tick failed")

    async def tick(self, now: datetime) -> None:
        if not self.settings()["enabled"]:
            return
        plan = await self.tonight(now)
        if plan is None:
            return
        row = self._row(date.fromisoformat(plan["date"]))
        nudge, bedtime = datetime.fromisoformat(plan["nudge_at"]), datetime.fromisoformat(plan["bedtime"])
        if row["live"] and now >= bedtime:
            await self._end_live(row, plan)
        if row["nudged"] or now < nudge:
            return
        self.conn.execute("UPDATE bedtime_nights SET nudged = ? WHERE day = ?", (now.isoformat(), plan["date"]))
        if now - nudge > LATE_NUDGE:
            log.info("bedtime: the nudge for %s was missed (%s late), not sent", plan["date"], now - nudge)
            return
        await self._nudge(plan, now)
        if plan["wind_down"]:
            self._lock(plan, now)

    def _texts(self, plan: dict) -> tuple[str, str]:
        bed = _local(plan["bedtime"], self.tz)
        return f"Bedtime at {_clock(bed)}", plan["why"]

    async def _nudge(self, plan: dict, now: datetime) -> None:
        title, body = self._texts(plan)
        bed, wake = datetime.fromisoformat(plan["bedtime"]), datetime.fromisoformat(plan["wake"])
        started = False
        if self.live and self.live.enabled and self.live.settings().get("bedtime", True):
            key = f"bedtime:{plan['date']}"
            state = {"bedtime": int(bed.timestamp()), "wake": int(wake.timestamp()), "since": int(now.timestamp()),
                     "need_min": plan["need_min"], "over": False}
            started = await self.live.start("bedtime", {"key": key, "title": "Bedtime"}, state,
                                            {"title": title, "body": body}, stale=bed + SHOWN)
            if started:
                self.conn.execute("UPDATE bedtime_nights SET live = ? WHERE day = ?", (key, plan["date"]))
        if not started and self.push and getattr(self.push, "enabled", False):
            await self.push.send_bedtime(title, body, plan["date"])
        log.info("bedtime: nudged for %s (%s)", plan["date"], "countdown" if started else "push")

    async def _end_live(self, row: dict, plan: dict) -> None:
        bed, wake = datetime.fromisoformat(plan["bedtime"]), datetime.fromisoformat(plan["wake"])
        state = {"bedtime": int(bed.timestamp()), "wake": int(wake.timestamp()),
                 "since": int(datetime.fromisoformat(plan["nudge_at"]).timestamp()), "need_min": plan["need_min"],
                 "over": True}
        await self.live.end(row["live"], state, bed + SHOWN)
        self.conn.execute("UPDATE bedtime_nights SET live = NULL WHERE day = ?", (row["day"],))

    def _lock(self, plan: dict, now: datetime) -> None:
        """The wind-down lock, from the bedtime to the wake time, unless a lock already holds then."""
        if self.locks is None:
            return
        bed, wake = datetime.fromisoformat(plan["bedtime"]), datetime.fromisoformat(plan["wake"])
        held = any(self.locks.locked_until(lock, bed + timedelta(minutes=1)) for lock in self.locks.all(now))
        if held:
            log.info("bedtime: a lock already holds at %s, no wind-down lock", bed)
            return
        try:
            lock = self.locks.lock_for("Bedtime", start=bed, until=wake, agent="coach", now=now)
        except ValueError as e:
            log.warning("bedtime: no wind-down lock (%s)", e)
            return
        self.conn.execute("UPDATE bedtime_nights SET lock = ? WHERE day = ?", (lock["id"], plan["date"]))


def bedtime_tools(bedtime: Bedtime):
    """Coach's: read the plan and the week against it, and change the settings."""
    from .tools import Tool

    async def sleep_plan() -> str:
        await bedtime.tonight()
        return bedtime.week_text()

    async def set_sleep_plan(**changes) -> str:
        clean = {}
        for key, value in changes.items():
            if value is None:  # left as it is
                continue
            if key.startswith("wake_") and value.strip().lower() in ("", "learn", "learnt", "auto"):
                value = None  # back to the learnt one
            clean[key] = value
        bedtime.update_settings(**clean)
        await bedtime.tonight()
        return "Saved.\n" + bedtime.week_text()

    return [
        Tool(
            name="sleep_plan",
            description="The bedtime plan: tonight's bedtime and wake time (worked out back from a steady wake time "
                        "and the night's sleep need), the settings, and the last week's nights against their plans. "
                        "Read it before talking about bedtime, and to notice a drift.",
            input_schema={"type": "object", "properties": {}, "required": [], "additionalProperties": False},
            handler=sleep_plan,
            step=lambda a: "Reading the sleep plan",
        ),
        Tool(
            name="set_sleep_plan",
            description="Change the bedtime plan's settings. Wake times are HH:MM, or \"learn\" to go back to the "
                        "one learnt from their nights. Leave out what doesn't change.",
            input_schema={"type": "object", "properties": {
                "enabled": {"type": ["boolean", "null"], "description": "The plan and its evening nudge, on or off."},
                "wake_weekdays": {"type": ["string", "null"], "description": "HH:MM, or \"learn\"."},
                "wake_weekends": {"type": ["string", "null"], "description": "HH:MM, or \"learn\"."},
                "ready_min": {"type": ["integer", "null"], "description": "Minutes from getting up to leaving."},
                "lead_min": {"type": ["integer", "null"], "description": "Minutes before bedtime for the nudge."},
                "wind_down": {"type": ["boolean", "null"],
                              "description": "A Screen Time lock from bedtime to the wake time, every night."},
            }, "required": ["enabled", "wake_weekdays", "wake_weekends", "ready_min", "lead_min", "wind_down"],
                "additionalProperties": False},
            handler=set_sleep_plan,
            step=lambda a: "Changing the sleep plan",
        ),
    ]
