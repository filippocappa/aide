from datetime import datetime, timedelta, timezone

import pytest

from aide.db import Database
from aide.reviews import ReviewStore, ReviewWatcher
from aide.study import StudyStore
from aide.tools.quiz import quiz_tools
from aide.quiz import QuizStore
from test_api import AUTH
from test_calendar import FakeCalendar
from test_notebook import nb  # noqa: F401 (the fixture)
from test_quiz import notebook_with_questions
from test_study import EVENTS, ROME, weekly


def tomorrow(hour: int) -> datetime:
    return (datetime.now(ROME) + timedelta(days=1)).replace(hour=hour, minute=0, second=0, microsecond=0)


@pytest.fixture
def reviews(nb):
    notebook_with_questions(nb)
    cal = FakeCalendar()
    store = ReviewStore(nb.db.conn, ROME, cal, nb.study)
    tools = {t.name: t for t in quiz_tools(QuizStore(nb.notebook), store, nb.study, nb.notebook, ROME)}
    return store, cal, tools


async def test_a_review_session_goes_in_the_timetable_calendar(nb, reviews):
    store, cal, tools = reviews
    start = tomorrow(15)
    out = await tools["add_review_session"].handler(course="macroeconomics", start=f"{start:%Y-%m-%dT%H:%M}",
                                                    minutes=90, topics=["The IS-LM model", "phillips curve"])
    (ev,) = cal.store.values()
    assert (ev.calendar, ev.title, ev.start, ev.end) == ("Work", "Review: Macroeconomics", start, start + timedelta(minutes=90))
    assert ev.notes == "Review with Professor in Aide.\nTopics: The IS-LM model; Phillips curve"
    (s,) = store.upcoming()
    assert out == f"Added to the Work calendar: [{s['public_id']}] {start:%a %d %b} 15:00, 90 min · macroeconomics · " \
                  "The IS-LM model; Phillips curve"

    listed = nb.api.get(f"/v1/reviews?course={nb.macro['id']}", headers=AUTH).json()
    assert listed == {"sessions": [{"id": s["public_id"], "course": nb.macro["id"], "start": start.isoformat(),
                                    "minutes": 90, "topics": ["The IS-LM model", "Phillips curve"]}]}
    assert nb.api.get("/v1/reviews?course=999", headers=AUTH).status_code == 404

    progress = await tools["study_progress"].handler(course="macroeconomics")
    assert "Next exam: " in progress and "The IS-LM model: 3 questions and cards; 3 never asked" in progress
    assert progress.endswith(f"Review sessions coming: \n{store.line(s)}")

    assert tools["cancel_review_session"].confirm  # queued for the user's !yes
    assert await tools["cancel_review_session"].describe(session=s["public_id"]) == \
        f"Take the review session off the calendar: {store.line(s)}"
    await tools["cancel_review_session"].handler(session=s["public_id"])
    assert cal.store == {} and store.upcoming() == []


async def test_a_session_that_starts_is_announced_in_the_course_chat(nb, reviews):
    store, cal, _ = reviews
    start = tomorrow(10)
    s = await store.add(nb.macro["id"], start, 60, ["The IS-LM model"])
    watcher = ReviewWatcher(store, nb.agent, nb.push)
    await watcher.tick(start.astimezone(timezone.utc) - timedelta(minutes=5))
    assert nb.push.messages == []

    # Moved later in the calendar: followed, and not announced at the old time.
    (ev,) = cal.store.values()
    cal.update(ev.uid, start=start + timedelta(hours=2), end=start + timedelta(hours=2, minutes=45))
    await watcher.tick(start.astimezone(timezone.utc))
    assert nb.push.messages == [] and store.get(s["public_id"])["minutes"] == 45

    await watcher.tick((start + timedelta(hours=2, minutes=1)).astimezone(timezone.utc))
    chat = nb.study.chat(nb.macro["id"])
    text = ("Time for your Macroeconomics review (45 min): The IS-LM model. Shall I quiz you? Say \"quiz me\", or start "
            "a voice quiz from the ••• menu.")
    assert nb.push.messages == [(chat, "Professor · Macroeconomics", text[:180])]
    history = nb.api.get(f"/v1/history?conversation_id={chat}", headers=AUTH).json()["messages"]
    assert history[-1]["text"] == text
    await watcher.tick((start + timedelta(hours=2, minutes=2)).astimezone(timezone.utc))
    assert len(nb.push.messages) == 1  # once


async def test_a_session_deleted_in_the_calendar_or_long_missed_is_dropped(nb, reviews):
    store, cal, _ = reviews
    gone = await store.add(nb.macro["id"], tomorrow(9), 60, [])
    missed = await store.add(nb.macro["id"], tomorrow(12), 60, [])
    cal.delete(gone["event_uid"])
    watcher = ReviewWatcher(store, nb.agent, nb.push)
    await watcher.tick((tomorrow(12) + timedelta(minutes=40)).astimezone(timezone.utc))  # the server was off
    assert nb.push.messages == []
    assert store.get(gone["public_id"])["cancelled_at"] and store.get(missed["public_id"])["announced_at"]


async def test_sessions_must_make_sense(nb, reviews):
    store, _, _ = reviews
    with pytest.raises(ValueError, match="15 to 240"):
        await store.add(nb.macro["id"], tomorrow(9), 5, [])
    with pytest.raises(ValueError, match="passed"):
        await store.add(nb.macro["id"], datetime.now(ROME) - timedelta(hours=1), 60, [])


async def test_review_sessions_are_never_a_course(tmp_path):
    db = Database(":memory:")
    reviews = [e.__class__(e.uid, e.calendar, "Review: Macroeconomics", e.start, e.end)
               for e in weekly("x", EVENTS[0].start + timedelta(hours=4))]
    study = StudyStore(db, ROME, FakeCalendar([*EVENTS, *reviews]), files_dir=tmp_path / "files")
    assert "Review: Macroeconomics" not in {c["name"] for c in await study.courses()}
    db.close()
