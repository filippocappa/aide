import random

import pytest

from aide.notebook import mcqs
from aide.quiz import QuizStore, parse_question, plain_math
from test_api import AUTH, done
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
    assert last["text"].startswith("To go over:") and last["text"].endswith("Want to go through them?")
    [card] = last["attachments"]  # the score is on the card, the note Professor reads stays out of sight
    assert card["type"] == "quiz" and "questions" not in card["quiz"]
    assert (card["quiz"]["id"], card["quiz"]["title"], card["quiz"]["score"]["points"]) == (quiz["id"], "Practice exam", 1.75)
    assert [t["title"] for t in card["quiz"]["score"]["topics"]]
    assert not any(m["text"].startswith("[Practice exam") for m in chat_messages(nb))
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


def test_formulas_on_their_own_lines_stay_latex_for_the_app():
    text = "\n".join([r"Real GDP, $Y_t$ in \$:", r"$$P_t=\frac{\$Y_t}{Y_t}$$", "",
                      r"> $$", r"> u=\frac{U}{L}", r"> $$", "", r"so $$g=\pi+g_Y$$ inline", r"$$a_{t-1}$$."])
    assert plain_math(text, blocks=True).split("\n") == [
        "Real GDP, Yₜ in $:", r"$$P_t=\frac{\$Y_t}{Y_t}$$", "", r"> $$", r"> u=\frac{U}{L}", r"> $$", "",
        "so g=π+g_Y inline", r"$$a_{t-1}$$."]
    assert "$$" not in plain_math(text)
    assert plain_math(text, blocks=True, inline=True).split("\n")[:2] == [r"Real GDP, \(Y_t\) in $:",
                                                                           r"$$P_t=\frac{\$Y_t}{Y_t}$$"]
    assert plain_math("so $$g=\\pi\n+g_Y$$ inline", blocks=True, inline=True) == r"so \(g=\pi +g_Y\) inline"


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
    brief = courses[cid]["notebook"]
    assert {k: v for k, v in brief.items() if k != "mastery"} == {"topics": 2, "questions": 6, "proposals": 0,
                                                                  "writing": False}
    assert [(m["title"], m["known"], m["learning"], m["unseen"]) for m in brief["mastery"]] == \
        [("The IS-LM model", 0, 0, 3), ("Phillips curve", 0, 0, 3)]
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


MOCK = """{"minutes": 90, "right": 1, "wrong": 0, "blank": 0}
**1.** What shifts IS right?
- A) More spending
- B) More money

> [!success]- Answer
> **A**. G is part of demand.
> Topic: [[The IS-LM model]]

**2.** Who drew the curve?
- A) Phillips
- B) Keynes

> [!success]- Answer
> **A**. He did, in 1958.
> Topic: [[Phillips curve]]

**3.** (15 points) Explain crowding out with the IS-LM model.

> [!success]- Model answer
> Spending shifts IS right, the rate rises, investment falls.
> Topic: [[The IS-LM model]]

> [!info]- Marking
> - 5 points: IS shifts right
> - 10 points: the rate rises and investment falls"""


EXERCISES = """**Exercise 1.** (from: Esercitazione 3.pdf, p. 2; solution: Soluzioni 3.pdf, p. 1)
With $c_1 = 0.5$, what is the multiplier?

> [!success]- Solution
> $1/(1-0.5) = 2$.
> **Answer:** 2
"""


def test_an_exercises_source_as_a_short_name():
    from aide.quiz import _source_name
    assert _source_name("Esercitazione 3.pdf, p. 2; solution: Soluzioni 3.pdf, p. 1") == "Esercitazione 3, p. 2"
    assert _source_name("2026-09-28.pdf, p. 1; solution: 2026-09-28.pdf, p. 1") == "Sheet of 28 Sep, p. 1"


def with_exercises(nb, t) -> None:
    nb.notebook.set_exercises(t["islm"], EXERCISES, [], True)


async def test_a_practice_exam_mixes_questions_cards_and_the_courses_exercises(nb):
    from test_notebook import drain, sent

    t = notebook_with_questions(nb)
    with_cards(nb, t)
    with_exercises(nb, t)
    cid = nb.macro["id"]
    bank = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()
    assert (bank["cards"], bank["exercises"]) == (2, 1)
    islm = bank["topics"][0]
    assert {k: islm[k] for k in ("questions", "cards", "exercises", "known", "learning", "unseen")} == \
        {"questions": 3, "cards": 2, "exercises": 1, "known": 0, "learning": 0, "unseen": 5}

    quiz = nb.api.post("/v1/quizzes", json={"course": cid, "count": 2, "cards": 1, "exercises": 1},
                       headers=AUTH).json()
    assert [q.get("type", "mcq") for q in quiz["questions"]] == ["mcq", "mcq", "card", "open"]
    assert quiz["questions"][0]["source"] == {"kind": "professor", "name": None}
    assert "key" not in quiz["questions"][0] and quiz["questions"][2]["key"]  # a card's back, to turn it
    ex = quiz["questions"][3]
    assert ex["source"] == {"kind": "course", "name": "Esercitazione 3, p. 2"} and ex["points"] == 1
    assert ex["text"].startswith("With c₁ = 0.5") and "model_answer" not in ex

    # Checked one at a time: each answer is final and comes back with its key.
    key = QuizStore(nb.notebook).quiz(quiz["id"])["questions"][0]["key"]
    checked = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": 1, "answer": key}, headers=AUTH).json()
    assert (checked["answer"], checked["key"], checked["correct"]) == (key, key, True)
    assert checked["explanation"].startswith("Because of")
    again = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": 1, "answer": "A"}, headers=AUTH)
    assert again.status_code == 409
    card = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": 3, "answer": "wrong"}, headers=AUTH).json()
    assert card["type"] == "card" and card["answer"] == "wrong" and card["correct"] is False and card["key"]
    shown = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": 4, "answer": {"text": "It is 2."}},
                        headers=AUTH).json()
    assert shown["model_answer"].startswith("1/(1−0.5) = 2") and shown["awarded"] is None
    assert shown["response"] == {"text": "It is 2.", "photos": []}
    assert nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": 9}, headers=AUTH).status_code == 404
    taking = nb.api.get(f"/v1/quizzes/{quiz['id']}", headers=AUTH).json()
    assert taking["checked"] == [1, 3, 4] and "key" not in taking["questions"][1]

    # Finished: the checked answers stand over what's sent, the card scores no penalty, the exercise is marked.
    finished = nb.api.post(f"/v1/quizzes/{quiz['id']}/finish", json={"answers": {"1": "Z", "3": "right"}},
                           headers=AUTH).json()
    assert {k: finished["score"][k] for k in ("points", "max", "right", "wrong", "blank", "grading")} == \
        {"points": 1.0, "max": 4.0, "right": 1, "wrong": 2, "blank": 1, "grading": True}  # the exercise waits
    before = len(nb.client.requests)
    nb.client.responses.append(done('[{"n": 4, "points": 1, "feedback": "Right."}]'))
    await drain(nb)
    [grade] = nb.client.requests[before:]
    assert "Question 4 (1 points):" in sent(grade) and "The course's solution" in sent(grade)
    marked = nb.api.get(f"/v1/quizzes/{quiz['id']}", headers=AUTH).json()
    assert (marked["score"]["points"], marked["score"]["grading"]) == (2.0, False)
    assert chat_messages(nb)[-1]["attachments"][0]["quiz"]["score"]["points"] == 2.0

    after = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()["topics"][0]
    assert after["known"] + after["learning"] >= 2  # the card and the questions answered count
    [course] = [c for c in nb.api.get("/v1/study", headers=AUTH).json()["courses"] if c["id"] == cid]
    mastery = course["notebook"]["mastery"]
    assert [m["title"] for m in mastery] == ["The IS-LM model", "Phillips curve"]
    assert mastery[0] == {k: after[k] for k in ("id", "title", "known", "learning", "unseen")}


def test_a_practice_exam_with_only_cards_or_none_of_them(nb):
    t = notebook_with_questions(nb)
    cid = nb.macro["id"]
    r = nb.api.post("/v1/quizzes", json={"course": cid, "count": 0, "cards": 3}, headers=AUTH)
    assert r.status_code == 409  # no cards yet
    with_cards(nb, t)
    quiz = nb.api.post("/v1/quizzes", json={"course": cid, "count": 0, "cards": 3}, headers=AUTH).json()
    assert [q["type"] for q in quiz["questions"]] == ["card", "card"]


async def test_a_mock_exam_like_the_real_one_taken_and_its_open_answer_marked(nb):
    from test_food import upload
    from test_notebook import drain, sent
    from test_study import add_pdf, make_pdf

    notebook_with_questions(nb)
    cid = nb.macro["id"]
    nb.notebook.set_intro(cid, "15 multiple-choice questions, no penalty, and one open question of 15 points",
                          "## The exam\nMultiple choice and one open question.")
    add_pdf(nb.api, data=make_pdf(None, ["Esame 2025: explain the multiplier"]), name="Esame 2025-01", course=cid)
    before = len(nb.client.requests)
    nb.client.responses += [done(MOCK), done('{"1": "A", "2": "A"}')]
    r = nb.api.post(f"/v1/notebook/mocks?course={cid}", headers=AUTH)
    assert r.status_code == 202 and r.json()["busy"]
    await drain(nb)
    write, check = nb.client.requests[before:]
    assert (write["model"], check["model"]) == ("smart", "m")
    assert "How the exam works, from the Introduction:\nExam: 15 multiple-choice" in sent(write)
    assert "## The IS-LM model\nIS-LM in one line." in sent(write) and "What shifts LM up?" not in sent(write)
    assert "Past exams, for the style:" in sent(write) and "Esame 2025: explain the multiplier" in sent(write)
    assert "**3.**" not in sent(check) and "IS-LM in one line." in sent(check)  # the MCQs, from every topic's notes

    [m] = nb.api.get(f"/v1/notebook/mocks?course={cid}", headers=AUTH).json()["mocks"]
    assert {k: m[k] for k in ("title", "minutes", "scoring", "count", "mcq", "open", "points", "taken", "best")} == {
        "title": "Mock exam 1", "minutes": 90, "scoring": {"right": 1.0, "wrong": 0.0, "blank": 0.0}, "count": 3,
        "mcq": 2, "open": 1, "points": 17.0, "taken": 0, "best": None}
    assert nb.api.get(f"/v1/notebook?course={cid}", headers=AUTH).json()["mocks"] == 1
    paper = nb.api.get(f"/v1/mocks/{m['id']}", headers=AUTH).json()
    assert [(q["type"], q["points"]) for q in paper["questions"]] == [("mcq", None), ("mcq", None), ("open", 15.0)]
    assert paper["questions"][2]["text"] == "Explain crowding out with the IS-LM model."
    assert "[!success]" not in paper["body"] and "key" not in paper["questions"][0]
    assert nb.api.get("/v1/mocks/m_000000000000", headers=AUTH).status_code == 404
    assert chat_messages(nb)[-1]["text"].startswith("I've written **Mock exam 1** for macroeconomics: 2 "
                                                    "multiple-choice questions and 1 open question in 90 min, 17 "
                                                    "points, multiple choice scored like the exam (right 1, no penalty")

    # Taken in the app: the open answer typed, with a photo of the working.
    quiz = nb.api.post("/v1/quizzes", json={"course": cid, "mock": m["id"]}, headers=AUTH).json()
    assert (quiz["kind"], quiz["mock"], quiz["minutes"], quiz["count"]) == ("mock", m["id"], 90, 3)
    assert quiz["questions"][2]["type"] == "open" and quiz["questions"][2]["points"] == 15
    law = nb.study.course_by_name("business law")["id"]
    assert nb.api.post("/v1/quizzes", json={"course": law, "mock": m["id"]}, headers=AUTH).status_code == 404
    photo = upload(nb.api).json()["id"]
    posted = len(chat_messages(nb))
    answers = {"1": "A", "2": "B", "3": {"text": "IS shifts right and the rate rises.", "photos": [photo, "p_0"]}}
    finished = nb.api.post(f"/v1/quizzes/{quiz['id']}/finish", json={"answers": answers}, headers=AUTH).json()
    assert {k: finished["score"][k] for k in ("points", "max", "right", "wrong", "grading")} == \
        {"points": 1.0, "max": 17.0, "right": 1, "wrong": 2, "grading": True}  # the open one waits, unmarked
    assert len(chat_messages(nb)) == posted  # the result comes once it's marked

    before = len(nb.client.requests)
    nb.client.responses.append(done('[{"n": 3, "points": 9.7, "feedback": "You left out investment."}]'))
    await drain(nb)
    [grade] = nb.client.requests[before:]
    assert grade["model"] == "smart" and "Question 3 (15 points):" in sent(grade)
    assert "Marking:\n- 5 points: IS shifts right" in sent(grade) and "IS shifts right and the rate rises." in sent(grade)
    assert [b["type"] for b in grade["messages"][-1]["content"]].count("image") == 1
    marked = nb.api.get(f"/v1/quizzes/{quiz['id']}", headers=AUTH).json()
    assert {k: marked["score"][k] for k in ("points", "right", "wrong", "grading")} == \
        {"points": 10.5, "right": 2, "wrong": 1, "grading": False}
    q3 = marked["questions"][2]
    assert (q3["awarded"], q3["feedback"], q3["correct"], q3["answer"]) == (9.5, "You left out investment.", True, None)
    assert q3["response"] == {"text": "IS shifts right and the rate rises.", "photos": [photo]}
    assert q3["model_answer"].startswith("Spending shifts IS right") and "10 points" in q3["rubric"]
    result = chat_messages(nb)[-1]
    assert result["text"].startswith("- Question 3: 9.5 / 15. You left out investment.")
    [card] = result["attachments"]
    assert (card["quiz"]["title"], card["quiz"]["score"]["points"], card["quiz"]["score"]["max"]) == ("Mock exam 1", 10.5, 17)
    assert nb.push.messages[-1][2] == "Mock exam 1: 10.5 / 17 (2 right, 1 wrong, 0 blank)."
    assert not any(m["text"].startswith("[Mock exam") for m in chat_messages(nb))
    [m] = nb.api.get(f"/v1/notebook/mocks?course={cid}", headers=AUTH).json()["mocks"]
    assert (m["taken"], m["best"], m["last"]["id"]) == (1, 10.5, quiz["id"])

    # Marking that fails leaves the open answer at 0, and the result still comes.
    again = nb.api.post("/v1/quizzes", json={"course": cid, "mock": m["id"]}, headers=AUTH).json()
    nb.api.post(f"/v1/quizzes/{again['id']}/finish", json={"answers": {"1": "A", "3": {"text": "No idea"}}},
                headers=AUTH)
    nb.client.responses.append(done("I can't read this."))
    await drain(nb)
    score = nb.api.get(f"/v1/quizzes/{again['id']}", headers=AUTH).json()["score"]
    assert (score["points"], score["grading"]) == (1.0, False)
    text = chat_messages(nb)[-1]["text"]
    assert text.startswith("I couldn't mark the open answers") and "- Question 3: not marked (15 points)." in text

    # Obsidian: the paper first, the answers after, linked from the Introduction.
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    page = (root / "Mock exams/Mock exam 1.md").read_text()
    assert "\n# Mock exam 1: macroeconomics\n\n90 minutes · 17 points · multiple choice: right 1, wrong 0, blank 0\n" \
        in page
    printed, _, answers = page.partition("## Answers")
    assert "**3.** (15 points) Explain crowding out" in printed and "[!success]" not in printed
    assert "> **A**. G is part of demand." in answers and "> [!info]- Marking" in answers
    assert "- Mock exams: [[Aide/macroeconomics/Mock exams/Mock exam 1|Mock exam 1]]" in \
        (root / "00 Introduction.md").read_text()

    # Nothing to write it from.
    assert nb.api.post(f"/v1/notebook/mocks?course={law}", headers=AUTH).status_code == 409
    assert nb.api.post("/v1/notebook/mocks?course=999", headers=AUTH).status_code == 404


PAPER = """{"title": "Mock exam 2026", "minutes": 60, "right": 1, "wrong": -0.25, "blank": 0}
**1.** What shifts IS right?
- A) More spending
- B) More money

> [!success]- Answer
> **B**. Money shifts it.
> Topic: [[The IS-LM model]]

**2.** Who drew the curve?
- A) Phillips
- B) Keynes

> [!success]- Answer
> **A**. He did, in 1958.
> Topic: [[Phillips curve]]"""


async def test_the_courses_own_papers_copied_apart_from_the_written_mocks(nb):
    from test_notebook import drain, sent
    from test_study import add_pdf, make_pdf

    notebook_with_questions(nb)
    cid = nb.macro["id"]
    r = nb.api.post(f"/v1/notebook/mocks?course={cid}&past=true", headers=AUTH)
    assert r.status_code == 409 and "no past exams" in r.json()["error"]
    paper = add_pdf(nb.api, data=make_pdf(None, ["Mock exam 2026: what shifts IS right"]),
                    name="Example Questions Midterm", course=cid).json()
    before = len(nb.client.requests)
    nb.client.responses += [done(PAPER), done('{"1": "A", "2": "A"}'),
                            done('[{"n": 1, "key": "A", "why": "G is part of demand."}]')]
    r = nb.api.post(f"/v1/notebook/mocks?course={cid}&past=true", headers=AUTH)
    assert r.status_code == 202
    await drain(nb)
    copy, check, fix = nb.client.requests[before:]
    assert [q["model"] for q in (copy, check, fix)] == ["smart", "m", "smart"]
    assert "The paper:\n" in sent(copy) and "Mock exam 2026: what shifts IS right" in sent(copy)
    assert "(The second reader chose: A)" in sent(fix) and "**2.**" not in sent(fix)

    # Only the key and its why changed; the question is the paper's.
    [m] = nb.notebook.mocks(cid)
    assert m["source"] == paper["id"] and m["title"] == "Mock exam 2026" and m["number"] == 1
    assert "> **A**. G is part of demand.\n> Topic: [[The IS-LM model]]" in m["body"]
    assert "- B) More money" in m["body"] and "Money shifts it" not in m["body"]
    assert [q["key"] for q in m["questions"]] == ["A", "A"]
    assert chat_messages(nb)[-1]["text"].startswith("I've copied the course's own paper for macroeconomics: "
                                                    "**Mock exam 2026** (2 questions), as they are")
    r = nb.api.post(f"/v1/notebook/mocks?course={cid}&past=true", headers=AUTH)
    assert r.status_code == 409 and "copied already" in r.json()["error"]

    # A written one is numbered on its own and listed after the course's papers.
    nb.client.responses += [done(MOCK), done('{"1": "A", "2": "A"}')]
    nb.api.post(f"/v1/notebook/mocks?course={cid}", headers=AUTH)
    await drain(nb)
    listed = nb.api.get(f"/v1/notebook/mocks?course={cid}", headers=AUTH).json()["mocks"]
    assert [(x["title"], x["number"], x["source"]) for x in listed] == [
        ("Mock exam 2026", 1, {"id": paper["id"], "name": "Example Questions Midterm.pdf"}), ("Mock exam 1", 1, None)]
    assert (listed[0]["minutes"], listed[0]["scoring"]["wrong"]) == (60, -0.25)

    # Obsidian: the papers in a folder of their own.
    await nb.vault.sync()
    root = nb.vault.folder / "Aide/macroeconomics"
    page = (root / "Past exams/Mock exam 2026.md").read_text()
    assert "  - past-exam\n" in page and "\n# Mock exam 2026: macroeconomics\n" in page
    assert "copied from Example Questions Midterm.pdf" in page
    assert (root / "Mock exams/Mock exam 1.md").exists()
    intro = (root / "00 Introduction.md").read_text()
    assert "- Past exams: [[Aide/macroeconomics/Past exams/Mock exam 2026|Mock exam 2026]]" in intro
    assert "- Mock exams: [[Aide/macroeconomics/Mock exams/Mock exam 1|Mock exam 1]]" in intro


def test_a_mock_exams_questions_read_from_its_paper():
    from aide.notebook import mock_questions

    titles = {"the is-lm model": {"public_id": "t_1", "title": "The IS-LM model"}}
    [mcq, open_] = [q for q in mock_questions(MOCK.partition("\n")[2], titles) if q["topic"]][:2]
    assert (mcq["type"], mcq["key"], mcq["explanation"], mcq["topic_title"]) == \
        ("mcq", "A", "G is part of demand.", "The IS-LM model")
    assert (open_["type"], open_["points"], open_["rubric"].splitlines()[0]) == ("open", 15.0, "- 5 points: IS shifts right")


async def test_a_study_session_marks_as_it_goes_and_asks_the_missed_again(nb):
    t = notebook_with_questions(nb)
    with_cards(nb, t)
    cid = nb.macro["id"]
    posted = len(chat_messages(nb))
    quiz = nb.api.post("/v1/quizzes", json={"course": cid, "kind": "study", "count": 2, "cards": 1, "write": 1,
                                            "minutes": 30}, headers=AUTH).json()
    assert (quiz["kind"], quiz["title"], quiz["minutes"], quiz["count"]) == ("study", "Study", None, 4)
    by_type = {q.get("type", "mcq"): q for q in quiz["questions"]}
    assert sorted(by_type) == ["card", "mcq", "open"]
    written, card = by_type["open"], by_type["card"]
    assert written["text"] != card["text"] and written["points"] == 1  # one card isn't both turned and written
    stored = QuizStore(nb.notebook).quiz(quiz["id"])["questions"][written["n"] - 1]
    assert stored["model_answer"] in ("Investment = saving", "The money supply")

    # Multiple choice: shown at once, and asked again in the next round.
    mcq = by_type["mcq"]
    key = QuizStore(nb.notebook).quiz(quiz["id"])["questions"][mcq["n"] - 1]["key"]
    wrong = "A" if key != "A" else "B"
    first = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": mcq["n"], "answer": wrong}, headers=AUTH).json()
    assert first["correct"] is False and first["key"] == key
    again = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": mcq["n"], "answer": key}, headers=AUTH).json()
    assert again["correct"] is True
    nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": card["n"], "answer": "right"}, headers=AUTH)

    # Written: marked now by the fast model, with a line on what was missing.
    before = len(nb.client.requests)
    nb.client.responses.append(done('{"points": 0.5, "feedback": "Half there: say what shifts it."}'))
    marked = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": written["n"], "answer": {"text": "Money"}},
                         headers=AUTH).json()
    [ask] = nb.client.requests[before:]
    assert ask["model"] == "m" and "The student's answer:\nMoney" in ask["messages"][0]["content"][0]["text"]
    assert (marked["awarded"], marked["correct"], marked["feedback"]) == (0.5, True, "Half there: say what shifts it.")
    assert marked["model_answer"] == stored["model_answer"] and marked["rubric"] is None

    # The model fails: 502, and the user says whether it was right.
    nb.client.responses.append(done("no idea"))
    r = nb.api.post(f"/v1/quizzes/{quiz['id']}/check", json={"n": written["n"], "answer": {"text": "M"}}, headers=AUTH)
    assert r.status_code == 502
    mine = nb.api.post(f"/v1/quizzes/{quiz['id']}/mark", json={"n": written["n"], "correct": True}, headers=AUTH).json()
    assert (mine["awarded"], mine["correct"]) == (1.0, True)
    assert nb.api.post(f"/v1/quizzes/{quiz['id']}/mark", json={"n": mcq["n"], "correct": True},
                       headers=AUTH).status_code == 409

    # Finished: nothing posted, not a practice exam, and every answer counted for how well it's known.
    finished = nb.api.post(f"/v1/quizzes/{quiz['id']}/finish", json={"answers": {}}, headers=AUTH).json()
    assert finished["finished_at"] and finished["score"]["grading"] is False
    assert len(chat_messages(nb)) == posted
    bank = nb.api.get(f"/v1/quizzes?course={cid}", headers=AUTH).json()
    assert bank["past"] == []
    seen = QuizStore(nb.notebook)._last(cid)
    assert sum(r["seen"] for r in seen.values()) == 5  # the question twice, the card, the written card twice
    assert all(r["correct"] for r in seen.values())  # the latest answer counts: all right now

    # A practice exam's check is still final, and has no marking.
    exam = nb.api.post("/v1/quizzes", json={"course": cid, "count": 1}, headers=AUTH).json()
    nb.api.post(f"/v1/quizzes/{exam['id']}/check", json={"n": 1, "answer": "A"}, headers=AUTH)
    assert nb.api.post(f"/v1/quizzes/{exam['id']}/check", json={"n": 1, "answer": "B"}, headers=AUTH).status_code == 409
    assert nb.api.post(f"/v1/quizzes/{exam['id']}/mark", json={"n": 1, "correct": True}, headers=AUTH).status_code == 404
