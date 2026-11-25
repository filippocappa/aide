from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from aide.channels.api import create_app
from aide.reading import PROMPT, AskStore, citations, found
from aide.reminders import ReminderStore
from test_api import AUTH, TOKEN
from test_lessons import FakeAsk
from test_notebook import nb  # noqa: F401 (the fixture)
from test_study import ROME


@pytest.fixture
def rd(nb):
    ask = FakeAsk({PROMPT: []})
    store = AskStore(nb.db.conn, nb.study, nb.notebook, nb.study.files, nb.agent, ask)
    api = TestClient(create_app(nb.agent, ReminderStore(nb.db.conn), None, ROME, TOKEN, study=nb.study,
                                notebook=nb.notebook, asks=store))
    topic = nb.notebook.add_topic(nb.macro["id"], "IS-LM")
    nb.notebook.set_body(topic["id"], "## The IS curve\nInvestment equals saving at each rate.")
    return SimpleNamespace(nb=nb, api=api, ask=ask, store=store, topic=nb.notebook.topic(topic["public_id"]))


def test_found_keeps_only_words_really_on_the_page():
    page = "LM: liquidity preference equals money\nsupply, on the second slide"
    assert found("liquidity preference equals money supply", page) == "liquidity preference equals money supply"
    assert found("“Liquidity  Preference”", page) == "liquidity preference"
    assert found("the IS curve slopes down", page) is None
    assert found("LM", page) is None  # one word: anywhere


def test_citations_from_the_page_lines_and_the_text():
    pages = {2: "LM: liquidity preference equals money supply", 3: "Crowding out: when spending raises the rate"}
    text, cites = citations("Money demand meets supply (p. 2), and see pp. 3–4.\n\nPAGE 2 | liquidity preference "
                            "equals money\nPAGE 9 | nothing\nPAGE 3 | not on the page at all", pages, 3)
    assert text == "Money demand meets supply (p. 2), and see pp. 3–4."
    assert cites == [{"page": 2, "text": "liquidity preference equals money"}, {"page": 3, "text": None}]


def test_asking_about_a_file_cites_its_pages_and_keeps_the_thread_in_the_course_chat(rd):
    f = rd.nb.file
    rd.ask.answers[PROMPT].append("It's where money demand meets supply (p. 2).\n"
                                  "PAGE 2 | liquidity preference equals money supply")
    r = rd.api.post("/v1/study/ask?plain=true&latex=true&inline=true", headers=AUTH,
                    json={"source": {"file": f["id"], "page": 2}, "passage": "LM: liquidity preference",
                          "question": "what's LM?"})
    assert r.status_code == 200, r.text
    t = r.json()
    assert t["id"].startswith("a_") and t["course"] == rd.nb.macro["id"] and t["source"] == {"file": f["id"], "page": 2}
    assert t["where"] == "Macroeconomics · Week 3 slides.pdf, p. 2" and t["passage"] == "LM: liquidity preference"
    turn = t["turns"][0]
    assert turn["q"] == "what's LM?" and turn["a"] == "It's where money demand meets supply (p. 2)."
    assert turn["citations"] == [{"file": f["id"], "page": 2, "text": "liquidity preference equals money supply"}]
    sent = rd.ask.calls[-1]
    assert sent["fast"] and sent["live"]
    assert "They're on p. 2." in sent["text"] and "[p. 3]\nCrowding out" in sent["text"]  # a short file goes whole
    assert "> LM: liquidity preference" in sent["text"] and sent["text"].endswith("Their question: what's LM?")

    # a quick action in the same thread, on another page
    rd.ask.answers[PROMPT].append("1. What crowds out?\n> [!success]- Answer\n> Higher rates (p. 3).")
    t = rd.api.post("/v1/study/ask", headers=AUTH,
                    json={"thread": t["id"], "source": {"file": f["id"], "page": 3}, "action": "quiz"}).json()
    assert len(t["turns"]) == 2 and t["turns"][1]["action"] == "quiz" and t["source"]["page"] == 3
    assert t["turns"][1]["citations"] == [{"file": f["id"], "page": 3, "text": None}]
    assert "They asked: what's LM?" in rd.ask.calls[-1]["text"] and "Quiz me" in rd.ask.calls[-1]["text"]

    # one message in the course chat, rewritten with each answer, folded into a card
    chat = t["conversation_id"]
    assert chat == rd.nb.study.chat(rd.nb.macro["id"])
    shown = rd.api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    entry = [m for m in shown if any(a["type"] == "ask" for a in m["attachments"])]
    assert len(entry) == 1 and entry[0]["role"] == "assistant"
    assert entry[0]["text"].startswith("Asked about: Macroeconomics · Week 3 slides.pdf, p. 3")
    assert "**what's LM?**" in entry[0]["text"] and "What crowds out?" in entry[0]["text"]
    card = entry[0]["attachments"][0]["ask"]
    assert card["id"] == t["id"] and len(card["turns"]) == 2 and card["turns"][0]["markdown"]
    assert not any(m["role"] == "user" for m in shown)  # the note before it isn't shown
    assert rd.api.get(f"/v1/study/ask/{t['id']}", headers=AUTH).json()["turns"] == t["turns"]


def test_asking_about_a_passage_in_the_notes(rd):
    rd.ask.answers[PROMPT].append("Saving is income not spent; at each rate it must fund investment.")
    t = rd.api.post("/v1/study/ask", headers=AUTH, json={
        "source": {"topic": rd.topic["public_id"]}, "passage": "Investment equals saving at each rate."}).json()
    assert t["where"] == "Macroeconomics · IS-LM" and t["turns"][0]["q"] == "Explain this."  # no question: explain
    assert t["turns"][0]["citations"] == []
    assert 'The topic\'s notes, "IS-LM"' in rd.ask.calls[-1]["text"]

    rd.ask.answers[PROMPT].append("The sheet's ISLM line.")
    t = rd.api.post("/v1/study/ask", headers=AUTH, json={
        "course": rd.nb.macro["id"], "source": {"notebook": "formulas"}, "question": "what's this?"}).json()
    assert t["where"] == "Macroeconomics · Formulas"


def test_asking_wrong(rd):
    post = lambda body: rd.api.post("/v1/study/ask", headers=AUTH, json=body)  # noqa: E731
    assert post({"source": {"file": "f_000000000000"}, "question": "?"}).status_code == 404
    assert post({"source": {"topic": rd.topic["public_id"]}}).status_code == 400  # nothing to ask
    assert post({"source": {"topic": rd.topic["public_id"]}, "action": "quiz"}).status_code == 400  # files only
    assert post({"source": {}, "question": "?"}).status_code == 400
    assert post({"thread": "a_000000000000", "question": "?"}).status_code == 404
    rd.ask.answers[PROMPT].append(RuntimeError("down"))
    assert post({"source": {"topic": rd.topic["public_id"]}, "question": "?"}).status_code == 502
    assert rd.nb.db.conn.execute("SELECT COUNT(*) FROM asks").fetchone()[0] == 0
