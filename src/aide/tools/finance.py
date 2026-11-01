"""Finance's tools: payments (from the Wallet taps, or told in chat), the month, the budget and subscriptions."""

from datetime import date, datetime, timedelta

from ..finance import CATEGORIES, NOT_SPENDING, FinanceStore, describe_tx, euros, normalise
from . import Tool, ToolOutput

CARD_MAX = 12  # payments shown as a card under the reply
SPENDING_CATS = [c for c in CATEGORIES if c not in NOT_SPENDING]


def payments_card(rows: list[dict]) -> dict:
    return {"type": "payments", "payments": rows[:CARD_MAX]}


def describe_month(m: dict) -> str:
    name = datetime.strptime(m["month"], "%Y-%m").strftime("%B %Y")
    lines = [f"{name}{' so far (day %d of %d)' % (m['day'], m['days']) if m['current'] else ''}: "
             f"{euros(m['spent'])} spent in {m['count']} payments."]
    if m["income"]:
        lines.append(f"Income: {euros(m['income'])}.")
    if m["budget"]:
        lines.append(f"Budget {euros(m['budget'])}: " + (f"{euros(m['left'])} left, about {euros(m['per_day'])} a day "
                                                          f"for {m['days_left']} days." if m["left"] > 0 else
                                                          f"{euros(-m['left'])} over."))
    else:
        lines.append("No monthly budget set.")
    last = m["last_month"]
    if last["by_now"] is not None:
        lines.append(f"Last month by the same day: {euros(last['by_now'])} (whole month {euros(last['total'])}).")
    for c in m["categories"]:
        if not (c["spent"] or c["budget"] or c["last_total"]):
            continue
        bits = [f"{euros(c['spent'])}"]
        if c["budget"]:
            bits.append(f"budget {euros(c['budget'])}" + (", over" if c["over"] else ", ahead of pace" if c["ahead"]
                                                            else ""))
        bits.append(f"last month by now {euros(c['last_by_now'])}")
        lines.append(f"- {c['name']}: {', '.join(bits)}")
    return "\n".join(lines)


def finance_tools(store: FinanceStore, banks=None) -> list[Tool]:
    async def log_payment(amount: float, merchant: str, income: bool = False, category: str | None = None,
                          paid_at: str | None = None, account: str | None = None, note: str | None = None,
                          cash: bool = False) -> str:
        value = abs(amount) if income else -abs(amount)
        if cash:
            account = "Cash"
        tx, new = store.add(value, merchant, account=account, at=paid_at, source="manual",
                            category=category or ("income" if income else None), note=note)
        if new and tx["sorted_by"] == "none":
            await store.sort_pending()
            tx = store.find(tx["id"])
        text = ("Logged" if new else "Already logged") + f": {describe_tx(tx, store.tz)[2:]}"
        return ToolOutput(text, attachment=payments_card([tx]))

    async def list_payments(days: int = 30, category: str | None = None, merchant: str | None = None,
                            start: str | None = None, end: str | None = None) -> str:
        last = date.fromisoformat(end) if end else store.today()
        first = date.fromisoformat(start) if start else last - timedelta(days=max(1, min(int(days), 400)) - 1)
        rows = store.between(first, last, category=category, merchant=merchant)
        if not rows:
            return f"No payments from {first} to {last}" + (f" in {category}" if category else "") + "."
        spent = -sum(r["amount"] for r in rows if r["category"] not in NOT_SPENDING)
        head = f"{len(rows)} payments from {first} to {last}, {euros(spent)} spent (newest first):"
        lines = [describe_tx(r, store.tz) for r in rows[:150]]
        if len(rows) > 150:
            lines.append(f"…and {len(rows) - 150} older.")
        return ToolOutput("\n".join([head, *lines]), attachment=payments_card(rows))

    async def spending(month: str | None = None) -> str:
        return describe_month(store.month(month))

    async def recategorize(payment_id: int, category: str, remember: bool = True) -> str:
        tx = store.update(payment_id, category=category, remember=remember)
        text = f"{tx['merchant']} is now {CATEGORIES[category][0].lower()}"
        return ToolOutput(text + (", and its other payments with it." if remember else "."),
                          attachment=payments_card([tx]))

    async def set_budget(monthly: float | None = None, categories: list[dict] | None = None) -> str:
        changes = {}
        kwargs = {}
        if monthly is not None:
            kwargs["monthly"] = monthly if monthly > 0 else None
        for c in categories or []:
            changes[c["category"]] = c["amount"] if c["amount"] > 0 else None
        b = store.set_budget(categories=changes, **kwargs)
        parts = [f"Monthly budget: {euros(b['monthly'])}" if b["monthly"] else "No monthly budget"]
        parts += [f"{CATEGORIES[k][0]} {euros(v)}" for k, v in b["categories"].items()]
        return "; ".join(parts) + "."

    async def subscriptions() -> str:
        s = store.subscriptions()
        if not s["subscriptions"]:
            return "No repeated charges found yet (it takes two charges, or one sorted as a subscription)."
        lines = [f"About {euros(s['monthly_total'])} a month in repeated charges, next first:"]
        for x in s["subscriptions"]:
            was = f", was {euros(x['price_was'])}" if x["price_was"] else ""
            last = f"last {x['last']} ({x['count']} charges)" if x["last"] else "no charge on record yet"
            mine = ", set by the user" if x["mine"] else ""
            lines.append(f"- {x['merchant']}: {euros(x['amount'])} a {x['period']}{was}, next {x['next']}, {last}{mine}")
        if s["hidden"]:
            lines.append("Not subscriptions (the user said): " + ", ".join(h["merchant"] for h in s["hidden"]))
        return "\n".join(lines)

    async def set_subscription(merchant: str, is_subscription: bool | None = True, amount: float | None = None,
                               period: str | None = None, next_charge: str | None = None) -> str:
        try:
            nxt = date.fromisoformat(next_charge) if next_charge else None
            store.set_subscription(merchant, is_subscription, amount, period, nxt)
        except ValueError as e:
            return f"Not changed: {e}"
        if is_subscription is False:
            return f"{merchant} is no longer listed as a subscription."
        if is_subscription is None:
            return f"{merchant}: back to what the charges show."
        key = normalise(merchant) or merchant.strip().lower()
        x = next((x for x in store.subscriptions()["subscriptions"] if x["key"] == key), None)
        return (f"{x['merchant']}: {euros(x['amount'])} a {x['period']}, next {x['next']}." if x
                else f"{merchant} saved as a subscription.")

    async def card_owed(owed: float, last4: str | None = None) -> str:
        a = store.set_owed(owed, last4)
        if banks is not None:
            banks.mark_card()
        a = next(x for x in store.accounts() if x["id"] == a["id"])
        return (f"Following {a['name']} from now: {euros(-a['balance'])} owed. Its Apple Pay taps are the spending from "
                f"here, and payoffs move money to it." + ("" if a.get("last4") else " Its last 4 digits aren't known, "
                                                          "so top-ups drawn from it aren't counted against it yet."))

    async def accounts() -> str:
        if banks is not None and banks.enabled:
            await banks.sync_all()  # within 2 minutes of the last read this reads nothing
        lines = []
        for a in store.accounts():
            if a["kind"] == "credit":
                lines.append(f"- {a['name']} (credit card, followed by Aide): " + (
                    f"{euros(-a['balance'])} owed" if a["balance"] is not None and a["balance"] <= 0 else
                    f"{euros(a['balance'])} in credit" if a["balance"] is not None else
                    "what's owed isn't known: ask the user, then card_owed") + (
                    f"; ends in {a['last4']}" if a.get("last4") else ""))
                continue
            if a["balance"] is not None:
                when = store.local(a["balance_at"]).strftime("%a %d %b %H:%M") if a["balance_at"] else "?"
                line = f"- {a['name']} ({a['kind']}): {'-' if a['balance'] < 0 else ''}{euros(a['balance'])}, " \
                       f"as of {when}"
            else:
                line = f"- {a['name']} ({a['kind']}): no balance (from {a['source']})"
            status = {"renew": "the bank link ends within a week: renew it in Money", "expired": "the bank link "
                      "ended: link it again in Money", "unlinked": "not linked any more"}.get(a["status"])
            if a["hidden"]:
                status = (f"{status}; " if status else "") + "hidden from Money's accounts and total by the user"
            lines.append(line + (f"; {status}" if status else ""))
        if not lines:
            return "No accounts yet. Banks are linked in the app: Money → Accounts → Link a bank."
        if banks is None or not banks.linked():
            lines.append("No bank is linked, so there are no balances (Money → Accounts → Link a bank).")
        return "\n".join(lines)

    async def delete_payment(payment_id: int) -> str:
        tx = store.find(payment_id)
        store.delete(payment_id)
        return f"Deleted the {euros(tx['amount'])} payment to {tx['merchant']}."

    async def describe_delete(payment_id: int) -> str:
        tx = store.find(payment_id)
        return f"Delete the {euros(tx['amount'])} payment to {tx['merchant']} ({store.local(tx['at']):%a %d %b})"

    category = {"type": "string", "enum": list(CATEGORIES)}
    return [
        Tool("log_payment", "Log a payment the user tells you about (\"8 euro for pizza\", cash, a bank transfer). "
             "Apple Pay taps come in by themselves, so don't log those twice. Sorted by the merchant's rule or the "
             "model unless you give the category. Runs immediately.",
             {"type": "object", "properties": {
                 "amount": {"type": "number", "description": "Euros, positive"},
                 "merchant": {"type": "string", "description": "Who was paid (or who paid, for income)"},
                 "income": {"type": "boolean", "description": "True for money received"},
                 "category": {**category, "description": "Only when the user says or it's obvious"},
                 "paid_at": {"type": "string", "description": "Local time as YYYY-MM-DDTHH:MM. Omit for now."},
                 "account": {"type": "string", "description": "The card or account, if said"},
                 "cash": {"type": "boolean", "description": "Paid in cash: it takes its share out of the cash "
                                                            "withdrawals, which already counted as spending"},
                 "note": {"type": "string"}},
              "required": ["amount", "merchant"], "additionalProperties": False}, log_payment),
        Tool("card_owed", "Set what the user owes on Carta YOU (Advanzia's credit card, which no bank link reads) right "
             "now, when they tell you, and its last 4 digits if said. From then on its Apple Pay taps are the spending "
             "and payoffs only move money to it, so what's owed follows. Runs immediately.",
             {"type": "object", "properties": {
                 "owed": {"type": "number", "description": "Euros owed now (0 if nothing)"},
                 "last4": {"type": "string", "description": "The card's last 4 digits"}},
              "required": ["owed"], "additionalProperties": False}, card_owed),
        Tool("list_payments", "The user's payments, newest first, with category, card and place ([payment N]): the "
             "last `days`, or from start to end; filter by category or merchant. Shows them as a card.",
             {"type": "object", "properties": {
                 "days": {"type": "integer", "description": "How many days back (default 30)"},
                 "start": {"type": "string", "description": "YYYY-MM-DD, instead of days"},
                 "end": {"type": "string", "description": "YYYY-MM-DD (default today)"},
                 "category": category,
                 "merchant": {"type": "string", "description": "Part of the merchant's name"}},
              "additionalProperties": False}, list_payments),
        Tool("spending", "A month at a glance: spent, income, the budget and what's left a day, last month by the same "
             "day, and each category against its budget and last month.",
             {"type": "object", "properties": {"month": {"type": "string", "description": "YYYY-MM (default this "
                                                                                          "month)"}},
              "additionalProperties": False}, spending),
        Tool("recategorize", "Move a payment to another category. By default the merchant's other payments move too "
             "and future ones follow (a rule); remember=false for this one alone. Runs immediately.",
             {"type": "object", "properties": {"payment_id": {"type": "integer"}, "category": category,
                                               "remember": {"type": "boolean"}},
              "required": ["payment_id", "category"], "additionalProperties": False}, recategorize),
        Tool("set_budget", "Set the monthly budget and/or budgets per category, only when the user asks. Budgets are "
             "optional; 0 removes one. Runs immediately.",
             {"type": "object", "properties": {
                 "monthly": {"type": "number", "description": "Euros a month for everything; 0 removes it"},
                 "categories": {"type": "array", "items": {"type": "object", "properties": {
                     "category": {"type": "string", "enum": SPENDING_CATS}, "amount": {"type": "number"}},
                     "required": ["category", "amount"], "additionalProperties": False}}},
              "additionalProperties": False}, set_budget),
        Tool("subscriptions", "Charges that repeat each week, month or year (and anything sorted as a subscription): "
             "the price, when the next one is, price changes, and the monthly total.",
             {"type": "object", "properties": {}, "additionalProperties": False}, subscriptions),
        Tool("set_subscription", "What the user says about a subscription: one that is (add it, or fix its price, how "
             "often or the next charge; one with no charges on record needs all three), one that isn't "
             "(is_subscription false: never listed again), or null to go back to what the charges show. Use the "
             "merchant's name as subscriptions lists it.",
             {"type": "object", "properties": {
                 "merchant": {"type": "string"},
                 "is_subscription": {"type": ["boolean", "null"]},
                 "amount": {"type": "number", "description": "The price each time, in euros"},
                 "period": {"type": "string", "enum": ["week", "month", "year"]},
                 "next_charge": {"type": "string", "description": "YYYY-MM-DD"}},
              "required": ["merchant", "is_subscription"], "additionalProperties": False}, set_subscription),
        Tool("accounts", "The user's accounts and cards: each balance from the bank (read now if the last read is "
             "older than 2 minutes) and the bank link's state. Read-only: Aide can't move money.",
             {"type": "object", "properties": {}, "additionalProperties": False}, accounts),
        Tool("delete_payment", "Delete a payment logged by mistake or twice ([payment N]). Needs the user's "
             "confirmation: it is queued, and runs only when the user replies !yes.",
             {"type": "object", "properties": {"payment_id": {"type": "integer"}}, "required": ["payment_id"],
              "additionalProperties": False}, delete_payment, confirm=True, describe=describe_delete,
             target_arg="payment_id"),
    ]
