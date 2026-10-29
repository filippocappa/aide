"""What to eat and how the day went. Contract in docs/API.md, "Food".

Targets: the rest-day base (the food goals) plus what the day's workouts burned, as the Watch says, mostly as carbs;
before a run, a run in the calendar counts at the user's usual kcal a minute. A food's grade is its Nutri-Score
(the 2023 rules), Open Food Facts' grade when it has one, else worked out from its numbers per 100 g. The day score
(0–100) is 60% how close the day came to its targets and 40% quality: half the day's nutrients (fibre, fruit and veg,
saturated fat, free sugars, salt against guidelines), a quarter how little was ultra-processed (NOVA 4) and a quarter
the foods' grades. None of it needs a model call; only proposing targets does (`PROPOSE_PROMPT`, run by the API
through the engine).
"""

import json
import re
import sqlite3
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from .food import MACROS, FoodStore, totals
from .health import HealthStore, workout_date, workout_minutes

KINDS = ("general", "fat", "drink", "water", "cheese", "red_meat")
QUALITY = ("sugars_100g", "sat_fat_100g", "fibre_100g", "salt_100g", "fvl_pct")
GRADES = "abcde"
GRADE_POINTS = {"a": 100, "b": 75, "c": 50, "d": 25, "e": 0}
GOALS = ("lose", "keep", "gain", "perform")
WORKOUTS = {"on": True, "share": 1.0, "carbs_pct": 80}  # what a workout adds, by default
PROFILE = ("weight_kg", "height_cm", "age", "sex", "goal", "note")
MAX_NOTE = 500
MAX_ANSWERS = 8  # answers to Coach's questions kept for the next proposals
RUN_WORDS = re.compile(r"\b(run|runs|running|jog|jogging|corsa|corsetta|correre)\b", re.I)
RUN_KCAL_MIN = 11.0  # kcal a minute of running, before the user's own runs say otherwise
KJ = 4.184

# -- Nutri-Score (2023) ---------------------------------------------------------------------------------------------

ENERGY = [335 * i for i in range(1, 11)]  # kJ per 100 g
SUGARS = [3.4, 6.8, 10, 14, 17, 20, 24, 27, 31, 34, 37, 41, 44, 48, 51]
SAT_FAT = list(range(1, 11))
SALT = [round(0.2 * i, 1) for i in range(1, 21)]
PROTEIN = [2.4, 4.8, 7.2, 9.6, 12, 14, 16]
FIBRE = [3.0, 4.1, 5.2, 6.3, 7.4]
SAT_ENERGY = [120 * i for i in range(1, 11)]  # fats: kJ from saturates
SAT_RATIO = [10, 16, 22, 28, 34, 40, 46, 52, 58, 64]  # fats: saturates as % of fat, at or above
DRINK_ENERGY = [30, 90, 150, 210, 240, 270, 300, 330, 360, 390]
DRINK_SUGARS = [0.5, 2, 3.5, 5, 6, 7, 8, 9, 10, 11]
DRINK_PROTEIN = [1.2, 1.5, 1.8, 2.1, 2.4, 2.7, 3.0]


def _over(value: float, steps: list[float]) -> int:
    return sum(value > s for s in steps)


def _fvl(pct: float, drink: bool = False) -> int:
    """Fruit, vegetables, legumes (and olive, rapeseed and walnut oil) as % of the food."""
    if pct > 80:
        return 6 if drink else 5
    if pct > 60:
        return 4 if drink else 2
    if pct > 40:
        return 2 if drink else 1
    return 0


def nutriscore(food: dict) -> str | None:
    """The 2023 Nutri-Score grade, a to e, from a food's numbers per 100 g (100 ml for a drink) and its kind; None
    without sugars, saturated fat and salt. Fibre and the fruit, vegetable and legume share are 0 when missing."""
    kind = food.get("kind") or "general"
    if kind == "water":
        return "a"
    if any(food.get(k) is None for k in ("sugars_100g", "sat_fat_100g", "salt_100g")):
        return None
    kj = food["kcal_100g"] * KJ
    sugars, sat, salt = food["sugars_100g"], food["sat_fat_100g"], food["salt_100g"]
    fibre, fvl, protein = food.get("fibre_100g") or 0, food.get("fvl_pct") or 0, food["protein_100g"]
    if kind == "drink":
        bad = _over(kj, DRINK_ENERGY) + _over(sugars, DRINK_SUGARS) + _over(sat, SAT_FAT) + _over(salt, SALT)
        score = bad - (_fvl(fvl, drink=True) + _over(fibre, FIBRE) + _over(protein, DRINK_PROTEIN))
        return "b" if score <= 2 else "c" if score <= 6 else "d" if score <= 9 else "e"
    if kind == "fat":
        ratio = 100 * sat / food["fat_100g"] if food["fat_100g"] else 0
        bad = (_over(sat * 37, SAT_ENERGY) + _over(sugars, SUGARS) + sum(ratio >= s for s in SAT_RATIO)
               + _over(salt, SALT))
        good = _fvl(fvl) + _over(fibre, FIBRE) + (0 if bad >= 7 else _over(protein, PROTEIN))
        score = bad - good
        return "a" if score <= -6 else "b" if score <= 2 else "c" if score <= 10 else "d" if score <= 18 else "e"
    bad = _over(kj, ENERGY) + _over(sugars, SUGARS) + _over(sat, SAT_FAT) + _over(salt, SALT)
    protein_points = _over(protein, PROTEIN)
    if kind == "red_meat":
        protein_points = min(protein_points, 2)
    if bad >= 11 and kind != "cheese":
        protein_points = 0
    score = bad - (_fvl(fvl) + _over(fibre, FIBRE) + protein_points)
    return "a" if score <= 0 else "b" if score <= 2 else "c" if score <= 10 else "d" if score <= 18 else "e"


def grade(food: dict | None) -> str | None:
    """A saved food's grade: Open Food Facts' when it has one, else worked out from its numbers."""
    if not food:
        return None
    return food.get("nutriscore") or nutriscore(food)


# -- the day score ---------------------------------------------------------------------------------------------------

WEIGHTS = {"calories": 0.4, "protein_g": 0.3, "carbs_g": 0.15, "fat_g": 0.15}
BANDS = {"calories": 0.10, "carbs_g": 0.15, "fat_g": 0.15}  # full marks within this far of the target
ZERO_AT = 0.5  # nothing left at 50% off
NUMBERS_SHARE = 0.6
MIN_GRADED = 0.5  # the quality counts once graded foods are half the day's calories


def _closeness(eaten: float, target: float, key: str, final: bool) -> float:
    """1 on target, falling to 0 at ZERO_AT off. Protein only counts when short of its target; before the day is
    over (not final) only going over counts, since there's still time to eat."""
    r = eaten / target
    if key == "protein_g":
        return 1.0 if r >= 1 or not final else max(0.0, (r - ZERO_AT) / (1 - ZERO_AT))
    off = abs(r - 1) if final else max(0.0, r - 1)
    band = BANDS[key]
    return 1.0 if off <= band else max(0.0, 1 - (off - band) / (ZERO_AT - band))


def _ramp(value: float, full: float, zero: float) -> float:
    """1 at `full`, 0 at `zero`, straight in between; either way round (at least, or at most)."""
    return min(1.0, max(0.0, (value - zero) / (full - zero)))


# The day's nutrients: (what's added up, at least or at most, full marks at, nothing at). Fibre and fruit and veg
# in grams; saturated fat and free sugars as % of the day's kcal; salt in grams.
NUTRIENTS = {
    "fibre": ("fibre_g", "least", 30, 10),
    "fruit_veg": ("fvl_g", "least", 400, 0),
    "sat_fat": ("sat_fat_g", "most", 10, 20),
    "sugars": ("free_sugars_g", "most", 10, 25),
    "salt": ("salt_g", "most", 5, 10),
}
UPF_FULL, UPF_ZERO = 10, 50  # % of kcal ultra-processed (NOVA 4)
PARTS = {"nutrients": 0.5, "processing": 0.25, "grades": 0.25}
DAY_KCAL = 2000  # a meal's nutrients are judged per this many kcal


def _covered(items: list[dict], key: str) -> tuple[list[dict], float]:
    """The items that have `key`, and their share of the day's kcal."""
    total = sum(i["kcal"] for i in items)
    have = [i for i in items if i.get(key) is not None]
    return have, (sum(i["kcal"] for i in have) / total if total else 0.0)


def nutrients(items: list[dict], final: bool, scale: float | None = None) -> dict:
    """Each of the day's nutrients against its guideline, or None without enough data (items with it under half the
    day's kcal). Limits are scaled up to the whole day by that share; what's needed at least isn't, so missing
    data never earns marks. Before the day's over (not final), only the limits can cost. `scale` multiplies the
    grams (a meal's, to 2000 kcal); the shares of kcal stay as they are."""
    total = sum(i["kcal"] for i in items)
    out = {}
    for name, (key, way, full, zero) in NUTRIENTS.items():
        have, coverage = _covered(items, key)
        if not total or coverage < MIN_GRADED:
            out[name] = None
            continue
        amount = sum(i[key] for i in have)
        if way == "least":
            amount *= scale or 1
            out[name] = {"g": round(amount), "target": full,
                         "score": round(100 * _ramp(amount, full, zero)) if final else 100}
        elif name == "salt":
            day = amount / coverage * (scale or 1)
            out[name] = {"g": round(day, 1), "limit": full, "score": round(100 * _ramp(day, full, zero))}
        else:
            pct = 100 * amount / coverage * (9 if name == "sat_fat" else 4) / total
            out[name] = {"pct": round(pct, 1), "limit": full, "score": round(100 * _ramp(pct, full, zero))}
    return out


def processing(items: list[dict]) -> dict | None:
    """The share of the day's kcal from ultra-processed foods (NOVA 4), of the kcal with a NOVA group."""
    have, coverage = _covered(items, "nova")
    known = sum(i["kcal"] for i in have)
    if coverage < MIN_GRADED or not known:
        return None
    upf = 100 * sum(i["kcal"] for i in have if i["nova"] == 4) / known
    return {"upf_pct": round(upf), "score": round(100 * _ramp(upf, UPF_FULL, UPF_ZERO))}


def _quality(items: list[dict], final: bool, scale: float | None = None) -> dict:
    """Quality from what was eaten: its parts (nutrients, processing, grades), each 0–100 or None, and their
    weighted mean (None when none has enough data). `scale` (a meal's): its nutrients per 2000 kcal, all counted."""
    by_grade = {g: 0.0 for g in GRADES}
    for i in items:
        if i.get("grade") in by_grade:
            by_grade[i["grade"]] += i["kcal"]
    graded_kcal = sum(by_grade.values())
    total = sum(i["kcal"] for i in items)
    coverage = min(1.0, graded_kcal / total) if total else 0.0
    grades = (sum(GRADE_POINTS[g] * k for g, k in by_grade.items()) / graded_kcal
              if graded_kcal and coverage >= MIN_GRADED else None)
    found = nutrients(items, final, scale)
    scored = [n["score"] for n in found.values() if n]
    upf = processing(items)
    parts = {"nutrients": sum(scored) / len(scored) if scored else None,
             "processing": upf["score"] if upf else None, "grades": grades}
    weighed = {k: v for k, v in parts.items() if v is not None}
    quality = (sum(PARTS[k] * v for k, v in weighed.items()) / sum(PARTS[k] for k in weighed)) if weighed else None
    return {"quality": quality, "parts": parts, "nutrients": found, "processing": upf, "by_grade": by_grade,
            "graded": coverage}


def score(eaten: dict, targets: dict, items: list[dict], final: bool) -> dict | None:
    """The day's score from its totals, its targets and what was eaten (`items`: each with its kcal, and when known
    its grade, nova and nutrients in grams, as `Nutrition.items` gives them). Without targets it's the quality alone.
    None before anything's eaten, or when neither has anything to go on."""
    if not eaten["calories"]:
        return None
    set_ = {k: targets[k] for k in MACROS if targets.get(k)}
    numbers = None
    if set_:
        weight = sum(WEIGHTS[k] for k in set_)
        numbers = 100 * sum(WEIGHTS[k] * _closeness(eaten[k], t, k, final) for k, t in set_.items()) / weight
    q = _quality(items, final)
    quality = q["quality"]
    if numbers is not None and quality is not None:
        total = NUMBERS_SHARE * numbers + (1 - NUMBERS_SHARE) * quality
    else:
        total = numbers if numbers is not None else quality
    if total is None:
        return None
    return {"score": round(total), "final": final, "numbers": None if numbers is None else round(numbers),
            "quality": None if quality is None else round(quality), "graded": round(q["graded"], 2),
            "grades": {g: round(k) for g, k in q["by_grade"].items()},
            "parts": {k: None if v is None else round(v) for k, v in q["parts"].items()},
            "nutrients": q["nutrients"], "processing": q["processing"]}


def meal_quality(items: list[dict]) -> int | None:  # one item works the same: a food's quality
    """A meal's quality, 0–100, the day's recipe on its items with its nutrients per 2000 kcal (a side of carrots
    is full of fibre for its calories, a pastry isn't); None without enough data or calories."""
    total = sum(i["kcal"] for i in items)
    if total < 1:
        return None
    q = _quality(items, final=True, scale=DAY_KCAL / total)["quality"]
    return None if q is None else round(q)


def weakest(s: dict | None) -> str | None:
    """The day's weakest quality point in a few words ("fibre 14/30 g", "40% ultra-processed"), or None."""
    if not s:
        return None
    worst = None
    for name, n in (s.get("nutrients") or {}).items():
        if n and n["score"] < 70 and (worst is None or n["score"] < worst[0]):
            label = {"fibre": f"fibre {n.get('g')}/30 g", "fruit_veg": f"fruit and veg {n.get('g')}/400 g",
                     "sat_fat": f"saturated fat {n.get('pct')}% of kcal (under 10%)",
                     "sugars": f"free sugars {n.get('pct')}% of kcal (under 10%)",
                     "salt": f"salt {n.get('g')}/5 g"}[name]
            worst = (n["score"], label)
    if (p := s.get("processing")) and p["score"] < 70 and (worst is None or p["score"] < worst[0]):
        worst = (p["score"], f"{p['upf_pct']}% of kcal ultra-processed")
    return worst[1] if worst else None


# -- targets ---------------------------------------------------------------------------------------------------------


class Nutrition:
    def __init__(self, food: FoodStore, health: HealthStore | None = None):
        self.food = food
        self.conn: sqlite3.Connection = food.conn
        self.health = health
        self.tz: ZoneInfo = food.tz

    def _saved(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'food_targets'").fetchone()
        return json.loads(row["value"]) if row else {}

    def targets(self) -> dict:
        """The rest-day base (the food goals), what workouts add, and the profile proposals start from."""
        saved = self._saved()
        return {"base": self.food.goals(), "workouts": {**WORKOUTS, **saved.get("workouts", {})},
                "profile": {k: saved.get("profile", {}).get(k) for k in PROFILE}}

    def set_targets(self, base: dict | None = None, workouts: dict | None = None, profile: dict | None = None) -> dict:
        """Change what's given; the base replaces the goals (a missing or 0 macro is no goal)."""
        saved = self._saved()
        if workouts is not None:
            w = {**WORKOUTS, **saved.get("workouts", {}), **workouts}
            if set(w) - set(WORKOUTS):
                raise ValueError(f"workouts takes {', '.join(WORKOUTS)}")
            if not 0 <= float(w["share"]) <= 1.5 or not 0 <= float(w["carbs_pct"]) <= 100:
                raise ValueError("share is 0–1.5 and carbs_pct 0–100")
            saved["workouts"] = {"on": bool(w["on"]), "share": round(float(w["share"]), 2),
                                 "carbs_pct": round(float(w["carbs_pct"]))}
        if profile is not None:
            p = {**saved.get("profile", {}), **profile}
            if set(p) - set(PROFILE):
                raise ValueError(f"profile takes {', '.join(PROFILE)}")
            if p.get("goal") is not None and p["goal"] not in GOALS:
                raise ValueError(f"goal is one of {', '.join(GOALS)}")
            if p.get("sex") is not None and p["sex"] not in ("male", "female"):
                raise ValueError("sex is male or female")
            if p.get("note") is not None:
                p["note"] = " ".join(str(p["note"]).split())[:MAX_NOTE] or None
            for key, top in (("weight_kg", 400), ("height_cm", 260), ("age", 120)):
                if p.get(key) is not None and not 0 < float(p[key]) <= top:
                    raise ValueError(f"{key} must be between 0 and {top}")
            saved["profile"] = {k: p.get(k) for k in PROFILE}
        if base is not None:
            self.food.set_goals(base)
        self._save(saved)
        return self.targets()

    def _save(self, saved: dict) -> None:
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('food_targets', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(saved),))

    def coach_notes(self) -> tuple[list[dict], dict | None]:
        """What Coach was told before (each {question, answer, date}) and its last proposal ({date, base, workouts})."""
        saved = self._saved()
        return saved.get("answers", []), saved.get("proposal")

    def coach_said(self, proposal: dict, answers: list[dict]) -> None:
        """Keeps Coach's proposal and the answers it came from (a question answered again replaces its old answer),
        so the next proposal knows what it suggested last and doesn't ask again."""
        saved = self._saved()
        today = self.food.today().isoformat()
        new = {a["question"] for a in answers}
        kept = [a for a in saved.get("answers", []) if a["question"] not in new]
        saved["answers"] = (kept + [{"question": a["question"], "answer": a["answer"], "date": today}
                                    for a in answers])[-MAX_ANSWERS:]
        saved["proposal"] = {"date": today, "base": proposal["base"],
                             "workouts": {k: v for k, v in proposal["workouts"].items() if k != "on"}}
        self._save(saved)

    # -- workouts --

    def _workouts(self, d: date) -> list[dict]:
        if self.health is None:
            return []
        out = {}
        for stored in (d, d + timedelta(days=1)):  # a late workout can land in the next day's upload
            day = self.health.get(stored) or {}
            for w in day.get("workouts", []):
                if workout_date(w, day.get("date", stored.isoformat()), self.tz) == d:
                    out[w["id"]] = w
        return list(out.values())

    def run_rate(self, before: date) -> float:
        """The user's kcal a minute running, from the last 60 days' runs; RUN_KCAL_MIN without any."""
        if self.health is None:
            return RUN_KCAL_MIN
        kcal = minutes = 0.0
        for day in self.health.between(before - timedelta(days=60), before):
            for w in day.get("workouts", []):
                if w.get("type") == "run" and w.get("kcal") and workout_minutes(w):
                    kcal, minutes = kcal + w["kcal"], minutes + workout_minutes(w)
        return kcal / minutes if minutes >= 20 else RUN_KCAL_MIN

    def bonus(self, d: date, events: list | None = None) -> dict:
        """What the day's workouts add: their kcal (times the share), or, before any, a run in the calendar
        (`events`, today's: a title that says run, or a calendar called Run) at the usual rate, `planned`."""
        settings = self.targets()["workouts"]
        done = [w for w in self._workouts(d) if w.get("kcal")]
        if not settings["on"]:
            return {"kcal": 0, "planned": False, "workouts": []}
        if done:
            burned = sum(w["kcal"] for w in done)
            return {"kcal": round(burned * settings["share"]), "planned": False,
                    "workouts": [{"type": w.get("type", "other"), "kcal": round(w["kcal"]),
                                  "minutes": round(workout_minutes(w))} for w in done]}
        runs = [e for e in events or [] if not e.all_day and (RUN_WORDS.search(e.title) or RUN_WORDS.search(e.calendar))
                and e.start.astimezone(self.tz).date() == d]
        if not runs:
            return {"kcal": 0, "planned": False, "workouts": []}
        rate = self.run_rate(d)
        planned = []
        for e in runs:
            minutes = (e.end - e.start).total_seconds() / 60
            planned.append({"type": "run", "kcal": round(minutes * rate), "minutes": round(minutes),
                            "title": e.title})
        return {"kcal": round(sum(p["kcal"] for p in planned) * settings["share"]), "planned": True,
                "workouts": planned}

    def day_targets(self, d: date, bonus: dict | None = None) -> dict:
        """The base plus the day's bonus: its kcal, carbs_pct of them as carbs and the rest as fat."""
        base = self.food.goals()
        bonus = bonus or self.bonus(d)
        kcal = bonus["kcal"]
        if not kcal:
            return dict(base)
        carbs = kcal * self.targets()["workouts"]["carbs_pct"] / 100
        return {"calories": base["calories"] and round((base["calories"] + kcal) / 10) * 10,
                "protein_g": base["protein_g"],
                "carbs_g": base["carbs_g"] and round(base["carbs_g"] + carbs / 4),
                "fat_g": base["fat_g"] and round(base["fat_g"] + (kcal - carbs) / 9)}

    # -- the day --

    def items(self, meals: list[dict]) -> list[dict]:
        """Each item eaten: its kcal, grade and NOVA group, and its fibre, fruit and veg, saturated fat, free sugars
        (the sugars not from fruit and veg) and salt in grams, each None when its food doesn't say. A meal logged
        without items is its kcal alone."""
        if not meals:
            return []
        ids = [m["id"] for m in meals]
        rows = self.conn.execute(
            f"SELECT mi.meal_id, mi.name AS item_name, mi.calories AS item_kcal, mi.grams AS item_grams, f.* "
            f"FROM meal_items mi LEFT JOIN foods f ON f.id = mi.food_id "
            f"WHERE mi.meal_id IN ({','.join('?' * len(ids))}) ORDER BY mi.id", ids).fetchall()
        with_items = {r["meal_id"] for r in rows}
        out = []
        for r in rows:
            food = dict(r) if r["id"] is not None else {}
            g = (r["item_grams"] or 0) / 100

            def per(key: str) -> float | None:
                return food[key] * g if food.get(key) is not None and r["item_grams"] else None
            sugars = per("sugars_100g")
            out.append({"meal_id": r["meal_id"], "name": r["item_name"],
                        "grams": r["item_grams"], "kcal": r["item_kcal"], "grade": grade(food) if food else None,
                        "nova": food.get("nova"),
                        "fibre_g": per("fibre_100g"), "fvl_g": per("fvl_pct"), "sat_fat_g": per("sat_fat_100g"),
                        "salt_g": per("salt_100g"),
                        "free_sugars_g": None if sugars is None else sugars * (1 - (food.get("fvl_pct") or 0) / 100)})
        return out + [{"meal_id": m["id"], "kcal": m["calories"]} for m in meals if m["id"] not in with_items]

    def meals(self, meals: list[dict]) -> dict[int, dict]:
        """Each meal's items (name, grams, kcal, grade, nova and their own quality) and the meal's quality, by meal
        id; a meal logged without items has none and no quality."""
        out = {m["id"]: {"items": [], "quality": None} for m in meals}
        by_meal: dict[int, list[dict]] = {}
        for i in self.items(meals):
            by_meal.setdefault(i["meal_id"], []).append(i)
        for meal_id, items in by_meal.items():
            if items[0].get("name") is None:
                continue
            out[meal_id] = {"items": [{"name": i["name"], "grams": i["grams"] and round(i["grams"]),
                                       "kcal": round(i["kcal"]), "grade": i["grade"], "nova": i["nova"],
                                       "quality": meal_quality([i])} for i in items],
                            "quality": meal_quality(items)}
        return out

    def day(self, d: date, events: list | None = None) -> dict:
        """The day's targets, what's left of them, its bonus and its score (final once the day is over)."""
        meals = self.food.day(d)
        eaten = totals(meals)
        bonus = self.bonus(d, events if d == self.food.today() else None)
        targets = self.day_targets(d, bonus)
        left = {k: targets[k] - eaten[k] if targets.get(k) else None for k in MACROS}
        return {"targets": targets, "left": left, "bonus": bonus,
                "score": score(eaten, targets, self.items(meals), final=d < self.food.today())}

    def scores(self, start: date, end: date) -> dict[str, int | None]:
        """Each day's score, start..end, by date."""
        out = {}
        d = start
        while d <= end:
            day = self.day(d)
            out[d.isoformat()] = day["score"]["score"] if day["score"] else None
            d += timedelta(days=1)
        return out


# -- proposing targets ---------------------------------------------------------------------------------------------

PROPOSE_TOKENS = 1500
PROPOSE_PROMPT = """You are Coach, a personal nutrition and training coach. Propose the user's daily nutrition \
targets from their own data: a rest-day base (calories, protein, carbs, fat in grams) and how much of what their \
Watch says a workout burned is added on top (share, 0 to 1; Watch numbers often run high, so 0.7–1 is usual) and \
how much of that goes to carbs (carbs_pct; the rest is fat). Work from the profile (weight, height, age, sex, goal), \
their usual activity on days without a workout (active kcal and steps), their runs and other workouts (how often, \
how long, pace, VO2 max), their weight trend and what they've actually been eating. Protein for someone who runs \
and trains: about 1.6–2.2 g per kg. The goal: lose is a modest deficit (300–500 kcal); keep is the weight as it is; \
gain is a modest surplus (200–300 kcal) for muscle; perform is eating for training and racing at a steady weight: \
enough carbs for the training load (most of a workout's burn back, as carbs), protein toward the top of the range, \
nothing cut. The profile's note is what the user told you in their own words (a race, how they train, what they \
want): follow it. \
When the Watch measures resting energy (resting kcal), \
use it: a rest day's burn is the usual resting kcal plus the usual active kcal on days without a workout. Don't \
estimate it from a formula then. Say why in two or three short sentences, plainly, with the numbers that \
mattered.

You may ask the user up to two short questions in `questions`, only when an answer would change the numbers \
(the latest weight is old, the goal's pace isn't clear, a race or a change in training is coming), never what the \
data already says or what they've answered (their earlier answers are given too; ask again only when one has \
gone stale, like a weight from over a month ago). Always propose anyway, from what you have; the user's answers \
come back to you for another proposal. When they've just answered, start `why` with what the answers changed \
against your last proposal, number by number, or say plainly that they changed nothing and why.

Answer with JSON only, nothing before or after it:
{"base": {"calories": 2500, "protein_g": 140, "carbs_g": 300, "fat_g": 80}, "workouts": {"share": 0.8, \
"carbs_pct": 80}, "why": "…", "questions": ["…"]}"""


def _median(values: list[float]) -> float | None:
    values = sorted(values)
    if not values:
        return None
    mid = len(values) // 2
    return values[mid] if len(values) % 2 else (values[mid - 1] + values[mid]) / 2


def proposal_input(nutrition: "Nutrition", foods_days: list[dict], answers: list[dict] | None = None) -> str:
    """What Coach proposes from: the profile, 60 days of Health, the last 14 days of food, the current targets, and
    the user's answers to its questions (each {question, answer})."""
    today = nutrition.food.today()
    t = nutrition.targets()
    lines = [f"Today: {today:%A %d %B %Y}.", f"Profile: {json.dumps(t['profile'])}",
             f"Current targets: base {json.dumps(t['base'])}, workouts {json.dumps(t['workouts'])}"]
    days = nutrition.health.between(today - timedelta(days=60), today) if nutrition.health else []
    if days:
        past = [d for d in days if d["date"] < today.isoformat()]  # today's numbers are only so far
        resting = _median([d["resting_kcal"] for d in past if d.get("resting_kcal")])
        active = _median([d["active_kcal"] for d in past if d.get("active_kcal") and not d.get("workouts")])
        if resting:
            lines.append(f"Measured by the Watch: usual resting kcal {resting:.0f} a day"
                         + (f", usual active kcal on days without a workout {active:.0f}, so a rest day burns about "
                            f"{resting + active:.0f}" if active else "") + ".")
        lines.append("Apple Health, newest first (resting kcal, active kcal, steps, exercise min, weight kg, VO2 max, "
                     "workouts):")
        for day in days:
            workouts = []
            for w in day.get("workouts", []):
                minutes = workout_minutes(w)
                pace = (f", {minutes / w['km']:.2f} min/km" if w.get("km") and w.get("type") in ("run", "walk", "hike")
                        else "")
                km = f", {w['km']:.1f} km" if w.get("km") else ""
                workouts.append(f"{w.get('type', 'other')} {minutes:.0f} min{km}{pace}, "
                                f"{w.get('kcal', 0):.0f} kcal")
            lines.append(f"- {day['date']}: {day.get('resting_kcal', '?')} + {day.get('active_kcal', '?')} kcal, "
                         f"{day.get('steps', '?')} steps, "
                         f"{day.get('exercise_min', '?')} min" + (f", {day['weight_kg']} kg" if day.get("weight_kg") else "")
                         + (f", VO2 max {day['vo2max']}" if day.get("vo2max") else "")
                         + (f"; {'; '.join(workouts)}" if workouts else ""))
    else:
        lines.append("No Apple Health days.")
    logged = [d for d in foods_days if d["meals"]]
    if logged:
        lines.append("Food logged (kcal, protein, carbs, fat):")
        lines += [f"- {d['date']}: {d['totals']['calories']}, {d['totals']['protein_g']} g, "
                  f"{d['totals']['carbs_g']} g, {d['totals']['fat_g']} g ({d['meals']} meals)" for d in logged]
    else:
        lines.append("No food logged in the last 14 days.")
    before, last = nutrition.coach_notes()
    now = {a["question"] for a in answers or []}
    if earlier := [a for a in before if a["question"] not in now]:
        lines.append("What the user answered before:")
        lines += [f"- ({a['date']}) {a['question']} {a['answer']}" for a in earlier]
    if last:
        lines.append(f"Your last proposal ({last['date']}): base {json.dumps(last['base'])}, "
                     f"workouts {json.dumps(last['workouts'])}")
    if answers:
        lines.append("The user just answered your questions:")
        lines += [f"- {a['question']} {a['answer']}" for a in answers]
    return "\n".join(lines)


def parse_proposal(answer) -> dict:
    """Coach's answer as {base, workouts, why, questions}; raises ValueError when it isn't one."""
    if not isinstance(answer, dict) or not isinstance(answer.get("base"), dict):
        raise ValueError("Coach's proposal didn't come back right; try again")
    base = {}
    for k in MACROS:
        v = answer["base"].get(k)
        top = 10_000 if k == "calories" else 1_000
        if not isinstance(v, (int, float)) or not 0 < v <= top:
            raise ValueError(f"Coach's proposal has no {k}; try again")
        base[k] = round(v / 10) * 10 if k == "calories" else round(v)
    w = answer.get("workouts") or {}
    share = w.get("share", WORKOUTS["share"])
    carbs = w.get("carbs_pct", WORKOUTS["carbs_pct"])
    workouts = {"on": True, "share": round(min(1.5, max(0.0, float(share))), 2),
                "carbs_pct": round(min(100, max(0, float(carbs))))}
    questions = [str(q).strip() for q in answer.get("questions") or [] if str(q).strip()][:2]
    return {"base": base, "workouts": workouts, "why": str(answer.get("why") or "").strip(), "questions": questions}


def now_events(calendar, tz: ZoneInfo) -> list:
    """Today's calendar events, for a run planned later today; [] when the calendar can't be read."""
    if calendar is None:
        return []
    start = datetime.now(tz).replace(hour=0, minute=0, second=0, microsecond=0)
    try:
        return calendar.events(start, start + timedelta(days=1))
    except Exception:  # noqa: BLE001 - the calendar is a nicety here
        return []
