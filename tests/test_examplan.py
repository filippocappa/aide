from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.examplan import (MOCK_FACTOR, MOCK_MIN, REVIEW_FLOOR, ExamPlan, credits, exam_minutes, examplan_tools, lay,
                           spread, words)
from aide.icloud import CalEvent
from aide.notebook import NotebookStore
from aide.photos import PhotoStore
from aide.quiz import QuizStore
from aide.reminders import ReminderStore
from aide.study import StudyStore
from aide.tools import ToolRegistry
from test_api import AUTH, TOKEN, FakeCalendar
from test_food import RecordingClient
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

    tool, = examplan_tools(plan, study)
    text = await tool.handler(course="macroeconomics")
    assert "macroeconomics: exam" in text and "the user's guess" in text
    with pytest.raises(ValueError):
        await tool.handler(course="astrology")
