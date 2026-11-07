"""The Esse3 reader: the pages as Esse3 draws them (made-up rows, the real markup), the course dates, the push."""

from datetime import datetime, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

from fastapi.testclient import TestClient

from aide.agent import Agent
from aide.channels.api import create_app
from aide.db import Database
from aide.esse3 import BOOKED, EXAMS, TRANSCRIPT, Esse3Reader, read_booked, read_exams, read_transcript
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
                          "The 4 Dec exam, until 27 Nov. Sign up on MyUniTo.", c["maths for economics II"])]
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

