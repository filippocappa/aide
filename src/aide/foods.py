"""Foods the user eats, per 100 g, so a meal can be worked out from its items instead of guessed each time.

A food comes from Open Food Facts (by barcode), a nutrition label in a photo, a web page, the user, or the model's
own estimate (saved as it logs a meal with it), saved once and reused so the same food always gives the same
numbers. Each food keeps its usual portion (the last one eaten) and how often it's eaten, which ranks searches.
A meal logged from items keeps them in meal_items. Drinks are per 100 ml, the same as grams.
A meal's water is worked out from its drinks (water_share), plus any plain water given on its own.
"""

import sqlite3
import unicodedata
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from .db import utcnow
from .food import MACROS, meal_emoji
from .nutrition import grade

SCHEMA = """
CREATE TABLE IF NOT EXISTS foods (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    brand        TEXT NOT NULL DEFAULT '',
    key          TEXT NOT NULL UNIQUE,  -- name and brand, lowercase without accents
    barcode      TEXT UNIQUE,
    kcal_100g    REAL NOT NULL,
    protein_100g REAL NOT NULL,
    carbs_100g   REAL NOT NULL,
    fat_100g     REAL NOT NULL,
    sugars_100g  REAL,  -- what the Nutri-Score needs besides the four above (nutrition.py), NULL when unknown
    sat_fat_100g REAL,
    fibre_100g   REAL,
    salt_100g    REAL,
    fvl_pct      REAL,  -- % fruit, vegetables, legumes (and olive, rapeseed, walnut oil)
    kind         TEXT NOT NULL DEFAULT 'general',  -- general | fat | drink | water | cheese | red_meat
    nutriscore   TEXT,  -- Open Food Facts' grade, a–e; else worked out from the numbers
    nova         INTEGER,  -- the processing group, 1–4: Open Food Facts', or Coach's estimate
    water_pct    REAL,  -- % of it that counts as water drunk, NULL to work it out from kind and numbers
    serving_g    REAL,  -- one serving as the packet says, NULL when unknown
    usual_g      REAL,  -- the portion the user had last time
    source       TEXT NOT NULL,  -- off | label | web | estimate | user
    source_ref   TEXT NOT NULL DEFAULT '',  -- a barcode or URL
    aliases      TEXT NOT NULL DEFAULT '',  -- other names it goes by, comma-separated
    uses         INTEGER NOT NULL DEFAULT 0,
    last_used    TEXT,
    created_at   TEXT NOT NULL,
    updated_at   TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS meal_items (
    id        INTEGER PRIMARY KEY,
    meal_id   INTEGER NOT NULL REFERENCES meals(id) ON DELETE CASCADE,
    food_id   INTEGER REFERENCES foods(id) ON DELETE SET NULL,  -- NULL for an item estimated on its own
    name      TEXT NOT NULL,
    grams     REAL,
    calories  REAL NOT NULL,
    protein_g REAL NOT NULL,
    carbs_g   REAL NOT NULL,
    fat_g     REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS meal_items_meal ON meal_items(meal_id);
"""

SOURCES = ("off", "label", "web", "estimate", "user")
PER_100 = ("kcal_100g", "protein_100g", "carbs_100g", "fat_100g")
QUALITY = ("sugars_100g", "sat_fat_100g", "fibre_100g", "salt_100g", "fvl_pct", "kind", "nutriscore", "nova",
           "water_pct")
EDITABLE = ("name", "brand", "barcode", *PER_100, *QUALITY, "serving_g", "usual_g", "source", "source_ref", "aliases")
KINDS = ("general", "fat", "drink", "water", "cheese", "red_meat")
QUALITY_COLUMNS = {"sugars_100g": "REAL", "sat_fat_100g": "REAL", "fibre_100g": "REAL", "salt_100g": "REAL",
                   "fvl_pct": "REAL", "kind": "TEXT NOT NULL DEFAULT 'general'", "nutriscore": "TEXT",
                   "nova": "INTEGER", "water_pct": "REAL"}
MAX_NAME = 100
MAX_PORTION = 5000  # g in one serving or one item
SEARCH_LIMIT = 5
RECENT_DAYS = 90  # how far back "what you eat" looks
RECENT_HOURS = 2  # eaten within this many hours of now's time of day counts double (breakfast in the morning)
RECENT_FOODS = 40
RECENT_MEALS = 10
ALCOHOL_KCAL = 15  # kcal per 100 ml beyond 4/4/9 × the macros: alcohol (~2 g, ~2.5% vol); less is labels rounding
MINERALS_PCT = 1  # what a drink holds besides water, protein, carbs and fat


def water_share(food: dict) -> float:
    """How much of a food counts as water drunk, 0–1. Plain water all of it; a drink what isn't protein, carbs, fat or
    minerals (coffee 0.98, cola 0.88, juice 0.88, milk 0.87); an alcoholic drink (kcal well over its macros' share)
    none, nor food. A food's water_pct, when set, says otherwise."""
    if food.get("water_pct") is not None:
        return food["water_pct"] / 100
    kind = food.get("kind") or "general"
    if kind == "water":
        return 1.0
    if kind != "drink":
        return 0.0
    p, c, f = food["protein_100g"], food["carbs_100g"], food["fat_100g"]
    if food["kcal_100g"] - (4 * p + 4 * c + 9 * f) >= ALCOHOL_KCAL:
        return 0.0
    return max(0.0, 100 - MINERALS_PCT - p - c - f) / 100


def normalize(text: str) -> str:
    """Lowercase, accents off, one space between words: 'Müller  Fitline' → 'muller fitline'."""
    plain = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode()
    return " ".join(plain.lower().split())


def items_line(items: list[dict]) -> str:
    return "Items: " + ", ".join(i["name"] + (f" {i['grams']:g} g" if i["grams"] else "") for i in items)


def free_notes(notes: str) -> str:
    """A meal's notes without the items line logging put first."""
    return notes.partition("\n")[2] if notes.startswith("Items: ") else notes


class FoodDB:
    def __init__(self, conn: sqlite3.Connection):
        self.conn = conn
        if self.conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'foods'").fetchone():
            have = {c["name"] for c in self.conn.execute("PRAGMA table_info(foods)")}
            for column, kind in QUALITY_COLUMNS.items():
                if column not in have:
                    self.conn.execute(f"ALTER TABLE foods ADD COLUMN {column} {kind}")
        self.conn.executescript(SCHEMA)

    def get(self, food_id: int) -> dict | None:
        row = self.conn.execute("SELECT * FROM foods WHERE id = ?", (food_id,)).fetchone()
        return dict(row) if row else None

    def find(self, food_id: int) -> dict:
        if (food := self.get(food_id)) is None:
            raise KeyError(f"no food {food_id}")
        return food

    def by_barcode(self, barcode: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM foods WHERE barcode = ?", (barcode.strip(),)).fetchone()
        return dict(row) if row else None

    def _by_key(self, key: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM foods WHERE key = ?", (key,)).fetchone()
        return dict(row) if row else None

    def search(self, text: str, limit: int = SEARCH_LIMIT) -> list[dict]:
        """Foods with every word of `text` in their name, brand or aliases; the most eaten first."""
        words = normalize(text).split()
        if not words:
            return []
        found = [dict(r) for r in self.conn.execute("SELECT * FROM foods ORDER BY id")
                 if all(w in normalize(f"{r['name']} {r['brand']} {r['aliases']}") for w in words)]
        found.sort(key=lambda f: (f["uses"], f["last_used"] or ""), reverse=True)
        return found[:limit]

    def recent(self, tz: ZoneInfo, text: str = "", limit: int = RECENT_FOODS) -> dict:
        """What the user eats, to log it again without the model: `foods` (eaten ones, or with `text` any saved food
        matching every word) and `meals` of more than one item, the same items once (the latest). Both ranked by how
        often they were had in the last RECENT_DAYS, each time near now's time of day counting double."""
        now = datetime.now(tz)
        since = (utcnow() - timedelta(days=RECENT_DAYS)).isoformat()
        rows = [dict(r) for r in self.conn.execute(
            "SELECT i.meal_id, i.food_id, i.name AS item, i.grams, m.name, m.emoji, m.eaten_at, m.calories "
            "FROM meal_items i JOIN meals m ON m.id = i.meal_id WHERE m.eaten_at >= ? ORDER BY m.eaten_at, i.id",
            (since,))]

        def near(eaten_at: str) -> bool:
            when = datetime.fromisoformat(eaten_at).astimezone(tz)
            gap = abs((when.hour * 60 + when.minute) - (now.hour * 60 + now.minute))
            return min(gap, 1440 - gap) <= RECENT_HOURS * 60

        def score(times: list[str]) -> tuple[int, str]:
            return len(times) + sum(near(t) for t in times), max(times)

        eaten: dict[int, list[str]] = {}
        meals: dict[int, list[dict]] = {}
        for r in rows:
            if r["food_id"] is not None:
                eaten.setdefault(r["food_id"], []).append(r["eaten_at"])
            meals.setdefault(r["meal_id"], []).append(r)
        words = normalize(text).split()

        def matches(*names: str) -> bool:
            return all(w in normalize(" ".join(names)) for w in words)

        foods = [dict(r) for r in self.conn.execute("SELECT * FROM foods")]
        foods = [f for f in foods if matches(f["name"], f["brand"], f["aliases"]) if words or f["id"] in eaten
                 or f["uses"]]
        foods.sort(key=lambda f: (score(eaten[f["id"]]) if f["id"] in eaten else (0, ""), f["uses"],
                                  f["last_used"] or ""), reverse=True)

        same: dict[tuple, list[list[dict]]] = {}  # the same items, whatever the meal was called
        for items in meals.values():
            if len(items) > 1:
                key = tuple(sorted(i["food_id"] if i["food_id"] is not None else normalize(i["item"]) for i in items))
                same.setdefault(key, []).append(items)
        combos = [(score([m[0]["eaten_at"] for m in group]), len(group), group[-1]) for group in same.values()
                  if matches(group[-1][0]["name"], *(i["item"] for i in group[-1]))]
        combos.sort(key=lambda c: c[0], reverse=True)

        def local(stamp: str | None) -> str | None:
            return stamp and datetime.fromisoformat(stamp).astimezone(tz).replace(microsecond=0).isoformat()

        return {
            "foods": [{**self.as_json(f), "emoji": meal_emoji(f["name"]), "uses": f["uses"],
                       "last_used": local(f["last_used"])} for f in foods[:limit]],
            "meals": [{"id": m[0]["meal_id"], "name": m[0]["name"], "emoji": m[0]["emoji"] or meal_emoji(m[0]["name"]),
                       "calories": m[0]["calories"], "times": times, "last_eaten": local(m[0]["eaten_at"]),
                       "items": [{"food_id": i["food_id"], "name": i["item"], "grams": i["grams"] and round(i["grams"])}
                                 for i in m]}
                      for _, times, m in combos[:RECENT_MEALS]],
        }

    def latest(self, tz: ZoneInfo, text: str = "", limit: int = RECENT_FOODS) -> dict:
        """What the user ate, newest first: each saved food as it was had in a meal of the last RECENT_DAYS (the
        same food every time it was had), with `eaten_at`, `grams` and the `meal` it was in; with `text`, only foods
        with every word in their name, brand or other names. Items estimated on their own (no saved food) are left
        out: there's nothing to have again."""
        since = (utcnow() - timedelta(days=RECENT_DAYS)).isoformat()
        words = normalize(text).split()
        out = []
        for r in self.conn.execute(
                "SELECT f.*, i.grams AS item_grams, m.id AS meal_id, m.name AS meal_name, m.eaten_at "
                "FROM meal_items i JOIN meals m ON m.id = i.meal_id JOIN foods f ON f.id = i.food_id "
                "WHERE m.eaten_at >= ? ORDER BY m.eaten_at DESC, i.id", (since,)):
            r = dict(r)
            if not all(w in normalize(" ".join((r["name"], r["brand"] or "", r["aliases"] or ""))) for w in words):
                continue
            eaten = datetime.fromisoformat(r["eaten_at"]).astimezone(tz).replace(microsecond=0).isoformat()
            last = r["last_used"] and datetime.fromisoformat(r["last_used"]).astimezone(tz).replace(microsecond=0)
            out.append({**self.as_json(r), "emoji": meal_emoji(r["name"]), "uses": r["uses"],
                        "last_used": last and last.isoformat(), "eaten_at": eaten,
                        "grams": r["item_grams"] and round(r["item_grams"]), "meal_id": r["meal_id"],
                        "meal": r["meal_name"]})
            if len(out) == limit:
                break
        return {"foods": out, "meals": []}

    def _clean(self, changes: dict) -> dict:
        out = {}
        for key, value in changes.items():
            if key in ("name", "brand", "aliases", "source_ref"):
                value = " ".join(str(value or "").split())
                if key == "name" and not 0 < len(value) <= MAX_NAME:
                    raise ValueError(f"name must be 1–{MAX_NAME} characters")
            elif key == "barcode":
                value = "".join(str(value or "").split()) or None
                if value and not value.isdigit():
                    raise ValueError("a barcode is digits only")
            elif key in PER_100:
                top = 900 if key == "kcal_100g" else 100  # pure fat is 900 kcal per 100 g
                if not 0 <= float(value) <= top:
                    raise ValueError(f"{key} must be between 0 and {top}")
                value = float(value)
            elif key in ("sugars_100g", "sat_fat_100g", "fibre_100g", "salt_100g", "fvl_pct", "water_pct"):
                if value is not None and not 0 <= float(value) <= 100:
                    raise ValueError(f"{key} must be between 0 and 100")
                value = None if value is None else float(value)
            elif key == "kind" and value not in KINDS:
                raise ValueError(f"kind must be one of {', '.join(KINDS)}")
            elif key == "nutriscore":
                value = str(value or "").lower() or None
                if value and value not in "abcde":
                    raise ValueError("nutriscore is a to e")
            elif key == "nova":
                if value is not None and int(value) not in (1, 2, 3, 4):
                    raise ValueError("nova is 1 to 4")
                value = None if value is None else int(value)
            elif key in ("serving_g", "usual_g"):
                if value is not None and not 0 < float(value) <= MAX_PORTION:
                    raise ValueError(f"{key} must be between 0 and {MAX_PORTION}")
                value = None if value is None else float(value)
            elif key == "source" and value not in SOURCES:
                raise ValueError(f"source must be one of {', '.join(SOURCES)}")
            out[key] = value
        return out

    @staticmethod
    def _check(food: dict) -> None:
        if food["protein_100g"] + food["carbs_100g"] + food["fat_100g"] > 105:  # labels round a little
            raise ValueError("protein, carbs and fat add up to more than 100 g per 100 g")

    def save(self, name: str, kcal_100g: float, protein_100g: float, carbs_100g: float, fat_100g: float,
             source: str, brand: str = "", barcode: str | None = None, serving_g: float | None = None,
             source_ref: str = "", aliases: str = "", **quality) -> dict:
        """Add a food, or update the one with the same barcode, or the same name and brand. `quality`: any of
        QUALITY, for its Nutri-Score."""
        if unknown := set(quality) - set(QUALITY):
            raise ValueError(f"can't save {', '.join(sorted(unknown))}")
        clean = self._clean({"name": name, "brand": brand, "barcode": barcode, "kcal_100g": kcal_100g,
                             "protein_100g": protein_100g, "carbs_100g": carbs_100g, "fat_100g": fat_100g,
                             "serving_g": serving_g, "source": source, "source_ref": source_ref,
                             "aliases": aliases, **{k: v for k, v in quality.items() if v is not None}})
        self._check(clean)
        key = normalize(f"{clean['name']} | {clean['brand']}")
        old = (clean["barcode"] and self.by_barcode(clean["barcode"])) or self._by_key(key)
        if old:
            return self.update(old["id"], **clean)  # None (no barcode, no serving) keeps what it has
        now = utcnow().isoformat()
        row = {**clean, "key": key, "created_at": now, "updated_at": now}
        cur = self.conn.execute(f"INSERT INTO foods ({', '.join(row)}) VALUES ({', '.join(':' + k for k in row)})", row)
        return self.find(cur.lastrowid)

    def update(self, food_id: int, **changes) -> dict:
        food = self.find(food_id)
        unknown = set(changes) - set(EDITABLE)
        if unknown:
            raise ValueError(f"can't change {', '.join(sorted(unknown))}")
        clean = self._clean({k: v for k, v in changes.items() if v is not None})
        merged = {**food, **clean}
        self._check(merged)
        key = normalize(f"{merged['name']} | {merged['brand']}")
        other = self._by_key(key)
        if other and other["id"] != food_id:
            raise ValueError(f"there's already a food called that: [food {other['id']}] {other['name']}")
        if clean.get("barcode") and (owner := self.by_barcode(clean["barcode"])) and owner["id"] != food_id:
            raise ValueError(f"barcode {clean['barcode']} is already [food {owner['id']}] {owner['name']}")
        clean["key"] = key
        self.conn.execute(f"UPDATE foods SET {', '.join(f'{c} = ?' for c in clean)}, updated_at = ? WHERE id = ?",
                          (*clean.values(), utcnow().isoformat(), food_id))
        return self.find(food_id)

    def touch(self, food_id: int, grams: float, count: bool = True) -> None:
        """The user had `grams` of it: that's the usual portion now, and (with count) one more use."""
        self.conn.execute("UPDATE foods SET usual_g = ?, uses = uses + ?, last_used = ? WHERE id = ?",
                          (grams, 1 if count else 0, utcnow().isoformat(), food_id))

    def as_json(self, food: dict) -> dict:
        return {**{k: food[k] for k in ("id", "name", "brand", "barcode", *PER_100, "serving_g", "usual_g", "source",
                                        "nova")}, "grade": grade(food)}

    # -- a meal's items -------------------------------------------------------

    def resolve(self, items: list[dict]) -> list[dict]:
        """Each item with its calories and macros from a food and its grams: a saved food (its usual portion, or one
        serving, without grams), or a new one with its numbers per 100 g, saved as an estimate first (a name and brand
        already saved is that food, as saved)."""
        out = []
        for item in items:
            if item.get("food_id") is not None:
                food = self.find(item["food_id"])
                grams = item.get("grams") or food["usual_g"] or food["serving_g"]
                if not grams:
                    raise ValueError(f"how many grams of {food['name']}? It has no usual portion yet")
            else:
                missing = [k for k in ("name", "grams", *PER_100) if item.get(k) is None]
                if missing:
                    raise ValueError(f"an item without food_id needs {', '.join(missing)} (its numbers per 100 g)")
                brand = item.get("brand") or ""
                food = self._by_key(normalize(f"{' '.join(item['name'].split())} | {' '.join(brand.split())}")) \
                    or self.save(item["name"], *(item[k] for k in PER_100), "estimate", brand=brand,
                                 **{k: item.get(k) for k in QUALITY if k != "nutriscore"})
                grams = item["grams"]
            if not 0 < grams <= MAX_PORTION:
                raise ValueError(f"grams must be between 0 and {MAX_PORTION}")
            scale = grams / 100
            out.append({"food_id": food["id"], "name": food["name"], "grams": grams,
                        "calories": food["kcal_100g"] * scale, "protein_g": food["protein_100g"] * scale,
                        "carbs_g": food["carbs_100g"] * scale, "fat_g": food["fat_100g"] * scale})
        return out

    def from_items(self, items: list[dict], notes: str | None) -> tuple[list[dict], dict, str]:
        """The resolved items, the meal's totals and its notes (the items line first). No items is a meal of
        nothing but water or caffeine."""
        rows = self.resolve(items)
        sums = {k: sum(r[k] for r in rows) for k in MACROS}
        return rows, sums, "\n".join(filter(None, [rows and items_line(rows), (notes or "").strip()]))

    def water(self, items: list[dict]) -> int:
        """ml of water drunk in a meal's items (resolved rows or stored meal_items): each saved food's grams times its
        water share; an item estimated on its own, none."""
        total = 0.0
        for i in items:
            if i.get("food_id") is not None and i.get("grams") and (food := self.get(i["food_id"])):
                total += i["grams"] * water_share(food)
        return round(total)

    def keep_items(self, meal_id: int, rows: list[dict], count: bool) -> None:
        """Store a meal's items; each saved food's portion becomes its usual (and, with count, one more use)."""
        self.set_items(meal_id, rows)
        for r in rows:
            if r["food_id"] is not None:
                self.touch(r["food_id"], r["grams"], count)

    def items(self, meal_id: int) -> list[dict]:
        return [dict(r) for r in self.conn.execute("SELECT * FROM meal_items WHERE meal_id = ? ORDER BY id",
                                                   (meal_id,))]

    def set_items(self, meal_id: int, items: list[dict]) -> None:
        self.conn.execute("BEGIN")
        try:
            self.conn.execute("DELETE FROM meal_items WHERE meal_id = ?", (meal_id,))
            self.conn.executemany(
                "INSERT INTO meal_items (meal_id, food_id, name, grams, calories, protein_g, carbs_g, fat_g) "
                "VALUES (:meal_id, :food_id, :name, :grams, :calories, :protein_g, :carbs_g, :fat_g)",
                [{**i, "meal_id": meal_id} for i in items])
            self.conn.execute("COMMIT")
        except BaseException:
            self.conn.execute("ROLLBACK")
            raise
