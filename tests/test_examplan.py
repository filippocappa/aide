from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.examplan import (MOCK_FACTOR, MOCK_MIN, REVIEW_FLOOR, ExamPlan, WeekProposer, credits, exam_minutes,
                           examplan_tools, lay, spread, words)
from aide.icloud import CalEvent
from aide.notebook import NotebookStore
from aide.objectives import ObjectivePlanner, ObjectiveStore
from aide.photos import PhotoStore
from aide.plans import PlanStore
from aide.quiz import QuizStore
from aide.reminders import ReminderStore
from aide.study import StudyStore
from aide.tools import ToolRegistry
from test_api import AUTH, TOKEN, FakeCalendar
from test_food import RecordingClient
from test_objectives import FakeEngine
from test_quiz import page

ROME = ZoneInfo("Europe/Rome")
TODAY = datetime.now(ROME).date()
NOW = datetime.combine(TODAY, time(9), ROME).astimezone(timezone.utc)  # the plan's "now": today at 09:00


def at(days: int, hour: int = 10) -> datetime:
    return datetime.combine(TODAY + timedelta(days=days), time(hour), ROME)


def lectures(title: str, days: list[int]) -> list[CalEvent]:
    return [CalEvent(f"{title}{d}", "Work", title, at(d), at(d, 12)) for d in days]


def make(tmp_path, events):
    db = Database(":memory:")
    study = StudyStore(db, ROME, FakeCalendar(events), files_dir=tmp_path / "files")
    notebook = NotebookStore(study)
    quizzes = QuizStore(notebook)
    plan = ExamPlan(db.conn, ROME, study, notebook, quizzes)
    notebook.on_change.append(plan.invalidate)  # as in __main__: a new date or note is in the next read
    return db, study, notebook, quizzes, plan


async def course(study, name):
    await study.courses()
    return study.course_by_name(name)


def written(notebook, cid, title, questions=3, cards=()):
    t = notebook.add_topic(cid, title)
    notebook.set_body(t["id"], page(title, [(f"{title} question {n}?", "A") for n in range(questions)]), cards=cards)
    return notebook.topic(t["public_id"])


# -- the pieces ---------------------------------------------------------------------------------------------------


def test_spread_fills_evenly_within_each_day():
    d = [TODAY + timedelta(days=i) for i in range(4)]
    free = {d[0]: 30, d[1]: 240, d[2]: 240, d[3]: 240}
    out = spread(free, d, 300)
    assert sum(out.values()) == 300
    assert out == {d[0]: 30, d[1]: 90, d[2]: 90, d[3]: 90}  # to the last day before the date
    assert spread(free, d, 2000) == free  # more than fits: every free minute
    assert spread(free, d, 0) == {}


def test_lay_puts_the_last_phases_last():
    d = [TODAY + timedelta(days=i) for i in range(3)]
    out = lay({d[0]: 60, d[1]: 60, d[2]: 60}, [("learn", 100), ("practise", 30), ("review", 50)])
    assert out[d[2]] == {"review": 50, "practise": 10}
    assert out[d[1]] == {"practise": 20, "learn": 40}
    assert out[d[0]] == {"learn": 60}
    short = lay({d[0]: 60}, [("learn", 100), ("review", 50)])
    assert short == {d[0]: {"review": 50, "learn": 10}}  # short: what's missing is learning


def test_words_lengths_and_credits():
    assert words("# Title\nOne two three.\n> [!success]- Answer\n> **A**. Because.\n![fig](x.png)\nfour") == 4
    assert exam_minutes("Written exam, 2 hours, 30 questions") == 120
    assert exam_minutes("90 minutes, open questions") == 90
    assert exam_minutes("1,5 ore") == 90
    assert exam_minutes("multiple choice") is None
    assert credits("9 CFU, written exam") == 9 and credits("6 ECTS") == 6 and credits(None) is None


# -- the plan ------------------------------------------------------------------------------------------------------


async def test_a_course_with_an_exam_date_is_planned(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1])
                                              + lectures("business law", [-13, -6, 1]))
    macro = await course(study, "macroeconomics")
    a = written(notebook, macro["id"], "IS-LM", cards=[("What is IS?", "Goods market"), ("What is LM?", "Money")])
    b = written(notebook, macro["id"], "Phillips curve")
    notebook.add_topic(macro["id"], "Not written yet")
    notebook.add_date(macro["id"], {"what": "written exam", "kind": "exam", "date": (TODAY + timedelta(days=20)).isoformat(),
                                    "time": "09:00"})

    out = await plan.plan(NOW)
    assert [u["name"] for u in out["undated"]] == ["business law"]
    t, = out["targets"]
    assert (t["name"], t["what"], t["from"], t["days_left"], t["time"]) == ("macroeconomics", "written exam", "course", 20,
                                                                            "09:00")
    assert [x["title"] for x in t["topics"]] == ["IS-LM", "Phillips curve"]  # only what's written
    learn = (words(a["body"]) + words(b["body"])) / 60
    practise = 6 * 1.5 + 2 * 0.5 * 3
    mocks = 3 * MOCK_MIN * MOCK_FACTOR
    review = max(REVIEW_FLOOR, 0.15 * (learn + practise))
    assert t["need_min"] == round(learn + practise + mocks + review)
    assert {p["phase"]: p["minutes"] for p in t["phases"]} == {
        "learn": round(learn), "practise": round(practise), "mocks": round(mocks), "review": round(review)}
    assert t["status"] == "fits" and t["short_min"] == 0 and t["planned_min"] == t["need_min"]
    assert t["lectures_left"] == 0 and t["stretch"] == 1.0
    # Business law has a lecture tomorrow, so the season starts after it: today and tomorrow are term days.
    assert out["season_from"] == (TODAY + timedelta(days=2)).isoformat()
    assert all(d["minutes"] <= (120 if d["date"] < out["season_from"] else 240) for d in t["days"])
    assert t["days"][-1]["phases"].get("review") and t["phases"][-1]["to"] < t["date"]
    assert out["today"] and all(b["course"] == macro["id"] for b in out["today"])
    assert "No past exams yet: the mocks are Professor's own." in t["warnings"]
    assert t["history"] == [{"date": TODAY.isoformat(), "need_min": t["need_min"]}] and t["moved"] is None

    text = plan.text(out)
    assert "macroeconomics: written exam" in text and ": fits" in text and "business law" in text


async def test_what_is_known_comes_off_and_lectures_to_come_stretch_it(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, 3]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM", questions=4)
    notebook.add_date(macro["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=30)).isoformat()})
    before = (await plan.plan(NOW))["targets"][0]
    assert before["lectures_held"] == 2 and before["lectures_left"] == 1 and before["stretch"] == 1.5

    for q in quizzes.bank(macro["id"]):
        db.conn.execute("INSERT INTO quiz_answers (course_id, qkey, answer, correct, answered_at) VALUES (?, ?, 'A', 1, ?)",
                        (macro["id"], q["qkey"], (NOW - timedelta(hours=1)).isoformat()))
    db.conn.commit()
    after = (await plan.plan(NOW, fresh=True))["targets"][0]
    learn = {p["phase"]: p["minutes"] for p in after["phases"]}
    assert "learn" not in learn and "practise" not in learn  # all known: only mocks and the review
    assert after["topics"][0]["known"] == 4 and after["need_min"] < before["need_min"]


async def test_the_credits_are_a_ceiling_on_own_study(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM")
    notebook.add_date(macro["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=40)).isoformat()})
    notes_only = (await plan.plan(NOW))["targets"][0]
    assert notes_only["by_credits"] is None  # nothing says the credits

    notebook.set_intro(macro["id"], "Written exam. 1 CFU", "The course.")
    t = (await plan.plan(NOW, fresh=True))["targets"][0]
    b = t["by_credits"]
    # 25 h less the three 2-hour lectures in the timetable: at most 19 h of the user's own, above the notes' count
    assert (b["credits"], b["from"], b["lectures_min"], b["own_min"], b["left_min"]) == (1, "notes", 360, 1140, 1140)
    assert not b["applied"] and b["notes_min"] == notes_only["need_min"] == t["need_min"]  # the notes' own count
    assert not any("credits" in w for w in t["warnings"])

    # Esse3's transcript wins over the Introduction; half a credit is less than the notes count: cut down to it
    db.conn.execute("CREATE TABLE esse3_courses (code TEXT, name TEXT, year INTEGER, credits REAL, course_id INTEGER)")
    db.conn.execute("INSERT INTO esse3_courses VALUES ('X1', 'MACROECONOMICS', 2, 0.5, ?)", (macro["id"],))
    db.conn.commit()
    out = await plan.plan(NOW, fresh=True)
    t = out["targets"][0]
    b = t["by_credits"]
    assert (b["credits"], b["from"], b["own_min"], b["left_min"]) == (0.5, "esse3", 390, 390)
    assert b["applied"] and abs(t["need_min"] - 390) <= 1
    phases = {p["phase"]: p["minutes"] for p in t["phases"]}
    before = {p["phase"]: p["minutes"] for p in notes_only["phases"]}
    assert all(phases.get(k, 0) <= before[k] for k in before) and phases["mocks"] < before["mocks"]  # cut in proportion
    assert any("more than the credits allow: 0.5 credits are 12 h of work; less 6 h of lectures, 6.5 h are your "
               "own study at most, 6.5 h still to do" in w for w in t["warnings"])
    assert "cut to the credits' ceiling (0.5 CFU less 6 h of lectures: 6.5 h left)" in plan.text(out)

    # what the notes show is done comes off the ceiling too
    for q in quizzes.bank(macro["id"]):
        db.conn.execute("INSERT INTO quiz_answers (course_id, qkey, answer, correct, answered_at) VALUES (?, ?, 'A', 1, ?)",
                        (macro["id"], q["qkey"], (NOW - timedelta(hours=1)).isoformat()))
    db.conn.commit()
    b = (await plan.plan(NOW, fresh=True))["targets"][0]["by_credits"]
    assert b["left_min"] < b["own_min"]


class FakeTimetable:
    def __init__(self, lectures):
        self.items, self.reads = lectures, 0

    async def lectures(self, start, end):
        self.reads += 1
        return [l for l in self.items if start <= l.start.date() <= end]


async def test_the_lectures_come_from_unitos_timetable(tmp_path):
    from aide.unitimetable import Lecture
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -3]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM")
    notebook.set_intro(macro["id"], "Written exam. 1 CFU", "The course.")
    notebook.add_date(macro["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=40)).isoformat()})
    lecture = lambda d, cancelled=False, kind="Lezione": Lecture("MACROECONOMICS", at(d), at(d, 13), (), (), cancelled, kind)
    plan.timetable = FakeTimetable([lecture(-14), lecture(-7), lecture(-3), lecture(5), lecture(6, cancelled=True),
                                    lecture(8, kind="Esame"), Lecture("PRIVATE LAW", at(2), at(2, 13), (), (), False, "")])
    out = await plan.plan(NOW)
    t = out["targets"][0]
    # four 3-hour lectures (not the cancelled one, the exam or another course's), held and to come
    assert t["by_credits"]["lectures_min"] == 720 and (t["lectures_held"], t["lectures_left"]) == (3, 1)
    assert out["season_from"] == (TODAY + timedelta(days=6)).isoformat()
    reads = plan.timetable.reads
    await plan.plan(NOW, fresh=True)
    assert plan.timetable.reads == reads  # once a day


async def test_short_of_time_and_the_fallback(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM")
    plan.update_caps(term_cap_min=60, season_cap_min=60)
    notebook.add_date(macro["id"], {"what": "January exam", "kind": "exam", "date": (TODAY + timedelta(days=2)).isoformat()})
    notebook.add_date(macro["id"], {"what": "February exam", "kind": "exam",
                                    "date": (TODAY + timedelta(days=40)).isoformat()})
    t = (await plan.plan(NOW))["targets"][0]
    assert t["what"] == "January exam" and t["status"] == "short"
    assert t["free_min"] == 120 and t["planned_min"] == 120 and t["short_min"] == t["need_min"] - 120
    assert t["fallback"]["what"] == "February exam" and t["fallback"]["fits"]
    assert any(w.startswith("Short by") and "February exam" in w and "would fit" in w for w in t["warnings"])
    assert {p["phase"]: p["planned"] for p in t["phases"]}["learn"] == 0  # the last days go to the review and mocks


async def test_the_calendar_and_earlier_exams_take_their_time(tmp_path):
    busy = [CalEvent("b", "Personal", "Trip", at(1, 6), at(1, 23))]
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1])
                                              + lectures("business law", [-13, -6, -2]) + busy)
    macro = await course(study, "macroeconomics")
    law = await course(study, "business law")
    written(notebook, macro["id"], "IS-LM")
    written(notebook, law["id"], "Contracts")
    notebook.add_date(macro["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=5)).isoformat()})
    notebook.add_date(law["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=8)).isoformat()})
    out = await plan.plan(NOW)
    first, second = out["targets"]
    assert (first["name"], second["name"]) == ("macroeconomics", "business law")
    tomorrow = (TODAY + timedelta(days=1)).isoformat()
    assert all(d["date"] != tomorrow for d in first["days"] + second["days"])  # away all day
    # The second exam has fewer free minutes than its days alone would give: the first took some.
    per_day = {}
    for t in out["targets"]:
        for d in t["days"]:
            per_day[d["date"]] = per_day.get(d["date"], 0) + d["minutes"]
    assert max(per_day.values()) <= 240
    assert any("Macroeconomics's exam is 3 days before" in w for w in second["warnings"])


async def test_an_expected_date_and_a_mid_terms_topics(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]))
    macro = await course(study, "macroeconomics")
    a = written(notebook, macro["id"], "IS-LM")
    written(notebook, macro["id"], "Phillips curve")
    assert (await plan.plan(NOW))["targets"] == []
    with pytest.raises(ValueError):
        plan.set_expected(macro["id"], TODAY, today=TODAY)
    plan.set_expected(macro["id"], TODAY + timedelta(days=25), today=TODAY)
    t = (await plan.plan(NOW))["targets"][0]
    assert t["from"] == "expected" and any("your guess" in w for w in t["warnings"])

    mid = notebook.add_date(macro["id"], {"what": "mid-term", "kind": "mid-term",
                                          "date": (TODAY + timedelta(days=10)).isoformat()})
    t = (await plan.plan(NOW))["targets"][0]
    assert t["kind"] == "mid-term" and t["key"] == mid["id"] and len(t["topics"]) == 2
    assert {p["phase"]: p["minutes"] for p in t["phases"]}["mocks"] == 2 * MOCK_MIN * MOCK_FACTOR
    with pytest.raises(ValueError):
        plan.set_topics(mid["id"], ["t_nope"], macro["id"])
    plan.set_topics(mid["id"], [a["public_id"]], macro["id"])
    t = (await plan.plan(NOW))["targets"][0]
    assert [x["title"] for x in t["topics"]] == ["IS-LM"] and t["topics_chosen"] == [a["public_id"]]


async def test_the_pace_is_learnt_from_answers(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM", questions=25)
    notebook.add_date(macro["id"], {"what": "exam", "kind": "exam", "date": (TODAY + timedelta(days=20)).isoformat()})
    start = NOW - timedelta(days=1)
    for i, q in enumerate(quizzes.bank(macro["id"])):  # one every 3 minutes, in one run
        db.conn.execute("INSERT INTO quiz_answers (course_id, qkey, answer, correct, answered_at) VALUES (?, ?, 'B', 0, ?)",
                        (macro["id"], q["qkey"], (start + timedelta(minutes=3 * i)).isoformat()))
    db.conn.commit()
    out = await plan.plan(NOW)
    assert out["assumptions"]["question_min"] == {"value": 3.0, "learnt": True, "answers": 24}
    assert out["assumptions"]["card_min"]["learnt"] is False
    assert out["targets"][0]["topics"][0]["practise_min"] == 75  # 25 × 3, none right


async def test_caps_are_checked(tmp_path):
    *_, plan = make(tmp_path, [])
    assert plan.caps() == {"term_cap_min": 120, "season_cap_min": 240}
    assert plan.update_caps(season_cap_min=300)["season_cap_min"] == 300
    for bad in ({"season_cap_min": 5}, {"term_cap_min": "2h"}, {"nope": 1}):
        with pytest.raises(ValueError):
            plan.update_caps(**bad)


# -- the API and the tool ---------------------------------------------------------------------------------------------


async def test_the_api_and_professors_tool(tmp_path):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]))
    macro = await course(study, "macroeconomics")
    written(notebook, macro["id"], "IS-LM")
    agent = Agent(RecordingClient([]), db, ToolRegistry([]), model="m", smart_model="s", tz=ROME,
                  photos=PhotoStore(tmp_path / "photos"), delegate=False)
    api = TestClient(create_app(agent, ReminderStore(db.conn), study.calendar, ROME, TOKEN, study=study,
                                notebook=notebook, quizzes=quizzes, examplan=plan))
    r = api.get("/v1/study/plan", headers=AUTH)
    assert r.status_code == 200 and r.json()["targets"] == [] and r.json()["undated"][0]["course"] == macro["id"]
    guess = (TODAY + timedelta(days=30)).isoformat()
    r = api.put(f"/v1/study/plan/courses/{macro['id']}", json={"expected": guess}, headers=AUTH)
    assert r.status_code == 200 and r.json()["targets"][0]["date"] == guess
    assert api.put(f"/v1/study/plan/courses/{macro['id']}", json={"expected": "soon"}, headers=AUTH).status_code == 422
    assert api.put(f"/v1/study/plan/courses/{macro['id']}", json={"topics": ["x"]}, headers=AUTH).status_code == 422
    assert api.put("/v1/study/plan/courses/999", json={"expected": guess}, headers=AUTH).status_code == 404
    assert api.get("/v1/study/settings", headers=AUTH).json() == {"term_cap_min": 120, "season_cap_min": 240}
    assert api.patch("/v1/study/settings", json={"term_cap_min": 90}, headers=AUTH).json()["term_cap_min"] == 90
    assert api.patch("/v1/study/settings", json={"term_cap_min": 0}, headers=AUTH).status_code == 422

    tool, = examplan_tools(plan, study)  # no plans: no propose_study_week
    text = await tool.handler(course="macroeconomics")
    assert "macroeconomics: exam" in text and "the user's guess" in text
    with pytest.raises(ValueError):
        await tool.handler(course="astrology")


# -- the day's blocks as objectives, the week as review sessions -----------------------------------------------------


async def exam_in(tmp_path, days, events=()):
    db, study, notebook, quizzes, plan = make(tmp_path, lectures("macroeconomics", [-14, -7, -1]) + list(events))
    macro = await course(study, "macroeconomics")
    for title in ("IS-LM", "Phillips curve", "AD-AS"):
        written(notebook, macro["id"], title, questions=6)
    notebook.add_date(macro["id"], {"what": "written exam", "kind": "exam",
                                    "date": (TODAY + timedelta(days=days)).isoformat()})
    return db, study, notebook, quizzes, plan, macro


async def test_todays_blocks_become_professors_objectives(tmp_path):
    db, study, notebook, quizzes, plan, macro = await exam_in(tmp_path, 3)
    store, engine = ObjectiveStore(db.conn, ROME), FakeEngine()
    planner = ObjectivePlanner(store, engine, db, study.calendar, study, notebook)
    planner.examplan = plan
    out = await plan.plan()
    minutes = next(d["minutes"] for d in out["targets"][0]["days"] if d["date"] == TODAY.isoformat())
    engine.replies = ['[{"agent": "professor", "title": "Read the IS-LM notes", "why": "x"}]']
    made = await planner.plan("day", TODAY, ["professor"])
    block = made[0]
    assert block["title"].startswith("Study Macroeconomics for") and block["target"] == min(600, minutes)
    assert block["measure"] == {"type": "focus", "course": macro["id"], "unit": "min"}
    assert "exam plan" in block["why"] and made[1]["title"] == "Read the IS-LM notes"
    assert "Already made from the exam plan" in engine.asked[0]["text"]
    assert store.as_json(block)["measure"]["label"] == "minutes of focus on macroeconomics"

    made = await planner.plan("day", TODAY, ["professor"])  # a replan makes the waiting one again
    assert [o["title"] for o in made][:1] == [block["title"]]
    store.accept("day", TODAY, [made[0]["public_id"]])
    made = await planner.plan("day", TODAY, ["professor"])  # taken: not made twice
    assert not any(o["measure"] and o["measure"].get("unit") == "min" for o in made)


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


async def test_the_week_goes_into_free_time(tmp_path):
    trip = CalEvent("t", "Personal", "Dentist", at(1, 9), at(1, 18))
    held = CalEvent("r", "Work", "Review: Macroeconomics", at(2, 9), at(2, 10))
    db, study, notebook, quizzes, plan, macro = await exam_in(tmp_path, 12, [trip, held])
    items, warnings = await plan.week(None, NOW)
    out = await plan.plan(NOW)
    days = {d["date"]: d["minutes"] for d in out["targets"][0]["days"]}
    assert items and all(i["title"] == "Review: Macroeconomics" and i["calendar"] == study.study_calendar
                         and i["course_id"] == macro["id"] for i in items)
    per_day: dict[str, int] = {}
    for i in items:
        s0, e0 = datetime.fromisoformat(i["start"]), datetime.fromisoformat(i["end"])
        assert s0.minute % 15 == 0 and (e0 - s0) >= timedelta(minutes=25)
        assert TODAY <= s0.date() <= TODAY + timedelta(days=6)
        assert not overlaps(s0, e0, at(1, 9).replace(tzinfo=None) - timedelta(minutes=15),
                            at(1, 18).replace(tzinfo=None) + timedelta(minutes=15))
        assert not overlaps(s0, e0, at(2, 9).replace(tzinfo=None), at(2, 10, ).replace(tzinfo=None) + timedelta(minutes=15))
        per_day[s0.date().isoformat()] = per_day.get(s0.date().isoformat(), 0) + int((e0 - s0).total_seconds() // 60)
    for d, m in per_day.items():
        assert m <= days[d] - (60 if d == (TODAY + timedelta(days=2)).isoformat() else 0)
    # Earlier days take topics first: learning goes through the course in order.
    assert items[0]["topics"][0] == "IS-LM" and "Topics: IS-LM" in items[0]["notes"]
    assert not warnings


async def test_proposing_the_week(tmp_path):
    db, study, notebook, quizzes, plan, macro = await exam_in(tmp_path, 15)
    plans = PlanStore(db.conn, ROME, study.calendar)
    propose, show = examplan_tools(plan, study, plans, lambda: ("c_chat", "professor"))
    assert propose.name == "propose_study_week"
    text = await propose.handler()
    assert "review sessions" in text and text.attachment["type"] == "events"
    assert all(e["title"] == "Review: Macroeconomics" for e in text.attachment["events"])

    class Agent_:
        def __init__(self):
            self.db, self.posts = db, []

        async def post(self, chat, note, text, attachments=None):
            self.posts.append((chat, text, attachments))

    class Push:
        sent = []

        async def send_message(self, chat, title, body):
            self.sent.append((chat, title, body))

    agent, push = Agent_(), Push()
    weekly = WeekProposer(plan, plans, agent, push)
    sunday = TODAY + timedelta(days=(6 - TODAY.weekday()) % 7)
    early = datetime.combine(sunday, time(16), ROME).astimezone(timezone.utc)
    assert await weekly.tick(early) is None and not agent.posts
    evening = datetime.combine(sunday, time(18), ROME).astimezone(timezone.utc)
    made = await weekly.tick(evening)
    chat, said, cards = agent.posts[0]
    assert made["conversation"] == chat == plan.settings()["chat"] and cards[0]["type"] == "events"
    assert said.startswith("Your study week from the exam plan") and push.sent[0][1] == "Professor · Study week"
    assert db.app_conversation(chat)["title"] == "Study week"
    assert await weekly.tick(evening + timedelta(minutes=30)) is None and len(agent.posts) == 1  # once a week
    assert weekly.chat() == chat
