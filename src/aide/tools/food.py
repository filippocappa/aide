"""Food log tools. Logging, changing and goals run immediately; deleting a meal waits for the user's !yes."""

from datetime import date as Date, datetime
from zoneinfo import ZoneInfo

from ..food import DRINKS, MACROS, FoodStore, totals
from ..photos import PhotoStore
from . import Tool, ToolOutput

WHEN_HELP = "Local time as YYYY-MM-DDTHH:MM. Omit for now."
NAMES = {"calories": "kcal", "protein_g": "protein", "carbs_g": "carbs", "fat_g": "fat"}


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def food_tools(store: FoodStore, photos: PhotoStore, tz: ZoneInfo) -> list[Tool]:
    def fmt(m: dict) -> str:
        at = datetime.fromisoformat(m["eaten_at"]).astimezone(tz)
        line = (f"[{m['id']}] {at:%a %d %b %H:%M} · {m['name']} · {m['calories']} kcal · P {m['protein_g']} g · "
                f"C {m['carbs_g']} g · F {m['fat_g']} g")
        line += f" · water {m['water_ml']} ml" if m["water_ml"] else ""
        line += f" · caffeine {m['caffeine_mg']} mg" if m["caffeine_mg"] else ""
        return line + (f"\n    notes: {m['notes']}" if m["notes"] else "")

    def cards(text: str, meals: list[dict]) -> ToolOutput:
        return ToolOutput(text, {"type": "meals", "meals": [store.as_json(m) for m in meals]})

    def day_line(d: Date) -> str:
        """The day's totals against the goals that are set."""
        sums, goals = totals(store.day(d)), store.goals()
        parts = [f"{sums[k]}" + (f"/{goals[k]}" if goals[k] else "") + (" kcal" if k == "calories" else f" g {NAMES[k]}")
                 for k in MACROS]
        parts += [f"{sums['water_ml']} ml water"] if sums["water_ml"] else []
        parts += [f"{sums['caffeine_mg']} mg caffeine"] if sums["caffeine_mg"] else []
        return f"{d:%a %d %b} so far: " + ", ".join(parts)

    async def log_meal(name: str, calories: int, protein_g: int, carbs_g: int, fat_g: int,
                       eaten_at: str | None = None, photo_id: str | None = None, notes: str | None = None,
                       water_ml: int = 0, caffeine_mg: int = 0) -> str:
        if photo_id and not photos.exists(photo_id):
            raise ValueError(f"no photo {photo_id}")
        meal = store.add(name, calories, protein_g, carbs_g, fat_g, eaten_at, photo_id, notes or "", water_ml,
                         caffeine_mg)
        return cards(f"Logged: {fmt(meal)}\n{day_line(store.local_day(meal))}", [meal])

    async def update_meal(meal_id: int, name: str | None = None, calories: int | None = None,
                          protein_g: int | None = None, carbs_g: int | None = None, fat_g: int | None = None,
                          eaten_at: str | None = None, notes: str | None = None, water_ml: int | None = None,
                          caffeine_mg: int | None = None) -> str:
        meal = store.update(meal_id, name=name, calories=calories, protein_g=protein_g, carbs_g=carbs_g,
                            fat_g=fat_g, eaten_at=eaten_at, notes=notes, water_ml=water_ml, caffeine_mg=caffeine_mg)
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
    numbers = {"calories": {"type": "integer", "description": "kcal, your best estimate for the whole portion"},
               "protein_g": {"type": "integer"}, "carbs_g": {"type": "integer"}, "fat_g": {"type": "integer"}}
    drinks = {"water_ml": {"type": "integer", "description": "ml of water drunk: plain or sparkling water, and the "
                           "volume of drinks that are mostly water (coffee, tea, juice). 0 or omit for none"},
              "caffeine_mg": {"type": "integer", "description": "mg of caffeine (an espresso about 65, a moka cup "
                              "about 100, a cola can about 35). 0 or omit for none"}}
    return [
        Tool("log_meal", "Log a meal (or a drink: water, coffee) the user had, with your estimate of its calories "
             "and macros (grams) for the portion they had, plus water and caffeine when there are any. Pass photo_id "
             "when it came from a photo. The phone writes it to Apple Health. Returns the day's totals so far. "
             "Runs immediately.",
             _obj({"name": {"type": "string", "description": "Short dish name, e.g. 'Pasta al pomodoro'"}, **numbers,
                   **drinks,
                   "eaten_at": {"type": "string", "description": WHEN_HELP},
                   "photo_id": {"type": "string", "description": "The id from a [Photo p_…] line"},
                   "notes": {"type": "string", "description": "What the estimate assumed, e.g. 'about 120 g dry pasta'"}},
                  ["name", *MACROS]), log_meal),
        Tool("update_meal", "Correct a logged meal (a bigger portion, the right dish, another time). Give only what "
             "changes; when the portion changes, give the new calories and macros too. Runs immediately.",
             _obj({**mid, "name": {"type": "string"}, **numbers, **drinks,
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
    ]
