"""Finding a food's real numbers: the saved foods first, then Open Food Facts (free, no key). All run immediately.
Also reading a nutrition label from a photo (one model call), for a barcode Open Food Facts doesn't have."""

import base64
from typing import Awaitable, Callable

import httpx

from ..foods import SOURCES, FoodDB
from . import Tool

SEARCH = "https://search.openfoodfacts.org/search"
PRODUCT = "https://world.openfoodfacts.org/api/v2/product/{}.json"
FIELDS = "code,product_name,product_name_it,brands,quantity,serving_quantity,nutriments"
USER_AGENT = "Aide/1.0 (personal assistant)"  # Open Food Facts asks every app to name itself
ONLINE_LIMIT = 5
LABEL_TOKENS = 1000

LABEL_PROMPT = """You read the nutrition facts table (valori nutrizionali) on a photo of a food or drink packet, so the \
numbers can be saved for that product. Read the column per 100 g (or per 100 ml). When there's only a column per \
serving, work out per 100 g from the serving's size. Energy in kcal; with only kJ, divide by 4.184. Read the \
numbers exactly as printed; don't estimate. Fat, carbohydrates and protein in grams; ignore the rest (sugars, \
fibre, salt). serving_g is one serving or one piece as printed on the packet (e.g. "per porzione (30 g)"), else null. \
name and brand only when the photo shows them, else null.

Answer with JSON only, nothing before or after it:
{"kcal_100g": 389, "protein_100g": 13.5, "carbs_100g": 58.7, "fat_100g": 7, "serving_g": 40, "name": "Fiocchi \
d'avena", "brand": "Quaker"}
or, when the photo has no nutrition table you can read: {"error": "what's wrong, in a few words"}"""


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def _num(value) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def product(raw: dict) -> dict | None:
    """An Open Food Facts product as a food, or None without a name or the four numbers per 100 g."""
    nut = raw.get("nutriments") or {}
    kcal = _num(nut.get("energy-kcal_100g"))
    if kcal is None and (kj := _num(nut.get("energy-kj_100g"))) is not None:
        kcal = kj / 4.184
    values = [kcal, *(_num(nut.get(f"{k}_100g")) for k in ("proteins", "carbohydrates", "fat"))]
    name = (raw.get("product_name_it") or raw.get("product_name") or "").strip()
    if not name or any(v is None for v in values):
        return None
    brands = raw.get("brands") or ""
    brand = (brands[0] if isinstance(brands, list) and brands else str(brands).split(",")[0]).strip()
    return {"name": name, "brand": brand, "barcode": str(raw.get("code") or "") or None,
            **dict(zip(("kcal_100g", "protein_100g", "carbs_100g", "fat_100g"), values)),
            "serving_g": _num(raw.get("serving_quantity")) or None, "pack": (raw.get("quantity") or "").strip()}


class OpenFoodFacts:
    def __init__(self, http: httpx.AsyncClient | None = None):
        self._http = http or httpx.AsyncClient(timeout=15)

    async def _get(self, url: str, params: dict) -> dict:
        r = await self._http.get(url, params=params, headers={"User-Agent": USER_AGENT})
        if r.status_code == 429:
            raise RuntimeError("Open Food Facts is busy (too many searches); try again in a minute, or use web_search.")
        if r.status_code == 404:
            return {}
        r.raise_for_status()
        return r.json()

    async def search(self, text: str) -> list[dict]:
        found = await self._get(SEARCH, {"q": text, "langs": "it,en", "page_size": 10, "fields": FIELDS})
        return [p for p in map(product, found.get("hits") or []) if p][:ONLINE_LIMIT]

    async def barcode(self, code: str) -> dict | None:
        found = await self._get(PRODUCT.format(code), {"fields": FIELDS})
        return product(found["product"]) if found.get("status") == 1 and found.get("product") else None


async def read_label(ask: Callable[[str, list[dict], int], Awaitable[str]], image: bytes,
                     media_type: str) -> dict:
    """The label's numbers per 100 g, with serving_g, name and brand when it shows them. Raises ValueError when
    the photo can't be read."""
    from ..notebook import parse_json  # notebook imports a lot; only here
    content = [{"type": "image", "source": {"type": "base64", "media_type": media_type,
                                            "data": base64.b64encode(image).decode()}},
               {"type": "text", "text": "The nutrition label."}]
    try:
        answer = parse_json(await ask(LABEL_PROMPT, content, LABEL_TOKENS))
    except RuntimeError as e:
        raise ValueError(f"couldn't read the label ({e})") from e
    if not isinstance(answer, dict) or answer.get("error"):
        raise ValueError(f"couldn't read the label: {answer.get('error') if isinstance(answer, dict) else answer}")
    values = {k: _num(answer.get(k)) for k in ("kcal_100g", "protein_100g", "carbs_100g", "fat_100g")}
    if any(v is None for v in values.values()):
        raise ValueError("couldn't read every number on the label (energy, protein, carbs and fat)")
    text = {k: str(answer.get(k) or "").strip() for k in ("name", "brand")}
    return {**values, "serving_g": _num(answer.get("serving_g")) or None, **text}


def _g(value: float | None) -> str:
    return f"{value:g} g" if value else ""


def describe(food: dict) -> str:
    """One line for the model: the id to use in log_meal's items, the numbers per 100 g, the portions."""
    line = (f"[food {food['id']}] {food['name']}" + (f" · {food['brand']}" if food["brand"] else "")
            + f" · per 100 g: {food['kcal_100g']:.0f} kcal, P {food['protein_100g']:g} g, C {food['carbs_100g']:g} g, "
              f"F {food['fat_100g']:g} g")
    line += f" · serving {_g(food['serving_g'])}" if food["serving_g"] else ""
    line += f" · usual {_g(food['usual_g'])}" if food["usual_g"] else ""
    line += f" · eaten {food['uses']}×" if food["uses"] else ""
    return line + f" · from {food['source']}"


def nutrition_tools(foods: FoodDB, off: OpenFoodFacts) -> list[Tool]:
    def online_line(i: int, p: dict) -> str:
        line = (f"{i}. {p['name']}" + (f" · {p['brand']}" if p["brand"] else "")
                + f" · per 100 g: {p['kcal_100g']:.0f} kcal, P {p['protein_100g']:g} g, C {p['carbs_100g']:g} g, "
                  f"F {p['fat_100g']:g} g")
        line += f" · serving {_g(p['serving_g'])}" if p["serving_g"] else ""
        line += f" · pack {p['pack']}" if p["pack"] else ""
        return line + (f" · barcode {p['barcode']}" if p["barcode"] else "")

    async def by_barcode(code: str) -> str:
        if saved := foods.by_barcode(code):
            return f"Saved food:\n{describe(saved)}"
        p = await off.barcode(code)
        if p is None:
            return f"Open Food Facts doesn't have barcode {code} (or not its nutrition values)."
        saved = foods.save(p["name"], p["kcal_100g"], p["protein_100g"], p["carbs_100g"], p["fat_100g"], "off",
                           brand=p["brand"], barcode=code, serving_g=p["serving_g"], source_ref=code)
        return f"From Open Food Facts, now saved:\n{describe(saved)}" + (f" · pack {p['pack']}" if p["pack"] else "")

    async def find_food(query: str | None = None, barcode: str | None = None, online: bool = False) -> str:
        if barcode:
            return await by_barcode("".join(barcode.split()))
        if not (query or "").strip():
            raise ValueError("give a query or a barcode")
        saved = foods.search(query)
        lines = ["Saved foods:", *map(describe, saved)] if saved else [f"No saved food matches '{query}'."]
        if saved and not online:
            return "\n".join(lines)
        found = await off.search(query)
        if found:
            lines += ["Open Food Facts (to use one, call find_food with its barcode; that saves it):",
                      *(online_line(i, p) for i, p in enumerate(found, 1))]
        else:
            lines.append("Nothing on Open Food Facts with nutrition values.")
        return "\n".join(lines)

    async def save_food(name: str, kcal_100g: float, protein_100g: float, carbs_100g: float, fat_100g: float,
                        source: str, brand: str | None = None, barcode: str | None = None,
                        serving_g: float | None = None, source_ref: str | None = None,
                        aliases: str | None = None) -> str:
        food = foods.save(name, kcal_100g, protein_100g, carbs_100g, fat_100g, source, brand or "", barcode,
                          serving_g, source_ref or "", aliases or "")
        return f"Saved:\n{describe(food)}"

    async def update_food(food_id: int, name: str | None = None, brand: str | None = None,
                          barcode: str | None = None, kcal_100g: float | None = None,
                          protein_100g: float | None = None, carbs_100g: float | None = None,
                          fat_100g: float | None = None, serving_g: float | None = None, usual_g: float | None = None,
                          source: str | None = None, aliases: str | None = None) -> str:
        food = foods.update(food_id, name=name, brand=brand, barcode=barcode, kcal_100g=kcal_100g,
                            protein_100g=protein_100g, carbs_100g=carbs_100g, fat_100g=fat_100g,
                            serving_g=serving_g, usual_g=usual_g, source=source, aliases=aliases)
        return f"Updated:\n{describe(food)}"

    per_100 = {"kcal_100g": {"type": "number", "description": "kcal per 100 g (per 100 ml for a drink)"},
               "protein_100g": {"type": "number"}, "carbs_100g": {"type": "number"}, "fat_100g": {"type": "number"}}
    details = {"brand": {"type": "string"},
               "barcode": {"type": "string", "description": "The EAN digits, when you can read them"},
               "serving_g": {"type": "number", "description": "One serving or one piece in grams, as the packet "
                             "says (a 125 g pot, a 30 g slice)"},
               "aliases": {"type": "string", "description": "Other names the user calls it, comma-separated"}}
    return [
        Tool("find_food", "Look up a food's real nutrition values: the foods already saved (what the user eats, "
             "with their usual portion) first; when none match, or with online, Open Food Facts (packaged foods, "
             "best for Italian supermarket brands). With a barcode, the exact product, saved for next time. Use the "
             "[food N] ids in log_meal's items.",
             _obj({"query": {"type": "string", "description": "Product and brand, e.g. 'yogurt greco Fage 0%'"},
                   "barcode": {"type": "string"},
                   "online": {"type": "boolean", "description": "Search Open Food Facts even when saved foods "
                              "match (none of them is the right one)"}}, []), find_food),
        Tool("save_food", "Save a food's values per 100 g so it's reused next time: read off a nutrition label in a "
             "photo (source label), from a web page (web, with the URL as source_ref), said by the user (user), or "
             "your own estimate for a plain food like pasta, an apple or olive oil (estimate). Saving a name and "
             "brand already saved updates it. Returns its [food N] id.",
             _obj({"name": {"type": "string", "description": "Short and specific: 'Yogurt greco 0%', 'Pasta "
                            "(dry)', 'Pizza margherita'"},
                   **per_100, "source": {"type": "string", "enum": [s for s in SOURCES if s != "off"]},
                   **details, "source_ref": {"type": "string"}},
                  ["name", "kcal_100g", "protein_100g", "carbs_100g", "fat_100g", "source"]), save_food),
        Tool("update_food", "Correct a saved food (the label says otherwise, a better name, the usual portion). Give "
             "only what changes.",
             _obj({"food_id": {"type": "integer"}, "name": {"type": "string"}, **per_100, **details,
                   "usual_g": {"type": "number", "description": "The portion the user usually has, in grams"},
                   "source": {"type": "string", "enum": list(SOURCES)}}, ["food_id"]), update_food),
    ]
