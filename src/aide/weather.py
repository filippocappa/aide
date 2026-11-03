"""Weather from Open-Meteo (free, no key): the forecast where the user is or is going. Read-only.
Contract in docs/API.md, "Weather".

Where: the phone's last fix while it's fresh (under FIX_USABLE), else home (`AIDE_HOME_ADDRESS`, found on Maps when
Maps is on, else with Open-Meteo's own geocoder on the town). A place is cached for good, a forecast for CACHE.

What it says is kept to what changes plans (`day_summary`): the low and high, rain or snow and when (a chance of
at least RAIN%, or rain falling), thunder, strong gusts, heat or frost, and a big change from the day before.
"""

import logging
import time as clock
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

import httpx

from . import usage
from .db import utcnow

log = logging.getLogger(__name__)

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
CACHE = timedelta(minutes=30)
FIX_USABLE = timedelta(hours=2)  # as transit.FIX_USABLE: older, the fix says nothing about where the user is
DAYS = 7
RAIN = 50  # % chance from which an hour counts as rainy
WET_MM = 0.3  # mm in an hour that count as rain, whatever the chance
GUSTS = 50  # km/h: windy
HOT, FROST = 32, 0  # °C
SWING = 6  # °C between one day's high and the day before's that's worth saying
WAKING = (7, 23)  # hours of the day that count: rain at 3 am isn't news
ALL_DAY = 10  # rainy waking hours that make it "rain all day"

HOURLY = ("temperature_2m", "apparent_temperature", "precipitation_probability", "precipitation", "weather_code",
          "wind_gusts_10m", "is_day")
DAILY = ("weather_code", "temperature_2m_max", "temperature_2m_min", "precipitation_probability_max",
         "precipitation_sum", "wind_gusts_10m_max", "sunrise", "sunset")
CURRENT = ("temperature_2m", "apparent_temperature", "weather_code", "is_day")

# WMO weather codes: (words, SF Symbol by day, by night).
CODES: dict[int, tuple[str, str, str]] = {
    0: ("Clear", "sun.max", "moon.stars"),
    1: ("Mostly clear", "sun.max", "moon.stars"),
    2: ("Partly cloudy", "cloud.sun", "cloud.moon"),
    3: ("Cloudy", "cloud", "cloud"),
    45: ("Fog", "cloud.fog", "cloud.fog"),
    48: ("Fog", "cloud.fog", "cloud.fog"),
    51: ("Light drizzle", "cloud.drizzle", "cloud.drizzle"),
    53: ("Drizzle", "cloud.drizzle", "cloud.drizzle"),
    55: ("Heavy drizzle", "cloud.drizzle", "cloud.drizzle"),
    56: ("Freezing drizzle", "cloud.sleet", "cloud.sleet"),
    57: ("Freezing drizzle", "cloud.sleet", "cloud.sleet"),
    61: ("Light rain", "cloud.rain", "cloud.rain"),
    63: ("Rain", "cloud.rain", "cloud.rain"),
    65: ("Heavy rain", "cloud.heavyrain", "cloud.heavyrain"),
    66: ("Freezing rain", "cloud.sleet", "cloud.sleet"),
    67: ("Freezing rain", "cloud.sleet", "cloud.sleet"),
    71: ("Light snow", "cloud.snow", "cloud.snow"),
    73: ("Snow", "cloud.snow", "cloud.snow"),
    75: ("Heavy snow", "cloud.snow", "cloud.snow"),
    77: ("Snow grains", "cloud.snow", "cloud.snow"),
    80: ("Showers", "cloud.sun.rain", "cloud.moon.rain"),
    81: ("Showers", "cloud.rain", "cloud.rain"),
    82: ("Heavy showers", "cloud.heavyrain", "cloud.heavyrain"),
    85: ("Snow showers", "cloud.snow", "cloud.snow"),
    86: ("Snow showers", "cloud.snow", "cloud.snow"),
    95: ("Thunderstorm", "cloud.bolt.rain", "cloud.bolt.rain"),
    96: ("Thunderstorm with hail", "cloud.bolt.rain", "cloud.bolt.rain"),
    99: ("Thunderstorm with hail", "cloud.bolt.rain", "cloud.bolt.rain"),
}
SNOW = {71, 73, 75, 77, 85, 86}
THUNDER = {95, 96, 99}


def words(code: int | None) -> str:
    return CODES.get(code, ("Unknown", "", ""))[0] if code is not None else "Unknown"


def symbol(code: int | None, day: bool = True) -> str:
    c = CODES.get(code) if code is not None else None
    return (c[1] if day else c[2]) if c else "cloud"


@dataclass(frozen=True)
class Hour:
    at: datetime  # local, aware
    temp: float
    feels: float | None
    rain_chance: int  # %
    rain_mm: float
    code: int
    gusts: float | None  # km/h
    day: bool

    @property
    def wet(self) -> bool:
        return self.rain_chance >= RAIN or self.rain_mm >= WET_MM


@dataclass(frozen=True)
class Day:
    day: date
    code: int
    high: float
    low: float
    rain_chance: int | None
    rain_mm: float | None
    gusts: float | None
    sunrise: datetime | None
    sunset: datetime | None


@dataclass(frozen=True)
class Forecast:
    place: str
    lat: float
    lon: float
    now: dict | None  # {temp, feels, code, day}
    hours: tuple[Hour, ...]
    days: tuple[Day, ...]  # from yesterday (past_days=1)

    def day(self, d: date) -> Day | None:
        return next((x for x in self.days if x.day == d), None)

    def hours_of(self, d: date) -> list[Hour]:
        return [h for h in self.hours if h.at.date() == d]

    def at(self, when: datetime) -> Hour | None:
        """The hour `when` falls in."""
        start = when.replace(minute=0, second=0, microsecond=0)
        return next((h for h in self.hours if h.at == start), None)


def _num(v) -> float | None:
    return float(v) if isinstance(v, (int, float)) else None


def parse(data: dict, tz: ZoneInfo, place: str, lat: float, lon: float) -> Forecast:
    def local(s: str | None) -> datetime | None:
        return datetime.fromisoformat(s).replace(tzinfo=tz) if s else None

    h = data.get("hourly") or {}
    hours = []
    for i, at in enumerate(h.get("time", [])):
        temp = _num(h["temperature_2m"][i])
        if temp is None:
            continue
        hours.append(Hour(local(at), temp, _num(h["apparent_temperature"][i]),
                          int(h["precipitation_probability"][i] or 0), _num(h["precipitation"][i]) or 0.0,
                          int(h["weather_code"][i] or 0), _num(h["wind_gusts_10m"][i]), bool(h["is_day"][i])))
    d = data.get("daily") or {}
    days = []
    for i, day in enumerate(d.get("time", [])):
        high, low = _num(d["temperature_2m_max"][i]), _num(d["temperature_2m_min"][i])
        if high is None or low is None:
            continue
        chance = d["precipitation_probability_max"][i]
        days.append(Day(date.fromisoformat(day), int(d["weather_code"][i] or 0), high, low,
                        int(chance) if chance is not None else None, _num(d["precipitation_sum"][i]),
                        _num(d["wind_gusts_10m_max"][i]), local(d["sunrise"][i]), local(d["sunset"][i])))
    c = data.get("current") or {}
    now = None
    if _num(c.get("temperature_2m")) is not None:
        now = {"temp": c["temperature_2m"], "feels": _num(c.get("apparent_temperature")),
               "code": int(c.get("weather_code") or 0), "day": bool(c.get("is_day", 1))}
    return Forecast(place, lat, lon, now, tuple(hours), tuple(days))


# -- what's worth saying -------------------------------------------------------------------------------------------


def _deg(v: float) -> str:
    return f"{round(v)}°"


def _wet_spans(hours: list[Hour]) -> list[tuple[Hour, Hour]]:
    """Runs of rainy hours, (first, last); a dry hour between two rainy ones doesn't split a run."""
    spans: list[list[Hour]] = []
    for h in hours:
        if not h.wet:
            continue
        if spans and h.at - spans[-1][-1].at <= timedelta(hours=2):
            spans[-1].append(h)
        else:
            spans.append([h])
    return [(s[0], s[-1]) for s in spans]


def rain_spell(hours: list[Hour]) -> dict | None:
    """The day's rain (or snow) in its waking hours: {from, to, chance, mm, snow, all_day}, or None if it's dry."""
    waking = [h for h in hours if WAKING[0] <= h.at.hour <= WAKING[1]]
    spans = _wet_spans(waking)
    if not spans:
        return None
    first, last = spans[0][0], spans[-1][1]
    wet = [h for h in waking if first.at <= h.at <= last.at]
    return {"from": first.at, "to": last.at + timedelta(hours=1), "chance": max(h.rain_chance for h in wet),
            "mm": round(sum(h.rain_mm for h in wet), 1), "snow": any(h.code in SNOW for h in wet),
            "thunder": any(h.code in THUNDER for h in wet), "all_day": sum(h.wet for h in waking) >= ALL_DAY}


def _when(spell: dict, start: datetime | None) -> str:
    """'from 17:00', '8:00–11:00', 'all day'; `start` is now, for today (rain already falling: 'until 11:00')."""
    if spell["all_day"]:
        return "all day"
    begin, end = spell["from"], spell["to"]
    if start and begin <= start:
        return f"until {end:%H:%M}" if end.hour > WAKING[0] and end.date() == begin.date() else "now"
    if end.date() > begin.date() or end.hour >= WAKING[1]:
        return f"from {begin:%H:%M}"
    return f"{begin:%H:%M}–{end:%H:%M}"


def day_summary(fc: Forecast, d: date, now: datetime | None = None) -> dict | None:
    """What's worth saying about a day: {summary, rain, high, low, code, flags}. `now` (today only) leaves out
    the hours gone. None when the forecast doesn't cover the day."""
    day = fc.day(d)
    if day is None:
        return None
    hours = [h for h in fc.hours_of(d) if now is None or h.at >= now.replace(minute=0, second=0, microsecond=0)]
    spell = rain_spell(hours)
    high, low = (max(h.temp for h in hours), min(h.temp for h in hours)) if now and hours else (day.high, day.low)
    parts = [f"{round(low)}–{_deg(high)}"]
    flags = []
    if spell:
        what = "snow" if spell["snow"] else "storms" if spell["thunder"] else "rain"
        flags.append(what)
        parts.append(f"{what} {_when(spell, now if now and now.date() == d else None)} ({spell['chance']}%)")
    else:
        parts.append(words(day.code).lower() if day.code < 51 else "dry")
    gusts = max((h.gusts or 0 for h in hours), default=day.gusts or 0) if hours else (day.gusts or 0)
    if gusts >= GUSTS:
        flags.append("wind")
        parts.append(f"windy, gusts {round(gusts)} km/h")
    if day.high >= HOT:
        flags.append("hot")
        parts.append("hot")
    if day.low <= FROST:
        flags.append("frost")
        parts.append("frost")
    if (before := fc.day(d - timedelta(days=1))) and abs(day.high - before.high) >= SWING:
        diff = round(day.high - before.high)
        flags.append("colder" if diff < 0 else "warmer")
        parts.append(f"{abs(diff)}° {'colder' if diff < 0 else 'warmer'} than the day before")
    code = day.code if not spell else max((h.code for h in hours if h.wet), default=day.code)
    return {"summary": ", ".join(parts), "rain": spell, "high": high, "low": low, "code": code,
            "flags": flags}


def out_note(fc: Forecast, when: datetime) -> str | None:
    """A line for someone heading out at `when`: rain or snow in that hour or the next, else None."""
    near = [h for h in fc.hours if when - timedelta(minutes=30) <= h.at <= when + timedelta(hours=1)]
    wet = [h for h in near if h.wet]
    if not wet:
        return None
    what = "Snow" if any(h.code in SNOW for h in wet) else "Rain"
    return f"{what} likely ({max(h.rain_chance for h in wet)}%): take an umbrella." if what == "Rain" \
        else f"Snow likely ({max(h.rain_chance for h in wet)}%)."


# -- the service ---------------------------------------------------------------------------------------------------


class Weather:
    def __init__(self, tz: ZoneInfo, home: str | None = None, location=None,
                 geocode: Callable[[str, tuple[float, float] | None], Awaitable[dict | None]] | None = None,
                 http: httpx.AsyncClient | None = None):
        """`location` is transit.Location (the phone's fixes); `geocode(address, near)` gives {name, lat, lon} (Maps'
        locate, biased to near the user), else Open-Meteo's geocoder is asked, preferring home's country."""
        self.tz = tz
        self.home = home
        self.location = location
        self.geocode = geocode
        self._http = http or httpx.AsyncClient(timeout=15)
        self._places: dict[str, tuple[float, float, str] | None] = {}
        self._country: str | None = None  # home's, from Open-Meteo's geocoder: "Milano" is Milan, not Milano, Texas
        self._cache: dict[tuple[float, float], tuple[float, Forecast]] = {}

    async def _get(self, url: str, params: dict, what: str) -> dict:
        started = clock.monotonic()
        r = await self._http.get(url, params=params)
        usage.record("open_meteo", what, ms=round((clock.monotonic() - started) * 1000), ok=not r.is_error)
        r.raise_for_status()
        return r.json()

    async def locate(self, address: str) -> tuple[float, float, str] | None:
        """(lat, lon, a short name) for an address or place, or None."""
        key = address.strip().lower()
        if key in self._places:
            return self._places[key]
        home = self.home and key == self.home.strip().lower()
        found = None
        if self.geocode:
            try:
                if p := await self.geocode(address, None if home else await self._near()):
                    found = (p["lat"], p["lon"], _town(address) or p["name"])
            except Exception:
                log.warning("weather: Maps couldn't find %r", address, exc_info=True)
        if found is None:
            country = None if home else await self._home_country()
            for name in dict.fromkeys(n for n in (address.strip(), _town(address)) if n):
                data = await self._get(GEOCODE_URL, {"name": name, "count": 10, "language": "en"}, "geocode")
                if results := data.get("results"):
                    r = next((r for r in results if country and r.get("country_code") == country), results[0])
                    found = (r["latitude"], r["longitude"], r["name"])
                    if home:
                        self._country = r.get("country_code")
                    break
        self._places[key] = found
        return found

    async def _near(self) -> tuple[float, float] | None:
        """Where the user is about, to tell places of the same name apart: the phone's fix, else home."""
        if self.location and (fix := self.location.latest()):
            return fix["lat"], fix["lon"]
        if self.home and (h := await self.locate(self.home)):
            return h[0], h[1]
        return None

    async def _home_country(self) -> str | None:
        if self._country is None and self.home and not self.geocode:
            await self.locate(self.home)
        return self._country

    async def where(self, place: str | None = None) -> tuple[float, float, str]:
        """Where to forecast: "here" (the phone, asked for a fresh fix), a place, or by default the phone while its
        fix is fresh, else home. ValueError when none of them is known."""
        if (place or "").strip().lower() == "here":
            fix = await self.location.here() if self.location else None
            if fix is None:
                raise ValueError("where the user is isn't known (location is off in the app, or the last fix is over "
                                 "2 hours old): ask where they are, or use home")
            return fix[0], fix[1], "where you are"
        if place and place.strip():
            if found := await self.locate(place):
                return found
            raise ValueError(f"couldn't find {place!r}")
        if self.location and (fix := self.location.latest()) and utcnow() - fix["at"] <= FIX_USABLE:
            return fix["lat"], fix["lon"], "where you are"
        if self.home and (found := await self.locate(self.home)):
            return found
        raise ValueError("no home address is set and the phone's location isn't known: ask where")

    async def forecast(self, lat: float, lon: float, place: str = "") -> Forecast:
        key = (round(lat, 2), round(lon, 2))  # ~1 km
        if (hit := self._cache.get(key)) and clock.monotonic() - hit[0] < CACHE.total_seconds():
            return hit[1] if hit[1].place == place else Forecast(place, *(getattr(hit[1], f) for f in
                                                                          ("lat", "lon", "now", "hours", "days")))
        data = await self._get(FORECAST_URL, {
            "latitude": f"{lat:.4f}", "longitude": f"{lon:.4f}", "hourly": ",".join(HOURLY),
            "daily": ",".join(DAILY), "current": ",".join(CURRENT), "timezone": str(self.tz),
            "forecast_days": DAYS, "past_days": 1, "wind_speed_unit": "kmh"}, "forecast")
        fc = parse(data, self.tz, place, lat, lon)
        self._cache[key] = (clock.monotonic(), fc)
        return fc

    async def here_or_home(self, place: str | None = None) -> Forecast:
        lat, lon, name = await self.where(place)
        return await self.forecast(lat, lon, name)

    async def section(self, d: date, now: datetime, title: str = "Weather") -> dict | None:
        """The digest's weather section for day `d` (docs/API.md, "Weather"), or None when it can't be had."""
        try:
            fc = await self.here_or_home()
        except Exception:
            log.warning("digest: no weather", exc_info=True)
            return None
        today = d == now.date()
        s = day_summary(fc, d, now if today else None)
        if s is None:
            return None
        hours = [h for h in fc.hours_of(d) if WAKING[0] <= h.at.hour <= WAKING[1]
                 and (not today or h.at >= now.replace(minute=0, second=0, microsecond=0))]
        rain = s["rain"]
        return {"type": "weather", "title": title, "weather": {
            "place": fc.place, "date": d.isoformat(), "summary": s["summary"],
            "high": round(s["high"]), "low": round(s["low"]), "words": words(s["code"]), "symbol": symbol(s["code"]),
            "now": ({"temp": round(fc.now["temp"]), "feels": round(fc.now["feels"]) if fc.now["feels"] is not None
                     else None, "words": words(fc.now["code"]), "symbol": symbol(fc.now["code"], fc.now["day"])}
                    if today and fc.now else None),
            "rain": ({"from": rain["from"].isoformat(), "to": rain["to"].isoformat(), "chance": rain["chance"],
                      "mm": rain["mm"], "snow": rain["snow"]} if rain else None),
            "flags": s["flags"],
            "hours": [{"at": h.at.isoformat(), "temp": round(h.temp), "rain_chance": h.rain_chance,
                       "symbol": symbol(h.code, h.day)} for h in hours]}}

    async def note_for(self, lat: float, lon: float, when: datetime) -> str | None:
        """Rain or snow for someone heading out at `when` from here, in a line; None if dry or unknown."""
        try:
            return out_note(await self.forecast(lat, lon), when.astimezone(self.tz))
        except Exception:
            log.warning("weather: no forecast for a leave-now note", exc_info=True)
            return None


def _town(address: str) -> str | None:
    """'Via Roma 1, 10121 Torino TO' or '…, 10121 Torino, Italy' -> 'Torino': the part with the postcode, less the
    postcode and a province code; else the last part. None for a bare name ('Politecnico')."""
    parts = [p.strip() for p in address.split(",") if p.strip()]
    if len(parts) < 2:
        return None
    part = next((p for p in reversed(parts) if any(w.isdigit() and len(w) >= 4 for w in p.split())), parts[-1])
    town = [w for w in part.split() if not w.isdigit() and not (len(w) == 2 and w.isupper())]
    return " ".join(town) or None


# -- the agents' tool ----------------------------------------------------------------------------------------------


def weather_tools(weather: Weather, tz: ZoneInfo):
    from .tools import Tool

    def hour_line(h: Hour) -> str:
        return f"{h.at:%H:%M} {_deg(h.temp)} {words(h.code).lower()}" + (f", rain {h.rain_chance}%"
                                                                          if h.rain_chance >= 20 else "")

    async def weather_tool(place: str | None = None, day: str | None = None) -> str:
        fc = await weather.here_or_home(place)
        now = datetime.now(tz)
        where = fc.place or "there"
        if day and day.strip().lower() not in ("", "today"):
            d = now.date() + timedelta(days=1) if day.strip().lower() == "tomorrow" else date.fromisoformat(day.strip())
            s = day_summary(fc, d)
            if s is None:
                return f"No forecast for {d:%a %d %b} (it covers the next {DAYS} days)."
            hours = [h for h in fc.hours_of(d) if WAKING[0] <= h.at.hour <= WAKING[1]]
            return "\n".join([f"Weather {where}, {d:%a %d %b}: {s['summary']}.", "Hour by hour:",
                              *(f"- {hour_line(h)}" for h in hours[::2])])
        out = []
        if fc.now:
            out.append(f"Weather {where}, now {_deg(fc.now['temp'])}"
                       + (f" (feels {_deg(fc.now['feels'])})" if fc.now["feels"] is not None
                          and abs(fc.now["feels"] - fc.now["temp"]) >= 2 else "")
                       + f", {words(fc.now['code']).lower()}.")
        if s := day_summary(fc, now.date(), now):
            out.append(f"Rest of today: {s['summary']}.")
        nxt = [h for h in fc.hours if now - timedelta(hours=1) < h.at <= now + timedelta(hours=12)]
        if nxt:
            out += ["Next hours:", *(f"- {hour_line(h)}" for h in nxt[::2])]
        later = [x for x in fc.days if x.day > now.date()]
        if later:
            out.append("Next days:")
            for x in later:
                s = day_summary(fc, x.day)
                out.append(f"- {x.day:%a %d %b}: {s['summary'] if s else words(x.code)}"
                           + (f" ({round(x.rain_mm)} mm)" if x.rain_mm and x.rain_mm >= 1 else ""))
        return "\n".join(out) or "No forecast came back."

    return [Tool(
        "weather", "The weather forecast (Open-Meteo): now, the next hours and the next 7 days, or one day hour by "
        "hour. Default: where the user's phone is (when known recently), else home.",
        {"type": "object", "additionalProperties": False, "required": [], "properties": {
            "place": {"type": "string", "description": "A town, address or place; \"here\" for where the phone is "
                                                       "(a fresh fix); default where the phone is, else home"},
            "day": {"type": "string", "description": "\"today\" (default: now, the next hours and the week), "
                                                     "\"tomorrow\" or YYYY-MM-DD for that day hour by hour"}}},
        weather_tool, step=lambda a: "Checking the weather")]
