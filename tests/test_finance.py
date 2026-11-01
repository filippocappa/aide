import asyncio
import json
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.agents import AGENTS, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.finance import FinanceStore, normalise, parse_amount
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.finance import finance_tools
from test_api import AUTH, TOKEN, FakeCalendar
from test_food import ROME, RecordingClient


class Model:
    def __init__(self, answer: dict | str):
        self.answer = answer
        self.calls: list[str] = []

    async def __call__(self, system: str, text: str) -> str:
        self.calls.append(text)
        return self.answer if isinstance(self.answer, str) else json.dumps(self.answer)


@pytest.fixture
def store():
    db = Database(":memory:")
    yield FinanceStore(db.conn, ROME)
    db.close()


def at(d: date, hour: int = 12) -> datetime:
    return datetime(d.year, d.month, d.day, hour, tzinfo=ROME)


def test_amounts_as_wallet_and_people_write_them():
    assert parse_amount("€4.50") == 4.5
    assert parse_amount("4,50 €") == 4.5
    assert parse_amount("1.234,56 €") == 1234.56
    assert parse_amount("$1,234.56") == 1234.56
    assert parse_amount("EUR 12") == 12
    assert parse_amount("1,000") == 1000
    assert parse_amount("-3.20") == -3.2
    with pytest.raises(ValueError):
        parse_amount("free")


def test_merchants_normalise_without_store_numbers_or_company_suffixes():
    assert normalise("ESSELUNGA S.P.A. 123") == "esselunga"
    assert normalise("Bar Roma s.r.l.") == "bar roma"
    assert normalise("Spotify AB") == "spotify ab"


def test_a_tap_told_twice_is_one_payment_and_the_card_is_made_once(store):
    now = datetime.now(timezone.utc) - timedelta(minutes=5)
    a, new_a = store.add(-4.5, "Bar Roma", account="Revolut", at=now)
    b, new_b = store.add(-4.5, "Bar Roma", account="Revolut", at=now + timedelta(minutes=1))
    assert new_a and not new_b and a["id"] == b["id"]
    store.add(-4.5, "Bar Roma", account="revolut", at=now + timedelta(minutes=10))
    assert [x["name"] for x in store.accounts()] == ["Revolut"]
    assert store.accounts()[0]["count"] == 2


def test_new_merchants_are_sorted_in_one_call_and_then_by_their_rule(store):
    model = Model({"Esselunga": "groceries", "Bar Roma": "eating_out", "Weird Ltd": "income"})
    store.ask = model
    for m in ("Esselunga", "Bar Roma", "Weird Ltd"):
        store.add(-10, m)
    assert asyncio.run(store.sort_pending()) == 2
    assert len(model.calls) == 1 and model.calls[0].splitlines() == ["Bar Roma", "Esselunga", "Weird Ltd"]
    cats = {t["merchant"]: (t["category"], t["sorted_by"]) for t in store.recent()}
    assert cats["Esselunga"] == ("groceries", "model")
    assert cats["Weird Ltd"] == ("other", "none")  # the model can't call a payment income
    tx, _ = store.add(-22, "ESSELUNGA via Nizza 12")  # the rule's merchant at another shop
    assert (tx["category"], tx["sorted_by"]) == ("groceries", "rule")
    assert asyncio.run(store.sort_pending()) == 0 or len(model.calls) == 2


def test_a_correction_becomes_the_merchants_rule_and_moves_its_other_payments(store):
    store.ask = Model({"Glovo": "shopping"})
    a, _ = store.add(-12, "Glovo")
    b, _ = store.add(-15, "Glovo", at=datetime.now(timezone.utc) - timedelta(days=1))
    asyncio.run(store.sort_pending())
    store.update(a["id"], category="eating_out")
    assert store.find(b["id"])["category"] == "eating_out"
    c, _ = store.add(-9, "Glovo", at=datetime.now(timezone.utc) - timedelta(days=2))
    assert c["category"] == "eating_out"
    store._save_rule("Glovo", "shopping", "model")  # the model never overrides the user
    assert store.rule("Glovo")["category"] == "eating_out"
    store.update(c["id"], category="fun", remember=False)
    assert store.find(a["id"])["category"] == "eating_out"


def test_the_month_without_a_budget_is_against_last_month_by_the_same_day(store):
    today = date(2026, 10, 10)
    store.add(-30, "Esselunga", at=at(date(2026, 9, 3)), category="groceries")
    store.add(-50, "Trenitalia", at=at(date(2026, 9, 20)), category="travel")
    store.add(-40, "Esselunga", at=at(date(2026, 10, 2)), category="groceries")
    store.add(-12, "Bar Roma", at=at(date(2026, 10, 9)), category="eating_out")
    store.add(5, "Esselunga", at=at(date(2026, 10, 9)), category="groceries")  # a refund
    store.add(300, "Mum", at=at(date(2026, 10, 1)), category="income")
    store.add(-100, "Revolut top-up", at=at(date(2026, 10, 1)), category="transfer")
    m = store.month(today=today)
    assert (m["spent"], m["income"], m["budget"], m["left"]) == (47, 300, None, None)
    assert m["last_month"] == {"month": "2026-09", "by_now": 30, "total": 80}
    groceries = next(c for c in m["categories"] if c["id"] == "groceries")
    assert (groceries["spent"], groceries["last_by_now"], groceries["last_total"]) == (35, 30, 30)
    assert "€47 so far this month, €17 more than last month by now" in m["line"]
    assert [c["id"] for c in m["categories"]][:3] == ["groceries", "eating_out", "travel"]


def test_with_a_budget_the_month_says_whats_left_a_day_and_whats_ahead(store):
    today = date(2026, 10, 10)
    store.set_budget(600, {"eating_out": 60})
    store.add(-50, "Sushi", at=at(date(2026, 10, 5)), category="eating_out")
    store.add(-150, "Rent share", at=at(date(2026, 10, 1)), category="bills")
    m = store.month(today=today)
    assert (m["spent"], m["left"], m["days_left"], m["per_day"]) == (200, 400, 22, 18.18)
    eat = next(c for c in m["categories"] if c["id"] == "eating_out")
    assert eat["pace"] == 19.35 and eat["ahead"] and not eat["over"]
    assert m["line"].startswith("€400 left for 22 days, about €18.18 a day.")
    assert "Eating out is ahead" in m["line"]
    store.add(-500, "Laptop", at=at(date(2026, 10, 9)), category="shopping")
    assert store.month(today=today)["line"].startswith("€100 over the budget")
    store.set_budget(None, {"eating_out": None})
    assert store.budget() == {"monthly": None, "categories": {}}
    with pytest.raises(ValueError):
        store.set_budget(categories={"income": 10})


def test_a_past_month_is_whole(store):
    store.add(-30, "Esselunga", at=at(date(2026, 8, 28)), category="groceries")
    m = store.month("2026-08", today=date(2026, 10, 10))
    assert not m["current"] and m["day"] == 31 and m["days_left"] == 0 and m["spent"] == 30
    assert m["line"] == "€30 spent in August."
    with pytest.raises(ValueError):
        store.month("2026-11", today=date(2026, 10, 10))


def test_subscriptions_are_charges_that_repeat_at_about_the_same_price(store):
    today = date(2026, 10, 10)
    for d in (date(2026, 7, 3), date(2026, 8, 3), date(2026, 9, 3)):
        store.add(-10.99, "Spotify", at=at(d), category="subscriptions")
    store.add(-11.99, "Spotify", at=at(date(2026, 10, 3)), category="subscriptions")
    store.add(-79.99, "iCloud yearly", at=at(date(2025, 10, 20)))
    store.add(-79.99, "iCloud yearly", at=at(date(2026, 10, 8)))
    store.add(-4.99, "Gym trial", at=at(date(2026, 10, 5)), category="subscriptions")  # one, sorted as one
    store.add(-3, "Bar Roma", at=at(date(2026, 10, 1)))
    store.add(-7, "Bar Roma", at=at(date(2026, 10, 8)))  # weekly-ish but not the same price
    store.add(-9.99, "Netflix", at=at(date(2026, 5, 1)), category="subscriptions")
    store.add(-9.99, "Netflix", at=at(date(2026, 6, 1)), category="subscriptions")  # stopped
    s = store.subscriptions(today=today)
    names = [x["merchant"] for x in s["subscriptions"]]
    assert names == ["Spotify", "Gym trial", "iCloud yearly"]
    spotify = s["subscriptions"][0]
    assert (spotify["amount"], spotify["period"], spotify["next"], spotify["price_was"]) == (11.99, "month",
                                                                                              "2026-11-03", 10.99)
    assert s["subscriptions"][2]["period"] == "year" and s["subscriptions"][2]["monthly"] == 6.67
    assert s["monthly_total"] == round(11.99 + 4.99 + 79.99 / 12, 2)


def test_payments_cant_be_empty_zero_or_in_the_future(store):
    with pytest.raises(ValueError):
        store.add(0, "Bar")
    with pytest.raises(ValueError):
        store.add(-3, "  ")
    with pytest.raises(ValueError):
        store.add(-3, "Bar", at=datetime.now(timezone.utc) + timedelta(days=1))
    with pytest.raises(ValueError):
        store.add(-3, "Bar", category="snacks")


def test_finances_tools_log_list_and_recategorize_with_cards(store):
    store.ask = Model({"Pizzeria Da Mario": "eating_out"})
    tools = ToolRegistry(finance_tools(store))
    out = asyncio.run(tools.call("log_payment", {"amount": 8, "merchant": "Pizzeria Da Mario"}))
    assert "eating out" in out and out.attachment["type"] == "payments"
    tx = out.attachment["payments"][0]
    assert tx["amount"] == -8 and tx["source"] == "manual"
    listed = asyncio.run(tools.call("list_payments", {"days": 7}))
    assert f"[payment {tx['id']}]" in listed and "€8 spent" in listed
    moved = asyncio.run(tools.call("recategorize", {"payment_id": tx["id"], "category": "fun"}))
    assert moved.attachment["payments"][0]["category"] == "fun"
    assert "No monthly budget" in asyncio.run(tools.call("set_budget", {"monthly": 0}))
    assert "€500" in asyncio.run(tools.call("set_budget", {"monthly": 500,
                                                           "categories": [{"category": "fun", "amount": 40}]}))
    assert "Budget €500" in asyncio.run(tools.call("spending", {}))
    assert tools.get("delete_payment").confirm


def test_finance_has_its_tools_and_the_payments_connector():
    assert {"log_payment", "list_payments", "spending", "subscriptions"} <= set(AGENTS["finance"].tools)
    payments = next(c for c in connectors(list(AGENTS["finance"].tools)) if c["id"] == "payments")
    assert not payments["read_only"]


@pytest.fixture
def api():
    db = Database(":memory:")
    finance = FinanceStore(db.conn, ROME, Model({"Esselunga": "groceries"}))
    agent = Agent(RecordingClient(()), db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME, delegate=False)
    app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, finance=finance)
    with TestClient(app) as c:
        yield c, finance
    db.close()


def test_the_api_takes_a_wallet_tap_and_sorts_it_in_the_background(api):
    c, finance = api
    r = c.post("/v1/finance/payments", headers=AUTH, json={"amount": "€23,40", "merchant": "Esselunga",
                                                           "card": "Revolut"})
    assert r.status_code == 200 and r.json()["new"]
    tx = r.json()["payment"]
    assert tx["amount"] == -23.4 and tx["account"] == "Revolut" and tx["source"] == "wallet"
    again = c.post("/v1/finance/payments", headers=AUTH, json={"amount": 23.4, "merchant": "Esselunga",
                                                               "card": "Revolut"}).json()
    assert not again["new"]
    got = c.get(f"/v1/finance/payments/{tx['id']}", headers=AUTH).json()
    assert got["payment"]["category"] == "groceries" and got["merchant"]["count"] == 0
    assert c.post("/v1/finance/payments", headers=AUTH, json={"amount": "nothing", "merchant": "X"}).status_code == 400
    assert c.post("/v1/finance/payments", headers=AUTH,
                  json={"amount": 5, "merchant": "X", "at": "2026-11-01T10:00"}).status_code == 400


def test_the_api_lists_patches_and_deletes_payments(api):
    c, finance = api
    ids = [c.post("/v1/finance/payments", headers=AUTH,
                  json={"amount": n, "merchant": f"Shop {n}", "category": "shopping",
                        "at": (datetime.now(timezone.utc) - timedelta(hours=n)).isoformat()}).json()["payment"]["id"]
           for n in (1, 2, 3)]
    page = c.get("/v1/finance/payments?limit=2", headers=AUTH).json()
    assert [p["id"] for p in page["payments"]] == ids[:2] and page["more"]
    rest = c.get("/v1/finance/payments", headers=AUTH, params={"before": page["payments"][-1]["at"]}).json()
    assert [p["id"] for p in rest["payments"]] == ids[2:] and not rest["more"]
    r = c.patch(f"/v1/finance/payments/{ids[0]}", headers=AUTH, json={"category": "fun", "note": "gift"})
    assert r.json()["payment"]["category"] == "fun" and r.json()["payment"]["note"] == "gift"
    assert c.patch(f"/v1/finance/payments/{ids[0]}", headers=AUTH, json={"category": "nope"}).status_code == 400
    assert c.delete(f"/v1/finance/payments/{ids[0]}", headers=AUTH).json() == {"ok": True}
    assert c.get(f"/v1/finance/payments/{ids[0]}", headers=AUTH).status_code == 404


def test_the_api_gives_the_month_accounts_budget_and_subscriptions(api):
    c, finance = api
    c.post("/v1/finance/payments", headers=AUTH, json={"amount": 9.99, "merchant": "Spotify", "card": "Hype",
                                                       "category": "subscriptions"})
    m = c.get("/v1/finance/month", headers=AUTH).json()
    assert m["spent"] == 9.99 and m["budget"] is None and m["line"]
    assert c.get("/v1/finance/month?month=2026-13", headers=AUTH).status_code in (400, 422)
    assert c.put("/v1/finance/budget", headers=AUTH, json={"monthly": 400, "categories": {"fun": 50}}).json() == \
        {"monthly": 400, "categories": {"fun": 50}}
    assert c.put("/v1/finance/budget", headers=AUTH, json={"categories": {"fun": None}}).json() == \
        {"monthly": 400, "categories": {}}
    assert c.put("/v1/finance/budget", headers=AUTH, json={"monthly": None}).json()["monthly"] is None
    assert c.put("/v1/finance/budget", headers=AUTH, json={"monthly": -1}).status_code == 400
    assert c.get("/v1/finance/accounts", headers=AUTH).json()["accounts"][0]["name"] == "Hype"
    assert c.get("/v1/finance/subscriptions", headers=AUTH).json()["subscriptions"][0]["merchant"] == "Spotify"
    cats = c.get("/v1/finance/categories", headers=AUTH).json()["categories"]
    assert {"id": "income", "name": "Income", "spending": False} in cats


def test_the_users_word_on_subscriptions_wins(store):
    today = date(2026, 11, 1)
    for d in (date(2026, 9, 5), date(2026, 10, 5)):
        store.add(-5, "Klarna* Cisalfa Sport", at=at(d), category="health")
        store.add(-100, "Pagamento Revolut * Dublin", at=at(d), category="transfer")  # own money: never one
    store.add(-17.06, "Openrouter, Inc", at=at(date(2026, 9, 24)), category="subscriptions")
    s = store.subscriptions(today=today)
    assert [x["merchant"] for x in s["subscriptions"]] == ["Openrouter, Inc", "Klarna* Cisalfa Sport"]
    assert not any(x["mine"] for x in s["subscriptions"])

    store.set_subscription("Klarna* Cisalfa Sport", False)
    store.set_subscription("Openrouter, Inc", True, amount=20, period="month", next_charge=date(2026, 10, 24))
    with pytest.raises(ValueError):  # nothing on record: it needs the price, the period and the next charge
        store.set_subscription("Netflix", True, amount=13.99)
    store.set_subscription("Netflix", True, amount=13.99, period="month", next_charge=date(2026, 11, 12))
    store.set_subscription("iCloud+", True, amount=36, period="year", next_charge=date(2026, 3, 2))
    s = store.subscriptions(today=today)
    by = {x["merchant"]: x for x in s["subscriptions"]}
    assert list(by) == ["Netflix", "Openrouter, Inc", "iCloud+"]
    assert by["Openrouter, Inc"]["amount"] == 20 and by["Openrouter, Inc"]["next"] == "2026-11-24"  # moved on
    assert by["Netflix"]["last"] is None and by["Netflix"]["mine"]
    assert by["iCloud+"]["next"] == "2027-03-02" and by["iCloud+"]["monthly"] == 3
    assert s["hidden"] == [{"merchant": "Klarna* Cisalfa Sport", "key": "klarna cisalfa sport"}]
    assert s["monthly_total"] == round(20 + 13.99 + 3, 2)

    store.set_subscription("Klarna* Cisalfa Sport", None)  # forgotten: back to what the charges show
    assert "Klarna* Cisalfa Sport" in [x["merchant"] for x in store.subscriptions(today=today)["subscriptions"]]
    assert store.subscriptions(today=today)["hidden"] == []
