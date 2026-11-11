"""The exam plan (#68): how many hours each coming exam still needs, and whether the free days before it hold them.
No model call. The contract is docs/API.md, "Exam plan".

A course's target is its next exam or mid-term: the Exam calendar's, else the course's dates (notebook.py), else a
likely date the user set (`expected`); the one after it of the same kind is the fallback the warnings point to.

The work is counted per notebook topic, not per word of the course: learning it (its words at a learning pace, less
what its lesson or answers show is known), practising it (its flashcards over three rounds, its checked questions,
its exercise set's items, less those last answered right), then per target the mock exams left (the exam's length
×1.5, for taking and marking) and the last review. While lectures remain before the date, the estimate is stretched
by the share still to come. The credits are only a ceiling: 25 h of work each (Esse3's transcript, else the
Introduction), less the course's lectures (UniTo's timetable, else the calendar's), is the most own study a course
can take; when the notes count more (something's off with them), the phases are cut down to it. The pace is the user's own where the Study page's answers show it (the gaps between
answers in a run), else a default.

The days: from today to the day before the date, each one's free time (wake to bed, less the calendar's events with
15 min around them), at most the daily cap (lighter in term, heavier from the day after the last lecture). Targets
take their days in date order; each spreads its hours as evenly as the days allow (steady from now), and its phases
are laid backwards from the date (review last, then mocks, then practise and learn), so a target that doesn't fit is
short of learning: it should have started earlier.
"""

import asyncio
import copy
import sqlite3
import json
import logging
import re
import statistics
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

from .db import utcnow
from .study import REVIEW_PREFIX, _name
from .tools import Tool, ToolOutput

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS exam_plan_history (  -- each day's estimate per course, for "+4 h since last week"
    day       TEXT NOT NULL,     -- local date
    course_id INTEGER NOT NULL,
    target    TEXT NOT NULL,     -- the target's date: a moved exam starts a new line
    need_min  INTEGER NOT NULL,
    topics    INTEGER NOT NULL,  -- written topics counted
    lectures  INTEGER NOT NULL,  -- lectures held so far
    PRIMARY KEY (day, course_id)
);
"""

KEY = "study_plan"
DEFAULTS = {"term_cap_min": 120, "season_cap_min": 240, "expected": {}, "topics": {}}
CAP = (15, 600)  # a daily cap's range, minutes
PACE = {"read_wpm": 60.0, "card_min": 0.5, "question_min": 1.5, "exercise_min": 12.0}  # defaults until learnt
LEARNT = 20  # answers of a kind before its pace is the user's own
GAP = (5, 600)  # seconds between two answers that count as one item's time; longer is a break
PACE_DAYS = 90
ROUNDS = 3  # a flashcard is learnt over three spaced rounds
MOCKS = {"exam": 3, "mid-term": 2}
MOCK_MIN = 90  # an exam's length when nothing says it
MOCK_FACTOR = 1.5  # taking it and going through the marking
CREDIT_H = 25  # hours of work a credit (CFU/ECTS) stands for, lectures included
REVIEW_SHARE, REVIEW_FLOOR = 0.15, 60  # the last review: a share of the whole course's work, at least an hour
WINDOW = (time(8, 30), time(22, 30))  # the day without a wake time
READY = timedelta(hours=1)  # from waking to studying
SLEEP = timedelta(hours=8, minutes=30)  # from stopping to the next wake
BUSY_GAP = timedelta(minutes=15)  # around each event
STEP = 5  # minutes
TIGHT = 0.85  # more of the free time than this: tight
CLOSE = 7  # two targets this many days apart or less
CACHE = 600  # seconds
HISTORY_DAYS = 90
PHASES = ("learn", "practise", "mocks", "review")
WEEK_AT = time(17, 0)  # on Sundays: the coming week proposed
WEEK_TICK = 600  # seconds
_WORD = re.compile(r"\w+")
_CREDITS = re.compile(r"(\d{1,2})\s*(?:CFU|ECTS|credits|crediti)", re.I)
_LENGTH = re.compile(r"(\d{1,3}(?:[.,]5)?)\s*(h\b|hours?|ore\b|min\b|minutes|minuti)", re.I)


def words(body: str) -> int:
    """The words to learn on a topic page: not its questions and answers (callouts), images or headings."""
    keep = [line for line in body.splitlines() if not line.lstrip().startswith((">", "![", "#"))]
    return len(_WORD.findall("\n".join(keep)))


def exam_minutes(text: str | None) -> int | None:
    """The exam's length from the Introduction's line on it: "2 hours", "90 minutes", "1,5 h"."""
    if not text or not (m := _LENGTH.search(text)):
        return None
    n = float(m.group(1).replace(",", "."))
    return int(n * 60) if m.group(2).lower().startswith(("h", "o")) else int(n)


def credits(text: str | None) -> int | None:
    return int(m.group(1)) if text and (m := _CREDITS.search(text)) else None


def spread(free: dict[date, int], days: list[date], need: int) -> dict[date, int]:
    """`need` minutes over `days` as evenly as each day's free minutes allow: the lowest daily level that holds
    them, the last day trimmed. All of it when they don't fit."""
    total = sum(free[d] for d in days)
    if need <= 0 or not days:
        return {}
    if need >= total:
        return {d: free[d] for d in days if free[d]}
    lo, hi = 0, max(free[d] for d in days)
    while lo < hi:
        mid = (lo + hi) // 2
        if sum(min(free[d], mid) for d in days) >= need:
            hi = mid
        else:
            lo = mid + 1
    level, left, out = lo, need, {}  # to the minute: rounded up, the work ran out days before the date
    for d in days:
        if (m := min(free[d], level, left)) > 0:
            out[d] = m
            left -= m
    return out


def lay(alloc: dict[date, int], phases: list[tuple[str, int]]) -> dict[date, dict[str, int]]:
    """The phases over the allocated days, backwards from the last: the last phase gets the last days; what doesn't
    fit is the first phases' (learning, when short)."""
    out: dict[date, dict[str, int]] = {}
    todo = [[p, m] for p, m in phases if m > 0]
    for d in sorted(alloc, reverse=True):
        room = alloc[d]
        while room > 0 and todo:
            p = todo[-1]
            take = min(room, p[1])
            out.setdefault(d, {})[p[0]] = out.get(d, {}).get(p[0], 0) + take
            room -= take
            p[1] -= take
            if p[1] <= 0:
                todo.pop()
    return out


def _hours(minutes: float) -> str:
    h = minutes / 60
    return f"{round(minutes)} min" if minutes < 60 else f"{h:.0f} h" if h >= 10 or h == int(h) else f"{h:.1f} h"


class ExamPlan:
    def __init__(self, conn, tz: ZoneInfo, study, notebook, quizzes, lessons=None, focus=None, bedtime=None,
                 timetable=None):
        self.conn, self.tz = conn, tz
        self.study, self.notebook, self.quizzes = study, notebook, quizzes
        self.lessons, self.focus, self.bedtime = lessons, focus, bedtime
        self.timetable = timetable  # UniTo's planner (unitimetable.py): every lecture, not only the calendar's
        self._uni: tuple[date, list] | None = None  # the planner's lectures, read once a day
        self.conn.executescript(SCHEMA)
        self._cache: tuple[datetime, dict] | None = None
        # From the last working out, for week(): each day's free stretches, the review sessions already in the
        # calendar ({day: [(course name, start, end)]}), and each target with its days laid out by phase.
        self._gaps: dict[date, list[tuple[datetime, datetime]]] = {}
        self._held: dict[date, list[tuple[str, datetime, datetime]]] = {}
        self._laid: list[tuple[dict, dict[date, dict[str, int]]]] = []

    # -- settings ----------------------------------------------------------------------------------------

    def settings(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = ?", (KEY,)).fetchone()
        return copy.deepcopy(DEFAULTS) | (json.loads(row[0]) if row else {})

    def _save(self, s: dict) -> None:
        self.conn.execute("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET "
                          "value = excluded.value", (KEY, json.dumps(s)))
        self.conn.commit()
        self.invalidate()

    def caps(self) -> dict:
        s = self.settings()
        return {"term_cap_min": s["term_cap_min"], "season_cap_min": s["season_cap_min"]}

    def update_caps(self, **changes) -> dict:
        s = self.settings()
        for k, v in changes.items():
            if k not in ("term_cap_min", "season_cap_min"):
                raise ValueError(f"unknown setting {k!r}")
            if not isinstance(v, int) or isinstance(v, bool) or not CAP[0] <= v <= CAP[1]:
                raise ValueError(f"{k} is {CAP[0]} to {CAP[1]} minutes")
            s[k] = v
        self._save(s)
        return self.caps()

    def set_expected(self, course_id: int, day: date | None, today: date | None = None) -> None:
        """The likely date of a course's exam while the course says none; None takes it away."""
        s = self.settings()
        if day is None:
            s["expected"].pop(str(course_id), None)
        else:
            if day <= (today or datetime.now(self.tz).date()):
                raise ValueError("the likely date has to be after today")
            s["expected"][str(course_id)] = day.isoformat()
        self._save(s)

    def set_topics(self, key: str, topics: list[str] | None, course_id: int) -> None:
        """Which topics a target covers (a mid-term: part of the course); None: all of them."""
        s = self.settings()
        if topics is None:
            s["topics"].pop(key, None)
        else:
            known = {t["public_id"] for t in self.notebook.topics(course_id)}
            if unknown := [t for t in topics if t not in known]:
                raise ValueError(f"not topics of this course: {', '.join(unknown)}")
            if not topics:
                raise ValueError("pick at least one topic, or send null for all")
            s["topics"][key] = list(dict.fromkeys(topics))
        self._save(s)

    def invalidate(self, *_) -> None:
        """What the plan reads changed (notes, dates, settings): the next read works it out again."""
        self._cache = None

    # -- the plan -------------------------------------------------------------------------------------------

    async def plan(self, now: datetime | None = None, fresh: bool = False) -> dict:
        now = now or utcnow()
        if not fresh and self._cache and 0 <= (now - self._cache[0]).total_seconds() < CACHE:
            return self._cache[1]
        out = await self._compute(now)
        self._cache = (now, out)
        return out

    def _targets(self, course: dict, today: date, s: dict) -> tuple[dict, dict | None] | None:
        """The course's next exam or mid-term after today, and the fallback: the next one of the same kind."""
        found: dict[date, dict] = {}
        if self.notebook is not None:
            for d in self.notebook.dates(course["id"], since=today + timedelta(days=1)):
                if d["kind"] in ("exam", "mid-term"):
                    found.setdefault(date.fromisoformat(d["date"]), {
                        "what": d["what"], "kind": d["kind"], "time": d["time"], "from": "course", "date_id": d["id"]})
        if (exam := course.get("next_exam")) is not None:
            at = exam.start.astimezone(self.tz) if isinstance(exam.start, datetime) else None
            if at and at.date() > today:
                had = found.get(at.date())
                found[at.date()] = {"what": had["what"] if had else "exam", "kind": had["kind"] if had else "exam",
                                    "time": f"{at:%H:%M}", "from": "calendar", "date_id": had["date_id"] if had else None}
        if not found and (guess := s["expected"].get(str(course["id"]))) and date.fromisoformat(guess) > today:
            found[date.fromisoformat(guess)] = {"what": "exam", "kind": "exam", "time": None, "from": "expected",
                                                "date_id": None}
        if not found:
            return None
        days = sorted(found)
        first = found[days[0]] | {"date": days[0]}
        nxt = next((found[d] | {"date": d} for d in days[1:] if found[d]["kind"] == first["kind"]), None)
        return first, nxt

    def _pace(self, banks: dict[int, dict[str, str]], now: datetime) -> dict:
        """Minutes an item takes the user, by kind, from the gaps between answers in one run (a break ends it)."""
        samples: dict[str, list[float]] = {"card": [], "question": [], "exercise": []}
        runs = 0
        since = (now - timedelta(days=PACE_DAYS)).isoformat()
        for cid, kinds in banks.items():
            prev = None
            for qkey, at in self.conn.execute("SELECT qkey, answered_at FROM quiz_answers WHERE course_id = ? AND "
                                              "answered_at >= ? ORDER BY answered_at", (cid, since)):
                at = datetime.fromisoformat(at)
                gap = (at - prev).total_seconds() if prev else None
                if gap is not None and GAP[0] <= gap <= GAP[1]:
                    if kind := kinds.get(qkey):
                        samples[kind].append(gap / 60)
                else:
                    runs += 1
                prev = at
        out = {"read_wpm": {"value": PACE["read_wpm"], "learnt": False, "answers": 0}}
        for kind, name in (("card", "card_min"), ("question", "question_min"), ("exercise", "exercise_min")):
            got = samples[kind]
            learnt = len(got) >= LEARNT
            out[name] = {"value": round(statistics.median(got), 2) if learnt else PACE[name], "learnt": learnt,
                         "answers": len(got)}
        out["runs"] = runs
        return out

    async def _days(self, start: date, end: date, now: datetime, s: dict, season_from: date | None) -> dict[date, int]:
        """Each day's study room from `start` to before `end`: free time between waking and bed, less the calendar,
        at most the day's cap; today's from now, less what's already been studied."""
        self._gaps, self._held = {}, {}
        if end <= start:
            return {}
        busy: list[tuple[datetime, datetime]] = []
        cal = self.study.calendar
        if cal is not None:
            a, b = datetime.combine(start, time.min, self.tz), datetime.combine(end + timedelta(days=1), time.min, self.tz)
            try:
                found = await asyncio.to_thread(cal.events, a, b)
            except Exception:
                log.warning("exam plan: couldn't read the calendar; the days are counted as free", exc_info=True)
                found = []
            for e in found:
                if e.all_day:
                    continue
                title = _name(e.title)
                s0 = e.start if e.start.tzinfo else e.start.replace(tzinfo=self.tz)
                e0 = e.end if e.end.tzinfo else e.end.replace(tzinfo=self.tz)
                if title.startswith(REVIEW_PREFIX):  # the plan's own review sessions are study time
                    self._held.setdefault(s0.astimezone(self.tz).date(), []).append(
                        (title[len(REVIEW_PREFIX):].strip().casefold(), s0, e0))
                    continue
                if title.casefold() in self.study.skip:
                    continue  # and so are the user's study blocks
                busy.append((s0 - BUSY_GAP, e0 + BUSY_GAP))
        busy.sort()
        wakes: dict[bool, time | None] = {}

        def wake(d: date) -> time | None:
            if self.bedtime is None:
                return None
            from .bedtime import weekend
            w = weekend(d)
            if w not in wakes:
                try:
                    wakes[w] = time.fromisoformat(self.bedtime.anchor(d)[0])
                except Exception:
                    log.warning("exam plan: no wake time", exc_info=True)
                    wakes[w] = None
            return wakes[w]

        studied_today = 0
        if self.focus is not None:
            midnight = datetime.combine(start, time.min, self.tz).astimezone(timezone.utc)
            studied_today = sum(t["minutes"] for t in self.focus.totals(midnight, now))
        out = {}
        d = start
        while d < end:
            w, w_next = wake(d), wake(d + timedelta(days=1))
            open_ = datetime.combine(d, w, self.tz) + READY if w else datetime.combine(d, WINDOW[0], self.tz)
            close = (datetime.combine(d + timedelta(days=1), w_next, self.tz) - SLEEP if w_next
                     else datetime.combine(d, WINDOW[1], self.tz))
            if d == start:
                open_ = max(open_, now.astimezone(self.tz))
            free, cursor, gaps = 0.0, open_, []
            for b0, b1 in busy:
                if b1 <= cursor or b0 >= close:
                    continue
                if min(b0, close) > cursor:
                    gaps.append((cursor, min(b0, close)))
                free += max(0.0, (min(b0, close) - cursor).total_seconds() / 60)
                cursor = max(cursor, b1)
            if close > cursor:
                gaps.append((cursor, close))
            free += max(0.0, (close - cursor).total_seconds() / 60)
            self._gaps[d] = gaps
            cap = s["season_cap_min"] if season_from is not None and d >= season_from else s["term_cap_min"]
            if d == start:
                cap = max(0, cap - studied_today)
            out[d] = int(min(cap, free) // STEP * STEP)
            d += timedelta(days=1)
        return out

    def _work(self, course: dict, target: dict, s: dict, pace: dict, data: dict) -> dict:
        """What's left for the target, per topic and per phase, in minutes (before the stretch for lectures)."""
        key = target["date_id"] or f"{course['id']}@{target['date'].isoformat()}"
        chosen = s["topics"].get(key)
        topics = [t for t in data["topics"] if not chosen or t["public_id"] in chosen]
        rows = []
        full = 0.0
        for t in topics:
            items = data["items"].get(t["public_id"], {})
            known = {k: sum(1 for c in items.get(k, []) if c) for k in ("card", "question", "exercise")}
            count = {k: len(items.get(k, [])) for k in ("card", "question", "exercise")}
            recall = count["card"] + count["question"]
            known_share = (known["card"] + known["question"]) / recall if recall else 0.0
            lesson = self.lessons.for_topic(t["id"]) if self.lessons is not None else None
            steps = len(((lesson or {}).get("content") or {}).get("steps") or [])
            lesson_share = 1.0 if lesson and lesson["finished_at"] else (lesson["at"] / steps if lesson and steps else 0.0)
            learned = max(known_share, lesson_share)
            n = words(t["body"])
            learn_full = n / pace["read_wpm"]["value"]
            card, question, exercise = (pace["card_min"]["value"], pace["question_min"]["value"],
                                        pace["exercise_min"]["value"])
            practise_full = count["card"] * card * ROUNDS + count["question"] * question + count["exercise"] * exercise
            learn = learn_full * (1 - learned)
            practise = ((count["card"] - known["card"]) * card * ROUNDS + (count["question"] - known["question"]) * question
                        + (count["exercise"] - known["exercise"]) * exercise)
            full += learn_full + practise_full
            rows.append({"id": t["public_id"], "title": t["title"], "words": n, "cards": count["card"],
                         "questions": count["question"], "exercises": count["exercise"],
                         "known": known["card"] + known["question"] + known["exercise"],
                         "items": count["card"] + count["question"] + count["exercise"],
                         "lesson": None if lesson is None else "done" if lesson["finished_at"] else
                         f"{lesson['at']}/{steps}" if steps else "writing",
                         "learn_min": round(learn), "practise_min": round(practise),
                         "_learn": learn, "_practise": practise, "_full": learn_full + practise_full,
                         "_share": known_share})
        length = data["exam_min"]
        mocks = MOCKS.get(target["kind"], 2)
        taken = data["mocks_taken"]
        mock_min = max(0, mocks - taken) * length * MOCK_FACTOR
        review = max(REVIEW_FLOOR, REVIEW_SHARE * full) if rows else 0.0
        return {"key": key, "chosen": chosen, "topics": rows, "full": full,
                "learn": sum(r["_learn"] for r in rows), "practise": sum(r["_practise"] for r in rows),
                "mocks": mock_min if rows else 0.0, "review": review,
                "mock": {"count": mocks, "taken": min(taken, mocks), "minutes_each": length}}

    def _course_data(self, cid: int) -> dict:
        topics = [t for t in self.notebook.topics(cid) if t["body"].strip()] if self.notebook else []
        items: dict[str, dict[str, list[bool]]] = {}
        kinds: dict[str, str] = {}
        if self.quizzes is not None and topics:
            for kind, bank in (("question", self.quizzes.bank(cid)), ("card", self.quizzes.cards(cid)),
                               ("exercise", self.quizzes.exercise_bank(cid))):
                for q in bank:
                    items.setdefault(q["topic"], {}).setdefault(kind, []).append(
                        bool(q["last"] and q["last"]["known"]))  # by the schedule: not due, not missed
                    kinds[q["qkey"]] = kind
        intro = self.notebook.intro(cid) if self.notebook else None
        mocks = self.notebook.mocks(cid) if self.notebook else []
        length = (exam_minutes(intro["exam"] if intro else None)
                  or next((m["minutes"] for m in mocks if m["minutes"]), None) or MOCK_MIN)
        taken = self.conn.execute("SELECT COUNT(*) FROM quizzes WHERE course_id = ? AND kind = 'mock' AND "
                                  "finished_at IS NOT NULL", (cid,)).fetchone()[0] if self.quizzes else 0
        return {"topics": topics, "items": items, "kinds": kinds, "exam_min": length, "mocks_taken": taken,
                "past_exams": any(m["source"] for m in mocks),
                "credits": self._credits(cid, intro)}

    def _credits(self, cid: int, intro: dict | None) -> tuple[float, str] | None:
        """The course's credits and where they're from: Esse3's transcript, else the notebook's Introduction."""
        try:
            row = self.conn.execute("SELECT credits FROM esse3_courses WHERE course_id = ? AND credits > 0 "
                                    "ORDER BY year DESC LIMIT 1", (cid,)).fetchone()
        except sqlite3.OperationalError:  # no Esse3 here
            row = None
        if row:
            return row[0], "esse3"
        found = credits(f"{intro['exam'] or ''}\n{intro['body'] or ''}") if intro else None
        return (found, "notes") if found else None

    def _by_credits(self, c: dict, work: dict, data: dict, mine: list, notes: float, now: datetime) -> dict | None:
        """The ceiling the credits set on what's left of the user's own study for the target: 25 h a credit less the lectures in
        the timetable (held and to come), the part of it the target's topics are (by words), less what's done: the
        larger of the notes' work done and the focus time logged since the first lecture."""
        if not data["credits"] or not work["topics"]:
            return None
        cr, source = data["credits"]
        lectures = sum((e.end - e.start).total_seconds() / 60 for e in mine)
        own = max(0.0, cr * CREDIT_H * 60 - lectures)
        every = sum(words(t["body"]) for t in data["topics"])
        share = sum(r["words"] for r in work["topics"]) / every if work["chosen"] and every else 1.0
        studied = 0
        if self.focus is not None and mine:
            first = min(e.start for e in mine)
            studied = sum(x["minutes"] for x in self.focus.totals(first, now) if x["course_id"] == c["id"])
        base = own * share
        notes_left = (work["learn"] + work["practise"]) / work["full"] if work["full"] else 1.0
        left = min(base * notes_left, max(0.0, base - studied * share))
        return {"credits": cr, "from": source, "total_min": round(cr * CREDIT_H * 60), "lectures_min": round(lectures),
                "own_min": round(own), "share": round(share, 2), "studied_min": studied, "left_min": round(left),
                "notes_min": round(notes), "applied": notes > left}

    async def _planner(self, today: date) -> list:
        """The UniTo planner's lectures from COURSE_RANGE back to COURSE_RANGE ahead (cancelled ones and exams
        left out), read once a day; the last read, or none, when it fails."""
        if self.timetable is None:
            return []
        if self._uni and self._uni[0] == today:
            return self._uni[1]
        from .study import COURSE_RANGE
        from .unitimetable import MAX_DAYS
        start, end = today - COURSE_RANGE, today + COURSE_RANGE
        spans = []
        while start <= end:
            spans.append((start, min(end, start + timedelta(days=MAX_DAYS - 1))))
            start += timedelta(days=MAX_DAYS)
        try:
            found = await asyncio.gather(*(self.timetable.lectures(a, b) for a, b in spans))
        except Exception:
            log.warning("exam plan: couldn't read UniTo's timetable; the calendar's lectures count", exc_info=True)
            return self._uni[1] if self._uni else []
        out = [l for part in found for l in part if not l.cancelled and "esam" not in l.kind.casefold()]
        self._uni = (today, out)
        return out

    async def _compute(self, now: datetime) -> dict:
        local = now.astimezone(self.tz)
        today = local.date()
        s = self.settings()
        courses = await self.study.courses()
        lectures = self.study._lectures(await self.study._events())
        uni: dict[int, list] = {}
        if planned := await self._planner(today):
            from .unitimetable import course_for
            names = {c["name"]: c["id"] for c in courses}
            for l in planned:
                if (name := course_for(l.name, list(names))) is not None:
                    uni.setdefault(names[name], []).append(l)
        ahead = [e.start.astimezone(self.tz).date() for e in [*lectures, *(l for ls in uni.values() for l in ls)]
                 if e.start > now]
        season_from = max(ahead) + timedelta(days=1) if ahead else (today if lectures else None)
        data = {c["id"]: self._course_data(c["id"]) for c in courses}
        pace = self._pace({cid: d["kinds"] for cid, d in data.items()}, now)

        targets, undated = [], []
        for c in courses:
            found = self._targets(c, today, s)
            if found is None:
                undated.append({"course": c["id"], "name": c["name"]})
                continue
            target, fallback = found
            work = self._work(c, target, s, pace, data[c["id"]])
            mine = (uni.get(c["id"])  # the timetable's lectures, else the calendar's
                    or [e for e in lectures if _name(e.title).casefold() == c["name"].casefold()])
            held = sum(1 for e in mine if e.end <= now)
            left = sum(1 for e in mine if e.start > now and e.start.astimezone(self.tz).date() < target["date"])
            stretch = (held + left) / held if held and left else 1.0
            phases = [("learn", work["learn"] * stretch), ("practise", work["practise"] * stretch),
                      ("mocks", work["mocks"]), ("review", work["review"] * stretch)]
            notes = sum(m for _, m in phases)
            by_credits = self._by_credits(c, work, data[c["id"]], mine, notes, now)
            if by_credits and by_credits["applied"]:  # the notes count more than the credits allow: cut down
                k = by_credits["left_min"] / notes
                phases = [(p, m * k) for p, m in phases]
            targets.append({"course": c, "target": target, "fallback": fallback, "work": work, "phases": phases,
                            "mine": mine, "by_credits": by_credits,
                            "need": round(sum(m for _, m in phases)), "held": held, "left": left, "stretch": stretch,
                            "data": data[c["id"]]})
        targets.sort(key=lambda t: (t["target"]["date"], t["course"]["name"]))
        if self.quizzes is not None:  # the spaced-repetition schedule tightens before each (srs.py)
            self.quizzes.targets = {t["course"]["id"]: (t["target"]["date"], set(t["work"]["chosen"] or []) or None)
                                    for t in targets}

        last = max([t["target"]["date"] for t in targets] + [t["fallback"]["date"] for t in targets if t["fallback"]],
                   default=today)
        room = await self._days(today, last, now, s, season_from)
        left_room = dict(room)
        out_targets, today_blocks = [], []
        self._laid = []
        for i, t in enumerate(targets):
            when = t["target"]["date"]
            days = [d for d in sorted(left_room) if d < when]
            free = sum(left_room[d] for d in days)
            fallback_free = (sum(left_room[d] for d in left_room if d < t["fallback"]["date"])
                             if t["fallback"] else None)
            alloc = spread(left_room, days, t["need"])
            for d, m in alloc.items():
                left_room[d] -= m
            laid = lay(alloc, t["phases"])
            self._laid.append((t, laid))
            planned = sum(alloc.values())
            short = max(0, t["need"] - planned)
            status = ("empty" if not t["work"]["topics"] else "short" if short > 0
                      else "tight" if free and t["need"] > TIGHT * free else "fits")
            item = self._target_json(t, alloc, laid, free, planned, short, status, fallback_free, now, today)
            item["warnings"] += self._warnings(t, targets[:i], short, fallback_free, today)
            out_targets.append(item)
            if today in laid:
                today_blocks += self._today(t, laid[today])
        self._history(today, out_targets, targets)
        return {"computed_at": local.replace(microsecond=0).isoformat(), "today": today_blocks,
                "targets": out_targets, "undated": undated, "settings": self.caps(),
                "season_from": season_from.isoformat() if season_from else None,
                "assumptions": {**{k: v for k, v in pace.items() if k != "runs"}, "runs": pace["runs"],
                                "card_rounds": ROUNDS, "mock_factor": MOCK_FACTOR, "review_share": REVIEW_SHARE}}

    def _target_json(self, t: dict, alloc, laid, free, planned, short, status, fallback_free, now, today) -> dict:
        c, target, work = t["course"], t["target"], t["work"]
        spans = []
        for p in PHASES:
            on = sorted(d for d, ps in laid.items() if ps.get(p))
            minutes = round(dict(t["phases"])[p])
            if minutes:
                spans.append({"phase": p, "minutes": minutes, "planned": sum(laid[d][p] for d in on),
                              "from": on[0].isoformat() if on else None, "to": on[-1].isoformat() if on else None})
        studied = 0
        if self.focus is not None:
            week = now - timedelta(days=7)
            studied = sum(x["minutes"] for x in self.focus.totals(week, now) if x["course_id"] == c["id"])
        fb = t["fallback"]
        return {
            "course": c["id"], "name": c["name"], "what": target["what"], "kind": target["kind"],
            "date": target["date"].isoformat(), "time": target["time"], "from": target["from"],
            "date_id": target["date_id"], "key": work["key"], "topics_chosen": work["chosen"],
            "days_left": (target["date"] - today).days,
            "fallback": {"date": fb["date"].isoformat(), "what": fb["what"],
                         "fits": fallback_free is not None and fallback_free >= t["need"]} if fb else None,
            "need_min": t["need"], "free_min": free, "planned_min": planned, "short_min": short, "status": status,
            "phases": spans,
            "days": [{"date": d.isoformat(), "minutes": alloc[d], "phases": laid.get(d, {})} for d in sorted(alloc)],
            "topics": [{k: v for k, v in r.items() if not k.startswith("_")} for r in work["topics"]],
            "mocks": work["mock"], "lectures_left": t["left"], "lectures_held": t["held"],
            "stretch": round(t["stretch"], 2), "studied_week_min": studied, "warnings": [],
            "by_credits": t["by_credits"],
        }

    def _warnings(self, t: dict, earlier: list[dict], short: int, fallback_free: int | None, today: date) -> list[str]:
        c, target, data, work = t["course"], t["target"], t["data"], t["work"]
        when = f"{target['date']:%a %d %b}"
        out = []
        if not work["topics"]:
            return [f"No notes for {c['name']} yet: nothing to count the hours from."]
        if short:
            line = f"Short by {_hours(short)} before the {target['what']} on {when}."
            if t["fallback"]:
                fb = t["fallback"]
                line += (f" The {fb['what']} on {fb['date']:%d %b} would fit." if fallback_free is not None
                         and fallback_free >= t["need"] else f" The {fb['what']} on {fb['date']:%d %b} wouldn't either.")
            out.append(line)
        for e in earlier:
            gap = (target["date"] - e["target"]["date"]).days
            if gap <= CLOSE:
                out.append(f"{e['course']['name'].capitalize()}'s {e['target']['what']} is {gap} day"
                           f"{'' if gap == 1 else 's'} before: learn {c['name']}'s theory before it.")
        if work["mocks"] and not data["past_exams"]:
            out.append("No past exams yet: the mocks are Professor's own.")
        if b := t["by_credits"]:
            cr = f"{b['credits']:g} credits"
            own = (f"{cr} are {_hours(b['total_min'])} of work; less {_hours(b['lectures_min'])} of lectures, "
                   f"{_hours(b['own_min'])} are your own study")
            if b["applied"]:
                part = f", {round(b['share'] * 100)}% of it for these topics" if b["share"] < 1 else ""
                out.append(f"The notes add up to {_hours(b['notes_min'])}, more than the credits allow: {own} at "
                           f"most{part}, {_hours(b['left_min'])} still to do. The plan counts that.")
        changes = self.notebook.changes(c["id"], utcnow() - timedelta(days=120)) if self.notebook else []
        if changes:
            since = datetime.fromisoformat(changes[0]["at"])
            behind = [e for e in t["mine"] if since < e.start and e.end <= utcnow()]
            if len(behind) >= 3:
                out.append(f"{len(behind)} lectures since the notes last changed: the hours count only what's written.")
        if target["from"] == "expected":
            out.append("The date is your guess: it's replaced when the course or the Exam calendar has the real one.")
        return out

    def _today(self, t: dict, phases: dict[str, int]) -> list[dict]:
        """Today's blocks for a target: the phase, the topic to take, the minutes."""
        rows = t["work"]["topics"]
        out = []
        for p in PHASES:
            if not (m := phases.get(p)):
                continue
            topic = None
            if p == "learn":
                topic = next((r for r in rows if r["_learn"] >= 1), None)
            elif p in ("practise", "review"):
                pool = [r for r in rows if r["items"]]
                topic = (max(pool, key=lambda r: r["_practise"]) if p == "practise" and pool
                         else min(pool, key=lambda r: r["_share"]) if pool else None)
            out.append({"course": t["course"]["id"], "name": t["course"]["name"], "phase": p, "minutes": m,
                        "topic": {"id": topic["id"], "title": topic["title"]} if topic else None})
        return out

    def _history(self, today: date, items: list[dict], targets: list[dict]) -> None:
        for item, t in zip(items, targets):
            self.conn.execute(
                "INSERT INTO exam_plan_history (day, course_id, target, need_min, topics, lectures) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(day, course_id) DO UPDATE SET target = excluded.target, "
                "need_min = excluded.need_min, topics = excluded.topics, lectures = excluded.lectures",
                (today.isoformat(), item["course"], item["date"], item["need_min"], len(t["work"]["topics"]), t["held"]))
            rows = self.conn.execute(
                "SELECT day, need_min, topics, lectures FROM exam_plan_history WHERE course_id = ? AND target = ? "
                "ORDER BY day", (item["course"], item["date"])).fetchall()
            item["history"] = [{"date": r[0], "need_min": r[1]} for r in rows]
            week = (today - timedelta(days=7)).isoformat()
            before = [r for r in rows if r[0] <= week]
            item["moved"] = ({"since": before[-1][0], "minutes": item["need_min"] - before[-1][1],
                              "topics": len(t["work"]["topics"]) - before[-1][2], "lectures": t["held"] - before[-1][3]}
                             if before else None)
        self.conn.execute("DELETE FROM exam_plan_history WHERE day < ?",
                          ((today - timedelta(days=HISTORY_DAYS)).isoformat(),))
        self.conn.commit()

    # -- a day's blocks and a week of review sessions ------------------------------------------------------------

    @staticmethod
    def day_blocks(plan: dict, d: date) -> list[dict]:
        """The study a day holds, a row per course: {course, name, what, date, minutes, phases, topics}; today's
        with the topics to take."""
        out = []
        for t in plan["targets"]:
            day = next((x for x in t["days"] if x["date"] == d.isoformat()), None)
            if not day or not day["minutes"]:
                continue
            topics = [b["topic"]["title"] for b in plan["today"] if b["course"] == t["course"] and b["topic"]
                      and d.isoformat() == plan["computed_at"][:10]]
            out.append({"course": t["course"], "name": t["name"], "what": t["what"], "date": t["date"],
                        "minutes": day["minutes"], "phases": {p: round(day["phases"][p]) for p in PHASES
                                                              if round(day["phases"].get(p, 0))},
                        "topics": list(dict.fromkeys(topics))})
        return out

    async def week(self, start: date | None = None, now: datetime | None = None) -> tuple[list[dict], list[str]]:
        """The blocks of the 7 days from `start` (today when left out; days gone are skipped), placed in each day's
        free time as review sessions to propose (plans.py): a course's day in one sitting where a gap holds it, else
        split around events (no piece under 25 min), less a review session already in the calendar for it that day.
        Returns the items {title, start, end, calendar, course_id, topics, notes} and the short targets' warnings."""
        now = now or utcnow()
        await self.plan(now, fresh=True)
        today = now.astimezone(self.tz).date()
        start = max(start or today, today)
        window = {start + timedelta(days=i) for i in range(7)}
        gaps = {d: list(g) for d, g in self._gaps.items()}
        for d, held in self._held.items():  # sessions already there are taken time
            for _, s0, e0 in held:
                gaps[d] = _cut(gaps.get(d, []), s0, e0 + BUSY_GAP)
        items, warnings = [], []
        for t, laid in self._laid:
            name = t["course"]["name"][:1].upper() + t["course"]["name"][1:]
            picker = _Topics(t["work"]["topics"], t["work"]["review"])
            if t["work"]["topics"] and any(laid.get(d) for d in window) and (short := max(
                    0, t["need"] - sum(sum(p.values()) for p in laid.values()))):
                warnings.append(f"{name} is short by {_hours(short)} before the {t['target']['what']} on "
                                f"{t['target']['date']:%a %d %b}.")
            for d in sorted(laid):
                if d > max(window):
                    break
                phases = {p: round(laid[d][p]) for p in PHASES if round(laid[d].get(p, 0))}
                topics = picker.take(phases)  # earlier days use topics up, so the week moves through the course
                if d not in window:
                    continue
                minutes = sum(phases.values()) - sum(
                    int((e0 - s0).total_seconds() // 60) for c, s0, e0 in self._held.get(d, [])
                    if c == t["course"]["name"].casefold())
                if minutes < MIN_PIECE:
                    continue
                what = ", ".join(f"{p} {m} min" for p, m in phases.items())
                notes = (f"From the exam plan, before the {t['target']['what']} on {t['target']['date']:%a %d %b}: "
                         f"{what}." + ("\nTopics: " + "; ".join(topics) if topics else ""))
                for s0, e0 in _place(gaps, d, minutes):
                    items.append({"title": REVIEW_PREFIX + name, "start": f"{s0:%Y-%m-%dT%H:%M}",
                                  "end": f"{e0:%Y-%m-%dT%H:%M}", "calendar": self.study.study_calendar,
                                  "course_id": t["course"]["id"], "topics": topics, "notes": notes})
        items.sort(key=lambda i: i["start"])
        return items, warnings

    # -- text for Professor and the objectives planner -----------------------------------------------------------

    @staticmethod
    def line(item: dict) -> str:
        parts = [f"{p['phase']} {_hours(p['minutes'])}" for p in item["phases"]]
        when = date.fromisoformat(item["date"])
        source = {"calendar": "Exam calendar", "course": "the course's dates", "expected": "the user's guess"}
        out = (f"{item['name']}: {item['what']} {when:%a %d %b} (in {item['days_left']} days, from "
               f"{source[item['from']]}): needs {_hours(item['need_min'])}")
        if parts:
            out += f" ({', '.join(parts)})"
        if (b := item.get("by_credits")) and b["applied"]:
            out += (f", cut to the credits' ceiling ({b['credits']:g} CFU less {_hours(b['lectures_min'])} of lectures: "
                    f"{_hours(b['left_min'])} left); the notes alone {_hours(b['notes_min'])}")
        out += f"; {_hours(item['free_min'])} free before it"
        out += {"fits": ": fits", "tight": ": tight", "empty": "",
                "short": f": SHORT by {_hours(item['short_min'])}"}[item["status"]]
        if item["moved"] and abs(item["moved"]["minutes"]) >= 30:
            out += f"; {'+' if item['moved']['minutes'] > 0 else '−'}{_hours(abs(item['moved']['minutes']))} in a week"
        out += f"; studied {_hours(item['studied_week_min'])} in the last 7 days."
        return out

    def text(self, plan: dict, course_id: int | None = None) -> str:
        items = [t for t in plan["targets"] if course_id is None or t["course"] == course_id]
        lines = []
        for t in items:
            lines.append(self.line(t))
            lines += [f"  - {w}" for w in t["warnings"]]
            if t["phases"]:
                lines.append("  - Phases: " + "; ".join(
                    f"{p['phase']} {p['from']} to {p['to']}" for p in t["phases"] if p["from"]))
        today = [b for b in plan["today"] if course_id is None or b["course"] == course_id]
        if today:
            lines.append("Today's blocks: " + "; ".join(
                f"{b['name']} {b['phase']} {b['minutes']} min" + (f" ({b['topic']['title']})" if b["topic"] else "")
                for b in today))
        undated = [u for u in plan["undated"] if course_id is None or u["course"] == course_id]
        if undated:
            lines.append("No exam date (not planned; the user can set a likely one on the plan's page): "
                         + ", ".join(u["name"] for u in undated))
        caps = plan["settings"]
        lines.append(f"Daily caps: {caps['term_cap_min']} min in term, {caps['season_cap_min']} min from "
                     f"{plan['season_from'] or 'the end of lectures'}.")
        return "\n".join(lines) if items or undated else "No courses to plan."


MIN_PIECE = 25  # minutes: no review session shorter (unless the whole block is)
QUARTER = 15  # sessions start on the quarter hour
BREAK = timedelta(minutes=15)  # between two sessions in a row


def _cut(gaps: list[tuple[datetime, datetime]], a: datetime, b: datetime) -> list[tuple[datetime, datetime]]:
    """The free stretches less [a, b)."""
    out = []
    for g0, g1 in gaps:
        if b <= g0 or a >= g1:
            out.append((g0, g1))
            continue
        if a > g0:
            out.append((g0, a))
        if b < g1:
            out.append((b, g1))
    return out


def _place(gaps: dict[date, list[tuple[datetime, datetime]]], d: date, minutes: int) -> list[tuple[datetime, datetime]]:
    """Sessions for `minutes` of study on day `d`, taken out of its free stretches: the first that holds it all, else
    pieces of at least MIN_PIECE in order; what doesn't fit is left out (the plan counted it as free, rounded)."""

    def at_quarter(t: datetime) -> datetime:
        t = t.replace(second=0, microsecond=0)
        extra = (-t.minute) % QUARTER
        return t + timedelta(minutes=extra)

    def room(g: tuple[datetime, datetime]) -> int:
        return max(0, int((g[1] - at_quarter(g[0])).total_seconds() // 60) // STEP * STEP)

    free = gaps.get(d, [])
    whole = next((g for g in free if room(g) >= minutes), None)
    out = []
    if whole is not None:
        s0 = at_quarter(whole[0])
        out.append((s0, s0 + timedelta(minutes=minutes)))
    else:
        left = minutes
        for g in free:
            piece = min(left, room(g))
            if piece < min(MIN_PIECE, left):
                continue
            s0 = at_quarter(g[0])
            out.append((s0, s0 + timedelta(minutes=piece)))
            left -= piece
            if left < MIN_PIECE:
                break
    for s0, e0 in out:
        gaps[d] = _cut(gaps.get(d, []), s0, e0 + BREAK)
    return out


class _Topics:
    """Which topics a run of days takes, using them up: learning goes through the topics in order, practice the
    ones with most left, the review the weakest, a few at a time."""

    def __init__(self, rows: list[dict], review: float):
        self.learn = [[r["title"], r["_learn"]] for r in rows if r["_learn"] >= 1]
        self.practise = [[r["title"], r["_practise"]] for r in sorted(rows, key=lambda r: -r["_practise"])
                         if r["_practise"] >= 1]
        weak = sorted(rows, key=lambda r: r["_share"])
        self.review = [[r["title"], review / len(rows)] for r in weak] if rows else []

    @staticmethod
    def _use(queue: list[list], minutes: float) -> list[str]:
        out = []
        while minutes > 0 and queue:
            item = queue[0]
            used = min(item[1], minutes)
            item[1] -= used
            minutes -= used
            out.append(item[0])
            if item[1] < 1:
                queue.pop(0)
        return out

    def take(self, phases: dict[str, int]) -> list[str]:
        out = []
        out += self._use(self.learn, phases.get("learn", 0))
        out += self._use(self.practise, phases.get("practise", 0))
        out += self._use(self.review, phases.get("review", 0))
        return list(dict.fromkeys(out))[:4]


def week_message(items: list[dict], warnings: list[str]) -> str:
    """What Professor says above the week's card."""
    by: dict[str, int] = {}
    for i in items:
        minutes = int((datetime.fromisoformat(i["end"]) - datetime.fromisoformat(i["start"])).total_seconds() // 60)
        by[i["title"][len(REVIEW_PREFIX):]] = by.get(i["title"][len(REVIEW_PREFIX):], 0) + minutes
    total = sum(by.values())
    out = (f"Your study week from the exam plan: {len(items)} session{'s' if len(items) != 1 else ''}, "
           f"{_hours(total)} in all (" + ", ".join(f"{n} {_hours(m)}" for n, m in by.items()) + "). "
           "Tap Add to put them in your calendar, or leave out the ones that don't suit; moving one there is fine, "
           "I follow it.")
    if warnings:
        out += "\n\n" + " ".join(warnings)
    return out


class WeekProposer:
    """Each Sunday from 17:00 the coming week's blocks go to Professor's Study week chat as proposed review sessions
    (the week card: added only on Add), with a push. Once a week; nothing when there's nothing to study."""

    def __init__(self, store: ExamPlan, plans, agent, push=None):
        self.store, self.plans, self.agent, self.push = store, plans, agent, push

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:
                log.exception("study week tick failed")
            await asyncio.sleep(WEEK_TICK)

    def chat(self) -> str:
        """Professor's Study week chat, made the first time; made again if it was deleted."""
        s = self.store.settings()
        db = self.agent.db
        if s.get("chat") and db.app_conversation(s["chat"]) is not None:
            return s["chat"]
        row = db.new_app_conversation("professor")
        db.set_conversation_title(row["id"], "Study week")
        s["chat"] = row["public_id"]
        self.store._save(s)
        return row["public_id"]

    async def tick(self, now: datetime | None = None) -> dict | None:
        now = now or utcnow()
        local = now.astimezone(self.store.tz)
        if local.weekday() != 6 or local.time() < WEEK_AT:
            return None
        monday = local.date() + timedelta(days=1)
        s = self.store.settings()
        if s.get("week_proposed") == monday.isoformat():
            return None
        s["week_proposed"] = monday.isoformat()  # once, whatever happens next: no retry every 10 min
        self.store._save(s)
        items, warnings = await self.store.week(monday, now)
        if not items:
            log.info("study week: nothing to propose for the week of %s", monday)
            return None
        chat = self.chat()
        plan = self.plans.propose(chat, "professor", items)
        text = week_message(items, warnings)
        note = (f"[The exam plan's week from {monday:%a %d %b}, proposed as review sessions (plan "
                f"{plan['public_id']}); they're not in the calendar until the user taps Add.]")
        await self.agent.post(chat, note, text, [{"type": "events", "events": self.plans.card_items(plan)}])
        if self.push is not None:
            try:
                await self.push.send_message(chat, "Professor · Study week", text.split("). ")[0][:178] + ").")
            except Exception:
                log.exception("couldn't push the study week")
        return plan


def examplan_tools(store: ExamPlan, study, plans=None, where=None) -> list[Tool]:
    """`plans` and `where()` (the chat of the turn and the agent) for propose_study_week."""
    async def study_plan(course: str | None = None) -> str:
        cid = None
        if course:
            c = study.course_by_name(course)
            if c is None and course.isdigit():
                c = study.course(int(course))
            if c is None:
                raise ValueError(f"no course {course!r}; see list_courses")
            cid = c["id"]
        return store.text(await store.plan(), cid)

    async def propose_study_week(start: str | None = None) -> str:
        if plans is None or plans.cal is None:
            raise RuntimeError("There's no calendar on this server.")
        day = date.fromisoformat(start) if start else None
        items, warnings = await store.week(day)
        if not items:
            return "The exam plan has no study in those 7 days (no dated exam with work left, or no free time)."
        conversation, agent = where() if where else (None, "professor")
        plan = plans.propose(conversation, agent, items)
        lines = "\n".join(f"- {plans.line(i)}" for i in plan["items"])
        return ToolOutput(f"Proposed the exam plan's week as plan {plan['public_id']} ({len(items)} review sessions). "
                          f"Not in the calendar yet: the user adds them with a tap on the card under your reply.\n"
                          f"{lines}" + ("\nShort: " + " ".join(warnings) if warnings else ""),
                          {"type": "events", "events": plans.card_items(plan)})

    tools = [Tool("propose_study_week",
                  "Put the exam plan's next 7 days on the week card as proposed review sessions, placed in the free "
                  "time around the calendar: what \"plan my week\" or \"put my study in the calendar\" means. No "
                  "guessing: the hours and topics come from study_plan. The user adds them with a tap.",
                  {"type": "object", "properties": {"start": {
                      "type": "string", "description": "The first day, YYYY-MM-DD; today when left out"}},
                   "required": [], "additionalProperties": False}, propose_study_week)] if plans is not None else []
    return tools + [Tool("study_plan",
                 "The exam plan: for each course's next exam or mid-term, the hours still needed (learn, practise, "
                 "mocks, review), the free hours before it, whether it fits, today's blocks and the warnings. Worked "
                 "out from the notebook, the answers so far and the calendar, no guessing. Read it before planning "
                 "review or focus sessions.",
                 {"type": "object", "properties": {"course": {"type": "string",
                                                              "description": "A course name; all when left out"}},
                  "required": [], "additionalProperties": False}, study_plan)]
