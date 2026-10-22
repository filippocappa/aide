import json
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.agents import WRITES, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.digest import DigestService
from aide.food import FoodStore
from aide.habits import HabitStore
from aide.health import HealthStore
from aide.notebook import NotebookStore
from aide.objectives import ObjectivePlanner, ObjectiveStore, bounds
from aide.photos import PhotoStore
from aide.quiz import QuizStore
from aide.reminders import ReminderStore
from aide.study import StudyStore
from aide.tools import ToolRegistry
from aide.tools.objectives import objective_tools
from test_api import AUTH, TOKEN, FakeCalendar, done
from test_food import RecordingClient
from test_study import EVENTS, ROME


class FakeEngine:
    """Answers each plan with the next queued reply, keeping what it was sent."""

    def __init__(self):
        self.replies: list[str] = []
        self.asked: list[dict] = []

    async def ask(self, system, content, max_tokens, fast=False, wait=True):
        self.asked.append({"system": system, "text": content[0]["text"], "wait": wait})
        return self.replies.pop(0) if self.replies else "[]"


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")
    habits, food, health = HabitStore(db.conn, ROME), FoodStore(db.conn, ROME), HealthStore(db.conn, ROME)
    reminders = ReminderStore(db.conn)
    study = StudyStore(db, ROME, FakeCalendar(list(EVENTS)))
    notebook = NotebookStore(study)
    QuizStore(notebook)  # its tables
    store = ObjectiveStore(db.conn, ROME, habits, food, health, reminders)
    engine = FakeEngine()
    planner = ObjectivePlanner(store, engine, db, FakeCalendar(list(EVENTS)), study, notebook)
    yield store, planner, engine, db, study
    db.close()


TODAY = datetime.now(ROME).date()


def test_bounds():
    wed = date(2026, 10, 21)
    assert bounds("day", wed) == (wed, date(2026, 10, 22))
    assert bounds("week", wed) == (date(2026, 10, 19), date(2026, 10, 26))
    assert bounds("month", wed) == (date(2026, 10, 1), date(2026, 11, 1))
    assert bounds("month", date(2026, 12, 31)) == (date(2026, 12, 1), date(2027, 1, 1))
    with pytest.raises(ValueError):
        bounds("year", wed)


def test_measures_tick_themselves(env):
    store, _, _, db, study = env
    run = store.habits.add("Run", per_week=3)
    o = store.add("coach", "week", TODAY, "Run 3 times", measure={"type": "habit", "habit": run.id}, target=3)
    assert store.as_json(o)["progress"] == 0
    store.habits.check(run.id, TODAY)
    j = store.as_json(store.get(o["public_id"]))
    assert j["progress"] == 1 and not j["done"] and j["measure"]["label"] == "check-ins of Run"

    store.food.set_goals({"protein_g": 120})
    logged = store.add("coach", "day", TODAY, "Log every meal", measure={"type": "food", "metric": "logged"})
    protein = store.add("coach", "day", TODAY, "Hit protein", measure={"type": "food", "metric": "protein_g"})
    store.food.add("Chicken", 600, 130, 20, 10)
    assert store.as_json(logged)["done"] and store.as_json(protein)["done"]
    with pytest.raises(ValueError, match="calories goal"):
        store.add("coach", "day", TODAY, "Eat right", measure={"type": "food", "metric": "calories"})

    store.health.save([{"date": TODAY.isoformat(), "sleep": {"asleep_min": 460}, "steps": 9000}])
    sleep = store.add("coach", "day", TODAY, "Sleep 7h30", measure={"type": "sleep", "hours": 7.5})
    steps = store.add("coach", "day", TODAY, "Walk 10k", measure={"type": "steps", "steps": 10000})
    assert store.as_json(sleep)["done"] and not store.as_json(steps)["done"]
    assert store.as_json(sleep)["measure"]["label"] == "nights with 7h30 of sleep or more"

    rem = store.reminders.create("Pay rent")
    pay = store.add("secretary", "day", TODAY, "Pay the rent", measure={"type": "reminder", "reminder": rem.id})
    assert not store.as_json(pay)["done"]
    store.reminders.update(rem.id, completed=True)
    assert store.as_json(pay)["done"]

    course = study.conn.execute("INSERT INTO courses (name) VALUES ('macroeconomics')").lastrowid
    quiz = store.add("professor", "week", TODAY, "Two practice exams",
                     measure={"type": "practice", "course": course, "score": 60}, target=2)
    now = datetime.now(timezone.utc).isoformat()
    for score in (7, 4):  # 70% and 40% of 10
        db.conn.execute("INSERT INTO quizzes (public_id, course_id, questions, score, started_at, finished_at) "
                        "VALUES (?, ?, ?, ?, ?, ?)", (f"x_{score}", course, json.dumps([{}] * 10), score, now, now))
    assert store.as_json(quiz)["progress"] == 1
    with pytest.raises(ValueError):
        store.add("coach", "day", TODAY, "Run", measure={"type": "habit", "habit": 999})


def test_proposals_wait_for_an_ok_and_lapse(env):
    store, *_ = env
    a = store.add("coach", "day", TODAY, "Stretch", status="proposed", added_by="agent")
    b = store.add("coach", "day", TODAY, "Walk", status="proposed", added_by="agent")
    assert store.as_json(a)["status"] == "proposed"
    assert [o["public_id"] for o in store.accept("day", TODAY, [a["public_id"]])] == [a["public_id"]]
    with pytest.raises(KeyError):
        store.accept("day", TODAY, ["o_000000000000"])
    j = store.as_json(store.update(b["public_id"], done=True))  # ticking a proposal takes it
    assert j["status"] == "active" and j["done"]
    store.update(a["public_id"], status="dropped")
    assert [o["public_id"] for o in store.objectives("day", TODAY)] == [b["public_id"]]
    old = store.add("coach", "day", TODAY - timedelta(days=1), "Yesterday's", status="proposed")
    assert store.as_json(old)["status"] == "lapsed"
    with pytest.raises(ValueError):
        store.update(b["public_id"], status="proposed")


async def test_a_plan_proposes_from_the_data_within_limits(env):
    store, planner, engine, db, _ = env
    run = store.habits.add("Run", per_week=3)
    db.add_memory("Wants to run a half marathon in spring", agent="coach")
    month = store.add("coach", "month", TODAY, "Build up to 12 runs", measure={"type": "habit", "habit": run.id},
                      target=12)
    engine.replies.append(json.dumps([
        {"agent": "coach", "title": "Run 3 times", "why": "the half marathon", "measure": {"type": "habit",
         "habit": run.id}, "target": 3, "parent": month["public_id"]},
        {"agent": "coach", "title": "Sleep 7h", "measure": {"type": "sleep", "hours": 99}, "target": 4},
        {"agent": "coach", "title": "Walk", "measure": None},
        {"agent": "coach", "title": "A fourth one is too many"},
        {"agent": "aide", "title": "Aide has none"},
        {"agent": "professor", "title": "Practice exam in macroeconomics", "target": 1},
    ]))
    made = await planner.plan("week", TODAY)
    asked = engine.asked[0]
    assert asked["wait"] is False  # never held up by the plan's limit
    assert f"[habit {run.id}] Run, 3 a week" in asked["text"] and "half marathon" in asked["text"]
    assert "Build up to 12 runs" in asked["text"] and "macroeconomics: exam" in asked["text"]
    assert "Dentist" in asked["text"]  # Secretary's calendar
    titles = [o["title"] for o in made]
    assert titles == ["Run 3 times", "Sleep 7h", "Walk", "Practice exam in macroeconomics"]
    first = store.as_json(made[0])
    assert first["status"] == "proposed" and first["parent"] == month["public_id"] and first["target"] == 3
    assert store.as_json(made[1])["measure"] is None  # 99 hours can't be tracked: ticked by hand
    assert store.planned("week", TODAY)

    store.accept("week", TODAY, [made[0]["public_id"]])
    engine.replies.append(json.dumps([{"agent": "coach", "title": "Stretch daily"}]))
    await planner.plan("week", TODAY, ["coach"])  # replaces Coach's waiting proposals, keeps the accepted one
    week = [o["title"] for o in store.objectives("week", TODAY)]
    assert week == ["Practice exam in macroeconomics", "Run 3 times", "Stretch daily"]  # in the team's order
    assert "Already set for this period" in engine.asked[1]["text"]


async def test_ensure_plans_the_month_and_week_first(env):
    store, planner, engine, *_ = env
    engine.replies += ["[]", "nonsense", "[]"]
    await planner.for_digest("daily", TODAY)
    assert [a["text"].split("Plan the objectives for ")[1].split(" ")[1] for a in engine.asked] == \
        ["month", "week", "day"]
    assert all(store.planned(p, TODAY) for p in ("day", "week", "month"))
    await planner.for_digest("daily", TODAY)
    await planner.for_digest("evening", TODAY)
    assert len(engine.asked) == 3


def test_digest_sections(env):
    store, *_ = env
    store.add("coach", "day", TODAY, "Stretch", status="proposed")
    store.add("professor", "day", TODAY, "Read chapter 4")
    dropped = store.add("coach", "day", TODAY, "Dropped")
    store.update(dropped["public_id"], status="dropped")
    [today] = store.digest_sections("daily", TODAY, TODAY)
    assert today["title"] == "Objectives for today" and today["period"] == "day"
    assert [o["title"] for o in today["objectives"]] == ["Read chapter 4", "Stretch"]  # in the team's order
    [evening] = store.digest_sections("evening", TODAY + timedelta(days=1), TODAY)
    assert [o["title"] for o in evening["objectives"]] == ["Read chapter 4"]  # the review: accepted ones only
    monday = bounds("week", TODAY)[1]
    store.add("coach", "week", TODAY, "Run 3 times")
    store.add("coach", "week", monday, "Run 4 times", status="proposed")
    last, nxt = store.digest_sections("weekly", monday, monday - timedelta(days=1))
    assert last["title"] == "Last week's objectives" and nxt["objectives"][0]["title"] == "Run 4 times"


async def test_the_morning_digest_plans_and_shows_them(env):
    store, planner, engine, db, _ = env
    engine.replies += ["[]", "[]", json.dumps([{"agent": "secretary", "title": "Book the dentist"}])]
    client = RecordingClient([done("Morning.")])
    digest = DigestService(db.conn, client, "m", ROME, store.reminders, store.habits)
    digest.objectives, digest.planner = store, planner
    now = datetime.combine(TODAY, datetime.min.time(), ROME) + timedelta(hours=8)
    made = await digest.generate("daily", now)
    section = next(s for s in made["sections"] if s["type"] == "objectives")
    assert section["objectives"][0]["title"] == "Book the dentist"
    assert "Book the dentist" in json.dumps(client.requests[0]["messages"])


def test_api(env, tmp_path):
    store, planner, engine, db, _ = env
    agent = Agent(RecordingClient([]), db, ToolRegistry([]), model="m", tz=ROME,
                  photos=PhotoStore(tmp_path / "photos"), delegate=False)
    api = TestClient(create_app(agent, store.reminders, FakeCalendar([]), ROME, TOKEN, store.habits,
                                objectives=store, planner=planner))
    body = api.get("/v1/objectives", headers=AUTH).json()
    assert set(body) == {"day", "week", "month"} and body["day"]["start"] == TODAY.isoformat()
    assert body["week"]["objectives"] == [] and body["week"]["planned"] is False

    r = api.post("/v1/objectives", json={"agent": "coach", "period": "day", "title": "Stretch"}, headers=AUTH)
    assert r.status_code == 201 and r.json()["status"] == "active" and r.json()["added_by"] == "user"
    oid = r.json()["id"]
    assert api.post("/v1/objectives", json={"agent": "aide", "period": "day", "title": "x"},
                    headers=AUTH).status_code == 400
    assert api.post("/v1/objectives", json={"agent": "coach", "period": "year", "title": "x"},
                    headers=AUTH).status_code == 400
    j = api.patch(f"/v1/objectives/{oid}", json={"done": True}, headers=AUTH).json()
    assert j["done"] and j["progress"] == 1
    assert api.patch("/v1/objectives/o_000000000000", json={"done": True}, headers=AUTH).status_code == 404

    engine.replies.append(json.dumps([{"agent": "coach", "title": "Run twice", "target": 2}]))
    week = api.post("/v1/objectives/plan", json={"period": "week"}, headers=AUTH).json()
    assert week["planned"] and week["objectives"][0]["status"] == "proposed"
    week = api.post("/v1/objectives/accept", json={"period": "week"}, headers=AUTH).json()
    assert week["objectives"][0]["status"] == "active"
    assert api.post("/v1/objectives/accept", json={"period": "week", "ids": ["o_000000000000"]},
                    headers=AUTH).status_code == 404
    assert api.get("/v1/objectives").status_code == 401


async def test_tools_keep_each_specialist_to_its_own(env):
    store, planner, engine, *_ = env
    coach = {t.name: t for t in objective_tools(store, planner, "coach")}
    aide = {t.name: t for t in objective_tools(store, planner, "aide", any_agent=True)}
    assert "agent" not in coach["add_objective"].input_schema["properties"]
    assert "agent" in aide["add_objective"].input_schema["required"]
    run = store.habits.add("Run")
    out = await coach["add_objective"].handler(period="week", title="Run 3 times", track="habit", habit_id=run.id,
                                               target=3)
    assert "0/3 check-ins of Run" in out
    theirs = await aide["add_objective"].handler(period="day", title="Read ch. 4", agent="professor")
    pid = theirs.split("[")[1].split("]")[0]
    with pytest.raises(KeyError):
        await coach["update_objective"].handler(objective_id=pid, done=True)
    assert "✓ done" in await aide["update_objective"].handler(objective_id=pid, done=True)
    listing = await coach["list_objectives"].handler()
    assert "Run 3 times" in listing and "Read ch. 4" not in listing
    engine.replies.append(json.dumps([{"agent": "coach", "title": "Stretch"}, {"agent": "professor", "title": "x"}]))
    out = await coach["plan_objectives"].handler(period="day")
    assert "Stretch" in out and "x" not in out.split("\n", 1)[1]  # Coach plans only its own
    assert "Accepted" in await coach["accept_objectives"].handler(period="day")


def test_every_agent_has_the_objective_tools(env, tmp_path):
    store, planner, _, db, _ = env
    agent = Agent(RecordingClient([]), db, ToolRegistry([]), model="m", tz=ROME,
                  photos=PhotoStore(tmp_path / "photos"), delegate=False,
                  agent_tools=lambda a, any_agent: objective_tools(store, planner, a, any_agent))
    for registry in agent.registries.values():
        assert "accept_objectives" in [t.name for t in registry]
    assert "plan_objectives" in WRITES
    assert any(c["id"] == "objectives" for c in connectors([t.name for t in agent.registries["coach"]]))
