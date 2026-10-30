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
from aide.nutrition import Nutrition, nutriscore, score, weakest
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


def item(kcal, grade=None, nova=None, **grams):
    return {"kcal": kcal, "grade": grade, "nova": nova, **grams}


def test_the_day_score():
    on = dict(BASE)
    assert score({**on, "calories": 0}, BASE, [], final=True) is None  # nothing eaten
    full = score(on, BASE, [item(2500, "a")], final=True)
    assert (full["score"], full["numbers"], full["quality"]) == (100, 100, 100)
    # A day over is 60% numbers and 40% quality: half the calories graded A, half E is 50.
    half = score(on, BASE, [item(1250, "a"), item(1250, "e")], final=True)
    assert (half["score"], half["quality"], half["grades"]["e"]) == (80, 50, 1250)
    # Under half the calories graded: numbers only.
    few = score(on, BASE, [item(1000, "e"), item(1500)], final=True)
    assert (few["score"], few["quality"], few["graded"]) == (100, None, 0.4)
    # Short of everything at the day's end costs; before it's over only going over does.
    short = {"calories": 1500, "protein_g": 80, "carbs_g": 180, "fat_g": 50}
    assert score(short, BASE, [], final=True)["numbers"] < 30
    assert score(short, BASE, [], final=False)["numbers"] == 100
    over = {**on, "calories": 3250}  # 30% over: half way from the 10% band to nothing at 50%
    assert score(over, BASE, [], final=False)["numbers"] == 80
    assert score(on, {"calories": None, "protein_g": None, "carbs_g": None, "fat_g": None}, [item(2500, "c")],
                 final=True)["score"] == 50  # no targets: quality alone


def test_quality_is_the_days_nutrients_and_processing_more_than_each_foods_grade():
    on = dict(BASE)
    # Oats, fruit, lentils and veg, olive oil, cheese and bread: whole foods, though a fifth of it is graded C.
    whole = [item(400, "a", 1, fibre_g=10, fvl_g=0, sat_fat_g=1.5, salt_g=0, free_sugars_g=1),
             item(160, "a", 1, fibre_g=7, fvl_g=300, sat_fat_g=0, salt_g=0, free_sugars_g=0),
             item(700, "a", 1, fibre_g=16, fvl_g=200, sat_fat_g=1, salt_g=1, free_sugars_g=0),
             item(440, "b", 2, fibre_g=0, fvl_g=50, sat_fat_g=7, salt_g=0, free_sugars_g=0),
             item(800, "c", 3, fibre_g=4, fvl_g=0, sat_fat_g=12, salt_g=3, free_sugars_g=2)]
    s = score(on, BASE, whole, final=True)
    assert s["parts"] == {"nutrients": 100, "processing": 100, "grades": 80} and s["quality"] == 95
    assert s["nutrients"]["fibre"] == {"g": 37, "target": 30, "score": 100}
    assert s["nutrients"]["sat_fat"] == {"pct": 7.7, "limit": 10, "score": 100}
    assert weakest(s) is None
    # Packaged snacks (NOVA 4, graded C) for 60% of it: processing and sugars lose marks, and fibre at the day's end.
    snacks = [item(1500, "c", 4, fibre_g=6, fvl_g=0, sat_fat_g=15, salt_g=3, free_sugars_g=90),
              item(1000, "a", 1, fibre_g=6, fvl_g=200, sat_fat_g=3, salt_g=1, free_sugars_g=0)]
    s = score(on, BASE, snacks, final=True)
    assert s["processing"] == {"upf_pct": 60, "score": 0}
    assert s["nutrients"]["sugars"] == {"pct": 14.4, "limit": 10, "score": 71}
    assert (s["nutrients"]["fibre"]["score"], s["nutrients"]["fruit_veg"]["score"]) == (10, 50)
    assert s["parts"] == {"nutrients": 66, "processing": 0, "grades": 70} and s["quality"] == 51
    assert weakest(s) == "60% of kcal ultra-processed"
    # Before the day's over, fibre and fruit and veg can still come.
    early = score(on, BASE, snacks, final=False)
    assert (early["nutrients"]["fibre"]["score"], early["nutrients"]["fruit_veg"]["score"]) == (100, 100)
    assert early["parts"]["nutrients"] == 94
    # A part without data on half the day's kcal is left out and the rest weighed again.
    some = score(on, BASE, [item(1500, "a", 4), item(1000)], final=True)
    assert some["parts"] == {"nutrients": None, "processing": 0, "grades": 100} and some["quality"] == 50
    assert all(n is None for n in some["nutrients"].values())
    assert score(on, BASE, [item(1000, "a", 1, fibre_g=30), item(1500)], final=True)["quality"] is None
    # Salt is scaled up to the day: 3 g on 60% of it is 5 g.
    salty = score(on, BASE, [item(1500, salt_g=3), item(1000)], final=True)["nutrients"]["salt"]
    assert salty == {"g": 5.0, "limit": 5, "score": 100}


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


def test_a_run_in_the_calendar_adds_nothing_until_the_watch_has_it(stores):
    f, _, health, nutrition, _ = stores
    f.set_goals(BASE)
    today = f.today()
    assert nutrition.bonus(today) == {"kcal": 0, "planned": False, "workouts": []}
    health.save([{"date": today.isoformat(), "workouts": [run(today, kcal=500)]}])
    assert nutrition.bonus(today) == {"kcal": 500, "planned": False, "share": 1.0,
                                      "workouts": [{"type": "run", "kcal": 500, "minutes": 54}]}


async def test_new_items_carry_their_quality_and_the_day_gets_a_score(stores, tmp_path):
    from aide.photos import PhotoStore
    f, foods, health, nutrition, _ = stores
    f.set_goals(BASE)
    tools = ToolRegistry(food_tools(f, PhotoStore(tmp_path), ROME, foods, OpenFoodFacts(client(Recorder())), health))
    said = await tools.call("log_meal", {"name": "Insalata", "items": [
        {"name": "Mela", "grams": 150, **food(52, 0.3, 14, 0.2, 10.4, 0, 0, fibre=2.4, fvl=100), "nova": 1},
        {"name": "Olio extravergine", "grams": 10, **food(884, 0, 0, 100, 0, 14, 0, fvl=100, kind="fat"),
         "nova": 2}]})
    assert "Day score" in said
    assert foods.as_json(foods.search("mela")[0])["grade"] == "a"
    assert foods.as_json(foods.search("olio")[0])["grade"] == "b"
    assert foods.as_json(foods.search("mela")[0])["nova"] == 1
    day = nutrition.day(f.today())
    # 78 kcal of apple (A) and 88 of oil (B), all graded; nothing ultra-processed, nutrients fine so far
    s = day["score"]
    assert s["parts"] == {"nutrients": 100, "processing": 100, "grades": 87} and s["quality"] == 97
    assert s["graded"] == 1 and s["final"] is False
    assert s["nutrients"]["fruit_veg"] == {"g": 160, "target": 400, "score": 100}
    assert s["nutrients"]["sugars"]["pct"] == 0  # the apple's sugars aren't free sugars
    assert day["left"]["calories"] == 2500 - 170  # the meal is rounded
    # Each meal's foods and quality: its nutrients per 2000 kcal, so a side of oil alone has no fibre to show.
    meal = f.day(f.today())[0]
    got = nutrition.meals([meal])[meal["id"]]
    assert got["quality_parts"] == {"nutrients": {"score": 100, "weight": 50}, "processing": {"score": 100, "weight": 25},
                                    "grades": {"score": 87, "weight": 25}}
    assert got["quality"] == 97 and "Meal quality 97/100 (Mela 100, Olio extravergine 75)" in said
    assert [(i["name"], i["grams"], i["kcal"], i["grade"], i["nova"], i["quality"]) for i in got["items"]] == [
        ("Mela", 150, 78, "a", 1, 100), ("Olio extravergine", 10, 88, "b", 2, 75)]
    bare = f.add("Pizza", 800, 30, 90, 30)
    assert nutrition.meals([bare]) == {bare["id"]: {"items": [], "quality": None, "quality_parts": None}}


def test_a_meal_gets_coachs_emoji_or_one_from_its_name(stores):
    from aide.food import meal_emoji
    f, *_ = stores
    assert [meal_emoji(n) for n in ("Pasta 120 g with mushroom sauce", "Hi-pro yogurt", "Melanzane grigliate",
                                     "Colazione: latte e biscotti", "Tè verde")] == ["🍝", "🥛", "🍽️", "🥛", "☕"]
    meal = f.add("Bowl", 500, 20, 60, 15, emoji="🥗")
    assert f.as_json(meal)["emoji"] == "🥗"
    assert f.as_json(f.update(meal["id"], emoji=""))["emoji"] == "🍽️"  # cleared: the guess


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
                "workouts": {"share": 0.8, "carbs_pct": 75}, "why": "You run 4 times a week at 74 kg.",
                "questions": ["Is 74 kg still right?", "A race coming?", "A third?"]}
    api, f, health, model = api_env(model=[done(json.dumps(proposal))] * 3)
    today = f.today()
    assert api.put("/v1/food/targets", json={"base": BASE, "profile": {"weight_kg": 74, "goal": "keep"}},
                   headers=AUTH).json()["base"] == BASE
    targets = api.get("/v1/food/targets", headers=AUTH).json()
    assert targets["profile"]["weight_kg"] == 74 and targets["workouts"] == {"on": True, "share": 1.0, "carbs_pct": 80}
    assert api.put("/v1/food/targets", json={"profile": {"goal": "bulk"}}, headers=AUTH).status_code == 400
    assert targets["coach"] == {"model": "Claude Smart", "via": "api"}  # who answers Ask Coach
    note = "  Half marathon in March,\n4 runs a week  "
    profile = api.put("/v1/food/targets", json={"profile": {"goal": "perform", "note": note}},
                      headers=AUTH).json()["profile"]
    assert profile["goal"] == "perform" and profile["note"] == "Half marathon in March, 4 runs a week"

    health.save([{"date": today.isoformat(), "active_kcal": 947, "steps": 14000, "workouts": [run(today)]}]
                + [{"date": (today - timedelta(days=n)).isoformat(), "resting_kcal": 1780 + 10 * n,
                    "active_kcal": 450} for n in (1, 2, 3)])
    f.add("Pasta", 900, 30, 150, 20)
    day = api.get("/v1/food", headers=AUTH).json()
    assert day["goals"]["calories"] == 3160 and day["base"] == BASE  # the ring follows the day's targets
    assert day["bonus"]["kcal"] == 656 and day["left"]["calories"] == 2260
    assert day["score"]["quality"] is None and day["score"]["final"] is False  # a meal without items: ungraded
    assert day["meals"][0]["items"] == [] and day["meals"][0]["quality"] is None
    days = api.get(f"/v1/food/days?from={today - timedelta(days=1)}&to={today}", headers=AUTH).json()["days"]
    assert [d["score"] for d in days] == [None, 100]

    got = api.post("/v1/food/targets/propose", headers=AUTH).json()
    assert got["base"] == {"calories": 2520, "protein_g": 135, "carbs_g": 310, "fat_g": 78}
    assert got["workouts"] == {"on": True, "share": 0.8, "carbs_pct": 75} and got["why"].startswith("You run")
    assert got["questions"] == ["Is 74 kg still right?", "A race coming?"]  # two at most
    asked = model.requests[0]["messages"][0]["content"][0]["text"]
    assert "run 54 min, 9.8 km, 5.51 min/km, 656 kcal" in asked and '"weight_kg": 74' in asked
    assert '"note": "Half marathon in March, 4 runs a week"' in asked
    # The Watch's resting energy, not a formula: the usual of the days before today.
    assert "usual resting kcal 1800 a day, usual active kcal on days without a workout 450" in asked
    assert "so a rest day burns about 2250" in asked
    # The answers go back for another proposal; empty ones are left out.
    api.post("/v1/food/targets/propose", json={"answers": [{"question": "Is 74 kg still right?", "answer": "72 now"},
                                                           {"question": "A race coming?", "answer": " "}]},
             headers=AUTH)
    asked = model.requests[1]["messages"][0]["content"][0]["text"]
    assert "- Is 74 kg still right? 72 now" in asked and "A race coming?" not in asked
    # Coach sees what it proposed last, and the answers stay for the proposals after.
    assert ('Your last proposal (%s): base {"calories": 2520, "protein_g": 135, "carbs_g": 310, "fat_g": 78}, '
            'workouts {"share": 0.8, "carbs_pct": 75}' % today) in asked
    api.post("/v1/food/targets/propose", headers=AUTH)
    asked = model.requests[2]["messages"][0]["content"][0]["text"]
    assert f"What the user answered before:\n- ({today}) Is 74 kg still right? 72 now" in asked
    assert "just answered" not in asked
    assert api.get("/v1/food/targets", headers=AUTH).json()["base"] == BASE  # nothing saved until a PUT


def test_a_proposal_that_doesnt_parse_is_a_502(api_env):
    api, *_ = api_env(model=[done("I think about 2500 kcal.")])
    assert api.post("/v1/food/targets/propose", headers=AUTH).status_code == 502


def test_coach_gives_its_take_on_a_score_when_asked(api_env):
    api, f, health, model = api_env(model=[done("  Your HRV is below your usual after a late night.  ")])
    today = f.today()
    health.save([{"date": (today - timedelta(days=n)).isoformat(), "hrv_ms": 60.0, "resting_hr": 45,
                  "hr_minutes": [[100, 30]]} for n in range(20)])
    got = api.post("/v1/health/insight", json={"kind": "recovery"}, headers=AUTH).json()
    assert got == {"kind": "recovery", "date": today.isoformat(),
                   "text": "Your HRV is below your usual after a late night."}
    req = model.requests[0]
    assert "recovery score" in req["system"]
    asked = json.loads(req["messages"][0]["content"][0]["text"])
    assert asked["score asked about"] == "recovery" and len(asked["last 30 days (newest first)"]) == 30
    assert len(asked["raw health days, last 14 (newest first)"]) == 14
    assert "hr_minutes" not in asked["raw health days, last 14 (newest first)"][0]
    assert api.post("/v1/health/insight", json={"kind": "mood"}, headers=AUTH).status_code in (400, 422)
