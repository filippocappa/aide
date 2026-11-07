"""The Esse3 reader: the pages as Esse3 draws them (made-up rows, the real markup), the course dates, the push."""

from datetime import datetime, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
import pytest

from aide.esse3 import (BOOKED, EXAMS, TRANSCRIPT, Esse3Reader, SignUpFailed, read_booked, read_exams,
                        read_transcript)
from aide.icloud import CalEvent
from aide.moodle import MoodleSync
from aide.notebook import NotebookStore
from aide.reminders import ReminderStore
from aide.study import StudyStore
from aide.tools import ToolRegistry
from aide.unito import LoginFailed, NoLogin
from test_api import AUTH, TOKEN, FakeCalendar, FakeClient

ROME = ZoneInfo("Europe/Rome")

CLOSED = ('<img title="iscrizioni chiuse" alt="iscrizioni chiuse" aria-label="iscrizioni chiuse" '
          'src="images/app_no_pren.gif">')
OPEN = ('<div class="tool-bar"> <a id="app-toolbarTipoAppello" href="auth/studente/Appelli/DatiPrenotazioneAppello.do?'
        'APP_ID=1&amp;CDS_ESA_ID=1&amp;ATT_DID_ESA_ID=2&amp;ADSCE_ID=3&amp;ISCR_APERTA=1" title="informazioni '
        'sull\'appello" class="toolbar-s-image">​</a> </div>')


def appello(icon, course, day, opens, closes, teachers="ROSSI MARIO, BIANCHI ANNA"):
    return (f'<tr> <td title="" class="">{icon}</td><td title="" class="">{course}</td><td title="" class="">{day}<br> '
            f'</td><td title="" class="">{opens}<br>{closes}</td><td title="" class="">{course}</td><td title="" '
            f'class="">Non Previsto</td><td title="" class="">2026/2027<br>2025/2026<br> </td><td title="" '
            f'class="">{teachers}</td> </tr>')


APPELLI = f"""<html><head><script>var x = "<td>not a cell</td>";</script></head><body>
<div class="header-h2"><h2>Appelli disponibili per insegnamenti del proprio libretto</h2></div>
<table id="app-tabella_appelli" class="table breaks3 table-1"><thead><tr> <th scope="col"></th><th scope="col">Attivit&agrave;
didattica</th><th scope="col">Appello</th><th scope="col">Iscrizione</th><th scope="col">Descrizione</th><th scope="col">Svolg.
Esame</th><th scope="col">Sessioni</th><th scope="col">Docenti</th> </tr></thead><tbody class="table-1-body">
{appello(CLOSED, "BUSINESS LAW", "10/12/2026", "10/11/2026", "03/12/2026")}
{appello(OPEN, "MATHEMATICS FOR ECONOMICS II", "04/12/2026", "04/11/2026", "27/11/2026")}
{appello(CLOSED, "MATHEMATICS FOR ECONOMICS II", "14/01/2027 09:30", "15/12/2026", "07/01/2027")}
{appello(CLOSED, "MICROECONOMICS", "18/01/2027", "18/12/2026", "11/01/2027")}
</tbody></table></body></html>"""

NONE_BOOKED = """<html><body><h2>Bacheca prenotazioni</h2><p>Nessun appello prenotato in bacheca.</p></body></html>"""
ONE_BOOKED = """<html><body><table class="detail_table"><tr><th>Appello</th><th>Data</th></tr>
<tr><td>MATHEMATICS FOR ECONOMICS II - [SEM0251]</td><td>04/12/2026 - 09:00</td></tr></table></body></html>"""


def libretto(code, name, year, credits, status, attended="", grade=""):
    return (f'<tr> <td class="cell-alignL libretto-TD-con-icone"><a href="auth/studente/Libretto/LibrettoAdScelta.do?'
            f'adsce_id=1&amp;lreg_id=">{code} - {name}</a> <div id="toolbarNoteAdsce" class="tool-bar"> <a '
            f'id="ad_piano" title="Attivit&agrave; Didattica collegata al piano" class="toolbar-s-image">​</a> '
            f'</div> </td><td data-type="number">{year}</td><td data-type="number">{credits}</td><td><img '
            f'title="{status}" alt="{status}" src="images/x.gif"></td><td>{attended or "&nbsp;"}</td><td>{grade}</td>'
            f'<td></td><td><a href="auth/studente/Libretto/LibrettoDettaglio.do?adsce_id=1"><img '
            f'src="images/detail.jpg"></a></td><td></td> </tr>')


LIBRETTO = f"""<html><body><table id="tableLibretto" class="table breaks3 table-1"><thead><tr> <th>Attivit&agrave;
Didattiche</th><th>Anno</th><th>Peso in crediti</th><th>Stato</th><th>AA Freq.</th><th>Voto - Data Esame</th>
<th>Ric.</th><th>Prove</th><th>Appelli</th> </tr></thead><tbody>
{libretto("SEM0248", "FINANCIAL AND BUSINESS ACCOUNTING", 1, 9, "Superata", "2025/2026", "27&nbsp;-&nbsp;30/01/2026")}
{libretto("SEM0246", "MATHEMATICS FOR ECONOMICS I", 1, 12, "Superata", "2025/2026", "30L&nbsp;-&nbsp;12/02/2026")}
{libretto("SEM0247", "MICROECONOMICS", 1, 12, "Pianificata")}
{libretto("SEM0251", "MATHEMATICS FOR ECONOMICS II", 2, 9, "Frequentata", "2026/2027")}
{libretto("SEM0164", "BUSINESS LAW", 2, 9, "Pianificata")}
</tbody></table></body></html>"""


# -- the pages ------------------------------------------------------------------------------------


def test_exams():
    exams = read_exams(APPELLI)
    assert [(e["course"], e["day"], e["open"]) for e in exams] == [
        ("BUSINESS LAW", "2026-12-10", False), ("MATHEMATICS FOR ECONOMICS II", "2026-12-04", True),
        ("MATHEMATICS FOR ECONOMICS II", "2027-01-14", False), ("MICROECONOMICS", "2027-01-18", False)]
    maths = exams[1]
    assert (maths["opens"], maths["closes"], maths["time"]) == ("2026-11-04", "2026-11-27", None)
    assert maths["teachers"] == "ROSSI MARIO, BIANCHI ANNA"
    assert maths["link"].startswith("https://esse3.unito.it/auth/studente/Appelli/DatiPrenotazioneAppello.do?")
    assert exams[2]["time"] == "09:30" and exams[0]["link"] is None


def test_transcript():
    t = {c["code"]: c for c in read_transcript(LIBRETTO)}
    assert t["SEM0248"] == {"code": "SEM0248", "name": "FINANCIAL AND BUSINESS ACCOUNTING", "year": 1, "credits": 9.0,
                            "status": "passed", "grade": "27", "passed_on": "2026-01-30", "attended": "2025/2026"}
    assert t["SEM0246"]["grade"] == "30L"
    assert (t["SEM0247"]["status"], t["SEM0247"]["grade"], t["SEM0247"]["attended"]) == ("planned", None, None)
    assert t["SEM0251"]["status"] == "attended"


def test_booked():
    exams = read_exams(APPELLI)
    assert read_booked(NONE_BOOKED, exams) == set()
    assert read_booked(ONE_BOOKED, exams) == {"mathematics for economics ii|2026-12-04"}


def test_pages_without_tables():
    assert read_exams("<html><body>Errore</body></html>") == [] and read_transcript("<p>") == []


# -- the reader -----------------------------------------------------------------------------------


class FakeSession:
    def __init__(self, pages=None, fail=None, entry=True):
        self.pages = pages if pages is not None else {EXAMS: APPELLI, BOOKED: NONE_BOOKED, TRANSCRIPT: LIBRETTO}
        self.fail = fail
        self.has_entry = entry
        self.logged_in = False
        self.got = []
        self.resets = 0

    def entry(self):
        if not self.has_entry:
            raise NoLogin("no UniTo password saved")
        return {"id": "pw_1", "status": "ok"}

    def reset(self):
        self.resets += 1

    async def get(self, url):
        self.entry()
        if self.fail:
            raise self.fail
        self.got.append(url)
        self.logged_in = True
        return SimpleNamespace(text=self.pages[url])


class FakePush:
    def __init__(self):
        self.sent = []

    async def send_esse3(self, title, body, course_id=None):
        self.sent.append((title, body, course_id))
        return True


def at(day: datetime, hour: int) -> datetime:
    return day.replace(hour=hour, minute=0, second=0, microsecond=0)


def make(session=None):
    db = Database(":memory:")
    now = datetime.now(ROME)
    events = [CalEvent(f"l{n}{d}", "Work", name, at(now - timedelta(days=d), 9 + n), at(now - timedelta(days=d), 10 + n))
              for n, name in enumerate(["maths for economics II", "business law", "macroeconomics"]) for d in (1, 2, 8)]
    study = StudyStore(db, ROME, FakeCalendar(events))
    notebook = NotebookStore(study)
    MoodleSync(study, None, None)  # its tables
    push = FakePush()
    reader = Esse3Reader(session or FakeSession(), study, notebook, push)
    return db, study, notebook, push, reader


async def ids(study):
    await study.courses()
    return {c["name"]: c["id"] for c in await study.courses()}


async def test_a_read_fills_the_course_dates():
    db, study, notebook, push, reader = make()
    c = await ids(study)
    # Moodle's course with the same code: Business Law's Moodle name says nothing else alike
    db.conn.execute("INSERT INTO moodle_courses (moodle_id, name, course_id) VALUES (1, 'SEM0164 LAW 2026/2027', ?)",
                    (c["business law"],))
    status = await reader.read()
    assert status["error"] is None and status["read_at"]
    exams = reader.exams()
    assert {e["course"]: e["course_id"] for e in exams} == {
        "BUSINESS LAW": c["business law"], "MATHEMATICS FOR ECONOMICS II": c["maths for economics II"],
        "MICROECONOMICS": None}  # no Aide course for it
    maths = notebook.dates(c["maths for economics II"])
    assert [(d["what"], d["date"], d["by"]) for d in maths] == [
        ("Sign-up opens for the 4 Dec exam", "2026-11-04", "esse3"),
        ("Sign-up closes for the 4 Dec exam", "2026-11-27", "esse3"),
        ("Exam", "2026-12-04", "esse3"),
        ("Sign-up opens for the 14 Jan exam", "2026-12-15", "esse3"),
        ("Sign-up closes for the 14 Jan exam", "2027-01-07", "esse3"),
        ("Exam", "2027-01-14", "esse3")]
    exam = maths[2]
    assert exam["kind"] == "exam" and exam["source"] == "Esse3"
    assert exam["you"] == "Sign-up open on MyUniTo until 27 Nov"
    assert "ROSSI MARIO" in exam["details"]
    assert notebook.dates(c["macroeconomics"]) == []
    # the transcript, matched by name
    t = {r["code"]: r for r in reader.transcript()}
    assert t["SEM0251"]["course_id"] == c["maths for economics II"] and t["SEM0248"]["course_id"] is None
    j = reader.json()
    assert j["credits"] == {"passed": 21.0, "total": 51.0}
    assert j["average"] == round((27 * 9 + 30 * 12) / 21, 2)
    # a push for the open sign-up, once
    assert push.sent == [("Sign-up open: Maths for economics II",
                          "The 4 Dec exam, until 27 Nov. Tap Sign me up on the course page.", c["maths for economics II"])]
    await reader.read()
    assert len(push.sent) == 1
    assert db.conn.execute("SELECT COUNT(*) FROM activity WHERE kind = 'study'").fetchone()[0] == 1


async def test_professors_exam_on_the_same_day_is_one_date():
    db, study, notebook, push, reader = make()
    c = (await ids(study))["maths for economics II"]
    notebook.set_dates(c, [
        {"what": "Written exam", "kind": "exam", "date": "2026-12-04", "time": "09:00", "room": "Aula 5",
         "details": "Bring a calculator", "source": "Moodle"},
        {"what": "Homework 3 due", "kind": "deadline", "date": "2026-11-20", "source": "Moodle"}])
    await reader.read()
    got = [(d["what"], d["date"], d["by"]) for d in notebook.dates(c)]
    assert ("Written exam", "2026-12-04", "professor") not in got
    assert ("Homework 3 due", "2026-11-20", "professor") in got
    exam = next(d for d in notebook.dates(c) if d["date"] == "2026-12-04")
    assert (exam["by"], exam["time"], exam["room"]) == ("esse3", "09:00", "Aula 5")
    assert "Bring a calculator" in exam["details"]
    # the user can hide or move one of Esse3's like any other
    notebook.hide_date(c, exam["id"])
    assert all(d["date"] != "2026-12-04" or d["kind"] != "exam" for d in notebook.dates(c))
    late = next(d for d in notebook.dates(c) if d["date"] == "2027-01-14")
    moved = notebook.edit_date(c, late["id"], {"time": "14:00"})
    assert moved["by"] == "you" and moved["time"] == "14:00"
    await reader.read()  # kept through the next read
    assert next(d for d in notebook.dates(c) if d["id"] == late["id"])["time"] == "14:00"


async def test_signed_up_and_sessions_gone():
    session = FakeSession()
    db, study, notebook, push, reader = make(session)
    c = (await ids(study))["maths for economics II"]
    session.pages[BOOKED] = ONE_BOOKED
    await reader.read()
    assert push.sent == []  # signed up already: nothing to tell
    exam = next(d for d in notebook.dates(c) if d["date"] == "2026-12-04" and d["kind"] == "exam")
    assert exam["you"] == "Signed up on Esse3"
    # the sessions are gone from Esse3: gone from the dates
    session.pages[EXAMS] = APPELLI.split("<tbody")[0] + "<tbody></tbody></table>"
    await reader.read()
    assert notebook.dates(c) == []
    assert reader.transcript()  # the transcript is still read


async def test_login_trouble_is_kept_and_nothing_is_lost():
    session = FakeSession()
    db, study, notebook, push, reader = make(session)
    c = (await ids(study))["maths for economics II"]
    await reader.read()
    before = notebook.dates(c)
    session.fail = LoginFailed("wrong", "UniTo refused the saved password")
    status = await reader.read()
    assert status["error"] == {"kind": "wrong", "message": "UniTo refused the saved password"}
    assert notebook.dates(c) == before
    session.fail = None
    session.pages[EXAMS] = "<html>Servizio non disponibile</html>"
    session.pages[TRANSCRIPT] = "<html></html>"
    status = await reader.read()
    assert status["error"]["kind"] == "page" and notebook.dates(c) == before
    # no password saved: quiet, nothing read
    session.has_entry = False
    assert not reader.ready()
    assert (await reader.read())["connected"] is False


async def test_a_login_reads_the_page_again():
    session = FakeSession()
    _, _, _, _, reader = make(session)
    await reader.read()
    assert session.got == [EXAMS, EXAMS, BOOKED, TRANSCRIPT]
    session.got.clear()
    await reader.read()
    assert session.got == [EXAMS, BOOKED, TRANSCRIPT]


async def test_a_new_unito_password_reads_again():
    session = FakeSession()
    _, _, _, _, reader = make(session)
    reader.login_changed(["amazon.it"])
    assert session.resets == 0 and not reader._wake.is_set()
    reader.login_changed(["unito.it"])
    assert session.resets == 1 and reader._wake.is_set()


def test_the_api():
    session = FakeSession()
    db, study, notebook, push, reader = make(session)
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    client = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, study=study,
                                   notebook=notebook, esse3=reader))
    assert client.get("/v1/esse3", headers=AUTH).json()["exams"] == []
    r = client.post("/v1/esse3/read", headers=AUTH)
    assert r.status_code == 200 and len(r.json()["exams"]) == 4 and r.json()["connected"]
    assert len(session.got) == 4
    client.post("/v1/esse3/read", headers=AUTH)  # read a moment ago: kept
    assert len(session.got) == 4
    assert client.get("/v1/esse3").status_code == 401
    off = TestClient(create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN))
    assert off.get("/v1/esse3", headers=AUTH).json()["connected"] is False
    assert off.post("/v1/esse3/read", headers=AUTH).status_code == 503



# -- signing up, cancelling, not taking an exam ----------------------------------------------------
# The clicking is an errand (tests/test_errands.py); here, what esse3.py does around it: start it with the login as
# cookies, decide from the bookings page when it ends, push once.

COOKIES = [{"name": "JSESSIONID", "value": "s3cret-session", "url": "https://esse3.unito.it/"}]


class BookingSession(FakeSession):
    """Esse3 whose bookings page the test changes, as if the errand had clicked; hands its login over as cookies."""

    def __init__(self):
        super().__init__()
        self.handed = 0

    async def handoff(self, url):
        await self.get(url)
        self.handed += 1
        return list(COOKIES)


class FakeErrands:
    """The runner's side: errands started, cancelled; the browser's profile forgotten."""

    def __init__(self):
        self.rows, self.started, self.forgot = {}, [], []
        self.store = SimpleNamespace(get=lambda i: self.rows.get(i))
        self.browser = SimpleNamespace(forget=self._forget)

    async def _forget(self, site):
        self.forgot.append(site)
        return True

    async def start_esse3(self, target, cookies):
        e = {"id": len(self.rows) + 1, "status": "queued", "step": "Waiting to start", "reason": None,
             "esse3": target}
        self.rows[e["id"]] = e
        self.started.append((target, cookies))
        return e

    def cancel(self, errand_id):
        self.rows[errand_id]["status"] = "cancelled"
        return self.rows[errand_id]


async def booking(session=None):
    session = session or BookingSession()
    db, study, notebook, push, reader = make(session)
    reader.errands = FakeErrands()
    c = await ids(study)
    await reader.read()
    maths = c["maths for economics II"]
    exam = next(d for d in notebook.dates(maths) if d["kind"] == "exam" and d["date"] == "2026-12-04")
    return db, study, notebook, push, reader, maths, exam


async def ended(reader, errand_id, kind, **args):
    e = reader.errands.rows[errand_id]
    e["status"] = {"finish": "done", "need_user": "needs_you", "failed": "failed", "cancelled": "cancelled"}[kind]
    await reader.errand_ended(e, kind, args)


async def test_sign_up_when_open():
    db, study, notebook, push, reader, maths, exam = await booking()
    session, errands = reader.session, reader.errands
    assert reader.signup(exam["id"])["state"] == "open"
    state = await reader.sign_up(exam["id"])
    assert (state["state"], state["busy"], state["errand_id"], state["step"]) == ("open", "signing up", 1,
                                                                                   "Waiting to start")
    (target, cookies), = errands.started
    assert cookies == COOKIES and session.handed == 1
    assert {k: target[k] for k in ("action", "course", "code", "day", "day_it", "app_id", "others")} == {
        "action": "book", "course": "MATHEMATICS FOR ECONOMICS II", "code": "SEM0251", "day": "2026-12-04",
        "day_it": "04/12/2026", "app_id": "1", "others": []}
    assert "DatiPrenotazioneAppello" in target["start_url"]
    # a second tap while it runs starts nothing
    assert (await reader.sign_up(exam["id"]))["busy"] == "signing up" and len(errands.started) == 1
    # the errand clicked; the bookings say so
    session.pages[BOOKED] = ONE_BOOKED
    push.sent.clear()
    await ended(reader, 1, "finish", ok=True, result="Prenotazione effettuata")
    state = reader.signup(exam["id"])
    assert (state["state"], state["busy"], state["error"], state["errand_id"]) == ("booked", None, None, None)
    assert state["can_cancel"] and errands.forgot == ["unito.it"]
    assert [t for t, *_ in push.sent] == ["Signed up: Maths for economics II"]
    assert next(d for d in notebook.dates(maths) if d["id"] == exam["id"])["you"] == "Signed up on Esse3"
    rows = db.conn.execute("SELECT title FROM activity WHERE kind = 'study'").fetchall()
    assert any("Signed up for Maths for economics II's 4 Dec exam" in r["title"] for r in rows)
    # and cancelled again, from the bookings page
    state = await reader.cancel(exam["id"])
    assert state["busy"] == "cancelling" and errands.started[-1][0]["action"] == "cancel"
    assert errands.started[-1][0]["start_url"] == BOOKED
    session.pages[BOOKED] = NONE_BOOKED
    await ended(reader, 2, "finish", ok=True, result="Cancellata")
    assert reader.signup(exam["id"])["state"] == "open"
    assert push.sent[-1][0] == "Sign-up cancelled: Maths for economics II"


async def test_the_bookings_decide_not_the_model():
    *_, push, reader, maths, exam = await booking()
    await reader.sign_up(exam["id"])
    push.sent.clear()
    await ended(reader, 1, "finish", ok=True, result="Done!")  # says done; Esse3 doesn't list it
    state = reader.signup(exam["id"])
    assert state["state"] == "open" and "didn't list the sign-up" in state["error"]
    assert [t for t, *_ in push.sent] == ["Couldn't sign you up: Maths for economics II"]
    # never tried again by itself
    await reader.read()
    assert len(reader.errands.started) == 1


async def test_a_questionnaire_first():
    *_, push, reader, maths, exam = await booking()
    await reader.sign_up(exam["id"])
    push.sent.clear()
    await ended(reader, 1, "need_user", why="other", reason="Esse3 asks for the course questionnaire first.")
    state = reader.signup(exam["id"])
    assert state["error"] == "Esse3 asks for the course questionnaire first. You can take over in the app."
    assert state["errand_id"] == 1  # waiting for the user: Take over
    assert reader.errands.forgot == []  # kept for the live view
    assert push.sent[0][0] == "Couldn't sign you up: Maths for economics II"
    # left waiting, then cancelled: nothing pushed again, the profile gone
    await ended(reader, 1, "cancelled")
    assert len(push.sent) == 1 and reader.errands.forgot == ["unito.it"]


async def test_a_new_tap_replaces_one_left_waiting():
    *_, push, reader, maths, exam = await booking()
    await reader.sign_up(exam["id"])
    await ended(reader, 1, "need_user", why="other", reason="A notice.")
    await reader.sign_up(exam["id"])
    assert reader.errands.rows[1]["status"] == "cancelled" and len(reader.errands.started) == 2
    sent = len(push.sent)
    await reader.errand_ended(reader.errands.rows[1], "cancelled", {})  # the old one's end changes nothing
    assert len(push.sent) == sent and reader.signup(exam["id"])["busy"] == "signing up"


async def test_no_browser_or_no_login():
    session = BookingSession()
    db, study, notebook, push, reader = make(session)
    c = await ids(study)
    await reader.read()
    exam = next(d for d in notebook.dates(c["maths for economics II"]) if d["date"] == "2026-12-04")
    with pytest.raises(SignUpFailed) as e:
        await reader.sign_up(exam["id"])
    assert e.value.kind == "page"
    reader.errands = FakeErrands()

    async def no_login(url):
        raise LoginFailed("needs_you", "UniTo asks for something Aide can't do")
    session.handoff = no_login
    with pytest.raises(SignUpFailed) as e:
        await reader.sign_up(exam["id"])
    assert e.value.kind == "login" and reader.errands.started == []


async def test_signed_up_as_soon_as_it_opens():
    db, study, notebook, push, reader, maths, _ = await booking()
    session = reader.session
    later = next(d for d in notebook.dates(maths) if d["kind"] == "exam" and d["date"] == "2027-01-14")
    state = await reader.sign_up(later["id"])
    assert (state["state"], state["auto"], state["busy"]) == ("soon", True, None) and reader.errands.started == []
    assert next(d for d in notebook.dates(maths) if d["id"] == later["id"])["you"].startswith("Aide signs you up")
    # it opens: the next read starts the errand
    session.pages[EXAMS] = APPELLI.replace(appello(CLOSED, "MATHEMATICS FOR ECONOMICS II", "14/01/2027 09:30",
                                                   "15/12/2026", "07/01/2027"),
                                           appello(OPEN, "MATHEMATICS FOR ECONOMICS II", "14/01/2027 09:30",
                                                   "15/12/2026", "07/01/2027"))
    push.sent.clear()
    await reader.read()
    (target, _), = reader.errands.started
    assert target["day"] == "2027-01-14" and reader.signup(later["id"])["busy"] == "signing up"
    await reader.read()  # still running: not started again
    assert len(reader.errands.started) == 1
    session.pages[BOOKED] = ONE_BOOKED.replace("04/12/2026 - 09:00", "14/01/2027 - 09:30")
    await ended(reader, 1, "finish", ok=True, result="ok")
    assert [t for t, *_ in push.sent] == ["Signed up: Maths for economics II"]
    assert "as soon as the sign-up opened" in push.sent[0][1] and reader.wants() == {}


async def test_cancelling_a_wish_stops_its_errand():
    *_, reader, maths, exam = await booking()
    await reader.sign_up(exam["id"])
    reader.conn.execute("INSERT INTO esse3_wants (key, at) VALUES (?, '2026-11-07')",
                        (reader.exam_for(exam["id"])["key"],))
    state = await reader.cancel(exam["id"])
    assert reader.errands.rows[1]["status"] == "cancelled" and state["busy"] is None and reader.wants() == {}
    await ended(reader, 1, "cancelled")
    assert not any(t.startswith(("Couldn't", "Signed")) for t, *_ in reader.push.sent)


async def test_the_model_reads_a_page_the_parser_cant():
    pages = {EXAMS: "<html><body><div>MATEMATICA II — 04/12/2026 ore 09:30, iscrizioni 04/11/2026–27/11/2026"
                    "</div></body></html>", BOOKED: NONE_BOOKED, TRANSCRIPT: LIBRETTO}
    asked = []

    async def ask(system, text):
        asked.append(text)
        return ('{"exams": [{"course": "Matematica II", "day": "2026-12-04", "time": "09:30", "opens": "2026-11-04", '
                '"closes": "2026-11-27", "open": true}]}')
    db, study, notebook, push, reader = make(FakeSession(pages))
    reader.ask = ask
    await reader.read()
    (e,) = reader.exams()
    assert (e["course"], e["day"], e["time"], e["open"], e["link"]) == ("Matematica II", "2026-12-04", "09:30", True,
                                                                        EXAMS)
    assert len(asked) == 1 and "04/12/2026" in asked[0]


async def test_not_taking_an_exam():
    db, study, notebook, push, reader, maths, exam = await booking()
    await reader.sign_up(next(d for d in notebook.dates(maths) if d["date"] == "2027-01-14")["id"])
    later = next(d for d in notebook.dates(maths) if d["kind"] == "exam" and d["date"] == "2027-01-14")
    notebook.archive_date(maths, later["id"])
    reader.forget(later["id"])
    left = notebook.dates(maths)
    assert later["id"] not in {d["id"] for d in left} and all(d.get("of") != later["id"] for d in left)
    assert len(left) == 3 and reader.wants() == {}
    every = notebook.dates(maths, archived=True)
    assert [d["archived"] for d in every].count(True) == 3
    notebook.unarchive_date(maths, later["id"])
    assert len(notebook.dates(maths)) == 6


async def test_signing_up_through_the_api():
    db, study, notebook, push, reader, maths, exam = await booking()
    agent = Agent(FakeClient([]), db, ToolRegistry([]), model="m", delegate=False, tz=ROME)
    app = create_app(agent, ReminderStore(db.conn), FakeCalendar([]), ROME, TOKEN, study=study, notebook=notebook,
                     esse3=reader)
    with TestClient(app) as client:
        items = client.get(f"/v1/study/courses/{maths}/dates", headers=AUTH).json()["items"]
        assert next(d for d in items if d["id"] == exam["id"])["signup"]["state"] == "open"
        assert "signup" not in next(d for d in items if d["kind"] != "exam")
        r = client.post(f"/v1/esse3/exams/{exam['id']}/signup", headers=AUTH)
        assert r.status_code == 202 and r.json()["signup"]["busy"] == "signing up"
        assert r.json()["signup"]["errand_id"] == 1
        later = next(d for d in items if d["kind"] == "exam" and d["date"] == "2027-01-14")
        r = client.post(f"/v1/esse3/exams/{later['id']}/signup", headers=AUTH)
        assert r.status_code == 200 and r.json()["signup"]["auto"] is True
        r = client.post(f"/v1/study/courses/{maths}/dates/{exam['id']}/archive", headers=AUTH)
        assert [d["archived"] for d in r.json()["items"] if d["id"] == exam["id"]] == [True]
        assert exam["id"] not in {d["id"] for d in client.get(f"/v1/study/courses/{maths}/dates", headers=AUTH)
                                  .json()["items"]}
        assert client.delete(f"/v1/study/courses/{maths}/dates/{exam['id']}/archive", headers=AUTH).status_code == 200
        assert client.post("/v1/esse3/exams/d_nope/signup", headers=AUTH).status_code == 404
