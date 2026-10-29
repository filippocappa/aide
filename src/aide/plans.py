"""Event plans: calendar events an agent proposes together (a study plan, a week), added when the user taps Add in the
app. The contract is docs/API.md, "Plans".

A plan is shown in the chat as an events card whose items are `proposed`; nothing is in the calendar until the
user's tap, which is the confirmation (like sending a mail draft). An item with a course is a review session, added
through ReviewStore so Professor still follows it.
"""

import asyncio
import json
import re
import secrets
import sqlite3
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .db import utcnow
from .icloud import CalendarBackend
from .reviews import ReviewStore

SCHEMA = """
CREATE TABLE IF NOT EXISTS event_plans (
    id           INTEGER PRIMARY KEY,
    public_id    TEXT NOT NULL UNIQUE,  -- ep_…
    conversation TEXT,                  -- the chat it was proposed in (a public id), NULL for the shared one
    agent        TEXT NOT NULL,
    items        TEXT NOT NULL,         -- JSON: the items, each with its status and, once added, its event
    created_at   TEXT NOT NULL
);
"""

MAX_ITEMS = 40
_ID = re.compile(r"^ep_[0-9a-f]{12}$")


class PlanStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, cal: CalendarBackend | None,
                 reviews: ReviewStore | None = None):
        self.conn, self.tz, self.cal, self.reviews = conn, tz, cal, reviews
        self.conn.executescript(SCHEMA)

    def propose(self, conversation: str | None, agent: str, items: list[dict]) -> dict:
        """A plan from items {title, start, end, calendar, location?, notes?, course_id?, topics?}, with start and
        end as local date-times (or dates, for all-day ones). Checked here, so a bad item fails before it's shown."""
        if not items:
            raise ValueError("a plan needs at least one event")
        if len(items) > MAX_ITEMS:
            raise ValueError(f"at most {MAX_ITEMS} events in a plan")
        public_id = "ep_" + secrets.token_hex(6)
        out = []
        for n, item in enumerate(items, 1):
            start, end = self._when(item["start"]), self._when(item["end"])
            if isinstance(start, datetime) != isinstance(end, datetime):
                raise ValueError(f"{item['title']}: start and end must both be dates or both be date-times")
            if end <= start if isinstance(start, datetime) else end < start:
                raise ValueError(f"{item['title']}: it ends before it starts")
            out.append({**item, "id": f"{public_id}-{n}", "start": start.isoformat(), "end": end.isoformat(),
                        "status": "proposed", "event": None})
        self.conn.execute("INSERT INTO event_plans (public_id, conversation, agent, items, created_at) "
                          "VALUES (?, ?, ?, ?, ?)", (public_id, conversation, agent, json.dumps(out),
                                                     utcnow().isoformat()))
        return self.get(public_id)

    def get(self, public_id: str) -> dict | None:
        if not _ID.match(public_id or ""):
            return None
        row = self.conn.execute("SELECT * FROM event_plans WHERE public_id = ?", (public_id,)).fetchone()
        return {**dict(row), "items": json.loads(row["items"])} if row else None

    def find(self, public_id: str) -> dict:
        if (plan := self.get(public_id)) is None:
            raise KeyError(f"no plan {public_id}")
        return plan

    async def add(self, public_id: str, ids: list[str] | None = None) -> tuple[dict, list[dict]]:
        """Puts the chosen items (all still proposed, when `ids` is None) in the calendar. Returns the plan and the
        items added; an item that can't be added keeps `proposed` and gets an `error`."""
        if self.cal is None:
            raise RuntimeError("There's no calendar on this server.")
        plan = self.find(public_id)
        added = []
        for item in self._chosen(plan, ids):
            if item["status"] != "proposed":
                continue
            start, end = self._when(item["start"]), self._when(item["end"])
            try:
                if item.get("course_id") is not None and self.reviews is not None:
                    minutes = int((end - start).total_seconds() // 60)
                    session = await self.reviews.add(item["course_id"], start, minutes, item.get("topics") or [])
                    uid = session["event_uid"]
                else:
                    last = end if isinstance(start, datetime) else end + timedelta(days=1)  # iCalendar's is exclusive
                    ev = await asyncio.to_thread(self.cal.create, item["calendar"], item["title"], start, last,
                                                 item.get("location") or "", item.get("notes") or "")
                    uid = ev.uid
            except Exception as e:  # noqa: BLE001 - reported on the item, the others go on
                item["error"] = str(e)
                continue
            item.pop("error", None)
            item["status"], item["event"] = "added", uid
            added.append(item)
        self._save(plan)
        return plan, added

    def drop(self, public_id: str, ids: list[str] | None = None) -> tuple[dict, list[dict]]:
        """The chosen items (all still proposed, when `ids` is None) won't be added. Added ones stay."""
        plan = self.find(public_id)
        dropped = [i for i in self._chosen(plan, ids) if i["status"] == "proposed"]
        for item in dropped:
            item["status"] = "dropped"
            item.pop("error", None)
        self._save(plan)
        return plan, dropped

    def card_items(self, plan: dict) -> list[dict]:
        """The plan's items as docs/API.md events, for the chat's events card."""
        return [self.item_json(plan, i) for i in plan["items"]]

    def item_json(self, plan: dict, item: dict) -> dict:
        start, end = self._when(item["start"]), self._when(item["end"])
        all_day = not isinstance(start, datetime)
        return {"id": item["id"], "title": item["title"], "calendar": item["calendar"], "start": start.isoformat(),
                "end": (end + timedelta(days=1)).isoformat() if all_day else end.isoformat(), "all_day": all_day,
                "location": item.get("location") or "", "notes": item.get("notes") or "", "recurring": False,
                "change": "proposed", "plan": plan["public_id"], "status": item["status"], "event": item["event"],
                **({"error": item["error"]} if item.get("error") else {})}

    def line(self, item: dict) -> str:
        start, end = self._when(item["start"]), self._when(item["end"])
        if isinstance(start, datetime):
            return f"{item['title']}, {start:%a %d %b %H:%M}–{end:%H:%M} ({item['calendar']})"
        return f"{item['title']}, {start:%a %d %b} (all day, {item['calendar']})"

    def _chosen(self, plan: dict, ids: list[str] | None) -> list[dict]:
        if ids is None:
            return plan["items"]
        known = {i["id"]: i for i in plan["items"]}
        if missing := [i for i in ids if i not in known]:
            raise KeyError(f"no item {missing[0]} in plan {plan['public_id']}")
        return [known[i] for i in dict.fromkeys(ids)]

    def _save(self, plan: dict) -> None:
        self.conn.execute("UPDATE event_plans SET items = ? WHERE id = ?", (json.dumps(plan["items"]), plan["id"]))

    def _when(self, value: str) -> date | datetime:
        if len(value) == 10:
            return date.fromisoformat(value)
        dt = datetime.fromisoformat(value)
        return dt.replace(tzinfo=self.tz) if dt.tzinfo is None else dt.astimezone(self.tz)
