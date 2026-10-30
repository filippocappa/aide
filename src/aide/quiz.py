"""Practice exams and quizzes from a course's notebook (#4). The contract is docs/API.md, "Practice exams" and
"Quizzes and review sessions".

The questions are the notebook's own: the multiple-choice questions at the end of each topic page, whose answer
keys were checked when the page was written (notebook.check_answers), and, in a quiz, its flashcards. A practice
exam costs no model call.

Picking is the spaced-repetition part: a question last answered wrong or left blank comes back first, then those
never seen, then the ones answered right longest ago, spread over the topics. Scoring is the exam's: a right answer
+1, a wrong one −0.25, a blank 0. When a practice exam is finished, Professor posts the score and the weakest
topics in the course chat, so the user can go through them there.

A quiz (`kind` "chat") is Professor asking in a chat, by text or by voice, one question at a time: the user's answer
is recorded as it comes (a flashcard's as right or wrong, judged by Professor), so stopping halfway loses nothing.
Its answers count for the next pick like a practice exam's, but it isn't one (objectives count practice exams only).

A mock exam (`kind` "mock") is a paper notebook.py wrote like the real exam (mock_exams), taken in the app: its time
and its scoring are the exam's, and it can have open questions, answered in text or with photos of the work on paper.
The multiple choice is scored at once; the open answers are marked by the notebook's `grade` job, and until then the
score says `grading`. Objectives count mocks as practice exams.
"""

import hashlib
import json
import math
import random
import re
import secrets
import sqlite3
import unicodedata
from datetime import datetime

from .db import utcnow
from .notebook import NotebookStore, exercises, max_points, mcqs, mock_title, parse_question

SCHEMA = """
CREATE TABLE IF NOT EXISTS quizzes (
    id          INTEGER PRIMARY KEY,
    public_id   TEXT NOT NULL UNIQUE,  -- x_…
    course_id   INTEGER NOT NULL,
    minutes     INTEGER,               -- the time allowed, or NULL when untimed
    questions   TEXT NOT NULL,         -- JSON: the questions as asked, with keys (a later rewrite doesn't change them)
    answers     TEXT,                  -- JSON: {"1": "B", "2": null}, once finished
    score       REAL,
    started_at  TEXT NOT NULL,
    finished_at TEXT,
    kind        TEXT NOT NULL DEFAULT 'exam',  -- exam: the app's practice exam; chat: Professor asking; mock
    mock        TEXT,                  -- a mock exam's id (m_…)
    scoring     TEXT,                  -- JSON: a mock's {"right", "wrong", "blank"}; NULL: RIGHT and WRONG
    checked     TEXT                   -- JSON: answers checked one at a time while taking it, {"3": "B"}: final
);
CREATE TABLE IF NOT EXISTS quiz_answers (
    id          INTEGER PRIMARY KEY,
    course_id   INTEGER NOT NULL,
    qkey        TEXT NOT NULL,     -- the question, by its text: numbers change when a page is rewritten
    answer      TEXT,              -- NULL: left blank
    correct     INTEGER NOT NULL,
    answered_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS quiz_answers_key ON quiz_answers (course_id, qkey, answered_at);
"""

RIGHT, WRONG = 1.0, -0.25  # points, as in the exam
PROFESSOR = {"kind": "professor", "name": None}  # where a notebook question or flashcard comes from
EXERCISE_RUBRIC = "The course's solution: full marks for the same result with sound working, half for the right method."
MOST = 60  # questions in one practice exam
ANSWER_CHARS = 20_000  # an open answer's text, at most
ANSWER_PHOTOS = 4  # photos of the work on paper, at most, for an open answer
QUIZ_MOST = 30  # in a quiz
STYLES = ("mixed", "questions", "cards")  # what a quiz asks: both, multiple choice only, flashcards only
_ID = re.compile(r"^x_[0-9a-f]{12}$")
_PHOTO = re.compile(r"^p_[0-9a-f]{16}$")


class QuizStore:
    def __init__(self, notebook: NotebookStore, rng: random.Random | None = None):
        self.notebook = notebook
        self.study = notebook.study
        self.conn: sqlite3.Connection = notebook.conn
        self.conn.executescript(SCHEMA)
        have = {r["name"] for r in self.conn.execute("PRAGMA table_info(quizzes)")}
        for column, sql in (("kind", "kind TEXT NOT NULL DEFAULT 'exam'"),  # from before quizzes
                            ("mock", "mock TEXT"), ("scoring", "scoring TEXT"),  # from before mock exams
                            ("checked", "checked TEXT")):  # from before answers shown after each question
            if column not in have:
                self.conn.execute(f"ALTER TABLE quizzes ADD COLUMN {sql}")
        self.rng = rng or random.Random()

    # -- the questions -----------------------------------------------------------------

    def _last(self, course_id: int) -> dict[str, dict]:
        """What the user last did with each question they've seen, by qkey."""
        return {r["qkey"]: dict(r) for r in self.conn.execute(
            # SQLite takes the bare columns from the row with the MAX: the latest answer.
            "SELECT qkey, correct, MAX(answered_at) AS answered_at, COUNT(*) AS seen FROM quiz_answers "
            "WHERE course_id = ? GROUP BY qkey", (course_id,))}

    def _topics(self, course_id: int, topics: list[str] | None) -> list[dict]:
        return [t for t in self.notebook.topics(course_id) if t["body"] and (not topics or t["public_id"] in topics)]

    def bank(self, course_id: int, topics: list[str] | None = None) -> list[dict]:
        """Every question in the course's written topics (or those listed), with what the user last did with it."""
        last = self._last(course_id)
        out = []
        for t in self._topics(course_id, topics):
            for n, q in mcqs(t["body"]).items():
                if parsed := parse_question(q):
                    key = qkey(parsed["text"])
                    out.append(parsed | {"qkey": key, "topic": t["public_id"], "topic_title": t["title"],
                                         "last": last.get(key)})
        return out

    def cards(self, course_id: int, topics: list[str] | None = None) -> list[dict]:
        """Every flashcard in the course's written topics (or those listed), as a question to answer in words: its
        answer is the key, and the user's answer is right or wrong."""
        last = self._last(course_id)
        out = []
        for t in self._topics(course_id, topics):
            for q, a in json.loads(t["cards"]):
                key = qkey(q)
                out.append({"type": "card", "text": q, "key": a, "explanation": "", "qkey": key,
                            "topic": t["public_id"], "topic_title": t["title"], "last": last.get(key)})
        return out

    def exercise_bank(self, course_id: int) -> list[dict]:
        """Every exercise in the course's exercise sets, as an open question worth a point: the course's own (an
        exercise sheet, a past exam), its solution the model answer."""
        last = self._last(course_id)
        topics = {t["id"]: t for t in self.notebook.topics(course_id)}
        out = []
        for e in self.notebook.exercise_sets(course_id):
            t = topics.get(e["topic_id"])
            for x in exercises(e["body"]) if t else []:
                solution = x["block"].partition("> [!success]")[2]
                solution = "\n".join(re.sub(r"^>\s?", "", line) for line in solution.splitlines()[1:]).strip()
                if not x["text"] or not solution:
                    continue
                key = qkey(x["text"])
                out.append({"type": "open", "points": 1.0, "text": x["text"], "model_answer": solution,
                            "rubric": EXERCISE_RUBRIC, "qkey": key, "topic": t["public_id"], "topic_title": t["title"],
                            "source": {"kind": "course", "name": _source_name(x["source"])} if x["source"]
                            else PROFESSOR, "last": last.get(key)})
        return out

    def pick(self, bank: list[dict], count: int) -> list[dict]:
        """`count` questions: wrong or blank last time first, then never seen, then right longest ago; no topic
        more than its share until the others run out."""
        def order(q):
            last = q["last"]
            if last is None:
                return 1, "", self.rng.random()
            return (0 if not last["correct"] else 2), last["answered_at"], self.rng.random()

        ranked = sorted(bank, key=order)
        share = math.ceil(count / max(1, len({q["topic"] for q in bank})))
        picked, per_topic = [], {}
        for q in ranked:
            if len(picked) < count and per_topic.get(q["topic"], 0) < share:
                picked.append(q)
                per_topic[q["topic"]] = per_topic.get(q["topic"], 0) + 1
        picked += [q for q in ranked if q not in picked][:count - len(picked)]
        self.rng.shuffle(picked)
        return picked

    # -- practice exams ----------------------------------------------------------------

    def start(self, course_id: int, count: int = 30, minutes: int | None = None,
              topics: list[str] | None = None, cards: int = 0, exercises: int = 0) -> dict:
        """A practice exam: `count` multiple-choice questions, then `cards` flashcards (answered right or wrong as
        the user judges) and `exercises` of the course's own (open, marked by the `grade` job), at most MOST."""
        count, cards, exercises = max(0, count), max(0, cards), max(0, exercises)
        bank = self.bank(course_id, topics) if count else []
        flash = self.cards(course_id, topics) if cards else []
        sheets = [q for q in self.exercise_bank(course_id) if not topics or q["topic"] in topics] if exercises else []
        if not bank and not flash and not sheets:
            raise ValueError("This course's notebook has no questions yet.")
        exercises = min(exercises, MOST)
        cards = min(cards, MOST - exercises)
        count = min(count, MOST - exercises - cards)
        keep = ("qkey", "topic", "topic_title", "text", "options", "key", "explanation")
        questions = [{k: q[k] for k in keep} | {"source": PROFESSOR} for q in self.pick(bank, count)] + \
                    [{k: q[k] for k in keep if k != "options"} | {"type": "card", "source": PROFESSOR}
                     for q in self.pick(flash, cards)] + \
                    [{k: q[k] for k in ("type", "points", "text", "model_answer", "rubric", "qkey", "topic",
                                        "topic_title", "source")} for q in self.pick(sheets, exercises)]
        if not questions:
            raise ValueError("This course's notebook has none of those yet.")
        public_id = "x_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO quizzes (public_id, course_id, minutes, questions, started_at) VALUES (?, ?, ?, ?, ?)",
            (public_id, course_id, minutes, json.dumps(questions), utcnow().isoformat()))
        return self.quiz(public_id)

    def quiz(self, public_id: str) -> dict | None:
        if not _ID.match(public_id or ""):
            return None
        row = self.conn.execute("SELECT * FROM quizzes WHERE public_id = ?", (public_id,)).fetchone()
        if row is None:
            return None
        return {**dict(row), "questions": json.loads(row["questions"]),
                "answers": json.loads(row["answers"]) if row["answers"] else None,
                "scoring": json.loads(row["scoring"]) if row["scoring"] else None,
                "checked": json.loads(row["checked"]) if row["checked"] else {}}

    def quizzes(self, course_id: int, limit: int = 20, kind: str = "exam") -> list[dict]:
        return [self.quiz(r[0]) for r in self.conn.execute(
            "SELECT public_id FROM quizzes WHERE course_id = ? AND finished_at IS NOT NULL AND kind = ? "
            "ORDER BY finished_at DESC LIMIT ?", (course_id, kind, limit))]

    def start_mock(self, mock_id: str) -> dict:
        """A mock exam taken in the app: its questions as written, timed and scored as the exam is."""
        m = self.notebook.mock(mock_id)
        if m is None:
            raise LookupError(f"no mock exam {mock_id}")
        source = {"kind": "course", "name": mock_title(m)} if m.get("source") else PROFESSOR
        questions = [q | {"qkey": qkey(q["text"]), "topic": q["topic"] or "", "topic_title": q["topic_title"] or
                          "The course", "source": source} for q in m["questions"]]
        public_id = "x_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO quizzes (public_id, course_id, minutes, questions, started_at, kind, mock, scoring) "
            "VALUES (?, ?, ?, ?, ?, 'mock', ?, ?)", (public_id, m["course_id"], m["minutes"], json.dumps(questions),
                                                    utcnow().isoformat(), m["public_id"], json.dumps(m["scoring"])))
        return self.quiz(public_id)

    def finish(self, public_id: str, answers: dict[str, str | dict | None]) -> dict:
        """Scores it and records each answer for the next pick. Answers are by question number, "1" on; a number
        left out is blank. An open question's answer is {"text", "photos"}: recorded once it's marked."""
        quiz = self.quiz(public_id)
        if quiz["finished_at"]:
            raise ValueError("This practice exam is already finished.")
        now = utcnow().isoformat()
        given = {}
        for n, q in enumerate(quiz["questions"], 1):
            if str(n) in quiz["checked"]:  # checked while taking it: that answer stands
                given[str(n)] = quiz["checked"][str(n)]
            else:
                given[str(n)] = _given(q, answers.get(str(n)))
            if q.get("type") != "open":
                self._record(quiz["course_id"], q, given[str(n)], now)
        quiz["answers"] = given
        score = self.score(quiz)["points"]
        self.conn.execute("UPDATE quizzes SET answers = ?, score = ?, finished_at = ? WHERE id = ?",
                          (json.dumps(given), score, now, quiz["id"]))
        return self.quiz(public_id)

    def _record(self, course_id: int, q: dict, answer: str | dict | None, at: str) -> None:
        self.conn.execute(
            "INSERT INTO quiz_answers (course_id, qkey, answer, correct, answered_at) VALUES (?, ?, ?, ?, ?)",
            (course_id, q["qkey"], "open" if isinstance(answer, dict) else answer, int(correct(q, answer)), at))

    def check(self, public_id: str, n: int, answer: str | dict | None) -> dict:
        """One question answered while taking a practice or mock exam, for answers shown after each question: the
        answer is kept (final: `finish` uses it) and the question comes back as it will on the results, without the
        marks of an open one (those come when it's finished)."""
        quiz = self.quiz(public_id)
        if quiz["kind"] == "chat":
            raise LookupError(f"no practice exam {public_id}")
        if quiz["finished_at"]:
            raise ValueError("This practice exam is already finished.")
        if not 1 <= n <= len(quiz["questions"]):
            raise LookupError(f"no question {n}")
        if str(n) in quiz["checked"]:
            raise ValueError(f"Question {n} is already checked.")
        q = quiz["questions"][n - 1]
        quiz["checked"][str(n)] = _given(q, answer)
        self.conn.execute("UPDATE quizzes SET checked = ? WHERE id = ?", (json.dumps(quiz["checked"]), quiz["id"]))
        return self.question_json(quiz, n, reveal=True)

    # -- marking a mock exam's open answers ----------------------------------------------

    @staticmethod
    def grading(quiz: dict) -> list[int]:
        """The open questions answered and not marked yet, by number."""
        given = quiz["answers"] or {}
        return [n for n, q in enumerate(quiz["questions"], 1)
                if q.get("type") == "open" and isinstance(a := given.get(str(n)), dict) and "awarded" not in a]

    def set_grades(self, public_id: str, grades: dict[int, tuple[float, str]]) -> dict:
        """The marks for open answers, by number: (points, feedback). Each is recorded for the next pick."""
        quiz = self.quiz(public_id)
        now = utcnow().isoformat()
        for n, (awarded, feedback) in grades.items():
            if n in self.grading(quiz):
                a = quiz["answers"][str(n)]
                a |= {"awarded": awarded, "feedback": feedback}
                self._record(quiz["course_id"], quiz["questions"][n - 1], a, now)
        return self._save_marks(quiz)

    def ungraded(self, public_id: str) -> dict:
        """The open answers still waiting, left unmarked (the marking failed): the score stands without them."""
        quiz = self.quiz(public_id)
        for n in self.grading(quiz):
            quiz["answers"][str(n)] |= {"awarded": None, "feedback": "Couldn't be marked."}
        return self._save_marks(quiz)

    def _save_marks(self, quiz: dict) -> dict:
        self.conn.execute("UPDATE quizzes SET answers = ?, score = ? WHERE id = ?",
                          (json.dumps(quiz["answers"]), self.score(quiz)["points"], quiz["id"]))
        return self.quiz(quiz["public_id"])

    # -- quizzes in a chat ---------------------------------------------------------------

    def start_chat(self, course_id: int, count: int = 10, topics: list[str] | None = None,
                   style: str = "mixed") -> dict:
        """A quiz Professor asks in a chat. A quiz of the course's still open is ended first: one at a time."""
        for row in self.conn.execute("SELECT public_id FROM quizzes WHERE course_id = ? AND kind = 'chat' AND "
                                     "finished_at IS NULL", (course_id,)).fetchall():
            self.end(row[0])
        bank = ([] if style == "cards" else self.bank(course_id, topics)) + \
               ([] if style == "questions" else self.cards(course_id, topics))
        if not bank:
            raise ValueError("No questions to ask: the topics have no " +
                             {"questions": "multiple-choice questions", "cards": "flashcards"}.get(style, "questions "
                                                                                                         "or flashcards") + " yet.")
        questions = [{k: q[k] for k in ("qkey", "topic", "topic_title", "text", "key", "explanation")} |
                     ({"type": "card"} if q.get("type") == "card" else {"options": q["options"]})
                     for q in self.pick(bank, max(1, min(count, QUIZ_MOST)))]
        public_id = "x_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO quizzes (public_id, course_id, questions, answers, started_at, kind) "
            "VALUES (?, ?, ?, '{}', ?, 'chat')", (public_id, course_id, json.dumps(questions), utcnow().isoformat()))
        return self.quiz(public_id)

    def current(self, quiz: dict) -> int | None:
        """The number of the question waiting for an answer; None once all are answered."""
        n = len(quiz["answers"] or {}) + 1
        return n if n <= len(quiz["questions"]) else None

    def answer(self, public_id: str, answer: str | None) -> dict:
        """The answer to the question waiting: a letter for a multiple-choice one, "right" or "wrong" for a flashcard
        (as judged), None (or "blank") for "I don't know". Recorded at once. Returns the quiz with `given` (n, the
        answer as recorded, correct)."""
        quiz = self.quiz(public_id)
        if quiz is None or quiz["kind"] != "chat":
            raise LookupError(f"no quiz {public_id}")
        if quiz["finished_at"] or (n := self.current(quiz)) is None:
            raise ValueError("This quiz is over.")
        q = quiz["questions"][n - 1]
        a = (answer or "").strip()
        if q.get("type") == "card":
            a = a.lower() if a.lower() in ("right", "wrong") else None
        else:
            a = a.upper().removesuffix(")")[:1] if a and a.lower() != "blank" else None
            if a is not None and a not in {o["letter"] for o in q["options"]}:
                raise ValueError(f"{answer!r} isn't one of the options: " + ", ".join(o["letter"] for o in q["options"]))
        self._record(quiz["course_id"], q, a, utcnow().isoformat())
        quiz["answers"][str(n)] = a
        self.conn.execute("UPDATE quizzes SET answers = ? WHERE public_id = ?", (json.dumps(quiz["answers"]), public_id))
        if self.current(quiz) is None:
            quiz = self.end(public_id)
        return quiz | {"given": {"n": n, "answer": a, "correct": correct(q, a)}}

    def end(self, public_id: str) -> dict | None:
        """Ends a quiz where it is: it keeps the questions answered (None when there were none: it's dropped)."""
        quiz = self.quiz(public_id)
        if quiz["finished_at"]:
            return quiz
        asked = len(quiz["answers"] or {})
        if not asked:
            self.conn.execute("DELETE FROM quizzes WHERE public_id = ?", (public_id,))
            return None
        quiz["questions"] = quiz["questions"][:asked]
        self.conn.execute("UPDATE quizzes SET questions = ?, score = ?, finished_at = ? WHERE public_id = ?",
                          (json.dumps(quiz["questions"]), self.score(quiz)["points"], utcnow().isoformat(), public_id))
        return self.quiz(public_id)

    def progress(self, course_id: int) -> list[dict]:
        """Each written topic, for planning reviews: its questions and cards, how many were last answered right,
        wrong (or blank), never seen, and when it was last practised."""
        out = {t["public_id"]: {"id": t["public_id"], "title": t["title"], "items": 0, "right": 0, "wrong": 0,
                                "unseen": 0, "last": None} for t in self._topics(course_id, None)}
        for q in self.bank(course_id) + self.cards(course_id):
            t = out[q["topic"]]
            t["items"] += 1
            if (last := q["last"]) is None:
                t["unseen"] += 1
            else:
                t["right" if last["correct"] else "wrong"] += 1
                t["last"] = max(t["last"] or "", last["answered_at"])
        return list(out.values())

    @staticmethod
    def score(quiz: dict) -> dict:
        """Points as the exam gives them: a multiple-choice answer by the scoring (a mock's own, else RIGHT and
        WRONG), an open one what it was marked (right when that's at least half). A mock's says `grading` while
        open answers wait to be marked."""
        scoring = quiz.get("scoring") or {"right": RIGHT, "wrong": WRONG, "blank": 0}
        right = wrong = blank = 0
        points = most = 0.0
        topics: dict[str, dict] = {}
        for n, q in enumerate(quiz["questions"], 1):
            a = (quiz["answers"] or {}).get(str(n))
            t = topics.setdefault(q["topic"], {"id": q["topic"], "title": q["topic_title"],
                                               "right": 0, "wrong": 0, "blank": 0})
            kind = "blank" if a is None else "right" if correct(q, a) else "wrong"
            t[kind] += 1
            right, wrong, blank = right + (kind == "right"), wrong + (kind == "wrong"), blank + (kind == "blank")
            if q.get("type") == "open":
                most += q["points"]
                points += (a or {}).get("awarded") or 0
            elif q.get("type") == "card":  # self-marked: no penalty
                most += 1
                points += kind == "right"
            else:
                most += scoring["right"]
                points += scoring.get(kind, 0)
        out = {"points": points, "max": most, "right": right, "wrong": wrong, "blank": blank,
               "topics": sorted(topics.values(), key=lambda t: (t["right"] / (t["right"] + t["wrong"] + t["blank"]),
                                                                 t["title"]))}
        if quiz.get("kind") == "mock" or any(q.get("type") == "open" for q in quiz["questions"]):
            out["grading"] = bool(QuizStore.grading(quiz))
        return out

    def title(self, quiz: dict) -> str:
        m = self.notebook.mock(quiz["mock"]) if quiz.get("mock") else None
        return mock_title(m) if m else "Quiz" if quiz["kind"] == "chat" else "Practice exam"

    def headline(self, quiz: dict) -> str:
        """The score in a line, for the push: in the chat it's on the quiz card."""
        s = self.score(quiz)
        return (f"{self.title(quiz)}: {_points(s['points'])} / {_points(s['max'])} ({s['right']} right, "
                f"{s['wrong']} wrong, {s['blank']} blank).")

    def summary(self, quiz: dict) -> str:
        """Professor's message in the course chat after a practice or mock exam, above its card (the score)."""
        s = self.score(quiz)
        parts = []
        marked = [(n, q, a) for n, q in enumerate(quiz["questions"], 1)
                  if q.get("type") == "open" and isinstance(a := quiz["answers"].get(str(n)), dict)]
        if marked:
            parts.append("\n".join(
                f"- Question {n}: " + (f"{_points(a['awarded'])} / {_points(q['points'])}. {a.get('feedback') or ''}"
                                       if a.get("awarded") is not None else f"not marked ({_points(q['points'])} points).")
                for n, q, a in marked).rstrip())
        weak = [t for t in s["topics"] if t["wrong"] + t["blank"]][:3]
        if weak:
            parts.append("To go over: " + ", ".join(
                f"{t['title']} ({t['right']} of {t['right'] + t['wrong'] + t['blank']})" for t in weak) +
                ". Want to go through them?")
        else:
            parts.append("All right. Nothing to go over.")
        return "\n\n".join(parts)

    def card(self, quiz: dict) -> dict:
        """The result as a chat card (docs/API.md, Chat, `quiz`): the Quiz without its questions."""
        return {"type": "quiz", "quiz": {k: v for k, v in self.quiz_json(quiz).items() if k != "questions"}}

    def note(self, quiz: dict) -> str:
        """What Professor reads with the result in the course chat: the questions missed, for "go through them"."""
        missed = []
        for n, q in enumerate(quiz["questions"], 1):
            a = quiz["answers"].get(str(n))
            if q.get("type") == "open":
                if not correct(q, a):
                    got = (a or {}).get("awarded") or 0
                    feedback = f": {a['feedback'][:200]}" if a and a.get("feedback") else ""
                    missed.append(f"{n}. {q['text'][:160]} (open, {_points(got)}/{_points(q['points'])}{feedback}; "
                                  f"{q['topic_title']})")
            elif q.get("type") == "card":
                if a != "right":
                    missed.append(f"{n}. {q['text'][:160]} (flashcard, {'missed' if a else 'blank'}; {q['topic_title']})")
            elif a != q["key"]:
                missed.append(f"{n}. {q['text'][:160]} (answered {a or 'blank'}, key {q['key']}; {q['topic_title']})")
        what = f"Mock exam {quiz['mock']} taken" if quiz.get("mock") else "Practice exam finished"
        return f"[{what} in the app." + (" Missed: " + " | ".join(missed) if missed else "") + "]"

    def mocks_json(self, course_id: int) -> list[dict]:
        """The course's mock exams, each with how it went: times taken, the best score and the last time."""
        out = []
        for m in self.notebook.mocks(course_id):
            taken = [self.quiz(r[0]) for r in self.conn.execute(
                "SELECT public_id FROM quizzes WHERE mock = ? AND finished_at IS NOT NULL ORDER BY finished_at DESC",
                (m["public_id"],))]
            out.append(self.notebook.mock_json(m) | {
                "taken": len(taken), "best": max((self.score(q)["points"] for q in taken), default=None),
                "last": self.quiz_json(taken[0], brief=True) if taken else None})
        return out

    # -- JSON for the API --------------------------------------------------------------

    def mastery(self, course_id: int) -> list[dict]:
        """Each written topic in order, how well it's known: its questions and flashcards last answered right
        (`known`), wrong or blank (`learning`), never (`unseen`)."""
        return [{"id": t["id"], "title": t["title"], "known": t["right"], "learning": t["wrong"], "unseen": t["unseen"]}
                for t in self.progress(course_id)]

    def bank_json(self, course_id: int) -> dict:
        bank = self.bank(course_id)
        topics: dict[str, dict] = {t["id"]: t | {"questions": 0, "cards": 0, "exercises": 0}
                                   for t in self.mastery(course_id)}
        for q in bank:
            topics[q["topic"]]["questions"] += 1
        for q in self.cards(course_id):
            topics[q["topic"]]["cards"] += 1
        for q in self.exercise_bank(course_id):
            if q["topic"] in topics:
                topics[q["topic"]]["exercises"] += 1
        intro = self.notebook.intro(course_id)
        return {"course": course_id, "exam": intro["exam"] if intro else None, "questions": len(bank),
                "to_review": sum(1 for q in bank if q["last"] and not q["last"]["correct"]),
                "unseen": sum(1 for q in bank if q["last"] is None),
                "cards": sum(t["cards"] for t in topics.values()),
                "exercises": sum(t["exercises"] for t in topics.values()),
                "topics": [t for t in topics.values() if t["questions"] or t["cards"] or t["exercises"]],
                "scoring": {"right": RIGHT, "wrong": WRONG, "blank": 0},
                "past": [self.quiz_json(q, brief=True) for q in self.quizzes(course_id)]}

    def quiz_json(self, quiz: dict, brief: bool = False) -> dict:
        done = quiz["finished_at"] is not None
        out = {"id": quiz["public_id"], "kind": quiz["kind"], "title": self.title(quiz), "course": quiz["course_id"],
               "minutes": quiz["minutes"],
               "mock": quiz["mock"], "scoring": quiz["scoring"] or {"right": RIGHT, "wrong": WRONG, "blank": 0},
               "count": len(quiz["questions"]), "started_at": self.study.local(quiz["started_at"]),
               "finished_at": self.study.local(quiz["finished_at"]) if done else None,
               "score": {k: v for k, v in self.score(quiz).items() if k != "topics" or not brief} if done else None}
        if brief:
            return out
        return out | {"questions": [self.question_json(quiz, n, done or str(n) in quiz["checked"])
                                    for n in range(1, len(quiz["questions"]) + 1)],
                      "checked": sorted(int(n) for n in quiz["checked"])}

    @staticmethod
    def question_json(quiz: dict, n: int, reveal: bool) -> dict:
        """Question n as the app shows it; with `reveal` (finished, or checked while taking it), the answer given and
        the key. An open one's marks only once the exam is finished."""
        q = quiz["questions"][n - 1]
        item = {"n": n, "topic": {"id": q["topic"], "title": q["topic_title"]}, "text": plain_math(q["text"]),
                "options": [{"letter": o["letter"], "text": plain_math(o["text"])} for o in q.get("options", [])],
                "source": q.get("source")}
        if q.get("type") == "card":  # its back from the start: it's turned before it's marked, and marked by the user
            item |= {"type": "card", "key": plain_math(q["key"])}
        done = quiz["finished_at"] is not None
        a = (quiz["answers"] if done else quiz["checked"]).get(str(n)) if reveal else None
        if q.get("type") == "open":
            item |= {"type": "open", "points": q["points"]}
            if reveal:
                item |= {"answer": None, "response": {"text": a["text"], "photos": a["photos"]} if a else None,
                         "awarded": (a.get("awarded") if a else 0) if done else None,
                         "feedback": a.get("feedback") if done and a else None,
                         "correct": correct(q, a) if done else None, "model_answer": plain_math(q["model_answer"]),
                         "rubric": plain_math(q["rubric"])}
        elif reveal:
            item |= {"answer": a, "key": plain_math(q["key"]), "correct": correct(q, a),
                     "explanation": plain_math(q["explanation"])}
        return item


def _points(x: float) -> str:
    return f"{x:g}"


def correct(q: dict, answer: str | dict | None) -> bool:
    """A multiple-choice answer is right when it's the key; a flashcard's, when it was judged right; an open one's,
    when it was marked at least half its points."""
    if q.get("type") == "open":
        return isinstance(answer, dict) and (answer.get("awarded") or 0) >= q["points"] / 2
    return answer == "right" if q.get("type") == "card" else answer == q.get("key")


def _given(q: dict, a) -> str | dict | None:
    """An answer as kept: an open question's {"text", "photos"}, a flashcard's "right" or "wrong", else a letter
    among the options; None when blank or not one of them."""
    if q.get("type") == "open":
        return _open_answer(a)
    if q.get("type") == "card":
        return a.strip().lower() if isinstance(a, str) and a.strip().lower() in ("right", "wrong") else None
    a = a.strip().upper()[:1] if isinstance(a, str) and a.strip() else None
    return a if a in {o["letter"] for o in q["options"]} else None


def _source_name(source: str) -> str:
    """An exercise's "from" note as a short name: "Esercitazione 3.pdf, p. 2; solution: …" → "Esercitazione 3, p. 2"."""
    name = re.sub(r"\.pdf\b", "", source.split(";")[0].strip(), flags=re.I)
    if m := re.match(r"(\d{4}-\d{2}-\d{2})\b", name):  # files named by their date: "Sheet of 28 Sep, p. 1"
        day = datetime.fromisoformat(m.group(1))
        name = f"Sheet of {day.day} {day:%b}" + name[m.end():]
    return name


def _open_answer(a) -> dict | None:
    """An open question's answer as kept: {"text", "photos"}; None when it says nothing."""
    if isinstance(a, str):
        a = {"text": a}
    if not isinstance(a, dict):
        return None
    text = str(a.get("text") or "").strip()[:ANSWER_CHARS]
    photos = [p for p in a.get("photos") or [] if isinstance(p, str) and _PHOTO.match(p)][:ANSWER_PHOTOS]
    return {"text": text, "photos": photos} if text or photos else None


def qkey(text: str) -> str:
    return hashlib.sha1(" ".join(text.split()).casefold().encode()).hexdigest()[:16]


# -- the notes' LaTeX as plain text, for the app ------------------------------------------

_COMMANDS = {
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "theta": "θ",
    "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "phi": "φ", "varphi": "φ",
    "omega": "ω", "eta": "η", "kappa": "κ", "chi": "χ", "psi": "ψ", "Delta": "Δ", "Pi": "Π", "Sigma": "Σ",
    "Phi": "Φ", "Omega": "Ω", "Gamma": "Γ", "Theta": "Θ", "Lambda": "Λ",
    "cdot": "·", "times": "×", "div": "÷", "approx": "≈", "neq": "≠", "ne": "≠", "leq": "≤", "le": "≤",
    "geq": "≥", "ge": "≥", "pm": "±", "infty": "∞", "to": "→", "rightarrow": "→", "Rightarrow": "⇒",
    "leftarrow": "←", "uparrow": "↑", "downarrow": "↓", "ldots": "…", "dots": "…", "cdots": "…", "sum": "Σ",
    "partial": "∂", "in": "∈", "quad": " ", "qquad": " ", "%": "%", ",": " ", ";": " ", "!": "", " ": " ",
    "{": "{", "}": "}", "$": "$", "_": "_", "&": "&",
}
_OPERATORS = {"cdot", "times", "div", "approx", "neq", "ne", "leq", "le", "geq", "ge", "pm", "to", "rightarrow",
              "Rightarrow", "leftarrow", "in", "quad", "qquad"}
_SUB = dict(zip("0123456789+-=()aehijklmnoprstuvx", "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"))
_SUP = dict(zip("0123456789+-=()abcdefghijklmnoprstuvwxyz*′'",
                "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ*′′"))
_MATH = re.compile(r"(?<!\\)\$\$(.+?)(?<!\\)\$\$|(?<!\\)\$(?=\S)(.+?)(?<=\S)(?<!\\)\$", re.S)  # \$ is money
_GROUP = r"(\{(?:[^{}]|\{[^{}]*\})*\}|\\[A-Za-z]+|.)"  # {…}, a command, or one character


def _ungroup(s: str) -> str:
    return s[1:-1] if s.startswith("{") and s.endswith("}") else s


def _script(base: str, table: dict, mark: str) -> str:
    inner = _math(_ungroup(base))
    if inner and all(c in table for c in inner):
        return "".join(table[c] for c in inner)
    return f"{mark}{inner}" if len(inner) == 1 else f"{mark}({inner})"


def _math(s: str) -> str:
    s = re.sub(r"\\(?:left|right|big|Big|bigg|Bigg)\b\s*", "", s)
    s = re.sub(r"\\(?:text|mathrm|mathit|textrm|operatorname|mathbf)\s*\{([^{}]*)\}", r"\1", s)
    for _ in range(3):  # nested fractions
        def frac(m):
            a, b = _math(_ungroup(m.group(1))), _math(_ungroup(m.group(2)))
            wrap = lambda x: f"({x})" if re.search(r"[\s+\-−*/=]", x) else x
            return f"{wrap(a)}/{wrap(b)}"
        s = re.sub(r"\\[dt]?frac\s*" + _GROUP + r"\s*" + _GROUP, frac, s)
    s = re.sub(r"\\(?:bar|overline)\s*" + _GROUP, lambda m: "".join(c + "\u0304" for c in _math(_ungroup(m.group(1)))), s)
    s = re.sub(r"\\hat\s*" + _GROUP, lambda m: "".join(c + "\u0302" for c in _math(_ungroup(m.group(1)))), s)
    s = re.sub(r"\\(?:tilde)\s*" + _GROUP, lambda m: "".join(c + "\u0303" for c in _math(_ungroup(m.group(1)))), s)
    s = re.sub(r"\\sqrt\s*" + _GROUP, lambda m: "√" + _math(_ungroup(m.group(1))), s)
    # A letter command swallows the space after it, as in LaTeX ("\\Delta Y" is ΔY); an operator keeps its spacing.
    s = re.sub(r"\\([A-Za-z]+)( ?)", lambda m: _COMMANDS.get(m.group(1), m.group(1)) +
               (m.group(2) if m.group(1) in _OPERATORS else ""), s)
    s = re.sub(r"\\([%,;! {}$_&])", lambda m: _COMMANDS[m.group(1)], s)
    s = re.sub(r"_\s*" + _GROUP, lambda m: _script(m.group(1), _SUB, "_"), s)
    s = re.sub(r"\^\s*" + _GROUP, lambda m: _script(m.group(1), _SUP, "^"), s)
    s = re.sub(r"(?<!\\)[{}]", "", s)
    return re.sub(r"[ \t]{2,}", " ", s).strip()


def plain_math(text: str, blocks: bool = False, inline: bool = False) -> str:
    """$…$ and $$…$$ in the notes as readable Unicode: $\\pi_t - \\pi_{t-1} = -\\alpha(u_t - u_n)$ as
    πₜ − πₜ₋₁ = −α(uₜ − uₙ). Markdown outside the maths stays. `blocks`: a $$…$$ on its own line(s) (in a
    callout too, a full stop after it allowed) stays LaTeX, for the app to draw. `inline`: the rest of the maths
    stays LaTeX too, as \\(…\\) (a $ left in the text is money)."""
    kept: list[str] = []

    def keep(latex: str) -> str:
        kept.append(latex)
        return f"\0{len(kept) - 1}\0"

    def sub(m: re.Match) -> str:
        if blocks and m.group(1) is not None:
            start = text.rfind("\n", 0, m.start()) + 1
            end = text.find("\n", m.end())
            if re.fullmatch(r"[\s>]*", text[start:m.start()]) and re.fullmatch(r"[\s.,;:]*", text[m.end():end if end >= 0 else None]):
                return keep(m.group(0))
        if inline:
            return keep("\\(" + " ".join((m.group(1) or m.group(2)).split()) + "\\)")
        return _math(m.group(1) or m.group(2)).replace("-", "−")

    out = unicodedata.normalize("NFC", _MATH.sub(sub, text).replace("\\$", "$"))  # i and a combining bar as ī
    return re.sub(r"\0(\d+)\0", lambda m: kept[int(m.group(1))], out)
