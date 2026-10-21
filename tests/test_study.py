import base64
import json
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

import aide.channels.api as api_module
import aide.study as study_module
from aide.agent import CONVERSATION, Agent
from aide.agents import STUDY, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.icloud import CalEvent
from aide.photos import PhotoStore
from aide.push import Push
from aide.reminders import ReminderStore
from aide.study import StudyStore, StudyWorker, paragraphs
from aide.tools import ToolRegistry
from aide.tools.study import study_tools
from test_api import AUTH, TOKEN, FakeCalendar, call, done
from test_food import JPEG, RecordingClient, images

ROME = ZoneInfo("Europe/Rome")
M4A = b"\x00\x00\x00\x1cftypM4A fake-audio"
NOTES = "# The IS-LM model\nHow the goods and money markets settle together.\n\n## Summary\nIS meets LM."
NOW = datetime.now(timezone.utc).replace(microsecond=0)


def z(when: datetime) -> str:
    """UTC with a Z, as the app sends it (a + in a query string would read as a space)."""
    return when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def weekly(title: str, start: datetime, hours: int = 2) -> list[CalEvent]:
    return [CalEvent(f"{title}{w}", "Work", title, start + timedelta(weeks=w), start + timedelta(weeks=w, hours=hours))
            for w in range(-1, 2)]


EVENTS = [
    *weekly("macroeconomics", NOW - timedelta(hours=1)),
    *weekly("business law", NOW - timedelta(days=1, hours=2)),
    *weekly("study", NOW + timedelta(days=2)),  # the user's own study blocks
    CalEvent("6", "Work", "Dentist", NOW + timedelta(days=3), NOW + timedelta(days=3, hours=1)),  # a one-off
    CalEvent("3", "Exam", "Macroeconomics exam", NOW + timedelta(days=20), NOW + timedelta(days=20, hours=2)),
    CalEvent("4", "Exam", "microeconomics exam", NOW - timedelta(days=30), NOW - timedelta(days=30, hours=-2)),
    CalEvent("5", "Meal", "lunch", NOW - timedelta(hours=1), NOW),
]


class FakePush(Push):
    def __init__(self, conn):
        super().__init__(conn)
        self.sent: list[tuple[str, str, str]] = []

    async def send_lecture(self, lecture_id, title, body):
        self.sent.append((lecture_id, title, body))
        return True


class Transcribe:
    def __init__(self, text="[0:00] Today, the IS-LM model.", fail=False):
        self.text, self.fail, self.calls = text, fail, []

    async def __call__(self, path):
        self.calls.append(path)
        if self.fail:
            raise RuntimeError("transcription failed")
        return self.text, "en", 84


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")

    def make(responses=(), transcribe=Transcribe(), events=EVENTS):
        client = RecordingClient(responses)
        study = StudyStore(db, ROME, FakeCalendar(list(events)))
        agent = Agent(client, db, ToolRegistry(study_tools(study, ROME, tmp_path / "audio")), model="m",
                      smart_model="smart", tz=ROME, photos=PhotoStore(tmp_path / "photos"), delegate=False)
        push = FakePush(db.conn)
        worker = StudyWorker(study, agent, push, tmp_path / "audio", transcribe)
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar(list(events)), ROME, TOKEN, push=push,
                         study=study, worker=worker)
        return TestClient(app), study, worker, push, client
    yield make
    db.close()


def upload(api, data=M4A, kind="audio/mp4", **query):
    return api.post("/v1/lectures", params={"recorded_at": z(NOW), **query}, content=data,
                    headers={**AUTH, "Content-Type": kind})


def test_courses_and_exams_come_from_the_calendar(env):
    api, *_ = env()
    body = api.get("/v1/study", headers=AUTH).json()
    courses = {c["name"]: c for c in body["courses"]}
    # Not the Meal calendar, nor a one-off, nor the skipped study blocks.
    assert list(courses) == ["business law", "macroeconomics"]
    macro = courses["macroeconomics"]
    assert macro["lectures"] == 0 and macro["last_lecture"] is None and macro["chat"] is None
    assert macro["next_exam"]["title"] == "Macroeconomics exam"  # case doesn't matter
    assert courses["business law"]["next_exam"] is None  # the microeconomics one is past, and not this course
    assert body["now"]["course"] == macro["id"] and body["now"]["name"] == "macroeconomics"
    assert body["unfiled"] == 0 and body["transcription"] is True
    assert api.get("/v1/study").status_code == 401


def test_a_recording_is_filed_transcribed_and_noted(env, tmp_path):
    api, study, worker, push, client = env([done(NOTES)])
    r = upload(api)
    assert r.status_code == 202
    lecture = r.json()
    macro = study.course_by_name("macroeconomics")
    assert lecture["course"] == macro["id"] and lecture["status"] == "queued" and lecture["has_audio"]
    assert (tmp_path / "audio" / f"{lecture['id']}.m4a").read_bytes() == M4A
    assert not list((tmp_path / "audio").glob(".*.tmp"))

    done_ = study.as_json(_run(worker), full=True, transcript=True)
    assert done_["status"] == "ready" and done_["title"] == "The IS-LM model"
    assert done_["summary"] == "How the goods and money markets settle together."
    assert not done_["notes"].startswith("#") and "## Summary" in done_["notes"]
    assert done_["transcript"].startswith("[0:00]") and done_["duration_s"] == 84 and done_["language"] == "en"
    sent = client.requests[0]
    assert sent["model"] == "smart" and "Course: macroeconomics" in sent["messages"][0]["content"][-1]["text"]
    assert "Transcript:\n[0:00] Today" in sent["messages"][0]["content"][-1]["text"]
    assert push.sent == [(lecture["id"], "Professor · macroeconomics", done_["summary"])]
    # A note in the course's Professor chat: only Professor's message shows, not the note before it.
    chat = api.get("/v1/study", headers=AUTH).json()["courses"][1]["chat"]
    messages = api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert [m["role"] for m in messages] == ["assistant"] and "The IS-LM model" in messages[0]["text"]
    row = study.db.app_conversation(chat)
    assert row["agent"] == "professor" and row["title"] == "Macroeconomics"


def _run(worker: StudyWorker) -> dict:
    import asyncio
    return asyncio.run(worker.process(worker.store.next_queued()))


def test_bad_uploads(env, monkeypatch):
    api, *_ = env()
    assert upload(api, kind="video/mp4").status_code == 415
    assert upload(api, b"").status_code == 400
    assert upload(api, course=999).status_code == 400
    r = api.post("/v1/lectures", params={"recorded_at": "2026-10-21T08:00:00"}, content=M4A,
                 headers={**AUTH, "Content-Type": "audio/mp4"})
    assert r.status_code == 400 and "UTC offset" in r.json()["error"]
    monkeypatch.setattr(api_module, "MAX_LECTURE", 10)
    assert upload(api).status_code == 413
    api, *_ = env(transcribe=None)
    assert upload(api).status_code == 503
    assert api.get("/v1/study", headers=AUTH).json()["transcription"] is False


def test_photos_and_text_skip_whisper_and_an_unmatched_one_is_unfiled(env, tmp_path):
    api, study, worker, push, client = env([done(NOTES)])
    photo = PhotoStore(tmp_path / "photos").save(JPEG, "image/jpeg")
    yesterday = NOW - timedelta(days=1, hours=6)  # no lecture then
    r = api.post("/v1/lectures", json={"photos": [photo], "text": "Slides 4-9", "recorded_at": yesterday.isoformat()},
                 headers=AUTH)
    assert r.status_code == 202 and r.json()["course"] is None and not r.json()["has_audio"]
    lecture = _run(worker)
    assert lecture["status"] == "ready" and worker.transcribe.calls == []
    assert len(images(client.requests[0])) == 1
    assert "What the student typed:\nSlides 4-9" in client.requests[0]["messages"][0]["content"][-1]["text"]
    assert push.sent[0][1] == "Professor"  # unfiled: no course chat, but a push
    assert api.get("/v1/study", headers=AUTH).json()["unfiled"] == 1
    assert [x["id"] for x in api.get("/v1/lectures?course=none", headers=AUTH).json()["lectures"]] == \
           [lecture["public_id"]]
    assert api.post("/v1/lectures", json={"photos": ["p_0000000000000000"]}, headers=AUTH).status_code == 400
    assert api.post("/v1/lectures", json={}, headers=AUTH).status_code == 400


def test_a_failed_lecture_can_be_retried_and_a_restart_requeues(env):
    api, study, worker, push, _ = env(transcribe=Transcribe(fail=True))
    lecture_id = upload(api).json()["id"]
    failed = _run(worker)
    assert failed["status"] == "failed" and failed["error"] == "transcription failed"
    assert push.sent[0][2] == "Couldn't make notes from this lecture: transcription failed"
    r = api.post(f"/v1/lectures/{lecture_id}/retry", headers=AUTH)
    assert r.status_code == 202 and r.json()["status"] == "queued" and r.json()["error"] is None
    assert api.post(f"/v1/lectures/{lecture_id}/retry", headers=AUTH).status_code == 400  # only a failed one
    study.set_status(study.find(lecture_id)["id"], "transcribing")
    assert study.requeue() == 1 and study.find(lecture_id)["status"] == "queued"


def test_a_long_transcript_is_noted_in_parts(env, monkeypatch):
    monkeypatch.setattr(study_module, "PART_CHARS", 40)
    text = "\n\n".join(f"[{i}:00] " + "word " * 8 for i in range(3))  # each paragraph over 40: a part each
    api, study, worker, _, client = env([done("part one"), done("part two"), done("part three"), done(NOTES)],
                                        transcribe=Transcribe(text))
    upload(api)
    assert _run(worker)["status"] == "ready"
    assert len(client.requests) == 4
    final = client.requests[-1]["messages"][0]["content"][-1]["text"]
    assert "(Working notes, part 1)\npart one" in final and "[0:00]" not in final


def test_lecture_endpoints(env, tmp_path):
    api, study, worker, *_ = env([done(NOTES)])
    lecture_id = upload(api).json()["id"]
    _run(worker)
    law = study.course_by_name("business law")["id"]
    full = api.get(f"/v1/lectures/{lecture_id}", headers=AUTH).json()
    assert full["notes"].startswith("How the goods") and "transcript" not in full
    assert api.get(f"/v1/lectures/{lecture_id}?transcript=true", headers=AUTH).json()["transcript"]
    r = api.patch(f"/v1/lectures/{lecture_id}", json={"course": law, "title": "  Week 3  ", "notes": "New"},
                  headers=AUTH).json()
    assert (r["course"], r["title"], r["notes"]) == (law, "Week 3", "New")
    assert study.find(lecture_id)["notes_prev"].startswith("How the goods")
    assert [x["id"] for x in api.get(f"/v1/lectures?course={law}", headers=AUTH).json()["lectures"]] == [lecture_id]
    assert api.patch(f"/v1/lectures/{lecture_id}", json={"course": None}, headers=AUTH).json()["course"] is None
    assert api.patch(f"/v1/lectures/{lecture_id}", json={"course": 999}, headers=AUTH).status_code == 400
    assert api.get("/v1/lectures?course=x", headers=AUTH).status_code == 400
    assert api.get("/v1/lectures/l_000000000000", headers=AUTH).status_code == 404
    assert api.get("/v1/lectures/..%2Fx", headers=AUTH).status_code == 404
    chat = api.post(f"/v1/study/courses/{law}/chat", headers=AUTH).json()["conversation_id"]
    assert api.post(f"/v1/study/courses/{law}/chat", headers=AUTH).json()["conversation_id"] == chat
    assert api.post("/v1/study/courses/999/chat", headers=AUTH).status_code == 404
    assert api.delete(f"/v1/lectures/{lecture_id}", headers=AUTH).json() == {"ok": True}
    assert not (tmp_path / "audio" / f"{lecture_id}.m4a").exists()
    assert api.delete(f"/v1/lectures/{lecture_id}", headers=AUTH).status_code == 404


async def test_professors_tools_search_change_and_queue_a_delete(env):
    api, study, worker, _, client = env()
    macro = (await study.match(NOW))["id"]
    lecture = study.add(NOW, macro, "IS-LM", text="notes")
    study.set_transcript(lecture["id"], "[0:00] The multiplier is one over one minus the propensità to consume.",
                         "en", 60)
    study.set_notes(lecture["id"], "The multiplier.\n\n## Summary\nMultiplier.")
    lid = lecture["public_id"]
    agent = worker.agent
    client.responses = [call("search_study", query="propensita multiplier"), done("Found it."),
                        call("update_notes", lecture_id=lid, notes="The multiplier, 1/(1-c)."), done("Updated."),
                        call("delete_lecture", lecture_id=lid), done("Queued.")]
    await agent.respond(CONVERSATION, "where did we see the multiplier?")
    found = client.requests[1]["messages"][-1]["content"][0]["content"]
    assert lid in found and "«propensità»" in found  # accents ignored, the snippet marks the match
    assert study.search("AND") == [] and study.search("") == []
    await agent.respond(CONVERSATION, "add the formula")
    assert study.find(lid)["notes"] == "The multiplier, 1/(1-c)." and study.find(lid)["notes_prev"]
    await agent.respond(CONVERSATION, "delete it")
    assert study.get(lid) is not None and "Delete the macroeconomics lecture 'IS-LM'" in agent.pending(CONVERSATION)[0]
    await agent.confirm(CONVERSATION)
    assert study.get(lid) is None and study.search("multiplier") == []


def test_whisper_output_becomes_paragraphs_a_minute_apart():
    out = "\n".join([json.dumps([0.0, "Good morning."]), json.dumps([20.5, "Today, IS-LM."]),
                     json.dumps([61.2, "The IS curve."]), json.dumps([3725.0, "Last bit."]),
                     json.dumps({"language": "it", "duration": 3730})])
    assert paragraphs(out) == ("[0:00] Good morning. Today, IS-LM.\n\n[1:01] The IS curve.\n\n[1:02:05] Last bit.",
                               "it", 3730)


def test_the_study_connector_can_change_notes():
    assert connectors(list(STUDY)) == [{"id": "study", "name": "Study notes", "read_only": False,
                                        "tools": list(STUDY)}]


# -- files ---------------------------------------------------------------------------


def make_pdf(path, pages: list[str]) -> bytes:
    """A real PDF with these pages of text (pdftotext must read it), written by hand: one Helvetica text line each."""
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", None, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    kids = []
    for text in pages:
        stream = f"BT /F1 12 Tf 72 720 Td ({text}) Tj ET".encode()
        objs.append(f"<< /Length {len(stream)} >>\nstream\n{stream.decode()}\nendstream")
        objs.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {len(objs)} 0 R "
                    "/Resources << /Font << /F1 3 0 R >> >> >>")
        kids.append(f"{len(objs)} 0 R")
    objs[1] = f"<< /Type /Pages /Kids [{' '.join(kids)}] /Count {len(kids)} >>"
    out, offsets = b"%PDF-1.4\n", []
    for i, body in enumerate(objs, 1):
        offsets.append(len(out))
        out += f"{i} 0 obj\n{body}\nendobj\n".encode()
    xref = len(out)
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
    out += "".join(f"{o:010d} 00000 n \n" for o in offsets).encode()
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    if path is not None:
        path.write_bytes(out)
    return out


SLIDES = make_pdf(None, ["The IS curve: investment equals saving, a long first slide with plenty of words",
                         "LM: liquidity preference equals money supply, on the second slide of the deck",
                         "Crowding out: when government spending raises the interest rate"])


def add_pdf(api, data=SLIDES, **query):
    return api.post("/v1/files", params={"name": "Week 3 slides", **query}, content=data,
                    headers={**AUTH, "Content-Type": "application/pdf"})


def test_a_pdf_is_read_page_by_page_and_searched(env):
    api, study, *_ = env()
    api.get("/v1/study", headers=AUTH)
    law = study.course_by_name("business law")["id"]
    r = add_pdf(api, course=law)
    assert r.status_code == 201
    f = r.json()
    assert (f["name"], f["pages"], f["course"], f["lecture"], f["source"], f["scanned"]) == \
           ("Week 3 slides.pdf", 3, law, None, "upload", False)
    assert api.get(f"/v1/files/{f['id']}/pdf", headers=AUTH).content == SLIDES
    found = study.files.search("crowding interest", law)
    assert [(x["public_id"], x["page"]) for x in found] == [(f["id"], 3)] and "«Crowding»" in found[0]["snippet"]
    assert study.files.search("crowding", law + 1) == []
    assert api.get(f"/v1/files?course={law}", headers=AUTH).json()["files"][0]["id"] == f["id"]
    assert {c["name"]: c["files"] for c in api.get("/v1/study", headers=AUTH).json()["courses"]}["business law"] == 1
    assert add_pdf(api, b"not a pdf").status_code == 400
    assert add_pdf(api, b"").status_code == 400
    assert api.post("/v1/files", content=SLIDES, headers={**AUTH, "Content-Type": "image/png"}).status_code == 415
    assert api.patch(f"/v1/files/{f['id']}", json={"name": "Handout"}, headers=AUTH).json()["name"] == "Handout.pdf"
    assert api.delete(f"/v1/files/{f['id']}", headers=AUTH).json() == {"ok": True}
    assert study.files.search("crowding") == [] and api.get(f"/v1/files/{f['id']}", headers=AUTH).status_code == 404


def test_slides_added_to_a_ready_lecture_rewrite_its_notes(env):
    api, study, worker, push, client = env([done(NOTES), done("# Better\nWith the slides.\n\n## Summary\nIS, LM.")])
    lecture = upload(api).json()
    _run(worker)
    f = add_pdf(api, lecture=lecture["id"]).json()
    assert f["lecture"] == lecture["id"] and f["course"] == lecture["course"]
    assert study.find(lecture["id"])["status"] == "queued"
    done_ = _run(worker)
    assert worker.transcribe.calls == [worker.audio_dir / f"{lecture['id']}.m4a"]  # not transcribed again
    assert done_["notes"].startswith("With the slides.") and done_["notes_prev"].startswith("How the goods")
    assert done_["title"] == "The IS-LM model"  # the user's (or the first) title stays
    sent = client.requests[-1]["messages"][0]["content"]
    pages = [base64.b64decode(b["source"]["data"]) for b in sent if b["type"] == "image"]
    assert len(pages) == 3 and all(p.startswith(b"\xff\xd8") for p in pages)  # every page of a short deck, drawn
    assert "Slides, Week 3 slides.pdf (3 pages" in sent[-1]["text"] and "[p. 2]\nLM: liquidity" in sent[-1]["text"]
    assert "rewrote the notes" in push.sent[-1][2]
    assert api.get(f"/v1/lectures/{lecture['id']}", headers=AUTH).json()["files"] == [f["id"]]
    # Deleting the lecture keeps the slides, as course material.
    api.delete(f"/v1/lectures/{lecture['id']}", headers=AUTH)
    assert api.get(f"/v1/files/{f['id']}", headers=AUTH).json()["lecture"] is None


def test_a_lecture_from_files_alone(env):
    api, study, worker, _, client = env([done(NOTES)])
    f = add_pdf(api).json()
    r = api.post("/v1/lectures", json={"files": [f["id"]], "recorded_at": z(NOW)}, headers=AUTH)
    assert r.status_code == 202 and r.json()["files"] == [f["id"]]
    assert study.files.get(f["id"])["course_id"] == r.json()["course"]  # filed with the lecture
    assert _run(worker)["status"] == "ready" and worker.transcribe.calls == []
    assert api.post("/v1/lectures", json={"files": ["f_000000000000"]}, headers=AUTH).status_code == 400


async def test_moodle_slides_near_a_lecture_are_attached(env, tmp_path):
    api, study, worker, *_ = env([done(NOTES)])
    macro = (await study.match(NOW))["id"]
    pdf = tmp_path / "s.pdf"
    make_pdf(pdf, ["Slides for today"])
    f = await study.files.add(pdf, "IS-LM.pdf", macro, source="moodle", source_key="https://m/1",
                              source_time=int((NOW - timedelta(hours=3)).timestamp()))
    upload(api)
    lecture = await worker.process(study.next_queued())
    assert study.files.get(f["public_id"])["lecture_id"] == lecture["id"]


async def test_professor_reads_files(env, tmp_path):
    api, study, worker, _, client = env()
    api.get("/v1/study", headers=AUTH)
    f = add_pdf(api, course=study.course_by_name("macroeconomics")["id"]).json()
    client.responses = [call("search_study", query="liquidity"), call("read_file", file_id=f["id"], first_page=2,
                                                                      last_page=3), done("p. 2")]
    await worker.agent.respond(CONVERSATION, "what's LM?")
    searched, read = (m["content"][0]["content"] for m in client.requests[2]["messages"][-3::2])
    assert f"[{f['id']}] Week 3 slides.pdf, p. 2" in searched
    assert "[p. 2]\nLM: liquidity" in read and "[p. 1]" not in read
