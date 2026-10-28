import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.agents import AGENTS, connectors
from aide.browser import Browser, BrowserError, site_of
from aide.channels.api import create_app
from aide.db import Database
from aide.errands import (ErrandRunner, ErrandStore, Phase, commits, errand_tools, parse_money, picture_for,
                          purchase_tools, _same_total)
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from test_agents import AUTH, ROME, FakeClient, calls

CART = "https://www.amazon.it/cart"
CHECKOUT = "https://www.amazon.it/checkout"
THANKS = "https://www.amazon.it/thanks"

PAGES = {
    "https://www.amazon.it/s?k=cavo": ("Risultati", "Cavo USB-C Anker 2 m 9,99 €", {
        "1": {"text": "Cavo USB-C Anker 2 m, intrecciato, ricarica rapida 60 W, compatibile con iPhone 16"},
        "2": {"text": "Aggiungi al carrello", "goes": CART}}),
    CART: ("Carrello", "Subtotale 9,99 €", {"3": {"text": "Procedi all'ordine", "goes": CHECKOUT}}),
    CHECKOUT: ("Checkout", "Indirizzo: Via Roma 1, Torino. Totale ordine: 12,98 €", {
        "4": {"text": "Acquista ora", "goes": THANKS},
        "5": {"text": "Password", "sensitive": True},
        "6": {"text": "Codice promozionale", "submits": "Applica"}}),
    THANKS: ("Grazie", "Ordine 402-1234 effettuato. Totale 12,98 €. Arriva domani.", {}),
    "https://www.amazon.it/login": ("Accedi", "Accedi", {"7": {"text": "Email"}}),
}


class FakeBrowser:
    """The Browser's interface on scripted pages: each element can lead to another page."""

    def __init__(self, pages=PAGES):
        self.pages = {url: (title, text, dict(els)) for url, (title, text, els) in pages.items()}
        self.at: dict[str, str] = {}
        self._objects: dict[str, object] = {}
        self.clicked, self.typed, self.live_typed, self.taps = [], [], [], []
        self.pictures: dict[str, list[dict]] = {}  # a page's pictures by link
        self.acts: dict[str, dict] = {}
        self.product_pages: list[str] = []
        self.scenes: dict[str, dict] = {}  # a page's scene by address (none: the live view sends none)
        self.notes, self.put_in, self.pressed = [], [], []

    def page(self, owner):
        return self._objects.get(owner) if owner in self.at else None

    def where(self, owner):
        return {"url": self.at[owner], "site": site_of(self.at[owner])} if owner in self.at else None

    def _here(self, owner):
        if owner not in self.at:
            raise BrowserError("No page is open: open_page first.")
        return self.pages[self.at[owner]]

    async def open(self, owner, url):
        self.at[owner] = url
        self._objects.setdefault(owner, object())
        return f"{self.pages[url][0]} — {url}"

    async def read(self, owner, everything=False):
        title, text, els = self._here(owner)
        return "\n".join([f"Page: {title} — {self.at[owner]}", text,
                          *(f"[{r}] button \"{e['text']}\"" for r, e in els.items())])

    async def find(self, owner, text):
        return "nothing"

    async def inspect(self, owner, ref):
        els = self._here(owner)[2]
        if ref not in els:
            raise BrowserError(f"There's no [{ref}] on the page now: read_page again.")
        e = els[ref]
        return {"tag": "button", "type": "", "text": e["text"], "sensitive": e.get("sensitive", False),
                "submits": e.get("submits", "")}

    async def focused(self, owner):
        return {"submits": ""}

    def last_action(self, owner):
        return self.acts.get(owner)

    def narrate(self, owner, note):
        if note:
            self.notes.append(note)

    async def scene(self, owner):
        return self.scenes.get(self.at.get(owner))

    async def crop(self, owner, ref):
        return b"\xff\xd8 crop", {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1}

    async def put(self, owner, ref, text):
        self.put_in.append((ref, text))

    async def press_ref(self, owner, ref, tick=None):
        self.pressed.append((ref, tick))

    async def click(self, owner, ref):
        e = self._here(owner)[2][ref]
        self.clicked.append(e["text"])
        self.acts[owner] = {"seq": len(self.clicked), "kind": "click", "x": 0.5, "y": 0.4, "label": e["text"]}
        if "goes" in e:
            self.at[owner] = e["goes"]
        return "Clicked."

    async def fill(self, owner, ref, text, submit=False):
        self.typed.append(text)
        return "Typed."

    async def choose(self, owner, ref, option):
        return "Chose."

    async def press(self, owner, key):
        return "Pressed."

    async def scroll(self, owner, direction):
        return "Scrolled."

    async def back(self, owner):
        return "Went back."

    async def screenshot(self, owner, sharp=False):
        return b"\xff\xd8\xff fake jpeg"

    async def images(self, owner):
        self._here(owner)
        return self.pictures.get(self.at[owner], [])

    async def main_image(self, owner, url):
        self.product_pages.append(url)
        return f"https://img.test/{url.rsplit('/', 1)[-1]}.jpg"

    async def text(self, owner):
        return self._here(owner)[1]

    async def close(self, owner):
        self.at.pop(owner, None)

    async def prune(self):
        pass

    async def stop(self):
        pass

    def sites(self):
        return [{"site": "amazon.it", "used_at": "2026-10-27T10:00:00+00:00", "open": False}]

    async def forget(self, site):
        return site == "amazon.it"

    async def screencast(self, owner, on_frame):
        on_frame("AAAA", 824, 1830)

        async def stop():
            pass
        return stop

    async def tap(self, owner, x, y):
        self.taps.append((x, y))

    async def wheel(self, owner, x, y, dy):
        pass

    async def type_text(self, owner, text):
        self.live_typed.append(text)

    async def key(self, owner, name):
        pass

    async def focus(self, owner):
        return {"field": "password", "label": "Password"}


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")
    store = ErrandStore(db.conn, ROME)
    browser = FakeBrowser()
    photos = PhotoStore(tmp_path / "photos")

    def make(script=()):
        model = FakeClient(script)
        runner = ErrandRunner(store, browser, model, "m", CONVERSATION, photos=photos, audit=db.audit)
        tools = [*errand_tools(runner, lambda: CONVERSATION), *purchase_tools(store, ROME)]
        agent = Agent(FakeClient([]), db, ToolRegistry(tools), model="m", tz=ROME, photos=photos)
        runner.agent = agent
        return runner, agent, model
    yield make, db, browser
    db.close()


async def next_phase(runner):
    """Run the next queued errand's phase, as the worker would."""
    e = runner.store.get(runner.queue.get_nowait())
    await runner._phase(e)
    return runner.store.get(e["id"])


ITEM = {"title": "Cavo USB-C Anker 2 m", "quantity": 1, "price": "9,99 €", "image": None}


def test_money_and_totals():
    assert parse_money("12,99 €") == (12.99, "EUR")
    assert parse_money("€1.234,50") == (1234.5, "EUR")
    assert parse_money("$5.00") == (5.0, "USD")
    assert parse_money("EUR 1.234") == (1234.0, "EUR")
    assert parse_money("gratis") == (None, None)
    assert _same_total("12,98 €", "Totale ordine: 12,98 €")
    assert _same_total("EUR 12.98", "Totale: 12,98 €")
    assert not _same_total("12,98 €", "Totale ordine: 14,50 €")


def test_commit_words():
    for text in ("Acquista ora", "Ordina", "Paga ora", "Invia", "Place your order", "Buy now", "Iscriviti",
                 "Conferma e paga", "Prenota", "Book now", "Cancel order"):
        assert commits(text), text
    for text in ("Aggiungi al carrello", "Procedi all'ordine", "Proceed to checkout", "Continua", "Cerca",
                 "Elimina", "Accedi", "Libro: The Book of Tea, copertina flessibile, edizione 2024 tascabile"):
        assert not commits(text), text


async def test_an_order_waits_for_confirm_then_goes_through(env):
    make, db, browser = env
    runner, agent, _ = make([
        calls(("open_page", {"url": "https://www.amazon.it/s?k=cavo"})),
        calls(("click", {"ref": "2"})),
        calls(("click", {"ref": "3"})),
        calls(("click", {"ref": "4"})),  # refused: it buys
        calls(("ask_confirm", {"summary": "Order the Anker USB-C cable", "ref": "4", "total": "12,98 €",
                               "items": [ITEM], "delivery": "Domani", "address": "Via Roma 1, Torino"})),
        # After Confirm:
        calls(("click", {"ref": "4"})),
        calls(("record_order", {"total": "12,98 €", "items": [ITEM], "order_number": "402-1234",
                                "delivery": "Domani"})),
        calls(("finish", {"result": "Ordered: the Anker cable, 12,98 €, arriving tomorrow.", "ok": True})),
    ])
    e = runner.start("A USB-C cable, cheap, 2 m", "USB-C cable", "amazon.it", CONVERSATION)
    assert e["status"] == "queued" and e["site"] == "amazon.it"
    e = await next_phase(runner)
    assert e["status"] == "waiting_confirm"
    assert browser.clicked == ["Aggiungi al carrello", "Procedi all'ordine"]  # not "Acquista ora"
    refused = [r for r in runner.client.requests[4]["messages"][-1]["content"] if r["type"] == "tool_result"][0]
    assert refused["is_error"] and "ask_confirm" in refused["content"][0]["text"]

    # The Confirm is queued, with what the app shows.
    [action] = db.pending_actions(CONVERSATION, runner_ttl())
    assert action["tool"] == "errand_go" and action["summary"] == "Order the Anker USB-C cable (12,98 €)"
    assert action["detail"]["items"] == [ITEM] and action["detail"]["total"] == "12,98 €"
    assert action["detail"]["address"] == "Via Roma 1, Torino" and action["detail"]["screenshot"].startswith("p_")
    assert action["detail"]["button"] == "Acquista ora" and action["detail"]["site"] == "amazon.it"

    # Confirm only schedules the next phase: no browser step under the agent's lock.
    result = await agent.confirm(CONVERSATION)
    assert "Aide is doing it now" in result
    assert browser.clicked == ["Aggiungi al carrello", "Procedi all'ordine"]
    e = await next_phase(runner)
    assert e["status"] == "done" and e["result"].startswith("Ordered")
    assert browser.clicked[-1] == "Acquista ora"
    assert "The user confirmed" in prompt_of(runner.client.requests[5])

    [p] = runner.store.purchases()
    assert (p["site"], p["total"], p["amount"], p["currency"], p["order_ref"]) == \
        ("amazon.it", "12,98 €", 12.98, "EUR", "402-1234")
    assert p["receipt"].startswith("p_") and p["errand_id"] == e["id"]
    # Its chat got the cards: the errand, then the purchase.
    history = agent.visible_history(CONVERSATION)
    last = history[-1]
    # Its chat got the purchase card (the errand's own card is on Aide's first message and follows it).
    assert last["text"].startswith("Ordered") and [a["type"] for a in last["attachments"]] == ["purchases"]
    assert last["attachments"][0]["purchases"][0]["order_ref"] == "402-1234"
    # Finance sees it.
    listed = await purchase_tools(runner.store, ROME)[0].handler(days=7, site=None)
    assert "amazon.it" in listed and "Total: 12.98 EUR" in listed


def prompt_of(request) -> str:
    """The phase's opening prompt (the first message; a block with the cache breakpoint when it's the only one)."""
    content = request["messages"][0]["content"]
    return content if isinstance(content, str) else content[0]["text"]


def runner_ttl():
    from aide.agent import PENDING_TTL
    return PENDING_TTL


async def test_products_come_with_their_pictures(env):
    make, db, browser = env
    search = "https://www.amazon.it/s?k=cavo"
    browser.pictures[search] = [
        {"path": "/Anker-Cavo-USB-C/dp/B0ANKER/ref=sr_1_1", "src": "https://m.media-amazon.com/anker.jpg", "alt": ""},
        {"path": None, "src": "https://m.media-amazon.com/ugreen.jpg", "alt": "UGREEN cavo USB C 2 m nylon"}]
    runner, agent, _ = make([
        calls(("open_page", {"url": search})),
        calls(("read_page", {"everything": None})),
        calls(("finish", {"result": "Prenderei l'Anker: costa poco ed è molto recensito.", "ok": True, "products": [
            {"title": "Anker USB-C, 2 m", "url": "https://www.amazon.it/dp/B0ANKER", "price": "9,99 €",
             "rating": "4,6", "reviews": "12.463", "note": "Arriva domani"},
            {"title": "UGREEN cavo USB C 2 m", "url": "https://www.amazon.it/dp/B0UGREEN", "price": "8,49 €",
             "rating": 4.5, "reviews": 800, "note": None},
            {"title": "Belkin 2 m", "url": "https://www.amazon.it/dp/B0BELKIN", "price": None, "rating": None,
             "reviews": None, "note": None},
            {"title": "No link", "url": "/dp/B0X", "price": None, "rating": None, "reviews": None, "note": None}]})),
    ])
    e = runner.start("Compare USB-C cables", "USB-C cables", "amazon.it", CONVERSATION)
    e = await next_phase(runner)
    assert e["status"] == "done"
    anker, ugreen, belkin = e["products"]  # the one without a full link is left out
    assert anker["image"] == "https://m.media-amazon.com/anker.jpg"  # from its link on the results
    assert (anker["rating"], anker["reviews"]) == (4.6, 12463)
    assert ugreen["image"] == "https://m.media-amazon.com/ugreen.jpg"  # by its picture's alt text
    assert belkin["image"] == "https://img.test/B0BELKIN.jpg"  # no page showed it: its own page
    assert browser.product_pages == ["https://www.amazon.it/dp/B0BELKIN"]
    assert runner.store.as_json(e)["products"][0]["title"] == "Anker USB-C, 2 m"
    # The closing message: short text and the product cards; Aide's note lists them with their links.
    last = agent.visible_history(CONVERSATION)[-1]
    [cards] = last["attachments"]
    assert cards["type"] == "products" and cards["errand_id"] == e["id"] and cards["site"] == "amazon.it"
    assert [p["title"] for p in cards["products"]] == ["Anker USB-C, 2 m", "UGREEN cavo USB C 2 m", "Belkin 2 m"]
    note = json.loads(db.conn.execute("SELECT content FROM messages WHERE role = 'user' ORDER BY id DESC LIMIT 1")
                      .fetchone()[0])
    assert "1. Anker USB-C, 2 m, 9,99 €: https://www.amazon.it/dp/B0ANKER" in note


def test_picture_for_a_product():
    images = [{"path": "/Lodge-L8SK3/dp/B00006JSUA/ref=sr_1_1", "src": "https://a/lodge.jpg", "alt": "Lodge"},
              {"path": "other.site/dp/B00006JSUA", "src": "https://a/elsewhere.jpg", "alt": ""},
              {"path": None, "src": "https://a/victoria.jpg", "alt": "VICTORIA Padella in ghisa 30 cm stagionata"}]
    assert picture_for("https://www.amazon.it/dp/B00006JSUA", "Lodge", images) == "https://a/lodge.jpg"
    assert picture_for("https://www.amazon.it/dp/B01726HD72", "Victoria padella in ghisa 30 cm", images) == \
        "https://a/victoria.jpg"
    assert picture_for("https://www.amazon.it/dp/B0NOTHERE", "Something else entirely", images) is None
    assert picture_for("https://www.amazon.it/", "x", images) is None  # a bare site isn't a product


async def test_a_changed_total_isnt_clicked(env):
    make, db, browser = env
    runner, agent, _ = make([
        calls(("open_page", {"url": CHECKOUT})),
        calls(("ask_confirm", {"summary": "Order the cable", "ref": "4", "total": "12,98 €", "items": [ITEM],
                               "delivery": None, "address": None})),
        calls(("click", {"ref": "4"})),
        calls(("finish", {"result": "The price went up, so I didn't order.", "ok": False})),
    ])
    e = runner.start("Order the cable", "Cable", None, CONVERSATION)
    await next_phase(runner)
    await agent.confirm(CONVERSATION)
    title, _, els = browser.pages[CHECKOUT]
    browser.pages[CHECKOUT] = (title, "Totale ordine: 14,50 €", els)  # the price moved meanwhile
    e = await next_phase(runner)
    assert "Acquista ora" not in browser.clicked
    refused = runner.client.requests[3]["messages"][-1]["content"][0]
    assert refused["is_error"] and "isn't on the page any more" in refused["content"][0]["text"]
    assert e["status"] == "failed"
    assert runner.store.purchases() == []


async def test_a_made_up_total_cant_be_asked(env):
    make, db, browser = env
    runner, _, _ = make([
        calls(("open_page", {"url": CHECKOUT})),
        calls(("ask_confirm", {"summary": "Order", "ref": "4", "total": "9,99 €", "items": [ITEM],
                               "delivery": None, "address": None})),
        calls(("finish", {"result": "Couldn't.", "ok": False})),
    ])
    runner.start("Order the cable", "Cable", None, CONVERSATION)
    e = await next_phase(runner)
    assert db.pending_actions(CONVERSATION, runner_ttl()) == []
    assert e["status"] == "failed"


async def test_password_fields_and_sending_forms_are_left_to_the_user(env):
    make, _, browser = env
    runner, _, _ = make([
        calls(("open_page", {"url": CHECKOUT})),
        calls(("type_text", {"ref": "5", "text": "hunter2", "press_enter": None})),
        calls(("type_text", {"ref": "6", "text": "PROMO", "press_enter": True})),
        calls(("need_user", {"why": "login", "reason": "Log in to Amazon."})),
    ])
    runner.start("Order", "Cable", None, CONVERSATION)
    e = await next_phase(runner)
    results = [m["content"][0] for m in runner.client.requests[3]["messages"] if m["role"] == "user"
               and isinstance(m["content"], list)]
    assert "password or card field" in results[1]["content"][0]["text"]
    assert browser.typed == ["PROMO"]  # Applica isn't committing: Enter is fine there
    assert (e["status"], e["why"], e["reason"]) == ("needs_you", "login", "Log in to Amazon.")


async def test_the_user_takes_over_then_it_goes_on(env):
    make, db, browser = env
    runner, agent, _ = make([
        calls(("open_page", {"url": "https://www.amazon.it/login"})),
        calls(("need_user", {"why": "login", "reason": "Log in to Amazon."})),
        calls(("finish", {"result": "Found it: 9,99 €.", "ok": True})),
    ])
    e = runner.start("Price of the Anker cable", "Cable price", "amazon.it", CONVERSATION)
    e = await next_phase(runner)
    assert e["status"] == "needs_you"
    with pytest.raises(ValueError):
        runner.reply(e["id"], "")
    assert runner.store.as_json(e)["why"] == "login"
    assert [x["id"] for x in runner.waiting()] == [e["id"]]
    runner.done(e["id"])
    e = await next_phase(runner)
    prompt = prompt_of(runner.client.requests[2])
    assert "says they're done" in prompt and "Opened https://www.amazon.it/login" in prompt
    assert "Page: Accedi" in prompt  # the page as it is now
    assert e["status"] == "done"
    with pytest.raises(ValueError):
        runner.done(e["id"])


async def test_a_question_is_answered_through_aide(env):
    make, _, _ = env
    runner, agent, _ = make([
        calls(("ask_user", {"question": "2 m or 1 m?", "options": ["2 m", "1 m"]})),
        calls(("finish", {"result": "OK, the 2 m one.", "ok": True})),
    ])
    e = runner.start("A cable", "Cable", None, CONVERSATION)
    e = await next_phase(runner)
    assert (e["status"], e["why"], e["options"]) == ("needs_you", "question", ["2 m", "1 m"])
    reply = agent.registries["aide"].get("reply_errand")
    assert "going on" in await reply.handler(errand=e["id"], answer="2 m")
    e = await next_phase(runner)
    assert "The user answered: 2 m" in prompt_of(runner.client.requests[1])
    assert e["status"] == "done"


async def test_a_cancelled_confirm_cancels_the_errand(env):
    make, db, _ = env
    runner, agent, _ = make([
        calls(("open_page", {"url": CHECKOUT})),
        calls(("ask_confirm", {"summary": "Order", "ref": "4", "total": "12,98 €", "items": [ITEM],
                               "delivery": None, "address": None})),
    ])
    e = runner.start("Order", "Cable", None, CONVERSATION)
    await next_phase(runner)
    await agent.cancel(CONVERSATION)
    await runner._check()
    e = runner.store.get(e["id"])
    assert e["status"] == "cancelled" and runner.queue.empty()


async def test_a_restart_interrupts_running_errands(env):
    make, db, _ = env
    runner, agent, _ = make([calls(("finish", {"result": "Done after all.", "ok": True}))])
    e = runner.start("A cable", "Cable", None, CONVERSATION)
    runner.store.update(e["id"], status="running", url="https://www.amazon.it/s?k=cavo")
    runner.queue.get_nowait()
    stopped = runner.store.interrupt_running()
    assert [x["id"] for x in stopped] == [e["id"]]
    assert runner.store.get(e["id"])["status"] == "interrupted"
    runner.reply(e["id"], "go on")
    e = await next_phase(runner)
    prompt = prompt_of(runner.client.requests[0])
    assert "restarted" in prompt and "Page: Risultati" in prompt  # its last page opened again
    assert e["status"] == "done"


async def test_out_of_actions_stops(env, monkeypatch):
    import aide.errands as errands
    monkeypatch.setattr(errands, "MAX_ACTIONS", 2)
    make, _, _ = env
    runner, _, _ = make([
        calls(("open_page", {"url": CART})),
        calls(("click", {"ref": "3"})),
        calls(("click", {"ref": "6"})),
        calls(("finish", {"result": "Got to the checkout.", "ok": False})),
    ])
    runner.start("A cable", "Cable", None, CONVERSATION)
    e = await next_phase(runner)
    last = runner.client.requests[3]["messages"][-1]["content"][0]
    assert last["is_error"] and "Out of browser actions" in last["content"][0]["text"]
    assert e["actions"] == 2


async def test_only_aide_starts_errands_and_finance_reads_purchases(env):
    make, _, _ = env
    runner, agent, _ = make()
    assert {"start_errand", "errand_status", "reply_errand", "cancel_errand"} <= \
        {t.name for t in agent.registries["aide"]}
    assert "errand_go" not in {t.name for r in agent.registries.values() for t in r}  # Confirm's only
    assert agent.tools.get("errand_go").confirm
    assert "list_purchases" in {t.name for t in agent.registries["finance"]}
    assert not any(t.name == "start_errand" for a in ("secretary", "coach", "finance", "professor")
                   for t in agent.registries[a])
    aide = connectors(list(AGENTS["aide"].tools))
    assert {"id": "browser", "name": "Browser", "read_only": False,
            "tools": ["start_errand", "errand_status", "reply_errand", "cancel_errand"]} in aide
    assert {"id": "purchases", "name": "Purchases", "read_only": True, "tools": ["list_purchases"]} in \
        connectors(list(AGENTS["finance"].tools))


async def test_start_errand_shows_a_card(env):
    make, _, _ = env
    runner, agent, _ = make()
    out = await agent.registries["aide"].get("start_errand").handler(task="Find a cable", title="Cable", site=None)
    assert out.attachment["type"] == "errands" and out.attachment["errands"][0]["status"] == "queued"
    assert out.attachment["errands"][0]["conversation_id"] == CONVERSATION


# -- the API ---------------------------------------------------------------------


def api(make, browser=None):
    runner, agent, _ = make()
    client = TestClient(create_app(agent, ReminderStore(agent.db.conn), None, ROME, "t", errands=runner))
    return client, runner, agent


async def test_errands_api(env):
    make, db, browser = env
    client, runner, agent = api(make)
    e = runner.start("A cable", "Cable", "amazon.it", CONVERSATION)
    got = client.get("/v1/errands", headers=AUTH).json()
    assert got["enabled"] and got["errands"][0]["id"] == e["id"]
    assert set(got["errands"][0]) == {"id", "title", "task", "site", "url", "status", "why", "reason", "options",
                                      "step", "steps", "result", "action_id", "conversation_id", "purchase_id", "products",
                                      "created_at", "updated_at"}
    assert client.post(f"/v1/errands/{e['id']}/done", headers=AUTH).status_code == 409  # not waiting for you
    assert client.get(f"/v1/errands/{e['id']}/frame", headers=AUTH).status_code == 404  # no page yet
    await browser.open(f"errand:{e['id']}", CART)
    frame = client.get(f"/v1/errands/{e['id']}/frame", headers=AUTH)
    assert frame.headers["content-type"] == "image/jpeg"
    runner.store.update(e["id"], status="needs_you", why="login", reason="Log in.")
    approvals = client.get("/v1/approvals", headers=AUTH).json()
    assert approvals["waiting"] == 1 and approvals["errands"][0]["why"] == "login"
    assert client.post(f"/v1/errands/{e['id']}/done", headers=AUTH).json()["status"] == "queued"
    assert client.post(f"/v1/errands/{e['id']}/cancel", headers=AUTH).json()["status"] == "cancelled"
    assert client.get("/v1/errands/999", headers=AUTH).status_code == 404
    assert client.get("/v1/browser/sites", headers=AUTH).json()["sites"][0]["site"] == "amazon.it"
    assert client.delete("/v1/browser/sites/amazon.it", headers=AUTH).json() == {"ok": True}
    assert client.delete("/v1/browser/sites/not_a_site", headers=AUTH).status_code == 400
    assert client.get("/v1/purchases", headers=AUTH).json() == {"purchases": [], "totals": {}}
    assert client.get("/v1/errands").status_code == 401


async def test_approvals_carry_the_purchase_detail(env):
    make, db, _ = env
    client, runner, agent = api(make)
    runner.client.responses += [
        calls(("open_page", {"url": CHECKOUT})),
        calls(("ask_confirm", {"summary": "Order the cable", "ref": "4", "total": "12,98 €", "items": [ITEM],
                               "delivery": "Domani", "address": None})),
    ]
    runner.start("Order", "Cable", None, CONVERSATION)
    await next_phase(runner)
    [action] = client.get("/v1/approvals", headers=AUTH).json()["actions"]
    assert action["summary"] == "Order the cable (12,98 €)"
    assert action["detail"]["kind"] == "purchase" and action["detail"]["total"] == "12,98 €"
    assert agent.pending_with_ids(CONVERSATION)[0]["detail"]["items"] == [ITEM]


def test_without_a_browser_the_api_says_so(env):
    make, _, _ = env
    runner, agent, _ = make()
    client = TestClient(create_app(agent, ReminderStore(agent.db.conn), None, ROME, "t"))
    assert client.get("/v1/errands", headers=AUTH).json() == {"errands": [], "enabled": False}
    assert client.get("/v1/browser/sites", headers=AUTH).json() == {"sites": [], "enabled": False}
    assert client.post("/v1/errands/1/done", headers=AUTH).status_code == 404


async def test_the_live_view(env):
    make, db, browser = env
    client, runner, agent = api(make)
    e = runner.start("A cable", "Cable", "amazon.it", CONVERSATION)
    runner.queue.get_nowait()
    await browser.open(f"errand:{e['id']}", "https://www.amazon.it/login")
    with pytest.raises(Exception):
        with client.websocket_connect(f"/v1/browser/live?errand={e['id']}") as ws:  # no token
            ws.receive_json()
    runner.store.update(e["id"], status="running")
    with client.websocket_connect(f"/v1/browser/live?errand={e['id']}", headers=AUTH) as ws:
        first = [ws.receive_json() for _ in range(2)]
        assert first[0] == {"type": "frame", "data": "AAAA", "width": 824, "height": 1830}
        assert first[1]["type"] == "status" and first[1]["control"] is False
        ws.send_json({"type": "tap", "x": 0.5, "y": 0.5})  # Aide is working: ignored
        browser.pages["https://www.amazon.it/login"][2]["8"] = {"text": "Accedi"}
        await browser.click(f"errand:{e['id']}", "8")  # what Aide does shows up as it happens
        action = next(m for m in iter(ws.receive_json, None) if m["type"] == "action")
        assert action == {"type": "action", "seq": 1, "kind": "click", "x": 0.5, "y": 0.4, "label": "Accedi"}
        ws.send_json({"type": "done"})
    assert browser.taps == []
    runner.store.update(e["id"], status="needs_you", why="login", reason="Log in to Amazon.")
    with client.websocket_connect(f"/v1/browser/live?errand={e['id']}", headers=AUTH) as ws:
        seen = [ws.receive_json() for _ in range(3)]
        assert seen[1]["control"] is True and seen[1]["reason"] == "Log in to Amazon."
        assert seen[2] == {"type": "focus", "field": "password", "label": "Password"}
        ws.send_json({"type": "tap", "x": 0.4, "y": 0.6})
        ws.send_json({"type": "text", "text": "s3cret-pass"})
        ws.send_json({"type": "done"})
    assert browser.taps == [(0.4, 0.6)] and browser.live_typed == ["s3cret-pass"]
    assert runner.store.get(e["id"])["status"] == "queued"  # done: it goes on
    logged = json.dumps([list(r) for r in db.conn.execute("SELECT * FROM audit_log")])
    assert "s3cret" not in logged and "s3cret" not in json.dumps(runner.store.get(e["id"]))


LOGIN = {"kind": "login", "site": "amazon.it", "title": "Accedi", "url": "https://www.amazon.it/login", "icon": None,
         "query": None, "items": [], "product": None, "cart": None, "captcha": None,
         "form": {"fields": [{"ref": "7", "kind": "username", "label": "Email", "filled": False},
                             {"ref": "9", "kind": "password", "label": "Password", "filled": False}],
                  "submit": {"ref": "10", "text": "Accedi"}, "choices": [], "remember": "11", "remembered": False,
                  "error": None}}


async def test_the_live_view_draws_scenes_and_logs_in_through_the_app(env):
    make, db, browser = env
    client, runner, agent = api(make)
    e = runner.start("A cable", "Cable", "amazon.it", CONVERSATION)
    runner.queue.get_nowait()
    await browser.open(f"errand:{e['id']}", "https://www.amazon.it/login")
    browser.scenes["https://www.amazon.it/login"] = LOGIN
    runner.store.update(e["id"], status="running")
    with client.websocket_connect(f"/v1/browser/live?errand={e['id']}&frames=false", headers=AUTH) as ws:
        first = [ws.receive_json() for _ in range(2)]
        assert [m["type"] for m in first] == ["status", "scene"]  # no frames
        assert first[1] == {"type": "scene", **LOGIN}
        ws.send_json({"type": "fill", "ref": "7", "text": "me@example.it"})  # Aide is working: ignored
        ws.send_json({"type": "done"})
    assert browser.put_in == []
    runner.store.update(e["id"], status="needs_you", why="login", reason="Log in to Amazon.")
    with client.websocket_connect(f"/v1/browser/live?errand={e['id']}&frames=false", headers=AUTH) as ws:
        assert [ws.receive_json()["type"] for _ in range(2)] == ["status", "scene"]
        ws.send_json({"type": "fill", "ref": "7", "text": "me@example.it"})
        ws.send_json({"type": "fill", "ref": "9", "text": "s3cret-pass"})
        ws.send_json({"type": "fill", "ref": "3", "text": "elsewhere"})  # not in the scene: ignored
        ws.send_json({"type": "press", "ref": "4"})  # nor this
        ws.send_json({"type": "press", "ref": "10"})  # Accedi, "stay logged in" ticked first
        ws.send_json({"type": "frames", "on": True})  # "Show the real page"
        assert next(m for m in iter(ws.receive_json, None) if m["type"] == "frame")["data"] == "AAAA"
        # A CAPTCHA comes with its picture.
        browser.scenes["https://www.amazon.it/login"] = {**LOGIN, "kind": "captcha", "form": None, "captcha": {
            "kind": "text", "ref": "12", "input_ref": "13", "submit_ref": "14"}}
        crop = next(m for m in iter(ws.receive_json, None) if m["type"] == "crop")
        assert crop["box"] == {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.1} and crop["data"]
        ws.send_json({"type": "fill", "ref": "13", "text": "XKCD42"})
        ws.send_json({"type": "press", "ref": "14"})
        ws.send_json({"type": "fill", "ref": "9", "text": "late"})  # the login's field is gone from the scene
        ws.send_json({"type": "done"})
    assert browser.put_in == [("7", "me@example.it"), ("9", "s3cret-pass"), ("13", "XKCD42")]
    assert browser.pressed == [("10", "11"), ("14", None)]
    logged = json.dumps([list(r) for r in db.conn.execute("SELECT * FROM audit_log")])
    assert "s3cret" not in logged and "s3cret" not in json.dumps(runner.store.get(e["id"]))


async def test_each_step_carries_what_aide_says_its_doing(env):
    make, db, browser = env
    runner, agent, _ = make()
    e = runner.start("A USB-C cable", "USB-C cable", "amazon.it", CONVERSATION)
    runner.queue.get_nowait()
    runner.store.update(e["id"], status="running")
    phase = Phase(runner, runner.store.get(e["id"]))
    tools = {t.name: t for t in phase.tools()}
    await tools["open_page"].handler(url="https://www.amazon.it/s?k=cavo", doing="Cerco un cavo USB-C")
    assert runner.store.get(e["id"])["step"] == "Cerco un cavo USB-C"
    await tools["read_page"].handler(doing="Guardo   i risultati")
    await tools["click"].handler(ref="2")
    e = runner.store.get(e["id"])
    assert browser.notes == ["Cerco un cavo USB-C", "Guardo i risultati"]
    assert e["step"].startswith("Clicked [2]")  # no line of its own: the plain one
    assert [s.get("doing") for s in e["steps"]][-3:] == ["Cerco un cavo USB-C", "Guardo i risultati", None]
    assert e["steps"][-2]["text"] == "Read the page"  # the model's log keeps the plain lines
    assert e["actions"] == 2  # reading doesn't count


def test_site_names():
    assert site_of("https://www.amazon.it/s?k=x") == "amazon.it"
    assert site_of("amazon.co.uk") == "amazon.co.uk"
    assert site_of("https://m.trenitalia.com") == "trenitalia.com"
    with pytest.raises(ValueError):
        site_of("http://127.0.0.1:8000")


# -- the real browser ------------------------------------------------------------

SHOP = """<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<meta property="og:image" content="https://shop.test/og.jpg">
<title>Shop</title></head><body>
<h1>Cavo USB-C</h1><p>Prezzo: 9,99 €</p>
<form action="/order"><label>Email <input name="email" type="email" value="a@b.it"></label>
<label>Password <input name="pw" type="password" value="hunter2"></label>
<img src="https://shop.test/pic.jpg" width="100" height="100" alt="Cavo USB-C"><a href="/dp/B0TEST?ref=x">Scheda</a>
<button type="button" onclick="document.title='added'">Aggiungi al carrello</button>
<button type="submit">Acquista ora</button></form>
<div style="height:3000px"></div><p>In fondo</p></body></html>"""


@pytest.mark.skipif(not Browser.available(), reason="Playwright's Chromium isn't installed")
async def test_real_chromium_reads_and_clicks(tmp_path):
    browser = Browser(tmp_path / "browser")
    try:
        context = await browser._context("shop.test")
        picture = '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="80"><rect width="80" height="80"/></svg>'
        await context.route("**/*", lambda route: route.fulfill(body=picture, content_type="image/svg+xml")
                            if route.request.url.endswith(".jpg") else route.fulfill(body=SHOP, content_type="text/html"))
        assert "Shop" in await browser.open("errand:1", "https://shop.test/")
        page = await browser.read("errand:1")
        assert "Prezzo: 9,99 €" in page and "In fondo" not in page and "(more below" in page
        assert '"Scheda" → /dp/B0TEST' in page
        pictures = await browser.images("errand:1")
        assert {"path": "/dp/B0TEST", "src": "https://shop.test/pic.jpg", "alt": "Cavo USB-C"} in pictures
        assert await browser.main_image("errand:2", "https://shop.test/dp/B0TEST") == "https://shop.test/og.jpg"
        assert "hunter2" not in page and "(filled, hidden)" in page and 'value="a@b.it"' in page
        ref = next(line.split("]")[0][1:] for line in page.splitlines() if line.startswith("[") and "Aggiungi" in line)
        buy = next(line.split("]")[0][1:] for line in page.splitlines() if line.startswith("[") and "Acquista" in line)
        pw = next(line.split("]")[0][1:] for line in page.splitlines() if line.startswith("[") and "Password" in line)
        assert (await browser.inspect("errand:1", buy))["text"] == "Acquista ora"
        assert (await browser.inspect("errand:1", pw))["sensitive"]
        await browser.click("errand:1", ref)
        assert await browser._page("errand:1").title() == "added"
        act = browser.last_action("errand:1")
        assert act["kind"] == "click" and act["label"] == "Aggiungi al carrello" and 0 < act["x"] < 1 and 0 < act["y"] < 1
        await browser.fill("errand:1", pw, "hunter3")
        assert browser.last_action("errand:1")["label"] is None  # never a password
        assert "In fondo" in await browser.read("errand:1", everything=True)
        shot = await browser.screenshot("errand:1")
        assert shot[:2] == b"\xff\xd8"
        frames = []
        stop = await browser.screencast("errand:1", lambda data, w, h: frames.append((w, h)))
        await asyncio.sleep(0.5)
        await stop()
        assert frames and frames[0] == (824, 1830)
        assert [s["site"] for s in browser.sites()] == ["shop.test"]
    finally:
        await browser.stop()


def _html(body: str, title: str = "Shop", head: str = "") -> str:
    return (f'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            f"<title>{title}</title>{head}</head><body>{body}</body></html>")


SCENE_PAGES = {
    "/s": _html("".join(f'<div class="card"><a href="/p/lamp{i}"><img src="/lamp{i}.jpg" width="160" height="160" '
                        f'alt=""></a><h3><a href="/p/lamp{i}">Lampada da tavolo FADO {i}, bianco</a></h3>'
                        f"<span>€{i}9,95</span></div>" for i in range(1, 5)), "Cerca lampada"),
    "/dp/B0LODGE": _html('<h1>Lodge L8SK3 Tegame tondo</h1><img src="/lodge.jpg" width="300" height="300">'
                         "<button>Aggiungi al carrello</button>", "Lodge L8SK3 Tegame tondo : Shop",
                         '<script type="application/ld+json">{"@context": "https://schema.org", "@type": "Product", '
                         '"name": "Lodge L8SK3", "image": "https://shop.test/lodge.jpg", "offers": {"price": "49.15", '
                         '"priceCurrency": "EUR"}, "aggregateRating": {"ratingValue": "4.7"}}</script>'),
    "/ap/signin": _html('<form action="/ap/password"><label>Indirizzo e-mail <input type="email" name="email"></label>'
                        '<button type="submit">Continua</button></form>', "Accedi"),
    "/ap/password": _html('<form onsubmit="document.title = this.rememberMe.checked ? \'remembered\' : \'forgot\'; '
                          'return false"><div role="alert">Password errata</div>'
                          '<label>Password <input type="password" name="password" value="hunter2"></label>'
                          '<label><input type="checkbox" name="rememberMe"> Resta connesso</label>'
                          '<input type="submit" value="Accedi"></form>', "Accedi"),
    "/ap/otp": _html('<p>Inserisci il codice che ti abbiamo inviato</p><form><input name="otp" '
                     'autocomplete="one-time-code" maxlength="6"><button type="submit">Invia codice</button></form>',
                     "Verifica"),
    "/captcha": _html('<form><p>Inserisci i caratteri che vedi</p><img src="/captcha.jpg" alt="captcha" width="200" '
                      'height="70"><input type="text" name="captchacharacters"><button type="submit">Continua'
                      "</button></form>", "Amazon.it"),
}


@pytest.mark.skipif(not Browser.available(), reason="Playwright's Chromium isn't installed")
async def test_real_chromium_scenes(tmp_path):
    from urllib.parse import urlparse
    browser = Browser(tmp_path / "browser")
    picture = '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="200"><rect width="200" height="200"/></svg>'

    async def serve(route):
        path = urlparse(route.request.url).path
        if path.endswith(".jpg"):
            await route.fulfill(body=picture, content_type="image/svg+xml")
        else:
            await route.fulfill(body=SCENE_PAGES.get(path, _html("<p>Nothing</p>")), content_type="text/html")
    try:
        await (await browser._context("shop.test")).route("**/*", serve)
        owner = "errand:1"

        await browser.open(owner, "https://shop.test/s?k=lampada")
        scene = await browser.scene(owner)
        assert scene["kind"] == "results" and scene["query"] == "lampada" and scene["site"] == "shop.test"
        assert [(i["title"], i["price"]) for i in scene["items"][:2]] == \
            [("Lampada da tavolo FADO 1, bianco", "€19,95"), ("Lampada da tavolo FADO 2, bianco", "€29,95")]
        assert scene["items"][0]["image"] == "https://shop.test/lamp1.jpg"
        await browser.click(owner, scene["items"][0]["ref"])  # the scene's refs are the model's
        assert browser.where(owner)["url"] == "https://shop.test/p/lamp1"

        await browser.open(owner, "https://shop.test/dp/B0LODGE")
        scene = await browser.scene(owner)
        assert scene["kind"] == "product"
        assert scene["product"] == {"title": "Lodge L8SK3", "price": "49.15 EUR",
                                    "image": "https://shop.test/lodge.jpg", "rating": 4.7}

        await browser.open(owner, "https://shop.test/ap/signin")
        scene = await browser.scene(owner)
        assert scene["kind"] == "login" and [f["kind"] for f in scene["form"]["fields"]] == ["username"]
        assert scene["form"]["submit"]["text"] == "Continua"
        await browser.put(owner, scene["form"]["fields"][0]["ref"], "me@example.it")
        await browser.press_ref(owner, scene["form"]["submit"]["ref"])
        assert browser.where(owner)["url"].startswith("https://shop.test/ap/password")
        assert browser.last_action(owner)["kind"] == "open"  # the user's typing isn't recorded as Aide's

        scene = await browser.scene(owner)
        form = scene["form"]
        assert scene["kind"] == "login" and form["fields"][0]["kind"] == "password" and form["fields"][0]["filled"]
        assert "hunter2" not in json.dumps(scene)
        assert form["remember"] and form["remembered"] is False and form["error"] == "Password errata"
        await browser.press_ref(owner, form["submit"]["ref"], tick=form["remember"])
        assert await browser._page(owner).title() == "remembered"

        await browser.open(owner, "https://shop.test/ap/otp")
        scene = await browser.scene(owner)
        assert scene["kind"] == "code" and scene["form"]["fields"][0]["kind"] == "code"

        await browser.open(owner, "https://shop.test/captcha")
        scene = await browser.scene(owner)
        assert scene["kind"] == "captcha" and scene["captcha"]["kind"] == "text"
        assert scene["captcha"]["input_ref"] and scene["captcha"]["submit_ref"]
        shot, box = await browser.crop(owner, scene["captcha"]["ref"])
        assert shot[:2] == b"\xff\xd8" and 0 < box["width"] < 1 and 0 <= box["y"] < 1
    finally:
        await browser.stop()
