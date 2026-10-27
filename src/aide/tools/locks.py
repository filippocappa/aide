"""Screen Time lock tools (Coach's). Locking and changing run immediately; ending a lock early and deleting one wait
for the user's Confirm, so a lock can't be talked away in a sentence. A strict lock that's on can't be ended here at
all: only with an emergency pass in the app."""

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from ..db import utcnow
from ..locks import PASSES, UNLOCKS_SHOWN, LockStore
from ..routines import check_time
from . import Tool


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

    lid = {"lock_id": {"type": "integer"}}
    hhmm = {"type": "string", "description": "HH:MM, 24-hour, local time"}
    days = {"type": "array", "items": {"type": "integer"},
            "description": "ISO weekdays it starts on, 1 = Monday … 7 = Sunday; [] for every day"}
    strict = {"type": "boolean", "description": "only when the user asks for it: once on, it can't be ended early "
              f"from chat or with a reason, only with one of the {PASSES} emergency passes a month, in the app"}
    return [
        Tool("list_locks", "List the Screen Time locks: id in brackets, title, when, whether it's on now, who set it; "
             "whether the phone allows Screen Time; and the times the user unlocked early this week, with reasons.",
             _obj({}, []), list_locks),
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
    ]
