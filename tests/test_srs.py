from datetime import date, datetime, timedelta, timezone

from aide import srs
from aide.objectives import ObjectiveStore
from aide.quiz import NEW_PER_DAY, QuizStore
from test_api import AUTH
from test_notebook import nb  # noqa: F401 (the fixture)
from test_quiz import notebook_with_questions, with_cards
from test_study import ROME

D = date(2026, 11, 1)


def day(n: int) -> date:
    return D + timedelta(days=n)


def test_a_first_right_answer_comes_back_in_four_days_a_miss_tomorrow():
    good = srs.schedule([(D, srs.GOOD)])
    assert good.due == day(4) and good.known(day(3)) and not good.known(day(4)) and good.is_due(day(4))
    assert 0.88 < good.retention(day(4)) < 0.9 < good.retention(day(3)) and good.retention(D) == 1
    again = srs.schedule([(D, srs.AGAIN)])
    assert again.due == day(1) and not again.known(D)  # missed: being learnt, even before it's due
    assert srs.schedule([]) is None


def test_each_right_answer_on_time_spaces_it_further_and_a_miss_brings_it_close():
    days, at, gaps = [], D, []
    for _ in range(4):
        days.append((at, srs.GOOD))
        s = srs.schedule(days)
        gaps.append((s.due - at).days)
        at = s.due
    assert gaps == sorted(gaps) and gaps[0] == 4 and gaps[-1] > 30
    lapsed = srs.schedule(days + [(at, srs.AGAIN)])
    assert (lapsed.due - at).days == 1 and lapsed.lapses == 1 and lapsed.difficulty > s.difficulty
    assert lapsed.stability < s.stability and srs.schedule(days + [(at, srs.AGAIN), (lapsed.due, srs.GOOD)]).due > \
        lapsed.due + timedelta(days=4)  # relearnt: it keeps some of what it had
    hard = srs.schedule(days[:1] + [(day(4), srs.HARD)])
    good = srs.schedule(days[:1] + [(day(4), srs.GOOD)])
    assert hard.stability < good.stability
    assert srs.interval(10_000) == srs.MAX_DAYS


def test_a_day_is_one_review_graded_by_its_worst_answer():
    # Missed in the first round, right in the second: still a miss.
    assert srs.by_day([(D, srs.AGAIN), (D, srs.GOOD), (day(2), srs.GOOD)]) == [(D, srs.AGAIN), (day(2), srs.GOOD)]
    assert srs.grade_of(True) == srs.GOOD and srs.grade_of(False) == srs.AGAIN
    assert [srs.grade_of(False, p) for p in (0, 0.4, 0.5, 1)] == [srs.AGAIN, srs.AGAIN, srs.HARD, srs.GOOD]


def ago(days: int) -> str:
    return (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()


def test_the_schedule_comes_from_the_answers_and_the_due_deck_starts_with_whats_due(nb):
    notebook_with_questions(nb)
    cid = nb.macro["id"]
    quizzes = QuizStore(nb.notebook)
    q1, q2, q3, *rest = quizzes.bank(cid)
    quizzes._record(cid, q1, q1["key"], ago(10))  # right 10 days ago: due
    quizzes._record(cid, q2, q2["key"], ago(0))  # right today: known
    quizzes._record(cid, q3, "Z", ago(1))  # wrong yesterday: due
    # An answer from before the grades: from `correct`.
    nb.db.conn.execute("UPDATE quiz_answers SET grade = NULL WHERE qkey = ?", (q1["qkey"],))

    last = quizzes._last(cid)
    assert (last[q1["qkey"]]["is_due"], last[q2["qkey"]]["known"], last[q3["qkey"]]["is_due"]) == (True, True, True)
    assert last[q1["qkey"]]["retention"] < 0.9 and last[q2["qkey"]]["retention"] == 1

    bank = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()
    assert (bank["due"], bank["new"]) == (2, 3)  # 3 never answered, today's allowance less the one started today
    assert bank["next_due"] > datetime.now(ROME).date().isoformat()
    brief = next(t for t in nb.api.get("/v1/study", headers=AUTH).json()["courses"] if t["id"] == cid)["notebook"]
    assert brief["due"] == 2 and {k for k in brief["mastery"][0]} >= {"known", "learning", "unseen", "due", "retention"}
    assert sum(t["known"] for t in brief["mastery"]) == 1 and sum(t["learning"] for t in brief["mastery"]) == 2

    # Practice picks what's due first, the least likely to be recalled first.
    islm = [q for q in quizzes.bank(cid) if q["topic"] == q1["topic"]]
    assert {q["qkey"] for q in quizzes.pick(islm, 2)} == {q1["qkey"], q3["qkey"]}

    r = nb.api.post("/v1/quizzes", json={"course": cid, "kind": "study", "due": True}, headers=AUTH)
    assert r.status_code == 201
    deck = r.json()
    assert (deck["kind"], deck["deck"], deck["title"]) == ("study", "due", "Due today")
    keys = [q["qkey"] for q in quizzes.quiz(deck["id"])["questions"]]
    assert set(keys[:2]) == {q1["qkey"], q3["qkey"]} and len(keys) == 5 and q2["qkey"] not in keys
    assert set(keys[2:]) == {q["qkey"] for q in rest}


def test_the_due_deck_brings_in_only_so_many_new_ones_a_day_cards_too(nb):
    t = notebook_with_questions(nb)
    with_cards(nb, t)
    cid = nb.macro["id"]
    quizzes = QuizStore(nb.notebook)
    items = quizzes.bank(cid) + quizzes.cards(cid)
    assert quizzes.due_json(cid) == {"due": 0, "new": 8, "next_due": None}
    deck = quizzes.start_due(cid)
    assert {q.get("type") for q in deck["questions"]} == {None, "card"} and len(deck["questions"]) == 8

    for q in items:  # all met today: no new ones left for today, nothing due
        quizzes._record(cid, q, q["key"] if q.get("type") != "card" else "right", ago(0))
    assert quizzes.new_left(cid) == NEW_PER_DAY - 8
    assert quizzes.due_json(cid)["due"] == 0
    try:
        quizzes.start_due(cid)
        raise AssertionError("nothing is due")
    except ValueError as e:
        assert str(e) == "Nothing due today."
    assert nb.api.post("/v1/quizzes", json={"course": cid, "kind": "study", "due": True},
                       headers=AUTH).status_code == 409


def test_a_review_objective_counts_each_item_once_a_day(nb):
    notebook_with_questions(nb)
    cid = nb.macro["id"]
    quizzes = QuizStore(nb.notebook)
    q1, q2, *_ = quizzes.bank(cid)
    for q, when in ((q1, 0), (q1, 0), (q2, 0), (q1, 2)):
        quizzes._record(cid, q, q["key"], ago(when))
    store = ObjectiveStore(nb.db.conn, ROME)
    m = store.check_measure({"type": "review", "course": cid})
    assert m == {"type": "review", "course": cid}
    today = datetime.now(ROME).date()
    assert store._count(m, today, today) == 2
    assert store._count(m, today - timedelta(days=6), today) == 3
    assert store.label(m) == "macroeconomics questions and flashcards reviewed" and store.source(m) == "Spaced repetition"
