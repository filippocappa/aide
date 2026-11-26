"""What the user writes into Aide's pages in Obsidian: read back, tidied once left alone, questions answered under
them and in the course chat, undone on request (pageedits.py, 2026-11-26)."""

import json
from datetime import datetime, timedelta

from aide.db import utcnow
from aide.pageedits import PROMPT, PageEdits, added_parts, answer_box
from aide.reading import AskStore
from aide.vault import exercises_body, lecture_notes
from test_api import done
from test_notebook import ROME, built, chat_messages, drain, nb, sent  # noqa: F401 (nb is a fixture)

TOPIC = "Aide/macroeconomics/01 The IS-LM model.md"
ANSWER = "Because a lower interest rate raises investment, so output is higher where $i$ is lower."


def wire(nb) -> tuple[PageEdits, list]:
    asked = []

    async def ask(system, content, max_tokens, fast, live):
        asked.append({"text": content[0]["text"], "fast": fast, "live": live})
        return ANSWER
    pages = PageEdits(nb.db.conn, nb.study, nb.notebook)
    pages.asks = AskStore(nb.db.conn, nb.study, nb.notebook, nb.study.files, nb.agent, ask)
    nb.vault.pages = nb.worker.pages = pages
    return pages, asked


def quiet(nb) -> None:
    """As though the page was left alone for longer than QUIET."""
    nb.db.conn.execute("UPDATE page_edits SET changed_at = ?", ((utcnow() - timedelta(minutes=11)).isoformat(),))


def test_what_was_added_is_found_line_by_line():
    base = "A\n\nB\nC\n\nD"
    mine = "A\n\nB\nmy note\n\nC\n\nD\n\nwhy??"
    assert added_parts(base, mine) == [(3, 4), (9, 10)]
    assert added_parts(base, "A\n\nB changed\nC\n\nD") == [(2, 3)]
    assert added_parts(base, "A\n\nD") == []  # only taken away: nothing to tidy
    assert answer_box("Why?\n", "One.\n\nTwo.") == "> [!question]- Why?\n> One.\n>\n> Two."


async def test_what_you_add_to_a_topic_is_tidied_and_your_question_answered(nb):
    await built(nb)
    pages, asked = wire(nb)
    pushed = len(nb.push.messages)
    await nb.vault.sync()
    disk = nb.vault.folder / TOPIC
    page = disk.read_text()
    anchor = "more output raises money demand and so the interest rate."
    mine = page.replace(anchor, anchor + "\nprof: LM flat in liq trap!! exam").replace(
        "It slopes down.", "It slopes down.\nwhy does it slope down??")
    disk.write_text(mine)
    await nb.vault.sync()  # read back, the user's for now
    topic = nb.notebook.topics(nb.macro["id"])[0]
    assert "prof: LM flat" in topic["body"] and nb.notebook.next_job() is None  # not left alone long enough yet

    quiet(nb)
    nb.client.responses.append(done(json.dumps({"parts": [
        {"n": 1, "text": "", "question": "Why does the IS curve slope down?", "about": "It slopes down."},
        {"n": 2, "text": "> [!tip] From class\n> In a liquidity trap the LM curve is flat: it comes up in the exam.",
         "question": None, "about": None}]})))
    await nb.vault.sync()
    await drain(nb)
    request = nb.client.requests[-1]
    assert request["system"] == PROMPT and request["model"] == "smart"
    assert "⟦1⟧\nwhy does it slope down??\n⟦/1⟧" in sent(request) and "⟦2⟧\nprof: LM flat" in sent(request)
    assert asked and asked[0]["live"] is False and "Their question: Why does the IS curve slope down?" in asked[0]["text"]

    body = nb.notebook.topics(nb.macro["id"])[0]["body"]
    assert "prof: LM flat" not in body and "why does it slope down??" not in body
    assert anchor + "\n\n> [!tip] From class\n> In a liquidity trap the LM curve is flat" in body
    assert "It slopes down.\n\n> [!question]- Why does the IS curve slope down?\n> Because a lower interest rate" in body
    assert "Investment equals saving along the IS curve" in body and "## Exam-style questions" in body  # Aide's, kept
    assert len(nb.push.messages) == pushed  # no push for any of it
    said = [m for m in chat_messages(nb) if m["role"] == "assistant"]
    assert any(a.get("type") == "ask" for m in said for a in m.get("attachments") or [])  # the thread, in the chat
    assert "I tidied what you added to *The IS-LM model* in Obsidian and answered your question there" in said[-1]["text"]
    await nb.vault.sync()
    assert "> [!question]- Why does the IS curve slope down?" in disk.read_text()  # back in Obsidian

    t = pages.undo("is-lm")
    assert t["questions"] == 1
    assert "prof: LM flat in liq trap!! exam" in nb.notebook.topics(nb.macro["id"])[0]["body"]
    await nb.vault.sync()
    quiet(nb)
    await nb.vault.sync()
    assert nb.notebook.next_job() is None  # their own version back: not tidied again
    assert "why does it slope down??" in disk.read_text()


async def test_a_page_aide_changed_meanwhile_is_left_alone(nb):
    await built(nb)
    pages, _ = wire(nb)
    await nb.vault.sync()
    disk = nb.vault.folder / TOPIC
    disk.write_text(disk.read_text() + "\nmy line\n")
    await nb.vault.sync()
    topic = nb.notebook.topics(nb.macro["id"])[0]
    nb.notebook.set_body(topic["id"], topic["body"] + "\n\nAide's new paragraph.")
    quiet(nb)
    await nb.vault.sync()
    asked = len(nb.client.requests)
    await drain(nb)
    assert len(nb.client.requests) == asked and pages.tidies() == []  # no model call, nothing tidied
    assert nb.db.conn.execute("SELECT COUNT(*) FROM page_edits").fetchone()[0] == 0


async def test_exercise_and_lecture_pages_are_read_back(nb):
    topics = await built(nb)
    pages, _ = wire(nb)
    solved = "**Exercise 1.** (new) What shifts IS?\n\n> [!success]- Solution\n> More $G$."
    e = nb.notebook.set_exercises(topics[0], solved, [], True)
    lecture = nb.study.add(datetime(2026, 11, 24, 9, tzinfo=ROME), nb.macro["id"], "IS-LM", text="IS and LM")
    nb.study.set_notes(lecture["id"], "## Summary\nIS meets LM.")
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    ex_page = root / "Exercises/01 The IS-LM model.md"
    lec_page = next((root / "Sources").glob("2026-11-24 *.md"))
    titles = nb.vault._titles()
    assert exercises_body(ex_page.read_text(), titles) == nb.notebook.exercise_set(e["public_id"])["body"]
    assert lecture_notes(lec_page.read_text()) == "## Summary\nIS meets LM."
    assert "Write in this page and Aide tidies what you add" in ex_page.read_text()

    ex_page.write_text(ex_page.read_text().replace("More $G$.", "More $G$.\n\nalso lower taxes?"))
    lec_page.write_text(lec_page.read_text().replace("IS meets LM.", "IS meets LM.\nprof drew it twice"))
    await nb.vault.sync()
    assert nb.notebook.exercise_set(e["public_id"])["body"].endswith("also lower taxes?")
    assert nb.study.get(lecture["public_id"])["notes"] == "## Summary\nIS meets LM.\nprof drew it twice"
    edits = {r[0] for r in nb.db.conn.execute("SELECT ref FROM page_edits")}
    assert edits == {f"exercises:{e['public_id']}", lecture["public_id"]}

    quiet(nb)
    for _ in range(2):
        nb.client.responses.append(done(json.dumps({"parts": [{"n": 1, "text": "Tidied: $x$.", "question": None}]})))
    await nb.vault.sync()
    await drain(nb)
    assert nb.notebook.exercise_set(e["public_id"])["body"].endswith("More $G$.\n\nTidied: $x$.")
    assert nb.study.get(lecture["public_id"])["notes"] == "## Summary\nIS meets LM.\nTidied: $x$."
    assert {t["title"] for t in pages.tidies()} == {"Exercises: The IS-LM model", "IS-LM"}
