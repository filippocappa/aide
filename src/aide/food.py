"""Food log: meals with estimated calories and macros, and daily goals. Contract in docs/API.md, "Food".

The numbers are the model's estimates from a photo or a description, so they're rounded: calories to 10,
grams to 1. Days are local days (AIDE_TIMEZONE); eaten_at is stored in UTC. Water (ml) and caffeine (mg) go along,
0 when there's none; the phone writes every meal to Apple Health.
"""

import json
import re
import sqlite3
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from .db import utcnow

SCHEMA = """
CREATE TABLE IF NOT EXISTS meals (
    id         INTEGER PRIMARY KEY,
    eaten_at   TEXT NOT NULL,  -- UTC
    name       TEXT NOT NULL,
    calories   INTEGER NOT NULL,
    protein_g  INTEGER NOT NULL,
    carbs_g    INTEGER NOT NULL,
    fat_g      INTEGER NOT NULL,
    water_ml   INTEGER NOT NULL DEFAULT 0,
    caffeine_mg INTEGER NOT NULL DEFAULT 0,
    photo      TEXT,  -- photo id (photos.py), NULL without one
    emoji      TEXT,  -- Coach's, NULL for a guess from the name (meal_emoji)
    notes      TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS meals_eaten ON meals(eaten_at);
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL  -- JSON
);
"""

MACROS = ("calories", "protein_g", "carbs_g", "fat_g")
DRINKS = ("water_ml", "caffeine_mg")  # what a meal also carries to Apple Health; no goals for them
LIMITS = {"calories": 10_000, "protein_g": 1_000, "carbs_g": 1_000, "fat_g": 1_000,  # per meal, and per goal
          "water_ml": 10_000, "caffeine_mg": 2_000}
MAX_NAME = 100
MAX_NOTES = 500
EDITABLE = ("name", "eaten_at", *MACROS, *DRINKS, "notes", "emoji")
# A meal without Coach's emoji gets the first of these its name mentions (Italian and English), else a plate. Each
# word matches from the start of a word in the name (regex).
EMOJI = [
    ("🍝", r"pasta spaghetti penne fusilli rigatoni lasagn gnocchi tortellini ravioli agnolotti tagliatell "
           r"orecchiette cappelletti carbonara"),
    ("🍕", r"pizza focaccia"), ("🍣", r"sushi"), ("🍔", r"burger hamburger"), ("🍟", r"fries patatine"),
    ("🥪", r"sandwich panino piadina tramezzino wrap toast"), ("🥐", r"croissant cornetto brioche"),
    ("🍞", r"bread pane\b fette crackers grissini"), ("🥣", r"oat avena porridge cereal muesli granola"),
    ("🥗", r"salad insalata"), ("🍲", r"soup zuppa minestr vellutata stew"), ("🍚", r"rice riso risotto"),
    ("🍗", r"chicken pollo turkey tacchino"), ("🥩", r"steak bistecca beef manzo meat carne pork maiale"),
    ("🐟", r"fish pesce salmon salmone tuna tonno merluzzo"), ("🥚", r"egg uova uovo omelette frittata"),
    ("🧀", r"cheese formaggio mozzarella parmigiano ricotta"), ("🥛", r"milk latte yogurt yoghurt kefir skyr"),
    ("🫘", r"lentil lenticchie beans fagioli chickpea ceci\b legum"), ("🥔", r"potato patat"),
    ("🥕", r"carot carrot verdur vegetabl zucchin broccol spinac"),
    ("🍫", r"chocolate cioccolat nutella nocciolata bar\b barrett"), ("🍪", r"biscuit biscott cookie"),
    ("🍰", r"cake torta tiramis"), ("🍦", r"ice\s?cream gelato"),
    ("🥜", r"nuts?\b noci mandorle almond peanut arachidi"), ("🍌", r"banana"), ("🍎", r"apple mela\b mele\b"),
    ("🍊", r"orange arancia mandarin"), ("🍓", r"fruit frutta berries fragol"),
    ("🥤", r"shake protein whey frullato smoothie coke cola\b soda"), ("🧃", r"juice succo"),
    ("☕", r"coffee caff espresso cappuccino tea\b tè\b"), ("🍺", r"beer birra"),
    ("🍷", r"wine vino spritz barbera nebbiolo barolo prosecco"),
    ("💧", r"water acqua"),
]
MAX_RANGE = 92  # days of meals in one read
FOOD_METRICS = ("logged", "protein_g", "calories")  # what a food objective or habit counts days by
CALORIE_BAND = 0.1  # a calorie goal is met within 10% either way


def _round(key: str, value: float) -> int:
    if not 0 <= value <= LIMITS[key]:
        raise ValueError(f"{key} must be between 0 and {LIMITS[key]}")
    return int(value / 10 + 0.5) * 10 if key == "calories" else int(value + 0.5)  # halves up, unlike round()


def meal_emoji(name: str) -> str:
    """The emoji for the first food the name mentions ("Pasta with mushroom sauce": 🍝), else 🍽️."""
    found = [(m.start(), n, emoji) for n, (emoji, words) in enumerate(EMOJI) for word in words.split()
             if (m := re.search(r"\b" + word, name, re.I))]
    return min(found)[2] if found else "🍽️"


class FoodStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo):
        self.conn = conn
        self.tz = tz
        if self.conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'meals'").fetchone():
            have = {c["name"] for c in self.conn.execute("PRAGMA table_info(meals)")}
            for column in DRINKS:
                if column not in have:
                    self.conn.execute(f"ALTER TABLE meals ADD COLUMN {column} INTEGER NOT NULL DEFAULT 0")
            if "emoji" not in have:
                self.conn.execute("ALTER TABLE meals ADD COLUMN emoji TEXT")
        self.conn.executescript(SCHEMA)
        self.on_change: list = []  # called when a meal is added, changed or deleted (the phone writes it to Health)

    def _changed(self) -> None:
        for callback in self.on_change:
            callback()

    def today(self) -> date:
        return datetime.now(self.tz).date()

    # -- meals ----------------------------------------------------------------

    def get(self, meal_id: int) -> dict | None:
        row = self.conn.execute("SELECT * FROM meals WHERE id = ?", (meal_id,)).fetchone()
        return dict(row) if row else None

    def find(self, meal_id: int) -> dict:
        if (meal := self.get(meal_id)) is None:
            raise KeyError(f"no meal {meal_id}")
        return meal

    def _clean(self, changes: dict) -> dict:
        out = {}
        for key, value in changes.items():
            if key == "name":
                value = " ".join(str(value).split())
                if not value or len(value) > MAX_NAME:
                    raise ValueError(f"name must be 1–{MAX_NAME} characters")
            elif key == "notes":
                value = str(value or "").strip()[:MAX_NOTES]
            elif key == "emoji":
                value = str(value or "").strip()[:8] or None
            elif key == "eaten_at":
                value = self._eaten_at(value)
            elif key in MACROS or key in DRINKS:
                value = _round(key, value)
            out[key] = value
        return out

    def _eaten_at(self, value: datetime | str) -> str:
        when = datetime.fromisoformat(value) if isinstance(value, str) else value
        when = when.replace(tzinfo=self.tz) if when.tzinfo is None else when
        if when > utcnow() + timedelta(hours=1):
            raise ValueError("a meal can't be in the future")
        return when.astimezone(ZoneInfo("UTC")).isoformat()

    def add(self, name: str, calories: float, protein_g: float, carbs_g: float, fat_g: float,
            eaten_at: datetime | str | None = None, photo: str | None = None, notes: str = "",
            water_ml: float = 0, caffeine_mg: float = 0, emoji: str | None = None) -> dict:
        clean = self._clean({"name": name, "calories": calories, "protein_g": protein_g, "carbs_g": carbs_g,
                             "fat_g": fat_g, "water_ml": water_ml, "caffeine_mg": caffeine_mg, "notes": notes,
                             "eaten_at": eaten_at or utcnow(), "emoji": emoji})
        now = utcnow().isoformat()
        cur = self.conn.execute(
            "INSERT INTO meals (eaten_at, name, calories, protein_g, carbs_g, fat_g, water_ml, caffeine_mg, photo, "
            "notes, emoji, created_at, updated_at) VALUES (:eaten_at, :name, :calories, :protein_g, :carbs_g, "
            ":fat_g, :water_ml, :caffeine_mg, :photo, :notes, :emoji, :now, :now)",
            {**clean, "photo": photo, "now": now})
        self._changed()
        return self.find(cur.lastrowid)

    def update(self, meal_id: int, **changes) -> dict:
        self.find(meal_id)
        unknown = set(changes) - set(EDITABLE)
        if unknown:
            raise ValueError(f"can't change {', '.join(sorted(unknown))}")
        clean = self._clean({k: v for k, v in changes.items() if v is not None})
        if clean:
            self.conn.execute(f"UPDATE meals SET {', '.join(f'{c} = ?' for c in clean)}, updated_at = ? WHERE id = ?",
                              (*clean.values(), utcnow().isoformat(), meal_id))
            self._changed()
        return self.find(meal_id)

    def delete(self, meal_id: int) -> bool:
        gone = self.conn.execute("DELETE FROM meals WHERE id = ?", (meal_id,)).rowcount > 0
        if gone:
            self._changed()
        return gone

    def _bounds(self, start: date, end: date) -> tuple[str, str]:
        """UTC bounds of the local days start..end, both included."""
        utc = ZoneInfo("UTC")
        lo = datetime.combine(start, time(), self.tz).astimezone(utc)
        hi = datetime.combine(end + timedelta(days=1), time(), self.tz).astimezone(utc)
        return lo.isoformat(), hi.isoformat()

    def day(self, d: date) -> list[dict]:
        return self.between(d, d)

    def between(self, start: date, end: date) -> list[dict]:
        lo, hi = self._bounds(start, end)
        return [dict(r) for r in self.conn.execute(
            "SELECT * FROM meals WHERE eaten_at >= ? AND eaten_at < ? ORDER BY eaten_at, id", (lo, hi))]

    def local_day(self, meal: dict) -> date:
        return datetime.fromisoformat(meal["eaten_at"]).astimezone(self.tz).date()

    def days(self, start: date, end: date) -> list[dict]:
        """Totals for every local day start..end, oldest first, zeros when empty."""
        by_day: dict[date, list[dict]] = {}
        for m in self.between(start, end):
            by_day.setdefault(self.local_day(m), []).append(m)
        every = (start + timedelta(days=i) for i in range((end - start).days + 1))
        return [{"date": d.isoformat(), "totals": totals(by_day.get(d, [])), "meals": len(by_day.get(d, []))}
                for d in every]

    def met_days(self, metric: str, start: date, end: date) -> set[date]:
        """The local days start..end (both included) that meet a food metric: a meal logged, the protein goal
        reached, or calories within CALORIE_BAND of the goal. None without the goal it needs."""
        goal = self.goals().get(metric)
        met = set()
        for day in self.days(start, end):
            if metric == "logged":
                ok = day["meals"] > 0
            elif not goal:
                ok = False
            elif metric == "protein_g":
                ok = day["totals"]["protein_g"] >= goal
            else:
                ok = day["meals"] > 0 and abs(day["totals"]["calories"] - goal) <= goal * CALORIE_BAND
            if ok:
                met.add(date.fromisoformat(day["date"]))
        return met

    def first_day(self) -> date | None:
        """The local day of the first meal logged."""
        row = self.conn.execute("SELECT * FROM meals ORDER BY eaten_at LIMIT 1").fetchone()
        return self.local_day(dict(row)) if row else None

    def as_json(self, meal: dict) -> dict:
        return {"id": meal["id"], "name": meal["name"],
                "eaten_at": datetime.fromisoformat(meal["eaten_at"]).astimezone(self.tz).replace(microsecond=0).isoformat(),
                **{k: meal[k] for k in (*MACROS, *DRINKS)}, "photo": meal["photo"], "notes": meal["notes"],
                "emoji": meal.get("emoji") or meal_emoji(meal["name"])}

    # -- goals ----------------------------------------------------------------

    def goals(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'food_goals'").fetchone()
        saved = json.loads(row["value"]) if row else {}
        return {k: saved.get(k) for k in MACROS}

    def set_goals(self, goals: dict) -> dict:
        """Replace the goals with `goals`; a missing, null or 0 key means no goal for it."""
        unknown = set(goals) - set(MACROS)
        if unknown:
            raise ValueError(f"unknown goal {', '.join(sorted(unknown))}; expected {', '.join(MACROS)}")
        clean = {k: _round(k, goals[k]) if goals.get(k) else None for k in MACROS}  # 0 is no goal too
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('food_goals', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(clean),))
        return self.goals()

    # -- a setting the API keeps: Coach's food-log chat, a new one each day ----

    def chat(self) -> str | None:
        return self.chat_day()[0]

    def chat_day(self) -> tuple[str | None, date | None]:
        """The Food log chat and the day it's for (None for one made before chats were daily)."""
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'food_chat'").fetchone()
        value = json.loads(row["value"]) if row else None
        if isinstance(value, dict):
            return value["id"], date.fromisoformat(value["day"])
        return value, None

    def set_chat(self, public_id: str, day: date) -> None:
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('food_chat', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                          (json.dumps({"id": public_id, "day": day.isoformat()}),))


def totals(meals: list[dict]) -> dict:
    return {k: sum(m[k] for m in meals) for k in (*MACROS, *DRINKS)}
