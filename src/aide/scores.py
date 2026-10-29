"""Strain, Recovery and Sleep: three 0–100 scores from the Apple Health days. Contract in docs/API.md, "Scores".

Every score compares the day with the user's own past (medians over the weeks before), not with population norms.
The formulas are ours, in the spirit of Whoop, Bevel and Athlytic (none of them publish theirs); the constants below
are a first guess, to be tuned on real data. Nothing here is a medical claim.

Pure functions over health days (`{date: day}`, the JSON as stored); `HealthStore.scores` feeds them.
"""

import math
from datetime import date, datetime, timedelta
from statistics import median

# Sleep
SLEEP_NEED = 450  # min asleep a night, before debt
DEBT_NIGHTS = 3  # nights whose shortfall adds to the need
DEBT_SHARE = 0.5  # of that shortfall carried into the need
DEBT_CAP = 60  # min the need can grow by
RESTORATIVE_FULL = 0.40  # deep + REM share of the night for full marks
EFFICIENCY_FULL, EFFICIENCY_ZERO = 0.92, 0.75  # asleep / in bed
CONSISTENCY_FULL, CONSISTENCY_ZERO = 30, 120  # min from the usual bedtime
CONSISTENCY_NIGHTS, MIN_CONSISTENCY_NIGHTS = 14, 5
SLEEP_PARTS = {"duration": 50, "restorative": 20, "efficiency": 15, "consistency": 15}

# Recovery
BASELINE = 60  # days before, for the usual numbers
MIN_BASELINE = 14
RECOVERY_PARTS = {"hrv": 50, "resting_hr": 30, "sleep": 20}
RECOVERY_SHIFT = 0.3  # a usual day scores ~62, as on Whoop
HRV_SPREAD_MIN, RHR_SPREAD_MIN = 0.08, 2.0  # floors on the spread (ln ms, bpm), so a steady past isn't twitchy
FLAG_CAP = 50  # a flag caps recovery here
RESPIRATORY_FLAG, TEMP_FLAG = 1.0, 0.5  # breaths/min, °C above the usual

# Strain
TRIMP_SCALE = 150  # TRIMP at which strain is 63%; a hard hour lands around 60%
HRR_FLOOR = 0.4  # heart-rate reserve below this (~110 bpm) is daily life, walking included, not load
REST_WINDOW, MAX_WINDOW = 30, 90  # days, for resting and max heart rate
DEFAULT_REST, DEFAULT_MAX = 60, 190
KCAL_PER_TRIMP = 5  # a workout without heart rate: its kcal over this
TARGETS = {"low": (10, 35), "normal": (35, 60), "good": (55, 80)}
ZONES = (0.5, 0.6, 0.7, 0.8, 0.9)  # heart-rate reserve where zones 1–5 start
LOAD_ACUTE, LOAD_CHRONIC, MIN_LOAD_DAYS = 7, 28, 14
LOAD_LABELS = ((0.8, "detraining"), (1.0, "maintaining"), (1.3, "building"), (math.inf, "overreaching"))


def hm(minutes: float) -> str:
    m = round(minutes)
    return f"{m // 60}h{m % 60:02d}"


def _phi(z: float) -> float:
    return 0.5 * (1 + math.erf(z / math.sqrt(2)))


def _clip(x: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, x))


def _spread(values: list[float], floor: float) -> float:
    """A robust standard deviation: the median absolute deviation, scaled."""
    mid = median(values)
    return max(floor, 1.4826 * median(abs(v - mid) for v in values))


def _before(days: dict[str, dict], day: date, n: int) -> list[dict]:
    """The stored days in the n days before `day`, oldest first."""
    out = []
    for i in range(n, 0, -1):
        if found := days.get((day - timedelta(days=i)).isoformat()):
            out.append(found)
    return out


def _weighted(parts: list[dict]) -> float | None:
    """The weighted mean of the parts that have a score, re-weighted over those."""
    have = [p for p in parts if p["score"] is not None]
    weight = sum(p["weight"] for p in have)
    return sum(p["score"] * p["weight"] for p in have) / weight if weight else None


# -- sleep ---------------------------------------------------------------------------


def _bedtime_minutes(sleep: dict) -> float | None:
    """Bedtime as minutes since the noon before, so 23:30 and 00:30 are an hour apart."""
    try:
        t = datetime.fromisoformat(sleep["bedtime"])
    except (KeyError, TypeError, ValueError):
        return None
    return ((t.hour - 12) % 24) * 60 + t.minute


def sleep_need(days: dict[str, dict], day: date) -> tuple[int, int]:
    """(Need for the night that ended on `day`, the debt behind it): the base plus half the last nights' shortfall."""
    nights = [d["sleep"]["asleep_min"] for d in _before(days, day, DEBT_NIGHTS) if "asleep_min" in d.get("sleep", {})]
    debt = sum(max(0, SLEEP_NEED - n) for n in nights)
    return SLEEP_NEED + min(DEBT_CAP, round(DEBT_SHARE * debt)), debt


def sleep_score(days: dict[str, dict], day: date) -> dict | None:
    found = days.get(day.isoformat()) or {}
    s = found.get("sleep") or {}
    asleep = s.get("asleep_min")
    if not asleep:
        return None
    need, _ = sleep_need(days, day)
    parts = []

    parts.append({"key": "duration", "label": "Hours vs need", "value": f"{hm(asleep)} of {hm(need)}",
                  "score": _clip(asleep / need)})

    stages = [s.get(k) for k in ("deep_min", "rem_min")]
    share = sum(stages) / asleep if all(v is not None for v in stages) else None
    parts.append({"key": "restorative", "label": "Deep and REM",
                  "value": f"{hm(sum(stages))} · {round(100 * share)}%" if share is not None else None,
                  "score": _clip(share / RESTORATIVE_FULL) if share is not None else None})

    in_bed = s.get("in_bed_min")
    eff = asleep / in_bed if in_bed else None
    parts.append({"key": "efficiency", "label": "Time asleep in bed",
                  "value": f"{round(100 * min(1, eff))}%" if eff is not None else None,
                  "score": _clip((eff - EFFICIENCY_ZERO) / (EFFICIENCY_FULL - EFFICIENCY_ZERO)) if eff is not None else None})

    bedtime = _bedtime_minutes(s)
    usual = [b for b in (_bedtime_minutes(d.get("sleep") or {}) for d in _before(days, day, CONSISTENCY_NIGHTS))
             if b is not None]
    off = None
    if bedtime is not None and len(usual) >= MIN_CONSISTENCY_NIGHTS:
        off = bedtime - median(usual)
    parts.append({"key": "consistency", "label": "Bedtime vs usual",
                  "value": (("on time" if abs(off) < 10 else f"{hm(abs(off))} {'later' if off > 0 else 'earlier'}")
                            if off is not None else None),
                  "score": (_clip((CONSISTENCY_ZERO - abs(off)) / (CONSISTENCY_ZERO - CONSISTENCY_FULL))
                            if off is not None else None)})

    for p in parts:
        p["weight"] = SLEEP_PARTS[p["key"]]
    score = _weighted(parts)
    after = [d["sleep"]["asleep_min"] for d in [*_before(days, day, DEBT_NIGHTS - 1), found]
             if "asleep_min" in d.get("sleep", {})]
    for p in parts:
        p["score"] = round(100 * p["score"]) if p["score"] is not None else None
    return {"score": round(100 * score), "asleep_min": asleep, "need_min": need,
            "debt_min": sum(max(0, SLEEP_NEED - n) for n in after), "contributors": parts}


# -- recovery ------------------------------------------------------------------------


def vitals(days: dict[str, dict], day: date) -> dict:
    """Each night number with its usual (the median of the 60 days before) and usual range (± one spread)."""
    past = _before(days, day, BASELINE)
    today = days.get(day.isoformat()) or {}
    out = {}
    for key, floor in (("hrv_ms", 3.0), ("resting_hr", RHR_SPREAD_MIN), ("respiratory_rate", 0.4),
                       ("wrist_temp_c", 0.15), ("asleep_min", 25)):
        get = (lambda d: d.get("sleep", {}).get("asleep_min")) if key == "asleep_min" else (lambda d, k=key: d.get(k))
        values = [v for v in map(get, past) if v is not None]
        if len(values) < MIN_BASELINE:
            out[key] = {"value": get(today), "usual": None, "low": None, "high": None}
            continue
        mid, spread = median(values), _spread(values, floor)
        out[key] = {"value": get(today), "usual": round(mid, 2), "low": round(mid - spread, 2),
                    "high": round(mid + spread, 2)}
    return out


def level(score: int) -> str:
    return "low" if score < 34 else "normal" if score < 67 else "good"


def recovery_score(days: dict[str, dict], day: date, sleep: dict | None) -> dict | None:
    today = days.get(day.isoformat()) or {}
    hrv, rhr = today.get("hrv_ms"), today.get("resting_hr")
    if hrv is None:
        return None
    past = [d for d in _before(days, day, BASELINE) if d.get("hrv_ms")]
    if len(past) < MIN_BASELINE:
        return {"score": None, "level": None, "calibrating": {"days": len(past), "needs": MIN_BASELINE},
                "contributors": [], "flags": []}

    logs = [math.log(d["hrv_ms"]) for d in past]
    z_hrv = _clip((math.log(hrv) - median(logs)) / _spread(logs, HRV_SPREAD_MIN), -3, 3)
    parts = [{"key": "hrv", "label": "HRV", "value": hrv, "usual": round(math.exp(median(logs)), 1), "unit": "ms",
              "z": z_hrv}]
    rhrs = [d["resting_hr"] for d in past if d.get("resting_hr") is not None]
    if rhr is not None and len(rhrs) >= MIN_BASELINE:
        z = _clip(-(rhr - median(rhrs)) / _spread(rhrs, RHR_SPREAD_MIN), -3, 3)
        parts.append({"key": "resting_hr", "label": "Resting heart rate", "value": rhr, "usual": round(median(rhrs)),
                      "unit": "bpm", "z": z})
    if sleep:
        parts.append({"key": "sleep", "label": "Sleep", "value": sleep["score"], "usual": None, "unit": "%",
                      "z": _clip((sleep["score"] - 70) / 15, -3, 3)})
    for p in parts:
        p["weight"] = RECOVERY_PARTS[p["key"]]
    z = sum(p["z"] * p["weight"] for p in parts) / sum(p["weight"] for p in parts)
    score = round(100 * _phi(z + RECOVERY_SHIFT))

    flags = []
    v = vitals(days, day)
    if (r := v["respiratory_rate"])["value"] is not None and r["usual"] is not None \
            and r["value"] >= r["usual"] + RESPIRATORY_FLAG:
        flags.append("respiratory_rate")
    if (t := v["wrist_temp_c"])["value"] is not None and t["usual"] is not None \
            and t["value"] >= t["usual"] + TEMP_FLAG:
        flags.append("wrist_temp")
    if flags:
        score = min(score, FLAG_CAP)
    score = int(_clip(score, 1, 99))
    for p in parts:
        p["score"] = round(100 * _phi(p.pop("z") + RECOVERY_SHIFT))
    return {"score": score, "level": level(score), "calibrating": None, "contributors": parts, "flags": flags}


# -- strain --------------------------------------------------------------------------


def heart(days: dict[str, dict], day: date, age: int | None = None) -> tuple[float, float]:
    """(Resting, max) heart rate for `day`: the 30-day median resting HR, and the highest workout max in 90 days
    (else the highest day max), never under the age estimate."""
    rests = [d["resting_hr"] for d in [*_before(days, day, REST_WINDOW), days.get(day.isoformat()) or {}]
             if d.get("resting_hr") is not None]
    window = [*_before(days, day, MAX_WINDOW), days.get(day.isoformat()) or {}]
    maxes = [w["max_hr"] for d in window for w in d.get("workouts", []) if w.get("max_hr")]
    maxes = maxes or [d["max_hr"] for d in window if d.get("max_hr")]
    top = max([*maxes, 208 - 0.7 * age if age else 0]) or DEFAULT_MAX
    rest = median(rests) if rests else DEFAULT_REST
    return rest, max(top, rest + 40)


def _trimp_minutes(minutes: float, bpm: float, rest: float, top: float) -> float:
    """Banister's TRIMP for `minutes` at `bpm`; nothing under the floor."""
    x = _clip((bpm - rest) / (top - rest))
    return minutes * x * 0.64 * math.exp(1.92 * x) if x >= HRR_FLOOR else 0.0


def strain_of(trimp: float) -> int:
    return round(100 * (1 - math.exp(-trimp / TRIMP_SCALE)))


def workout_trimp(w: dict, rest: float, top: float) -> float:
    if w.get("avg_hr") and w.get("minutes"):
        return _trimp_minutes(w["minutes"], w["avg_hr"], rest, top)
    return (w.get("kcal") or 0) / KCAL_PER_TRIMP


def day_trimp(d: dict, rest: float, top: float) -> tuple[float, bool]:
    """(TRIMP for the day, estimated): from the heart-rate minutes, else from the workouts."""
    buckets = d.get("hr_minutes")
    if buckets:
        return sum(_trimp_minutes(m, bpm + 2.5, rest, top) for bpm, m in buckets), False
    return sum(workout_trimp(w, rest, top) for w in d.get("workouts", [])), True


def strain_score(days: dict[str, dict], day: date, recovery: dict | None, age: int | None = None) -> dict | None:
    today = days.get(day.isoformat())
    if not today:
        return None
    rest, top = heart(days, day, age)
    trimp, estimated = day_trimp(today, rest, top)
    zones = [0.0] * len(ZONES)
    for bpm, m in today.get("hr_minutes", []):
        x = (bpm + 2.5 - rest) / (top - rest)
        if i := sum(1 for z in ZONES if x >= z):
            zones[i - 1] += m
    lvl = recovery and recovery.get("level")
    return {"score": strain_of(trimp), "trimp": round(trimp, 1), "estimated": estimated,
            "target": list(TARGETS[lvl]) if lvl else None, "rest_hr": round(rest), "max_hr": round(top),
            "zones": [round(z) for z in zones],
            "workouts": [{"id": w["id"], "type": w.get("type", "other"), "minutes": w.get("minutes"),
                          "strain": strain_of(workout_trimp(w, rest, top))} for w in today.get("workouts", [])]}


def load(days: dict[str, dict], day: date, age: int | None = None) -> dict | None:
    """The last 7 days' average TRIMP against the last 28's: Bevel's cardio load."""
    rest, top = heart(days, day, age)
    window = [days.get((day - timedelta(days=i)).isoformat()) for i in range(LOAD_CHRONIC - 1, -1, -1)]
    have = [day_trimp(d, rest, top)[0] for d in window if d]
    if len(have) < MIN_LOAD_DAYS:
        return None
    recent = [day_trimp(d, rest, top)[0] for d in window[-LOAD_ACUTE:] if d]
    acute, chronic = sum(recent) / LOAD_ACUTE, sum(have) / LOAD_CHRONIC
    if not chronic:
        return None
    ratio = acute / chronic
    return {"acute": round(acute, 1), "chronic": round(chronic, 1), "ratio": round(ratio, 2),
            "label": next(name for top_, name in LOAD_LABELS if ratio < top_)}


# -- the day ---------------------------------------------------------------------------


def line(sleep: dict | None, recovery: dict | None, strain: dict | None) -> str:
    """One plain sentence on the day, from code."""
    if recovery and recovery["score"] is None:
        c = recovery["calibrating"]
        return f"Learning your usual numbers: {c['days']} of {c['needs']} nights so far."
    if not recovery:
        return "Waiting for last night's data from the Watch." if not sleep else \
            f"Slept {hm(sleep['asleep_min'])}; recovery comes with last night's HRV."
    first = f"Recovery {recovery['score']}%" + (f" after {hm(sleep['asleep_min'])} asleep" if sleep else "")
    lo, hi = TARGETS[recovery["level"]]
    advice = {"good": f"a good day to push, aim for {lo}–{hi}% strain",
              "normal": f"a normal day, aim for {lo}–{hi}% strain",
              "low": f"an easy day suits you better, keep strain to {lo}–{hi}%"}[recovery["level"]]
    out = f"{first}: {advice}."
    if "respiratory_rate" in recovery["flags"] or "wrist_temp" in recovery["flags"]:
        what = " and ".join(n for f, n in (("respiratory_rate", "breathing rate"), ("wrist_temp", "wrist temperature"))
                            if f in recovery["flags"])
        out += f" Your {what} is above your usual."
    if strain and strain["score"] >= hi:
        out += " You've reached today's target."
    return out


def day_scores(days: dict[str, dict], day: date, age: int | None = None) -> dict:
    sleep = sleep_score(days, day)
    recovery = recovery_score(days, day, sleep)
    strain = strain_score(days, day, recovery, age)
    return {"date": day.isoformat(), "sleep": sleep, "recovery": recovery, "strain": strain,
            "load": load(days, day, age), "vitals": vitals(days, day), "line": line(sleep, recovery, strain)}
