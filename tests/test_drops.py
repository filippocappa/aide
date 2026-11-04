"""Timed drops: an errand that gets ready ahead, has its limits confirmed once, and buys at the sale inside them."""
from datetime import datetime, timedelta, timezone

import pytest

from aide.agent import CONVERSATION
from aide.db import utcnow
from aide.errands import DROP_LEAD, drop_mismatch, no_bots, order_total, plan_drop
from test_agents import ROME, calls
from test_errands import THANKS, env, runner_ttl  # noqa: F401  (env is a fixture)

PRODUCT = "https://www.amazon.it/dp/B0SWITCH2"
DCART = "https://www.amazon.it/cart?drop"
DCHECKOUT = "https://www.amazon.it/checkout?drop"


def drop_pages(browser, total="469,99 €"):
    browser.pages[PRODUCT] = ("Nintendo Switch 2", "Nintendo Switch 2 Nero. Disponibile ora. 469,99 €", {
        "20": {"text": "Aggiungi al carrello", "goes": DCART}})
    browser.pages[DCART] = ("Carrello", "Nintendo Switch 2 Nero. Subtotale 469,99 €", {
        "21": {"text": "Procedi all'ordine", "goes": DCHECKOUT}})
    browser.pages[DCHECKOUT] = ("Checkout", f"Nintendo Switch 2 - Nero, quantità 1. Spedizione: 0,00 €. "
                                f"Totale ordine: {total}", {"22": {"text": "Acquista ora", "goes": THANKS}})


ARM = ("arm_drop", {"summary": "1 Nintendo Switch 2, black", "item": "Nintendo Switch 2", "variant": "Nero",
                    "quantity": 1, "max_total": "480,00 €", "address": "Via Roma 1, Torino",
                    "card": "Visa ending 6411"})


def local(when: datetime) -> str:
    return when.astimezone(ROME).replace(tzinfo=None).isoformat(timespec="minutes")


async def armed(runner, agent, db, browser):
    """A drop an hour away, got ready and confirmed: (errand, its pending action)."""
    drop_pages(browser)
    opens = utcnow() + timedelta(hours=1)
    e = runner.start("Buy one Nintendo Switch 2, black, at the drop", "Switch 2", "amazon.it", CONVERSATION,
                     drop_at=local(opens), max_total="500 €")
    assert e["timed_drop"]["armed"] is False
    e = runner.store.get(runner.queue.get_nowait())
    await runner._phase(e)
    e = runner.store.get(e["id"])
    assert e["status"] == "waiting_confirm" and browser.clicked == []
    [action] = db.pending_actions(CONVERSATION, runner_ttl())
    return e, action


async def test_a_drop_gets_ready_then_buys_inside_the_limits(env):  # noqa: F811
    make, db, browser = env
    runner, agent, _ = make([
        calls(("open_page", {"url": PRODUCT})),
        calls(ARM),
        # At the sale:
        calls(("open_page", {"url": PRODUCT})),
        calls(("wait_for_drop", {"text": "Disponibile ora"})),
        calls(("click", {"ref": "20"})),
        calls(("click", {"ref": "21"})),
        calls(("click", {"ref": "22"})),  # allowed: inside the limits
        calls(("record_order", {"total": "469,99 €", "items": [{"title": "Nintendo Switch 2", "quantity": 1,
                                                                 "price": "469,99 €", "image": None}],
                                "order_number": "402-9", "delivery": None})),
        calls(("finish", {"result": "Bought the Switch 2 at the drop, 469,99 €.", "ok": True, "products": None})),
    ])
    e, action = await armed(runner, agent, db, browser)
    assert action["tool"] == "errand_drop"
    d = action["detail"]
    assert d["kind"] == "drop" and d["max_total"] == "480,00 €" and d["variant"] == "Nero"
    assert d["card"] == "Visa ending 6411" and d["opens_at"].startswith(local(utcnow() + timedelta(hours=1))[:13])
    # It waits past the usual 30 minutes: until the window closes.
    assert datetime.fromisoformat(action["expires_at"]) > utcnow() + timedelta(hours=2)

    # A chat's "yes" (Confirm all) doesn't answer it: only its own card does.
    assert await agent.confirm(CONVERSATION) == "Nothing is waiting for confirmation."
    out = await agent.confirm(CONVERSATION, [action["id"]])
    assert "Buying at" in out or "Set:" in out
    e = runner.store.get(e["id"])
    assert e["status"] == "scheduled" and e["timed_drop"]["armed"]
    opens = datetime.fromisoformat(e["timed_drop"]["opens_at"])
    assert datetime.fromisoformat(e["wake_at"]) == opens - DROP_LEAD
    assert runner.store.as_json(e)["drop"]["max_total"] == "480,00 €"

    # Not yet: nothing starts.
    await runner._due_drops()
    assert runner._dropping == {}

    # The sale is open: the drop runs beside the queue.
    now = utcnow()
    runner.store.update(e["id"], wake_at=(now - timedelta(seconds=1)).isoformat(),
                        timed_drop={**e["timed_drop"], "opens_at": (now - timedelta(seconds=30)).isoformat()})
    await runner._due_drops()
    await runner._dropping[e["id"]]
    e = runner.store.get(e["id"])
    assert e["status"] == "done", e["result"]
    assert browser.clicked == ["Aggiungi al carrello", "Procedi all'ordine", "Acquista ora"]
    [p] = runner.store.purchases()
    assert p["amount"] == 469.99 and p["order_ref"] == "402-9"


async def test_a_drop_over_its_limit_isnt_placed(env):  # noqa: F811
    make, db, browser = env
    runner, agent, _ = make([
        calls(("open_page", {"url": PRODUCT})),
        calls(ARM),
        calls(("open_page", {"url": DCHECKOUT})),
        calls(("click", {"ref": "22"})),  # refused: 499,99 € is over 480,00 €
        calls(("finish", {"result": "The total was over your limit, so I didn't buy.", "ok": False,
                          "products": None})),
    ])
    e, action = await armed(runner, agent, db, browser)
    await agent.confirm(CONVERSATION, [action["id"]])
    drop_pages(browser, total="499,99 €")
    now = utcnow()
    e = runner.store.get(e["id"])
    runner.store.update(e["id"], wake_at=now.isoformat(),
                        timed_drop={**e["timed_drop"], "opens_at": (now - timedelta(seconds=30)).isoformat()})
    await runner._due_drops()
    await runner._dropping[e["id"]]
    assert "Acquista ora" not in browser.clicked
    refused = [r for r in runner.client.requests[4]["messages"][-1]["content"] if r["type"] == "tool_result"][0]
    assert refused["is_error"] and "over the limit" in refused["content"][0]["text"]


async def test_the_errand_cant_raise_the_users_limit(env):  # noqa: F811
    make, db, browser = env
    drop_pages(browser)
    runner, _, _ = make([
        calls(("open_page", {"url": PRODUCT})),
        calls(("arm_drop", {**ARM[1], "max_total": "550,00 €"})),  # over the user's 500 €
        calls(("finish", {"result": "Stopped.", "ok": False, "products": None})),
    ])
    runner.start("Buy one at the drop", "Switch 2", "amazon.it", CONVERSATION,
                 drop_at=local(utcnow() + timedelta(hours=1)), max_total="500 €")
    e = runner.store.get(runner.queue.get_nowait())
    await runner._phase(e)
    refused = [r for r in runner.client.requests[2]["messages"][-1]["content"] if r["type"] == "tool_result"][0]
    assert refused["is_error"] and "500 €" in refused["content"][0]["text"]
    assert db.pending_actions(CONVERSATION, runner_ttl()) == []


async def test_a_missed_drop_and_a_cancelled_one(env):  # noqa: F811
    make, db, browser = env
    runner, agent, _ = make([calls(("open_page", {"url": PRODUCT})), calls(ARM)])
    e, action = await armed(runner, agent, db, browser)
    await agent.confirm(CONVERSATION, [action["id"]])
    e = runner.store.get(e["id"])
    past = utcnow() - timedelta(minutes=1)
    runner.store.update(e["id"], timed_drop={**e["timed_drop"], "closes_at": past.isoformat()})
    await runner._due_drops()
    e = runner.store.get(e["id"])
    assert e["status"] == "failed" and "nothing was bought" in e["result"]


def test_bot_forbidding_shops_are_refused(env):  # noqa: F811
    make, db, browser = env
    runner, _, _ = make()
    with pytest.raises(ValueError, match="Nike"):
        runner.start("Buy the Dunks at the drop", "Dunks", "nike.com", CONVERSATION,
                     drop_at=local(utcnow() + timedelta(hours=1)))
    assert no_bots("www.ticketmaster.it") and no_bots("adidas.it") and no_bots("amazon.it") is None
    # An ordinary errand there (finding, comparing) is fine.
    assert runner.start("Find the Dunks' price", "Dunks", "nike.com", CONVERSATION)["status"] == "queued"


def test_plan_drop_and_its_window():
    d = plan_drop("2030-11-07T10:00", None, "480 €", ROME)
    assert d["opens_at"] == "2030-11-07T09:00:00+00:00" and d["closes_at"] == "2030-11-07T11:00:00+00:00"
    with pytest.raises(ValueError):
        plan_drop("2030-11-07T10:00", "2030-11-07T09:00", None, ROME)
    with pytest.raises(ValueError):
        plan_drop("2020-11-07T10:00", None, None, ROME)  # over
    with pytest.raises(ValueError):
        plan_drop("Friday", None, None, ROME)


def test_the_limits_against_the_page():
    now = datetime(2030, 11, 7, 9, 5, tzinfo=timezone.utc)
    d = {"opens_at": "2030-11-07T09:00:00+00:00", "closes_at": "2030-11-07T11:00:00+00:00",
         "limits": {"item": "Nintendo Switch 2", "variant": "Nero", "amount": 480.0, "max_total": "480,00 €"}}
    page = "Nintendo Switch 2 - Nero. Subtotale 469,99 €. Spedizione 5,00 €. Totale ordine: 474,99 €"
    assert order_total(page) == 474.99
    assert drop_mismatch(d, page, now) is None
    assert "variant" in drop_mismatch(d, page.replace("Nero", "Bianco"), now)
    assert "isn't on the page" in drop_mismatch(d, page.replace("Switch 2", "Switch Lite"), now)
    assert "over the limit" in drop_mismatch(d, page.replace("474,99", "489,99"), now)
    assert "no order total" in drop_mismatch(d, "Nintendo Switch 2 Nero 469,99 €", now)
    assert "hasn't opened" in drop_mismatch(d, page, now - timedelta(minutes=10))
    assert "over" in drop_mismatch(d, page, now + timedelta(hours=3))
    assert order_total("Order total: €1,234.50") is not None


def test_a_pending_action_can_wait_past_the_usual_half_hour(env):  # noqa: F811
    make, db, browser = env
    ttl = runner_ttl()
    old = db.add_pending(CONVERSATION, "errand_go", {"errand": 1}, "old", None, CONVERSATION, "aide")[0]
    db.conn.execute("UPDATE pending_actions SET created_at = ? WHERE id = ?",
                    ((utcnow() - ttl - timedelta(minutes=1)).isoformat(), old))
    later = db.add_pending(CONVERSATION, "errand_drop", {"errand": 2}, "drop", None, CONVERSATION, "aide",
                           expires_at=utcnow() + timedelta(hours=5))[0]
    db.conn.execute("UPDATE pending_actions SET created_at = ? WHERE id = ?",
                    ((utcnow() - ttl - timedelta(minutes=1)).isoformat(), later))
    gone = db.add_pending(CONVERSATION, "errand_drop", {"errand": 3}, "gone", None, CONVERSATION, "aide",
                          expires_at=utcnow() - timedelta(seconds=1))[0]
    assert [a["id"] for a in db.pending_actions(CONVERSATION, ttl)] == [later]
    assert db.pending_status(old, ttl) == "expired" and db.pending_status(gone, ttl) == "expired"
