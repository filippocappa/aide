from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import httpx
import pytest

from aide.db import utcnow
from aide.weather import Weather, _town, day_summary, out_note, parse, weather_tools

ROME = ZoneInfo("Europe/Rome")
HOME = "Via Roma 1, 10121 Torino TO"
D = date(2026, 11, 4)


def payload(rain_hours=(17, 18, 19), chance=70, high=14.0, yesterday_high=21.0, gusts=20.0, code=63):
    """Open-Meteo's answer for yesterday, D and the day after: hourly and daily."""
    days = [D - timedelta(days=1), D, D + timedelta(days=1)]
    times, temp, prob, mm, codes, gust, is_day = [], [], [], [], [], [], []
    for d in days:
        for h in range(24):
            times.append(f"{d}T{h:02d}:00")
            temp.append(10.0 + h / 4)
            wet = d == D and h in rain_hours
            prob.append(chance if wet else 5)
            mm.append(1.2 if wet else 0.0)
            codes.append(code if wet else 2)
            gust.append(gusts)
            is_day.append(1 if 7 <= h <= 17 else 0)
    return {
        "current": {"temperature_2m": 12.4, "apparent_temperature": 10.1, "weather_code": 2, "is_day": 1},
        "hourly": {"time": times, "temperature_2m": temp, "apparent_temperature": temp,
                   "precipitation_probability": prob, "precipitation": mm, "weather_code": codes,
                   "wind_gusts_10m": gust, "is_day": is_day},
        "daily": {"time": [str(d) for d in days], "weather_code": [2, code, 2],
                  "temperature_2m_max": [yesterday_high, high, 15.0], "temperature_2m_min": [8.0, 7.6, 6.0],
                  "precipitation_probability_max": [5, chance, 5], "precipitation_sum": [0, 3.6, 0],
                  "wind_gusts_10m_max": [gusts] * 3,
                  "sunrise": [f"{d}T07:05" for d in days], "sunset": [f"{d}T17:02" for d in days]},
    }


class Recorder:
    def __init__(self, *bodies):
        self.bodies = list(bodies)
        self.requests: list[httpx.Request] = []

    def __call__(self, request):
        self.requests.append(request)
        return httpx.Response(200, json=self.bodies.pop(0) if len(self.bodies) > 1 else self.bodies[0])


class Fixes:
    def __init__(self, fix=None):
        self.fix = fix

    def latest(self):
        return self.fix

    async def here(self):
        return (self.fix["lat"], self.fix["lon"]) if self.fix else None


def service(rec, fix=None, geocode=None):
    return Weather(ROME, HOME, Fixes(fix), geocode, httpx.AsyncClient(transport=httpx.MockTransport(rec)))


async def maps_locate(address, near=None):
    return {"name": "Via Roma 1", "lat": 45.0703, "lon": 7.6869}


def test_day_summary_says_rain_and_when_and_a_big_drop():
    fc = parse(payload(), ROME, "Torino", 45.07, 7.69)
    s = day_summary(fc, D)
    assert s["summary"] == "8–14°, rain 17:00–20:00 (70%), 7° colder than the day before"
    assert s["flags"] == ["rain", "colder"]
    assert s["rain"]["mm"] == 3.6


def test_day_summary_of_an_ordinary_day_flags_nothing():
    fc = parse(payload(rain_hours=(), yesterday_high=15.0, code=2), ROME, "Torino", 45.07, 7.69)
    s = day_summary(fc, D)
    assert s["summary"] == "8–14°, partly cloudy" and s["flags"] == [] and s["rain"] is None


def test_rain_at_night_isnt_news_but_wind_and_snow_are():
    fc = parse(payload(rain_hours=(2, 3), gusts=60.0, yesterday_high=15.0), ROME, "", 0, 0)
    assert day_summary(fc, D)["flags"] == ["wind"]
    fc = parse(payload(rain_hours=(9, 10), code=73, yesterday_high=15.0), ROME, "", 0, 0)
    assert day_summary(fc, D)["summary"] == "8–14°, snow 09:00–11:00 (70%)"


def test_today_leaves_out_the_hours_gone():
    fc = parse(payload(rain_hours=(8, 9)), ROME, "", 0, 0)
    assert day_summary(fc, D, datetime(2026, 11, 4, 12, 0, tzinfo=ROME))["rain"] is None


def test_out_note_for_leaving_in_the_rain():
    fc = parse(payload(), ROME, "", 0, 0)
    assert out_note(fc, datetime(2026, 11, 4, 17, 25, tzinfo=ROME)) == "Rain likely (70%): take an umbrella."
    assert out_note(fc, datetime(2026, 11, 4, 12, 0, tzinfo=ROME)) is None


def test_town_from_an_address():
    assert _town(HOME) == "Torino"
    assert _town("Corso Duca degli Abruzzi 24, 10129 Torino, Italy") == "Torino"
    assert _town("Politecnico") is None


async def test_forecast_is_cached_and_home_found_on_maps():
    rec = Recorder(payload())
    w = service(rec, geocode=maps_locate)
    fc = await w.here_or_home()
    assert fc.place == "Torino" and fc.lat == 45.0703
    await w.here_or_home()
    assert len(rec.requests) == 1
    q = rec.requests[0].url.params
    assert q["timezone"] == "Europe/Rome" and q["past_days"] == "1" and q["latitude"] == "45.0703"


async def test_a_fresh_phone_fix_wins_over_home_and_open_meteo_geocodes_without_maps():
    fix = {"lat": 45.06, "lon": 7.66, "at": utcnow() - timedelta(minutes=20), "accuracy": 30}
    rec = Recorder(payload())
    assert (await service(rec, fix).where()) == (45.06, 7.66, "where you are")
    old = dict(fix, at=utcnow() - timedelta(hours=3))
    rec = Recorder({"results": [{"latitude": 45.07, "longitude": 7.68, "name": "Turin", "country_code": "IT"}]},
                   payload())
    assert (await service(rec, old).where()) == (45.07, 7.68, "Turin")
    assert "geocoding-api" in str(rec.requests[0].url)


async def test_a_place_is_looked_for_in_homes_country_first():
    rec = Recorder({"results": [{"latitude": 45.07, "longitude": 7.68, "name": "Turin", "country_code": "IT"}]},
                   {"results": [{"latitude": 30.7, "longitude": -96.6, "name": "Milano", "country_code": "US"},
                                {"latitude": 45.46, "longitude": 9.19, "name": "Milan", "country_code": "IT"}]})
    assert (await service(rec).locate("Milano")) == (45.46, 9.19, "Milan")


async def test_maps_is_biased_to_near_the_user():
    seen = []

    async def locate(address, near=None):
        seen.append((address, near))
        return {"name": address, "lat": 45.0, "lon": 7.6}
    fix = {"lat": 45.06, "lon": 7.66, "at": utcnow() - timedelta(hours=5), "accuracy": 30}
    await service(Recorder(payload()), fix, locate).locate("Politecnico")
    assert seen == [("Politecnico", (45.06, 7.66))]


def test_rest_of_today_is_the_hours_left():
    fc = parse(payload(rain_hours=()), ROME, "", 0, 0)
    assert day_summary(fc, D, datetime(2026, 11, 4, 20, 0, tzinfo=ROME))["summary"].startswith("15–16°")


async def test_here_without_a_fix_says_why():
    with pytest.raises(ValueError, match="isn't known"):
        await service(Recorder(payload())).where("here")


async def test_digest_section():
    w = service(Recorder(payload()), geocode=maps_locate)
    s = await w.section(D, datetime(2026, 11, 4, 8, 10, tzinfo=ROME))
    assert s["type"] == "weather" and s["title"] == "Weather"
    x = s["weather"]
    assert (x["high"], x["low"], x["place"], x["date"]) == (16, 12, "Torino", "2026-11-04")  # the hours left
    assert x["now"] == {"temp": 12, "feels": 10, "words": "Partly cloudy", "symbol": "cloud.sun"}
    assert x["rain"]["from"] == "2026-11-04T17:00:00+01:00" and x["rain"]["chance"] == 70
    assert x["hours"][0]["at"] == "2026-11-04T08:00:00+01:00" and x["hours"][-1]["at"].startswith("2026-11-04T23")
    tomorrow = await w.section(D + timedelta(days=1), datetime(2026, 11, 4, 21, 0, tzinfo=ROME))
    assert tomorrow["weather"]["now"] is None and tomorrow["weather"]["hours"][0]["at"].endswith("07:00:00+01:00")


async def test_digest_section_is_none_when_open_meteo_fails():
    w = Weather(ROME, HOME, None, maps_locate,
                httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(500))))
    assert await w.section(D, datetime(2026, 11, 4, 8, tzinfo=ROME)) is None


async def test_the_tool_reads_a_day_hour_by_hour():
    tool = weather_tools(service(Recorder(payload()), geocode=maps_locate), ROME)[0]
    assert tool.name == "weather"
    out = await tool.handler(day=str(D))
    assert out.startswith("Weather Torino, Wed 04 Nov: 8–14°, rain 17:00–20:00 (70%)")
    assert "- 17:00 14° rain, rain 70%" in out


async def test_the_greeting_reads_the_weather_section():
    from aide.digest import to_text
    s = await service(Recorder(payload()), geocode=maps_locate).section(D, datetime(2026, 11, 4, 8, tzinfo=ROME))
    assert to_text(None, [s], ROME) == ("**Weather**\n• Now 12°, partly cloudy. 12–16°, rain 17:00–20:00 (70%), "
                                        "7° colder than the day before (Torino)")
