import json
from datetime import datetime, timedelta
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.material import visual_pages
from aide.notebook import DATES_PROMPT, SCAN_PROMPT, NotebookStore, NotebookWorker, date_line, parse_page, sections
from aide.photos import PhotoStore
from aide.plans import PlanStore
from aide.reminders import ReminderStore
from aide.study import StudyStore, tidy_math
from aide.tools import ToolRegistry
from aide.tools.study import study_tools
from aide.vault import Vault
from test_api import AUTH, TOKEN, FakeCalendar, call, done
from test_food import RecordingClient, images
from test_study import EVENTS, ROME, FakePush, add_pdf, make_pdf

INTRO = "Exam: 20 to 35 multiple-choice questions, −0.25 for a wrong answer.\n\n## The exam\nMultiple choice."
PAGE = """The IS-LM model ties the goods and the money market together.

## Explanation
### The IS curve
Investment equals saving along the IS curve: a lower interest rate raises investment and so output. It slopes down.
### The LM curve
Money demand equals the money supply along LM: more output raises money demand and so the interest rate.

## Formulas
$Y = C + I + G$

## Exam-style questions
**1.** What shifts IS to the right?
- A) More government spending
- B) More money
> [!success]- Answer
> **A**. G is part of demand.

===CARDS===
- What does IS stand for? :: Investment equals saving
2. What shifts LM? :: The money supply"""
CROWDING = """Crowding out is when public spending raises the interest rate.

## Explanation
Government borrowing pushes rates up, and private investment falls. How much depends on the slope of LM: a
steep LM means full crowding out, a flat one (a liquidity trap) means almost none.

===CARDS===
What is crowding out? :: Public spending displacing private investment"""
PROBLEMS = make_pdf(None, ["Problem 1: a liquidity trap, where the LM curve is flat at a zero interest rate",
                           "Problem 2: a fiscal expansion financed by debt, and what happens to the interest rate"])


class ByTopic(RecordingClient):
    """Answers topic pages by the topic they're for, since they're written in parallel: a response can be
    {title: response or [responses]}, used up a title at a time. The slide scan is answered by `scan`, a function
    of the pages asked about (by default an answer that can't be read, so files stay unscanned), and kept apart. So
    is reading a course's dates, answered with `dates`."""

    scan = None
    scans: list[dict]
    dates: list | str = []
    dated: list[dict]

    async def _create(self, **kwargs):
        if kwargs.get("system") == DATES_PROMPT:
            self.__dict__.setdefault("dated", []).append(kwargs)
            answer = done(json.dumps(self.dates))
            return SimpleNamespace(stop_reason=answer[0], content=answer[1])
        if kwargs.get("system") == SCAN_PROMPT:
            self.__dict__.setdefault("scans", []).append(kwargs)
            pages = [int(b["text"][4:-1]) for b in kwargs["messages"][-1]["content"]
                     if b.get("type") == "text" and b["text"].startswith("[p. ")]
            answer = done(json.dumps(self.scan(pages)) if self.scan else "no")
            return SimpleNamespace(stop_reason=answer[0], content=answer[1])
        if isinstance(self.responses[0], dict):
            pages = self.responses[0]
            title = next(t for t in pages if f"Topic: {t}\n" in sent(kwargs))
            self.requests.append(kwargs)
            response = pages[title].pop(0) if isinstance(pages[title], list) else pages.pop(title)
            if pages.get(title) == []:
                del pages[title]
            if not pages:
                self.responses.pop(0)
            return SimpleNamespace(stop_reason=response[0], content=response[1])
        return await super()._create(**kwargs)


def sent(request: dict) -> str:
    """The text of a model request's user message."""
    return "\n".join(b["text"] for b in request["messages"][-1]["content"] if b.get("type") == "text")


@pytest.fixture
def nb(tmp_path):
    db = Database(":memory:")
    client = ByTopic([])
    study = StudyStore(db, ROME, FakeCalendar(list(EVENTS)), files_dir=tmp_path / "files")
    notebook = NotebookStore(study)
    agent = Agent(client, db, ToolRegistry(study_tools(study, ROME, tmp_path / "audio", notebook)), model="m",
                  smart_model="smart", tz=ROME, photos=PhotoStore(tmp_path / "photos"), delegate=False)
    push = FakePush(db.conn)
    push.messages = []

    async def send_message(conversation_id, title, body):
        push.messages.append((conversation_id, title, body))
        return True
    push.send_message = send_message
    worker = NotebookWorker(notebook, agent, push)
    api = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar(list(EVENTS)), ROME, TOKEN, push=push,
                                study=study, notebook=notebook))
    api.get("/v1/study", headers=AUTH)  # the calendar's courses into the table
    macro = study.course_by_name("macroeconomics")
    db.conn.execute("INSERT INTO moodle_courses (moodle_id, name, course_id, text) VALUES (1, 'MACRO', ?, ?)",
                    (macro["id"], "## EXAM\nThe exam will consist of 20 to 35 multiple-choice questions."))
    f = add_pdf(api, course=macro["id"]).json()
    vault = Vault(tmp_path / "vault", study, notebook)
    yield SimpleNamespace(api=api, db=db, study=study, notebook=notebook, worker=worker, client=client, push=push,
                          agent=agent, macro=macro, file=f, vault=vault)
    db.close()


async def drain(nb) -> None:
    while job := nb.notebook.next_job():
        await nb.worker.process(job)


def chat_messages(nb) -> list[dict]:
    chat = nb.study.chat(nb.macro["id"])
    return nb.api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]


async def started(nb) -> dict:
    """A notebook with the outline proposed: The IS-LM model (p. 1-2) and Crowding out (p. 3)."""
    outline = [{"title": "The IS-LM model", "summary": "Goods and money markets together.",
                "sources": [{"file": nb.file["id"], "pages": "1-2"}]},
               {"title": "Crowding out", "summary": "Spending and the interest rate.",
                "sources": [{"file": nb.file["id"], "pages": [3]}, {"file": "f_000000000000", "pages": "1"}]}]
    nb.client.responses += [done(INTRO), done("Here it is:\n```json\n" + json.dumps(outline) + "\n```")]
    assert nb.api.post(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).status_code == 202
    await drain(nb)
    return nb.notebook.proposals(nb.macro["id"])[0]


async def built(nb) -> list[dict]:
    p = await started(nb)
    nb.client.responses.append({"The IS-LM model": [done(PAGE), done('{"1": "A"}')], "Crowding out": done(CROWDING)})
    assert nb.api.post(f"/v1/proposals/{p['public_id']}/apply", json={}, headers=AUTH).status_code == 202
    writing = nb.api.get(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).json()["writing"]
    assert writing["id"] == p["public_id"] and writing["progress"] == {"done": 0, "total": 2}
    await drain(nb)
    after = nb.api.get(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).json()
    assert after["writing"] is None and after["step"] is None and nb.notebook.proposal(p["public_id"])["done"] == 2
    return nb.notebook.topics(nb.macro["id"])


async def test_starting_writes_the_introduction_and_proposes_topics(nb):
    p = await started(nb)
    intro_request, outline_request = nb.client.requests
    assert intro_request["model"] == "smart" and "20 to 35 multiple-choice" in sent(intro_request)
    assert "Next exam in the calendar: " in sent(intro_request) and "Macroeconomics exam" in sent(intro_request)
    intro = nb.notebook.intro(nb.macro["id"])
    assert intro["exam"].startswith("20 to 35") and intro["body"].startswith("## The exam")
    # The outline sees a map of the pages, not their full text.
    assert f"[{nb.file['id']}] Week 3 slides.pdf · no section · 3 pages\n  p.1: The IS curve" in sent(outline_request)
    assert p["kind"] == "outline" and p["status"] == "pending" and [it["title"] for it in p["items"]] == \
        ["The IS-LM model", "Crowding out"]
    assert p["items"][0]["sources"] == [{"file": nb.file["id"], "pages": [1, 2]}]
    assert p["items"][1]["sources"] == [{"file": nb.file["id"], "pages": [3]}]  # the made-up file is dropped
    assert nb.notebook.topics(nb.macro["id"]) == []  # nothing written before the user's OK
    messages = chat_messages(nb)
    chats = nb.api.get("/v1/conversations", headers=AUTH).json()["conversations"]
    # The app finds the course's progress from its chat.
    assert {c["id"]: c["course"] for c in chats}[nb.study.chat(nb.macro["id"])] == nb.macro["id"]
    assert {c["course"] for c in chats} == {nb.macro["id"], None}
    assert [m["role"] for m in messages] == ["assistant"]  # the note with the proposal's id stays hidden
    # The topics are on the card under the message (and in the note for the model), not in its text.
    assert "2 topics, one page each" in messages[0]["text"]
    card = messages[0]["attachments"][-1]["proposal"]
    assert card["id"] == p["public_id"] and [it["title"] for it in card["items"]] == ["The IS-LM model", "Crowding out"]
    note = nb.db.history(nb.db.app_conversation(nb.study.chat(nb.macro["id"]))["id"])[0]["content"]
    assert "1. **The IS-LM model**: Goods and money markets together." in note
    assert "Shall I write them?" in messages[0]["text"] and len(nb.push.messages) == 1
    assert nb.api.get(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).json()["proposals"][0]["items"][1] == \
        {"n": 2, "topic": None, "title": "Crowding out", "add": "Spending and the interest rate.",
         "sources": ["Week 3 slides, p. 3"]}


async def test_the_introduction_reads_what_the_files_say_about_the_exam(nb):
    info = make_pdf(None, ["Exam: 15 multiple choice questions, 1 point each, no penalty\nand 1 open question, "
                           "15 points. Duration: 60 minutes. Mid-terms: 2.", "Office hours on Tuesday"])
    assert add_pdf(nb.api, data=info, course=nb.macro["id"], name="01 info").status_code == 201
    await started(nb)
    intro_request = nb.client.requests[0]
    assert "[01 info.pdf, p. 1]\nExam: 15 multiple choice questions" in sent(intro_request)
    # All of an info sheet; of the slides, nothing (they don't talk about the exam).
    assert "[01 info.pdf, p. 2]\nOffice hours on Tuesday" in sent(intro_request)
    assert "The IS curve" not in sent(intro_request)

    # Written again on its own when it's wrong: the topics and proposals stay.
    nb.client.responses.append(done("Exam: 15 multiple choice questions and an open one, no penalty.\n\n## The exam\n…"))
    nb.notebook.enqueue(nb.macro["id"], "intro")
    await drain(nb)
    assert nb.notebook.intro(nb.macro["id"])["exam"].startswith("15 multiple choice")
    assert len(nb.notebook.proposals(nb.macro["id"])) == 1
    assert "rewritten the macroeconomics Introduction" in chat_messages(nb)[-1]["text"]


async def test_a_courses_dates_are_read_from_its_page_and_files(nb):
    cid = nb.macro["id"]
    assert nb.notebook.undated() == [cid]  # never read: the worker queues it when it starts
    today = datetime.now(ROME).date()
    soon, later, before = today + timedelta(days=3), today + timedelta(days=11), today - timedelta(days=20)
    nb.client.dates = [
        {"what": "1st mid-term", "kind": "mid-term", "date": later.isoformat(), "time": "11:00", "end": "14:00",
         "details": "Chapters 1-12 and slides 02-08.", "source": "01 info.pdf, p. 5"},
        {"what": "Sign-up for the 1st mid-term closes", "kind": "deadline", "date": soon.isoformat(),
         "time": "23:59", "end": None, "details": "Google form, UniTo email only", "source": "Moodle"},
        {"what": "Classes start", "kind": "start", "date": before.isoformat(), "time": "11"},
        {"what": "The 2nd mid-term", "date": "the last class"}, "not a date"]
    await started(nb)  # the Introduction, then the dates from the same pages
    asked = nb.client.dated[0]
    assert asked["model"] == "smart" and "20 to 35 multiple-choice" in sent(asked) and "Today: " in sent(asked)
    dates = nb.notebook.dates(cid)
    assert [d["what"] for d in dates] == ["Classes start", "Sign-up for the 1st mid-term closes", "1st mid-term"]
    assert dates[0]["kind"] == "other" and dates[0]["time"] is None  # made-up kinds and times are dropped
    assert nb.notebook.undated() == []
    assert [d["what"] for d in nb.notebook.dates(cid, since=today)] == ["Sign-up for the 1st mid-term closes",
                                                                        "1st mid-term"]
    line = date_line(dates[2], today)
    assert line == f"{later:%a %d %b %Y}, 11:00-14:00: 1st mid-term (in 11 days). Chapters 1-12 and slides 02-08. " \
                   "(01 info.pdf, p. 5)"

    # Professor sees them with the courses, and the Introduction lists them all.
    list_courses = next(t for t in study_tools(nb.study, ROME, None, nb.notebook) if t.name == "list_courses")
    courses = await list_courses.handler()
    assert "the exam: 20 to 35 multiple-choice questions" in courses and f"    {line}" in courses
    assert "Classes start" not in courses
    await nb.vault.sync()
    intro = (nb.vault.folder / "Aide/macroeconomics/00 Introduction.md").read_text()
    assert "## Dates\n- " in intro and "1st mid-term" in intro and intro.index("## Dates") < intro.index("## Files")

    # Read again on a change, once however many come; an answer that can't be read keeps the old ones, quietly.
    nb.notebook.reread_dates(cid)
    nb.notebook.reread_dates(cid)
    assert nb.db.conn.execute("SELECT COUNT(*) FROM notebook_jobs WHERE kind = 'dates' AND status = 'queued'"
                              ).fetchone()[0] == 1
    nb.client.dates = "no"
    before_chat = len(chat_messages(nb))
    await drain(nb)
    assert len(nb.notebook.dates(cid)) == 3 and len(chat_messages(nb)) == before_chat


async def test_an_exam_notice_is_read_for_dates_with_the_users_name_and_checked_against_the_calendar(nb):
    cid = nb.macro["id"]
    nb.db.conn.execute("INSERT INTO moodle_state (key, value) VALUES ('user', ?)",
                       (json.dumps({"id": 7, "name": "Filippo Cappa", "site": "UniTo"}),))
    nb.worker.plans = PlanStore(nb.db.conn, ROME, None)
    await started(nb)
    asked = len(nb.client.dated)
    today = datetime.now(ROME).date()
    mid, exam = today + timedelta(days=9), (datetime.now(ROME) + timedelta(days=20)).date()

    # A lecture's slides that mention the exam only far in, or "0.25" and a test, aren't read for dates.
    lecture = make_pdf(None, ["The IS curve", "A test of the model: a 0.25 rise in 3 markets", "Money demand",
                              "More slides", "On the exam: 12/01, a written test"])
    assert add_pdf(nb.api, lecture, course=cid, name="Lecture 7").status_code == 201
    assert not nb.notebook.dates_reading(cid)

    # An exam notice is: by its name here (an "Avviso"), or by its first pages.
    assert nb.notebook.looks_like_dates({"name": "Rooms.pdf", "id": 0, "pages": 0})
    nb.client.dates = [
        {"what": "1st mid-term", "kind": "mid-term", "date": mid.isoformat(), "time": "11:00", "end": "13:00",
         "room": "Aula 5", "you": "Aula 5: surnames A–L", "details": "Chapters 1-6.", "source": "Avviso.pdf, p. 1"},
        {"what": "Final exam", "kind": "exam", "date": exam.isoformat(), "time": "09:00", "room": None,
         "you": None, "details": "", "source": "Moodle"}]
    notice = make_pdf(None, [f"Prova intermedia {mid:%d/%m}: aula 5 cognomi A-L, aula 7 cognomi M-Z"])
    assert add_pdf(nb.api, notice, course=cid, name="Avviso").status_code == 201
    assert nb.notebook.dates_reading(cid)
    await drain(nb)
    assert len(nb.client.dated) == asked + 1
    request = sent(nb.client.dated[-1])
    assert "The student: Filippo Cappa" in request and "[Avviso.pdf, p. 1]" in request
    first, final = nb.notebook.dates(cid)
    assert (first["room"], first["you"], first["by"]) == ("Aula 5", "Aula 5: surnames A–L", "professor")
    assert first["id"].startswith("d_") and "For you: Aula 5: surnames A–L." in date_line(first, today)

    # The final exam is in the Exam calendar; the mid-term isn't, so Professor proposes it, once.
    assert final["calendar"]["state"] == "in" and first["calendar"]["state"] == "missing"
    card = chat_messages(nb)[-1]
    assert "**1st mid-term**" in card["text"] and "isn't in your Exam calendar" in card["text"]
    [event] = card["attachments"][0]["events"]
    assert (event["title"], event["calendar"], event["location"], event["change"]) == \
        ("macroeconomics: 1st mid-term", "Exam", "Aula 5", "proposed")
    assert event["start"].startswith(f"{mid.isoformat()}T11:00") and "For you: Aula 5" in event["notes"]
    assert nb.push.messages[-1][1] == "Professor · macroeconomics"
    posts = len(chat_messages(nb))

    # The same pages again: no model call, nothing proposed again. Read again on purpose: the model is asked.
    nb.notebook.reread_dates(cid)
    await drain(nb)
    assert len(nb.client.dated) == asked + 1 and len(chat_messages(nb)) == posts
    r = nb.api.post(f"/v1/study/courses/{cid}/dates/read", headers=AUTH)
    assert r.status_code == 202 and r.json()["reading"]
    await drain(nb)
    assert len(nb.client.dated) == asked + 2 and len(chat_messages(nb)) == posts

    # Professor reads the final exam a few days off what the calendar has: it's flagged as moved.
    late = exam + timedelta(days=4)
    nb.client.dates[1]["date"] = late.isoformat()
    nb.api.post(f"/v1/study/courses/{cid}/dates/read", headers=AUTH)
    await drain(nb)
    final = nb.notebook.dates(cid)[1]
    assert final["calendar"]["state"] == "moved" and final["calendar"]["on"] == exam.isoformat()
    card = chat_messages(nb)[-1]
    assert f"your Exam calendar has it on {exam:%a %d %b}" in card["text"]
    assert [e["change"] for e in card["attachments"][0]["events"]] == ["proposed", "found"]


async def test_the_user_edits_a_courses_dates_and_professors_reads_keep_them(nb):
    cid, law = nb.macro["id"], nb.study.course_by_name("business law")["id"]
    nb.worker.plans = PlanStore(nb.db.conn, ROME, None)
    today = datetime.now(ROME).date()
    mid = today + timedelta(days=9)
    nb.client.dates = [{"what": "1st mid-term", "kind": "mid-term", "date": mid.isoformat(), "time": "11:00",
                        "source": "Moodle"},
                       {"what": "Sign-up closes", "kind": "deadline", "date": (mid - timedelta(days=3)).isoformat()}]
    await started(nb)
    url = f"/v1/study/courses/{cid}/dates"
    got = nb.api.get(url, headers=AUTH).json()
    assert [d["what"] for d in got["items"]] == ["Sign-up closes", "1st mid-term"] and not got["reading"]
    first = got["items"][1]["id"]

    # Moved by the user: theirs, through Professor's next reads of the same date.
    moved = mid + timedelta(days=1)
    r = nb.api.patch(f"{url}/{first}", json={"date": moved.isoformat(), "room": "Aula 2"}, headers=AUTH)
    item = next(d for d in r.json()["items"] if d["id"] == first)
    assert (item["date"], item["time"], item["room"], item["by"], item["differs"]) == \
        (moved.isoformat(), "11:00", "Aula 2", "you", None)
    await drain(nb)
    nb.api.post(f"{url}/read", headers=AUTH)
    await drain(nb)
    assert nb.notebook.find_date(cid, first)["date"] == moved.isoformat()
    # Professor now reads another date for it: the user's stays, and says what the course says now.
    later = mid + timedelta(days=5)
    nb.client.dates[0]["date"] = later.isoformat()
    nb.api.post(f"{url}/read", headers=AUTH)
    await drain(nb)
    item = nb.notebook.find_date(cid, first)
    assert item["date"] == moved.isoformat() and item["differs"]["date"] == later.isoformat()
    nb.api.patch(f"{url}/{first}", json={"date": later.isoformat()}, headers=AUTH)  # Use it
    assert nb.notebook.find_date(cid, first)["differs"] is None

    # Hidden stays hidden; the user's own are added and deleted.
    deadline = got["items"][0]["id"]
    assert [d["id"] for d in nb.api.delete(f"{url}/{deadline}", headers=AUTH).json()["items"]] == [first]
    nb.api.post(f"{url}/read", headers=AUTH)
    await drain(nb)
    assert [d["id"] for d in nb.notebook.dates(cid)] == [first]
    r = nb.api.post(url, json={"what": "Oral exam", "kind": "exam", "date": (today + timedelta(days=40)).isoformat(),
                               "room": "Room 3"}, headers=AUTH)
    assert r.status_code == 201 and next(d for d in r.json()["items"] if d["id"] == r.json()["item"])["by"] == "you"
    assert nb.api.delete(f"{url}/{r.json()['item']}", headers=AUTH).json()["items"][-1]["id"] == first
    assert nb.api.post(url, json={"what": "x", "date": "soon"}, headers=AUTH).status_code == 400
    assert nb.api.patch(f"{url}/d_000000000000", json={"what": "x"}, headers=AUTH).status_code == 404

    # The course card's exam: the calendar's, else the course's own next exam or mid-term.
    nb.notebook.set_dates(law, [{"what": "Written exam", "kind": "exam", "date": (today + timedelta(days=30)).isoformat()}])
    courses = {c["id"]: c for c in nb.api.get("/v1/study", headers=AUTH).json()["courses"]}
    assert courses[cid]["next_exam"]["from"] == "calendar"
    assert courses[law]["next_exam"] | {"date": None} == {"date": None, "title": "business law Written exam",
                                                          "from": "course", "all_day": True}


async def test_the_app_sees_what_professor_is_doing(nb):
    seen = []

    def scan(pages):
        seen.append(nb.api.get(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).json()["step"])
        return []
    nb.client.scan = scan
    await built(nb)  # and, done, no step
    # Each topic's slides are looked at as it's written, not the course's up front.
    assert len(seen) == 2 and all(s.startswith("Writing ") for s in seen)


async def test_applying_the_outline_writes_each_topic_from_its_own_pages(nb):
    topics = await built(nb)
    assert [t["title"] for t in topics] == ["The IS-LM model", "Crowding out"]
    first = next(r for r in nb.client.requests[2:] if "Topic: The IS-LM model" in sent(r))
    assert "[Week 3 slides.pdf, p. 1]" in sent(first) and "[Week 3 slides.pdf, p. 3]" not in sent(first)
    assert len(images(first)) == 2  # its two pages, short of text, as images too
    assert "The notebook's other topics, for links: Crowding out" in sent(first)
    assert "Exam: 20 to 35" not in sent(first) and "The exam: 20 to 35" in sent(first)
    t = topics[0]
    assert t["body"].startswith("The IS-LM model ties") and "===CARDS===" not in t["body"]
    assert json.loads(t["cards"]) == [["What does IS stand for?", "Investment equals saving"],
                                      ["What shifts LM?", "The money supply"]]
    p = nb.notebook.proposals(nb.macro["id"], None)[0]
    assert p["status"] == "applied" and p["result"] == "Wrote The IS-LM model, Crowding out."
    assert "Wrote the notes: **The IS-LM model**, **Crowding out**. 3 flashcards in all." in chat_messages(nb)[-1]["text"]
    body = nb.api.get(f"/v1/topics/{t['public_id']}", headers=AUTH).json()
    assert body["sections"] == ["Explanation", "Formulas", "Exam-style questions"] and body["questions"] == 1
    assert body["cards"] == 2 and body["sources"] == ["Week 3 slides, p. 1–2"]
    assert nb.api.post(f"/v1/proposals/{p['public_id']}/apply", headers=AUTH).status_code == 409
    assert nb.api.post(f"/v1/notebook?course={nb.macro['id']}", headers=AUTH).status_code == 409

    # The vault: the Introduction instead of the course index, a page per topic, and the cards.
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    intro = (root / "00 Introduction.md").read_text()
    assert "## The exam\nMultiple choice." in intro and "Next exam: " in intro
    assert "## Topics\n1. [[Aide/macroeconomics/01 The IS-LM model|The IS-LM model]]: Goods" in intro
    assert not (root / "macroeconomics.md").exists()
    page = (root / "01 The IS-LM model.md").read_text()
    assert page.startswith('---\ncourse: "[[Aide/macroeconomics/00 Introduction|macroeconomics]]"\n'
                           'cards: "[[Aide/macroeconomics/Cards/The IS-LM model|Cards]]"\ntopic: t_')
    assert "\n# The IS-LM model\n\nThe IS-LM model ties" in page
    cards = (root / "Cards/The IS-LM model.md").read_text()
    assert cards.startswith("#flashcards/macroeconomics\n") and cards.endswith(
        "What does IS stand for?::Investment equals saving\nWhat shifts LM?::The money supply\n")


async def test_the_formula_sheet_gathers_every_topics_formulas(nb):
    is_lm, crowding = await built(nb)
    cid = nb.macro["id"]
    assert nb.notebook.formulas(cid) == "## [[The IS-LM model]]\n\n$Y = C + I + G$"  # crowding out has none
    assert nb.api.get(f"/v1/notebook?course={cid}", headers=AUTH).json()["formulas"] == 1
    nb.notebook.set_body(crowding["id"], CROWDING.partition("===")[0] + "\n## Formulas\n### Crowding\n$\\Delta I = -b \\Delta i$")
    assert nb.api.get(f"/v1/notebook?course={cid}", headers=AUTH).json()["formulas"] == 2
    sheet = nb.api.get(f"/v1/notebook/formulas?course={cid}&plain=true", headers=AUTH).json()
    assert sheet["body"].startswith("## The IS-LM model\n\nY = C + I + G\n\n## Crowding out\n\n### Crowding\n")
    assert nb.api.get("/v1/notebook/formulas?course=999", headers=AUTH).status_code == 404

    # In the vault: a page of its own, linked from the Introduction, kept in step until the user edits it.
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    page = (root / "Formulas.md").read_text()
    assert page.startswith('---\ncourse: "[[Aide/macroeconomics/00 Introduction|macroeconomics]]"\ntags:\n  - formulas')
    assert "## [[Aide/macroeconomics/01 The IS-LM model|The IS-LM model]]\n\n$Y = C + I + G$" in page
    assert "## Practice\n- [[Aide/macroeconomics/Formulas|Formulas]]" in (root / "00 Introduction.md").read_text()
    nb.notebook.replace_section(is_lm, "Formulas", "$Y = C + I + G + NX$")
    await nb.vault.sync()
    assert "$Y = C + I + G + NX$" in (root / "Formulas.md").read_text()
    (root / "Formulas.md").write_text("my own sheet")
    nb.notebook.replace_section(nb.notebook.topic(is_lm["public_id"]), "Formulas", "$Y = C + I$")
    await nb.vault.sync()
    assert (root / "Formulas.md").read_text() == "my own sheet"


EXERCISES = """Here they are.

**Exercise 1.** (from: Problem set 2, p. 1)
In a liquidity trap the government raises $G$ by 100. With a multiplier of 2, how much does $Y$ rise?
> [!success]- Solution
> LM is flat, so the interest rate doesn't move and nothing is crowded out: $\\Delta Y = 2 \\times 100$.
> **Answer:** $\\Delta Y = 200$

**Exercise 2.** (from: Problem set 2, p. 1; solution: Solution problem set 2, p. 1)
Explain why the IS curve slopes down, and give the multiplier with $c = 0.5$.
> [!success]- Solution
> A lower interest rate raises investment, and so output; see [[Crowding out]].
> **Answer:** 2

**Exercise 3.** (from: Problem set 2, p. 1)
With $c = 0.75$, what is the multiplier?
> [!success]- Solution
> $1/(1 - 0.75)$.
> **Answer:** 3"""
FIXED = """**Exercise 3.** (from: Problem set 2, p. 1)
With $c = 0.75$, what is the multiplier?
> [!success]- Solution
> $1/(1 - 0.75) = 1/0.25$.
> **Answer:** 4"""


async def test_exercises_are_the_courses_own_copied_solved_and_checked(nb):
    is_lm, crowding = await built(nb)
    cid = nb.macro["id"]
    sheet = add_pdf(nb.api, data=PROBLEMS, name="Problem set 2", course=cid).json()
    assert [f["public_id"] for f in nb.notebook.exercise_files(cid)] == [sheet["id"]]  # not the slides
    # Solutions, review questions and a midterm's example questions are exercises too; only papers are past exams.
    names = {"solution_problem_set_1": (True, False), "Macro_AdditionalQU_withSol_ENG": (True, False),
             "Example Questions Midterm": (True, True), "Additional Questions": (True, False),
             "Resource 6 Exercises": (True, False), "Week 4 slides": (False, False)}
    from aide.notebook import _EXERCISE_NAME, _PAST_EXAM
    assert {n: (bool(_EXERCISE_NAME.search(n)), bool(_PAST_EXAM.search(n))) for n in names} == names
    before = len(nb.client.requests)
    exercise_map = {is_lm["public_id"]: [{"file": sheet["id"], "pages": "1"}, {"file": nb.file["id"], "pages": "1"}],
                    "t_000000000000": [{"file": sheet["id"], "pages": "2"}]}
    nb.client.responses += [done(json.dumps(exercise_map)), done(EXERCISES),
                            done("The trap: 2 x 100.\nRESULTS\n1: 200\n3: 4"), done("1: same\n3: different"),
                            done(FIXED)]
    r = nb.api.post(f"/v1/notebook/exercises?course={cid}", json={"topics": [is_lm["public_id"]]}, headers=AUTH)
    assert r.status_code == 202 and r.json()["busy"]
    await drain(nb)
    mapping, write, solve, same, fix = nb.client.requests[before:]
    assert [q["model"] for q in (mapping, write, solve, same, fix)] == ["m", "smart", "m", "m", "smart"]
    # The map sees the outline and the exercise files' pages, not the slides.
    assert f"[{is_lm['public_id']}] The IS-LM model" in sent(mapping)
    assert "p.1: Problem 1: a liquidity trap" in sent(mapping) and "Week 3 slides" not in sent(mapping)
    # The writer: how the exam works, the notes without their questions, and the topic's sheet pages only.
    assert "How the exam works, from the Introduction:\nExam: 20 to 35" in sent(write)
    assert "## The exam\nMultiple choice." in sent(write)
    assert "Investment equals saving" in sent(write) and "What shifts IS to the right?" not in sent(write)
    assert "[Problem set 2.pdf, p. 1]" in sent(write) and "[Problem set 2.pdf, p. 2]" not in sent(write)
    assert "[Week 3 slides.pdf" not in sent(write)  # a sheet's pages only
    # The check: the statements with a final answer, solved blind, then compared; only the disputed one is fixed.
    # One the course solved itself isn't checked.
    assert "> [!success]" not in sent(solve) and "**Exercise 3.**" in sent(solve)
    assert "Explain why the IS curve" not in sent(solve)
    assert "Exercise 3.\nFirst: 3\nSecond: 4" in sent(same)
    assert "(The second solver got: 4)" in sent(fix) and "**Exercise 1.**" not in sent(fix)
    e = nb.notebook.exercise_set(is_lm["id"])
    assert e["body"].startswith("**Exercise 1.**") and e["body"].endswith("> **Answer:** 4") and e["checked"]
    assert json.loads(e["sources"]) == [{"file": sheet["id"], "pages": [1]}]

    listed = nb.api.get(f"/v1/notebook/exercises?course={cid}", headers=AUTH).json()["sets"]
    assert [(x["id"], x["topic"]["title"], x["count"], x["from_material"], x["new"], x["checked"]) for x in listed] \
        == [(e["public_id"], "The IS-LM model", 3, 3, 0, True)]
    full = nb.api.get(f"/v1/exercises/{e['public_id']}?plain=true", headers=AUTH).json()
    assert full["body"].startswith("**Exercise 1.** (from: Problem set 2, p. 1)") and "$" not in full["body"]
    assert full["sources"] == ["Problem set 2, p. 1"]
    assert nb.api.get("/v1/exercises/e_000000000000", headers=AUTH).status_code == 404
    assert nb.api.get(f"/v1/notebook?course={cid}", headers=AUTH).json()["exercises"] == 1
    message = chat_messages(nb)[-1]["text"]
    assert message.startswith("I've copied the course's exercises for **The IS-LM model**: 3 in all, from its "
                              "exercise sheets and past exams, each solved step by step with the solution folded (1 "
                              "following the course's own solutions).") and nb.push.messages

    # Professor reads one without its solution first.
    tools = {t.name: t for t in study_tools(nb.study, ROME, None, nb.notebook)}
    assert "3. (Problem set 2, p. 1) With $c = 0.75$" in await tools["read_exercises"].handler(topic="The IS-LM model")
    statement = await tools["read_exercises"].handler(topic=is_lm["public_id"], n=3)
    assert statement.startswith("**Exercise 3.**") and "[!success]" not in statement
    assert "**Answer:** 4" in await tools["read_exercises"].handler(topic=is_lm["public_id"], n=3, solution=True)
    assert "no exercises yet" in await tools["read_exercises"].handler(topic="Crowding out")

    # The vault: a page per topic, linked from the topic page and the Introduction.
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    page = (root / "Exercises/01 The IS-LM model.md").read_text()
    assert page.startswith('---\ncourse: "[[Aide/macroeconomics/00 Introduction|macroeconomics]]"\n'
                           'topic: "[[Aide/macroeconomics/01 The IS-LM model|The IS-LM model]]"\ntags:\n  - exercises')
    assert "\n# Exercises: The IS-LM model\n" in page and "see [[Aide/macroeconomics/02 Crowding out|Crowding out]]" in page
    assert 'exercises: "[[Aide/macroeconomics/Exercises/01 The IS-LM model|Exercises]]"' in \
        (root / "01 The IS-LM model.md").read_text()
    assert "- Exercises: [[Aide/macroeconomics/Exercises/01 The IS-LM model|The IS-LM model]]" in \
        (root / "00 Introduction.md").read_text()

    # Asking for what can't be done.
    assert nb.api.post(f"/v1/notebook/exercises?course={cid}", json={"topics": ["t_000000000000"]},
                       headers=AUTH).status_code == 400
    assert nb.api.post("/v1/notebook/exercises?course=999", headers=AUTH).status_code == 404
    law = nb.study.course_by_name("business law")["id"]
    assert nb.api.post(f"/v1/notebook/exercises?course={law}", headers=AUTH).status_code == 409


async def test_exercises_only_where_the_course_has_some_and_never_invented(nb):
    is_lm, crowding = await built(nb)
    cid = nb.macro["id"]
    tools = {t.name: t for t in study_tools(nb.study, ROME, None, nb.notebook)}
    # No exercise files at all: nothing to copy.
    r = nb.api.post(f"/v1/notebook/exercises?course={cid}", headers=AUTH)
    assert r.status_code == 409 and "no exercise sheets" in r.json()["error"]
    assert "no exercises to copy" in await tools["write_exercises"].handler(course="macroeconomics")

    # A sheet on one topic only: the other gets no set, and its old one (with exercises of Aide's own) goes.
    nb.notebook.set_exercises(crowding, "**Exercise 1.** (new)\nExplain crowding out.\n> [!success]- Solution\n> "
                              "Rates rise.", [], False)
    sheet = add_pdf(nb.api, data=PROBLEMS, name="Problem set 2", course=cid).json()
    own = "**Exercise 1.** (from: Problem set 2, p. 1)\nThe trap.\n> [!success]- Solution\n> LM is flat."
    nb.client.responses += [done(json.dumps({is_lm["public_id"]: [{"file": sheet["id"], "pages": "1"}]})), done(own)]
    assert nb.api.post(f"/v1/notebook/exercises?course={cid}", headers=AUTH).status_code == 202
    await drain(nb)
    write = nb.client.requests[-1]
    assert "[Problem set 2.pdf, p. 1]" in sent(write) and "Topic: The IS-LM model" in sent(write)
    assert [x["topic"]["title"] for x in nb.api.get(f"/v1/notebook/exercises?course={cid}", headers=AUTH).json()["sets"]] \
        == ["The IS-LM model"]
    assert nb.notebook.exercise_set(crowding["id"]) is None
    message = chat_messages(nb)[-1]["text"]
    assert "1 in all" in message and "No sheet has exercises on Crowding out." in message
    # Asking for that topic alone: nothing on it.
    nb.client.responses.append(done("{}"))
    assert nb.api.post(f"/v1/notebook/exercises?course={cid}", json={"topics": [crowding["public_id"]]},
                       headers=AUTH).status_code == 202
    await drain(nb)
    assert nb.notebook.exercise_set(crowding["id"]) is None


async def test_new_material_is_proposed_from_the_outline_and_merged_into_the_users_version(nb):
    is_lm, crowding = await built(nb)
    nb.worker.vault = nb.vault
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    page = root / "01 The IS-LM model.md"
    page.write_text(page.read_text().replace("It slopes down.", "It slopes down. My own line: see [[02 Crowding out]]."))
    cards = root / "Cards/The IS-LM model.md"
    reviewed = cards.read_text().replace("saving\n", "saving <!--SR:!2026-10-25,3,250-->\n")
    cards.write_text(reviewed)

    f2 = add_pdf(nb.api, data=PROBLEMS, name="Problem set 2", course=nb.macro["id"]).json()
    assert nb.notebook.new_material(nb.macro["id"], [{"file": f2["id"]}])
    triage = [{"topic": is_lm["public_id"], "title": "x", "add": "The liquidity-trap exercise.",
               "sources": [{"file": f2["id"], "pages": "1"}]},
              {"topic": None, "title": "Fiscal policy", "add": "Debt-financed spending.",
               "sources": [{"file": f2["id"], "pages": "2"}], "after": is_lm["public_id"]},
              {"topic": None, "title": "Nothing", "add": "", "sources": []}]
    nb.client.responses.append(done(json.dumps(triage)))
    await drain(nb)
    assert nb.client.requests[-1]["model"] == "m"  # sorting is the cheap model's
    request = sent(nb.client.requests[-1])
    # The triage sees the notebook's outline and the new file's map, not the topics' text.
    assert f"[{is_lm['public_id']}] The IS-LM model: Goods" in request and "The IS curve; The LM curve" in request
    assert "a lower interest rate raises investment" not in request and "p.1: Problem 1: a liquidity trap" in request
    p = nb.notebook.proposals(nb.macro["id"])[0]
    assert p["kind"] == "update" and [it["title"] for it in p["items"]] == ["The IS-LM model", "Fiscal policy"]
    # In a chat of its own (about the course), with the file to open and the proposal to answer as cards.
    chat = p["chat"]
    assert chat and chat != nb.study.chat(nb.macro["id"]) and nb.push.messages[-1][0] == chat
    row = next(c for c in nb.api.get("/v1/conversations", headers=AUTH).json()["conversations"] if c["id"] == chat)
    assert row["title"] == "Macroeconomics: Problem set 2" and row["course"] == nb.macro["id"]
    message = nb.api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"][-1]
    assert message["text"] == ("New in macroeconomics: **Problem set 2**. From it I'd expand 1 topic and add 1 new one "
                               "in the notes. Pick below, or tell me which (\"only 1 and 3\", \"also stress the "
                               "graphs\").")
    files, card = message["attachments"]
    assert files["type"] == "files" and [f["id"] for f in files["files"]] == [f2["id"]]
    assert card["type"] == "proposal" and card["proposal"]["id"] == p["public_id"]
    assert card["proposal"]["conversation_id"] == chat and card["proposal"]["status"] == "pending"
    assert [it["title"] for it in card["proposal"]["items"]] == ["The IS-LM model", "Fiscal policy"]
    # The model reads the items in the note before it.
    note = nb.db.history(nb.db.app_conversation(chat)["id"])[-2]["content"]
    assert "1. Expand **The IS-LM model**: The liquidity-trap exercise." in note
    assert "2. New topic **Fiscal policy**: Debt-financed spending." in note
    assert not nb.notebook.new_material(nb.macro["id"], [])

    # Only the first item, with a wish; the merge builds on the user's edit, read back from the vault.
    merged = PAGE.split("===CARDS===")[0].replace("It slopes down.", "It slopes down. My own line: see [[Crowding out]].")
    merged += "\n### The liquidity trap\nLM is flat at zero."
    merged += "\n===CARDS===\nWhat is a liquidity trap? :: LM flat at zero\nWhat does IS stand for? :: again"
    nb.client.responses.append(done(merged))
    r = nb.api.post(f"/v1/proposals/{p['public_id']}/apply", json={"items": [1], "note": "keep it short"},
                    headers=AUTH)
    assert r.status_code == 202 and r.json()["status"] == "applying"
    await drain(nb)
    request = sent(nb.client.requests[-1])
    assert "My own line: see [[Crowding out]]." in request  # read back, with the link by title
    assert "What to add: The liquidity-trap exercise." in request and "The student asked: keep it short" in request
    assert "[Problem set 2.pdf, p. 1]" in request and "[Problem set 2.pdf, p. 2]" not in request
    t = nb.notebook.topic(is_lm["public_id"])
    assert "### The liquidity trap" in t["body"] and "My own line" in t["prev_body"] and t["edited_at"]
    assert [q for q, _ in json.loads(t["cards"])] == ["What does IS stand for?", "What shifts LM?",
                                                      "What is a liquidity trap?"]
    assert {"file": f2["id"], "pages": [1]} in json.loads(t["sources"])
    assert [x["title"] for x in nb.notebook.topics(nb.macro["id"])] == ["The IS-LM model", "Crowding out"]
    # The result comes in the proposal's chat, and its card shows it applied.
    after = nb.api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert after[-1]["text"].startswith("Updated the notes: **The IS-LM model**.")
    assert after[-2]["attachments"][1]["proposal"]["status"] == "applied"

    await nb.vault.sync()
    assert "LM is flat at zero." in page.read_text()
    assert "[[Aide/macroeconomics/02 Crowding out|Crowding out]]" in page.read_text()
    # Cards are only added to: the plugin's review note stays.
    assert cards.read_text() == reviewed + "What is a liquidity trap?::LM flat at zero\n"


async def test_a_new_file_before_the_outline_is_answered_replans_it(nb):
    first = await started(nb)
    f2 = add_pdf(nb.api, data=PROBLEMS, name="Problem set 2", course=nb.macro["id"]).json()
    nb.notebook.new_material(nb.macro["id"], [{"file": f2["id"]}])
    nb.client.responses.append(done(json.dumps([{"title": "Everything", "sources": [{"file": f2["id"]}]}])))
    await drain(nb)
    assert nb.notebook.proposal(first["public_id"])["status"] == "superseded"
    assert nb.notebook.proposals(nb.macro["id"])[0]["items"][0]["sources"] == [{"file": f2["id"], "pages": [1, 2]}]
    other = nb.study.course_by_name("business law")["id"]
    assert not nb.notebook.new_material(other, [{"file": f2["id"]}])  # no notebook there


async def test_professor_reads_the_notebook_a_section_at_a_time(nb):
    is_lm, _ = await built(nb)
    tools = nb.agent.tools

    async def use(name, **args):
        return await tools.call(name, args)
    outline = await use("notebook", course="macroeconomics")
    assert "Exam: 20 to 35" in outline and f"1. [{is_lm['public_id']}] The IS-LM model: Goods" in outline
    assert "(1 questions, 2 cards)" in outline and "investment and so output" not in outline
    formulas = await use("read_topic", topic="the is-lm model", section="formulas")
    assert "$Y = C + I + G$" in formulas and "The IS curve" not in formulas
    lm = await use("read_topic", topic=is_lm["public_id"], section="Explanation › The LM curve")
    assert "Money demand" in lm and "Investment equals" not in lm
    assert "has no section 'Graphs'" in await use("read_topic", topic="The IS-LM model", section="Graphs")
    found = await use("search_study", query="money supply")
    assert found.startswith(f"[{is_lm['public_id']}] The IS-LM model › Explanation › The LM curve")
    await use("edit_topic", topic="The IS-LM model", section="Formulas", text="$Y = C + I + G + NX$")
    t = nb.notebook.topic(is_lm["public_id"])
    assert "$Y = C + I + G + NX$\n\n## Exam-style questions" in t["body"] and "$Y = C + I + G$" in t["prev_body"]
    assert "No proposals are waiting." == await use("proposals")


async def test_declining_and_the_proposals_list(nb):
    p = await started(nb)
    listed = nb.api.get("/v1/proposals", headers=AUTH).json()["proposals"]
    assert [x["id"] for x in listed] == [p["public_id"]]
    assert nb.api.post(f"/v1/proposals/{p['public_id']}/apply", json={"items": [3]}, headers=AUTH).status_code == 400
    assert nb.api.post(f"/v1/proposals/{p['public_id']}/decline", headers=AUTH).json()["status"] == "declined"
    assert nb.api.get("/v1/proposals", headers=AUTH).json()["proposals"] == []
    assert len(nb.api.get("/v1/proposals?status=all", headers=AUTH).json()["proposals"]) == 1
    assert nb.api.post("/v1/proposals/p_000000000000/decline", headers=AUTH).status_code == 404


async def test_old_tool_results_are_cut_in_the_replayed_history(nb, tmp_path):
    long = make_pdf(None, [f"Page {n}: " + "word " * 15 for n in range(30)])
    f = add_pdf(nb.api, data=long, name="Long", course=nb.macro["id"]).json()
    chat = nb.study.chat(nb.macro["id"])
    nb.client.responses += [call("read_file", file_id=f["id"]), done("Read it."), done("Again.")]
    await nb.agent.reply(CONVERSATION, "read the long file", chat)
    full = nb.client.requests[-1]["messages"][-1]["content"][0]["content"]
    assert len(full) > 2000  # whole within its own turn
    await nb.agent.reply(CONVERSATION, "and now?", chat)
    request = nb.client.requests[-1]
    old = next(b for m in request["messages"] if isinstance(m["content"], list) for b in m["content"]
               if b.get("type") == "tool_result")
    assert old["content"].startswith(full[:300]) and "more characters left out of this old result" in old["content"]
    assert "that answer stands" in old["content"] and len(old["content"]) < 600
    assert request["system"][0]["cache_control"] == {"type": "ephemeral"}
    assert request["messages"][-1]["content"][-1]["cache_control"] == {"type": "ephemeral"}
    stored = [m for m in nb.db.history(nb.db.app_conversation(chat)["id"]) if isinstance(m["content"], list)]
    assert any(b.get("content") == full for m in stored for b in m["content"])  # the database keeps it whole


async def test_figures_are_drawn_from_the_slides_and_read_back(nb):
    p = await started(nb)
    fid = nb.file["id"]
    page = PAGE.replace("It slopes down.", "It slopes down.\n\nFIGURE: Week 3 slides.pdf, p. 1 | The IS curve sloping down"
                        "\nFIGURE: Nowhere.pdf, p. 2 | made up\n**FIGURE:** week 3 slides, p. 9 | out of range")
    nb.client.responses.append({"The IS-LM model": [done(page), done('{"1": "A"}')], "Crowding out": done(CROWDING)})
    nb.api.post(f"/v1/proposals/{p['public_id']}/apply", headers=AUTH)
    await drain(nb)
    request = next(r for r in nb.client.requests if "Topic: The IS-LM model\n" in sent(r))
    marks = [b["text"] for b in request["messages"][-1]["content"][:4] if b["type"] == "text"]
    assert sorted(marks) == ["[Week 3 slides.pdf, p. 1]", "[Week 3 slides.pdf, p. 2]"]  # each image after its mark
    t = nb.notebook.find_topic("The IS-LM model")
    assert f"It slopes down.\n\n![The IS curve sloping down](figure:{fid}/1)\n\n### The LM curve" in t["body"]
    assert "made up" not in t["body"] and "out of range" not in t["body"]

    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    image, page_file = root / "Images/Week 3 slides p1.jpg", root / "01 The IS-LM model.md"
    assert image.read_bytes()[:2] == b"\xff\xd8"
    text = page_file.read_text()
    assert "![[Aide/macroeconomics/Images/Week 3 slides p1.jpg]]\n*The IS curve sloping down*" in text
    page_file.write_text(text.replace("*The IS curve sloping down*", "*IS, my caption*"))
    assert nb.vault.pull() == 1
    body = nb.notebook.topic(t["public_id"])["body"]
    assert f"![IS, my caption](figure:{fid}/1)" in body and "Images/" not in body
    # A figure no topic shows any more goes from the vault.
    nb.notebook.set_body(t["id"], body.replace(f"![IS, my caption](figure:{fid}/1)", ""))
    await nb.vault.sync()
    assert not image.exists() and "Images/" not in page_file.read_text()


async def test_figures_for_pages_already_written(nb):
    is_lm, _ = await built(nb)
    fid = nb.file["id"]
    nb.client.responses += [
        done(json.dumps([{"after": "Explanation › The LM curve", "file": "Week 3 slides.pdf", "page": 2,
                          "caption": "LM sloping up"},
                         {"after": "Nowhere", "file": "Week 3 slides.pdf", "page": 1, "caption": "lost"}])),
        done("[]")]
    nb.notebook.enqueue(nb.macro["id"], "figures")
    await drain(nb)
    first = nb.client.requests[-2]
    assert len(images(first)) == 2 and "Explanation › The LM curve" in sent(first)
    assert "investment and so output" not in sent(first)  # headings only, not the page
    body = nb.notebook.topic(is_lm["public_id"])["body"]
    assert f"the interest rate.\n\n![LM sloping up](figure:{fid}/2)\n\n## Formulas" in body and "lost" not in body
    assert chat_messages(nb)[-1]["text"] == "Added slide figures to the notes: The IS-LM model (1). They're in Obsidian."


async def test_a_disputed_answer_key_is_looked_at_again(nb):
    topic = nb.notebook.add_topic(nb.macro["id"], "The IS-LM model", "", [])
    second = ("**2.** What does a flat LM curve mean?\n- A) A liquidity trap\n- B) Full crowding out\n"
              "> [!success]- Answer\n> **B**. Wrong on purpose.")
    body = PAGE.split("===CARDS===")[0] + "\n\n" + second
    fixed = second.replace("> **B**. Wrong on purpose.", "> **A**. Money demand is flat at a zero rate.")
    nb.client.responses += [done('{"1": "A", "2": "A"}'), done(json.dumps([{"n": 2, "block": fixed}]))]
    out = await nb.worker.check_answers(topic, body)
    check, fix = nb.client.requests
    assert check["model"] == "m" and fix["model"] == "smart"
    assert "> [!success]" not in sent(check) and "**2.** What does a flat LM" in sent(check)
    assert "Money demand equals the money supply" in sent(check)  # the notes, without the questions
    assert "**1.**" not in sent(fix) and "(The second reader chose: A)" in sent(fix)
    assert out == body.replace(second, fixed)
    # A merge checks only the questions that are new.
    assert await nb.worker.check_answers(topic, out, out) == out and len(nb.client.requests) == 2


def test_page_parsing():
    body, cards = parse_page("# Title\nOne line.\n\n## Formulas\n$a$\n" + "===CARDS===\nQ1 :: A1\nno card\n* Q2::A2 :: more")
    assert body == "One line.\n\n## Formulas\n$a$" and cards == [("Q1", "A1"), ("Q2", "A2 : more")]
    assert sections("Intro.\n## A\na\n### B\nb\n## C\nc") == [("", "Intro."), ("A", "a"), ("A › B", "b"), ("C", "c")]


async def test_the_slide_scan_picks_the_figures_whatever_their_text(nb):
    is_lm, _ = await built(nb)  # its scan answer couldn't be read: nothing scanned yet
    fid = nb.file["id"]
    nb.client.scans.clear()
    nb.client.scan = lambda pages: [{"page": 2, "what": "the LM curve"}] if 2 in pages else []
    nb.client.responses.append(done(json.dumps([{"after": "Explanation › The LM curve", "file": "Week 3 slides.pdf",
                                                 "page": 2, "caption": "LM sloping up"}])))
    assert nb.api.post(f"/v1/notebook/figures?course={nb.macro['id']}", headers=AUTH).status_code == 202
    await drain(nb)
    # Each topic's own slides, once: The IS-LM model's two, then Crowding out's one.
    assert [len(images(r)) for r in nb.client.scans] == [2, 1]
    request = nb.client.requests[-1]
    assert len(images(request)) == 1  # only the slide with a figure; Crowding out's slide has none: no call
    body = nb.notebook.topic(is_lm["public_id"])["body"]
    assert f"![LM sloping up](figure:{fid}/2)" in body

    # Asked again: no slide is looked at twice, and a figure the page has isn't offered again.
    before = len(nb.client.requests)
    nb.notebook.enqueue(nb.macro["id"], "figures", again=True)
    await drain(nb)
    assert len(nb.client.scans) == 2 and len(nb.client.requests) == before
    nb.notebook.set_looks(nb.notebook.files.get(fid)["id"], [(1, True, "the IS curve")])
    nb.client.responses.append(done("[]"))
    nb.notebook.enqueue(nb.macro["id"], "figures", again=True)
    await drain(nb)
    request = nb.client.requests[-1]
    assert len(images(request)) == 1 and "Figures the page already has: LM sloping up. Add only ones that show " \
        "something these don't, at most 3." in sent(request)
    assert nb.api.post("/v1/notebook/figures?course=999", headers=AUTH).status_code == 404


async def test_the_scan_sends_only_slides_that_may_hold_a_figure(nb, tmp_path):
    words = "\n".join(["A bullet point with plenty of words on the rules of the course"] * 3)
    data = make_pdf(None, [words, words, "A chart"], shapes=[0, 8, 0])  # p. 2 draws boxes, p. 3 is short of text
    f = add_pdf(nb.api, data=data, course=nb.macro["id"]).json()
    nb.client.scan = lambda pages: [{"page": 2, "what": "a tree of the accounting books"}]
    assert await nb.worker.scan([{"file": f["id"], "pages": [1, 2, 3]}]) == 2
    assert [len(images(r)) for r in nb.client.scans] == [2]  # the bullet list is marked without a call
    assert nb.notebook.looks(nb.notebook.files.get(f["id"])["id"]) == {1: False, 2: True, 3: False}
    assert await nb.worker.scan([{"file": f["id"]}]) == 0 and len(nb.client.scans) == 1  # never twice
    one = tmp_path / "one.pdf"
    make_pdf(one, [words], shapes=[8])
    assert await visual_pages(one, 1) == {1}  # one page: pdftocairo's SVG has no <page> around it


def test_money_and_sentence_formulas_made_safe_for_obsidian():
    raw = ("Output $13.5 trillion, output per person $9,700. Ranges $5–$10, $10k a year, costs $5.\n"
           "Growth $1909/1632-1=+17.0\\%$ and about $0.6/4\\approx 15$–$20\\%$, $1$ unit.\n"
           "The curve: $$\\pi - \\pi^e = -\\alpha(u-u_n)$$ where $u_n$ is natural.\n"
           "$$Y = C + I + G$$\n> $$Y = N$$\nAlready \\$3 billion.")
    assert tidy_math(raw) == (
        "Output \\$13.5 trillion, output per person \\$9,700. Ranges \\$5–\\$10, \\$10k a year, costs \\$5.\n"
        "Growth $1909/1632-1=+17.0\\%$ and about $0.6/4\\approx 15$–$20\\%$, $1$ unit.\n"
        "The curve: $\\pi - \\pi^e = -\\alpha(u-u_n)$ where $u_n$ is natural.\n"
        "$$Y = C + I + G$$\n> $$Y = N$$\nAlready \\$3 billion.")
    assert tidy_math(tidy_math(raw)) == tidy_math(raw)


def test_set_body_tidies_aides_text_not_the_users(nb):
    topic = nb.notebook.add_topic(nb.macro["id"], "Data", "", [])
    t = nb.notebook.set_body(topic["id"], "GDP is $13.5 trillion.", cards=[("GDP in $?", "$13.5 trillion")])
    assert t["body"] == "GDP is \\$13.5 trillion." and json.loads(t["cards"]) == [["GDP in $?", "\\$13.5 trillion"]]
    assert nb.notebook.set_body(topic["id"], "Mine: $5 here.", by_user=True)["body"] == "Mine: $5 here."


async def test_writing_topics_shows_on_the_lock_screen(nb):
    calls = []

    class Run:
        detail = ""

        def start(self, detail): calls.append(("start", detail))
        def step(self, detail): calls.append(("step", detail))
        def progress(self): calls.append(("progress",))
        def finished(self, result): calls.append(("finished", result))
        def failed(self, error): calls.append(("failed", error))

    class Live:
        def notes(self, key, conversation, title, total=None):
            calls.append(("notes", key.split(":")[0], conversation == nb.study.chat(nb.macro["id"]), title, total))
            return Run()
    nb.worker.live = Live()
    await built(nb)
    assert calls[0] == ("notes", "notes", True, "Macroeconomics", 2)
    assert calls[1] == ("start", "Writing 2 topics")
    assert sum(c == ("progress",) for c in calls) == 2 and any(c[0] == "step" for c in calls)
    assert calls[-1] == ("finished", "Wrote The IS-LM model, Crowding out.")
