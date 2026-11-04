"""Release trackers: research by an errand, the user's picks, then a daily look that sets up the drops."""
from datetime import datetime, timedelta

from fastapi.testclient import TestClient

from aide.agent import CONVERSATION
from aide.channels.api import create_app
from aide.releases import Releases, clean_colourway, merge, release_tools
from aide.reminders import ReminderStore
from aide.tools import Tool
from test_agents import AUTH, ROME, FakeClient, calls, done
from test_errands import env, next_phase  # noqa: F401  (env is a fixture)

CALENDAR = "https://www.soleretriever.com/sneaker-release-dates/nike/alphafly-4"


def day(days: int) -> str:
    return (datetime.now(ROME) + timedelta(days=days)).date().isoformat()


def colourway(name, code, status="upcoming", date=None, time=None, method="fcfs", shops=("nike.com",), price="299,99 €"):
    return {"name": name, "code": code, "price": price, "status": status, "date": date, "time": time,
            "method": method, "url": f"https://www.nike.com/it/t/alphafly-4-{code.lower()}",
            "shops": [{"site": s, "url": f"https://www.{s}/p/{code.lower()}", "note": None} for s in shops],
            "note": None}


def report(*colourways):
    return {"title": "Nike Alphafly 4", "summary": "One colourway is out; two are coming.",
            "colourways": list(colourways), "sources": [{"title": "Sole Retriever", "url": CALENDAR}]}


def web_search():
    async def run(query: str) -> str:
        return "results"
    return Tool("web_search", "search", {"type": "object", "properties": {"query": {"type": "string"}},
                                         "required": ["query"], "additionalProperties": False}, run)


def tracker(runner, agent, looks=()):
    rel = Releases(agent.db.conn, ROME, FakeClient(looks), "fast", [web_search()],
                   runner.browser, None, ReminderStore(agent.db.conn), CONVERSATION)
    rel.errands, rel.agent, runner.releases = runner, agent, rel
    return rel


async def researched(make, *colourways):
    runner, agent, _ = make([calls(("open_page", {"url": CALENDAR})),
                             calls(("report_release", report(*colourways)))])
    runner.browser.pages[CALENDAR] = ("Alphafly 4 release dates", "Nike Alphafly 4 Volt/Black HF7356-700", {})
    rel = tracker(runner, agent)
    r = rel.start("Nike Alphafly 4", CONVERSATION)
    assert r["status"] == "researching"
    e = await next_phase(runner)
    assert e["status"] == "done" and e["release"] == r["id"]
    return runner, agent, rel, rel.get(r["id"])


def test_colourways_are_cleaned_and_merged():
    c = clean_colourway({**colourway("Volt/Black", "hf7356-700", date="2026-11-20", time="9.00"),
                         "status": "soon", "method": "?", "shops": [{"site": "https://www.nike.com/it", "url": None,
                                                                     "note": None}]})
    assert (c["code"], c["time"], c["status"], c["method"]) == ("HF7356-700", "09:00", "rumoured", "unknown")
    assert c["shops"] == [{"site": "nike.com", "url": None, "note": None}]
    assert clean_colourway(colourway("X", "A1", time="10:00"))["time"] is None  # a time without a day is dropped
    old = [clean_colourway(colourway("Volt/Black", "HF7356-700", date="2026-11-20")),
           clean_colourway(colourway("White", "HF7356-100", status="out"))]
    old[0]["image"] = "https://img.test/volt.jpg"
    new = [clean_colourway(colourway("Volt / Black", "HF7356-700", date="2026-11-21", time="10:00")),
           clean_colourway(colourway("Pink", "HF7356-600"))]
    out, changes = merge(old, new)
    assert [c["name"] for c in out] == ["Volt / Black", "Pink", "White"]  # the white one, not mentioned, stays
    assert out[0]["image"] == "https://img.test/volt.jpg" and out[1]["new"]
    assert [c["kind"] for c in changes] == ["date", "new"]
    assert "drops 2026-11-21 10:00 (was 2026-11-20)" in changes[0]["text"]


async def test_research_posts_a_card_to_pick_from(env):  # noqa: F811
    make, db, browser = env
    runner, agent, rel, r = await researched(
        make, colourway("Volt/Black", "HF7356-700", date=day(10)), colourway("White", "HF7356-100", status="out"))
    assert r["status"] == "ready" and r["title"] == "Nike Alphafly 4"
    assert [c["image"] for c in r["colourways"]] == ["https://img.test/alphafly-4-hf7356-700.jpg",
                                                     "https://img.test/alphafly-4-hf7356-100.jpg"]
    last = agent.visible_history(CONVERSATION)[-1]
    assert last["text"] == "One colourway is out; two are coming."
    [card] = last["attachments"]
    assert card["type"] == "releases" and card["releases"][0]["shops"] == ["nike.com"]
    assert rel.as_json(r)["colourways"][0]["picked"] is False
    # Asking for it again doesn't start a second one.
    assert rel.start("nike alphafly 4", CONVERSATION)["id"] == r["id"]


async def test_buy_picks_set_up_a_drop_and_follow_a_move(env):  # noqa: F811
    make, db, browser = env
    runner, agent, rel, r = await researched(
        make, colourway("Volt/Black", "HF7356-700", date=day(10), shops=("nike.com", "zalando.it")),
        colourway("White", "HF7356-100", date=day(3), time="10:00", method="draw"))
    try:
        rel.set_picks(r["id"], ["Volt/Black"], None, None, [], "buy")
        raise AssertionError("buying needs a size and a limit")
    except ValueError as e:
        assert "size" in str(e)
    r = rel.set_picks(r["id"], ["HF7356-700", "white"], "EU 43", "320 €", ["zalando.it"], "buy")
    assert r["status"] == "tracking" and r["picks"]["max_total"] == 320.0
    acts = await rel._act(r)
    # The white one is a draw: a reminder, never a bot. The black one has no time yet: nothing.
    assert len(acts) == 1 and "draw" in acts[0]
    [rem] = ReminderStore(db.conn).open()
    assert "draw" in rem.title and rem.due_at is not None
    assert not any(e["timed_drop"] for e in runner.store.recent())

    # A look: the black one gets its time. It becomes a timed drop on the user's shop, inside their limits.
    rel.client = FakeClient([calls(("report_release", report(
        colourway("Volt/Black", "HF7356-700", date=day(10), time="09:00", shops=("nike.com", "zalando.it")),
        colourway("White", "HF7356-100", date=day(3), time="10:00", method="draw"),
        colourway("Pink", "HF7356-600")))), done("ok")])
    r = await rel.check(r["id"])
    drop = runner.store.get(r["acted"][r["colourways"][0]["key"]]["errand_id"])
    assert drop["site"] == "zalando.it" and drop["release"] == r["id"]
    assert drop["timed_drop"]["max_total"] == "320,00 €"
    opens = datetime.fromisoformat(drop["timed_drop"]["opens_at"]).astimezone(ROME)
    assert (opens.date().isoformat(), opens.strftime("%H:%M")) == (day(10), "09:00")
    assert "EU 43" in drop["task"]
    last = agent.visible_history(CONVERSATION)[-1]
    assert "New colourway: Pink" in last["text"] and "drops" in last["text"]
    assert last["attachments"][0]["releases"][0]["colourways"][0]["plan"]["what"] == "drop"

    # The drop moves a day: the old errand is cancelled and a new one waits for the new time.
    rel.client = FakeClient([calls(("report_release", report(
        colourway("Volt/Black", "HF7356-700", date=day(11), time="09:00", shops=("nike.com", "zalando.it"))))),
        done("ok")])
    r = await rel.check(r["id"])
    assert runner.store.get(drop["id"])["status"] == "cancelled"
    moved = runner.store.get(r["acted"][r["colourways"][0]["key"]]["errand_id"])
    assert moved["id"] != drop["id"] and moved["status"] == "queued"
    assert len(r["colourways"]) == 3  # nothing forgotten

    # Stopping cancels what's set up.
    r = rel.stop(r["id"])
    assert r["status"] == "stopped" and runner.store.get(moved["id"])["status"] == "cancelled"
    assert ReminderStore(db.conn).open() == []


async def test_tell_mode_reminds_and_a_failed_look_waits(env):  # noqa: F811
    make, db, browser = env
    runner, agent, rel, r = await researched(make, colourway("Volt/Black", "HF7356-700", date=day(5), time="10:00"))
    r = rel.set_picks(r["id"], ["Volt/Black"], "43", None, [], "tell")
    await rel._act(r)
    [rem] = ReminderStore(db.conn).open()
    assert rem.title.startswith("Nike Alphafly 4 Volt/Black drops at 10:00")
    assert rem.due_at.astimezone(ROME).strftime("%H:%M") == "09:50"
    rel.client = FakeClient([done("I couldn't find anything")])
    r = await rel.check(r["id"])
    assert r["fails"] == 1 and r["status"] == "tracking" and "didn't report" in r["error"]


async def test_tools_and_api(env):  # noqa: F811
    make, db, browser = env
    runner, agent, rel, r = await researched(make, colourway("Volt/Black", "HF7356-700", date=day(5), time="10:00"))
    tools = {t.name: t for t in release_tools(rel, lambda: CONVERSATION)}
    out = await tools["set_release_picks"].handler(release=r["id"], colourways=["Volt/Black"], size="EU 43",
                                                   max_total="300 €", shops=None, mode="buy")
    assert "Set up now" in out and out.attachment["type"] == "releases"
    assert "picked Volt/Black (buy, size EU 43)" in await tools["list_releases"].handler()

    client = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t", errands=runner, releases=rel))
    got = client.get("/v1/releases", headers=AUTH).json()
    assert got["enabled"] and got["releases"][0]["colourways"][0]["plan"]["what"] == "drop"
    body = {"colourways": [r["colourways"][0]["key"]], "size": "EU 44", "max_total": 310, "shops": [], "mode": "buy"}
    r2 = client.put(f"/v1/releases/{r['id']}/picks", json=body, headers=AUTH).json()
    assert r2["picks"]["size"] == "EU 44" and r2["picks"]["max_total_text"] == "310,00 €"
    assert "EU 44" in runner.store.get(r2["colourways"][0]["plan"]["errand_id"])["task"]  # the drop was redone
    assert client.put(f"/v1/releases/{r['id']}/picks", json={**body, "colourways": ["nope"]},
                      headers=AUTH).status_code == 422
    assert client.post(f"/v1/releases/{r['id']}/stop", headers=AUTH).json()["status"] == "stopped"
    assert client.post(f"/v1/releases/{r['id']}/resume", headers=AUTH).json()["status"] == "tracking"
    assert client.delete(f"/v1/releases/{r['id']}", headers=AUTH).json() == {"ok": True}
    assert client.get(f"/v1/releases/{r['id']}", headers=AUTH).status_code == 404
