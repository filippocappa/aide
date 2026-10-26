import base64
import hashlib
from datetime import timedelta
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.moodle import MoodleSync, token_from
from aide.notebook import NotebookStore
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.study import StudyStore, StudyWorker
from aide.tools import ToolRegistry
from test_api import AUTH, TOKEN, FakeCalendar, done
from test_food import RecordingClient
from test_study import EVENTS, NOTES, NOW, ROME, SLIDES, FakePush, Transcribe, upload

SITE = "https://elearning.unito.it/sme"
T = int((NOW - timedelta(hours=2)).timestamp())  # when the files went up


def callback(passport: str, token: str = "tok", site: str = SITE) -> str:
    signed = hashlib.md5((site + passport).encode()).hexdigest()
    return "moodlemobile://token=" + base64.b64encode(f"{signed}:::{token}:::private".encode()).decode()


def pdf(module_id: int, filename: str, stamp: int = T, kind: str = "application/pdf") -> dict:
    return {"type": "file", "filename": filename, "filepath": "/", "timemodified": stamp, "filesize": len(SLIDES),
            "mimetype": kind, "fileurl": f"{SITE}/webservice/pluginfile.php/{module_id}/{filename}?forcedownload=1"}


class FakeMoodle:
    """Moodle's REST web services and pluginfile.php, enough for the sync."""

    def __init__(self):
        self.token = "tok"
        year = int(timedelta(days=365).total_seconds())
        self.courses = [
            {"id": 101, "fullname": "Macroeconomics 2026/27", "shortname": "MACRO", "startdate": T - year // 12,
             "enddate": T + year // 6},
            {"id": 102, "fullname": "Diritto commerciale", "shortname": "DIR", "startdate": T - 100, "enddate": 0},
            {"id": 99, "fullname": "Old macroeconomics", "shortname": "OLD", "startdate": T - 2 * year,
             "enddate": T - year},
        ]
        self.contents = {
            101: [{"name": "Week 3", "modules": [
                {"id": 5, "name": "IS-LM slides", "contents": [pdf(5, "L3.pdf")]},
                {"id": 6, "name": "Exercises", "contents": [pdf(6, "ex1.pdf"), pdf(6, "ex2.PDF"),
                                                            pdf(6, "notes.docx", kind="application/msword")]},
                {"id": 7, "name": "Hidden", "uservisible": False, "contents": [pdf(7, "secret.pdf")]},
                {"id": 8, "name": "A forum", "modname": "forum"},
            ]}],
            102: [{"name": "Materiale", "modules": [{"id": 9, "name": "Codice civile", "contents": [pdf(9, "cc.pdf")]}]}],
        }
        self.downloads: list[str] = []

    def handle(self, request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/webservice/rest/server.php"):
            form = {k: v[0] for k, v in parse_qs(request.content.decode()).items()}
            if form["wstoken"] != self.token:
                return httpx.Response(200, json={"exception": "moodle_exception", "errorcode": "invalidtoken",
                                                 "message": "Invalid token"})
            fn = form["wsfunction"]
            if fn == "core_webservice_get_site_info":
                return httpx.Response(200, json={"userid": 7, "fullname": "Filippo Cappa", "sitename": "SME"})
            if fn == "core_enrol_get_users_courses":
                assert form["userid"] == "7"
                return httpx.Response(200, json=self.courses)
            if fn == "core_course_get_contents":
                return httpx.Response(200, json=self.contents[int(form["courseid"])])
            if fn == "mod_forum_get_forum_discussions":
                assert form["forumid"] == "80"
                return httpx.Response(200, json={"discussions": [
                    {"subject": "Textbook &amp; slides", "message": "<p>Blanchard, <b>Macroeconomics</b>, 8th ed.</p>"}]})
        if "/webservice/pluginfile.php/" in request.url.path:
            if request.url.params.get("token") != self.token:
                return httpx.Response(403, json={"error": "invalidtoken"})
            self.downloads.append(request.url.path.rsplit("/", 1)[1])
            return httpx.Response(200, content=SLIDES, headers={"content-type": "application/pdf"})
        return httpx.Response(404)


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")

    def make(responses=(), token="tok"):
        server = FakeMoodle()
        study = StudyStore(db, ROME, FakeCalendar(list(EVENTS)), files_dir=tmp_path / "files")
        agent = Agent(RecordingClient(responses), db, ToolRegistry([]), model="m", smart_model="smart", tz=ROME,
                      photos=PhotoStore(tmp_path / "photos"), delegate=False)
        push = FakePush(db.conn)
        push.moodle = []

        async def send_moodle(title, body, login=False, files=None):
            push.moodle.append((body, login))
            push.moodle_files = (title, files)
            return True
        push.send_moodle = send_moodle
        worker = StudyWorker(study, agent, push, tmp_path / "audio", Transcribe())
        saved = []
        moodle = MoodleSync(study, SITE, token, saved.append, push, worker, httpx.MockTransport(server.handle))
        app = create_app(agent, ReminderStore(db.conn), FakeCalendar(list(EVENTS)), ROME, TOKEN, push=push,
                         study=study, worker=worker, moodle=moodle)
        return TestClient(app), moodle, server, push, saved
    yield make
    db.close()


def test_the_token_must_be_signed_for_the_passport():
    assert token_from(callback("abc"), SITE, "abc") == "tok"
    assert token_from(callback("abc") + "/", SITE + "/", "abc") == "tok"
    for bad in (callback("other"), callback("abc", site="https://evil.example"), "moodlemobile://token=%%%",
                "https://elearning.unito.it/?token=x", callback("abc", token="")):
        with pytest.raises(ValueError):
            token_from(bad, SITE, "abc")


def test_courses_are_matched_by_their_words():
    aide = [{"id": 3, "name": "maths for economics II"}, {"id": 4, "name": "business law"},
            {"id": 5, "name": "macroeconomics"}]

    def guess(name):
        return MoodleSync._guess({"name": name, "short": ""}, aide)
    assert guess("SEM0251 - MATHEMATICS FOR ECONOMICS II") == 3
    assert guess("SEM0246 - MATHEMATICS FOR ECONOMICS I") is None
    assert guess("SEM0164 BUSINESS LAW 2026/2027 ") == 4
    assert guess("SEM0250 - PRIVATE LAW") is None
    assert guess("SEM0252 - MACROECONOMICS") == 5
    assert guess("SEM0247 - MICROECONOMICS") is None


def test_logging_in_through_the_app(env):
    api, moodle, server, _, saved = env(token=None)
    status = api.get("/v1/moodle", headers=AUTH).json()
    assert status == {"enabled": True, "site": SITE, "connected": False, "user": None, "last_sync": None,
                      "error": None, "courses": []}
    assert api.post("/v1/moodle/sync", headers=AUTH).status_code == 409
    login = api.post("/v1/moodle/login", headers=AUTH).json()
    url = urlparse(login["url"])
    assert login["scheme"] == "moodlemobile" and url.path == "/sme/admin/tool/mobile/launch.php"
    query = parse_qs(url.query)
    assert query["service"] == ["moodle_mobile_app"] and query["urlscheme"] == ["moodlemobile"]
    assert api.post("/v1/moodle/connect", json={"url": callback("not-ours")}, headers=AUTH).status_code == 400
    r = api.post("/v1/moodle/connect", json={"url": callback(query["passport"][0])}, headers=AUTH)
    assert r.status_code == 200 and r.json()["connected"] and r.json()["user"] == "Filippo Cappa"
    assert saved == ["tok"] and moodle.token == "tok"
    # A passport works once.
    assert api.post("/v1/moodle/connect", json={"url": callback(query["passport"][0])}, headers=AUTH).status_code == 400
    assert api.delete("/v1/moodle", headers=AUTH).json()["connected"] is False and saved == ["tok", None]


def test_without_a_site_moodle_is_off(tmp_path):
    db = Database(":memory:")
    agent = Agent(RecordingClient([]), db, ToolRegistry([]), model="m", tz=ROME, delegate=False)
    api = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, TOKEN))
    assert api.get("/v1/moodle", headers=AUTH).json() == {"enabled": False}
    assert api.post("/v1/moodle/login", headers=AUTH).status_code == 503


async def test_a_sync_brings_the_pdfs_of_matched_courses(env):
    api, moodle, server, push, _ = env()
    assert await moodle.sync() == {"new": 3, "updated": 0}
    files = moodle.files.files()
    assert sorted(f["name"] for f in files) == ["IS-LM slides.pdf", "ex1.pdf", "ex2.PDF"]
    macro = moodle.study.course_by_name("macroeconomics")["id"]
    assert {f["course_id"] for f in files} == {macro} and {f["section"] for f in files} == {"Week 3"}
    assert {f["source"] for f in files} == {"moodle"} and files[0]["source_time"] == T
    assert push.moodle == [("Macroeconomics: " + ", ".join(f["name"].rsplit(".", 1)[0] for f in files), False)]
    assert push.moodle_files == ("Moodle · 3 new files", [f["public_id"] for f in files])
    status = api.get("/v1/moodle", headers=AUTH).json()
    # The old course isn't listed; the Italian one isn't matched by itself.
    assert [(c["id"], c["course"], c["matched"], c["files"]) for c in status["courses"]] == \
           [(102, None, None, 0), (101, macro, "auto", 3)]
    assert status["last_sync"] and status["error"] is None

    assert await moodle.sync() == {"new": 0, "updated": 0} and len(server.downloads) == 3  # nothing again
    server.contents[101][0]["modules"][0]["contents"][0]["timemodified"] = T + 60  # changed on Moodle
    assert await moodle.sync() == {"new": 0, "updated": 1}
    # One the user deleted stays deleted, even when it changes on Moodle.
    gone = next(f for f in files if f["name"] == "ex1.pdf")
    api.delete(f"/v1/files/{gone['public_id']}", headers=AUTH)
    server.contents[101][0]["modules"][1]["contents"][0]["timemodified"] = T + 60
    assert await moodle.sync() == {"new": 0, "updated": 0}

    # Matching the other course by hand brings its files.
    law = moodle.study.course_by_name("business law")["id"]
    r = api.patch("/v1/moodle/courses/102", json={"course": law}, headers=AUTH)
    assert r.json() == {"id": 102, "name": "Diritto commerciale", "course": law, "matched": "user", "files": 0}
    assert (await moodle.sync())["new"] == 1 and moodle.files.files(law)[0]["name"] == "Codice civile.pdf"
    api.patch("/v1/moodle/courses/101", json={"course": None}, headers=AUTH)  # the user's choice sticks
    await moodle.sync()
    assert moodle.conn.execute("SELECT course_id FROM moodle_courses WHERE moodle_id = 101").fetchone()[0] is None
    assert api.patch("/v1/moodle/courses/5", json={"course": None}, headers=AUTH).status_code == 404


async def test_the_course_page_is_kept_as_text_for_the_notebook(env):
    api, moodle, server, *_ = env()
    server.contents[101] = [
        {"name": "EXAM", "summary": "<p>20 to 35 multiple-choice questions,<br>&minus;0.25 for a wrong one.</p>",
         "modules": [{"id": 10, "name": "Consumption &amp; Investment", "contents": [pdf(10, "C&amp;I.pdf")]},
                     {"id": 11, "name": "", "modname": "label", "description": "<p>Office hours: Thu 11:30</p>"}]},
        {"name": "Notices", "modules": [
            {"id": 12, "name": "Announcements", "modname": "forum", "instance": 80, "description": ""},
            {"id": 13, "name": "Questions", "modname": "forum", "instance": 81},
            {"id": 14, "name": "Hidden quiz", "modname": "quiz", "uservisible": False}]}]
    await moodle.sync()
    assert [f["name"] for f in moodle.files.files()] == ["Consumption & Investment.pdf"]
    text = moodle.conn.execute("SELECT text FROM moodle_courses WHERE moodle_id = 101").fetchone()[0]
    assert text.startswith("## EXAM\n20 to 35 multiple-choice questions,\n−0.25 for a wrong one.")
    assert "Office hours: Thu 11:30" in text and "- Questions (forum)" in text and "Hidden quiz" not in text
    assert "- Announcements (forum)\n\n### Textbook & slides\nBlanchard, Macroeconomics, 8th ed." in text


async def test_a_change_on_the_course_page_has_its_dates_read_again(env):
    api, moodle, server, *_ = env()
    moodle.notebook = NotebookStore(moodle.study)

    def queued() -> list[int]:
        return [r[0] for r in moodle.conn.execute(
            "SELECT course_id FROM notebook_jobs WHERE kind = 'dates' AND status = 'queued'")]
    await moodle.sync()
    macro = moodle.study.course_by_name("macroeconomics")["id"]
    assert queued() == [macro]  # new files, a new page
    moodle.conn.execute("UPDATE notebook_jobs SET status = 'done'")
    await moodle.sync()
    assert queued() == []  # nothing changed
    server.contents[101][0]["summary"] = "<p>The mid-term moves to 9 November.</p>"
    await moodle.sync()
    assert queued() == [macro]


async def test_slides_put_up_near_a_lecture_rewrite_its_notes(env):
    api, moodle, server, push, _ = env([done(NOTES), done(NOTES)])
    lecture = upload(api).json()
    await moodle.worker.process(moodle.study.next_queued())
    server.contents[101][0]["modules"] = server.contents[101][0]["modules"][:1]  # one file: the day's slides
    await moodle.sync()
    f = moodle.files.files()[0]
    assert moodle.study.lecture_row(f["lecture_id"])["public_id"] == lecture["id"]
    assert moodle.study.find(lecture["id"])["status"] == "queued"  # notes written again, with the slides


async def test_an_expired_login_asks_once(env):
    api, moodle, server, push, _ = env()
    server.token = "new"
    assert (await moodle.sync())["error"] == "the Moodle login has expired"
    await moodle.sync()
    assert push.moodle == [("Log in again to keep getting course files.", True)]
    assert api.get("/v1/moodle", headers=AUTH).json()["error"] == "the Moodle login has expired"
