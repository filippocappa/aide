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


class FakeBrowser:
    """Stands in for aide.browser.Browser: read_whole answers with `text` (or raises), every owner closed after."""

    def __init__(self, text: str | Exception):
        self.text, self.reads, self.closed, self.pruned = text, [], [], 0

    async def read_whole(self, owner, url):
        self.reads.append((owner, url))
        if isinstance(self.text, Exception):
            raise self.text
        return self.text

    async def close(self, owner):
        self.closed.append(owner)

    async def prune(self):
        self.pruned += 1


def read_with(browser, rec=None) -> dict:
    return {t.name: t for t in search_tools(Tavily("tv-key", client(rec or Recorder())), ROME, browser)}


async def test_fetch_page_reads_in_the_browser_and_closes_it():
    browser = FakeBrowser("Schedule — https://a.example\n\n10 November\n9.45 - 10.00\nKICK-OFF")
    out = await read_with(browser)["fetch_page"].handler(url="https://a.example")
    assert out == "Schedule — https://a.example\n\n10 November\n9.45 - 10.00\nKICK-OFF"
    assert browser.reads == [("read:1", "https://a.example")] and browser.closed == ["read:1"] and browser.pruned == 1


async def test_fetch_page_falls_back_to_tavily_when_the_browser_fails():
    rec = Recorder(httpx.Response(200, json={"results": [{"url": "https://a.example", "raw_content": "Hello"}]}))
    browser = FakeBrowser(TimeoutError())
    out = await read_with(browser, rec)["fetch_page"].handler(url="https://a.example")
    assert out == "https://a.example\n\nHello" and browser.closed == ["read:1"]


async def test_a_long_page_comes_in_parts_read_once():
    from aide.tools.search import PAGE_LIMIT
    line = "x" * 99
    browser = FakeBrowser("\n".join(f"{i:03d}{line}" for i in range(int(PAGE_LIMIT * 2.5 / 103))))
    tools = read_with(browser)
    first = await tools["fetch_page"].handler(url="https://a.example")
    assert first.startswith("000x") and first.endswith("[Part 1 of 3. The rest: fetch_page with part=2. The page's links are at the end of the last part.]")
    second = await tools["fetch_page"].handler(url="https://a.example", part=2)
    last = await tools["fetch_page"].handler(url="https://a.example", part=9)
    assert second.startswith("[Part 2 of 3 of this page]\n") and last.endswith("[Part 3 of 3, the last.]")
    assert len(browser.reads) == 1  # the later parts come from the first read
    joined = "\n".join(p.removeprefix("[Part 2 of 3 of this page]\n").removeprefix("[Part 3 of 3 of this page]\n")
                       .rsplit("\n\n[Part", 1)[0] for p in (first, second, last))
    assert joined == browser.text


def test_parts_cut_a_very_long_line():
    from aide.tools.search import _parts
    assert _parts("ab\n" + "c" * 25 + "\nd", limit=10) == ["ab", "c" * 10, "c" * 10, "c" * 5 + "\nd"]


def test_new_part_keeps_what_next_added():
    from aide.browser import _new_part
    before = ["Header", "Menu", "Talk A", "Talk B", "More pages", "Footer"]
    after = ["Header", "Menu", "Talk C", "Talk D", "More pages", "Footer"]
    assert _new_part(before, after) == ["Talk C", "Talk D"]
    assert _new_part(before, before) == []
    assert _new_part(["Header", "Talk A"], ["Header", "Talk A", "Talk B"]) == ["Talk B"]  # a Load more


def test_a_ticking_countdown_is_not_a_next_page():
    from aide.browser import _worth
    assert not _worth(["44"]) and not _worth(["06", "27", "44"]) and not _worth(["02:13"]) and not _worth([])
    assert _worth(["Talk C"]) and _worth(["44", "Mattia Mucci"])


def test_the_page_links_are_listed_own_site_first():
    from aide.browser import _link_list
    found = [["", "https://x.com/SF_Summit"], ["View All", "https://socialfootballsummit.com/en/sfs-26/speaker"],
             ["", "https://socialfootballsummit.com/en/sfs-26/schedule"],
             ["Schedule", "https://socialfootballsummit.com/en/sfs-26/schedule#day1"],
             ["Home", "https://socialfootballsummit.com/en/"], ["Mail", "mailto:info@sfs.com"],
             ["Shop", "https://shop.socialfootballsummit.com/tickets"]]
    assert _link_list(found, "https://socialfootballsummit.com/en") == [
        "View All: https://socialfootballsummit.com/en/sfs-26/speaker",
        "Schedule: https://socialfootballsummit.com/en/sfs-26/schedule",
        "Shop: https://shop.socialfootballsummit.com/tickets",
        "https://x.com/SF_Summit"]
    assert len(_link_list([["", f"https://a.it/{i}"] for i in range(9)], "https://a.it", limit=4)) == 4


# -- maps ---------------------------------------------------------------------------------


def maps(rec: Recorder, home=HOME) -> dict:
    return {t.name: t for t in maps_tools(GoogleMaps("gm-key", client(rec)), ROME, home)}


def test_all_tools_are_read_only():
    tools = [*search(Recorder()).values(), *maps(Recorder()).values()]
    assert [t.name for t in tools] == ["web_search", "research", "fetch_page", "find_places", "travel_time"]
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
    assert "google.com" not in out and out.endswith("(no link to paste).")  # the card has it
    [card] = out.attachment["routes"]
    assert out.attachment["type"] == "routes"
    assert {k: card[k] for k in ("mode", "from", "to", "duration", "usual", "distance", "rides")} == {
        "mode": "drive", "from": HOME, "to": "Linate Airport", "duration": 1980, "usual": 1500, "distance": 12400,
        "rides": []}
    depart, arrive = (datetime.fromisoformat(card[k].replace("Z", "+00:00")) for k in ("depart", "arrive"))
    assert arrive - depart == timedelta(seconds=1980) and abs(depart - datetime.now(ROME)) < timedelta(minutes=1)
    assert card["url"].startswith("https://www.google.com/maps/dir/?") and card["id"]


async def test_here_starts_from_the_phone():
    rec = Recorder(httpx.Response(200, json={"routes": [{"duration": "900s", "distanceMeters": 6100}]}),
                   httpx.Response(200, json={}))

    async def here():
        return 45.0703, 7.6869

    tools = {t.name: t for t in maps_tools(GoogleMaps("gm-key", client(rec)), ROME, HOME, here)}
    out = await tools["travel_time"].handler(destination="SME, Torino", origin="here")
    assert rec.body(0)["origin"] == {"location": {"latLng": {"latitude": 45.0703, "longitude": 7.6869}}}
    assert out.startswith("Drive from where you are to SME, Torino: 15 min, 6.1 km.")
    assert "origin=45.070300%2C7.686900" in out.attachment["routes"][0]["url"]
    await tools["find_places"].handler(query="pharmacy", near="Here")
    assert rec.body(1) == {"textQuery": "pharmacy", "pageSize": 5, "locationBias": {"circle": {
        "center": {"latitude": 45.0703, "longitude": 7.6869}, "radius": 1500}}}


async def test_here_unknown_asks():
    async def nowhere():
        return None

    for tools in (maps(Recorder()), {t.name: t for t in maps_tools(GoogleMaps("k", client(Recorder())), ROME, HOME,
                                                                   nowhere)}):
        with pytest.raises(ValueError, match="ask where they are"):
            await tools["travel_time"].handler(destination="SME", origin="here")


async def test_address_near_is_street_and_town():
    rec = Recorder(httpx.Response(200, json={"places": [{"formattedAddress": "Piazza Castello, 34, 10122 Torino TO",
        "addressComponents": [{"longText": "34", "types": ["street_number"]},
                              {"longText": "Piazza Castello", "types": ["route"]},
                              {"longText": "Torino", "types": ["locality", "political"]}]}]}),
                   httpx.Response(200, json={}))
    gm = GoogleMaps("gm-key", client(rec))
    assert await gm.address_near(45.05, 7.66) == "Piazza Castello 34, Torino"
    assert rec.body(0)["rankPreference"] == "DISTANCE" and rec.requests[0].url.path.endswith("searchNearby")
    assert await gm.address_near(45.05, 7.66) is None


async def test_transit_arrival_time_lists_lines_in_local_time():
    rec = Recorder(httpx.Response(200, json={"routes": [{
        "duration": "1500s", "distanceMeters": 6100,
        "legs": [{"steps": [
            {"travelMode": "WALK"},
            {"transitDetails": {
                "stopDetails": {"departureStop": {"name": "Duomo"}, "arrivalStop": {"name": "Centrale FS"},
                                "departureTime": "2099-01-05T07:40:00Z", "arrivalTime": "2099-01-05T07:52:00Z"},
                "headsign": "Comasina", "transitLine": {"nameShort": "M3", "vehicle": {"name": {"text": "Subway"},
                                                                                      "type": "SUBWAY"}}}},
        ]}]}]}))
    out = await maps(rec)["travel_time"].handler(destination="Milano Centrale", mode="transit",
                                                  arrival_time="2099-01-05T09:00")
    body = rec.body()
    assert body["travelMode"] == "TRANSIT" and body["arrivalTime"] == "2099-01-05T08:00:00Z"
    assert "routingPreference" not in body
    assert "Transit from Via Roma 1, Milano to Milano Centrale: 25 min, 6.1 km." in out
    assert "First departure Mon 05 Jan 08:40." in out
    assert "- Subway M3 towards Comasina: Mon 05 Jan 08:40 from Duomo, Mon 05 Jan 08:52 at Centrale FS" in out
    assert "travelmode=transit" in out.attachment["routes"][0]["url"]
    [card] = out.attachment["routes"]
    assert card["rides"] == [{"line": "M3", "vehicle": "Metro", "towards": "Comasina", "from": "Duomo",
                              "depart": "2099-01-05T07:40:00Z", "to": "Centrale FS", "arrive": "2099-01-05T07:52:00Z"}]
    assert (card["depart"], card["arrive"], card["usual"]) == ("2099-01-05T07:40:00Z", "2099-01-05T07:52:00Z", None)


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


# -- research -----------------------------------------------------------------------------


PAGE = "\n".join([
    "* [PRODUCTS](https://coros.example/products)", "* [SUPPORT](https://coros.example/support)",
    "Box contents and care for your strap, washing it by hand in cold water.",
    "Compatibility: the COROS Heart Rate Monitor works with Apple Watch (all models) over Bluetooth.",
    "Shipping and returns within 30 days of purchase for every order placed online.",
])


async def test_research_reads_the_top_sites_and_keeps_what_matches():
    rec = Recorder(httpx.Response(200, json={
        "answer": "Yes, it pairs.",
        "results": [{"title": f"Site {i}", "url": f"https://s{i}.example/p", "content": "snip",
                     "raw_content": PAGE if i == 1 else f"Apple Watch heart rate monitor notes number {i} here."}
                    for i in range(1, 7)] + [{"title": "Unread", "url": "https://u.example", "content": "c"}],
    }))
    tools = search(rec)
    out = await tools["research"].handler(query="COROS heart rate monitor Apple Watch")
    assert rec.body()["include_raw_content"] is True and rec.body()["max_results"] == 7
    assert rec.body()["search_depth"] == "advanced"
    assert "Read 5 sites" in out and "5. Site 5" in out and "6. Site 6" not in out
    assert "works with Apple Watch (all models)" in out
    assert "PRODUCTS" not in out  # the menu is dropped
    assert "Also found, not read:\n- Site 6: https://s6.example/p\n- Unread: https://u.example" in out
    assert tools["research"].step({"query": "q"}) == "Reading 5 sites on “q”"
    assert tools["web_search"].step({"query": "q"}) == "Searching the web for “q”"
    assert tools["fetch_page"].step({"url": "https://www.coros.com/a/b"}) == "Reading coros.com"


async def test_research_without_page_text_falls_back_to_a_search():
    rec = Recorder(httpx.Response(200, json={"results": [{"title": "T", "url": "https://t.example", "content": "c"}]}),
                   httpx.Response(200, json={"results": [{"title": "T", "url": "https://t.example", "content": "c"}]}))
    out = await search(rec)["research"].handler(query="q", sites=3)
    assert out.startswith("1. T") and len(rec.requests) == 2


def test_excerpt_keeps_the_closest_parts_within_the_limit():
    from aide.tools.search import _excerpt
    filler = [f"Unrelated paragraph {i} about shipping costs and delivery windows in general." for i in range(80)]
    page = "\n".join(filler[:40] + ["The strap pairs with Apple Watch over Bluetooth, says the maker."] + filler[40:])
    out = _excerpt(page, "does the strap pair with Apple Watch", 600)
    assert "pairs with Apple Watch" in out and len(out) < 1100
