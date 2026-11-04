"""Price watches: a product page read every few hours with no model, a post when the line is crossed."""
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION
from aide.channels.api import create_app
from aide.pricewatch import PriceWatches, format_money, price_watch_tools, read_offer, with_coupon
from aide.reminders import ReminderStore
from test_agents import AUTH, ROME
from test_errands import env  # noqa: F401  (a fixture)

AIRPODS = "https://www.amazon.it/dp/B0AIRPODS3"


def amazon(price=None, availability=None, coupon=None, buybox=True):
    return {"title": "AirPods Pro 3", "name": None, "offers": [], "meta": {}, "text": "",
            "amazon": {"price": price, "availability": availability, "coupon": coupon, "buybox": buybox}}


def test_reading_an_offer():
    o = read_offer(amazon("169,00 €", "Disponibilità immediata"))
    assert (o["amount"], o["currency"], o["in_stock"], o["effective"]) == (169.0, "EUR", True, 169.0)
    o = read_offer(amazon("169,00 €", coupon="Applica coupon da 20 €"))
    assert o["effective"] == 149.0 and o["coupon"] == "Applica coupon da 20 €"
    assert read_offer(amazon(None, "Attualmente non disponibile.", buybox=False))["in_stock"] is False
    # Schema.org JSON-LD and the meta tags, on any shop.
    ld = {"offers": [{"price": "129.90", "currency": "EUR", "availability": "https://schema.org/InStock"}],
          "meta": {}, "amazon": {}, "text": "", "name": "Sony WH-1000XM6"}
    o = read_offer(ld)
    assert (o["amount"], o["in_stock"], o["price"], o["name"]) == (129.9, True, "129,90 €", "Sony WH-1000XM6")
    o = read_offer({"offers": [], "amazon": {}, "text": "",
                    "meta": {"price": "99", "currency": "usd", "availability": "out of stock"}})
    assert (o["amount"], o["currency"], o["in_stock"]) == (99.0, "USD", False)
    assert read_offer({"offers": [], "meta": {}, "amazon": {}, "text": "Nothing here"})["amount"] is None
    assert with_coupon(200.0, "Risparmia 10% con coupon") == 180.0
    assert with_coupon(10.0, "coupon da 20 €") == 10.0  # not below zero: ignored
    assert format_money(1234.5, "EUR") == "1.234,50 €"


class OfferBrowser:
    def __init__(self):
        self.raw = amazon("189,00 €", "Disponibilità immediata")
        self.opened, self.closed = [], []

    async def open(self, owner, url):
        self.opened.append(url)

    async def offer(self, owner):
        return self.raw

    async def close(self, owner):
        self.closed.append(owner)


class Posts:
    def __init__(self):
        self.posts = []

    async def post(self, conversation, note, text, attachments=None, record=True):
        self.posts.append((conversation, text, attachments))


async def test_a_watch_posts_once_when_the_price_crosses_the_line(env):  # noqa: F811
    make, db, _ = env
    browser, chat = OfferBrowser(), Posts()
    watches = PriceWatches(db.conn, ROME, browser)
    watches.agent = chat
    w = watches.add(AIRPODS, "AirPods Pro 3", 150, False, None, CONVERSATION)
    assert w["site"] == "amazon.it" and w["every_hours"] == 4
    assert [x["id"] for x in watches.due()] == [w["id"]]
    w = await watches.check(w["id"])
    assert w["status"] == "active" and w["amount"] == 189.0 and chat.posts == []
    assert browser.closed == [f"watch:{w['id']}"]  # the page isn't kept open
    assert watches.due() == []  # next in 4 h

    browser.raw = amazon("169,00 €", "Disponibilità immediata", "Applica coupon da 20 €")
    w = await watches.check(w["id"])
    assert w["status"] == "met" and w["effective"] == 149.0
    [(conversation, text, [card])] = chat.posts
    assert "149,00 €" in text and "under your 150,00 €" in text and "coupon" in text
    assert card["type"] == "price_watches" and card["price_watches"][0]["lowest"] == 149.0
    j = watches.as_json(w)
    assert j["next_at"] is None and j["below_text"] == "150,00 €" and len(j["history"]) == 2

    # Met: it doesn't check again until the user watches again.
    assert watches.due() == []
    w = watches.update(w["id"], status="active", below=130)
    assert w["met_at"] is None and [x["id"] for x in watches.due()] == [w["id"]]


async def test_back_in_stock_and_a_page_that_stops_showing_a_price(env):  # noqa: F811
    make, db, _ = env
    browser, chat = OfferBrowser(), Posts()
    watches = PriceWatches(db.conn, ROME, browser)
    watches.agent = chat
    browser.raw = amazon(None, "Attualmente non disponibile.", buybox=False)
    w = watches.add("https://www.amazon.it/dp/B0PS5", "PS5 Pro", None, True, 2, CONVERSATION)
    w = await watches.check(w["id"])
    assert w["in_stock"] is False and w["status"] == "active"
    browser.raw = amazon("799,00 €", "Disponibilità immediata")
    w = await watches.check(w["id"])
    assert w["status"] == "met" and "back in stock" in chat.posts[0][1]

    # Four looks in a row with nothing on the page: it stops and says so.
    browser.raw = {"offers": [], "meta": {}, "amazon": {}, "text": "Captcha"}
    w = watches.update(w["id"], status="active")
    for _ in range(4):
        w = await watches.check(w["id"])
    assert w["status"] == "failed" and "stopped watching" in chat.posts[-1][1]


def test_one_watch_per_page_and_what_a_watch_needs(env):  # noqa: F811
    make, db, _ = env
    watches = PriceWatches(db.conn, ROME)
    a = watches.add(AIRPODS, "AirPods", 150, False, None, CONVERSATION)
    b = watches.add(AIRPODS, "AirPods Pro 3", 140, False, 0.1, CONVERSATION)
    assert a["id"] == b["id"] and b["below"] == 140 and b["every_hours"] == 1  # at least an hour
    for bad in ((AIRPODS, "x", None, False), ("amazon.it/dp/1", "x", 10, False), (AIRPODS, "x", -1, False)):
        try:
            watches.add(*bad, None, CONVERSATION)
        except ValueError:
            continue
        raise AssertionError(bad)


async def test_the_tools_and_the_api(env):  # noqa: F811
    make, db, _ = env
    runner, agent, _ = make()
    browser = OfferBrowser()
    watches = PriceWatches(db.conn, ROME, browser)
    watches.agent, watches.errands = agent, runner
    tools = {t.name: t for t in price_watch_tools(watches, lambda: CONVERSATION)}
    out = await tools["watch_price"].handler(url=AIRPODS, title="AirPods Pro 3", below=150, stock=None, every_hours=None)
    assert "Watching AirPods Pro 3" in out and out.attachment["type"] == "price_watches"
    assert "under 150,00 €" in await tools["list_price_watches"].handler()

    client = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t", errands=runner, watches=watches))
    got = client.get("/v1/pricewatches", headers=AUTH).json()
    assert got["enabled"] and got["price_watches"][0]["price"] == "189,00 €"
    wid = got["price_watches"][0]["id"]
    assert client.patch(f"/v1/pricewatches/{wid}", headers=AUTH, json={"below": 200}).json()["below"] == 200
    assert client.patch(f"/v1/pricewatches/{wid}", headers=AUTH, json={"status": "nope"}).status_code == 422
    assert client.post(f"/v1/pricewatches/{wid}/check", headers=AUTH).json()["status"] == "met"
    added = client.post("/v1/pricewatches", headers=AUTH,
                        json={"url": "https://www.mediaworld.it/p/1", "title": "Kindle", "below": 90}).json()
    assert added["site"] == "mediaworld.it" and added["checked_at"]
    e = client.post(f"/v1/pricewatches/{wid}/buy", headers=AUTH).json()
    assert e["status"] == "queued" and AIRPODS in runner.store.get(e["id"])["task"]
    assert client.delete(f"/v1/pricewatches/{added['id']}", headers=AUTH).json() == {"ok": True}
    assert client.delete(f"/v1/pricewatches/{added['id']}", headers=AUTH).status_code == 404
    # Without a browser on the server.
    bare = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t"))
    assert bare.get("/v1/pricewatches", headers=AUTH).json() == {"price_watches": [], "enabled": False}
    assert bare.post("/v1/pricewatches", headers=AUTH, json={"url": AIRPODS, "title": "x"}).status_code == 503
