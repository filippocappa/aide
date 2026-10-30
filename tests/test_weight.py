from datetime import datetime, time, timedelta

import pytest

from aide.db import Database
from aide.health import HealthStore
from aide.nutrition import Nutrition, proposal_input
from aide.food import FoodStore
from aide.tools import ToolRegistry
from aide.tools.weight import weight_tools
from aide.weight import WeightStore
from test_api import AUTH
from test_food import ROME
from test_nutrition import api_env  # noqa: F401  (a fixture)


@pytest.fixture
def env():
    db = Database(":memory:")
    health = HealthStore(db.conn, ROME)
    yield WeightStore(db.conn, ROME, health), health, Nutrition(FoodStore(db.conn, ROME), health)
    db.close()


def at(day, hour=8):
    return datetime.combine(day, time(hour), ROME)


def test_a_days_reading_is_aides_last_else_healths(env):
    weights, health, _ = env
    today = weights.today()
    health.save([{"date": (today - timedelta(days=n)).isoformat(), "weight_kg": 70 + n / 10} for n in (0, 1, 2)])
    first = weights.log(71.3, at(today, 0))  # just after midnight: never in the future, whenever the test runs
    weights.log(71.1, at(today, 0) + timedelta(minutes=1))
    got = weights.readings(today - timedelta(days=2), today)
    assert [(r["date"], r["kg"], r["source"]) for r in got] == [
        ((today - timedelta(days=2)).isoformat(), 70.2, "health"), ((today - timedelta(days=1)).isoformat(), 70.1, "health"),
        (today.isoformat(), 71.1, "aide")]
    assert [w["kg"] for w in weights.logged()] == [71.3, 71.1]
    assert weights.delete(first["id"]) and not weights.delete(first["id"])
    with pytest.raises(ValueError):
        weights.log(7)
    with pytest.raises(ValueError):
        weights.log(70, datetime.now(ROME) + timedelta(days=1))


def test_the_trend_against_the_goals_pace(env):
    weights, health, nutrition = env
    today = weights.today()
    assert weights.summary()["latest"] is None and weights.summary()["verdict"] is None
    # Gaining: falling 0.1 kg a week, weighed every other day for 4 weeks.
    health.save([{"date": (today - timedelta(days=n)).isoformat(), "weight_kg": round(66 + n * 0.1 / 7, 2)}
                 for n in range(0, 28, 2)])
    nutrition.set_targets(profile={"goal": "gain"})
    s = weights.summary()
    assert s["latest"] == {"date": today.isoformat(), "kg": 66.0} and s["days_since"] == 0
    assert s["rate_kg_week"] == -0.1 and s["verdict"] == "below"
    assert s["pace_kg_week"] == {"low_kg": 0.04, "high_kg": 0.08} and s["average_kg"] == pytest.approx(66.045, abs=0.01)
    assert s["change_kg"] == pytest.approx(-0.3, abs=0.015)
    nutrition.set_targets(profile={"goal": "lose"})
    assert weights.summary()["verdict"] == "above"
    nutrition.set_targets(profile={"goal": "keep"})
    assert weights.summary()["verdict"] == "below"
    health.save([{"date": (today - timedelta(days=n)).isoformat(), "weight_kg": 66 + n % 4 / 10} for n in range(28)])
    assert weights.summary()["verdict"] == "on_track"  # up and down with the scale's noise


def test_too_few_readings_make_no_trend(env):
    weights, health, nutrition = env
    today = weights.today()
    nutrition.set_targets(profile={"goal": "gain"})
    health.save([{"date": (today - timedelta(days=60)).isoformat(), "weight_kg": 65.4}])
    s = weights.summary()
    assert s["latest"]["kg"] == 65.4 and s["days_since"] == 60 and s["average_kg"] is None
    assert s["rate_kg_week"] is None and s["verdict"] is None and s["pace_kg_week"]["low_kg"] == 0.04
    weights.log(66)
    weights.log(66.2, at(today - timedelta(days=3)))
    assert weights.summary()["rate_kg_week"] is None  # 3 days apart: not a trend yet
    text = proposal_input(nutrition, [], None, weights)
    assert "Weight: Latest weight 66.0 kg on" in text and "not enough readings for a trend" in text


async def test_coach_logs_and_reads_the_weight(env):
    weights, health, nutrition = env
    tools = ToolRegistry(weight_tools(weights))
    nutrition.set_targets(profile={"goal": "gain"})
    got = await tools.get("log_weight").handler(kg=72.4)
    assert got.startswith("Logged 72.4 kg [weight 1]. Latest weight 72.4 kg")
    assert "The goal (gain) wants +0.04 to +0.09 kg a week." in got
    trend = await tools.get("weight_trend").handler()
    assert f"- {weights.today()}: 72.4 kg [weight 1, logged through Aide]" in trend
    assert tools.get("delete_weight").confirm  # queued
    assert (await tools.get("delete_weight").describe(weight_id=1)).startswith("Delete the 72.4 kg weight logged")


def test_the_weight_api(api_env):  # noqa: F811
    api, *_ = api_env()
    got = api.post("/v1/health/weight", json={"kg": 70.55}, headers=AUTH).json()
    assert got["weight"]["kg"] == 70.55 and got["summary"]["latest"]["kg"] == 70.55
    assert api.post("/v1/health/weight", json={"kg": 70, "at": "2026-10-01T08:00:00"}, headers=AUTH).status_code == 400
    assert api.post("/v1/health/weight", json={"kg": 900}, headers=AUTH).status_code == 400
    listed = api.get("/v1/health/weight?days=30", headers=AUTH).json()
    assert [r["source"] for r in listed["readings"]] == ["aide"] and listed["logged"][0]["kg"] == 70.55
    assert api.get("/v1/food/targets", headers=AUTH).json()["weight"]["latest"]["kg"] == 70.55
    assert api.delete(f"/v1/health/weight/{got['weight']['id']}", headers=AUTH).json()["summary"]["latest"] is None
    assert api.delete(f"/v1/health/weight/{got['weight']['id']}", headers=AUTH).status_code == 404
