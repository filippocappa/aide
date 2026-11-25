"""Tomorrow's plan, made the evening before (#84; docs/API.md, "Exam plan", "Tomorrow's plan").

At `day_plan_at` (21:00) Secretary writes in its "Tomorrow" chat, with a push: tomorrow's timed events, the reminders
due, and the study the exam plan wants that day, and asks what else the user has to do. Their answer is a Secretary
turn, which calls `plan_tomorrow` with those things: they're placed first (at their time, or in the free time of the
part of the day they said), the exam plan's study blocks go around them (`ExamPlan.week` for one day), and the whole
day is proposed as one events card (plans.py): nothing is in the calendar until Add. With no answer in FALLBACK_AFTER,
the study blocks around the calendar alone are proposed in the same chat, so the plan is there in the morning.

The study blocks land in the study calendar as review sessions, which is what the off-task nudges (nudges.py) watch.
"""

import asyncio
import logging
from datetime import date, datetime, time, timedelta
from typing import Awaitable, Callable
from zoneinfo import ZoneInfo

from .db import utcnow
from .examplan import BUSY_GAP, ExamPlan, _cut, _hours, _place
from .tools import Tool, ToolOutput

log = logging.getLogger(__name__)

TICK = 300  # seconds
FALLBACK_AFTER = timedelta(minutes=90)  # no answer by then: the study blocks around the calendar alone
PARTS = {"morning": (time(0, 0), time(13, 0)), "afternoon": (time(13, 0), time(18, 0)),
         "evening": (time(18, 0), time(23, 59))}
MOST_ITEMS = 12  # the user's things in one plan


class DayPlanner:
    def __init__(self, store: ExamPlan, plans, agent, push=None, reminders=None,
                 events: Callable[[datetime, datetime], Awaitable[list[dict] | None]] | None = None,
                 calendar: str | None = None):
        """`events(start, end)`: the calendar as event_json; `calendar`: where the user's own things go (the default
        calendar), the study blocks going to the study calendar."""
        self.store, self.plans, self.agent, self.push = store, plans, agent, push
        self.reminders, self.events, self.calendar = reminders, events, calendar
        self.tz: ZoneInfo = store.tz

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:
                log.exception("day plan tick failed")
            await asyncio.sleep(TICK)

    def chat(self) -> str:
        """Secretary's Tomorrow chat (a specialist's, so the router leaves the answer there), made once."""
        s = self.store.settings()
        db = self.agent.db
        if s.get("day_chat") and db.app_conversation(s["day_chat"]) is not None:
            return s["day_chat"]
        row = db.new_app_conversation("secretary")
        db.set_conversation_title(row["id"], "Tomorrow")
        s["day_chat"] = row["public_id"]
        self.store._save(s)
        return row["public_id"]

    def _mark(self, key: str, day: date) -> None:
        s = self.store.settings()
        s[key] = day.isoformat()
        self.store._save(s)

    async def tick(self, now: datetime | None = None) -> str | None:
        """Asks at day_plan_at, proposes the fallback FALLBACK_AFTER later; each once per evening. Returns what it did."""
        now = now or utcnow()
        local = now.astimezone(self.tz)
        s = self.store.settings()
        if not s["day_plan"] or self.plans is None or self.plans.cal is None:
            return None
        tomorrow = local.date() + timedelta(days=1)
        at = time.fromisoformat(s["day_plan_at"])
        if local.time() < at:
            return None
        if s.get("day_asked") != tomorrow.isoformat():
            self._mark("day_asked", tomorrow)  # once, whatever happens next
            return "asked" if await self.ask(tomorrow, now) else None
        fallback = min(datetime.combine(local.date(), at, self.tz) + FALLBACK_AFTER,
                       datetime.combine(local.date(), time(23, 55), self.tz))
        if s.get("day_planned") != tomorrow.isoformat() and local >= fallback:
            self._mark("day_planned", tomorrow)
            plan, _ = await self.propose(tomorrow, [], self.chat(), "secretary", now)
            if plan is None:
                return None
            text = ("No answer, so here's tomorrow's study around what's in the calendar. Add it, or tell me what "
                    "else you have and I'll fit it around that.")
            await self.agent.post(self.chat(), f"[Tomorrow's plan without an answer: plan {plan['public_id']}, not "
                                  "in the calendar until Add.]", text,
                                  [{"type": "events", "events": self.plans.card_items(plan)}])
            return "fallback"
        return None

    # -- what tomorrow holds -------------------------------------------------------------------------------------

    async def _calendar(self, day: date) -> list[dict]:
        if self.events is None:
            return []
        start = datetime.combine(day, time.min, self.tz)
        try:
            found = await self.events(start, start + timedelta(days=1))
        except Exception:
            log.warning("day plan: calendar lookup failed", exc_info=True)
            return []
        return sorted((e for e in found or [] if not e.get("all_day")), key=lambda e: e["start"])

    def _reminders(self, day: date) -> list:
        if self.reminders is None:
            return []
        start = datetime.combine(day, time.min, self.tz)
        try:
            return self.reminders.due_between(start, start + timedelta(days=1))
        except Exception:
            log.warning("day plan: reminders lookup failed", exc_info=True)
            return []

    async def summary(self, day: date, now: datetime) -> tuple[str, int]:
        """What Secretary says about `day` before asking, and the study minutes the exam plan wants then."""
        lines = [f"Tomorrow, {day:%a %d %b}:"]
        events = await self._calendar(day)
        for e in events:
            s0, e0 = datetime.fromisoformat(e["start"]), datetime.fromisoformat(e["end"])
            lines.append(f"- {s0.astimezone(self.tz):%H:%M}–{e0.astimezone(self.tz):%H:%M} {e['title']}")
        if not events:
            lines.append("- nothing in the calendar")
        due = self._reminders(day)
        if due:
            lines.append("Reminders: " + "; ".join(
                r.title + (f" ({r.due_at.astimezone(self.tz):%H:%M})" if getattr(r, "due_at", None) else "")
                for r in due))
        plan = await self.store.plan(now, fresh=True)
        blocks = self.store.day_blocks(plan, day)
        minutes = sum(b["minutes"] for b in blocks)
        if blocks:
            lines.append("Study from the exam plan: " + "; ".join(
                f"{b['name'][:1].upper() + b['name'][1:]} {_hours(b['minutes'])} "
                f"({', '.join(b['phases'])}, before the {b['what']} on {date.fromisoformat(b['date']):%a %d %b})"
                for b in blocks) + ".")
        return "\n".join(lines), minutes

    async def ask(self, day: date, now: datetime) -> bool:
        """False (nothing said) when the exam plan has no study for `day`: no evening question about it."""
        text, minutes = await self.summary(day, now)
        if not minutes:
            self._mark("day_planned", day)
            return False
        text += ("\n\nAnything else you have to do tomorrow? Tell me the time, or how long it takes and roughly when, "
                 "and I'll fit the study around it. Or just say that's all.")
        chat = self.chat()
        note = (f"[Tomorrow's plan ({day:%a %d %b}), asked at {datetime.now(self.tz):%H:%M}. When the user answers, "
                "call plan_tomorrow with what they have to do tomorrow that isn't already in the calendar (timed "
                "items with start and end; untimed ones with minutes and the part of the day): with nothing more, "
                "call it with no items. If they say to skip tomorrow, don't call it.]")
        await self.agent.post(chat, note, text)
        if self.push is not None:
            try:
                await self.push.send_message(chat, "Secretary · Tomorrow", "Anything else tomorrow besides "
                                             + (f"{_hours(minutes)} of study" if minutes else "what's planned") + "?")
            except Exception:
                log.exception("couldn't push the day plan question")
        return True

    # -- the plan ----------------------------------------------------------------------------------------------

    async def propose(self, day: date, things: list[dict], conversation: str | None, agent: str,
                      now: datetime | None = None) -> tuple[dict | None, list[str]]:
        """The user's things placed first, the exam plan's study for `day` around them, as one plan. Returns the plan
        (None when there's nothing to propose) and what couldn't be placed."""
        now = now or utcnow()
        await self.store.plan(now, fresh=True)
        gaps = {day: list(self.store._gaps.get(day, []))}
        for _, s0, e0 in self.store._held.get(day, []):
            gaps[day] = _cut(gaps[day], s0, e0 + BUSY_GAP)
        items, busy, left = [], [], []
        for t in sorted(things, key=lambda t: (t.get("start") is None, t.get("start") or "")):
            title = " ".join(str(t.get("title") or "").split())[:120]
            if not title:
                continue
            if t.get("start"):
                s0 = _local(t["start"], day, self.tz)
                e0 = (_local(t["end"], day, self.tz) if t.get("end")
                      else s0 + timedelta(minutes=int(t.get("minutes") or 60)))
                if e0 <= s0:
                    raise ValueError(f"{title}: it ends before it starts")
                gaps[day] = _cut(gaps[day], s0 - BUSY_GAP, e0 + BUSY_GAP)
            else:
                minutes = max(5, min(int(t.get("minutes") or 60), 600))
                lo, hi = PARTS.get(t.get("part") or "", (time.min, time(23, 59)))
                window = datetime.combine(day, lo, self.tz), datetime.combine(day, hi, self.tz)
                part = {day: [(max(a, window[0]), min(b, window[1])) for a, b in gaps[day]
                              if min(b, window[1]) > max(a, window[0])]}
                placed = _place(part, day, minutes)
                if len(placed) != 1 or placed[0][1] - placed[0][0] < timedelta(minutes=minutes):
                    left.append(title)  # not in one piece where they said: they place it themselves
                    continue
                s0, e0 = placed[0]
                gaps[day] = _cut(gaps[day], s0 - BUSY_GAP, e0 + BUSY_GAP)
            busy.append((s0, e0))
            items.append({"title": title, "start": f"{s0:%Y-%m-%dT%H:%M}", "end": f"{e0:%Y-%m-%dT%H:%M}",
                          "calendar": t.get("calendar") or self.calendar or self.store.study.study_calendar,
                          "notes": "Planned the evening before."})
        study, warnings = await self.store.week(day, now, days=1, busy=busy, fresh=False)
        items = sorted(items + study, key=lambda i: i["start"])
        self._mark("day_planned", day)
        if not items:
            return None, left
        return self.plans.propose(conversation, agent, items), left + warnings


def _local(value: str, day: date, tz: ZoneInfo) -> datetime:
    """'14:30' on `day`, or a full local date-time."""
    value = str(value).strip()
    if "T" in value or len(value) > 5:
        dt = datetime.fromisoformat(value)
    else:
        dt = datetime.combine(day, time.fromisoformat(value))
    return dt.astimezone(tz) if dt.tzinfo else dt.replace(tzinfo=tz)


def dayplan_tools(planner: DayPlanner, where=None) -> list[Tool]:
    """`where()`: the chat of the turn and the agent, where the plan's card goes."""

    async def plan_tomorrow(items: list[dict] | None = None, day: str | None = None) -> str:
        now = utcnow()
        d = date.fromisoformat(day) if day else now.astimezone(planner.tz).date() + timedelta(days=1)
        if len(items or []) > MOST_ITEMS:
            raise ValueError(f"at most {MOST_ITEMS} things")
        conversation, agent = where() if where else (None, "secretary")
        plan, left = await planner.propose(d, items or [], conversation, agent, now)
        if plan is None:
            return (f"Nothing to propose for {d:%a %d %b}: no study left in the exam plan and nothing new."
                    + (f" Couldn't place: {', '.join(left)}." if left else ""))
        lines = "\n".join(f"- {planner.plans.line(i)}" for i in plan["items"])
        return ToolOutput(
            f"Proposed {d:%a %d %b} as plan {plan['public_id']}: their things first, the exam plan's study around them "
            f"(review sessions in the study calendar). Not in the calendar until the user taps Add on the card.\n"
            f"{lines}" + (f"\nNot placed (say so, and ask when): {'; '.join(left)}" if left else ""),
            {"type": "events", "events": planner.plans.card_items(plan)})

    item = {"type": "object", "properties": {
        "title": {"type": "string"},
        "start": {"type": "string", "description": "HH:MM (or YYYY-MM-DDTHH:MM) when it has a time"},
        "end": {"type": "string", "description": "HH:MM; else `minutes` from the start"},
        "minutes": {"type": "integer", "description": "How long, for one without an end or without a time"},
        "part": {"type": "string", "enum": list(PARTS), "description": "Roughly when, for one without a time"},
        "calendar": {"type": "string", "description": "Only when the user names one; else the default calendar"}},
        "required": ["title"], "additionalProperties": False}
    return [Tool("plan_tomorrow",
                 "Tomorrow's plan, as one events card: the user's things for the day that aren't in the calendar yet "
                 "(placed first: at their time, or in the free time of the part of the day they said), then the exam "
                 "plan's study blocks around them and around the calendar. Use it when the user answers the evening "
                 "'anything else tomorrow?' question, or asks to plan tomorrow. No items: just the study around the "
                 "calendar. Nothing is added until the user taps Add.",
                 {"type": "object", "properties": {
                     "items": {"type": "array", "items": item},
                     "day": {"type": "string", "description": "YYYY-MM-DD; tomorrow when left out"}},
                  "required": [], "additionalProperties": False}, plan_tomorrow)]
