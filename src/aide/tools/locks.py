"""Screen Time lock tools (Coach's). Locking and changing run immediately; ending a lock early and deleting one wait
for the user's Confirm, so a lock can't be talked away in a sentence. A strict lock that's on can't be ended here at
all: only with an emergency pass in the app."""

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from ..db import utcnow
from ..locks import PASSES, UNLOCKS_SHOWN, LockStore
from ..routines import check_time
from . import Tool, ToolOutput
from .pages import open_card


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def lock_tools(store: LockStore, tz: ZoneInfo, agent: str = "coach") -> list[Tool]:
    def until_time(value: str, now: datetime) -> datetime:
        """HH:MM local, the next time it comes."""
        hh, mm = map(int, check_time(value).split(":"))
        local = now.astimezone(tz)
        at = local.replace(hour=hh, minute=mm, second=0, microsecond=0)
        return (at if at > local else at + timedelta(days=1)).astimezone(timezone.utc)

    async def list_locks() -> str:
        now = utcnow()
        device = store.device()
        lines = [store.line(lock, now) for lock in store.all(now)] or ["No locks yet."]
        if limits := store.limits():
            lines.append("Daily app limits (the apps each covers are picked on the phone):")
            lines += [f"- {store.limit_line(limit, now)}" for limit in limits]
        if not device["authorized"]:
            lines.append("The phone hasn't allowed Screen Time yet (Settings → Screen Time in the app), so locks "
                         "don't hold until it does.")
        if unlocks := store.unlocks(now - UNLOCKS_SHOWN):
            lines.append("Unlocked early, the last 7 days:")
            lines += [f"- {datetime.fromisoformat(u['at']).astimezone(tz):%a %d %b %H:%M} {u['title']}"
                      f"{' (emergency pass)' if u['pass'] else ''}: {u['reason']}" for u in unlocks]
        passes = store.passes(now)
        lines.append(f"Emergency passes: {passes['left']} of {PASSES} left this month.")
        return "\n".join(lines)

    async def screen_usage(days: int = 14) -> str:
        return store.usage_text(utcnow(), max(1, min(int(days), 90)))

    async def lock_now(title: str, minutes: int | None = None, until: str | None = None,
                       start: str | None = None, strict: bool = False) -> str:
        now = utcnow()
        begin = until_time(start, now) if start else None
        end = until_time(until, begin or now) if until else None
        lock = store.lock_for(title, minutes=minutes, until=end, start=begin, agent=agent, strict=strict, now=now)
        return "Locked: " + store.line(lock, now)

    async def add_lock_schedule(title: str, start: str, end: str, days: list[int], strict: bool = False) -> str:
        now = utcnow()
        return "Set: " + store.line(store.schedule(title, start, end, days, agent=agent, strict=strict, now=now), now)

    async def update_lock(lock_id: int, title: str | None = None, start: str | None = None, end: str | None = None,
                          days: list[int] | None = None, enabled: bool | None = None,
                          strict: bool | None = None) -> str:
        now = utcnow()
        lock = store.update(lock_id, now=now, title=title, start_time=start, end_time=end, days=days,
                            enabled=enabled, strict=strict)
        return "Updated: " + store.line(lock, now)

    async def end_lock(lock_id: int, reason: str) -> str:
        lock = store.get(lock_id)
        store.unlock(lock_id, reason)
        return f"Ended '{lock['title']}' early" + ("" if lock["days"] is None else "; it's back next time")

    async def describe_end(lock_id: int, reason: str) -> str:
        now = utcnow()
        lock = store.get(lock_id)
        until = store.locked_until(lock, now)
        if until is None:
            raise ValueError(f"'{lock['title']}' isn't on now")
        if lock["strict"]:
            raise ValueError(f"'{lock['title']}' is strict: it can't be ended from chat, only with an emergency pass "
                             f"in the app (Settings → Screen Time; {store.passes(now)['left']} left this month)")
        if not reason.strip():
            raise ValueError("ending a lock early needs the user's reason")
        return (f"End '{lock['title']}' early and unlock the apps now (it's on until "
                f"{until.astimezone(tz):%H:%M}). Reason: {reason.strip()}")

    async def delete_lock(lock_id: int) -> str:
        lock = store.get(lock_id)
        store.delete(lock_id)
        return f"Deleted the lock '{lock['title']}'"

    async def describe_delete(lock_id: int) -> str:
        now = utcnow()
        lock = store.get(lock_id)
        if lock["strict"] and store.locked_until(lock, now):
            raise ValueError(f"'{lock['title']}' is strict and on now: it can't be deleted until it's over")
        on = " It's on now, so the apps unlock." if store.locked_until(lock, now) else ""
        return f"Delete the lock '{lock['title']}' ({store.summary(lock, now)}).{on}"

    # -- daily app limits: the apps each covers are picked on the phone (Apple's picker), the rest is here ----------

    async def add_limit(title: str, minutes: int, days: list[int] | None = None, strict: bool = False) -> str:
        now = utcnow()
        limit = store.add_limit(title, minutes, days=days, strict=strict, now=now)
        return ToolOutput(f"Set: {store.limit_line(limit, now)}. It counts nothing until the user picks its apps on "
                          "the phone (Screen Time → the limit): say so, the card opens that page.",
                          open_card("Pick the apps", f"For the limit '{limit['title']}'", "aide://settings/screentime"))

    async def update_limit(limit_id: int, title: str | None = None, minutes: int | None = None,
                           days: list[int] | None = None, enabled: bool | None = None,
                           strict: bool | None = None) -> str:
        now = utcnow()
        limit = store.update_limit(limit_id, now=now, reached_needs_reason=True, title=title, minutes=minutes, days=days, enabled=enabled,
                                   strict=strict)
        return "Updated: " + store.limit_line(limit, now)

    async def end_limit(limit_id: int, reason: str) -> str:
        limit = store.unlock_limit(limit_id, reason)
        return f"Ended the limit '{limit['title']}' for today: its apps are open until midnight"

    async def describe_end_limit(limit_id: int, reason: str) -> str:
        now = utcnow()
        limit = store.get_limit(limit_id)
        if not store.reached(limit, now):
            raise ValueError(f"'{limit['title']}' isn't reached today: nothing to end")
        if limit["strict"]:
            raise ValueError(f"'{limit['title']}' is strict: it can't be ended from chat, only with an emergency pass "
                             f"in the app (Screen Time; {store.passes(now)['left']} left this month)")
        if not reason.strip():
            raise ValueError("ending a limit early needs the user's reason")
        return f"End the limit '{limit['title']}' for today and open its apps until midnight. Reason: {reason.strip()}"

    async def delete_limit(limit_id: int) -> str:
        limit = store.get_limit(limit_id)
        store.delete_limit(limit_id)
        return f"Deleted the limit '{limit['title']}'"

    async def describe_delete_limit(limit_id: int) -> str:
        now = utcnow()
        limit = store.get_limit(limit_id)
        if limit["strict"] and store.reached(limit, now):
            raise ValueError(f"'{limit['title']}' is strict and reached today: it can be deleted tomorrow")
        on = " It's reached today, so its apps open." if store.reached(limit, now) else ""
        return f"Delete the limit '{limit['title']}' ({store.limit_summary(limit)}).{on}"

    lid = {"lock_id": {"type": "integer"}}
    mid = {"limit_id": {"type": "integer"}}
    hhmm = {"type": "string", "description": "HH:MM, 24-hour, local time"}
    days = {"type": "array", "items": {"type": "integer"},
            "description": "ISO weekdays it starts on, 1 = Monday … 7 = Sunday; [] for every day"}
    strict = {"type": "boolean", "description": "only when the user asks for it: once on, it can't be ended early "
              f"from chat or with a reason, only with one of the {PASSES} emergency passes a month, in the app"}
    return [
        Tool("list_locks", "List the Screen Time locks: id in brackets, title, when, whether it's on now, who set it; "
             "the daily app limits and whether they were reached today; whether the phone allows Screen Time; and "
             "the times the user unlocked early this week, with reasons.",
             _obj({}, []), list_locks),
        Tool("screen_usage", "How much the user was on their phone, day by day (at least so much, from the phone's "
             "Screen Time in 15-minute steps), today so far and their usual. Per-app times stay on the phone; the "
             "daily app limits and when they were reached are in list_locks.",
             _obj({"days": {"type": "integer", "description": "how many days back, default 14"}}, []), screen_usage),
        Tool("lock_now", "Lock the phone's apps for a while (all but Phone and the ones the user allows): from now, "
             "or from `start`, for `minutes` or until `until`. 15 minutes to 24 hours. Runs immediately.",
             _obj({"title": {"type": "string", "description": "short, shown on the lock screen: Focus, Study, Dinner"},
                   "minutes": {"type": "integer", "description": "how long; or give until"},
                   "until": {**hhmm, "description": "HH:MM local, when it ends (the next time it comes)"},
                   "start": {**hhmm, "description": "HH:MM local, when it starts; default now"},
                   "strict": strict},
                  ["title"]), lock_now),
        Tool("add_lock_schedule", "Lock the apps every week from `start` to `end` (an end before the start is the "
             "next morning: 22:30 to 07:00), on `days`. Runs immediately.",
             _obj({"title": {"type": "string", "description": "short: Bedtime, Morning, Study"},
                   "start": hhmm, "end": hhmm, "days": days, "strict": strict},
                  ["title", "start", "end", "days"]), add_lock_schedule),
        Tool("update_lock", "Change a schedule (title, start, end, days, strict, or turn it off and on with enabled), "
             "or a one-off's title or strict. Pass only what changes. Refused for a lock that's on now (except the "
             "title, or making it strict): that's end_lock. Runs immediately.",
             _obj({**lid, "title": {"type": "string"}, "start": hhmm, "end": hhmm, "days": days,
                   "enabled": {"type": "boolean"}, "strict": strict}, ["lock_id"]), update_lock),
        Tool("end_lock", "End a lock that's on now, early: a one-off is gone, a schedule comes back next time. Only "
             "when the user asks, with their reason in their words. Not for a strict lock (only an emergency pass in "
             "the app ends one). Queued: runs only when the user confirms.",
             _obj({**lid, "reason": {"type": "string"}}, ["lock_id", "reason"]), end_lock, confirm=True,
             describe=describe_end, target_arg="lock_id"),
        Tool("delete_lock", "Delete a lock for good. Queued: runs only when the user confirms.", _obj(lid, ["lock_id"]),
             delete_lock, confirm=True, describe=describe_delete, target_arg="lock_id"),
        Tool("add_limit", "Add a daily app limit: so many minutes a day on some apps, then they're locked until "
             "midnight. Which apps it covers can only be picked on the phone (Apple's picker), so the title says what "
             "they are (Social, Games) and the reply tells the user to pick them; the card opens the page. Runs "
             "immediately.",
             _obj({"title": {"type": "string", "description": "short: what the apps are, Social, YouTube, Games"},
                   "minutes": {"type": "integer", "description": "minutes a day, 5 to 720"}, "days": days,
                   "strict": {**strict, "description": "only when the user asks for it: once reached, it can't be "
                              f"ended early from chat, only with one of the {PASSES} emergency passes a month"}},
                  ["title", "minutes"]), add_limit),
        Tool("update_limit", "Change a daily app limit: title, minutes, days, strict, or turn it off and on with "
             "enabled. Pass only what changes. A strict limit reached today can only be tightened until tomorrow. "
             "Runs immediately. (Its apps are changed on the phone.)",
             _obj({**mid, "title": {"type": "string"}, "minutes": {"type": "integer"}, "days": days,
                   "enabled": {"type": "boolean"}, "strict": {"type": "boolean"}}, ["limit_id"]), update_limit),
        Tool("end_limit", "End a daily app limit reached today, until midnight. Only when the user asks, with their "
             "reason in their words. Not for a strict limit (only an emergency pass in the app). Queued: runs only "
             "when the user confirms.",
             _obj({**mid, "reason": {"type": "string"}}, ["limit_id", "reason"]), end_limit, confirm=True,
             describe=describe_end_limit, target_arg="limit_id"),
        Tool("delete_limit", "Delete a daily app limit for good. Queued: runs only when the user confirms.",
             _obj(mid, ["limit_id"]), delete_limit, confirm=True, describe=describe_delete_limit,
             target_arg="limit_id"),
    ]
