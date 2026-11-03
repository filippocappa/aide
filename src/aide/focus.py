"""Focus sessions (docs/API.md, "Focus sessions"; #54): study blocks with breaks, everything else locked meanwhile.

A session is a course (and maybe a topic), a rhythm (25/5, 50/10 or one of the user's) and a number of rounds. Each
focus round is a one-off Screen Time lock (locks.py, `focus` on the lock), all made when the session starts, so the
phone shields and opens them on time with the app closed; a break is the gap between two of them. The phone and the
Mac cover every app but the few allowed for focus (and Aide). Strict by default: then only an emergency pass ends a
round early, as with strict locks; otherwise a reason does. A break has nothing to end, so stopping then is free.

FocusWatcher keeps the `focus` Live Activity (the phase, the time left, the topic, round 2 of 4; an alert with a sound
at each switch), finishes a session when its last round ends, and has Professor post it in the course chat with the
check: five of the notebook's questions on the Study page (Learn, no model call). What was studied counts: minutes and
rounds per course in `study_progress`, the `focus` objective measure, and Coach sees them beside screen time.
"""

import asyncio
import logging
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from urllib.parse import quote
from zoneinfo import ZoneInfo

from .db import utcnow
from .live import LiveActivities, unix
from .locks import LockStore

log = logging.getLogger(__name__)

PRESETS = [{"name": "25/5", "focus_min": 25, "break_min": 5, "rounds": 4},
           {"name": "50/10", "focus_min": 50, "break_min": 10, "rounds": 2}]
FOCUS_MIN, FOCUS_MAX = 15, 120  # a round's minutes (Screen Time won't watch a lock under 15)
BREAK_MIN, BREAK_MAX = 1, 30
ROUNDS_MAX = 8  # each round is a DeviceActivity schedule on the phone, which keeps about 20
CHECK = 5  # questions in the check at the end
TICK = 30  # seconds between the watcher's looks
SHOWN = timedelta(minutes=5)  # the finished activity stays this long
POST_LATE = timedelta(hours=6)  # a session that ended longer ago than this (the server was off) isn't posted

SCHEMA = """
CREATE TABLE IF NOT EXISTS focus_sessions (
    id          INTEGER PRIMARY KEY,
    public_id   TEXT NOT NULL UNIQUE,  -- f_…
    course_id   INTEGER NOT NULL,
    topic       TEXT,                  -- a notebook topic's id (t_…)
    topic_title TEXT,
    focus_min   INTEGER NOT NULL,
    break_min   INTEGER NOT NULL,
    rounds      INTEGER NOT NULL,
    strict      INTEGER NOT NULL DEFAULT 1,
    review      TEXT,                  -- the review session it was started from
    agent       TEXT,                  -- who started it; NULL: the user, in the app
    started_at  TEXT NOT NULL,         -- UTC
    ended_at    TEXT,                  -- UTC: when it finished, or was ended early
    ended       TEXT,                  -- done, or early
    reason      TEXT,                  -- why it was ended early
    posted      INTEGER NOT NULL DEFAULT 0, -- Professor has posted it in the course chat
    live        TEXT,                  -- the phase the Live Activity last showed ("focus:2"); 'off' when none started
    check_right INTEGER,
    check_total INTEGER
);
"""


def _hm(minutes: int) -> str:
    return f"{minutes // 60} h {minutes % 60:02d}" if minutes >= 60 else f"{minutes} min"


def _at(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def check_rhythm(focus_min, break_min, rounds) -> tuple[int, int, int]:
    try:
        focus_min, break_min, rounds = int(focus_min), int(break_min), int(rounds)
    except (TypeError, ValueError):
        raise ValueError("focus_min, break_min and rounds are whole numbers")
    if not FOCUS_MIN <= focus_min <= FOCUS_MAX:
        raise ValueError(f"a focus round is {FOCUS_MIN} to {FOCUS_MAX} minutes (Screen Time won't hold a shorter one)")
    if not 1 <= rounds <= ROUNDS_MAX:
        raise ValueError(f"a session is 1 to {ROUNDS_MAX} rounds")
    if rounds > 1 and not BREAK_MIN <= break_min <= BREAK_MAX:
        raise ValueError(f"a break is {BREAK_MIN} to {BREAK_MAX} minutes")
    return focus_min, (break_min if rounds > 1 else 0), rounds


def natural_end(s: dict) -> datetime:
    start = _at(s["started_at"])
    return start + timedelta(minutes=s["rounds"] * s["focus_min"] + (s["rounds"] - 1) * s["break_min"])


def phase(s: dict, now: datetime) -> dict:
    """Where the session is: {kind: focus | break | done, round, since, ends} (round counts from 1)."""
    start = _at(s["started_at"])
    cycle = timedelta(minutes=s["focus_min"] + s["break_min"])
    end = min(_at(s["ended_at"]) or natural_end(s), natural_end(s))
    if now >= end:
        return {"kind": "done", "round": s["rounds"], "since": end, "ends": end}
    i = max(0, int((now - start) / cycle))
    round_start = start + i * cycle
    focus_end = round_start + timedelta(minutes=s["focus_min"])
    if now < focus_end:
        return {"kind": "focus", "round": i + 1, "since": round_start, "ends": focus_end}
    return {"kind": "break", "round": i + 1, "since": focus_end, "ends": round_start + cycle}


def studied(s: dict, now: datetime) -> tuple[int, int]:
    """(rounds finished, minutes of focus) up to its end, or now."""
    start = _at(s["started_at"])
    stop = min(_at(s["ended_at"]) or now, now, natural_end(s))
    cycle = timedelta(minutes=s["focus_min"] + s["break_min"])
    rounds, minutes = 0, 0.0
    for i in range(s["rounds"]):
        begin = start + i * cycle
        if stop <= begin:
            break
        spent = min(stop - begin, timedelta(minutes=s["focus_min"]))
        minutes += spent.total_seconds() / 60
        rounds += spent >= timedelta(minutes=s["focus_min"])
    return rounds, int(minutes)


class FocusStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, locks: LockStore, study=None):
        self.conn, self.tz, self.locks, self.study = conn, tz, locks, study
        self.conn.executescript(SCHEMA)
        self.on_change: list = []  # FocusWatcher.poke
        locks.focus = self  # Coach's screen_usage shows the sessions

    def _changed(self) -> None:
        for hook in self.on_change:
            hook()

    def get(self, public_id: str) -> dict:
        row = self.conn.execute("SELECT * FROM focus_sessions WHERE public_id = ?", (public_id,)).fetchone()
        if row is None:
            raise KeyError(f"no focus session {public_id}")
        return self._row(row)

    @staticmethod
    def _row(row) -> dict:
        s = dict(row)
        s["strict"] = bool(s["strict"])
        return s

    def course_name(self, course_id: int) -> str:
        row = self.conn.execute("SELECT name FROM courses WHERE id = ?", (course_id,)).fetchone()
        name = row[0] if row else "your course"
        return name[:1].upper() + name[1:]

    def current(self, now: datetime | None = None) -> dict | None:
        """The session going on now (a focus round or a break), if any."""
        now = now or utcnow()
        for row in self.conn.execute("SELECT * FROM focus_sessions WHERE ended_at IS NULL ORDER BY id DESC"):
            s = self._row(row)
            if natural_end(s) > now:
                return s
        return None

    def start(self, course_id: int, focus_min: int = 25, break_min: int = 5, rounds: int = 4,
              topic: str | None = None, topic_title: str | None = None, strict: bool = True,
              agent: str | None = None, review: str | None = None, now: datetime | None = None) -> dict:
        now = (now or utcnow()).replace(microsecond=0)
        focus_min, break_min, rounds = check_rhythm(focus_min, break_min, rounds)
        if not self.conn.execute("SELECT 1 FROM courses WHERE id = ?", (course_id,)).fetchone():
            raise ValueError(f"no course {course_id}")
        self.finish_due(now)
        if (on := self.current(now)) is not None:
            raise ValueError(f"a focus session on {self.course_name(on['course_id'])} is on until "
                             f"{natural_end(on).astimezone(self.tz):%H:%M}; end it first")
        public_id = "f_" + secrets.token_hex(6)
        name = self.course_name(course_id)
        cycle = timedelta(minutes=focus_min + break_min)
        made = []
        try:
            for i in range(rounds):
                made.append(self.locks.lock_for(f"Focus · {name}", minutes=focus_min, start=now + i * cycle,
                                                agent=agent, strict=strict, now=now, focus=public_id, quiet=True))
        except ValueError:
            for lock in made:
                self.conn.execute("DELETE FROM screen_locks WHERE id = ?", (lock["id"],))
            raise
        self.conn.execute(
            "INSERT INTO focus_sessions (public_id, course_id, topic, topic_title, focus_min, break_min, rounds, strict, "
            "review, agent, started_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (public_id, course_id, topic or None, (topic_title or "").strip()[:120] or None, focus_min, break_min,
             rounds, int(strict), review, agent, now.isoformat()))
        self.locks._changed()  # one sync push for all the rounds
        self._changed()
        log.info("focus session %s on %s: %d × %d/%d", public_id, name, rounds, focus_min, break_min)
        return self.get(public_id)

    def round_lock(self, s: dict, now: datetime) -> dict | None:
        """The lock holding now for the session's round."""
        for row in self.conn.execute("SELECT id FROM screen_locks WHERE focus = ?", (s["public_id"],)):
            lock = self.locks.get(row["id"])
            if self.locks.locked_until(lock, now):
                return lock
        return None

    def end(self, public_id: str, reason: str | None = None, use_pass: bool = False,
            now: datetime | None = None) -> dict:
        """Ends it early. In a focus round that's unlocking its lock (a reason, and a pass if strict); in a break
        nothing holds, so nothing is asked. The rounds still to come go."""
        now = now or utcnow()
        s = self.get(public_id)
        if s["ended_at"] or natural_end(s) <= now:
            raise ValueError("that focus session is over")
        if phase(s, now)["kind"] == "focus" and (lock := self.round_lock(s, now)) is not None:
            why = (reason or "").strip() or ("Ended a focus session" if use_pass and s["strict"] else "")
            self.locks.unlock(lock["id"], why, use_pass=use_pass, now=now)  # raises when it can't
        self.conn.execute("DELETE FROM screen_locks WHERE focus = ?", (public_id,))
        self.conn.execute("UPDATE focus_sessions SET ended_at = ?, ended = 'early', reason = ? WHERE public_id = ?",
                          (now.isoformat(), (reason or "").strip()[:280] or None, public_id))
        self.locks._changed()
        self._changed()
        return self.get(public_id)

    def finish_due(self, now: datetime | None = None) -> list[dict]:
        """Sessions whose last round has ended are done; one whose round lock went some other way (deleted, unlocked
        on the locks page) ended early then. Returns the ones that finished now."""
        now = now or utcnow()
        out = []
        for row in self.conn.execute("SELECT * FROM focus_sessions WHERE ended_at IS NULL").fetchall():
            s = self._row(row)
            end = natural_end(s)
            if end <= now:
                self.conn.execute("UPDATE focus_sessions SET ended_at = ?, ended = 'done' WHERE id = ?",
                                  (end.isoformat(), s["id"]))
            elif (p := phase(s, now))["kind"] == "focus" and now - p["since"] > timedelta(minutes=1) and \
                    self.round_lock(s, now) is None:
                self.conn.execute("DELETE FROM screen_locks WHERE focus = ?", (s["public_id"],))
                self.conn.execute("UPDATE focus_sessions SET ended_at = ?, ended = 'early' WHERE id = ?",
                                  (now.isoformat(), s["id"]))
                self.locks._changed()
            else:
                continue
            out.append(self.get(s["public_id"]))
        return out

    def set_check(self, public_id: str, right: int, total: int) -> dict:
        if not 0 <= right <= total <= 50:
            raise ValueError("right is 0 to total")
        self.get(public_id)
        self.conn.execute("UPDATE focus_sessions SET check_right = ?, check_total = ? WHERE public_id = ?",
                          (right, total, public_id))
        return self.get(public_id)

    def sessions(self, since: datetime, course_id: int | None = None) -> list[dict]:
        sql, args = "SELECT * FROM focus_sessions WHERE started_at >= ?", [since.isoformat()]
        if course_id is not None:
            sql, args = sql + " AND course_id = ?", args + [course_id]
        return [self._row(r) for r in self.conn.execute(sql + " ORDER BY started_at DESC", args)]

    def totals(self, since: datetime, now: datetime | None = None) -> list[dict]:
        """Per course since then: sessions, rounds finished, minutes of focus."""
        now = now or utcnow()
        out: dict[int, dict] = {}
        for s in self.sessions(since):
            rounds, minutes = studied(s, now)
            t = out.setdefault(s["course_id"], {"course_id": s["course_id"], "name": self.course_name(s["course_id"]),
                                                "sessions": 0, "rounds": 0, "minutes": 0})
            t["sessions"] += 1
            t["rounds"] += rounds
            t["minutes"] += minutes
        return sorted(out.values(), key=lambda t: -t["minutes"])

    # -- shapes ------------------------------------------------------------------

    def _local(self, dt: datetime | None) -> str | None:
        return dt.astimezone(self.tz).replace(microsecond=0).isoformat() if dt else None

    def check_url(self, s: dict) -> str:
        url = f"aide://study/{s['course_id']}/quiz?focus={s['public_id']}"
        if s["topic"]:
            url += f"&topic={quote(s['topic'])}&title={quote(s['topic_title'] or '')}"
        return url

    def as_json(self, s: dict, now: datetime | None = None) -> dict:
        now = now or utcnow()
        p = phase(s, now)
        rounds, minutes = studied(s, now)
        return {"id": s["public_id"], "course_id": s["course_id"], "course": self.course_name(s["course_id"]),
                "topic": s["topic"], "topic_title": s["topic_title"],
                "focus_min": s["focus_min"], "break_min": s["break_min"], "rounds": s["rounds"], "strict": s["strict"],
                "agent": s["agent"], "review": s["review"],
                "started_at": self._local(_at(s["started_at"])), "ends_at": self._local(natural_end(s)),
                "ended_at": self._local(_at(s["ended_at"])), "ended": s["ended"], "reason": s["reason"],
                "phase": {"kind": p["kind"], "round": p["round"], "since": self._local(p["since"]),
                          "ends": self._local(p["ends"])},
                "rounds_done": rounds, "minutes": minutes,
                "check": {"right": s["check_right"], "total": s["check_total"]} if s["check_total"] else None,
                "check_url": self.check_url(s)}

    def rhythm(self, s: dict) -> str:
        return f"{s['rounds']} × {s['focus_min']} min" + (f" with {s['break_min']}-min breaks" if s["rounds"] > 1 else "")

    def line(self, s: dict, now: datetime) -> str:
        """'Tue 03 Nov 15:10 Macroeconomics (IS-LM), 4 × 25 min: 3 rounds, 75 min, ended early: a call'."""
        rounds, minutes = studied(s, now)
        text = f"{_at(s['started_at']).astimezone(self.tz):%a %d %b %H:%M} {self.course_name(s['course_id'])}" + \
            (f" ({s['topic_title']})" if s["topic_title"] else "") + f", {self.rhythm(s)}: {rounds} round" + \
            ("s" if rounds != 1 else "") + f", {_hm(minutes)}"
        if not s["ended_at"]:
            text += f", on now ({phase(s, now)['kind']})"
        elif s["ended"] == "early":
            text += ", ended early" + (f": {s['reason']}" if s["reason"] else "")
        if s["check_total"]:
            text += f", check {s['check_right']}/{s['check_total']}"
        return text

    def text(self, now: datetime | None = None, days: int = 7, course_id: int | None = None) -> str:
        """The last `days` days of focus sessions, for the agents."""
        now = now or utcnow()
        self.finish_due(now)
        found = self.sessions(now - timedelta(days=days), course_id)
        if not found:
            return f"No focus sessions in the last {days} days."
        lines = [f"Focus sessions, the last {days} days (everything but study apps locked):"]
        if course_id is None:
            lines += [f"- {t['name']}: {t['sessions']} sessions, {t['rounds']} rounds, {_hm(t['minutes'])}"
                      for t in self.totals(now - timedelta(days=days), now)]
        else:
            rounds = sum(studied(s, now)[0] for s in found)
            lines.append(f"- In all: {len(found)} sessions, {rounds} rounds, "
                         f"{_hm(sum(studied(s, now)[1] for s in found))}")
        lines += [f"- {self.line(s, now)}" for s in found[:10]]
        return "\n".join(lines)


class FocusWatcher:
    """The `focus` Live Activity, the end of a session, and Professor's post in the course chat."""

    def __init__(self, store: FocusStore, live: LiveActivities | None = None, agent=None, push=None):
        self.store, self.live, self.agent, self.push = store, live, agent, push
        self._loop: asyncio.AbstractEventLoop | None = None
        self._poked: asyncio.Event | None = None
        store.on_change.append(self.poke)

    def poke(self) -> None:
        if self._loop and self._poked:
            self._loop.call_soon_threadsafe(self._poked.set)

    async def run(self) -> None:
        self._loop, self._poked = asyncio.get_running_loop(), asyncio.Event()
        while True:
            try:
                await asyncio.wait_for(self._poked.wait(), self._wait())
            except asyncio.TimeoutError:
                pass
            self._poked.clear()
            try:
                await self.tick(utcnow())
            except Exception:
                log.exception("focus tick failed")

    def _wait(self) -> float:
        """Until the next switch, so focus and break change on the second, at most TICK."""
        now = utcnow()
        if (s := self.store.current(now)) is None:
            return TICK
        return max(1.0, min(TICK, (phase(s, now)["ends"] - now).total_seconds() + 0.5))

    def _key(self, s: dict) -> str:
        return f"focus:{s['public_id']}"

    def _state(self, s: dict, p: dict, now: datetime) -> dict:
        _, minutes = studied(s, now)
        return {"phase": p["kind"], "since": unix(p["since"]), "ends": unix(p["ends"]), "round": p["round"],
                "rounds": s["rounds"], "strict": s["strict"], "minutes": minutes, "over": p["kind"] == "done"}

    def _alert(self, s: dict, p: dict) -> dict:
        ends = p["ends"].astimezone(self.store.tz)
        if p["kind"] == "focus":
            title = f"Focus · round {p['round']} of {s['rounds']}"
            body = f"{s['topic_title'] or self.store.course_name(s['course_id'])} until {ends:%H:%M}. Apps are locked."
        else:
            title = f"Break · {s['break_min']} min"
            body = f"Round {p['round']} of {s['rounds']} done. Back to it at {ends:%H:%M}."
        return {"title": title, "body": body, "sound": "default"}

    async def tick(self, now: datetime) -> None:
        for s in self.store.finish_due(now):
            await self._finished(s, now)
        for row in self.store.conn.execute(
                "SELECT public_id FROM focus_sessions WHERE ended_at IS NOT NULL AND posted = 0").fetchall():
            await self._finished(self.store.get(row[0]), now)
        if (s := self.store.current(now)) is None or self.live is None or not self.live.enabled:
            return
        p = phase(s, now)
        shown = f"{p['kind']}:{p['round']}"
        if s["live"] == shown or s["live"] == "off":
            return
        if s["live"] is None:
            ok = False
            if self.live.settings().get("focus", True):
                attributes = {"key": self._key(s), "title": self.store.course_name(s["course_id"]),
                              "topic": s["topic_title"] or ""}
                ok = await self.live.start("focus", attributes, self._state(s, p, now), self._alert(s, p),
                                           stale=natural_end(s) + SHOWN)
            shown = shown if ok else "off"
        else:
            await self.live.update(self._key(s), self._state(s, p, now), self._alert(s, p),
                                   stale=natural_end(s) + SHOWN)
        self.store.conn.execute("UPDATE focus_sessions SET live = ? WHERE id = ?", (shown, s["id"]))

    async def _finished(self, s: dict, now: datetime) -> None:
        self.store.conn.execute("UPDATE focus_sessions SET posted = 1 WHERE id = ?", (s["id"],))
        if self.live is not None and s["live"] not in (None, "off"):
            p = phase(s, now)
            await self.live.end(self._key(s), self._state(s, p, now), now + SHOWN)
        if now - _at(s["ended_at"]) > POST_LATE or self.agent is None or self.store.study is None:
            return
        rounds, minutes = studied(s, now)
        if minutes < 1:
            return
        name = self.store.course_name(s["course_id"])
        what = f"{name}" + (f", {s['topic_title']}" if s["topic_title"] else "")
        if s["ended"] == "done":
            text = f"Focus done: {rounds} round{'s' if rounds != 1 else ''} on {what}, {_hm(minutes)}."
        else:
            text = (f"Focus ended early on {what}: {rounds} of {s['rounds']} rounds, {_hm(minutes)}"
                    + (f" ({s['reason']})." if s["reason"] else "."))
        text += f" Let's see what stuck: {CHECK} quick questions."
        note = (f"[Focus session {s['public_id']} ended ({s['ended']}): {what}, {self.store.rhythm(s)}, {rounds} "
                f"rounds and {minutes} min of focus. The app offers the check: {CHECK} of the notebook's questions.]")
        card = {"type": "open", "open": [{"id": s["public_id"], "title": "Check what stuck",
                                          "subtitle": f"{CHECK} questions" + (f" on {s['topic_title']}"
                                                                              if s["topic_title"] else ""),
                                          "url": self.store.check_url(s)}]}
        try:
            chat = self.store.study.chat(s["course_id"])
            await self.agent.post(chat, note, text, [card])
            if self.push is not None:
                await self.push.send_message(chat, f"Professor · {name}", text[:180])
        except Exception:
            log.exception("couldn't post focus session %s", s["public_id"])

    async def checked(self, s: dict) -> None:
        """The check at the end was taken: Professor says how it went, in the course chat."""
        if self.agent is None or self.store.study is None or not s["check_total"]:
            return
        right, total = s["check_right"], s["check_total"]
        verdict = ("All of it stuck." if right == total else "Most of it stuck." if right >= total * 0.6
                   else "Worth another look before moving on.")
        text = f"Check after focus: {right} of {total} right. {verdict}"
        note = f"[The check after focus session {s['public_id']}: {right} of {total} right.]"
        try:
            await self.agent.post(self.store.study.chat(s["course_id"]), note, text)
        except Exception:
            log.exception("couldn't post the check of focus session %s", s["public_id"])


def focus_tools(store: FocusStore, study, tz: ZoneInfo, agent: str = "professor"):
    from .tools import Tool

    def _obj(properties: dict, required: list[str]) -> dict:
        return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}

    async def course_id(course: str) -> int:
        await study.courses()
        c = study.course_by_name(course)
        if c is None:
            names = [x["name"] for x in await study.courses()]
            match = [n for n in names if course.lower() in n.lower()]
            if len(match) != 1:
                raise ValueError(f"no course {course!r}; the courses are: {', '.join(names)}")
            c = study.course_by_name(match[0])
        return c["id"]

    async def start_focus(course: str, focus_min: int = 25, break_min: int = 5, rounds: int = 4,
                          topic: str | None = None, strict: bool = True) -> str:
        s = store.start(await course_id(course), focus_min, break_min, rounds, topic_title=topic, strict=strict,
                        agent=agent)
        j = store.as_json(s)
        return (f"Started: {store.rhythm(s)} on {j['course']}" + (f" ({topic})" if topic else "") +
                f", until {natural_end(s).astimezone(tz):%H:%M}. Every app but the ones allowed for focus is locked "
                f"in the rounds{' (strict: only an emergency pass ends a round early)' if strict else ''}; breaks "
                "are open. The Live Activity counts it down. Tell the user, briefly.")

    async def focus_status(days: int = 7) -> str:
        now = utcnow()
        out = []
        if (s := store.current(now)) is not None:
            p = phase(s, now)
            out.append(f"On now: {store.line(s, now)}; {p['kind']} of round {p['round']} until "
                       f"{p['ends'].astimezone(tz):%H:%M}. Ending it early is the user's, in the app.")
        out.append(store.text(now, max(1, min(int(days), 90))))
        return "\n".join(out)

    return [
        Tool("start_focus", "Start a focus session (pomodoro) on a course: rounds of focus with breaks between, every "
             "app but the few allowed for focus locked in the rounds (Screen Time, phone and Mac). '50 minutes on "
             "macro' is one round of 50; 'a pomodoro' is 25/5; 25/5 and 50/10 are the usual rhythms. Rounds are "
             f"{FOCUS_MIN}–{FOCUS_MAX} min, breaks {BREAK_MIN}–{BREAK_MAX}, at most {ROUNDS_MAX} rounds. Strict by "
             "default (only an emergency pass ends a round early); strict false lets a reason end it. Starts now.",
             _obj({"course": {"type": "string", "description": "the course's name"},
                   "focus_min": {"type": "integer", "description": "minutes of a focus round, default 25"},
                   "break_min": {"type": "integer", "description": "minutes of a break, default 5"},
                   "rounds": {"type": "integer", "description": "how many focus rounds, default 4"},
                   "topic": {"type": "string", "description": "what they'll study, if they said"},
                   "strict": {"type": "boolean", "description": "default true"}}, ["course"]), start_focus),
        Tool("focus_status", "The focus session on now, if any, and the recent ones (per course: sessions, rounds, "
             "minutes, ended early and why, the check after).",
             _obj({"days": {"type": "integer", "description": "how many days back, default 7"}}, []), focus_status),
    ]
