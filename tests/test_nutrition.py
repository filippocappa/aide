import json
from datetime import datetime, time, timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.food import FoodStore
from aide.foods import FoodDB
from aide.health import HealthStore
from aide.icloud import CalEvent
from aide.nutrition import Nutrition, nutriscore, score
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.food import food_tools
from aide.tools.nutrition import OpenFoodFacts, product
from test_api import AUTH, TOKEN, FakeCalendar, done
from test_food import ROME, RecordingClient
from test_foods import NOCCIOLATA
from test_search_maps import Recorder, client

BASE = {"calories": 2500, "protein_g": 140, "carbs_g": 300, "fat_g": 80}


def food(kcal, protein, carbs, fat, sugars, sat, salt, fibre=0, fvl=0, kind="general"):
    return {"kcal_100g": kcal, "protein_100g": protein, "carbs_100g": carbs, "fat_100g": fat, "sugars_100g": sugars,
            "sat_fat_100g": sat, "salt_100g": salt, "fibre_100g": fibre, "fvl_pct": fvl, "kind": kind}


def test_nutriscore_follows_the_2023_rules():
    assert nutriscore(food(884, 0, 0, 100, 0, 14, 0, fvl=100, kind="fat")) == "b"  # extra virgin olive oil
    assert nutriscore(food(717, 0.9, 0.1, 81, 0.1, 51, 0.02, kind="fat")) == "e"  # butter
    assert nutriscore(food(42, 0, 10.6, 0, 10.6, 0, 0, kind="drink")) == "e"  # cola
    assert nutriscore(food(52, 0.3, 14, 0.2, 10.4, 0, 0, fibre=2.4, fvl=100)) == "a"  # an apple
    assert nutriscore(food(0, 0, 0, 0, 0, 0, 0, kind="water")) == "a"
    assert nutriscore(food(544, 8.1, 54, 32, 50, 4.6, 0.1)) == "e"  # a hazelnut spread
    assert nutriscore(food(359, 13, 71, 1.5, 3.5, 0.3, 0.01, fibre=3)) == "a"  # dry pasta
    assert nutriscore({"kcal_100g": 52, "protein_100g": 0.3, "carbs_100g": 14, "fat_100g": 0.2}) is None


def test_the_day_score():
    on = dict(BASE)
    assert score({**on, "calories": 0}, BASE, [], final=True) is None  # nothing eaten
    full = score(on, BASE, [(2500, "a")], final=True)
    assert (full["score"], full["numbers"], full["quality"]) == (100, 100, 100)
    # A day over is 60% numbers and 40% quality: half the calories graded A, half E is 50.
    half = score(on, BASE, [(1250, "a"), (1250, "e")], final=True)
    assert (half["score"], half["quality"], half["grades"]["e"]) == (80, 50, 1250)
    # Under half the calories graded: numbers only.
    few = score(on, BASE, [(1000, "e"), (1500, None)], final=True)
    assert (few["score"], few["quality"], few["graded"]) == (100, None, 0.4)
    # Short of everything at the day's end costs; before it's over only going over does.
    short = {"calories": 1500, "protein_g": 80, "carbs_g": 180, "fat_g": 50}
    assert score(short, BASE, [], final=True)["numbers"] < 30
    assert score(short, BASE, [], final=False)["numbers"] == 100
    over = {**on, "calories": 3250}  # 30% over: half way from the 10% band to nothing at 50%
    assert score(over, BASE, [], final=False)["numbers"] == 80
    assert score(on, {"calories": None, "protein_g": None, "carbs_g": None, "fat_g": None}, [(2500, "c")],
                 final=True)["score"] == 50  # no targets: quality alone


@pytest.fixture
def stores():
    db = Database(":memory:")
    f, health = FoodStore(db.conn, ROME), HealthStore(db.conn, ROME)
    yield f, FoodDB(db.conn), health, Nutrition(f, health), db
    db.close()


def run(day, kcal=656, minutes=54, hour=8, wid="w1"):
    start = datetime.combine(day, time(hour), ROME)
    return {"id": wid, "type": "run", "start": start.isoformat(),
            "end": (start + timedelta(minutes=minutes)).isoformat(), "minutes": minutes, "kcal": kcal, "km": 9.8}


def test_a_run_adds_its_kcal_mostly_as_carbs(stores):
    f, _, health, nutrition, _ = stores
    f.set_goals(BASE)
    today = f.today()
    assert nutrition.day_targets(today) == BASE
    health.save([{"date": today.isoformat(), "active_kcal": 947, "workouts": [run(today)]}])
    bonus = nutrition.bonus(today)
    assert (bonus["kcal"], bonus["planned"], bonus["workouts"][0]["minutes"]) == (656, False, 54)
    # 656 kcal: 80% carbs (131 g), the rest fat (15 g); protein stays.
    assert nutrition.day_targets(today) == {"calories": 3160, "protein_g": 140, "carbs_g": 431, "fat_g": 95}
    nutrition.set_targets(workouts={"share": 0.5})
    assert nutrition.day_targets(today)["calories"] == 2830
    nutrition.set_targets(workouts={"on": False})
    assert nutrition.day_targets(today) == BASE
    with pytest.raises(ValueError):
        nutrition.set_targets(workouts={"share": 3})
    with pytest.raises(ValueError):
        nutrition.set_targets(profile={"goal": "bulk"})


def test_a_run_in_the_calendar_counts_before_it_happens_at_the_usual_rate(stores):
    f, _, health, nutrition, _ = stores
    f.set_goals(BASE)
    today = f.today()
    week_ago = today - timedelta(days=7)
    health.save([{"date": week_ago.isoformat(), "workouts": [run(week_ago, kcal=600, minutes=50)]}])  # 12 kcal/min
    at = datetime.combine(today, time(18), ROME)
    events = [CalEvent("e1", "Home", "Corsa al Valentino", at, at + timedelta(minutes=45)),
              CalEvent("e2", "Home", "Running club dinner", today, today + timedelta(days=1)),  # all day
              CalEvent("e3", "Work", "Lezione", at, at + timedelta(hours=2))]
    bonus = nutrition.bonus(today, events)
    assert (bonus["kcal"], bonus["planned"], bonus["workouts"][0]["title"]) == (540, True, "Corsa al Valentino")
    # The Run calendar's events are runs whatever they're called.
    assert nutrition.bonus(today, [CalEvent("e4", "Run", "Valentino 10k", at, at + timedelta(minutes=30))])["kcal"] == 360
    # Once the Watch has the run, that's what counts.
    health.save([{"date": today.isoformat(), "workouts": [run(today, kcal=500)]}])
    assert nutrition.bonus(today, events) == {"kcal": 500, "planned": False,
                                              "workouts": [{"type": "run", "kcal": 500, "minutes": 54}]}


async def test_new_items_carry_their_quality_and_the_day_gets_a_score(stores, tmp_path):
    from aide.photos import PhotoStore
    f, foods, health, nutrition, _ = stores
    f.set_goals(BASE)
    tools = ToolRegistry(food_tools(f, PhotoStore(tmp_path), ROME, foods, OpenFoodFacts(client(Recorder())), health))
    said = await tools.call("log_meal", {"name": "Insalata", "items": [
        {"name": "Mela", "grams": 150, **food(52, 0.3, 14, 0.2, 10.4, 0, 0, fibre=2.4, fvl=100)},
        {"name": "Olio extravergine", "grams": 10, **food(884, 0, 0, 100, 0, 14, 0, fvl=100, kind="fat")}]})
    assert "Day score" in said
    assert foods.as_json(foods.search("mela")[0])["grade"] == "a"
    assert foods.as_json(foods.search("olio")[0])["grade"] == "b"
    day = nutrition.day(f.today())
    # 78 kcal of apple (A) and 88 of oil (B), all graded
    assert day["score"]["quality"] == 87 and day["score"]["graded"] == 1 and day["score"]["final"] is False
    assert day["left"]["calories"] == 2500 - 170  # the meal is rounded


def test_open_food_facts_brings_its_grade_and_nova():
    p = product({**NOCCIOLATA, "nutriscore_grade": "e", "nova_group": 4,
                 "nutriments": {**NOCCIOLATA["nutriments"], "sugars_100g": 50, "saturated-fat_100g": 4.6}})
    assert p["quality"]["nutriscore"] == "e" and p["quality"]["nova"] == 4 and p["quality"]["sugars_100g"] == 50
    assert product(NOCCIOLATA)["quality"]["nutriscore"] is None


@pytest.fixture
def api_env(tmp_path):
    db = Database(":memory:")
    f, health = FoodStore(db.conn, ROME), HealthStore(db.conn, ROME)

    def make(model=(), events=()):
        model_client = RecordingClient(model)
        agent = Agent(model_client, db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME, delegate=False)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar(list(events)), ROME, TOKEN, food=f,
                         health=health, off=OpenFoodFacts(client(Recorder())))
        return TestClient(app), f, health, model_client
    yield make
    db.close()


def test_the_api_gives_the_days_targets_score_and_coachs_proposal(api_env):
    proposal = {"base": {"calories": 2520, "protein_g": 135.4, "carbs_g": 310, "fat_g": 78},
                "workouts": {"share": 0.8, "carbs_pct": 75}, "why": "You run 4 times a week at 74 kg."}
    api, f, health, model = api_env(model=[done(json.dumps(proposal))])
    today = f.today()
    assert api.put("/v1/food/targets", json={"base": BASE, "profile": {"weight_kg": 74, "goal": "keep"}},
                   headers=AUTH).json()["base"] == BASE
    targets = api.get("/v1/food/targets", headers=AUTH).json()
    assert targets["profile"]["weight_kg"] == 74 and targets["workouts"] == {"on": True, "share": 1.0, "carbs_pct": 80}
    assert api.put("/v1/food/targets", json={"profile": {"goal": "bulk"}}, headers=AUTH).status_code == 400

    health.save([{"date": today.isoformat(), "active_kcal": 947, "steps": 14000, "workouts": [run(today)]}])
    f.add("Pasta", 900, 30, 150, 20)
    day = api.get("/v1/food", headers=AUTH).json()
    assert day["goals"]["calories"] == 3160 and day["base"] == BASE  # the ring follows the day's targets
    assert day["bonus"]["kcal"] == 656 and day["left"]["calories"] == 2260
    assert day["score"]["quality"] is None and day["score"]["final"] is False  # a meal without items: ungraded
    days = api.get(f"/v1/food/days?from={today - timedelta(days=1)}&to={today}", headers=AUTH).json()["days"]
    assert [d["score"] for d in days] == [None, 100]

    got = api.post("/v1/food/targets/propose", headers=AUTH).json()
    assert got["base"] == {"calories": 2520, "protein_g": 135, "carbs_g": 310, "fat_g": 78}
    assert got["workouts"] == {"on": True, "share": 0.8, "carbs_pct": 75} and got["why"].startswith("You run")
    asked = model.requests[0]["messages"][0]["content"][0]["text"]
    assert "run 54 min, 9.8 km, 5.51 min/km, 656 kcal" in asked and '"weight_kg": 74' in asked
    assert api.get("/v1/food/targets", headers=AUTH).json()["base"] == BASE  # nothing saved until a PUT


def test_a_proposal_that_doesnt_parse_is_a_502(api_env):
    api, *_ = api_env(model=[done("I think about 2500 kcal.")])
    assert api.post("/v1/food/targets/propose", headers=AUTH).status_code == 502


def test_a_planned_run_in_the_calendar_shows_on_todays_food(api_env):
    at = datetime.combine(datetime.now(ROME).date(), time(23, 0), ROME)
    api, f, *_ = api_env(events=[CalEvent("e1", "Home", "Run", at, at + timedelta(minutes=30))])
    f.set_goals(BASE)
    day = api.get("/v1/food", headers=AUTH).json()
    assert day["bonus"] == {"kcal": 330, "planned": True,
                            "workouts": [{"type": "run", "kcal": 330, "minutes": 30, "title": "Run"}]}
