"""The wake-up briefing: a "wake" digest once a day, when the user gets up. Rules in docs/API.md, "Apple Health".

Signals: POST /v1/wake (a Shortcuts automation on the phone), or a health upload whose today has a sleep that
ended in the last 3 hours. The first signal of a local day between 03:00 and 15:00 starts it. If last night
isn't uploaded yet, it waits up to 10 minutes for it (in the background, not in the HTTP request).
"""

import asyncio
import json
import logging
from datetime import datetime, timedelta
from typing import Callable
from zoneinfo import ZoneInfo

from .digest import DigestService
from .health import HealthStore
from .push import Push

log = logging.getLogger(__name__)

HOURS = (3, 15)  # local hours a signal counts in: [03:00, 15:00)
RECENT = timedelta(hours=3)  # an uploaded sleep.wake this recent counts as getting up
WAIT = 600  # seconds to wait for last night's sleep


class WakeService:
    def __init__(self, digest: DigestService, health: HealthStore, tz: ZoneInfo, push: Push | None = None,
                 clock: Callable[[], datetime] | None = None):
        self.digest = digest
        self.health = health
        self.tz = tz
        self.push = push
        self.now = clock or (lambda: datetime.now(tz))
        self._running: str | None = None  # local date of a briefing being made
        self._task: asyncio.Task | None = None
        self._uploaded = asyncio.Event()

    def _done_day(self) -> str | None:
        row = self.digest.conn.execute("SELECT value FROM settings WHERE key = 'wake_day'").fetchone()
        return json.loads(row["value"]) if row else None

    def _mark_done(self, day: str) -> None:
        self.digest.conn.execute("INSERT INTO settings (key, value) VALUES ('wake_day', ?) "
                                 "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(day),))

    def signal(self, at: datetime | None = None) -> tuple[bool, str | None]:
        """A wake signal. Returns (started, reason): reason is off, outside_hours or already."""
        at = (at or self.now()).astimezone(self.tz)
        if not self.digest.settings()["wake"]["enabled"]:
            return False, "off"
        if not HOURS[0] <= at.hour < HOURS[1]:
            return False, "outside_hours"
        day = at.date().isoformat()
        if day in (self._running, self._done_day()):
            return False, "already"
        self._running = day
        self._task = asyncio.get_running_loop().create_task(self._run(at))
        return True, None

    def uploaded(self, days: list[dict]) -> None:
        """After a health upload: wake any briefing waiting for sleep, and treat a fresh sleep.wake as a signal."""
        self._uploaded.set()
        now = self.now()
        today = next((d for d in days if d["date"] == now.date().isoformat()), None)
        woke = (today or {}).get("sleep", {}).get("wake")
        if woke:
            try:
                at = datetime.fromisoformat(woke)
            except ValueError:
                return
            if timedelta(0) <= now - at <= RECENT:
                started, _ = self.signal(at)
                if started:
                    log.info("wake-up from a health upload (woke %s)", f"{at.astimezone(self.tz):%H:%M}")

    async def _wait_for_sleep(self, at: datetime) -> None:
        loop = asyncio.get_running_loop()
        deadline = loop.time() + WAIT
        while not (self.health.get(at.date()) or {}).get("sleep"):
            left = deadline - loop.time()
            if left <= 0:
                log.info("wake-up: no sleep data after %d s, going ahead", WAIT)
                return
            self._uploaded.clear()
            try:
                await asyncio.wait_for(self._uploaded.wait(), left)
            except TimeoutError:
                pass

    async def _run(self, at: datetime) -> None:
        day = at.date().isoformat()
        try:
            await self._wait_for_sleep(at)
            digest = await self.digest.generate("wake", self.now(), at)
            self._mark_done(day)
            log.info("wake-up briefing generated")
            if self.push:
                try:
                    await self.push.send_digest("wake", digest["greeting"])
                except Exception:
                    log.exception("wake-up push failed")
        except Exception:
            log.exception("wake-up briefing failed")  # not marked done: a later signal today tries again
        finally:
            self._running = None
