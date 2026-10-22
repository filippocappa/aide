"""Google Maps: places (Places API (New) Text Search) and travel times (Routes API). Read-only.

Plain HTTP with an API key. Field masks keep each request to the fields shown, which is what Google bills.
"""

import re
from collections.abc import Awaitable, Callable
from datetime import datetime, timedelta
from urllib.parse import urlencode
from zoneinfo import ZoneInfo

import httpx

from . import Tool

PLACES_URL = "https://places.googleapis.com/v1/places:searchText"
ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
PLACE_FIELDS = ("places.displayName,places.formattedAddress,places.rating,places.userRatingCount,"
                "places.currentOpeningHours.openNow,places.currentOpeningHours.weekdayDescriptions,"
                "places.googleMapsUri")
ROUTE_FIELDS = ("routes.duration,routes.staticDuration,routes.distanceMeters,"
                "routes.legs.steps.transitDetails")
MAX_PLACES = 5
MODES = {"drive": ("DRIVE", "driving"), "walk": ("WALK", "walking"),
         "transit": ("TRANSIT", "transit"), "bicycle": ("BICYCLE", "bicycling")}

TIME_HELP = "Local time as YYYY-MM-DDTHH:MM, or HH:MM for today."
HERE = "here"  # origin or near: where the user's phone is
NEARBY = 1500  # metres: the circle a search "here" is biased to


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


class GoogleMaps:
    def __init__(self, api_key: str, http: httpx.AsyncClient | None = None):
        self._key = api_key
        self._http = http or httpx.AsyncClient(timeout=30)

    async def _post(self, url: str, fields: str, body: dict) -> dict:
        r = await self._http.post(url, json=body, headers={"X-Goog-Api-Key": self._key, "X-Goog-FieldMask": fields})
        if r.status_code >= 400:
            try:
                message = r.json()["error"]["message"]
            except (ValueError, KeyError, TypeError):
                message = r.text[:200]
            raise RuntimeError(f"Google Maps error {r.status_code}: {message}")
        return r.json()

    async def search_places(self, query: str, open_now: bool, center: tuple[float, float] | None = None) -> list[dict]:
        body: dict = {"textQuery": query, "pageSize": MAX_PLACES}
        if center:
            body["locationBias"] = {"circle": {"center": {"latitude": center[0], "longitude": center[1]},
                                               "radius": NEARBY}}
        if open_now:
            body["openNow"] = True
        return (await self._post(PLACES_URL, PLACE_FIELDS, body)).get("places", [])

    async def locate(self, query: str, near: tuple[float, float] | None = None, radius: float = 20_000) -> dict | None:
        """Where a place is: {name, lat, lon}, the best match (near a point, when given), or None."""
        body: dict = {"textQuery": query, "pageSize": 1}
        if near:
            body["locationBias"] = {"circle": {"center": {"latitude": near[0], "longitude": near[1]}, "radius": radius}}
        places = (await self._post(PLACES_URL, "places.displayName,places.location", body)).get("places", [])
        if not places or "location" not in places[0]:
            return None
        p = places[0]
        return {"name": (p.get("displayName") or {}).get("text") or query,
                "lat": p["location"]["latitude"], "lon": p["location"]["longitude"]}

    async def route(self, body: dict) -> dict | None:
        routes = (await self._post(ROUTES_URL, ROUTE_FIELDS, body)).get("routes", [])
        return routes[0] if routes else None


def _seconds(duration: str | None) -> int:
    return int(float(duration.rstrip("s"))) if duration else 0  # protobuf Duration, e.g. "1234s"


def _human(seconds: int) -> str:
    minutes = round(seconds / 60)
    if minutes < 60:
        return f"{max(minutes, 1)} min"
    return f"{minutes // 60} h {minutes % 60:02d} min" if minutes % 60 else f"{minutes // 60} h"


def _distance(meters: int) -> str:
    return f"{meters} m" if meters < 1000 else f"{meters / 1000:.1f} km"


def maps_tools(maps: GoogleMaps, tz: ZoneInfo, home: str | None,
               here: Callable[[], Awaitable[tuple[float, float] | None]] | None = None) -> list[Tool]:
    """`here` gives where the phone is, (lat, lon), or None when that isn't known."""
    def place_or_home(value: str | None, what: str) -> str:
        if value and value.strip():
            return value.strip()
        if not home:
            raise ValueError(f"no home address is set: ask the user for the {what}")
        return home

    async def phone(value: str | None) -> tuple[float, float] | None:
        """The phone's position when value is "here"; None for any other value."""
        if (value or "").strip().lower() != HERE:
            return None
        fix = await here() if here else None
        if fix is None:
            raise ValueError("where the user is isn't known (location is off in the app, or the last fix is "
                             "over 2 hours old): ask where they are")
        return fix

    def parse_time(value: str) -> datetime:
        now = datetime.now(tz)
        if re.fullmatch(r"\d{1,2}:\d{2}", value.strip()):
            h, m = map(int, value.split(":"))
            return now.replace(hour=h, minute=m, second=0, microsecond=0)
        dt = datetime.fromisoformat(value)
        return dt.replace(tzinfo=tz) if dt.tzinfo is None else dt.astimezone(tz)

    def local(timestamp: str) -> datetime:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone(tz)

    def clock(dt: datetime) -> str:
        return f"{dt:%H:%M}" if dt.date() == datetime.now(tz).date() else f"{dt:%a %d %b %H:%M}"

    async def find_places(query: str, open_now: bool | None = None, near: str | None = None) -> str:
        if center := await phone(near):
            where = "where you are"
            found = await maps.search_places(query, bool(open_now), center)
        else:
            where = place_or_home(near, "area to search")
            found = await maps.search_places(f"{query} near {where}", bool(open_now))
        if not found:
            return "No places found." + (" (Only places open now were searched.)" if open_now else "")
        weekday = datetime.now(tz).weekday()  # weekdayDescriptions start on Monday
        out = []
        for p in found:
            line = p.get("displayName", {}).get("text", "?")
            if rating := p.get("rating"):
                line += f" · ★{rating}" + (f" ({p['userRatingCount']})" if p.get("userRatingCount") else "")
            hours = p.get("currentOpeningHours") or {}
            if "openNow" in hours:
                line += " · open now" if hours["openNow"] else " · closed now"
            line += f"\n   {p.get('formattedAddress', '')}"
            if (days := hours.get("weekdayDescriptions")) and len(days) == 7:
                line += f"\n   Today: {days[weekday].split(': ', 1)[-1]}"
            if url := p.get("googleMapsUri"):
                line += f"\n   {url.split('&g_mp=')[0]}"  # g_mp is Google's tracking blob; the cid is the link
            out.append(line)
        return f"Near {where}:\n" + "\n".join(out)

    async def travel_time(destination: str, origin: str | None = None, mode: str | None = None,
                          departure_time: str | None = None, arrival_time: str | None = None) -> str:
        mode = mode or "drive"
        if mode not in MODES:
            raise ValueError(f"mode must be one of {', '.join(MODES)}")
        if departure_time and arrival_time:
            raise ValueError("give a departure time or an arrival time, not both")
        if arrival_time and mode != "transit":
            raise ValueError("an arrival time works only for transit; give a departure time instead")
        if fix := await phone(origin):
            start, link_start = "where you are", f"{fix[0]:.6f},{fix[1]:.6f}"
            start_point: dict = {"location": {"latLng": {"latitude": fix[0], "longitude": fix[1]}}}
        else:
            start = link_start = place_or_home(origin, "starting point")
            start_point = {"address": start}
        travel_mode, url_mode = MODES[mode]
        body: dict = {"origin": start_point, "destination": {"address": destination}, "travelMode": travel_mode}
        if mode == "drive":
            body["routingPreference"] = "TRAFFIC_AWARE"
        when = None
        if departure_time or arrival_time:
            when = parse_time(departure_time or arrival_time)
            if when < datetime.now(tz) - timedelta(minutes=1):
                raise ValueError(f"{when:%a %d %b %H:%M} is in the past")
            stamp = when.astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")
            body["departureTime" if departure_time else "arrivalTime"] = stamp

        route = await maps.route(body)
        link = "https://www.google.com/maps/dir/?" + urlencode(
            {"api": 1, "origin": link_start, "destination": destination, "travelmode": url_mode})
        if route is None:
            return f"No {mode} route found from {start} to {destination}.\n{link}"

        seconds = _seconds(route.get("duration"))
        line = f"{mode.capitalize()} from {start} to {destination}: {_human(seconds)}"
        if mode == "drive":
            usual = _seconds(route.get("staticDuration"))
            if usual and abs(seconds - usual) >= 120:
                line += f" with traffic ({_human(usual)} without)"
        line += f", {_distance(route.get('distanceMeters', 0))}."
        out = [line]
        if mode != "transit" and when and departure_time:
            out.append(f"Leaving {clock(when)}, arriving about {clock(when + timedelta(seconds=seconds))}.")

        if mode == "transit":
            rides = [s["transitDetails"] for leg in route.get("legs", []) for s in leg.get("steps", [])
                     if s.get("transitDetails")]
            for t in rides:
                stops, tl = t.get("stopDetails", {}), t.get("transitLine", {})
                name = tl.get("nameShort") or tl.get("name") or "?"
                vehicle = tl.get("vehicle", {}).get("name", {}).get("text", "")
                towards = f" towards {t['headsign']}" if t.get("headsign") else ""
                dep = local(stops["departureTime"]) if stops.get("departureTime") else None
                arr = local(stops["arrivalTime"]) if stops.get("arrivalTime") else None
                out.append(f"- {vehicle + ' ' if vehicle else ''}{name}{towards}: "
                           f"{clock(dep) if dep else '?'} from {stops.get('departureStop', {}).get('name', '?')}, "
                           f"{clock(arr) if arr else '?'} at {stops.get('arrivalStop', {}).get('name', '?')}")
            if rides and rides[0].get("stopDetails", {}).get("departureTime"):
                first = local(rides[0]["stopDetails"]["departureTime"])
                out.insert(1, f"First departure {clock(first)}.")
            elif not rides:
                out.append("No transit rides on this route (it's walking only).")
        out.append(link)
        return "\n".join(out)

    return [
        Tool("find_places", "Find places with Google Maps: shops, pharmacies, restaurants, stations. Returns up to "
             f"{MAX_PLACES} with name, rating, open or closed now, address, today's hours and a Google Maps link. "
             "Searches near the user's home unless near is given (\"here\": near the user's phone).",
             _obj({"query": {"type": "string", "description": "What to look for, e.g. 'pharmacy', 'sushi'"},
                   "open_now": {"type": "boolean", "description": "Only places open right now"},
                   "near": {"type": "string",
                            "description": "Address or place to search around, or \"here\" for where the "
                                           "user's phone is; default the user's home"}},
                  ["query"]), find_places),
        Tool("travel_time", "How long it takes to get somewhere, with Google Maps. Driving includes live traffic; "
             "transit lists the lines and departure times. Ends with a Google Maps directions link.",
             _obj({"destination": {"type": "string", "description": "Address or place name"},
                   "origin": {"type": "string", "description": "Address or place name, or \"here\" for where "
                                                         "the user's phone is; default the user's home"},
                   "mode": {"type": "string", "enum": list(MODES), "description": "default drive"},
                   "departure_time": {"type": "string", "description": f"Leave at this time. {TIME_HELP}"},
                   "arrival_time": {"type": "string",
                                    "description": f"Arrive by this time (transit only). {TIME_HELP}"}},
                  ["destination"]), travel_time),
    ]
