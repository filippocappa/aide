"""Food log tools. Logging, changing and goals run immediately; deleting a meal waits for the user's !yes.

A meal is logged from its items: saved foods (foods.py) with grams, or new foods with the model's numbers per 100 g,
saved as they're logged; the server works out the totals. Meals logged before items only have their totals.
"""

from datetime import date as Date, datetime
from zoneinfo import ZoneInfo

from ..food import DRINKS, MACROS, FoodStore, totals
from ..foods import FoodDB, free_notes
from ..health import HealthStore
from ..nutrition import Nutrition, weakest
from ..photos import PhotoStore
from . import Tool, ToolOutput
from .nutrition import OpenFoodFacts, nutrition_tools, quality_schema

WHEN_HELP = "Local time as YYYY-MM-DDTHH:MM. Omit for now."
NAMES = {"calories": "kcal", "protein_g": "protein", "carbs_g": "carbs", "fat_g": "fat"}


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def food_tools(store: FoodStore, photos: PhotoStore, tz: ZoneInfo, foods: FoodDB | None = None,
               off: OpenFoodFacts | None = None, health: HealthStore | None = None) -> list[Tool]:
    foods = foods or FoodDB(store.conn)
    nutrition = Nutrition(store, health)

    def fmt(m: dict) -> str:
        at = datetime.fromisoformat(m["eaten_at"]).astimezone(tz)
        line = (f"[{m['id']}] {at:%a %d %b %H:%M} · {m['name']} · {m['calories']} kcal · P {m['protein_g']} g · "
                f"C {m['carbs_g']} g · F {m['fat_g']} g")
        line += f" · water {m['water_ml']} ml" if m["water_ml"] else ""
        line += f" · caffeine {m['caffeine_mg']} mg" if m["caffeine_mg"] else ""
        return line + (f"\n    notes: {m['notes']}" if m["notes"] else "")

    def cards(text: str, meals: list[dict]) -> ToolOutput:
        quality = nutrition.meals(meals)
        return ToolOutput(text, {"type": "meals", "meals": [store.as_json(m) | quality[m["id"]] for m in meals]})

    def quality_line(meal: dict) -> str:
        """The meal's quality and its foods' grades, for Coach to mention when it's worth it."""
        q = nutrition.meals([meal])[meal["id"]]
        if q["quality"] is None:
            return ""
        foods = ", ".join(f"{i['name']} {i['quality'] if i['quality'] is not None else '?'}" for i in q["items"])
        return f"\nMeal quality {q['quality']}/100 ({foods})"

    def day_line(d: Date) -> str:
        """The day's totals against its targets (the goals plus what workouts burned), and its score."""
        sums, day = totals(store.day(d)), nutrition.day(d)
        goals = day["targets"]
        parts = [f"{sums[k]}" + (f"/{goals[k]}" if goals[k] else "") + (" kcal" if k == "calories" else f" g {NAMES[k]}")
                 for k in MACROS]
        parts += [f"{sums['water_ml']} ml water"] if sums["water_ml"] else []
        parts += [f"{sums['caffeine_mg']} mg caffeine"] if sums["caffeine_mg"] else []
        line = f"{d:%a %d %b} so far: " + ", ".join(parts)
        if day["bonus"]["kcal"]:
            line += f" (targets include +{day['bonus']['kcal']} kcal from workouts)"
        if s := day["score"]:
            line += f". Day score {s['score']}/100" + (f", food quality {s['quality']}" if s["quality"] is not None
                                                        else "")
            if low := weakest(s):
                line += f"; weakest: {low}"
        return line

    async def log_meal(name: str, items: list[dict], eaten_at: str | None = None, photo_id: str | None = None,
                       notes: str | None = None, water_ml: int = 0, caffeine_mg: int = 0,
                       emoji: str | None = None) -> str:
        if photo_id and not photos.exists(photo_id):
            raise ValueError(f"no photo {photo_id}")
        if not items and not (water_ml or caffeine_mg):
            raise ValueError("items is empty: give what they ate, each with its grams")
        top = store.conn.execute("SELECT COALESCE(MAX(id), 0) FROM foods").fetchone()[0]
        rows, sums, notes = foods.from_items(items, notes)
        meal = store.add(name, **sums, eaten_at=eaten_at, photo=photo_id, notes=notes, water_ml=water_ml,
                         caffeine_mg=caffeine_mg, emoji=emoji)
        foods.keep_items(meal["id"], rows, count=True)
        lines = [f"Logged: {fmt(meal)}{quality_line(meal)}", day_line(store.local_day(meal))]
        new = [f"[food {r['food_id']}] {r['name']}" for r in rows if r["food_id"] > top]
        lines += [f"Saved as new foods: {', '.join(new)}"] if new else []
        return cards("\n".join(lines), [meal])

    async def update_meal(meal_id: int, name: str | None = None, items: list[dict] | None = None,
                          eaten_at: str | None = None, notes: str | None = None, water_ml: int | None = None,
                          caffeine_mg: int | None = None, emoji: str | None = None) -> str:
        rows = None
        sums = {k: None for k in MACROS}
        if items:
            kept = notes if notes is not None else free_notes(store.find(meal_id)["notes"])
            rows, sums, notes = foods.from_items(items, kept)
        meal = store.update(meal_id, name=name, **sums, eaten_at=eaten_at, notes=notes, water_ml=water_ml,
                            caffeine_mg=caffeine_mg, emoji=emoji)
        if rows:
            foods.keep_items(meal_id, rows, count=False)
        return cards(f"Updated: {fmt(meal)}\n{day_line(store.local_day(meal))}", [meal])

    async def list_meals(date: str | None = None) -> str:  # noqa: A002
        d = Date.fromisoformat(date) if date else store.today()
        meals = store.day(d)
        if not meals:
            return f"No meals logged on {d:%a %d %b}."
        return cards("\n".join([*(fmt(m) for m in meals), day_line(d)]), meals)

    async def set_food_goals(calories: int | None = None, protein_g: int | None = None,
                             carbs_g: int | None = None, fat_g: int | None = None) -> str:
        given = {k: v for k, v in (("calories", calories), ("protein_g", protein_g), ("carbs_g", carbs_g),
                                   ("fat_g", fat_g)) if v is not None}
        goals = store.set_goals({**store.goals(), **given})
        set_ = [f"{goals[k]}{' kcal' if k == 'calories' else ' g ' + NAMES[k]}" for k in MACROS if goals[k]]
        return "Daily goals: " + (", ".join(set_) if set_ else "none")

    async def delete_meal(meal_id: int) -> str:
        meal = store.find(meal_id)
        store.delete(meal_id)
        return f"Deleted meal: {meal['name']}"

    async def describe_delete(meal_id: int) -> str:
        meal = store.find(meal_id)
        at = datetime.fromisoformat(meal["eaten_at"]).astimezone(tz)
        return f"Delete meal '{meal['name']}' ({at:%a %d %b %H:%M}, {meal['calories']} kcal)"

    mid = {"meal_id": {"type": "integer"}}
    numbers = {"calories": {"type": "integer"}, "protein_g": {"type": "integer"}, "carbs_g": {"type": "integer"},
               "fat_g": {"type": "integer"}}
    per_100 = {"kcal_100g": {"type": "number", "description": "Without food_id: kcal per 100 g (100 ml for a drink)"},
               "protein_100g": {"type": "number"}, "carbs_100g": {"type": "number"}, "fat_100g": {"type": "number"}}
    item = _obj({"food_id": {"type": "integer", "description": "A saved food's id, from [food N]"},
                 "name": {"type": "string", "description": "Without food_id: the food, short and specific ('Pasta "
                          "(dry)', 'Pizza margherita', 'Olio extravergine')"},
                 "brand": {"type": "string"},
                 "grams": {"type": "number", "description": "How much they had (ml for a drink). With food_id, "
                           "omit for the food's usual portion"}, **per_100, **quality_schema()}, [])
    items = {"items": {"type": "array", "items": item,
                       "description": "The meal item by item, each a food and its grams: a saved food by food_id, "
                       "or a new one with name and your numbers per 100 g (saved as it's logged, for next time; a "
                       "name already saved is that food). The server adds them up and lists them in notes"}}
    drinks = {"water_ml": {"type": "integer", "description": "ml of water drunk: plain or sparkling water, and the "
                           "volume of drinks that are mostly water (coffee, tea, juice). 0 or omit for none"},
              "caffeine_mg": {"type": "integer", "description": "mg of caffeine (an espresso about 65, a moka cup "
                              "about 100, a cola can about 35). 0 or omit for none"},
              "emoji": {"type": "string", "description": "One emoji for the meal, shown in the app's list instead "
                        "of the photo (🍝, 🥗, 🥣, ☕)"}}
    return [
        Tool("log_meal", "Log a meal (or a drink: water, coffee) the user had from its items, each a food with "
             "the grams they had; plus water and caffeine when there are any (water alone: items empty). Pass "
             "photo_id when it came from a photo. The phone writes it to Apple Health. Returns the day's totals so "
             "far. Runs immediately.",
             _obj({"name": {"type": "string", "description": "Short dish name, e.g. 'Pasta al pomodoro'"}, **items,
                   **drinks,
                   "eaten_at": {"type": "string", "description": WHEN_HELP},
                   "photo_id": {"type": "string", "description": "The id from a [Photo p_…] line"},
                   "notes": {"type": "string", "description": "What the portions assumed, e.g. 'a full plate'"}},
                  ["name", "items"]), log_meal),
        Tool("update_meal", "Correct a logged meal (a bigger portion, the right dish, another time). Give only what "
             "changes; when what they ate or how much changes, give all its items again with the new grams. Runs "
             "immediately.",
             _obj({**mid, "name": {"type": "string"}, **items, **drinks,
                   "eaten_at": {"type": "string", "description": WHEN_HELP},
                   "notes": {"type": "string"}}, ["meal_id"]), update_meal),
        Tool("list_meals", "List the meals logged on a day (default today), each with its id in brackets, and the "
             "day's totals against the goals.",
             _obj({"date": {"type": "string", "description": "YYYY-MM-DD"}}, []), list_meals),
        Tool("set_food_goals", "Set daily goals for calories and macros (grams). Give only the ones that change; "
             "0 removes a goal. Runs immediately.", _obj(dict(numbers), []), set_food_goals),
        Tool("delete_meal", "Delete a logged meal. Needs the user's confirmation: it is queued, and runs only "
             "when the user replies !yes.", _obj(mid, ["meal_id"]),
             delete_meal, confirm=True, describe=describe_delete, target_arg="meal_id"),
        *nutrition_tools(foods, off or OpenFoodFacts()),
    ]
