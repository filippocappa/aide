from datetime import date, datetime, timedelta

import pytest

from aide import scores
from test_api import AUTH
from test_health import ROME, TODAY, world  # noqa: F401  (the fixture)

D = date(2026, 10, 30)


def day(d: date, asleep=450, bedtime="23:30", deep=70, rem=110, in_bed=470, hrv=55.0, rhr=54, **extra) -> dict:
    """A health day for `d` with last night's sleep going to bed at `bedtime` the evening before."""
    h, m = map(int, bedtime.split(":"))
    start = datetime.combine(d - timedelta(days=1 if h >= 12 else 0), datetime.min.time(), ROME).replace(hour=h, minute=m)
    sleep = {"bedtime": start.isoformat(), "wake": (start + timedelta(minutes=in_bed)).isoformat(),
             "asleep_min": asleep, "in_bed_min": in_bed, "deep_min": deep, "rem_min": rem}
    return {"date": d.isoformat(), "sleep": sleep, "hrv_ms": hrv, "resting_hr": rhr, **extra}


def past(n=30, **kw) -> dict[str, dict]:
    """n usual days before D, a little noise in HRV and resting HR."""
    out = {}
    for i in range(1, n + 1):
        d = D - timedelta(days=i)
        out[d.isoformat()] = day(d, hrv=kw.get("hrv", 55.0) + (i % 5 - 2), rhr=kw.get("rhr", 54) + (i % 3 - 1))
    return out


def with_today(days: dict, **kw) -> dict:
    return {**days, D.isoformat(): day(D, **kw)}


# -- sleep ---------------------------------------------------------------------------


def test_a_full_usual_night_scores_high_and_parts_add_up():
    s = scores.sleep_score(with_today(past()), D)
    assert s["need"] == {"need": 450, "base": 450, "strain": 0, "debt": 0} and s["debt_min"] == 0
    assert [p["key"] for p in s["contributors"]] == ["duration", "deep", "rem", "efficiency", "consistency"]
    assert [p["score"] for p in s["contributors"]] == [100] * 5 and s["score"] == 100
    assert s["contributors"][4]["value"] == "bed on time, up on time"


def test_a_short_late_night_scores_lower_and_debt_raises_the_need():
    days = past()
    for i in (1, 2, 3):
        d = D - timedelta(days=i)
        days[d.isoformat()] = day(d, asleep=390)
    s = scores.sleep_score(with_today(days, asleep=300, bedtime="01:30", in_bed=360), D)
    assert s["need_min"] == 450 + 45  # half of 3 × 60 short, capped at 45
    assert s["debt_min"] == 60 + 60 + 150
    parts = {p["key"]: p for p in s["contributors"]}
    assert parts["duration"]["value"] == "5h00 of 8h15" and parts["duration"]["score"] == 21
    assert parts["consistency"]["value"] == "bed 2h00 later, up on time" and parts["consistency"]["score"] == 55  # wake 10 min off
    assert s["score"] < 65


def test_the_need_is_learnt_from_past_nights_and_grows_after_a_hard_day():
    days = {}
    for i in range(1, 41):
        d = D - timedelta(days=i)
        days[d.isoformat()] = day(d, asleep=510 if i % 10 else 200)  # a short night now and then
    assert scores.base_need(days, D) == 510  # the short nights are left out
    yesterday = (D - timedelta(days=1)).isoformat()
    days[yesterday]["workouts"] = [{"id": "R", "kcal": 500}]  # TRIMP 100: strain 49
    need = scores.sleep_need(days, D)
    assert need["strain"] == 15 and need["need"] == need["base"] + 15 + need["debt"]
    assert scores.base_need({}, D) == scores.NEED_DEFAULT


def test_sleep_without_stages_or_history_weighs_what_it_has():
    only = {D.isoformat(): day(D, asleep=420, deep=None, rem=None, in_bed=450)}
    s = scores.sleep_score(only, D)
    parts = {p["key"]: p["score"] for p in s["contributors"]}
    assert parts["deep"] is None and parts["rem"] is None and parts["consistency"] is None
    assert s["need_min"] == 480
    duration, eff = 1 - 2 * (1 - 420 / 480), (420 / 450 - 0.80) / 0.15
    assert s["score"] == round(100 * (45 * duration + 10 * eff) / 55)
    assert scores.sleep_score({}, D) is None


# -- recovery ------------------------------------------------------------------------


def test_recovery_calibrates_then_scores_a_usual_day_in_the_sixties():
    r = scores.recovery_score(with_today(past(10)), D, None)
    assert r["score"] is None and r["calibrating"] == {"days": 10, "needs": 14}
    days = with_today(past())
    r = scores.recovery_score(days, D, scores.sleep_score(days, D))
    assert 60 <= r["score"] <= 80 and r["level"] in ("normal", "good")
    assert [p["key"] for p in r["contributors"]] == ["hrv", "hrv_week", "resting_hr", "sleep"]
    assert r["contributors"][0]["usual"] == 55.0 and r["flags"] == []
    assert scores.recovery_score(past(), D, None) is None  # no HRV last night


def test_low_hrv_and_high_resting_hr_mean_low_recovery():
    r = scores.recovery_score(with_today(past(), hrv=38.0, rhr=61), D, None)
    assert r["score"] < 34 and r["level"] == "low"
    good = scores.recovery_score(with_today(past(), hrv=70.0, rhr=50), D, None)
    assert good["score"] >= 67 and good["level"] == "good"


def test_a_heavy_week_costs_recovery():
    days = with_today(past())
    calm = scores.recovery_score(days, D, None)["score"]
    for i in range(1, 29):
        d = D - timedelta(days=i)
        days[d.isoformat()]["workouts"] = [{"id": f"W{i}", "kcal": 1500 if i <= 7 else 300}]
    r = scores.recovery_score(days, D, None)
    load = next(p for p in r["contributors"] if p["key"] == "load")
    assert load["value"] > 1.3 and load["score"] < 30 and r["score"] < calm


def test_breathing_or_temperature_up_caps_recovery():
    days = past()
    for d in days.values():
        d.update(respiratory_rate=14.0, wrist_temp_c=35.9)
    r = scores.recovery_score(with_today(days, hrv=70.0, rhr=50, respiratory_rate=15.4, wrist_temp_c=35.9), D, None)
    assert r["flags"] == ["respiratory_rate"] and r["score"] == 50
    assert "breathing rate is above your usual" in scores.line(None, r, None)


# -- strain --------------------------------------------------------------------------


def test_strain_from_heart_rate_minutes_with_zones_and_target():
    days = with_today(past(), hr_minutes=[[95, 300], [150, 30], [170, 30]],
                      workouts=[{"id": "R", "type": "run", "minutes": 60, "avg_hr": 160, "max_hr": 190}])
    rec = {"level": "normal"}
    s = scores.strain_score(days, D, rec)
    assert s["rest_hr"] == 54 and s["max_hr"] == 190 and not s["estimated"]
    # 300 min around 97 bpm (reserve 0.32) is under the floor: walking about isn't load
    assert 45 <= s["score"] <= 75 and s["target"] == [35, 60]
    assert sum(s["zones"]) == 60 and s["zones"][2] == 30  # 152.5 → 0.72, zone 3
    assert s["zone_bpm"] == [122, 136, 149, 163, 176, 190]  # where zones 1–5 start, then the max
    assert s["workouts"] == [{"id": "R", "type": "run", "minutes": 60, "strain": s["workouts"][0]["strain"]}]
    assert 40 <= s["workouts"][0]["strain"] <= 70


def test_strain_without_heart_rate_is_estimated_from_workouts():
    days = with_today(past(), workouts=[{"id": "S", "type": "strength", "minutes": 52, "kcal": 310}])
    s = scores.strain_score(days, D, None)
    assert s["estimated"] and s["trimp"] == 62.0 and s["score"] == 34 and s["target"] is None
    rest = scores.strain_score(with_today(past()), D, None)
    assert rest["score"] == 0


def test_max_heart_rate_from_workouts_then_age():
    days = with_today(past())
    assert scores.heart(days, D) == (54, 190)
    assert scores.heart(days, D, age=22) == (54, pytest.approx(192.6))
    days[D.isoformat()]["workouts"] = [{"id": "R", "max_hr": 201}]
    assert scores.heart(days, D, age=22)[1] == 201
    days[D.isoformat()]["workouts"] += [{"id": f"W{m}", "max_hr": m} for m in (230, 196, 180)]
    assert scores.heart(days, D)[1] == 201  # the middle of the top three: one spike doesn't count


def test_load_compares_the_last_week_with_the_last_four():
    days = past(30)
    assert scores.load(days, D) is None  # all rest days: no load
    for i in range(28):
        d = D - timedelta(days=i)
        kcal = 600 if i < 7 else 300
        days.setdefault(d.isoformat(), day(d))["workouts"] = [{"id": f"W{i}", "kcal": kcal}]
    lo = scores.load(days, D)
    assert lo["acute"] == 120 and lo["chronic"] == 75 and lo["ratio"] == 1.6  # kcal / 5
    assert lo["label"] == "overreaching"


def test_the_line_follows_recovery():
    days = with_today(past())
    out = scores.day_scores(days, D)
    assert out["line"].startswith(f"Recovery {out['recovery']['score']}% after 7h30 asleep: ")
    assert set(out) == {"date", "sleep", "recovery", "strain", "load", "vitals", "line"}
    assert out["vitals"]["hrv_ms"]["usual"] == 55.0 and out["vitals"]["hrv_ms"]["value"] == 55.0
    assert scores.line(None, None, None) == "Waiting for last night's data from the Watch."


# -- the endpoints -----------------------------------------------------------------------


def test_scores_endpoints(world):  # noqa: F811
    w = world()
    w.health.save([day(TODAY - timedelta(days=i)) for i in range(20)])
    out = w.http.get("/v1/health/scores", headers=AUTH).json()
    assert out["date"] == TODAY.isoformat() and out["recovery"]["score"] is not None
    assert w.http.get(f"/v1/health/scores?date={TODAY - timedelta(days=30)}", headers=AUTH).json()["sleep"] is None
    hist = w.http.get("/v1/health/scores/history?days=3", headers=AUTH).json()["days"]
    assert [h["date"] for h in hist] == [(TODAY - timedelta(days=i)).isoformat() for i in range(3)]
    assert set(hist[0]) == {"date", "sleep", "recovery", "strain"}


def test_hr_hourly_keeps_its_nulls_in_place(world):  # noqa: F811
    w = world()
    hourly = [None] * 7 + [70] + [None] * 16
    w.health.save([{"date": TODAY.isoformat(), "hr_hourly": hourly, "hr_minutes": [[95, 2.5]]}])
    assert w.health.get(TODAY)["hr_hourly"] == hourly
    with pytest.raises(ValueError):
        w.health.save([{"date": TODAY.isoformat(), "hr_hourly": [70] * 23}])
