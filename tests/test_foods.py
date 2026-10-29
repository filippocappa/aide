import httpx
import pytest

from aide.db import Database
from aide.food import FoodStore
from aide.foods import FoodDB, normalize
from aide.photos import PhotoStore
from aide.tools import ToolRegistry
from aide.tools.food import food_tools
from aide.tools.nutrition import OpenFoodFacts, product
from test_food import ROME
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
        {"name": "Miele", "grams": 10, "calories": 30, "protein_g": 0, "carbs_g": 8, "fat_g": 0}],
        "notes": "honey a guess"})
    meal = food.get(1)
    # 91.8 + 148.8 + 30 kcal; 17.5 + 5.4 g protein
    assert (meal["calories"], meal["protein_g"], meal["carbs_g"], meal["fat_g"]) == (270, 23, 37, 3)
    assert meal["notes"] == "Items: Yogurt greco 0% 170 g, Fiocchi d'avena 40 g, Miele 10 g\nhoney a guess"
    assert [i["food_id"] for i in foods.items(1)] == [fage["id"], oats["id"], None]
    assert foods.get(oats["id"])["usual_g"] == 40 and foods.get(oats["id"])["uses"] == 1

    await tools.call("log_meal", {"name": "Colazione", "items": [{"food_id": oats["id"]}]})  # the usual 40 g
    assert food.get(2)["calories"] == 150 and foods.get(oats["id"])["uses"] == 2

    await tools.call("update_meal", {"meal_id": 1, "items": [{"food_id": oats["id"], "grams": 60}]})
    meal = food.get(1)
    assert meal["calories"] == 220 and meal["notes"] == "Items: Fiocchi d'avena 60 g\nhoney a guess"
    assert len(foods.items(1)) == 1 and foods.get(oats["id"])["uses"] == 2 and foods.get(oats["id"])["usual_g"] == 60

    food.delete(1)
    assert foods.items(1) == []


async def test_log_meal_without_items_still_takes_totals(env):
    tools, food, foods, _ = env()
    await tools.call("log_meal", {"name": "Pizza", "calories": 900, "protein_g": 35, "carbs_g": 110, "fat_g": 30})
    assert food.get(1)["calories"] == 900 and foods.items(1) == []
    with pytest.raises(ValueError):
        await tools.call("log_meal", {"name": "Pizza", "calories": 900})
    plain = foods.save("Riso", 360, 7, 80, 0.6, "estimate")
    with pytest.raises(ValueError, match="how many grams"):
        await tools.call("log_meal", {"name": "Riso", "items": [{"food_id": plain["id"]}]})
