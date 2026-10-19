import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import httpx
import pytest

from aide.tools.maps import GoogleMaps, maps_tools
from aide.tools.search import Tavily, search_tools

ROME = ZoneInfo("Europe/Rome")
HOME = "Via Roma 1, Milano"


class Recorder:
    """A MockTransport handler that answers with canned JSON and keeps every request."""

    def __init__(self, *responses: httpx.Response):
        self.responses = list(responses)
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self.responses.pop(0)

    def body(self, i=-1) -> dict:
        return json.loads(self.requests[i].content)


def client(rec: Recorder) -> httpx.AsyncClient:
    return httpx.AsyncClient(transport=httpx.MockTransport(rec))


# -- web search ---------------------------------------------------------------------------


def search(rec: Recorder) -> dict:
    return {t.name: t for t in search_tools(Tavily("tv-key", client(rec)), ROME)}


async def test_search_lists_answer_titles_urls_snippets():
    rec = Recorder(httpx.Response(200, json={
        "answer": "It opens on Monday.",
        "results": [{"title": "Museum reopens", "url": "https://news.example/a",
                     "content": "The museum\n reopens  Monday " + "x" * 400,
                     "published_date": "Mon, 19 Oct 2026 08:00:00 GMT"}],
    }))
    out = await search(rec)["web_search"].handler(query="museum reopening", topic="news")
    assert rec.requests[0].headers["Authorization"] == "Bearer tv-key"
    assert rec.body() == {"query": "museum reopening", "max_results": 5, "topic": "news", "include_answer": True}
    assert out.startswith("Answer: It opens on Monday.")
    assert "1. Museum reopens · Mon 19 Oct 2026 10:00\n   https://news.example/a\n   The museum reopens Monday" in out
    assert out.endswith("x…")


async def test_search_clamps_count_and_handles_no_results():
    rec = Recorder(httpx.Response(200, json={"results": []}))
    assert await search(rec)["web_search"].handler(query="q", max_results=50) == "No results."
    assert rec.body()["max_results"] == 10 and rec.body()["topic"] == "general"


async def test_search_out_of_credits_says_so():
    rec = Recorder(httpx.Response(432, json={"detail": "limit"}))
    with pytest.raises(RuntimeError, match="used up"):
        await search(rec)["web_search"].handler(query="q")


async def test_fetch_page_returns_the_text():
    rec = Recorder(httpx.Response(200, json={"results": [{"url": "https://a.example", "raw_content": "Hello page"}],
                                             "failed_results": []}))
    out = await search(rec)["fetch_page"].handler(url="https://a.example")
    assert rec.body() == {"urls": ["https://a.example"]}
    assert out == "https://a.example\n\nHello page"


async def test_fetch_page_failure_and_bad_url():
    rec = Recorder(httpx.Response(200, json={"results": [], "failed_results": [{"url": "https://a.example"}]}))
    assert "Couldn't read" in await search(rec)["fetch_page"].handler(url="https://a.example")
    with pytest.raises(ValueError):
        await search(rec)["fetch_page"].handler(url="file:///etc/passwd")


# -- maps ---------------------------------------------------------------------------------


def maps(rec: Recorder, home=HOME) -> dict:
    return {t.name: t for t in maps_tools(GoogleMaps("gm-key", client(rec)), ROME, home)}


def test_all_tools_are_read_only():
    tools = [*search(Recorder()).values(), *maps(Recorder()).values()]
    assert [t.name for t in tools] == ["web_search", "fetch_page", "find_places", "travel_time"]
    assert not any(t.confirm for t in tools)


async def test_find_places_near_home_with_field_mask():
    week = [f"{d}: 9:00 AM – 7:30 PM" for d in
            ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]]
    rec = Recorder(httpx.Response(200, json={"places": [{
        "displayName": {"text": "Farmacia Centrale"}, "formattedAddress": "Via Dante 2, Milano",
        "rating": 4.6, "userRatingCount": 120,
        "currentOpeningHours": {"openNow": True, "weekdayDescriptions": week},
        "googleMapsUri": "https://maps.google.com/?cid=1&g_mp=Cidnb"}]}))
    out = await maps(rec)["find_places"].handler(query="pharmacy", open_now=True)
    req = rec.requests[0]
    assert req.headers["X-Goog-Api-Key"] == "gm-key"
    assert "places.googleMapsUri" in req.headers["X-Goog-FieldMask"] and "places.photos" not in req.headers["X-Goog-FieldMask"]
    assert rec.body() == {"textQuery": f"pharmacy near {HOME}", "pageSize": 5, "openNow": True}
    today = week[datetime.now(ROME).weekday()].split(": ", 1)[1]
    assert out == (f"Near {HOME}:\nFarmacia Centrale · ★4.6 (120) · open now\n   Via Dante 2, Milano\n"
                   f"   Today: {today}\n   https://maps.google.com/?cid=1")


async def test_find_places_elsewhere_and_empty():
    rec = Recorder(httpx.Response(200, json={}))
    out = await maps(rec)["find_places"].handler(query="sushi", near="Navigli")
    assert rec.body() == {"textQuery": "sushi near Navigli", "pageSize": 5} and out == "No places found."


async def test_no_home_and_no_origin_asks():
    with pytest.raises(ValueError, match="no home address"):
        await maps(Recorder(), home=None)["travel_time"].handler(destination="Milano Centrale")


async def test_drive_reports_traffic_and_link():
    rec = Recorder(httpx.Response(200, json={"routes": [
        {"duration": "1980s", "staticDuration": "1500s", "distanceMeters": 12400}]}))
    out = await maps(rec)["travel_time"].handler(destination="Linate Airport")
    body = rec.body()
    assert body["travelMode"] == "DRIVE" and body["routingPreference"] == "TRAFFIC_AWARE"
    assert body["origin"] == {"address": HOME} and "departureTime" not in body
    assert out.startswith(f"Drive from {HOME} to Linate Airport: 33 min with traffic (25 min without), 12.4 km.")
    assert out.endswith("travelmode=driving")


async def test_transit_arrival_time_lists_lines_in_local_time():
    rec = Recorder(httpx.Response(200, json={"routes": [{
        "duration": "1500s", "distanceMeters": 6100,
        "legs": [{"steps": [
            {"travelMode": "WALK"},
            {"transitDetails": {
                "stopDetails": {"departureStop": {"name": "Duomo"}, "arrivalStop": {"name": "Centrale FS"},
                                "departureTime": "2099-01-05T07:40:00Z", "arrivalTime": "2099-01-05T07:52:00Z"},
                "headsign": "Comasina", "transitLine": {"nameShort": "M3", "vehicle": {"name": {"text": "Subway"}}}}},
        ]}]}]}))
    out = await maps(rec)["travel_time"].handler(destination="Milano Centrale", mode="transit",
                                                  arrival_time="2099-01-05T09:00")
    body = rec.body()
    assert body["travelMode"] == "TRANSIT" and body["arrivalTime"] == "2099-01-05T08:00:00Z"
    assert "routingPreference" not in body
    assert "Transit from Via Roma 1, Milano to Milano Centrale: 25 min, 6.1 km." in out
    assert "First departure Mon 05 Jan 08:40." in out
    assert "- Subway M3 towards Comasina: Mon 05 Jan 08:40 from Duomo, Mon 05 Jan 08:52 at Centrale FS" in out
    assert "travelmode=transit" in out


async def test_departure_at_a_clock_time_today_and_validation():
    soon = datetime.now(ROME) + timedelta(hours=1)
    if soon.date() != datetime.now(ROME).date():
        pytest.skip("too close to midnight for an HH:MM test")
    rec = Recorder(httpx.Response(200, json={"routes": [{"duration": "600s", "distanceMeters": 2500}]}))
    out = await maps(rec)["travel_time"].handler(destination="Park", mode="bicycle",
                                                  departure_time=f"{soon:%H:%M}")
    assert rec.body()["departureTime"].endswith("Z")
    assert f"Leaving {soon:%H:%M}, arriving about {soon + timedelta(minutes=10):%H:%M}." in out
    tools = maps(Recorder())
    with pytest.raises(ValueError, match="in the past"):
        await tools["travel_time"].handler(destination="Park", departure_time="2001-01-01T09:00")
    with pytest.raises(ValueError, match="only for transit"):
        await tools["travel_time"].handler(destination="Park", arrival_time="2099-01-01T09:00")


async def test_google_error_message_is_passed_on():
    rec = Recorder(httpx.Response(403, json={"error": {"message": "Routes API has not been used in project"}}))
    with pytest.raises(RuntimeError, match="Routes API has not been used"):
        await maps(rec)["travel_time"].handler(destination="Park")
