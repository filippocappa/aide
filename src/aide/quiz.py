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
from .notebook import NotebookStore, mcqs

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
    kind        TEXT NOT NULL DEFAULT 'exam'  -- exam: the app's practice exam; chat: Professor asking in a chat
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
MOST = 60  # questions in one practice exam
QUIZ_MOST = 30  # in a quiz
STYLES = ("mixed", "questions", "cards")  # what a quiz asks: both, multiple choice only, flashcards only
_ID = re.compile(r"^x_[0-9a-f]{12}$")
_OPTION = re.compile(r"^\s*[-*]?\s*([A-E])\)\s*(.*)$")


class QuizStore:
    def __init__(self, notebook: NotebookStore, rng: random.Random | None = None):
        self.notebook = notebook
        self.study = notebook.study
        self.conn: sqlite3.Connection = notebook.conn
        self.conn.executescript(SCHEMA)
        if "kind" not in {r["name"] for r in self.conn.execute("PRAGMA table_info(quizzes)")}:
            self.conn.execute("ALTER TABLE quizzes ADD COLUMN kind TEXT NOT NULL DEFAULT 'exam'")  # from before quizzes
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
              topics: list[str] | None = None) -> dict:
        bank = self.bank(course_id, topics)
        if not bank:
            raise ValueError("This course's notebook has no questions yet.")
        questions = [{k: q[k] for k in ("qkey", "topic", "topic_title", "text", "options", "key", "explanation")}
                     for q in self.pick(bank, max(1, min(count, MOST)))]
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
                "answers": json.loads(row["answers"]) if row["answers"] else None}

    def quizzes(self, course_id: int, limit: int = 20, kind: str = "exam") -> list[dict]:
        return [self.quiz(r[0]) for r in self.conn.execute(
            "SELECT public_id FROM quizzes WHERE course_id = ? AND finished_at IS NOT NULL AND kind = ? "
            "ORDER BY finished_at DESC LIMIT ?", (course_id, kind, limit))]

    def finish(self, public_id: str, answers: dict[str, str | None]) -> dict:
        """Scores it and records each answer for the next pick. Answers are by question number, "1" on; a number
        left out is blank."""
        quiz = self.quiz(public_id)
        if quiz["finished_at"]:
            raise ValueError("This practice exam is already finished.")
        now = utcnow().isoformat()
        given = {}
        for n, q in enumerate(quiz["questions"], 1):
            a = answers.get(str(n))
            a = a.strip().upper()[:1] if isinstance(a, str) and a.strip() else None
            given[str(n)] = a if a in {o["letter"] for o in q["options"]} else None
            self._record(quiz["course_id"], q, given[str(n)], now)
        quiz["answers"] = given
        score = self.score(quiz)["points"]
        self.conn.execute("UPDATE quizzes SET answers = ?, score = ?, finished_at = ? WHERE id = ?",
                          (json.dumps(given), score, now, quiz["id"]))
        return self.quiz(public_id)

    def _record(self, course_id: int, q: dict, answer: str | None, at: str) -> None:
        self.conn.execute(
            "INSERT INTO quiz_answers (course_id, qkey, answer, correct, answered_at) VALUES (?, ?, ?, ?, ?)",
            (course_id, q["qkey"], answer, int(correct(q, answer)), at))

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
        right = wrong = blank = 0
        topics: dict[str, dict] = {}
        for n, q in enumerate(quiz["questions"], 1):
            a = (quiz["answers"] or {}).get(str(n))
            t = topics.setdefault(q["topic"], {"id": q["topic"], "title": q["topic_title"],
                                               "right": 0, "wrong": 0, "blank": 0})
            kind = "blank" if a is None else "right" if correct(q, a) else "wrong"
            t[kind] += 1
            right, wrong, blank = right + (kind == "right"), wrong + (kind == "wrong"), blank + (kind == "blank")
        return {"points": right * RIGHT + wrong * WRONG, "max": len(quiz["questions"]) * RIGHT,
                "right": right, "wrong": wrong, "blank": blank,
                "topics": sorted(topics.values(), key=lambda t: (t["right"] / (t["right"] + t["wrong"] + t["blank"]),
                                                                  t["title"]))}

    def summary(self, quiz: dict) -> str:
        """Professor's note in the course chat after a practice exam."""
        s = self.score(quiz)
        minutes = round((datetime.fromisoformat(quiz["finished_at"]) -
                         datetime.fromisoformat(quiz["started_at"])).total_seconds() / 60)
        text = (f"Practice exam: **{_points(s['points'])} / {_points(s['max'])}** ({s['right']} right, "
                f"{s['wrong']} wrong, {s['blank']} blank) in {minutes} min.")
        weak = [t for t in s["topics"] if t["wrong"] + t["blank"]][:3]
        if weak:
            text += "\n\nTo go over: " + ", ".join(
                f"{t['title']} ({t['right']} of {t['right'] + t['wrong'] + t['blank']})" for t in weak) + "."
            text += " Want to go through them?"
        else:
            text += "\n\nAll right. Nothing to go over."
        return text

    # -- JSON for the API --------------------------------------------------------------

    def bank_json(self, course_id: int) -> dict:
        bank = self.bank(course_id)
        topics: dict[str, dict] = {}
        for q in bank:
            t = topics.setdefault(q["topic"], {"id": q["topic"], "title": q["topic_title"], "questions": 0})
            t["questions"] += 1
        intro = self.notebook.intro(course_id)
        return {"course": course_id, "exam": intro["exam"] if intro else None, "questions": len(bank),
                "to_review": sum(1 for q in bank if q["last"] and not q["last"]["correct"]),
                "unseen": sum(1 for q in bank if q["last"] is None),
                "topics": list(topics.values()),
                "scoring": {"right": RIGHT, "wrong": WRONG, "blank": 0},
                "past": [self.quiz_json(q, brief=True) for q in self.quizzes(course_id)]}

    def quiz_json(self, quiz: dict, brief: bool = False) -> dict:
        done = quiz["finished_at"] is not None
        out = {"id": quiz["public_id"], "kind": quiz["kind"], "course": quiz["course_id"], "minutes": quiz["minutes"],
               "count": len(quiz["questions"]), "started_at": self.study.local(quiz["started_at"]),
               "finished_at": self.study.local(quiz["finished_at"]) if done else None,
               "score": {k: v for k, v in self.score(quiz).items() if k != "topics" or not brief} if done else None}
        if brief:
            return out
        questions = []
        for n, q in enumerate(quiz["questions"], 1):
            item = {"n": n, "topic": {"id": q["topic"], "title": q["topic_title"]}, "text": plain_math(q["text"]),
                    "options": [{"letter": o["letter"], "text": plain_math(o["text"])} for o in q.get("options", [])]}
            if q.get("type") == "card":
                item["type"] = "card"
            if done:
                answer = quiz["answers"].get(str(n))
                item |= {"answer": answer, "key": plain_math(q["key"]), "correct": correct(q, answer),
                         "explanation": plain_math(q["explanation"])}
            questions.append(item)
        return out | {"questions": questions}


def _points(x: float) -> str:
    return f"{x:g}"


def correct(q: dict, answer: str | None) -> bool:
    """A multiple-choice answer is right when it's the key; a flashcard's, when it was judged right."""
    return answer == "right" if q.get("type") == "card" else answer == q["key"]


def qkey(text: str) -> str:
    return hashlib.sha1(" ".join(text.split()).casefold().encode()).hexdigest()[:16]


def parse_question(q: dict) -> dict | None:
    """A question block from notebook.mcqs as its text, options [{letter, text}], key and explanation."""
    stem, options = [], []
    for line in q["question"].splitlines():
        if m := _OPTION.match(line):
            options.append({"letter": m.group(1), "text": m.group(2).strip()})
        elif options and line.strip():
            options[-1]["text"] += " " + line.strip()  # an option over two lines
        elif not options:
            stem.append(line)
    text = re.sub(r"^\*\*\d+\.\*\*\s*", "", "\n".join(stem).strip())
    answer = q["block"].partition("> [!success]")[2].partition("\n")[2]
    explanation = "\n".join(re.sub(r"^>\s?", "", line) for line in answer.splitlines()).strip()
    explanation = re.sub(r"^\*\*[A-E]\*\*\.?\s*", "", explanation)
    if not text or len(options) < 2 or q["key"] not in {o["letter"] for o in options}:
        return None
    return {"text": text, "options": options, "key": q["key"], "explanation": explanation}


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


def plain_math(text: str) -> str:
    """$…$ and $$…$$ in the notes as readable Unicode: $\\pi_t - \\pi_{t-1} = -\\alpha(u_t - u_n)$ as
    πₜ − πₜ₋₁ = −α(uₜ − uₙ). Markdown outside the maths stays."""
    out = _MATH.sub(lambda m: _math(m.group(1) or m.group(2)).replace("-", "−"), text).replace("\\$", "$")
    return unicodedata.normalize("NFC", out)  # i and a combining bar as ī where there is one
