from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.food import FoodStore
from aide.foods import FoodDB, normalize
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.food import food_tools
from aide.tools.nutrition import OpenFoodFacts, product
from test_api import AUTH, TOKEN, FakeCalendar, done
from test_food import ROME, RecordingClient, upload
from test_search_maps import Recorder, client

NOCCIOLATA = {"code": "8001505005707", "product_name": "Nocciolata", "brands": "Rigoni di Asiago, Nocciolata",
              "quantity": "700 g", "serving_quantity": 15,
              "nutriments": {"energy-kcal_100g": 544, "proteins_100g": 8.1, "carbohydrates_100g": 54, "fat_100g": 32}}
FAGE = {"code": "5201054017371", "product_name": "Total 0%", "brands": ["Fage"], "quantity": "170 g",
        "nutriments": {"energy-kj_100g": 226, "proteins_100g": 10.3, "carbohydrates_100g": 3, "fat_100g": 0}}
NO_NUMBERS = {"code": "1", "product_name": "Mystery", "brands": ["X"], "nutriments": {"energy-kcal_100g": 100}}


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")
    food, foods = FoodStore(db.conn, ROME), FoodDB(db.conn)

    def make(*responses: httpx.Response):
        rec = Recorder(*responses)
        tools = ToolRegistry(food_tools(food, PhotoStore(tmp_path / "photos"), ROME, foods,
                                        OpenFoodFacts(client(rec))))
        return tools, food, foods, rec
    yield make
    db.close()


def test_open_food_facts_products_map_to_foods():
    p = product(NOCCIOLATA)
    assert (p["name"], p["brand"], p["barcode"], p["kcal_100g"], p["serving_g"], p["pack"]) == \
        ("Nocciolata", "Rigoni di Asiago", "8001505005707", 544, 15, "700 g")
    assert round(product(FAGE)["kcal_100g"]) == 54 and product(FAGE)["brand"] == "Fage"  # from kJ
    assert product(NO_NUMBERS) is None
    # "100 g" alone is Open Food Facts' placeholder, not a serving; a real one that happens to be 100 g stays.
    jam = {**NOCCIOLATA, "serving_quantity": 100, "serving_size": "100 g"}
    assert product(jam)["serving_g"] is None
    assert product({**jam, "serving_size": "1 vasetto (100 g)"})["serving_g"] == 100


def test_search_needs_every_word_ignores_accents_and_puts_the_most_eaten_first(env):
    _, _, foods, _ = env()
    a = foods.save("Yogurt greco 0%", 54, 10, 3, 0, "label", brand="Fage")
    b = foods.save("Yogurt bianco", 60, 4, 5, 3, "estimate", aliases="yoghurt")
    foods.save("Caffè latte", 40, 2, 4, 2, "estimate")
    assert [f["id"] for f in foods.search("yogurt")] == [a["id"], b["id"]]
    foods.touch(b["id"], 125)
    assert [f["id"] for f in foods.search("YOGURT")] == [b["id"], a["id"]]
    assert [f["name"] for f in foods.search("fage greco")] == ["Yogurt greco 0%"]
    assert [f["name"] for f in foods.search("caffe")] == ["Caffè latte"] and foods.search("yoghurt")[0] == \
        foods.get(b["id"])
    assert normalize("  Müller  Fitline ") == "muller fitline"


def test_saving_again_updates_by_name_and_brand_or_barcode(env):
    _, _, foods, _ = env()
    a = foods.save("Pasta (dry)", 350, 12, 72, 1.5, "estimate")
    again = foods.save("pasta (DRY)", 359, 13, 71, 2, "label", serving_g=80)
    assert again["id"] == a["id"] and again["kcal_100g"] == 359 and again["serving_g"] == 80
    coded = foods.save("Barilla Spaghetti n.5", 359, 13, 71, 2, "off", brand="Barilla", barcode="8076800195057")
    renamed = foods.save("Spaghetti", 359, 13, 71, 2, "off", brand="Barilla", barcode="8076 800195057")
    assert renamed["id"] == coded["id"] and renamed["name"] == "Spaghetti" and renamed["serving_g"] is None
    with pytest.raises(ValueError):
        foods.save("Oil", 900, 0, 0, 101, "estimate")
    with pytest.raises(ValueError):
        foods.save("Nonsense", 300, 60, 60, 0, "estimate")  # more than 100 g of macros in 100 g
    with pytest.raises(ValueError):
        foods.update(a["id"], name="Spaghetti", brand="Barilla")  # that one exists


async def test_find_food_searches_saved_foods_first_then_open_food_facts(env):
    tools, _, foods, rec = env(httpx.Response(200, json={"hits": [NO_NUMBERS, NOCCIOLATA]}))
    out = await tools.call("find_food", {"query": "nocciolata"})
    assert "No saved food" in out and "1. Nocciolata · Rigoni di Asiago" in out and "barcode 8001505005707" in out
    assert "Mystery" not in out
    assert rec.requests[0].url.params["q"] == "nocciolata" and rec.requests[0].headers["user-agent"].startswith("Aide")
    foods.save("Nocciolata", 544, 8.1, 54, 32, "label")
    out = await tools.call("find_food", {"query": "Nocciolata"})
    assert out.startswith("Saved foods:\n[food ") and len(rec.requests) == 1  # no call out


async def test_find_food_by_barcode_saves_the_product_once(env):
    tools, _, foods, rec = env(httpx.Response(200, json={"status": 1, "product": NOCCIOLATA}),
                               httpx.Response(200, json={"status": 0}))
    out = await tools.call("find_food", {"barcode": "8001505005707"})
    assert out.startswith("From Open Food Facts, now saved:") and "serving 15 g" in out
    saved = foods.by_barcode("8001505005707")
    assert (saved["source"], saved["kcal_100g"], saved["brand"]) == ("off", 544, "Rigoni di Asiago")
    assert (await tools.call("find_food", {"barcode": "8001505005707"})).startswith("Saved food:")
    assert len(rec.requests) == 1
    assert "doesn't have barcode 123" in await tools.call("find_food", {"barcode": "123"})


async def test_open_food_facts_busy_is_a_readable_error(env):
    tools, *_ = env(httpx.Response(429))
    with pytest.raises(RuntimeError, match="busy"):
        await tools.call("find_food", {"query": "biscotti"})


async def test_a_meal_from_items_is_added_up_by_the_server_and_remembers_portions(env):
    tools, food, foods, _ = env()
    fage = foods.save("Yogurt greco 0%", 54, 10.3, 3, 0, "label", brand="Fage", serving_g=170)
    oats = foods.save("Fiocchi d'avena", 372, 13.5, 58.7, 7, "label")
    await tools.call("log_meal", {"name": "Colazione", "items": [
        {"food_id": fage["id"]},  # no grams: one serving
        {"food_id": oats["id"], "grams": 40},
        {"name": "Miele", "grams": 10, "kcal_100g": 300, "protein_100g": 0, "carbs_100g": 80, "fat_100g": 0}],
        "notes": "honey a guess"})
    meal = food.get(1)
    # 91.8 + 148.8 + 30 kcal; 17.5 + 5.4 g protein
    assert (meal["calories"], meal["protein_g"], meal["carbs_g"], meal["fat_g"]) == (270, 23, 37, 3)
    assert meal["notes"] == "Items: Yogurt greco 0% 170 g, Fiocchi d'avena 40 g, Miele 10 g\nhoney a guess"
    honey = foods.search("miele")[0]  # a new item is saved as it's logged
    assert (honey["source"], honey["usual_g"], honey["uses"]) == ("estimate", 10, 1)
    assert [i["food_id"] for i in foods.items(1)] == [fage["id"], oats["id"], honey["id"]]
    assert foods.get(oats["id"])["usual_g"] == 40 and foods.get(oats["id"])["uses"] == 1

    await tools.call("log_meal", {"name": "Colazione", "items": [{"food_id": oats["id"]}]})  # the usual 40 g
    assert food.get(2)["calories"] == 150 and foods.get(oats["id"])["uses"] == 2

    await tools.call("update_meal", {"meal_id": 1, "items": [{"food_id": oats["id"], "grams": 60}]})
    meal = food.get(1)
    assert meal["calories"] == 220 and meal["notes"] == "Items: Fiocchi d'avena 60 g\nhoney a guess"
    assert len(foods.items(1)) == 1 and foods.get(oats["id"])["uses"] == 2 and foods.get(oats["id"])["usual_g"] == 60

    food.delete(1)
    assert foods.items(1) == []


async def test_a_meal_is_always_items_and_a_new_item_with_a_saved_name_is_that_food(env):
    tools, food, foods, _ = env()
    with pytest.raises(TypeError):  # totals guessed in one go aren't taken any more
        await tools.call("log_meal", {"name": "Pizza", "calories": 900, "protein_g": 35, "carbs_g": 110, "fat_g": 30})
    with pytest.raises(ValueError, match="items is empty"):
        await tools.call("log_meal", {"name": "Pizza", "items": []})
    with pytest.raises(ValueError, match="grams"):
        await tools.call("log_meal", {"name": "Pizza", "items": [{"name": "Pizza", "kcal_100g": 250,
                                                                  "protein_100g": 11, "carbs_100g": 30, "fat_100g": 9}]})
    pizza = {"name": "Pizza margherita", "grams": 350, "kcal_100g": 250, "protein_100g": 11, "carbs_100g": 30,
             "fat_100g": 9}
    said = await tools.call("log_meal", {"name": "Pizza", "items": [pizza]})
    assert food.get(1)["calories"] == 880 and "Saved as new foods: [food 1] Pizza margherita" in said
    # The same name again is the saved food, as saved: the same numbers every time.
    said = await tools.call("log_meal", {"name": "Pizza", "items": [{**pizza, "kcal_100g": 300}]})
    assert food.get(2)["calories"] == 880 and "Saved as new" not in said
    assert len(foods.search("pizza")) == 1 and foods.get(1)["uses"] == 2
    # Water alone needs no items.
    await tools.call("log_meal", {"name": "Water", "items": [], "water_ml": 1000})
    assert (food.get(3)["calories"], food.get(3)["water_ml"], food.get(3)["notes"]) == (0, 1000, "")
    plain = foods.save("Riso", 360, 7, 80, 0.6, "estimate")
    with pytest.raises(ValueError, match="how many grams"):
        await tools.call("log_meal", {"name": "Riso", "items": [{"food_id": plain["id"]}]})


# -- scanning in the app ----------------------------------------------------------------


@pytest.fixture
def app_env(tmp_path):
    db = Database(":memory:")
    food, foods = FoodStore(db.conn, ROME), FoodDB(db.conn)
    photos = PhotoStore(tmp_path / "photos")

    def make(*off_responses: httpx.Response, model=()):
        rec, client_ = Recorder(*off_responses), RecordingClient(model)
        agent = Agent(client_, db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME, photos=photos,
                      delegate=False)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, food=food, foods=foods,
                         off=OpenFoodFacts(client(rec)))
        return TestClient(app), food, foods, rec, client_
    yield make
    db.close()


def test_a_scanned_barcode_is_found_saved_and_logged_without_the_model(app_env):
    api, food, foods, rec, model = app_env(httpx.Response(200, json={"status": 1, "product": NOCCIOLATA}))
    found = api.get("/v1/food/barcode/8001505005707", headers=AUTH).json()["food"]
    assert (found["name"], found["brand"], found["kcal_100g"], found["serving_g"], found["usual_g"], found["source"]) \
        == ("Nocciolata", "Rigoni di Asiago", 544, 15, None, "off")
    assert api.get("/v1/food/barcode/8001505005707", headers=AUTH).json()["food"]["id"] == found["id"]
    assert len(rec.requests) == 1  # the second scan is the saved food

    meal = api.post(f"/v1/food/foods/{found['id']}/log", json={}, headers=AUTH).json()["meal"]  # one serving
    assert (meal["name"], meal["calories"], meal["fat_g"]) == ("Nocciolata (Rigoni di Asiago)", 80, 5)
    assert meal["notes"] == "Items: Nocciolata 15 g"
    meal = api.post(f"/v1/food/foods/{found['id']}/log", json={"grams": 30}, headers=AUTH).json()["meal"]
    assert meal["calories"] == 160 and foods.get(found["id"])["usual_g"] == 30
    yesterday = food.today() - timedelta(days=1)
    meal = api.post(f"/v1/food/foods/{found['id']}/log", json={"date": yesterday.isoformat()}, headers=AUTH).json()
    assert meal["meal"]["calories"] == 160 and meal["meal"]["eaten_at"].startswith(yesterday.isoformat())
    assert model.requests == []
    # Each one is in Coach's Food log chat too, with its card, the note before it hidden.
    chat = food.chat()
    said = api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert [m["role"] for m in said] == ["assistant"] * 3
    assert said[0]["text"] == "Logged Nocciolata (Rigoni di Asiago), 15 g: 80 kcal."
    assert said[0]["attachments"][0]["meals"][0]["calories"] == 80
    other = api.post("/v1/conversations", json={"agent": "coach"}, headers=AUTH).json()["id"]
    api.post(f"/v1/food/foods/{found['id']}/log", json={"conversation_id": other}, headers=AUTH)
    assert len(api.get(f"/v1/history?conversation_id={other}", headers=AUTH).json()["messages"]) == 1
    assert api.post("/v1/food/foods/999/log", json={}, headers=AUTH).status_code == 404
    assert api.get("/v1/food/barcode/abc", headers=AUTH).status_code == 400


def test_an_unknown_barcode_is_read_off_its_label_once(app_env):
    label = ('{"kcal_100g": 389, "protein_100g": 13.5, "carbs_100g": 58.7, "fat_100g": 7, "serving_g": 40, '
             '"name": null, "brand": "Quaker"}')
    api, food, foods, rec, model = app_env(httpx.Response(200, json={"status": 0}), model=[done(label)])
    assert api.get("/v1/food/barcode/8000000000001", headers=AUTH).json() == {"food": None}
    photo = upload(api).json()["id"]
    r = api.post("/v1/food/label", json={"barcode": "8000000000001", "photo": photo, "name": "Avena"}, headers=AUTH)
    saved = r.json()["food"]
    assert (saved["name"], saved["brand"], saved["kcal_100g"], saved["serving_g"], saved["source"]) == \
        ("Avena", "Quaker", 389, 40, "label")
    [request] = model.requests
    assert request["model"] == "smart" and request["messages"][0]["content"][0]["type"] == "image"
    assert api.get("/v1/food/barcode/8000000000001", headers=AUTH).json()["food"]["id"] == saved["id"]
    assert len(rec.requests) == 1


def test_a_label_that_cant_be_read_says_why(app_env):
    api, *_ = app_env(model=[done('{"error": "the photo is blurry"}'),
                             done('{"kcal_100g": 300, "protein_100g": 80, "carbs_100g": 80, "fat_100g": 0}')])
    photo = upload(api).json()["id"]
    r = api.post("/v1/food/label", json={"barcode": "8000000000001", "photo": photo}, headers=AUTH)
    assert r.status_code == 422 and "blurry" in r.json()["error"]
    r = api.post("/v1/food/label", json={"barcode": "8000000000001", "photo": photo}, headers=AUTH)
    assert r.status_code == 422 and "another photo" in r.json()["error"]
    assert api.post("/v1/food/label", json={"barcode": "8000000000001", "photo": "p_nope"},
                    headers=AUTH).status_code == 400


def test_what_you_eat_is_listed_searched_and_logged_again_without_the_model(app_env):
    api, food, foods, rec, model = app_env()
    yogurt = foods.save("Yogurt greco 0%", 54, 10, 3, 0, "label", brand="Fage")
    granola = foods.save("Granola", 450, 10, 60, 18, "estimate")
    cola = foods.save("Coca-Cola", 42, 0, 10.6, 0, "off")
    never = foods.save("Nocciolata", 544, 8.1, 54, 32, "off", brand="Rigoni di Asiago")
    assert api.get("/v1/food/recent", headers=AUTH).json() == {"foods": [], "meals": []}

    # Several foods as one meal: the server adds them up and names it after them.
    out = api.post("/v1/food/foods/log", json={"items": [{"food_id": yogurt["id"], "grams": 170},
                                                         {"food_id": granola["id"], "grams": 40}]}, headers=AUTH)
    meal = out.json()["meal"]
    assert (meal["name"], meal["calories"], meal["protein_g"]) == ("Yogurt greco 0% and Granola", 270, 21)
    api.post("/v1/food/foods/log", json={"items": [{"food_id": cola["id"], "grams": 330}]}, headers=AUTH)
    assert api.post("/v1/food/foods/log", json={"items": [{"food_id": cola["id"], "grams": 330}],
                                                "name": "Cola at lunch"}, headers=AUTH).json()["meal"]["name"] \
        == "Cola at lunch"
    assert model.requests == []

    recent = api.get("/v1/food/recent", headers=AUTH).json()
    names = [f["name"] for f in recent["foods"]]  # eaten most first; never-eaten foods only when searched
    assert names[0] == "Coca-Cola" and sorted(names[1:]) == ["Granola", "Yogurt greco 0%"]
    assert recent["foods"][0]["usual_g"] == 330 and recent["foods"][0]["uses"] == 2
    assert [m["name"] for m in recent["meals"]] == ["Yogurt greco 0% and Granola"]  # only meals of several items
    assert recent["meals"][0]["items"] == [{"food_id": yogurt["id"], "name": "Yogurt greco 0%", "grams": 170},
                                           {"food_id": granola["id"], "name": "Granola", "grams": 40}]
    # Searching finds any saved food, eaten or not; meals by their name or items.
    found = api.get("/v1/food/recent?q=rigoni", headers=AUTH).json()
    assert [f["id"] for f in found["foods"]] == [never["id"]] and found["meals"] == []
    assert [m["name"] for m in api.get("/v1/food/recent?q=granola", headers=AUTH).json()["meals"]] \
        == ["Yogurt greco 0% and Granola"]

    # The same meal again: its items and grams, its emoji, a new meal now.
    again = api.post(f"/v1/food/meals/{meal['id']}/again", json={}, headers=AUTH).json()["meal"]
    assert (again["name"], again["calories"], again["emoji"]) == (meal["name"], 270, meal["emoji"])
    assert again["id"] != meal["id"] and foods.items(again["id"])[1]["grams"] == 40
    # Two meals of the same items are one entry, said twice.
    assert api.get("/v1/food/recent", headers=AUTH).json()["meals"][0]["times"] == 2
    # A meal logged before items: its totals again.
    old = food.add("Pizza", 800, 30, 90, 30, emoji="🍕")
    assert api.post(f"/v1/food/meals/{old['id']}/again", json={}, headers=AUTH).json()["meal"]["calories"] == 800

    said = api.get(f"/v1/history?conversation_id={food.chat()}", headers=AUTH).json()["messages"]
    assert said[0]["text"] == "Logged Yogurt greco 0% and Granola: 270 kcal."
    assert api.post("/v1/food/foods/log", json={"items": [{"food_id": 999}]}, headers=AUTH).status_code == 404
    assert api.post("/v1/food/foods/log", json={"items": []}, headers=AUTH).status_code == 400
    tomorrow = (food.today() + timedelta(days=1)).isoformat()
    assert api.post("/v1/food/foods/log", json={"items": [{"food_id": cola["id"]}], "date": tomorrow},
                    headers=AUTH).status_code == 400
    assert api.post("/v1/food/meals/999/again", json={}, headers=AUTH).status_code == 404


def test_what_you_eat_at_this_time_of_day_comes_first(env):
    from datetime import datetime
    _, food, foods, _ = env()
    now = datetime.now(ROME)
    coffee = foods.save("Caffè", 2, 0, 0, 0, "estimate")
    pizza = foods.save("Pizza", 250, 10, 30, 10, "estimate")
    for days, f, hours in ((1, pizza, 6), (2, pizza, 6), (3, pizza, 6), (1, coffee, 0)):
        rows, sums, notes = foods.from_items([{"food_id": f["id"], "grams": 100}], "")
        meal = food.add(f["name"], **sums, eaten_at=now - timedelta(days=days, hours=hours), notes=notes)
        foods.keep_items(meal["id"], rows, count=True)
    # Pizza three times, six hours from now's time of day; coffee once, at this time of day: 3 against 1 + 1.
    assert [f["name"] for f in foods.recent(ROME)["foods"]] == ["Pizza", "Caffè"]
    rows, sums, notes = foods.from_items([{"food_id": coffee["id"], "grams": 100}], "")
    meal = food.add("Caffè", **sums, eaten_at=now - timedelta(days=4), notes=notes)
    foods.keep_items(meal["id"], rows, count=True)
    assert [f["name"] for f in foods.recent(ROME)["foods"]] == ["Caffè", "Pizza"]  # 2 + 2 against 3
