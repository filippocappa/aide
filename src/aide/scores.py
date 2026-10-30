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
NEED_NIGHTS, MIN_NEED_NIGHTS = 90, 14  # nights the base need is learnt from (Oura: 90 days, odd nights left out)
NEED_TRIM = 0.1  # share of the shortest and of the longest nights left out
NEED_DEFAULT, NEED_MIN, NEED_MAX = 480, 450, 570  # min asleep: before there's history, and the bounds on the base
STRAIN_NEED = 0.3  # min of need per % of the day before's strain (Whoop: a hard day asks for more sleep)
DEBT_NIGHTS = 3  # nights whose shortfall adds to the need
DEBT_SHARE = 0.5  # of that shortfall carried into the need
DEBT_CAP = 45  # min the need can grow by
DURATION_SLOPE = 2.5  # score lost per share of the need missed: 90% of it scores 75, 80% scores 50
DEEP_FULL, DEEP_ZERO = 0.15, 0.05  # deep share of the night (typical adults: 13–23%)
REM_FULL, REM_ZERO = 0.23, 0.10  # REM share (typical: 20–25%)
EFFICIENCY_FULL, EFFICIENCY_ZERO = 0.97, 0.85  # asleep / in bed (the Watch's "in bed" is the sleep itself: ~96–98%)
CONSISTENCY_FULL, CONSISTENCY_ZERO = 20, 120  # min bedtime and wake are off the usual, on average
CONSISTENCY_NIGHTS, MIN_CONSISTENCY_NIGHTS = 14, 5
SLEEP_PARTS = {"duration": 50, "deep": 15, "rem": 15, "efficiency": 5, "consistency": 15}
USUAL_NIGHTS = 30  # nights a sleep part's usual is the median of

# Recovery
BASELINE = 60  # days before, for the usual numbers
MIN_BASELINE = 14
RECOVERY_PARTS = {"hrv": 30, "hrv_week": 20, "sleep_hr": 25, "resting_hr": 25, "sleep": 15, "load": 10}
# The heart part: heart rate while asleep (the phone's average over the night's sleep stages, as Oura and Whoop read the
# night), else Apple's resting heart rate for the day, which is mostly worked out while awake and often missing in the
# morning. Only one of the two counts.
HEART_KEYS = (("sleep_hr", "Heart rate asleep"), ("resting_hr", "Resting heart rate"))
TREND_DAYS, MIN_TREND_DAYS = 7, 4  # HRV's rolling mean (Plews and Buchheit: the trend says more than one morning)
LOAD_EASY = 1.05  # acute:chronic load at which training neither helps nor costs recovery; each 0.25 over is a spread
RECOVERY_SHIFT = 0.5  # a usual day scores ~60, as on Whoop
HRV_SPREAD_MIN, RHR_SPREAD_MIN = 0.08, 3.0  # floors on the spread (ln ms, bpm), so a steady past isn't twitchy
FLAG_CAP = 50  # a flag caps recovery here
RESPIRATORY_FLAG, TEMP_FLAG = 1.0, 0.5  # breaths/min, °C above the usual

# Strain
TRIMP_SCALE = 150  # TRIMP at which strain is 63%; a hard hour lands around 60%
HRR_FLOOR = 0.4  # heart-rate reserve below this (~110 bpm) is daily life, walking included, not load
REST_WINDOW, MAX_WINDOW = 30, 90  # days, for resting and max heart rate
DEFAULT_REST, DEFAULT_MAX = 60, 190
TOP_MAXES = 3  # the max heart rate is the middle of the top this many
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


def _clock(sleep: dict, key: str) -> float | None:
    """`bedtime` as minutes since noon, `wake` since 18:00, so 23:30 and 00:30 are an hour apart, as are 11:30 and
    12:30."""
    try:
        t = datetime.fromisoformat(sleep[key])
    except (KeyError, TypeError, ValueError):
        return None
    return ((t.hour - (12 if key == "bedtime" else 18)) % 24) * 60 + t.minute


def _asleep(d: dict | None) -> float | None:
    return (d or {}).get("sleep", {}).get("asleep_min")


def base_need(days: dict[str, dict], day: date) -> int:
    """The user's own need: the mean of the last 90 nights with the shortest and longest tenth left out, as Oura
    does, within 7h30–9h30. Habit, not a lab measure: a lasting debt hides in it, hence the floor."""
    nights = sorted(n for n in map(_asleep, _before(days, day, NEED_NIGHTS)) if n)
    if len(nights) < MIN_NEED_NIGHTS:
        return NEED_DEFAULT
    cut = int(len(nights) * NEED_TRIM)
    kept = nights[cut:len(nights) - cut]
    return round(_clip(sum(kept) / len(kept), NEED_MIN, NEED_MAX))


def sleep_need(days: dict[str, dict], day: date, age: int | None = None) -> dict:
    """The need for the night that ended on `day`: the base, plus some for the day before's strain, plus half of
    what the last 3 nights were short of the base, net of what they were over (capped)."""
    base = base_need(days, day)
    before = days.get((day - timedelta(days=1)).isoformat())
    strain = 0
    if before:
        rest, top = heart(days, day - timedelta(days=1), age)
        strain = strain_of(day_trimp(before, rest, top)[0])
    nights = [n for n in map(_asleep, _before(days, day, DEBT_NIGHTS)) if n]
    debt = max(0, sum(base - n for n in nights))
    extra_strain = round(STRAIN_NEED * strain)
    extra_debt = min(DEBT_CAP, round(DEBT_SHARE * debt))
    return {"need": base + extra_strain + extra_debt, "base": base, "strain": extra_strain, "debt": extra_debt}


def _share_part(key: str, label: str, minutes, asleep: float, full: float, zero: float) -> dict:
    share = minutes / asleep if minutes is not None else None
    return {"key": key, "label": label, "value": f"{hm(minutes)} · {round(100 * share)}%" if share is not None else None,
            "score": _clip((share - zero) / (full - zero)) if share is not None else None}


def _usual_parts(days: dict[str, dict], day: date, s: dict, parts: list[dict]) -> None:
    """Each part's usual, the median of the 30 nights before (`usual`, written like `value`), and for the timed ones
    `diff_min`, tonight's minutes against it. Needs 5 nights; else both None."""
    past = [d["sleep"] for d in _before(days, day, USUAL_NIGHTS) if (d.get("sleep") or {}).get("asleep_min")]

    def mid(key: str, nights: list[dict]) -> float | None:
        values = [n[key] for n in nights if n.get(key) is not None]
        return median(values) if len(values) >= MIN_CONSISTENCY_NIGHTS else None

    for p in parts:
        p["usual"] = p["diff_min"] = None
        key = {"duration": "asleep_min", "deep": "deep_min", "rem": "rem_min"}.get(p["key"])
        if key:
            usual = mid(key, past)
            if usual is None:
                continue
            if p["key"] == "duration":
                p["usual"] = hm(usual)
            else:
                shares = [n[key] / n["asleep_min"] for n in past if n.get(key) is not None]
                p["usual"] = f"{hm(usual)} · {round(100 * median(shares))}%"
            if s.get(key) is not None:
                p["diff_min"] = round(s[key] - usual)
        elif p["key"] == "efficiency":
            effs = [n["asleep_min"] / n["in_bed_min"] for n in past if n.get("in_bed_min")]
            if len(effs) >= MIN_CONSISTENCY_NIGHTS:
                p["usual"] = f"{round(100 * min(1, median(effs)))}%"


def sleep_score(days: dict[str, dict], day: date, age: int | None = None) -> dict | None:
    found = days.get(day.isoformat()) or {}
    s = found.get("sleep") or {}
    asleep = s.get("asleep_min")
    if not asleep:
        return None
    need = sleep_need(days, day, age)
    parts = []

    parts.append({"key": "duration", "label": "Hours vs need", "value": f"{hm(asleep)} of {hm(need['need'])}",
                  "score": _clip(1 - DURATION_SLOPE * (1 - asleep / need["need"]))})
    parts.append(_share_part("deep", "Deep sleep", s.get("deep_min"), asleep, DEEP_FULL, DEEP_ZERO))
    parts.append(_share_part("rem", "REM sleep", s.get("rem_min"), asleep, REM_FULL, REM_ZERO))

    in_bed = s.get("in_bed_min")
    eff = asleep / in_bed if in_bed else None
    parts.append({"key": "efficiency", "label": "Time asleep in bed",
                  "value": f"{round(100 * min(1, eff))}%" if eff is not None else None,
                  "score": _clip((eff - EFFICIENCY_ZERO) / (EFFICIENCY_FULL - EFFICIENCY_ZERO)) if eff is not None else None})

    # Regularity: how far bedtime and wake were from their usual, on average (a late night and a late morning both count)
    past = [d.get("sleep") or {} for d in _before(days, day, CONSISTENCY_NIGHTS)]
    offs, words = [], []
    for key, name in (("bedtime", "bed"), ("wake", "up")):
        mine, usual = _clock(s, key), [c for c in (_clock(p, key) for p in past) if c is not None]
        if mine is None or len(usual) < MIN_CONSISTENCY_NIGHTS:
            continue
        off = mine - median(usual)
        offs.append(abs(off))
        words.append(f"{name} on time" if abs(off) < 15 else f"{name} {hm(abs(off))} {'later' if off > 0 else 'earlier'}")
    mean_off = sum(offs) / len(offs) if offs else None
    parts.append({"key": "consistency", "label": "Bed and wake vs usual", "value": ", ".join(words) or None,
                  "score": (_clip((CONSISTENCY_ZERO - mean_off) / (CONSISTENCY_ZERO - CONSISTENCY_FULL))
                            if mean_off is not None else None)})

    for p in parts:
        p["weight"] = SLEEP_PARTS[p["key"]]
    _usual_parts(days, day, s, parts)
    score = _weighted(parts)
    after = [n for n in map(_asleep, [*_before(days, day, DEBT_NIGHTS - 1), found]) if n]
    for p in parts:
        p["score"] = round(100 * p["score"]) if p["score"] is not None else None
    return {"score": round(100 * score), "asleep_min": asleep, "need_min": need["need"], "need": need,
            "debt_min": round(max(0, sum(need["base"] - n for n in after))), "contributors": parts}


# -- recovery ------------------------------------------------------------------------


def vitals(days: dict[str, dict], day: date) -> dict:
    """Each night number with its usual (the median of the 60 days before) and usual range (± one spread)."""
    past = _before(days, day, BASELINE)
    today = days.get(day.isoformat()) or {}
    out = {}
    for key, floor in (("hrv_ms", 3.0), ("sleep_hr", 2.0), ("resting_hr", RHR_SPREAD_MIN), ("respiratory_rate", 0.4),
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


def _log_hrv(d: dict | None) -> float | None:
    return math.log(d["hrv_ms"]) if d and d.get("hrv_ms") else None


def _week_mean(days: dict[str, dict], day: date) -> float | None:
    """The mean ln HRV of the 7 days to `day`, with at least 4 of them."""
    logs = [v for v in (_log_hrv(days.get((day - timedelta(days=i)).isoformat())) for i in range(TREND_DAYS))
            if v is not None]
    return sum(logs) / len(logs) if len(logs) >= MIN_TREND_DAYS else None


def recovery_score(days: dict[str, dict], day: date, sleep: dict | None, age: int | None = None) -> dict | None:
    today = days.get(day.isoformat()) or {}
    hrv = today.get("hrv_ms")
    if hrv is None:
        return None
    past = [d for d in _before(days, day, BASELINE) if d.get("hrv_ms")]
    if len(past) < MIN_BASELINE:
        return {"score": None, "level": None, "calibrating": {"days": len(past), "needs": MIN_BASELINE},
                "contributors": [], "flags": []}

    # Each against the 60 days before: median and MAD, so one odd morning in the past doesn't move the usual
    logs = [math.log(d["hrv_ms"]) for d in past]
    z_hrv = _clip((math.log(hrv) - median(logs)) / _spread(logs, HRV_SPREAD_MIN), -3, 3)
    parts = [{"key": "hrv", "label": "HRV", "value": hrv, "usual": round(math.exp(median(logs)), 1), "unit": "ms",
              "z": z_hrv}]
    week = _week_mean(days, day)
    weeks = [w for w in (_week_mean(days, day - timedelta(days=i)) for i in range(1, BASELINE + 1)) if w is not None]
    if week is not None and len(weeks) >= MIN_BASELINE:
        z = _clip((week - median(weeks)) / _spread(weeks, HRV_SPREAD_MIN / 2), -3, 3)
        parts.append({"key": "hrv_week", "label": "HRV, last 7 days", "value": round(math.exp(week), 1),
                      "usual": round(math.exp(median(weeks)), 1), "unit": "ms", "z": z})
    for key, label in HEART_KEYS:
        values = [d[key] for d in past if d.get(key) is not None]
        if today.get(key) is not None and len(values) >= MIN_BASELINE:
            z = _clip(-(today[key] - median(values)) / _spread(values, RHR_SPREAD_MIN), -3, 3)
            parts.append({"key": key, "label": label, "value": today[key], "usual": round(median(values)),
                          "unit": "bpm", "z": z})
            break
    if sleep:
        parts.append({"key": "sleep", "label": "Sleep", "value": sleep["score"], "usual": None, "unit": "%",
                      "z": _clip((sleep["score"] - 70) / 15, -3, 3)})
    # Training load up to yesterday (Oura's activity balance): well over the usual costs, under it helps a little
    if lo := load(days, day - timedelta(days=1), age):
        parts.append({"key": "load", "label": "Training load", "value": lo["ratio"], "usual": 1.0, "unit": "×",
                      "z": _clip(-(lo["ratio"] - LOAD_EASY) / 0.25, -3, 1)})
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
    """(Resting, max) heart rate for `day`: the 30-day median resting HR, and the max from the workouts of the last
    90 days (else the days' highs), never under the age estimate. The max is the middle of the top three: the Watch's
    optical sensor throws the odd spike (230 bpm on a walk), and one spike shouldn't move every zone."""
    rests = [d["resting_hr"] for d in [*_before(days, day, REST_WINDOW), days.get(day.isoformat()) or {}]
             if d.get("resting_hr") is not None]
    window = [*_before(days, day, MAX_WINDOW), days.get(day.isoformat()) or {}]
    maxes = [w["max_hr"] for d in window for w in d.get("workouts", []) if w.get("max_hr")]
    maxes = maxes or [d["max_hr"] for d in window if d.get("max_hr")]
    peak = median(sorted(maxes)[-TOP_MAXES:]) if len(maxes) >= TOP_MAXES else max(maxes, default=0)
    top = max(peak, 208 - 0.7 * age if age else 0) or DEFAULT_MAX
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
            "zone_bpm": [round(rest + f * (top - rest)) for f in ZONES] + [round(top)],
            "workouts": [{"id": w["id"], "type": w.get("type", "other"), "minutes": w.get("minutes"),
                          "strain": strain_of(workout_trimp(w, rest, top))} for w in today.get("workouts", [])]}


def load(days: dict[str, dict], day: date, age: int | None = None) -> dict | None:
    """The 7 days to `day` (included) against the 28: Bevel's cardio load. The day's own page asks for the days
    before it (`day_scores`), since a day under way would count as a rest day."""
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
    label = next(name for top_, name in LOAD_LABELS if ratio < top_)
    off = round(100 * abs(ratio - 1))
    than = "about the same as" if off < 5 else f"{off}% {'more' if ratio > 1 else 'less'} than"
    meaning = {"detraining": "under 0.8× your fitness starts to slip", "maintaining": "0.8–1× keeps your fitness",
               "building": "1–1.3× builds it", "overreaching": "over 1.3× risks overdoing it"}[label]
    return {"acute": round(acute, 1), "chronic": round(chronic, 1), "ratio": round(ratio, 2), "label": label,
            "acute_strain": strain_of(acute), "chronic_strain": strain_of(chronic),
            "days": [None if d is None else strain_of(day_trimp(d, rest, top)[0]) for d in window[-LOAD_ACUTE:]],
            "why": f"The last 7 days averaged {strain_of(acute)}% strain a day, {than} your 4-week average of "
                   f"{strain_of(chronic)}% ({ratio:.2f}×): {meaning}."}


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
    sleep = sleep_score(days, day, age)
    recovery = recovery_score(days, day, sleep, age)
    strain = strain_score(days, day, recovery, age)
    return {"date": day.isoformat(), "sleep": sleep, "recovery": recovery, "strain": strain,
            "load": load(days, day - timedelta(days=1), age), "vitals": vitals(days, day), "line": line(sleep, recovery, strain)}
