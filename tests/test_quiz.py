import random

from aide.notebook import mcqs
from aide.quiz import QuizStore, parse_question, plain_math
from test_api import AUTH
from test_notebook import chat_messages, nb  # noqa: F401 (the fixture)


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
