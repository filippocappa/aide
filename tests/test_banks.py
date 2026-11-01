import asyncio
from datetime import date, datetime, timedelta, timezone
from urllib.parse import parse_qs, urlparse

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.banks import Banks, BankError, EnableBanking, clean_merchant, parse_tx, pick_balance
from aide.channels.api import create_app
from aide.db import Database
from aide.finance import FinanceStore
from aide.reminders import ReminderStore
from aide.tools import ToolRegistry
from aide.tools.finance import finance_tools
from test_api import AUTH, FakeCalendar, TOKEN
from test_food import ROME, RecordingClient


def tx(amount: float, day: date, name: str = "", text: str = "", status: str = "BOOK", ident: str | None = None,
       iban: str | None = None, mcc: str | None = None) -> dict:
    out = amount < 0
    party = {"name": name} if name else None
    return {"transaction_id": ident, "transaction_amount": {"amount": f"{abs(amount):.2f}", "currency": "EUR"},
            "credit_debit_indicator": "DBIT" if out else "CRDT", "status": status, "booking_date": day.isoformat(),
            "creditor": party if out else None, "debtor": None if out else party,
            ("creditor_account" if out else "debtor_account"): {"iban": iban} if iban else None,
            "remittance_information": [text] if text else [], "merchant_category_code": mcc}


class FakeBank:
    """Enable Banking as Aide uses it: one bank, accounts by uid, their balances and transactions."""

    def __init__(self):
        self.accounts = {"u1": {"uid": "u1", "account_id": {"iban": "IT60X0542811101000000123456"}, "product": "Conto",
                                "name": "Filippo Cappa", "currency": "EUR", "cash_account_type": "CACC",
                                "identification_hash": "h1"}}
        self.bal = {"u1": [{"balance_type": "CLBD", "balance_amount": {"amount": "1200.00", "currency": "EUR"}},
                                {"balance_type": "ITAV", "balance_amount": {"amount": "1180.50", "currency": "EUR"}}]}
        self.txs: dict[str, list[dict]] = {"u1": []}
        self.starts: list[dict] = []
        self.closed: list[str] = []
        self.reads: list[tuple[str, date, dict | None]] = []
        self.fail: BankError | None = None
        self.sessions = 0

    async def banks(self, country):
        return [{"name": "Intesa Sanpaolo", "country": "IT", "logo": "https://x/intesa.png",
                 "maximum_consent_validity": 180 * 86400},
                {"name": "Fineco", "country": "IT", "maximum_consent_validity": 90 * 86400, "beta": True}]

    async def start(self, bank, country, redirect, state, valid_until):
        self.starts.append({"bank": bank, "redirect": redirect, "state": state, "valid_until": valid_until})
        return f"https://bank.example/login?state={state}"

    async def session(self, code):
        self.sessions += 1
        return {"session_id": f"s{self.sessions}", "accounts": list(self.accounts.values()),
                "access": {"valid_until": (datetime.now(timezone.utc) + timedelta(days=180)).isoformat()}}

    async def close(self, session_id):
        self.closed.append(session_id)

    async def details(self, uid):
        return self.accounts[uid]

    async def balances(self, uid, psu=None):
        if self.fail:
            raise self.fail
        return self.bal.get(uid, [])

    async def transactions(self, uid, date_from, psu=None):
        if self.fail:
            raise self.fail
        self.reads.append((uid, date_from, psu))
        return [t for t in self.txs.get(uid, []) if date.fromisoformat(t["booking_date"]) >= date_from]


@pytest.fixture
def setup():
    db = Database(":memory:")
    finance = FinanceStore(db.conn, ROME)
    fake = FakeBank()
    pushes: list[tuple] = []

    async def notify(title, body, extra):
        pushes.append((title, body, extra))
    banks = Banks(finance, fake, notify)
    yield finance, banks, fake, pushes
    db.close()


def link(banks: Banks, fake: FakeBank) -> dict:
    asyncio.run(banks.start_link("Intesa Sanpaolo", "IT", "https://cappa.ts.net/v1/finance/banks/callback"))
    return asyncio.run(banks.finish_link(fake.starts[-1]["state"], "code"))


def today(finance) -> date:
    return finance.today()


def test_merchants_come_out_of_italian_bank_text():
    assert clean_merchant("PAGAMENTO POS 12,50 EUR DEL 30.10.2026 ORE 12:31 ESSELUNGA TORINO CARTA N.****1234") \
        == "Esselunga Torino"
    assert clean_merchant("Pagamento Apple Pay Bar Roma") == "Bar Roma"
    assert clean_merchant("SPOTIFY AB") == "Spotify Ab"
    assert clean_merchant("") == "Bank"


def test_balance_prefers_available_on_an_account_and_booked_on_a_card():
    b = FakeBank().bal["u1"]
    assert pick_balance(b) == (1180.5, "EUR")
    assert pick_balance(b, card=True) == (1200.0, "EUR")
    assert pick_balance([]) is None


def test_parse_skips_cancelled_and_signs_debits():
    seen: dict = {}
    d = date(2026, 10, 30)
    assert parse_tx(tx(-5, d, status="CNCL"), "u1", seen) is None
    p = parse_tx(tx(-5, d, name="Bar Roma"), "u1", seen)
    assert p["amount"] == -5 and p["merchant"] == "Bar Roma" and not p["pending"]
    q = parse_tx(tx(-5, d, name="Bar Roma"), "u1", seen)
    assert p["ref"] != q["ref"]  # two coffees on the same day without ids are two
    assert parse_tx(tx(50, d, name="Mamma"), "u1", seen)["amount"] == 50
    assert parse_tx(tx(-50, d, text="PRELIEVO ATM"), "u1", seen)["cash"]


def test_link_keeps_the_accounts_and_reads_balances_and_90_days(setup):
    finance, banks, fake, _ = setup
    d = today(finance)
    fake.txs["u1"] = [tx(-12.5, d - timedelta(days=2), text="PAGAMENTO POS ESSELUNGA TORINO", ident="t1"),
                      tx(800, d - timedelta(days=20), name="Universita di Torino", ident="t2"),
                      tx(-40, d - timedelta(days=200), name="Too old", ident="t3")]
    linked = link(banks, fake)
    assert linked["bank"] == "Intesa Sanpaolo" and linked["status"] == "linked" and linked["days_left"] >= 179
    assert fake.starts[0]["valid_until"] > datetime.now(timezone.utc) + timedelta(days=179)
    acc = finance.accounts()[0]
    assert acc["name"] == "Intesa Sanpaolo Conto ··3456" and acc["kind"] == "account"
    assert acc["balance"] == 1180.5 and acc["status"] == "bank" and acc["bank_id"] == linked["id"]
    assert fake.reads[0][1] == d - timedelta(days=90)
    rows = finance.recent()
    assert [(r["merchant"], r["amount"], r["category"]) for r in rows] == [
        ("Esselunga Torino", -12.5, "other"), ("Universita di Torino", 800, "income")]
    assert all(r["source"] == "bank" and r["bank"] for r in rows)


def test_a_used_or_old_link_state_is_refused(setup):
    finance, banks, fake, _ = setup
    link(banks, fake)
    with pytest.raises(ValueError):
        asyncio.run(banks.finish_link(fake.starts[0]["state"], "code"))
    with pytest.raises(ValueError):
        asyncio.run(banks.start_link("No Such Bank", "IT", "https://x"))


def test_the_bank_record_of_a_tap_is_the_tap(setup):
    finance, banks, fake, _ = setup
    d = today(finance)
    tap_at = datetime.combine(d - timedelta(days=3), datetime.min.time(), ROME).replace(hour=8, minute=12)
    tap, _ = finance.add(-4.5, "Bar Roma", account="Intesa card", at=tap_at, category="eating_out")
    fake.txs["u1"] = [tx(-4.5, d - timedelta(days=1), text="PAGAMENTO APPLE PAY BAR ROMA TORINO", ident="b1")]
    link(banks, fake)
    rows = finance.recent()
    assert len(rows) == 1
    assert rows[0]["id"] == tap["id"] and rows[0]["merchant"] == "Bar Roma" and rows[0]["at"] == tap["at"]
    assert rows[0]["source"] == "wallet" and rows[0]["bank"] and rows[0]["category"] == "eating_out"
    asyncio.run(banks.sync_all(force=True))  # read again: still one
    assert len(finance.recent()) == 1


def test_a_tap_that_comes_after_the_bank_record_merges_into_it(setup):
    finance, banks, fake, _ = setup
    d = today(finance)
    fake.txs["u1"] = [tx(-9.9, d - timedelta(days=1), text="POS 9,90 EUR PIZZERIA DA GINO", ident="b1")]
    link(banks, fake)
    tap_at = datetime.combine(d - timedelta(days=2), datetime.min.time(), ROME).replace(hour=20)
    tx_, new = finance.add(-9.9, "Pizzeria da Gino", account="Hype", at=tap_at)
    rows = finance.recent()
    assert len(rows) == 1 and rows[0]["merchant"] == "Pizzeria da Gino" and rows[0]["source"] == "wallet"
    assert rows[0]["at"] == tap_at.astimezone(timezone.utc).isoformat()


def test_pending_becomes_booked_in_place_and_a_dropped_pending_goes(setup):
    finance, banks, fake, _ = setup
    d = today(finance)
    fake.txs["u1"] = [tx(-30, d, name="Amazon", status="PDNG", ident="p1"),
                      tx(-7, d, name="Cinema", status="PDNG", ident="p2")]
    link(banks, fake)
    assert sorted(r["pending"] for r in finance.recent()) == [True, True]
    fake.txs["u1"] = [tx(-30, d, name="Amazon", ident="booked-1")]  # booked under a new id; the cinema cancelled
    asyncio.run(banks.sync_all(force=True))
    rows = finance.recent()
    assert [(r["merchant"], r["pending"]) for r in rows] == [("Amazon", False)]


def test_moves_between_linked_accounts_are_transfers(setup):
    finance, banks, fake, _ = setup
    fake.accounts["u2"] = {"uid": "u2", "account_id": {"iban": "IT11Y0000000000000000999999"}, "name": "Risparmio",
                           "currency": "EUR", "cash_account_type": "SVGS"}
    fake.bal["u2"] = [{"balance_type": "ITAV", "balance_amount": {"amount": "300", "currency": "EUR"}}]
    d = today(finance)
    fake.txs["u1"] = [tx(-100, d - timedelta(days=1), name="Me", ident="o1", iban="IT11Y0000000000000000999999")]
    fake.txs["u2"] = [tx(100, d, name="Filippo", ident="i1")]
    link(banks, fake)
    assert {r["category"] for r in finance.recent()} == {"transfer"}
    assert finance.month()["spent"] == 0 and finance.month()["income"] == 0


def test_money_in_is_pushed_only_when_the_user_is_away(setup):
    finance, banks, fake, pushes = setup
    link(banks, fake)
    fake.txs["u1"] = [tx(250, today(finance), name="Borsa di studio", ident="in1")]
    asyncio.run(banks.sync_all(psu={"Psu-Ip-Address": "1.2.3.4"}, force=True))
    assert pushes == []
    fake.txs["u1"].append(tx(60, today(finance), name="Mamma", ident="in2"))
    bank_id = banks.linked()[0]["id"]
    asyncio.run(banks.sync(bank_id))
    assert pushes == [("Money in", "€60 from Mamma", {"payment_id": finance.recent()[0]["id"]})]


def test_four_background_reads_a_day_and_none_twice_in_a_slot(setup):
    finance, banks, fake, _ = setup
    link(banks, fake)
    n = len(fake.reads)
    day = today(finance)
    asyncio.run(banks.tick(datetime.combine(day, datetime.min.time(), ROME).replace(hour=12, minute=1)))
    assert len(fake.reads) == n + 1
    asyncio.run(banks.tick(datetime.combine(day, datetime.min.time(), ROME).replace(hour=16, minute=59)))
    assert len(fake.reads) == n + 1
    assert banks.due_slot(datetime.combine(day, datetime.min.time(), ROME).replace(hour=5)).hour == 22


def test_an_ended_consent_is_marked_and_a_week_before_a_push_asks_to_renew(setup):
    finance, banks, fake, pushes = setup
    linked = link(banks, fake)
    soon = (datetime.now(timezone.utc) + timedelta(days=5)).isoformat()
    finance.conn.execute("UPDATE finance_banks SET valid_until = ?", (soon,))
    assert finance.accounts()[0]["status"] == "renew"
    asyncio.run(banks.tick())
    asyncio.run(banks.tick())
    assert [p[0] for p in pushes] == ["Renew Intesa Sanpaolo"]
    fake.fail = BankError(401, "EXPIRED_SESSION", "Session is expired")
    asyncio.run(banks.sync(linked["id"]))
    assert banks.bank(linked["id"])["status"] == "expired" and finance.accounts()[0]["status"] == "expired"


def test_relinking_a_bank_replaces_the_old_session_and_keeps_the_accounts(setup):
    finance, banks, fake, _ = setup
    first = link(banks, fake)
    second = link(banks, fake)
    assert fake.closed == ["s1"]
    assert [b["id"] for b in banks.linked()] == [second["id"]] != [first["id"]]
    assert len(finance.accounts()) == 1 and finance.accounts()[0]["bank_id"] == second["id"]


def test_a_rate_limit_keeps_the_link_and_says_so(setup):
    finance, banks, fake, _ = setup
    linked = link(banks, fake)
    fake.fail = BankError(429, "ASPSP_RATE_LIMIT_EXCEEDED", "ASPSP Rate limit exceeded")
    assert asyncio.run(banks.sync(linked["id"])) == 0
    b = banks.bank(linked["id"])
    assert b["status"] == "linked" and "later" in b["error"]


def test_client_signs_a_jwt_with_the_app_key_and_pages_transactions(tmp_path):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    (tmp_path / "eb.pem").write_bytes(pem)
    seen = []

    def handler(request: httpx.Request) -> httpx.Response:
        token = request.headers["authorization"].removeprefix("Bearer ")
        claims = jwt.decode(token, key.public_key(), algorithms=["RS256"], audience="api.enablebanking.com")
        assert claims["iss"] == "enablebanking.com" and jwt.get_unverified_header(token)["kid"] == "app-1"
        seen.append(request)
        q = parse_qs(urlparse(str(request.url)).query)
        if request.headers.get("psu-ip-address") == "100.64.0.1":
            return httpx.Response(400, json={"error": "PSU_HEADER_INVALID", "message": "bad ip"})
        if "continuation_key" in q:
            return httpx.Response(200, json={"transactions": [{"n": 2}], "continuation_key": None})
        return httpx.Response(200, json={"transactions": [{"n": 1}], "continuation_key": "k"})

    client = EnableBanking("app-1", tmp_path / "eb.pem",
                           httpx.AsyncClient(base_url="https://api.enablebanking.com",
                                             transport=httpx.MockTransport(handler)))
    got = asyncio.run(client.transactions("u1", date(2026, 8, 1), psu={"Psu-Ip-Address": "100.64.0.1"}))
    assert got == [{"n": 1}, {"n": 2}]
    assert len(seen) == 3 and "psu-ip-address" not in seen[-1].headers  # retried without the tailnet address, then no more


def test_api_links_through_the_callback_and_lists_banks(setup):
    finance, banks, fake, _ = setup
    db = Database(":memory:")
    agent = Agent(RecordingClient(()), db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME, delegate=False)
    finance2 = FinanceStore(db.conn, ROME)
    banks2 = Banks(finance2, fake)
    app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, finance=finance2, banks=banks2)
    c = TestClient(app)
    assert c.get("/v1/finance/banks", headers=AUTH).json() == {"enabled": True, "banks": []}
    avail = c.get("/v1/finance/banks/available", headers=AUTH).json()["banks"]
    assert [b["name"] for b in avail] == ["Fineco", "Intesa Sanpaolo"] and avail[0]["days"] == 90
    assert c.post("/v1/finance/banks/link", headers=AUTH, json={"bank": "Intesa Sanpaolo"}).status_code == 400
    r = c.post("/v1/finance/banks/link", headers=AUTH,
               json={"bank": "Intesa Sanpaolo", "server": "https://cappa.ts.net/"})
    assert r.json()["url"].startswith("https://bank.example/")
    assert fake.starts[-1]["redirect"] == "https://cappa.ts.net/v1/finance/banks/callback"
    r = c.get(f"/v1/finance/banks/callback?state={fake.starts[-1]['state']}&code=abc", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"].startswith("aide://money/banks?linked=")
    r = c.get("/v1/finance/banks/callback?state=x&error=access_denied", follow_redirects=False)
    assert r.headers["location"] == "aide://money/banks?error=access_denied"
    accounts = c.get("/v1/finance/accounts", headers=AUTH).json()
    assert accounts["total"] == 1180.5 and accounts["accounts"][0]["status"] == "bank"
    acc_id = accounts["accounts"][0]["id"]
    r = c.patch(f"/v1/finance/accounts/{acc_id}", headers=AUTH, json={"hidden": True})
    assert r.json()["account"]["hidden"] is True
    assert c.get("/v1/finance/accounts", headers=AUTH).json()["total"] is None
    assert c.patch("/v1/finance/accounts/999", headers=AUTH, json={"hidden": True}).status_code == 404
    c.patch(f"/v1/finance/accounts/{acc_id}", headers=AUTH, json={"hidden": False})
    assert c.post("/v1/finance/banks/sync", headers=AUTH).json()["new"] == 0
    bank_id = c.get("/v1/finance/banks", headers=AUTH).json()["banks"][0]["id"]
    assert c.delete(f"/v1/finance/banks/{bank_id}", headers=AUTH).json() == {"ok": True}
    assert c.get("/v1/finance/accounts", headers=AUTH).json()["accounts"][0]["status"] == "unlinked"
    db.close()


def test_api_without_a_key_says_bank_sync_is_off():
    db = Database(":memory:")
    agent = Agent(RecordingClient(()), db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME, delegate=False)
    c = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN))
    assert c.get("/v1/finance/banks", headers=AUTH).json() == {"enabled": False, "banks": []}
    assert c.get("/v1/finance/banks/available", headers=AUTH).status_code == 503
    assert c.post("/v1/finance/banks/sync", headers=AUTH).json() == {"new": 0, "banks": []}
    db.close()


def test_finance_reads_balances(setup):
    finance, banks, fake, _ = setup
    tools = {t.name: t for t in finance_tools(finance, banks)}
    assert "No accounts yet" in asyncio.run(tools["accounts"].handler())
    link(banks, fake)
    out = asyncio.run(tools["accounts"].handler())
    assert "Intesa Sanpaolo Conto ··3456 (account): €1,180.50" in out


def test_own_money_moving_is_a_transfer_not_spending_or_income(setup):
    finance, banks, fake, _ = setup
    d = today(finance)
    fake.txs["u1"] = [
        tx(200, d, text="Apple Pay Top-Up by *5372", ident="t1"),           # a card topping the account up
        tx(-1800, d, name="Filippo Cappa", text="Mastercard To Filippo Cappa", ident="t2"),  # to the user's own name
        tx(-50, d, name="CAPPA FILIPPO", text="Giroconto", ident="t3"),
        tx(-44.15, d, text="To investment account", ident="t4"),
        tx(-300, d, name="Advanzia Bank S.A.", text="Carta YOU", ident="t5"),
        tx(13.3, d, name="Filippo Cappa", text="Refund from Jcdecaux Espana Slu", ident="t6"),  # a refund: income
        tx(100, d, name="Marco Cappa", text="Paghetta", ident="t7"),        # a parent, same surname: income
        tx(-20, d, name="Vodafone", text="Ricarica top-up", ident="t8"),     # a phone top-up out: spending
    ]
    link(banks, fake)
    cats = {r["raw"].split(" · ")[-1]: r["category"] for r in finance.conn.execute(
        "SELECT raw, category FROM finance_transactions")}
    assert [cats[k] for k in ("Apple Pay Top-Up by *5372", "Mastercard To Filippo Cappa", "Giroconto",
                              "To investment account", "Carta YOU")] == ["transfer"] * 5
    assert cats["Refund from Jcdecaux Espana Slu"] == "income" and cats["Paghetta"] == "income"
    assert cats["Ricarica top-up"] != "transfer"


def test_records_from_before_the_rule_are_sorted_again_but_not_the_users(setup):
    finance, banks, fake, _ = setup
    link(banks, fake)
    acc = finance.accounts()[0]["id"]
    d = today(finance)
    banks.add(acc, parse_tx(tx(-500, d, name="Filippo Cappa", text="To Filippo Cappa", ident="x1"), "u1", {}))
    banks.add(acc, parse_tx(tx(-60, d, name="Filippo Cappa", text="Cena", ident="x2"), "u1", {}))
    finance.conn.execute("UPDATE finance_transactions SET category = 'other', sorted_by = 'model'")
    mine = finance.recent()[0]["id"] if finance.recent()[0]["amount"] == -60 else finance.recent()[1]["id"]
    finance.conn.execute("UPDATE finance_transactions SET sorted_by = 'user' WHERE id = ?", (mine,))
    asyncio.run(banks.sync_all(force=True))
    by_amount = {r["amount"]: r["category"] for r in finance.recent()}
    assert by_amount == {-500: "transfer", -60: "other"}


def test_an_account_linked_before_holders_learns_its_holder_and_drops_it_from_the_name(setup):
    finance, banks, fake, _ = setup
    fake.accounts["u1"].pop("product")
    link(banks, fake)
    finance.conn.execute("UPDATE finance_accounts SET holder = NULL, name = 'Intesa Sanpaolo Filippo Cappa ··3456'")
    asyncio.run(banks.sync_all(force=True))
    a = finance.accounts()[0]
    assert a["name"] == "Intesa Sanpaolo ··3456"
    assert banks._holders() == {frozenset({"filippo", "cappa"})}


def test_a_hidden_account_stays_out_of_the_total_but_its_payments_count(setup):
    finance, banks, fake, _ = setup
    fake.accounts["u2"] = {"uid": "u2", "account_id": {"iban": "IT11Y0000000000000000999999"}, "product": "Per Merito",
                           "name": "Filippo Cappa", "currency": "EUR", "cash_account_type": "CACC"}
    fake.bal["u2"] = [{"balance_type": "ITAV", "balance_amount": {"amount": "-5400", "currency": "EUR"}}]
    fake.txs["u2"] = [tx(-30, today(finance), name="Esselunga", ident="e1")]
    link(banks, fake)
    merito = next(a for a in finance.accounts() if "Merito" in a["name"])
    assert finance.set_hidden(merito["id"], True)["hidden"] is True
    assert finance.set_hidden(999, True) is None
    assert finance.month()["spent"] == 30
