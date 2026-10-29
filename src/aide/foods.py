"""Foods the user eats, per 100 g, so a meal can be worked out from its items instead of guessed each time.

A food comes from Open Food Facts (by barcode), a nutrition label in a photo, a web page, the user, or the model's
own estimate (saved as it logs a meal with it), saved once and reused so the same food always gives the same
numbers. Each food keeps its usual portion (the last one eaten) and how often it's eaten, which ranks searches.
A meal logged from items keeps them in meal_items. Drinks are per 100 ml, the same as grams.
"""

import sqlite3
import unicodedata

from .db import utcnow
from .food import MACROS

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
EDITABLE = ("name", "brand", "barcode", *PER_100, "serving_g", "usual_g", "source", "source_ref", "aliases")
MAX_NAME = 100
MAX_PORTION = 5000  # g in one serving or one item
SEARCH_LIMIT = 5


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
             source_ref: str = "", aliases: str = "") -> dict:
        """Add a food, or update the one with the same barcode, or the same name and brand."""
        clean = self._clean({"name": name, "brand": brand, "barcode": barcode, "kcal_100g": kcal_100g,
                             "protein_100g": protein_100g, "carbs_100g": carbs_100g, "fat_100g": fat_100g,
                             "serving_g": serving_g, "source": source, "source_ref": source_ref,
                             "aliases": aliases})
        self._check(clean)
        key = normalize(f"{clean['name']} | {clean['brand']}")
        old = (clean["barcode"] and self.by_barcode(clean["barcode"])) or self._by_key(key)
        if old:
            return self.update(old["id"], **clean)  # None (no barcode, no serving) keeps what it has
        now = utcnow().isoformat()
        cur = self.conn.execute(
            "INSERT INTO foods (name, brand, key, barcode, kcal_100g, protein_100g, carbs_100g, fat_100g, "
            "serving_g, source, source_ref, aliases, created_at, updated_at) VALUES (:name, :brand, :key, :barcode, "
            ":kcal_100g, :protein_100g, :carbs_100g, :fat_100g, :serving_g, :source, :source_ref, :aliases, "
            ":now, :now)", {**clean, "key": key, "now": now})
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
        return {k: food[k] for k in ("id", "name", "brand", "barcode", *PER_100, "serving_g", "usual_g", "source")}

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
                    or self.save(item["name"], *(item[k] for k in PER_100), "estimate", brand=brand)
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
