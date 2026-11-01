"""Money: payments from the Wallet taps (and later the banks and statements), sorted into categories, the month, the
subscriptions and an optional budget. Contract in docs/API.md, "Finance".

Amounts are euros, negative when money goes out. Spending is every payment that isn't income or a transfer between
the user's own accounts; a refund (positive, not income) takes from its category's spending.

Carta YOU (Advanzia), which no bank link reads, is followed here (`kind` "credit"): what's owed from when the user
says (`set_owed`), its Wallet taps as spending, and the payoffs and draws the banks show (`link_id`, banks.py) moving
it. Before that, a payoff stands for the purchases it pays (`card`). Cash: a withdrawal is spending when it's taken
out; a cash payment told to Finance (the "Cash" account) moves that much out of it into its own category.

Sorting: a merchant's rule first (the user's correction, else the model's earlier answer), else the fast model, in
one call for every merchant not yet known; its answer becomes the merchant's rule, so each merchant costs once.
"""

import json
import logging
import re
import sqlite3
from calendar import monthrange
from collections.abc import Awaitable, Callable
from datetime import date, datetime, time, timedelta, timezone
from statistics import median
from zoneinfo import ZoneInfo

from .db import utcnow

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS finance_accounts (
    id            INTEGER PRIMARY KEY,
    key           TEXT NOT NULL UNIQUE,  -- the card's or account's name, lowercased
    name          TEXT NOT NULL,
    kind          TEXT NOT NULL DEFAULT 'card',  -- card | account
    source        TEXT NOT NULL DEFAULT 'wallet',  -- wallet | bank | statement | manual
    currency      TEXT NOT NULL DEFAULT 'EUR',
    balance       REAL,
    balance_at    TEXT,
    consent_until TEXT,
    created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS finance_transactions (
    id         INTEGER PRIMARY KEY,
    account_id INTEGER REFERENCES finance_accounts (id),
    at         TEXT NOT NULL,  -- UTC
    amount     REAL NOT NULL,  -- negative: money out
    currency   TEXT NOT NULL DEFAULT 'EUR',
    merchant   TEXT NOT NULL,
    raw        TEXT,           -- the bank's or Wallet's own text
    category   TEXT NOT NULL DEFAULT 'other',
    sorted_by  TEXT NOT NULL DEFAULT 'none',  -- rule | model | user | none
    source     TEXT NOT NULL,  -- wallet | bank | statement | manual
    place      TEXT,
    lat        REAL,
    lon        REAL,
    note       TEXT,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS finance_transactions_at ON finance_transactions (at);
CREATE TABLE IF NOT EXISTS finance_rules (
    pattern    TEXT PRIMARY KEY,  -- the merchant, normalised
    category   TEXT NOT NULL,
    origin     TEXT NOT NULL,     -- user | model
    updated_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS finance_banks (
    id            INTEGER PRIMARY KEY,
    session_id    TEXT NOT NULL UNIQUE,
    bank          TEXT NOT NULL,
    country       TEXT NOT NULL,
    valid_until   TEXT,
    status        TEXT NOT NULL DEFAULT 'linked',  -- linked | expired | unlinked | replaced
    error         TEXT,
    last_sync_at  TEXT,
    last_slot_at  TEXT,  -- the background slot last read
    reminded      INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

# id: (name, what goes in it, for the model)
CATEGORIES: dict[str, tuple[str, str]] = {
    "groceries": ("Groceries", "supermarkets, food shops, markets"),
    "eating_out": ("Eating out", "restaurants, bars, cafés, takeaway, food delivery"),
    "transport": ("Transport", "public transport, trains for commuting, taxis, fuel, parking, bike and scooter hire"),
    "shopping": ("Shopping", "clothes, electronics, Amazon, home things, gifts"),
    "subscriptions": ("Subscriptions", "streaming, apps, cloud storage, phone plans, memberships"),
    "bills": ("Bills", "rent, utilities, internet, insurance, bank fees"),
    "health": ("Health", "pharmacy, doctors, gym, sport"),
    "study": ("Study", "university fees, books, stationery, courses"),
    "travel": ("Travel", "flights, long-distance trains, hotels, holidays"),
    "fun": ("Fun", "cinema, concerts, games, events, hobbies"),
    "cash": ("Cash", "cash withdrawals (a cash payment told to Finance takes its share out of them)"),
    "card": ("Credit card", "paying off a credit card before Aide follows its purchases (Advanzia's Carta YOU): the "
                            "payoff stands for them"),
    "income": ("Income", "salary, allowances, money received"),
    "transfer": ("Transfer", "moving money between the user's own accounts, a credit line drawn into them"),
    "other": ("Other", "anything else"),
}
NOT_SPENDING = {"income", "transfer"}
RULE_ONLY = {"card"}  # set by the bank rules, never by the sorting model
SOURCES = {"wallet", "bank", "statement", "manual"}
CREDIT_NAME = re.compile(r"\badvanzia\b|\bcarta\s*you\b", re.I)  # the credit card Aide follows itself
CREDIT_CARD = "Carta YOU"
CASH_NAMES = {"cash", "contanti"}  # payments told on this "account" were paid in cash
REPEAT_WINDOW = timedelta(minutes=3)  # a Shortcut that runs twice for one tap
# A repeated charge: (period, its days, the gaps that count as it)
PERIODS = (("week", 7, (6, 8)), ("month", 30, (26, 35)), ("year", 365, (350, 380)))
SAME_PRICE = 0.2  # charges within 20% of the last one are the same subscription

SORT_PROMPT = f"""You sort payments into spending categories for one person, a university student in Turin, Italy.
The categories (id: what goes in it):
{chr(10).join(f"- {k}: {v[1]}" for k, v in CATEGORIES.items() if k not in NOT_SPENDING | RULE_ONLY)}
Answer with JSON only: an object from each merchant exactly as given to its category id. When unsure, pick the most \
likely; "other" only when nothing fits."""

Ask = Callable[[str, str], Awaitable[str]]  # (system, text) → the model's answer


def normalise(merchant: str) -> str:
    """A merchant's key for its rule: lowercase, no punctuation, store numbers or company suffixes."""
    s = merchant.lower()
    s = re.sub(r"\b(s\.?r\.?l\.?s?|s\.?p\.?a\.?|s\.?n\.?c\.?|s\.?a\.?s\.?|ltd|inc|gmbh|llc)\b", " ", s)
    s = re.sub(r"[^\w\s&]", " ", s)
    s = re.sub(r"\b\d+\b", " ", s)
    return " ".join(s.split())


def parse_amount(text: str) -> float:
    """An amount as Shortcuts or a person writes it: "€4.50", "4,50 €", "1.234,56", "EUR 12", "-3.20"."""
    s = re.sub(r"[^\d,.\-]", "", text.replace("−", "-"))
    if not re.search(r"\d", s):
        raise ValueError(f"no amount in {text!r}")
    if "," in s and "." in s:  # the last one is the decimal mark
        s = s.replace(".", "").replace(",", ".") if s.rfind(",") > s.rfind(".") else s.replace(",", "")
    elif "," in s:
        head, _, tail = s.rpartition(",")
        s = f"{head.replace(',', '')}.{tail}" if len(tail) != 3 else s.replace(",", "")
    elif s.count(".") > 1 or re.search(r"\.\d{3}$", s) and len(s) > 4:
        s = s.replace(".", "")
    return float(s)


def euros(v: float) -> str:
    return f"€{abs(v):,.2f}".replace(".00", "")


class FinanceStore:
    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo, ask: Ask | None = None):
        self.conn = conn
        self.tz = tz
        self.ask = ask  # the fast model, for sorting new merchants; None: they stay "other" until a rule says
        self.conn.executescript(SCHEMA)
        self._migrate()

    def _migrate(self) -> None:
        """Bank sync (#31, step 2, banks.py): the bank's id of each payment, pending ones, and each account's link."""
        cols = {t: {r["name"] for r in self.conn.execute(f"PRAGMA table_info({t})")}
                for t in ("finance_transactions", "finance_accounts")}
        for table, col, decl in (("finance_transactions", "ref", "TEXT"),
                                 ("finance_transactions", "pending", "INTEGER NOT NULL DEFAULT 0"),
                                 ("finance_accounts", "bank_id", "INTEGER"), ("finance_accounts", "uid", "TEXT"),
                                 ("finance_accounts", "ident", "TEXT"), ("finance_accounts", "iban", "TEXT"),
                                 ("finance_accounts", "holder", "TEXT"),
                                 ("finance_accounts", "hidden", "INTEGER NOT NULL DEFAULT 0"),
                                 ("finance_accounts", "last4", "TEXT"), ("finance_accounts", "opening", "REAL"),
                                 ("finance_accounts", "opening_at", "TEXT"),
                                 ("finance_transactions", "link_id", "INTEGER")):
            if col not in cols[table]:
                self.conn.execute(f"ALTER TABLE {table} ADD COLUMN {col} {decl}")
        self.conn.execute("CREATE INDEX IF NOT EXISTS finance_transactions_ref ON finance_transactions (ref)")

    def today(self) -> date:
        return datetime.now(self.tz).date()

    def _utc(self, d: date) -> str:
        return datetime.combine(d, time(), self.tz).astimezone(timezone.utc).isoformat()

    def local(self, at: str) -> datetime:
        return datetime.fromisoformat(at).astimezone(self.tz)

    # -- accounts --------------------------------------------------------------------------------

    def account(self, name: str, source: str = "wallet", kind: str = "card") -> dict:
        """The account or card with this name, made the first time it's seen. Carta YOU (by its name or its last
        digits, as Wallet may call it) is the followed credit card; "Cash" is cash."""
        name = " ".join(name.split()) or "Card"
        credit = self.conn.execute("SELECT * FROM finance_accounts WHERE kind = 'credit'").fetchone()
        if CREDIT_NAME.search(name) or credit and credit["last4"] and re.search(rf"\b{credit['last4']}\b", name):
            return self.credit_card()
        if normalise(name) in CASH_NAMES:
            name, kind = "Cash", "cash"
        key = name.lower()
        row = self.conn.execute("SELECT * FROM finance_accounts WHERE key = ?", (key,)).fetchone()
        if not row:
            self.conn.execute("INSERT INTO finance_accounts (key, name, kind, source, created_at) VALUES (?, ?, ?, ?, ?)",
                              (key, name, kind, source, utcnow().isoformat()))
            row = self.conn.execute("SELECT * FROM finance_accounts WHERE key = ?", (key,)).fetchone()
        return dict(row)

    def credit_card(self) -> dict:
        """Carta YOU, made the first time it's needed."""
        row = self.conn.execute("SELECT * FROM finance_accounts WHERE kind = 'credit'").fetchone()
        if row:
            return dict(row)
        self.conn.execute("INSERT INTO finance_accounts (key, name, kind, source, created_at) VALUES (?, ?, 'credit', "
                          "'manual', ?)", (CREDIT_CARD.lower(), CREDIT_CARD, utcnow().isoformat()))
        return dict(self.conn.execute("SELECT * FROM finance_accounts WHERE kind = 'credit'").fetchone())

    def followed_since(self, card) -> str | None:
        """From when the card's purchases are its own payments (what's owed told, or its first Wallet tap), so a
        payoff from then on is a transfer to it, not spending."""
        first = self.conn.execute("SELECT MIN(at) AS at FROM finance_transactions WHERE account_id = ?",
                                  (card["id"],)).fetchone()["at"]
        return min(x for x in (card["opening_at"], first) if x) if card["opening_at"] or first else None

    def owed(self, card) -> float | None:
        """The card's balance (below zero: owed): what the user said, minus its purchases since, plus payoffs, minus
        draws (a draw tops another account up from the card)."""
        if card["opening"] is None:
            return None
        own = self.conn.execute("SELECT COALESCE(SUM(amount), 0) AS s FROM finance_transactions WHERE account_id = ? "
                                "AND at >= ?", (card["id"], card["opening_at"])).fetchone()["s"]
        moved = self.conn.execute("SELECT COALESCE(SUM(amount), 0) AS s FROM finance_transactions WHERE link_id = ? "
                                  "AND at >= ?", (card["id"], card["opening_at"])).fetchone()["s"]
        return round(card["opening"] + own - moved, 2)

    def set_owed(self, owed: float | None, last4: str | None = None) -> dict:
        """What's owed on Carta YOU now (None: unchanged), and its last 4 digits, which name its draws ("Top-Up by
        *1234"). From then on its taps are the spending and payoffs move money to it; banks.Banks.mark_card sorts them
        again."""
        if owed is not None and not 0 <= owed <= 1_000_000:
            raise ValueError("what's owed is 0 or more")
        if last4 is not None and not re.fullmatch(r"\d{4}", last4):
            raise ValueError("last4 is the card's last 4 digits")
        card = self.credit_card()
        if owed is not None:
            self.conn.execute("UPDATE finance_accounts SET opening = ?, opening_at = ? WHERE id = ?",
                              (-round(owed, 2), utcnow().isoformat(), card["id"]))
        if last4 is not None:
            self.conn.execute("UPDATE finance_accounts SET last4 = ? WHERE id = ?", (last4, card["id"]))
        return next(a for a in self.accounts() if a["id"] == card["id"])

    def accounts(self) -> list[dict]:
        out = []
        for a in self.conn.execute("SELECT * FROM finance_accounts ORDER BY name COLLATE NOCASE"):
            last = self.conn.execute("SELECT MAX(at) AS at, COUNT(*) AS n FROM finance_transactions "
                                     "WHERE account_id = ?", (a["id"],)).fetchone()
            month = self.conn.execute("SELECT COALESCE(SUM(amount), 0) AS s FROM finance_transactions WHERE "
                                      "account_id = ? AND at >= ? AND category NOT IN ('income', 'transfer')",
                                      (a["id"], self._utc(self.today().replace(day=1)))).fetchone()["s"]
            balance, balance_at = a["balance"], a["balance_at"]
            if a["kind"] == "credit":
                balance = self.owed(a)
                balance_at = utcnow().isoformat() if balance is not None else None
            out.append({"id": a["id"], "name": a["name"], "kind": a["kind"], "source": a["source"],
                        "currency": a["currency"], "balance": balance, "balance_at": balance_at,
                        "consent_until": a["consent_until"], "status": self._status(a), "bank_id": a["bank_id"],
                        "last_at": last["at"], "count": last["n"], "spent_month": round(-month, 2),
                        "hidden": bool(a["hidden"]),
                        **({"owed_since": a["opening_at"], "last4": a["last4"]} if a["kind"] == "credit" else {})})
        return out

    def set_hidden(self, account_id: int, hidden: bool) -> dict | None:
        """Leave an account out of Money's accounts and total (a credit line that's always below zero), or show it
        again. Its payments still count."""
        if not self.conn.execute("UPDATE finance_accounts SET hidden = ? WHERE id = ?",
                                 (int(hidden), account_id)).rowcount:
            return None
        return next(a for a in self.accounts() if a["id"] == account_id)

    def _status(self, a) -> str:
        """Where an account's payments come from: wallet, manual, or its bank's link (bank, renew a week before the
        consent ends, expired, unlinked)."""
        if not a["bank_id"]:
            return a["source"]
        b = self.conn.execute("SELECT status, valid_until FROM finance_banks WHERE id = ?", (a["bank_id"],)).fetchone()
        if not b or b["status"] in ("unlinked", "replaced") or not a["uid"]:
            return "unlinked"
        if b["status"] == "expired" or b["valid_until"] and datetime.fromisoformat(b["valid_until"]) <= utcnow():
            return "expired"
        if b["valid_until"] and datetime.fromisoformat(b["valid_until"]) - utcnow() <= timedelta(days=7):
            return "renew"
        return "bank"

    # -- transactions -----------------------------------------------------------------------------

    def as_json(self, row) -> dict:
        acc = self.conn.execute("SELECT name FROM finance_accounts WHERE id = ?", (row["account_id"],)).fetchone()
        return {"id": row["id"], "at": row["at"], "amount": row["amount"], "currency": row["currency"],
                "merchant": row["merchant"], "category": row["category"], "sorted_by": row["sorted_by"],
                "source": row["source"], "account": acc["name"] if acc else None, "account_id": row["account_id"],
                "place": row["place"], "lat": row["lat"], "lon": row["lon"], "note": row["note"],
                "pending": bool(row["pending"]), "bank": bool(row["ref"])}

    def find(self, tx_id: int) -> dict:
        row = self.conn.execute("SELECT * FROM finance_transactions WHERE id = ?", (tx_id,)).fetchone()
        if not row:
            raise KeyError(f"no payment {tx_id}")
        return self.as_json(row)

    def rule(self, merchant: str) -> dict | None:
        """The rule for a merchant: its own, else the longest one it starts with ("esselunga" for "esselunga via
        nizza")."""
        key = normalise(merchant)
        if not key:
            return None
        rows = self.conn.execute("SELECT * FROM finance_rules WHERE ? = pattern OR ? LIKE pattern || ' %' "
                                 "ORDER BY length(pattern) DESC LIMIT 1", (key, key)).fetchall()
        return dict(rows[0]) if rows else None

    def _save_rule(self, merchant: str, category: str, origin: str) -> None:
        key = normalise(merchant)
        if not key:
            return
        if origin == "model":  # never over the user's
            self.conn.execute("INSERT INTO finance_rules (pattern, category, origin, updated_at) VALUES (?, ?, ?, ?) "
                              "ON CONFLICT(pattern) DO NOTHING", (key, category, origin, utcnow().isoformat()))
        else:
            self.conn.execute("INSERT INTO finance_rules (pattern, category, origin, updated_at) VALUES (?, ?, ?, ?) "
                              "ON CONFLICT(pattern) DO UPDATE SET category = excluded.category, origin = "
                              "excluded.origin, updated_at = excluded.updated_at",
                              (key, category, origin, utcnow().isoformat()))

    def add(self, amount: float, merchant: str, account: str | None = None, at: datetime | str | None = None,
            source: str = "wallet", category: str | None = None, place: str | None = None,
            lat: float | None = None, lon: float | None = None, raw: str | None = None,
            currency: str = "EUR", note: str | None = None) -> tuple[dict, bool]:
        """Store a payment, sorted by its merchant's rule (or `category`, which then becomes the rule). Returns it and
        whether it's new: the same card, merchant and amount within 3 minutes is the same tap told twice."""
        if source not in SOURCES:
            raise ValueError(f"source must be one of {', '.join(sorted(SOURCES))}")
        if category is not None and category not in CATEGORIES:
            raise ValueError(f"unknown category {category!r}")
        merchant = " ".join((merchant or "").split())
        if not merchant:
            raise ValueError("a payment needs a merchant")
        amount = round(float(amount), 2)
        if amount == 0 or abs(amount) > 1_000_000:
            raise ValueError("the amount must be more than 0")
        when = datetime.fromisoformat(at) if isinstance(at, str) else (at or utcnow())
        when = (when.replace(tzinfo=self.tz) if when.tzinfo is None else when).astimezone(timezone.utc)
        if when > utcnow() + timedelta(hours=1):
            raise ValueError("a payment can't be in the future")
        acc = self.account(account, source) if account else None
        same = self.conn.execute(
            "SELECT * FROM finance_transactions WHERE merchant = ? AND amount = ? AND account_id IS ? AND at BETWEEN ? "
            "AND ?", (merchant, amount, acc and acc["id"], (when - REPEAT_WINDOW).isoformat(),
                      (when + REPEAT_WINDOW).isoformat())).fetchone()
        if same:
            return self.as_json(same), False
        if source == "wallet" and (bank := self._bank_twin(amount, when)) is not None:
            # the bank had it first (the tap waited on the phone): the tap's name, time and place, the bank's record
            self.conn.execute("UPDATE finance_transactions SET merchant = ?, at = ?, source = 'wallet', place = ?, "
                              "lat = ?, lon = ? WHERE id = ?", (merchant, when.isoformat(), place, lat, lon, bank["id"]))
            if bank["sorted_by"] != "user":
                cat, by = (category, "user") if category else \
                    ((r["category"], "rule") if (r := self.rule(merchant)) else ("other", "none"))
                if category:
                    self._save_rule(merchant, category, "user")
                self.conn.execute("UPDATE finance_transactions SET category = ?, sorted_by = ? WHERE id = ?",
                                  (cat, by, bank["id"]))
            return self.find(bank["id"]), True
        sorted_by = "none"
        if category:
            sorted_by = "user"
            self._save_rule(merchant, category, "user")
        elif amount > 0 and source == "manual":
            category, sorted_by = "income", "rule"
        elif (r := self.rule(merchant)) is not None:
            category, sorted_by = r["category"], "rule"
        cur = self.conn.execute(
            "INSERT INTO finance_transactions (account_id, at, amount, currency, merchant, raw, category, sorted_by, "
            "source, place, lat, lon, note, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (acc and acc["id"], when.isoformat(), amount, currency, merchant, raw, category or "other", sorted_by,
             source, place, lat, lon, note, utcnow().isoformat()))
        return self.find(cur.lastrowid), True

    def _bank_twin(self, amount: float, when: datetime):
        """A bank transaction of this amount from the day of the tap to 5 days after, not yet matched to a tap."""
        day = when.astimezone(self.tz).date()
        rows = self.conn.execute("SELECT * FROM finance_transactions WHERE source = 'bank' AND amount = ? AND at "
                                 "BETWEEN ? AND ? ORDER BY at", (amount, self._utc(day - timedelta(days=1)),
                                                                 self._utc(day + timedelta(days=6)))).fetchall()
        return rows[0] if rows else None

    async def sort_pending(self) -> int:
        """Ask the model once for every merchant still unsorted; their answers become rules. Returns how many payments
        were sorted."""
        rows = self.conn.execute("SELECT id, merchant, amount FROM finance_transactions WHERE sorted_by = 'none'"
                                 ).fetchall()
        if not rows or self.ask is None:
            return 0
        sorted_now = 0
        for r in rows:  # a rule may have come since (another payment, a correction)
            if (rule := self.rule(r["merchant"])) is not None:
                self.conn.execute("UPDATE finance_transactions SET category = ?, sorted_by = 'rule' WHERE id = ?",
                                  (rule["category"], r["id"]))
                sorted_now += 1
        left = [r for r in rows if self.rule(r["merchant"]) is None]
        merchants = sorted({r["merchant"] for r in left})
        if not merchants:
            return sorted_now
        try:
            answer = await self.ask(SORT_PROMPT, "\n".join(merchants))
            got = json.loads(answer[answer.index("{"):answer.rindex("}") + 1])
        except Exception as e:  # noqa: BLE001 — they stay unsorted until the next try
            log.warning("sorting payments failed: %s", e)
            return sorted_now
        for merchant in merchants:
            category = got.get(merchant)
            if category in CATEGORIES and category not in NOT_SPENDING:
                self._save_rule(merchant, category, "model")
        for r in left:
            if (rule := self.rule(r["merchant"])) is not None:
                self.conn.execute("UPDATE finance_transactions SET category = ?, sorted_by = 'model' WHERE id = ? "
                                  "AND sorted_by = 'none'", (rule["category"], r["id"]))
                sorted_now += 1
        return sorted_now

    def update(self, tx_id: int, category: str | None = None, merchant: str | None = None, note: str | None = None,
               remember: bool = True) -> dict:
        """Change a payment. A new category becomes the merchant's rule (`remember`) and re-sorts its other payments
        that the user didn't sort by hand."""
        tx = self.find(tx_id)
        if merchant is not None and merchant.strip():
            self.conn.execute("UPDATE finance_transactions SET merchant = ? WHERE id = ?",
                              (" ".join(merchant.split()), tx_id))
        if note is not None:
            self.conn.execute("UPDATE finance_transactions SET note = ? WHERE id = ?", (note.strip() or None, tx_id))
        if category is not None:
            if category not in CATEGORIES:
                raise ValueError(f"unknown category {category!r}")
            self.conn.execute("UPDATE finance_transactions SET category = ?, sorted_by = 'user' WHERE id = ?",
                              (category, tx_id))
            if remember:
                name = self.find(tx_id)["merchant"]
                self._save_rule(name, category, "user")
                key = normalise(name)
                for other in self.conn.execute("SELECT id, merchant FROM finance_transactions WHERE id != ? AND "
                                               "sorted_by != 'user'", (tx_id,)).fetchall():
                    if normalise(other["merchant"]) == key:
                        self.conn.execute("UPDATE finance_transactions SET category = ?, sorted_by = 'rule' "
                                          "WHERE id = ?", (category, other["id"]))
        return self.find(tx["id"])

    def delete(self, tx_id: int) -> bool:
        return self.conn.execute("DELETE FROM finance_transactions WHERE id = ?", (tx_id,)).rowcount > 0

    def between(self, start: date, end: date, category: str | None = None, merchant: str | None = None,
                account_id: int | None = None) -> list[dict]:
        """Payments from start to end (local days, both included), newest first."""
        sql = "SELECT * FROM finance_transactions WHERE at >= ? AND at < ?"
        args: list = [self._utc(start), self._utc(end + timedelta(days=1))]
        if category:
            sql += " AND category = ?"
            args.append(category)
        if account_id:
            sql += " AND account_id = ?"
            args.append(account_id)
        rows = [self.as_json(r) for r in self.conn.execute(sql + " ORDER BY at DESC, id DESC", args)]
        if merchant:
            key = normalise(merchant)
            rows = [r for r in rows if key in normalise(r["merchant"])]
        return rows

    def recent(self, limit: int = 50, before: str | None = None, category: str | None = None) -> list[dict]:
        sql, args = "SELECT * FROM finance_transactions WHERE 1 = 1", []
        if before:
            sql += " AND at < ?"
            args.append(before)
        if category:
            sql += " AND category = ?"
            args.append(category)
        return [self.as_json(r) for r in self.conn.execute(sql + " ORDER BY at DESC, id DESC LIMIT ?",
                                                           (*args, limit))]

    def merchant_history(self, tx: dict) -> dict:
        """The merchant's other payments: how many, the total this month and the last few."""
        key = normalise(tx["merchant"])
        rows = [self.as_json(r) for r in self.conn.execute(
            "SELECT * FROM finance_transactions WHERE id != ? ORDER BY at DESC", (tx["id"],))
            if normalise(r["merchant"]) == key]
        start = self._utc(self.today().replace(day=1))
        return {"count": len(rows), "month_total": round(-sum(r["amount"] for r in rows if r["at"] >= start), 2),
                "recent": rows[:5]}

    # -- the budget -------------------------------------------------------------------------------

    def budget(self) -> dict:
        row = self.conn.execute("SELECT value FROM settings WHERE key = 'finance_budget'").fetchone()
        value = json.loads(row["value"]) if row else {}
        return {"monthly": value.get("monthly"), "categories": value.get("categories") or {}}

    def set_budget(self, monthly: float | None = ..., categories: dict | None = None) -> dict:
        """The month's budget (None: none) and each category's (a None value removes it). Both optional."""
        value = self.budget()
        if monthly is not ...:
            if monthly is not None and monthly <= 0:
                raise ValueError("a budget must be more than 0")
            value["monthly"] = round(monthly, 2) if monthly is not None else None
        for cat, amount in (categories or {}).items():
            if cat not in CATEGORIES or cat in NOT_SPENDING:
                raise ValueError(f"no budget for {cat!r}")
            if amount is None:
                value["categories"].pop(cat, None)
            elif amount <= 0:
                raise ValueError("a budget must be more than 0")
            else:
                value["categories"][cat] = round(amount, 2)
        self.conn.execute("INSERT INTO settings (key, value) VALUES ('finance_budget', ?) "
                          "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (json.dumps(value),))
        return self.budget()

    # -- the month --------------------------------------------------------------------------------

    def _spent(self, start: date, end: date) -> dict[str, float]:
        """Spending by category from start to end, both included (a refund takes from its category)."""
        out: dict[str, float] = {}
        if end < start:
            return out
        for r in self.conn.execute("SELECT category, SUM(amount) AS s FROM finance_transactions WHERE at >= ? AND "
                                   "at < ? AND category NOT IN ('income', 'transfer') GROUP BY category",
                                   (self._utc(start), self._utc(end + timedelta(days=1)))):
            out[r["category"]] = round(-r["s"], 2)
        if out.get("card", 0) < 0:  # a month that only drew from the card: nothing spent on it yet
            del out["card"]
        if "cash" in out:
            covered = self._cash_covered()
            taken = sum(covered.get(r["id"], 0) for r in self.conn.execute(
                "SELECT id FROM finance_transactions WHERE category = 'cash' AND amount < 0 AND at >= ? AND at < ?",
                (self._utc(start), self._utc(end + timedelta(days=1)))))
            out["cash"] = round(out["cash"] - taken, 2)
            if out["cash"] <= 0.005:
                del out["cash"]
        return out

    def _cash_covered(self) -> dict[int, float]:
        """How much of each withdrawal the cash payments told to Finance account for: each payment takes from the
        oldest withdrawal before it with cash left, so it isn't counted twice (once taken out, once spent)."""
        withdrawals = [{"id": r["id"], "at": r["at"], "left": -r["amount"]} for r in self.conn.execute(
            "SELECT t.id, t.at, t.amount FROM finance_transactions t LEFT JOIN finance_accounts a ON a.id = t.account_id "
            "WHERE t.category = 'cash' AND t.amount < 0 AND COALESCE(a.kind, '') != 'cash' ORDER BY t.at")]
        covered: dict[int, float] = {}
        if not withdrawals:
            return covered
        for t in self.conn.execute("SELECT t.at, t.amount FROM finance_transactions t JOIN finance_accounts a ON "
                                   "a.id = t.account_id WHERE a.kind = 'cash' AND t.amount < 0 AND t.category NOT IN "
                                   "('income', 'transfer', 'cash') ORDER BY t.at"):
            need = -t["amount"]
            for w in withdrawals:
                if w["at"] > t["at"] or need <= 0:
                    break
                take = min(w["left"], need)
                if take > 0:
                    w["left"] -= take
                    need -= take
                    covered[w["id"]] = covered.get(w["id"], 0) + take
        return covered

    def month(self, month: str | None = None, today: date | None = None) -> dict:
        """A month at a glance: spent, the budget and what's left, against last month by the same day, each
        category, and Finance's line. The current month counts to today; a past one is whole."""
        today = today or self.today()
        first = date.fromisoformat(f"{month}-01") if month else today.replace(day=1)
        days = monthrange(first.year, first.month)[1]
        last_day = first.replace(day=days)
        current = first <= today <= last_day
        if first > today:
            raise ValueError("that month hasn't started")
        day = today.day if current else days
        prev_first = (first - timedelta(days=1)).replace(day=1)
        prev_days = monthrange(prev_first.year, prev_first.month)[1]
        spent_by = self._spent(first, first.replace(day=day))
        prev_by = self._spent(prev_first, prev_first.replace(day=min(day, prev_days)))
        prev_all = self._spent(prev_first, prev_first.replace(day=prev_days))
        spent = round(sum(spent_by.values()), 2)
        income = self.conn.execute("SELECT COALESCE(SUM(amount), 0) AS s FROM finance_transactions WHERE "
                                   "category = 'income' AND at >= ? AND at < ?",
                                   (self._utc(first), self._utc(last_day + timedelta(days=1)))).fetchone()["s"]
        count = self.conn.execute("SELECT COUNT(*) AS n FROM finance_transactions WHERE at >= ? AND at < ?",
                                  (self._utc(first), self._utc(last_day + timedelta(days=1)))).fetchone()["n"]
        budget = self.budget()
        monthly = budget["monthly"]
        left = round(monthly - spent, 2) if monthly else None
        days_left = days - day + 1 if current else 0  # today counts as a day still to spend in
        pace = round(monthly * day / days, 2) if monthly else None
        cats = []
        for cat in sorted(set(spent_by) | set(prev_all) | set(budget["categories"]),
                          key=lambda c: (-spent_by.get(c, 0), -prev_all.get(c, 0), c)):
            b = budget["categories"].get(cat)
            s = spent_by.get(cat, 0.0)
            cat_pace = round(b * day / days, 2) if b else None
            cats.append({"id": cat, "name": CATEGORIES[cat][0], "spent": s, "budget": b, "pace": cat_pace,
                         "ahead": bool(b and current and s > cat_pace * 1.1 and s - cat_pace > 5),
                         "over": bool(b and s > b), "last_by_now": prev_by.get(cat, 0.0),
                         "last_total": prev_all.get(cat, 0.0)})
        prev_spent = round(sum(prev_by.values()), 2)
        has_prev = self.conn.execute("SELECT 1 FROM finance_transactions WHERE at < ? LIMIT 1",
                                     (self._utc(first),)).fetchone() is not None
        out = {"month": first.strftime("%Y-%m"), "current": current, "day": day, "days": days,
               "days_left": days_left, "spent": spent, "income": round(income, 2), "count": count,
               "budget": monthly, "left": left,
               "per_day": round(left / days_left, 2) if left is not None and left > 0 and days_left else None,
               "pace": pace, "ahead": bool(monthly and current and spent > pace * 1.1),
               "last_month": {"month": prev_first.strftime("%Y-%m"),
                              "by_now": prev_spent if has_prev else None,
                              "total": round(sum(prev_all.values()), 2) if has_prev else None},
               "categories": cats}
        out["line"] = self.line(out)
        return out

    def line(self, m: dict) -> str:
        """Finance's line over the Money page, from the month's numbers (no model call)."""
        if m["count"] == 0 and not self.conn.execute("SELECT 1 FROM finance_transactions LIMIT 1").fetchone():
            return ("Nothing to count yet. Set up Log payment (Settings → Payments) and every Apple Pay tap comes in "
                    "here, sorted.")
        name = datetime.strptime(m["month"], "%Y-%m").strftime("%B")
        if not m["current"]:
            line = f"{euros(m['spent'])} spent in {name}"
            last = m["last_month"]["total"]
            if last:
                line += f", {euros(m['spent'] - last)} {'more' if m['spent'] > last else 'less'} than the month before"
            return line + "."
        if m["budget"]:
            if m["left"] > 0:
                line = (f"{euros(m['left'])} left for {m['days_left']} day{'s' if m['days_left'] != 1 else ''}, "
                        f"about {euros(m['per_day'])} a day.")
            else:
                line = f"{euros(-m['left'])} over the budget, with {m['days_left']} days to go."
            ahead = [c["name"] for c in m["categories"] if c["ahead"]]
            if ahead and m["left"] > 0:
                line += f" {' and '.join(ahead[:2])} {'is' if len(ahead) == 1 else 'are'} ahead of where it should be."
            return line
        line = f"{euros(m['spent'])} so far this month"
        last = m["last_month"]["by_now"]
        if last is not None:
            diff = m["spent"] - last
            line += (", about the same as last month by now" if abs(diff) < 5 else
                     f", {euros(diff)} {'more' if diff > 0 else 'less'} than last month by now")
        top = next((c for c in m["categories"] if c["spent"] > 0), None)
        if top and m["spent"] and top["spent"] / m["spent"] >= 0.3:
            line += f", most of it on {top['name'].lower()}"
        return line + "."

    # -- subscriptions ----------------------------------------------------------------------------

    def subscriptions(self, today: date | None = None) -> dict:
        """Charges that repeat (each week, month or year at about the same price), and anything sorted as a
        subscription: the price, the period, the last and next charge, and the monthly total."""
        today = today or self.today()
        rows = self.conn.execute("SELECT * FROM finance_transactions WHERE amount < 0 AND at >= ? ORDER BY at",
                                 (self._utc(today - timedelta(days=400)),)).fetchall()
        groups: dict[str, list] = {}
        for r in rows:
            groups.setdefault(normalise(r["merchant"]) or r["merchant"], []).append(r)
        subs = []
        for charges in groups.values():
            last = charges[-1]
            price = -last["amount"]
            same = [c for c in charges if abs(-c["amount"] - price) <= price * SAME_PRICE]
            dates = [self.local(c["at"]).date() for c in same]
            period = None
            if len(dates) >= 2:
                gap = median((b - a).days for a, b in zip(dates, dates[1:]))
                period = next((p for p in PERIODS if p[2][0] <= gap <= p[2][1]), None)
            if period is None and last["category"] == "subscriptions":
                period = PERIODS[1]  # one charge so far: monthly until it shows otherwise
            if period is None:
                continue
            name, length, _ = period
            last_day = dates[-1] if dates else self.local(last["at"]).date()
            if (today - last_day).days > length * 1.5:
                continue  # stopped
            nxt = (_add_months(last_day, 1) if name == "month" else
                   _add_months(last_day, 12) if name == "year" else last_day + timedelta(days=7))
            monthly = price if name == "month" else price / 12 if name == "year" else price * 52 / 12
            subs.append({"merchant": last["merchant"], "amount": round(price, 2), "period": name,
                         "category": last["category"], "account": self.as_json(last)["account"],
                         "last": last_day.isoformat(), "next": nxt.isoformat(), "count": len(same),
                         "monthly": round(monthly, 2), "price_was": round(-same[-2]["amount"], 2)
                         if len(same) >= 2 and same[-2]["amount"] != last["amount"] else None})
        subs.sort(key=lambda s: s["next"])
        return {"subscriptions": subs, "monthly_total": round(sum(s["monthly"] for s in subs), 2)}


def _add_months(d: date, n: int) -> date:
    y, m = divmod(d.month - 1 + n, 12)
    y, m = d.year + y, m + 1
    return d.replace(year=y, month=m, day=min(d.day, monthrange(y, m)[1]))


def describe_tx(tx: dict, tz: ZoneInfo) -> str:
    when = datetime.fromisoformat(tx["at"]).astimezone(tz)
    sign = "+" if tx["amount"] > 0 else "−"
    parts = [f"{when:%a %d %b %H:%M}", f"{sign}{euros(tx['amount'])}", tx["merchant"],
             CATEGORIES[tx["category"]][0].lower()]
    if tx["account"]:
        parts.append(tx["account"])
    if tx["place"]:
        parts.append(tx["place"])
    if tx["note"]:
        parts.append(f"note: {tx['note']}")
    return f"- {', '.join(parts)} [payment {tx['id']}]"
