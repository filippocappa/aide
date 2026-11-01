"""Bank accounts through Enable Banking (#31, step 2; docs/API.md "Finance", "Banks"): balances and every transaction,
read-only under PSD2. Enable Banking is the licensed provider in between: the user picks a bank in the app, logs in on
the bank's own page and allows reading for up to 180 days; Aide then reads with a JWT signed by the key on `cappa`.
Aide can't move money: nothing here can.

Banks answer at most 4 reads a day per account when the user isn't there, so the background sync runs at 07:00,
12:00, 17:00 and 22:00; opening Money reads again with the user present (no limit). A Wallet tap and the bank's record
of the same payment are one payment: the bank's is matched to the tap (amount, a few days) and the tap keeps its clean
name and exact time. A pending card payment becomes its booked one in place.
"""

import asyncio
import hashlib
import logging
import re
import secrets
import time as clock
from collections.abc import Awaitable, Callable
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

import httpx
import jwt

from .db import utcnow
from .finance import FinanceStore, normalise

log = logging.getLogger(__name__)

API = "https://api.enablebanking.com"
SLOTS = (7, 12, 17, 22)  # local hours of the background reads: 4 a day, the PSD2 limit without the user
PRESENT_GAP = timedelta(minutes=2)  # opening Money again sooner doesn't read again
FIRST_DAYS = 90  # history read when a bank is linked
OVERLAP_DAYS = 10  # each read goes back this far before the last booked day (late bookings, pending → booked)
MATCH_BEFORE, MATCH_AFTER = timedelta(days=5), timedelta(days=1)  # a tap is up to 5 days before its booking
RENEW_DAYS = 7  # the consent's reminder
LINK_TTL = timedelta(minutes=30)
INCOME_PUSH = 10.0  # money in from this much is pushed
CONSENT_DAYS = 180

SCHEMA = """
CREATE TABLE IF NOT EXISTS finance_bank_links (
    state      TEXT PRIMARY KEY,
    bank       TEXT NOT NULL,
    country    TEXT NOT NULL,
    created_at TEXT NOT NULL
);
"""

# Words Italian banks put around the merchant in a card payment's text.
NOISE = [
    r"\bpagamento\s+(pos|con\s+carta|carta|apple\s*pay|google\s*pay|contactless|online)\b",
    r"\bpag\.?\s*(pos|carta)\b", r"\bpos\b", r"\bacquisto\b", r"\boperazione\b", r"\bdisposizione\b",
    r"\bcarta\s*(di\s+(credito|debito))?\s*(n\.?|nr\.?|num\.?)?\s*[*x\d][*x\d\s]*",
    r"[*x]{2,}\s*\d{2,4}\b",
    r"\b(del|il|in\s+data)\s+\d{1,2}[./-]\d{1,2}([./-]\d{2,4})?",
    r"\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b",
    r"\b(ore|alle)\s+\d{1,2}[.:]\d{2}\b", r"\b\d{1,2}:\d{2}(:\d{2})?\b",
    r"\b(eur|euro)\s*-?\d+([.,]\d+)*", r"-?\d+([.,]\d+)*\s*(eur|euro|€)", r"€\s*-?\d+([.,]\d+)*",
    r"\((ita|it|irl|ie|gbr|nld|deu|fra|esp|lux|usa)\)", r"\b(presso|c/o)\b", r"\bloc\.?\b",
    r"\babi\s*\d+\b", r"\bcab\s*\d+\b",
]
CASH = re.compile(r"\b(prelievo|prelevamento|atm|bancomat|cash\s+withdrawal)\b", re.I)


def clean_merchant(text: str) -> str:
    """The merchant out of a bank's text: "PAGAMENTO POS 12,50 EUR DEL 30.10.2026 ORE 12:31 ESSELUNGA TORINO CARTA
    N.****1234" → "Esselunga Torino"."""
    s = " ".join((text or "").split())
    for pattern in NOISE:
        s = re.sub(pattern, " ", s, flags=re.I)
    s = re.sub(r"\s*[-–|/]\s*(?=\s|$)", " ", s)
    s = " ".join(s.split()).strip(" -–|/.,;:")
    if not s:
        return " ".join((text or "").split())[:60] or "Bank"
    if s.isupper() or s.islower():
        s = " ".join(w if len(w) <= 3 and w.isupper() and not w.isalpha() else w.capitalize() for w in s.split())
    return s[:80]


class BankError(Exception):
    def __init__(self, status: int, code: str | None, message: str):
        super().__init__(message)
        self.status, self.code = status, code


class EnableBanking:
    """Enable Banking's API, signed with the application's private key (RS256 JWT, an hour at a time)."""

    def __init__(self, app_id: str, key_path: Path | str, http: httpx.AsyncClient | None = None):
        self.app_id = app_id
        self.key = Path(key_path).expanduser().read_text()
        self.http = http or httpx.AsyncClient(base_url=API, timeout=60)
        self._jwt: tuple[str, float] | None = None
        self._banks: dict[str, tuple[float, list[dict]]] = {}
        self._psu_ok = True  # the bank refused the user's address once (a tailnet one): read as unattended

    def token(self) -> str:
        if self._jwt and self._jwt[1] > clock.time() + 60:
            return self._jwt[0]
        now = int(clock.time())
        token = jwt.encode({"iss": "enablebanking.com", "aud": "api.enablebanking.com", "iat": now, "exp": now + 3600},
                           self.key, algorithm="RS256", headers={"kid": self.app_id})
        self._jwt = (token, now + 3600)
        return token

    async def _call(self, method: str, path: str, *, json: dict | None = None, params: dict | None = None,
                    psu: dict | None = None) -> dict:
        psu = psu if self._psu_ok else None
        headers = {"Authorization": f"Bearer {self.token()}", **(psu or {})}
        r = await self.http.request(method, path, json=json, params=params, headers=headers)
        if r.status_code >= 400:
            try:
                body = r.json()
            except ValueError:
                body = {}
            if psu and body.get("error") == "PSU_HEADER_INVALID":  # a tailnet address: read as unattended instead
                self._psu_ok = False
                return await self._call(method, path, json=json, params=params)
            raise BankError(r.status_code, body.get("error"),
                            str(body.get("message") or body.get("detail") or r.text)[:300])
        return r.json() if r.content else {}

    async def banks(self, country: str) -> list[dict]:
        """The banks of a country (cached a day)."""
        country = country.upper()
        cached = self._banks.get(country)
        if cached and cached[0] > clock.time():
            return cached[1]
        got = (await self._call("GET", "/aspsps", params={"country": country, "psu_type": "personal"})).get("aspsps", [])
        self._banks[country] = (clock.time() + 86400, got)
        return got

    async def start(self, bank: str, country: str, redirect: str, state: str, valid_until: datetime) -> str:
        body = {"access": {"valid_until": valid_until.isoformat()}, "aspsp": {"name": bank, "country": country},
                "state": state, "redirect_url": redirect, "psu_type": "personal"}
        return (await self._call("POST", "/auth", json=body))["url"]

    async def session(self, code: str) -> dict:
        return await self._call("POST", "/sessions", json={"code": code})

    async def close(self, session_id: str) -> None:
        await self._call("DELETE", f"/sessions/{session_id}")

    async def details(self, uid: str) -> dict:
        return await self._call("GET", f"/accounts/{uid}/details")

    async def balances(self, uid: str, psu: dict | None = None) -> list[dict]:
        return (await self._call("GET", f"/accounts/{uid}/balances", psu=psu)).get("balances", [])

    async def transactions(self, uid: str, date_from: date, psu: dict | None = None) -> list[dict]:
        out, key = [], None
        for _ in range(50):  # pages
            params = {"date_from": date_from.isoformat(), **({"continuation_key": key} if key else {})}
            page = await self._call("GET", f"/accounts/{uid}/transactions", params=params, psu=psu)
            out += page.get("transactions") or []
            key = page.get("continuation_key")
            if not key:
                break
        return out


def pick_balance(balances: list[dict], card: bool = False) -> tuple[float, str] | None:
    """The balance to show: what's available on an account, what's booked on a card (its available includes the
    credit limit)."""
    order = ("ITBD", "CLBD", "XPCD", "ITAV", "CLAV") if card else ("ITAV", "CLAV", "XPCD", "ITBD", "CLBD")
    by_type = {b.get("balance_type"): b for b in balances if b.get("balance_amount")}
    for kind in (*order, *by_type):
        if (b := by_type.get(kind)) is not None:
            try:
                return float(b["balance_amount"]["amount"]), b["balance_amount"].get("currency") or "EUR"
            except (TypeError, ValueError, KeyError):
                continue
    return None


def parse_tx(t: dict, uid: str, seen: dict[str, int]) -> dict | None:
    """A bank transaction in Finance's terms, or None for a cancelled, rejected or scheduled one."""
    status = t.get("status") or "BOOK"
    if status in ("CNCL", "RJCT", "SCHD"):
        return None
    try:
        amount = abs(float(t["transaction_amount"]["amount"]))
    except (TypeError, ValueError, KeyError):
        return None
    if amount == 0:
        return None
    indicator = t.get("credit_debit_indicator")
    if indicator == "DBIT" or (indicator is None and float(t["transaction_amount"]["amount"]) < 0):
        amount = -amount
    out = amount < 0
    day = t.get("booking_date") or t.get("transaction_date") or t.get("value_date")
    if not day:
        return None
    party = (t.get("creditor") if out else t.get("debtor")) or {}
    party_account = (t.get("creditor_account") if out else t.get("debtor_account")) or {}
    remittance = " ".join(r for r in (t.get("remittance_information") or []) if isinstance(r, str))
    name = (party.get("name") or "").strip()
    raw = " · ".join(x for x in (name, remittance) if x) or "Bank"
    merchant = clean_merchant(name or remittance)
    ident = t.get("transaction_id") or t.get("entry_reference")
    if not ident:  # no id from the bank: the same text, day and amount, counted
        base = hashlib.sha1(f"{day}|{amount}|{raw}".encode()).hexdigest()[:16]
        seen[base] = seen.get(base, 0) + 1
        ident = f"h{base}-{seen[base]}"
    mcc = str(t.get("merchant_category_code") or "")
    return {"ref": f"{uid}:{ident}", "amount": round(amount, 2),
            "currency": (t.get("transaction_amount") or {}).get("currency") or "EUR",
            "day": date.fromisoformat(str(day)[:10]), "merchant": merchant, "raw": raw[:300],
            "pending": status in ("PDNG", "HOLD"), "iban": party_account.get("iban"),
            "cash": mcc == "6011" or bool(CASH.search(raw))}


class Banks:
    """Linked banks, their accounts and the sync. `client` None: bank sync is off (no key on the server)."""

    def __init__(self, finance: FinanceStore, client: EnableBanking | None,
                 notify: Callable[[str, str, dict], Awaitable[object]] | None = None):
        self.finance = finance
        self.conn = finance.conn
        self.tz = finance.tz
        self.client = client
        self.notify = notify  # (title, body, extra) → a push
        self.conn.executescript(SCHEMA)
        self._lock = asyncio.Lock()

    @property
    def enabled(self) -> bool:
        return self.client is not None

    # -- linking --------------------------------------------------------------------------------

    async def banks(self, country: str = "IT") -> list[dict]:
        out = []
        for b in await self.client.banks(country):
            days = b.get("maximum_consent_validity")
            out.append({"name": b["name"], "country": b.get("country") or country.upper(), "logo": b.get("logo"),
                        "beta": bool(b.get("beta")),
                        "days": min(CONSENT_DAYS, int(days) // 86400) if days else CONSENT_DAYS})
        return sorted(out, key=lambda b: b["name"].lower())

    async def start_link(self, bank: str, country: str, redirect: str) -> str:
        """The bank's login page for this bank. Its answer comes back to `redirect` (the server's callback)."""
        country = country.upper()
        known = {b["name"]: b for b in await self.banks(country)}
        if bank not in known:
            raise ValueError(f"no bank called {bank!r} in {country}")
        self.conn.execute("DELETE FROM finance_bank_links WHERE created_at < ?",
                          ((utcnow() - LINK_TTL).isoformat(),))
        state = secrets.token_urlsafe(24)
        self.conn.execute("INSERT INTO finance_bank_links (state, bank, country, created_at) VALUES (?, ?, ?, ?)",
                          (state, bank, country, utcnow().isoformat()))
        until = utcnow() + timedelta(days=known[bank]["days"]) - timedelta(minutes=5)
        return await self.client.start(bank, country, redirect, state, until)

    async def finish_link(self, state: str, code: str, psu: dict | None = None) -> dict:
        """The bank said yes: keep the session and its accounts, replace an older link to the same bank, and read the
        last 90 days."""
        row = self.conn.execute("SELECT * FROM finance_bank_links WHERE state = ?", (state,)).fetchone()
        if not row or datetime.fromisoformat(row["created_at"]) < utcnow() - LINK_TTL:
            raise ValueError("this link has expired: start again from the app")
        self.conn.execute("DELETE FROM finance_bank_links WHERE state = ?", (state,))
        s = await self.client.session(code)
        until = (s.get("access") or {}).get("valid_until")
        old = self.conn.execute("SELECT * FROM finance_banks WHERE bank = ? AND country = ? AND status IN "
                                "('linked', 'expired')", (row["bank"], row["country"])).fetchall()
        cur = self.conn.execute(
            "INSERT INTO finance_banks (session_id, bank, country, valid_until, created_at) VALUES (?, ?, ?, ?, ?)",
            (s["session_id"], row["bank"], row["country"], until, utcnow().isoformat()))
        bank_id = cur.lastrowid
        hashes = {a.get("uid"): a.get("identification_hash") for a in s.get("accounts_data") or []}
        for a in s.get("accounts") or []:
            if isinstance(a, str):  # an older answer: the uid alone
                a = {"uid": a, **(await self.client.details(a))}
            self._keep_account(bank_id, row["bank"], a, until, hashes.get(a.get("uid")))
        for o in old:
            self.conn.execute("UPDATE finance_banks SET status = 'replaced' WHERE id = ?", (o["id"],))
            try:
                await self.client.close(o["session_id"])
            except Exception as e:  # noqa: BLE001 — it ends by itself anyway
                log.info("closing the old %s session failed: %s", o["bank"], e)
        await self.sync(bank_id, psu=psu, first=True)
        return self.bank(bank_id)

    def _keep_account(self, bank_id: int, bank: str, a: dict, until: str | None, ident: str | None) -> None:
        ident = a.get("identification_hash") or ident
        iban = (a.get("account_id") or {}).get("iban")
        card = (a.get("cash_account_type") or "").upper() == "CARD"
        name = a.get("name") or a.get("product") or a.get("details") or bank
        name = name if bank.lower() in name.lower() else f"{bank} {name}"
        if iban:
            name += f" ··{iban[-4:]}"
        found = None
        for col, value in (("ident", ident), ("iban", iban)):
            if value and not found:
                found = self.conn.execute(f"SELECT id FROM finance_accounts WHERE {col} = ?", (value,)).fetchone()
        acc_id = found["id"] if found else self.finance.account(name, "bank", "card" if card else "account")["id"]
        self.conn.execute("UPDATE finance_accounts SET source = 'bank', kind = ?, bank_id = ?, uid = ?, ident = ?, "
                          "iban = ?, currency = ?, consent_until = ? WHERE id = ?",
                          ("card" if card else "account", bank_id, a["uid"], ident, iban, a.get("currency") or "EUR",
                           until, acc_id))

    async def unlink(self, bank_id: int) -> bool:
        b = self.conn.execute("SELECT * FROM finance_banks WHERE id = ?", (bank_id,)).fetchone()
        if not b:
            return False
        try:
            await self.client.close(b["session_id"])
        except Exception as e:  # noqa: BLE001
            log.info("closing the %s session failed: %s", b["bank"], e)
        self.conn.execute("UPDATE finance_banks SET status = 'unlinked' WHERE id = ?", (bank_id,))
        self.conn.execute("UPDATE finance_accounts SET uid = NULL, consent_until = NULL WHERE bank_id = ?", (bank_id,))
        return True

    # -- status ---------------------------------------------------------------------------------

    def bank(self, bank_id: int) -> dict:
        b = self.conn.execute("SELECT * FROM finance_banks WHERE id = ?", (bank_id,)).fetchone()
        days_left = None
        if b["valid_until"]:
            days_left = max(0, (datetime.fromisoformat(b["valid_until"]) - utcnow()).days)
        status = b["status"]
        if status == "linked" and days_left is not None and days_left <= RENEW_DAYS:
            status = "renew"
        accounts = [a["id"] for a in self.conn.execute("SELECT id FROM finance_accounts WHERE bank_id = ? AND "
                                                       "uid IS NOT NULL", (bank_id,))]
        return {"id": b["id"], "bank": b["bank"], "country": b["country"], "status": status,
                "valid_until": b["valid_until"], "days_left": days_left, "last_sync_at": b["last_sync_at"],
                "error": b["error"], "accounts": accounts}

    def linked(self) -> list[dict]:
        return [self.bank(r["id"]) for r in self.conn.execute(
            "SELECT id FROM finance_banks WHERE status IN ('linked', 'expired') ORDER BY bank COLLATE NOCASE")]

    # -- the sync -------------------------------------------------------------------------------

    async def sync_all(self, psu: dict | None = None, force: bool = False) -> dict:
        """Read every linked bank now (the user is in the app: `psu` has their headers). Skipped within 2 minutes of
        the last read unless `force`."""
        new = 0
        for b in self.conn.execute("SELECT * FROM finance_banks WHERE status = 'linked'").fetchall():
            if not force and b["last_sync_at"] and datetime.fromisoformat(b["last_sync_at"]) > utcnow() - PRESENT_GAP:
                continue
            new += await self.sync(b["id"], psu=psu)
        return {"new": new, "banks": self.linked()}

    async def sync(self, bank_id: int, psu: dict | None = None, first: bool = False) -> int:
        """Read one bank's accounts: balances and transactions. Returns how many payments are new."""
        async with self._lock:
            b = self.conn.execute("SELECT * FROM finance_banks WHERE id = ?", (bank_id,)).fetchone()
            new_rows: list[dict] = []
            try:
                for acc in self.conn.execute("SELECT * FROM finance_accounts WHERE bank_id = ? AND uid IS NOT NULL",
                                             (bank_id,)).fetchall():
                    new_rows += await self._sync_account(dict(acc), psu, first)
            except BankError as e:
                if e.code in ("EXPIRED_SESSION", "REVOKED_SESSION", "CLOSED_SESSION") or e.status == 401 and \
                        "session" in str(e).lower():
                    self.conn.execute("UPDATE finance_banks SET status = 'expired', error = NULL WHERE id = ?",
                                      (bank_id,))
                    log.info("%s: the consent ended", b["bank"])
                else:
                    self.conn.execute("UPDATE finance_banks SET error = ? WHERE id = ?",
                                      ("The bank asked to wait: it reads again later." if
                                       e.code == "ASPSP_RATE_LIMIT_EXCEEDED" else str(e)[:200], bank_id))
                    log.warning("%s sync failed: %s %s", b["bank"], e.status, e.code)
                return 0
            except httpx.HTTPError as e:
                self.conn.execute("UPDATE finance_banks SET error = ? WHERE id = ?", ("Couldn't reach the bank.",
                                                                                     bank_id))
                log.warning("%s sync failed: %s", b["bank"], type(e).__name__)
                return 0
            self.conn.execute("UPDATE finance_banks SET last_sync_at = ?, error = NULL WHERE id = ?",
                              (utcnow().isoformat(), bank_id))
            self._mark_transfers()
        if new_rows:
            asyncio.create_task(self.finance.sort_pending())
            if psu is None and self.notify:  # the user isn't in the app: say when money comes in
                for tx in new_rows:
                    if tx["category"] == "income" and tx["amount"] >= INCOME_PUSH:
                        await self.notify("Money in", f"{_eur(tx['amount'])} from {tx['merchant']}",
                                          {"payment_id": tx["id"]})
        return len(new_rows)

    async def _sync_account(self, acc: dict, psu: dict | None, first: bool) -> list[dict]:
        uid = acc["uid"]
        got = pick_balance(await self.client.balances(uid, psu), acc["kind"] == "card")
        if got:
            self.conn.execute("UPDATE finance_accounts SET balance = ?, currency = ?, balance_at = ? WHERE id = ?",
                              (got[0], got[1], utcnow().isoformat(), acc["id"]))
        last = self.conn.execute("SELECT MAX(at) AS at FROM finance_transactions WHERE account_id = ? AND source = "
                                 "'bank' AND pending = 0", (acc["id"],)).fetchone()["at"]
        if first or not last:
            since = self.finance.today() - timedelta(days=FIRST_DAYS)
        else:
            since = self.finance.local(last).date() - timedelta(days=OVERLAP_DAYS)
        seen: dict[str, int] = {}
        txs = [p for t in await self.client.transactions(uid, since, psu) if (p := parse_tx(t, uid, seen))]
        new, refs = [], set()
        for p in sorted(txs, key=lambda p: (p["day"], p["pending"])):
            refs.add(p["ref"])
            tx, is_new = self.add(acc["id"], p)
            if is_new:
                new.append(tx)
        # pending ones the bank no longer lists were cancelled or booked under another id (and matched above)
        for r in self.conn.execute("SELECT id, ref FROM finance_transactions WHERE account_id = ? AND source = 'bank' "
                                   "AND pending = 1 AND at >= ?", (acc["id"], self.finance._utc(since))).fetchall():
            if r["ref"] not in refs:
                self.conn.execute("DELETE FROM finance_transactions WHERE id = ?", (r["id"],))
        return new

    def add(self, account_id: int, p: dict) -> tuple[dict, bool]:
        """One bank transaction: already known (its id), the booked one of a pending one, the bank's record of a Wallet
        tap, or new."""
        f = self.finance
        known = self.conn.execute("SELECT * FROM finance_transactions WHERE ref = ?", (p["ref"],)).fetchone()
        if known:
            if known["pending"] and not p["pending"]:
                self.conn.execute("UPDATE finance_transactions SET pending = 0, at = ?, raw = ? WHERE id = ?",
                                  (self._at(p["day"], known["at"]), p["raw"], known["id"]))
            return f.find(known["id"]), False
        lo = f._utc(p["day"] - MATCH_BEFORE)
        hi = f._utc(p["day"] + MATCH_AFTER + timedelta(days=1))
        if not p["pending"]:  # the booked one of a pending payment
            row = self._closest("SELECT * FROM finance_transactions WHERE account_id = ? AND source = 'bank' AND "
                                "pending = 1 AND amount = ? AND at BETWEEN ? AND ?",
                                (account_id, p["amount"], lo, hi), p)
            if row:
                self.conn.execute("UPDATE finance_transactions SET ref = ?, pending = 0, at = ?, raw = ? WHERE id = ?",
                                  (p["ref"], self._at(p["day"], row["at"]), p["raw"], row["id"]))
                return f.find(row["id"]), False
        row = self._closest("SELECT * FROM finance_transactions WHERE source = 'wallet' AND ref IS NULL AND amount = ? "
                            "AND at BETWEEN ? AND ?", (p["amount"], lo, hi), p)
        if row:  # the tap: keep its name and time, remember the bank's record
            self.conn.execute("UPDATE finance_transactions SET ref = ?, raw = ? WHERE id = ?",
                              (p["ref"], p["raw"], row["id"]))
            return f.find(row["id"]), False
        own = p["iban"] and self.conn.execute("SELECT 1 FROM finance_accounts WHERE iban = ?",
                                              (p["iban"],)).fetchone()
        category, sorted_by = "other", "none"
        if own:
            category, sorted_by = "transfer", "rule"
        elif p["cash"] and p["amount"] < 0:
            category, sorted_by = "cash", "rule"
        elif (r := f.rule(p["merchant"])) is not None:
            category, sorted_by = r["category"], "rule"
        elif p["amount"] > 0:
            category, sorted_by = "income", "rule"
        cur = self.conn.execute(
            "INSERT INTO finance_transactions (account_id, at, amount, currency, merchant, raw, category, sorted_by, "
            "source, ref, pending, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'bank', ?, ?, ?)",
            (account_id, self._at(p["day"]), p["amount"], p["currency"], p["merchant"], p["raw"], category, sorted_by,
             p["ref"], int(p["pending"]), utcnow().isoformat()))
        return f.find(cur.lastrowid), True

    def _closest(self, sql: str, args: tuple, p: dict):
        """Of the rows that could be this one, the nearest in time, then the one with the most alike name."""
        rows = self.conn.execute(sql, args).fetchall()
        if not rows:
            return None
        key = set(normalise(p["merchant"]).split())
        noon = datetime.combine(p["day"], time(12), self.tz)
        return min(rows, key=lambda r: (-len(key & set(normalise(r["merchant"]).split())),
                                        abs((self.finance.local(r["at"]) - noon).total_seconds())))

    def _at(self, day: date, before: str | None = None) -> str:
        """A bank's day as a time: the earlier one's time when it was that day, else noon."""
        if before and self.finance.local(before).date() == day:
            return before
        return datetime.combine(day, time(12), self.tz).astimezone(timezone.utc).isoformat()

    def _mark_transfers(self) -> None:
        """Money out of one linked account and the same into another within 3 days: a transfer, not spending or
        income (unless the user sorted it)."""
        rows = self.conn.execute(
            "SELECT o.id AS o, i.id AS i FROM finance_transactions o JOIN finance_transactions i ON i.amount = -o.amount "
            "AND i.account_id != o.account_id AND julianday(i.at) BETWEEN julianday(o.at) - 3 AND julianday(o.at) + 3 "
            "WHERE o.source = 'bank' AND i.source = 'bank' AND o.amount < 0 AND NOT (o.category = 'transfer' AND "
            "i.category = 'transfer') AND o.sorted_by != 'user' AND i.sorted_by != 'user' AND o.at >= ?",
            (f"{(utcnow() - timedelta(days=FIRST_DAYS + 5)).isoformat()}",)).fetchall()
        done: set[int] = set()
        for r in rows:
            if r["o"] in done or r["i"] in done:
                continue
            done |= {r["o"], r["i"]}
            self.conn.execute("UPDATE finance_transactions SET category = 'transfer', sorted_by = 'rule' WHERE id IN "
                              "(?, ?)", (r["o"], r["i"]))

    # -- the schedule ---------------------------------------------------------------------------

    def due_slot(self, now: datetime | None = None) -> datetime | None:
        """The latest background slot that has come (local), or None before the first today."""
        now = (now or datetime.now(self.tz)).astimezone(self.tz)
        passed = [h for h in SLOTS if h <= now.hour]
        if not passed:
            return datetime.combine(now.date() - timedelta(days=1), time(SLOTS[-1]), self.tz)
        return datetime.combine(now.date(), time(passed[-1]), self.tz)

    async def tick(self, now: datetime | None = None) -> None:
        slot = self.due_slot(now)
        for b in self.conn.execute("SELECT * FROM finance_banks WHERE status = 'linked'").fetchall():
            info = self.bank(b["id"])
            if info["status"] == "renew" and not b["reminded"] and self.notify:
                self.conn.execute("UPDATE finance_banks SET reminded = 1 WHERE id = ?", (b["id"],))
                day = self.finance.local(b["valid_until"])
                await self.notify(f"Renew {b['bank']}",
                                  f"Aide can read {b['bank']} until {day:%-d %b}. Renewing is one login.",
                                  {"bank_id": b["id"]})
            if b["valid_until"] and datetime.fromisoformat(b["valid_until"]) <= utcnow():
                self.conn.execute("UPDATE finance_banks SET status = 'expired' WHERE id = ?", (b["id"],))
                continue
            if slot is None or (b["last_slot_at"] and datetime.fromisoformat(b["last_slot_at"]) >= slot):
                continue
            if b["last_sync_at"] and datetime.fromisoformat(b["last_sync_at"]) >= slot.astimezone(timezone.utc) \
                    - timedelta(minutes=30) and b["last_slot_at"]:
                # read with the user there just before the slot: this slot isn't needed
                self.conn.execute("UPDATE finance_banks SET last_slot_at = ? WHERE id = ?", (slot.isoformat(), b["id"]))
                continue
            self.conn.execute("UPDATE finance_banks SET last_slot_at = ? WHERE id = ?", (slot.isoformat(), b["id"]))
            await self.sync(b["id"])

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:  # noqa: BLE001 — try again next minute
                log.exception("bank sync")
            await asyncio.sleep(60)


def _eur(v: float) -> str:
    return f"€{abs(v):,.2f}".replace(".00", "")
