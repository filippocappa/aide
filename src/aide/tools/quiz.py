"""Quiz and review tools, for Professor (#4): quizzes in a chat, by text or voice, from a notebook's questions and
flashcards (quiz.py), mock exams written for the app, and review sessions in the calendar (reviews.py). Answers are
recorded as they come; adding a session runs at once, cancelling one waits for the user's !yes."""

from datetime import datetime
from zoneinfo import ZoneInfo

from ..notebook import NotebookStore
from ..quiz import STYLES, QuizStore, correct, plain_math
from ..reviews import ReviewStore
from ..study import StudyStore
from . import Tool


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def quiz_tools(quizzes: QuizStore, reviews: ReviewStore | None, study: StudyStore, notebook: NotebookStore,
               tz: ZoneInfo) -> list[Tool]:
    async def course_row(name: str) -> dict:
        await study.courses()
        course = study.course_by_name(name)
        if course is None:
            raise ValueError(f"no course called {name!r}; list_courses has their names")
        return course

    def ask(quiz: dict) -> str:
        """The question waiting, with its answer marked for Professor alone."""
        n = quizzes.current(quiz)
        q = quiz["questions"][n - 1]
        card = q.get("type") == "card"
        out = [f"Question {n} of {len(quiz['questions'])}, {q['topic_title']} "
               f"({'a flashcard: they answer in their own words' if card else 'multiple choice'}):",
               plain_math(q["text"])]
        out += [f"{o['letter']}) {plain_math(o['text'])}" for o in q.get("options", [])]
        secret = f"the answer is {plain_math(q['key'])}"
        if q["explanation"]:
            secret += f". Why: {plain_math(q['explanation'])}"
        return "\n".join(out) + f"\n[For you, not to say before they answer: {secret}]"

    def result(quiz: dict) -> str:
        s = quizzes.score(quiz)
        out = f"The quiz is over: {s['right']} of {s['right'] + s['wrong'] + s['blank']} right"
        if s["wrong"] or s["blank"]:
            out += f" ({s['wrong']} wrong, {s['blank']} blank)"
        weak = [t for t in s["topics"] if t["wrong"] + t["blank"]][:3]
        if weak:
            out += ". To go over: " + ", ".join(
                f"{t['title']} ({t['right']} of {t['right'] + t['wrong'] + t['blank']})" for t in weak)
        return out + ". Tell the user, and offer to go through what they missed."

    async def quiz_me(course: str, count: int = 10, topics: list[str] | None = None, style: str = "mixed") -> str:
        c = await course_row(course)
        ids = [notebook.find_topic(t, c["id"])["public_id"] for t in topics or []] or None
        quiz = quizzes.start_chat(c["id"], count, ids, style if style in STYLES else "mixed")
        return f"Quiz {quiz['public_id']}, {len(quiz['questions'])} questions.\n\n{ask(quiz)}"

    async def quiz_answer(quiz: str, answer: str) -> str:
        done = quizzes.answer(quiz, answer)
        n, given = done["given"]["n"], done["given"]
        q = done["questions"][n - 1] if n <= len(done["questions"]) else None
        if given["answer"] is None:
            line = f"Recorded as blank: the answer is {plain_math(q['key'])}."
        elif given["correct"]:
            line = "Right."
        else:
            line = f"Wrong: the answer is {plain_math(q['key'])}."
        if q and q["explanation"]:
            line += f" Why: {plain_math(q['explanation'])}"
        if done["finished_at"]:
            return f"{line}\n\n{result(done)}"
        so_far = sum(correct(done["questions"][int(k) - 1], a) for k, a in done["answers"].items())
        return f"{line} ({so_far} of {n} right so far.)\n\n{ask(done)}"

    async def end_quiz(quiz: str) -> str:
        found = quizzes.quiz(quiz)
        if found is None or found["kind"] != "chat":
            raise KeyError(f"no quiz {quiz}")
        ended = quizzes.end(quiz)
        return result(ended) if ended else "Ended before any answer: nothing recorded."

    async def study_progress(course: str) -> str:
        c = await course_row(course)
        out = []
        courses = {x["id"]: x for x in await study.courses()}
        if exam := courses.get(c["id"], {}).get("next_exam"):
            day = exam.start.astimezone(tz)
            out.append(f"Next exam: {day:%a %d %b %Y %H:%M} ({exam.title}), in {(day.date() - datetime.now(tz).date()).days} days.")
        topics = quizzes.progress(c["id"])
        if not topics:
            out.append("No written topics yet, so nothing to practise.")
        for t in topics:
            seen = t["right"] + t["wrong"]
            line = f"{t['title']}: {t['items']} questions and cards"
            if seen:
                line += f"; last time {t['right']} right, {t['wrong']} wrong or blank"
            if t["unseen"]:
                line += f"; {t['unseen']} never asked"
            if t["last"]:
                line += f"; last practised {datetime.fromisoformat(t['last']).astimezone(tz):%a %d %b}"
            out.append(line)
        for m in quizzes.mocks_json(c["id"]):
            line = f"{m['title']} ({m['count']} questions, {m['points']:g} points): "
            if m["taken"]:
                last = m["last"]["score"]
                line += (f"taken {m['taken']} time(s), best {m['best']:g}, last {last['points']:g}"
                         + (" (open answers still being marked)" if last.get("grading") else ""))
            else:
                line += "not taken yet"
            out.append(line)
        if reviews is not None:
            coming = reviews.upcoming(c["id"])
            out.append("Review sessions coming: " + ("\n" + "\n".join(reviews.line(s) for s in coming) if coming
                                                     else "none."))
        return "\n".join(out)

    async def write_mock_exam(course: str) -> str:
        c = await course_row(course)
        if not notebook.started(c["id"]):
            return f"{c['name']} has no notebook yet: a mock exam is written from its topics."
        notebook.write_mock(c["id"])
        return (f"Under way, in the background: a mock exam for {c['name']} in the real exam's format, from every "
                "topic's notes" + (" and its past exams" if notebook.past_exam_files(c["id"]) else "")
                + ". A few minutes; it's posted in the course chat, and the user takes it in the app (Practice), timed "
                "and scored like the exam, open questions marked after. Tell the user.")

    async def add_review_session(course: str, start: str, minutes: int, topics: list[str]) -> str:
        c = await course_row(course)
        titles = [notebook.find_topic(t, c["id"])["title"] for t in topics]
        s = await reviews.add(c["id"], datetime.fromisoformat(start), minutes, titles)
        return f"Added to the {study.study_calendar} calendar: {reviews.line(s)}"

    async def cancel_review_session(session: str) -> str:
        s = await reviews.cancel(session)
        return f"Cancelled: {reviews.line(s)}"

    async def describe_cancel(session: str) -> str:
        return f"Take the review session off the calendar: {reviews.line(reviews.find(session))}"

    one_course = {"course": {"type": "string", "description": "A course name from list_courses"}}
    qid = {"quiz": {"type": "string", "description": "The quiz's id, x_…"}}
    tools = [
        Tool("quiz_me", "Start a quiz in this chat (by text or voice) from a course notebook's multiple-choice "
             "questions and flashcards: what the user got wrong last time first, then what they've never seen. "
             "Returns the first question, with its answer for you alone. A quiz still open for the course ends.",
             _obj({**one_course,
                   "count": {"type": "integer", "description": "How many questions, 1 to 30; default 10"},
                   "topics": {"type": "array", "items": {"type": "string"},
                              "description": "Topic titles or ids to stick to; omit for all"},
                   "style": {"type": "string", "enum": list(STYLES),
                             "description": "mixed (default), questions (multiple choice only) or cards (flashcards "
                                            "only, good by voice)"}}, ["course"]), quiz_me),
        Tool("quiz_answer", "Record the user's answer to the question waiting, and get whether it was right, why, "
             "and the next question (or the result at the end).",
             _obj({**qid, "answer": {"type": "string", "description": "A multiple-choice letter (A–E); for a "
                                     "flashcard right or wrong, as you judge their words against its answer; blank "
                                     "for don't know or skip"}}, ["quiz", "answer"]), quiz_answer),
        Tool("end_quiz", "End a quiz early, when the user wants to stop: what they answered stays recorded.",
             _obj(qid, ["quiz"]), end_quiz),
        Tool("study_progress", "How the user is doing on a course, topic by topic (right, wrong, never asked, when "
             "last practised), its mock exams and their scores, the next exam, and the review sessions coming. For "
             "planning reviews.", _obj(one_course, ["course"]), study_progress),
        Tool("write_mock_exam", "Write a mock exam for a course: a paper like the real exam (its kinds of questions, "
             "open ones included, its points, time and scoring), over every topic, in the style of its past exams. "
             "The user takes it in the app, under Practice; open answers are marked after, and the result comes in "
             "the course chat. Runs in the background.", _obj(one_course, ["course"]), write_mock_exam),
    ]
    if reviews is not None and reviews.cal is not None:
        tools += [
            Tool("add_review_session", "Put a review session the user agreed to in their timetable calendar, as "
                 "\"Review: <course>\" with its topics. Runs immediately. When it starts, you offer a quiz on them "
                 "in this chat.",
                 _obj({**one_course, "start": {"type": "string", "description": "Local time, YYYY-MM-DDTHH:MM"},
                       "minutes": {"type": "integer", "description": "15 to 240"},
                       "topics": {"type": "array", "items": {"type": "string"}, "description": "Topic titles or ids"}},
                      ["course", "start", "minutes", "topics"]), add_review_session),
            Tool("cancel_review_session", "Take a review session off the calendar. Needs the user's confirmation: "
                 "it is queued, and runs only when the user replies !yes.",
                 _obj({"session": {"type": "string", "description": "Its id in brackets, v_…"}}, ["session"]),
                 cancel_review_session, confirm=True, describe=describe_cancel, target_arg="session"),
        ]
    return tools
