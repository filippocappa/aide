import random

import pytest

from aide.notebook import mcqs
from aide.quiz import QuizStore, parse_question, plain_math
from test_api import AUTH
from test_notebook import chat_messages, nb  # noqa: F401 (the fixture)
from test_study import ROME


def page(topic: str, questions: list[tuple[str, str]]) -> str:
    """A topic page whose questions are (question, key), each with options A–D."""
    blocks = [f"**{n}.** {q}\n- A) one\n- B) two\n- C) three\n- D) four\n\n> [!success]- Answer\n> **{key}**. "
              f"Because of {topic.lower()}." for n, (q, key) in enumerate(questions, 1)]
    return f"{topic} in one line.\n\n## Explanation\nText.\n\n## Exam-style questions\n\n" + "\n\n".join(blocks)


def notebook_with_questions(nb) -> dict:
    cid = nb.macro["id"]
    islm = nb.notebook.add_topic(cid, "The IS-LM model")
    nb.notebook.set_body(islm["id"], page("IS-LM", [("What shifts IS right?", "A"), ("What shifts LM up?", "B"),
                                                    (r"If $c_1 = 0.6$, the multiplier $\frac{1}{1-c_1}$ is:", "C")]))
    pc = nb.notebook.add_topic(cid, "Phillips curve")
    nb.notebook.set_body(pc["id"], page("Phillips", [(r"In $\pi_t - \pi_{t-1} = -\alpha(u_t - u_n)$, $\alpha$ is:", "D"),
                                                     ("Who drew the curve?", "A"), ("Is it stable?", "B")]))
    nb.notebook.add_topic(cid, "Not written yet")
    return {"islm": nb.notebook.topic(islm["public_id"]), "pc": nb.notebook.topic(pc["public_id"])}


def test_a_practice_exam_from_the_notebook_scored_like_the_exam(nb):
    notebook_with_questions(nb)
    cid = nb.macro["id"]
    bank = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()
    assert (bank["questions"], bank["unseen"], bank["to_review"], bank["past"]) == (6, 6, 0, [])
    assert [(x["title"], x["questions"]) for x in bank["topics"]] == [("The IS-LM model", 3), ("Phillips curve", 3)]
    assert bank["scoring"] == {"right": 1.0, "wrong": -0.25, "blank": 0}

    r = nb.api.post("/v1/quizzes", json={"course": cid, "count": 4, "minutes": 6}, headers=AUTH)
    assert r.status_code == 201
    quiz = r.json()
    assert quiz["count"] == 4 and quiz["minutes"] == 6 and quiz["score"] is None
    assert sorted(q["topic"]["title"] for q in quiz["questions"]) == ["Phillips curve"] * 2 + ["The IS-LM model"] * 2
    assert all("key" not in q and "explanation" not in q for q in quiz["questions"])  # not before it's finished
    assert [o["letter"] for o in quiz["questions"][0]["options"]] == ["A", "B", "C", "D"]
    assert nb.api.get(f"/v1/quizzes/{quiz['id']}", headers=AUTH).json() == quiz

    keys = [q["key"] for q in QuizStore(nb.notebook).quiz(quiz["id"])["questions"]]
    wrong = {"A": "B", "B": "C", "C": "D", "D": "A"}
    answers = {"1": keys[0], "2": keys[1], "3": wrong[keys[2]]}  # 4 left blank
    done = nb.api.post(f"/v1/quizzes/{quiz['id']}/finish", json={"answers": answers}, headers=AUTH).json()
    assert {k: done["score"][k] for k in ("points", "max", "right", "wrong", "blank")} == \
        {"points": 1.75, "max": 4.0, "right": 2, "wrong": 1, "blank": 1}
    q3 = done["questions"][2]
    assert (q3["answer"], q3["key"], q3["correct"]) == (wrong[keys[2]], keys[2], False)
    assert q3["explanation"].startswith("Because of") and done["questions"][3]["answer"] is None
    assert nb.api.post(f"/v1/quizzes/{quiz['id']}/finish", json={}, headers=AUTH).status_code == 409

    last = chat_messages(nb)[-1]
    assert last["text"].startswith("Practice exam: **1.75 / 4** (2 right, 1 wrong, 1 blank) in 0 min.")
    assert "To go over:" in last["text"] and "Want to go through them?" in last["text"]
    after = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()
    assert (after["unseen"], after["to_review"]) == (2, 2)
    assert after["past"][0]["id"] == quiz["id"] and after["past"][0]["score"]["points"] == 1.75


def test_the_next_practice_exam_starts_with_what_went_wrong(nb):
    notebook_with_questions(nb)
    cid = nb.macro["id"]
    quizzes = QuizStore(nb.notebook, random.Random(3))
    first = quizzes.start(cid, count=6)
    answers = {str(n): (q["key"] if n > 2 else None) for n, q in enumerate(first["questions"], 1)}
    quizzes.finish(first["public_id"], answers)  # 1 and 2 blank
    missed = {q["qkey"] for q in first["questions"][:2]}
    again = quizzes.start(cid, count=2)
    assert {q["qkey"] for q in again["questions"]} == missed
    quizzes.finish(again["public_id"], {str(n): q["key"] for n, q in enumerate(again["questions"], 1)})
    # All answered right once now: the oldest right answers come back first.
    third = quizzes.start(cid, count=4)
    assert not {q["qkey"] for q in third["questions"]} & missed


def test_an_empty_notebook_has_no_practice_exam(nb):
    r = nb.api.post("/v1/quizzes", json={"course": nb.macro["id"]}, headers=AUTH)
    assert r.status_code == 409 and "no questions" in r.json()["error"]
    assert nb.api.get("/v1/quizzes/x_000000000000", headers=AUTH).status_code == 404


def test_questions_and_their_maths_as_plain_text():
    body = page("IS-LM", [(r"What is $\Delta Y$ when $G$ rises by $\frac{1}{2}$?", "B")])
    q = parse_question(next(iter(mcqs(body).values())))
    assert q["text"] == r"What is $\Delta Y$ when $G$ rises by $\frac{1}{2}$?"
    assert [o["text"] for o in q["options"]] == ["one", "two", "three", "four"]
    assert (q["key"], q["explanation"]) == ("B", "Because of is-lm.")
    assert plain_math(q["text"]) == "What is ΔY when G rises by 1/2?"
    assert plain_math(r"$\pi_t - \pi_{t-1} = -\alpha(u_t - u_n)$") == "πₜ − πₜ₋₁ = −α(uₜ − uₙ)"
    assert plain_math(r"$\Delta Y = \frac{\Delta G}{1-c_1}$, so $\bar i = 5\%$") == "ΔY = ΔG/(1−c₁), so ī = 5%"
    assert plain_math(r"$Y_D$ and $\pi^e_t$ and **bold**") == "Y_D and πᵉₜ and **bold**"


def test_the_study_tab_reads_notes_as_plain_text(nb):
    t = notebook_with_questions(nb)
    cid = nb.macro["id"]
    body = t["islm"]["body"] + f"\n\nSee [[Phillips curve]] and [[Phillips curve|the PC]].\n\n" \
        f"![The IS curve](figure:{nb.file['id']}/1)"
    nb.notebook.set_body(t["islm"]["id"], body)
    raw = nb.api.get(f"/v1/topics/{t['islm']['public_id']}", headers=AUTH).json()["body"]
    assert r"$\frac{1}{1-c_1}$" in raw and "[[Phillips curve]]" in raw
    plain = nb.api.get(f"/v1/topics/{t['islm']['public_id']}?plain=true", headers=AUTH).json()["body"]
    assert "1/(1−c₁)" in plain and "See Phillips curve and the PC." in plain
    assert f"![The IS curve](figure:{nb.file['id']}/1)" in plain  # the app draws it from the page below

    page = nb.api.get(f"/v1/files/{nb.file['id']}/pages/1", headers=AUTH)
    assert page.status_code == 200 and page.headers["content-type"] == "image/jpeg" and page.content[:2] == b"\xff\xd8"
    assert nb.api.get(f"/v1/files/{nb.file['id']}/pages/99", headers=AUTH).status_code == 404

    courses = {c["id"]: c for c in nb.api.get("/v1/study", headers=AUTH).json()["courses"]}
    assert courses[cid]["notebook"] == {"topics": 2, "questions": 6, "proposals": 0, "writing": False}
    assert all(c["notebook"] is None for i, c in courses.items() if i != cid)


def test_escaped_money_is_not_maths():
    assert plain_math(r"From \$13.5 trillion to \$9,700, and $\Delta Y$.") == "From $13.5 trillion to $9,700, and ΔY."


# -- quizzes in a chat ---------------------------------------------------------------------

def quiz_tools_for(nb) -> dict:
    from aide.tools.quiz import quiz_tools
    return {t.name: t.handler for t in quiz_tools(QuizStore(nb.notebook), None, nb.study, nb.notebook, ROME)}


def with_cards(nb, t) -> None:
    nb.notebook.set_body(t["islm"]["id"], t["islm"]["body"], cards=[("What does IS stand for?", "Investment = saving"),
                                                                      ("What shifts LM?", "The money supply")])


async def test_a_quiz_in_chat_asks_questions_and_cards_one_at_a_time(nb):
    t = notebook_with_questions(nb)
    with_cards(nb, t)
    tools, quizzes = quiz_tools_for(nb), QuizStore(nb.notebook)
    out = await tools["quiz_me"](course="macroeconomics", count=4, topics=["the is-lm model"])
    qid = out.split()[1].rstrip(",")
    assert out.startswith(f"Quiz {qid}, 4 questions.") and "Question 1 of 4, The IS-LM model" in out
    assert "[For you, not to say before they answer: the answer is " in out
    questions = quizzes.quiz(qid)["questions"]
    assert all(q["topic_title"] == "The IS-LM model" for q in questions)
    assert {q.get("type", "mcq") for q in questions} == {"mcq", "card"}  # both kinds from 3 questions and 2 cards

    for n, q in enumerate(questions, 1):
        card = q.get("type") == "card"
        if card:
            assert "a flashcard: they answer in their own words" in out and "\nA) " not in out
        else:
            assert "(multiple choice)" in out and "\nA) one\nB) two" in out
        right = n != 2  # the second one wrong
        answer = ("right" if right else "wrong") if card else (q["key"] if right else "ABCD".replace(q["key"], "")[0])
        out = await tools["quiz_answer"](quiz=qid, answer=answer.lower())
        assert out.startswith("Right." if right else "Wrong: the answer is ")
        if n < 4:
            assert f"({n - (n >= 2)} of {n} right so far.)" in out and f"Question {n + 1} of 4" in out
    assert "The quiz is over: 3 of 4 right (1 wrong, 0 blank). To go over: The IS-LM model (3 of 4)." in out
    with pytest.raises(ValueError, match="over"):
        await tools["quiz_answer"](quiz=qid, answer="A")

    # Its answers count for the next pick, but it isn't a practice exam.
    assert nb.db.conn.execute("SELECT COUNT(*) FROM quiz_answers").fetchone()[0] == 4
    bank = nb.api.get(f"/v1/quizzes?course={nb.macro['id']}", headers=AUTH).json()
    asked = [q for q in questions if q.get("type") != "card"]
    assert bank["past"] == [] and bank["unseen"] == 6 - len(asked)
    assert bank["to_review"] == (questions[1].get("type") != "card")  # the second, if it was multiple choice
    done = nb.api.get(f"/v1/quizzes/{qid}", headers=AUTH).json()
    assert done["score"]["right"] == 3 and {q.get("type") for q in done["questions"]} == {None, "card"}


async def test_a_card_answered_wrong_comes_back_and_stopping_keeps_what_was_answered(nb):
    t = notebook_with_questions(nb)
    with_cards(nb, t)
    tools, quizzes = quiz_tools_for(nb), QuizStore(nb.notebook)
    out = await tools["quiz_me"](course="macroeconomics", count=2, style="cards")
    qid = out.split()[1].rstrip(",")
    first = quizzes.quiz(qid)["questions"][0]
    assert first["type"] == "card" and f"the answer is {first['key']}" in out
    out = await tools["quiz_answer"](quiz=qid, answer="wrong")
    assert out.startswith(f"Wrong: the answer is {first['key']}.") and "Question 2 of 2" in out
    assert await tools["end_quiz"](quiz=qid) == ("The quiz is over: 0 of 1 right (1 wrong, 0 blank). To go over: "
                                                 "The IS-LM model (0 of 1). Tell the user, and offer to go through "
                                                 "what they missed.")
    assert len(quizzes.quiz(qid)["questions"]) == 1

    again = await tools["quiz_me"](course="macroeconomics", count=1, style="cards")
    assert f"the answer is {first['key']}" in again  # the missed one first
    # Starting another ends this one; with no answers it's dropped.
    await tools["quiz_me"](course="macroeconomics", style="questions")
    assert quizzes.quiz(again.split()[1].rstrip(",")) is None

    with pytest.raises(ValueError, match="isn't one of the options"):
        await tools["quiz_answer"](quiz=quizzes.conn.execute(
            "SELECT public_id FROM quizzes WHERE finished_at IS NULL").fetchone()[0], answer="F")


async def test_a_quiz_needs_something_to_ask(nb):
    notebook_with_questions(nb)  # questions, no cards
    with pytest.raises(ValueError, match="no flashcards"):
        await quiz_tools_for(nb)["quiz_me"](course="macroeconomics", style="cards")
