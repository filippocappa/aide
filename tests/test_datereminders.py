from datetime import date, datetime

from aide.datereminders import DateReminders
from aide.esse3 import BOOKED, EXAMS
from aide.reminders import ReminderStore
from test_esse3 import APPELLI, ONE_BOOKED, ROME, FakeSession, ids, make


def setup(today=date(2026, 11, 7), session=None):
    db, study, notebook, push, reader = make(session)
    reminders = ReminderStore(db.conn)
    dr = DateReminders(notebook, reminders, ROME, today=lambda: today)
    notebook.on_change.append(dr.changed)
    return db, study, notebook, push, reader, reminders, dr


def live(reminders, course="Maths"):
    return sorted((r.title, r.due_at.astimezone(ROME).strftime("%Y-%m-%d %H:%M"))
                  for r in reminders.changed_since(0)
                  if not r.deleted and not r.completed and r.title.startswith(course))


async def test_esse3_sign_ups_become_reminders():
    db, study, notebook, push, reader, reminders, dr = setup()
    c = await ids(study)
    await reader.read()
    assert live(reminders) == [
        ("Maths for economics II: sign-up closes for the 14 Jan exam", "2027-01-07 09:00"),
        ("Maths for economics II: sign-up closes for the 4 Dec exam", "2026-11-27 09:00"),
        ("Maths for economics II: sign-up opens for the 14 Jan exam", "2026-12-15 09:00"),
        # the 4 Dec sign-up opened on 4 Nov, before today: no reminder for it
    ]
    # an open sign-up with no reminder for its opening is still pushed; read again, nothing new
    assert len(push.sent) == 1
    await reader.read()
    assert len(live(reminders)) == 3 and len(push.sent) == 1
    assert live(reminders, "Business") == [
        ("Business law: sign-up closes for the 10 Dec exam", "2026-12-03 09:00"),
        ("Business law: sign-up opens for the 10 Dec exam", "2026-11-10 09:00")]
    # the course's dates still have them (the exam plan and Professor read them)
    kinds = [d["kind"] for d in notebook.dates(c["maths for economics II"])]
    assert kinds.count("exam") == 2 and "deadline" in kinds


async def test_signing_up_removes_the_reminders():
    session = FakeSession()
    db, study, notebook, push, reader, reminders, dr = setup(session=session)
    await ids(study)
    await reader.read()
    session.pages[BOOKED] = ONE_BOOKED  # signed up for the 4 Dec one
    await reader.read()
    assert [t for t, _ in live(reminders)] == [
        "Maths for economics II: sign-up closes for the 14 Jan exam",
        "Maths for economics II: sign-up opens for the 14 Jan exam"]
    # the sessions are gone from Esse3: so are their reminders
    session.pages[EXAMS] = APPELLI.split("<tbody")[0] + "<tbody></tbody></table>"
    await reader.read()
    assert live(reminders, "") == []


async def test_an_opening_with_a_reminder_isnt_pushed_too():
    db, study, notebook, push, reader, reminders, dr = setup(today=date(2026, 11, 1))
    await ids(study)
    await reader.read()  # 1 Nov: the 4 Dec sign-up opens on 4 Nov, a reminder is made
    assert "Maths for economics II: sign-up opens for the 4 Dec exam" in [t for t, _ in live(reminders)]
    push.sent.clear()
    reader._set("told", "[]")
    await reader.read()  # now Esse3 shows it open: the reminder said so already
    assert push.sent == []


async def test_professors_deadlines_and_the_users_hand():
    db, study, notebook, push, reader, reminders, dr = setup()
    c = (await ids(study))["business law"]
    notebook.set_dates(c, [
        {"what": "1st mid-term registration opens", "kind": "other", "date": "2026-10-05", "source": "Moodle"},
        {"what": "2nd mid-term registration deadline", "kind": "deadline", "date": "2026-11-25", "time": "23:59",
         "details": "Fill in the form on Moodle", "source": "Moodle"},
        {"what": "Group list published", "kind": "other", "date": "2026-11-20", "time": "14:00", "source": "Moodle"},
        {"what": "2nd mid-term", "kind": "mid-term", "date": "2026-12-03", "source": "Moodle"}])
    assert live(reminders, "Business") == [  # nothing for the past one or the mid-term; a deadline at 09:00 on its day
        ("Business law: 2nd mid-term registration deadline", "2026-11-25 09:00"),
        ("Business law: group list published", "2026-11-20 14:00")]
    rem = next(r for r in reminders.changed_since(0) if "deadline" in r.title)
    assert rem.notes == "Fill in the form on Moodle From Moodle."
    # moved by the user: the reminder moves
    d = next(d for d in notebook.dates(c) if d["what"] == "2nd mid-term registration deadline")
    notebook.edit_date(c, d["id"], {"date": "2026-11-26"})
    assert ("Business law: 2nd mid-term registration deadline", "2026-11-26 09:00") in live(reminders, "Business")
    # ticked in Apple Reminders: left alone, never made again
    reminders.update(rem.id, completed=True)
    notebook.set_dates(c, [*notebook.professor_dates(c)])
    assert [t for t, _ in live(reminders, "Business")] == ["Business law: group list published"]
    # hidden on the course page: its reminder goes
    g = next(d for d in notebook.dates(c) if d["what"] == "Group list published")
    notebook.hide_date(c, g["id"])
    assert live(reminders, "Business") == []


async def test_a_passed_date_lets_go_of_its_reminder():
    db, study, notebook, push, reader, reminders, dr = setup()
    c = (await ids(study))["business law"]
    notebook.set_dates(c, [{"what": "Hand-in", "kind": "deadline", "date": "2026-11-10", "source": "Moodle"}])
    assert len(live(reminders, "Business")) == 1
    dr._today = lambda: date(2026, 11, 12)
    dr.sync(c)
    assert len(live(reminders, "Business")) == 1  # kept: it's the user's now
    assert db.conn.execute("SELECT COUNT(*) FROM date_reminders").fetchone()[0] == 0
    dr.sync_all()
    assert len(live(reminders, "Business")) == 1
