import asyncio
import json
import random
from types import SimpleNamespace

import pytest
from fastapi.testclient import TestClient

from aide.channels.api import create_app
from aide.lessons import ASK_PROMPT, BUILD_PROMPT, EXPLAIN_PROMPT, LessonStore, parse_lesson
from aide.quiz import MARK_PROMPT
from aide.reminders import ReminderStore
from test_api import AUTH, TOKEN
from test_notebook import nb  # noqa: F401 (the fixture)
from test_study import ROME

LESSON = r"""# Hook
Why do prices rise when the central bank prints money? This topic is 3–4 questions on the exam.
# Goals
- You'll be able to read the IS curve
- You'll be able to find the multiplier
# Step: Demand makes output
When you spend, someone earns: **demand** sets output in the short run.
$$Y = C + I + G$$
## Again
Think of a café: more customers, more coffee made.
## Say
Y equals C plus I plus G.
## Key idea
Output follows demand in the short run.
## Choice
What sets output in the short run?
- [x] Demand :: Firms make what's bought.
- [ ] The money supply alone :: Money works through interest rates, not directly.
- [ ] Prices :: Prices are fixed in the short run here.
## Write
If G rises by 10, what happens to Y at first?
Answer: Y rises by 10 times the multiplier $\frac{1}{1-c_1}$.
# Step: The multiplier
Each euro spent is spent again, in part: with $c_1 = 0.6$ the multiplier is $\frac{1}{1-c_1} = 2.5$.
## Again
A rumour passed on: each person tells 60% of what they heard.
## Key idea
The multiplier is $\frac{1}{1-c_1}$.
## Choice
With $c_1 = 0.5$ the multiplier is:
- [ ] 0.5 :: That's $c_1$ itself.
- [x] 2 :: $\frac{1}{1-0.5} = 2$.
- [ ] 1.5 :: Added, not divided.
- [ ] 5 :: That's $\frac{1}{0.2}$.
## Write
Why is the multiplier above 1?
Answer: spending becomes income that is partly spent again.
# Step: A broken one
No check here, so it's left out.
"""


class FakeAsk:
    """Answers by prompt: a list of answers per prompt, used up in order; every call recorded."""

    def __init__(self, answers: dict[str, list[str]]):
        self.answers = answers
        self.calls: list[dict] = []

    async def __call__(self, system, content, max_tokens, fast, live):
        self.calls.append({"system": system, "text": content[0]["text"], "fast": fast, "live": live})
        answer = self.answers[system].pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


@pytest.fixture
def ls(nb):
    cid = nb.macro["id"]
    topics = []
    for title, body in [("Demand", "Output follows demand.\n\n$$Y = C + I + G$$"), ("The multiplier", "1/(1-c1)."),
                        ("Not written", ""), ("IS-LM", "Both markets at once.")]:
        t = nb.notebook.add_topic(cid, title)
        if body:
            nb.notebook.set_body(t["id"], body)
        topics.append(nb.notebook.topic(t["public_id"]))
    ask = FakeAsk({BUILD_PROMPT: [LESSON, LESSON, LESSON], ASK_PROMPT: [], MARK_PROMPT: [], EXPLAIN_PROMPT: []})
    store = LessonStore(nb.notebook, ask, rng=random.Random(1))
    api = TestClient(create_app(nb.agent, ReminderStore(nb.db.conn), None, ROME, TOKEN, study=nb.study,
                                notebook=nb.notebook, lessons=store))
    return SimpleNamespace(nb=nb, api=api, store=store, ask=ask, cid=cid, topics=topics)


def build(ls) -> None:
    while not ls.store.queue.empty():
        asyncio.run(ls.store.build(ls.store.queue.get_nowait()))


def test_parse_lesson_reads_the_tagged_text_and_keeps_latex():
    lesson = parse_lesson(LESSON, random.Random(1))
    assert lesson["goals"] == ["You'll be able to read the IS curve", "You'll be able to find the multiplier"]
    assert lesson["hook"].startswith("Why do prices rise")
    assert [s["title"] for s in lesson["steps"]] == ["Demand makes output", "The multiplier"]  # the broken one left out
    one, two = lesson["steps"]
    assert "$$Y = C + I + G$$" in one["body"] and one["say"] == "Y equals C plus I plus G." and two["say"] is None
    assert one["again"].startswith("Think of a café")
    choice, write = one["checks"]
    assert choice["type"] == "choice" and len(choice["options"]) == 3
    right = next(o for o in choice["options"] if o["letter"] == choice["key"])
    assert right["text"] == "Demand" and right["why"] == "Firms make what's bought."
    assert write == {"type": "write", "question": "If G rises by 10, what happens to Y at first?",
                     "answer": r"Y rises by 10 times the multiplier $\frac{1}{1-c_1}$."}
    assert r"\frac{1}{1-0.5}" in next(o["why"] for o in two["checks"][0]["options"] if o["text"] == "2")
    with pytest.raises(ValueError):
        parse_lesson("# Hook\nNothing else.")


def test_a_lesson_written_from_the_notes_then_gone_through(ls):
    demand = ls.topics[0]
    assert ls.api.get(f"/v1/topics/{demand['public_id']}/lesson", headers=AUTH).status_code == 404
    r = ls.api.post(f"/v1/topics/{demand['public_id']}/lesson", headers=AUTH)
    assert r.status_code == 202 and r.json()["status"] == "building" and r.json()["steps"] == []
    # asked again while it's written: the same one, not a second
    assert ls.api.post(f"/v1/topics/{demand['public_id']}/lesson", headers=AUTH).json()["id"] == r.json()["id"]
    build(ls)
    call = ls.ask.calls[0]
    assert call["system"] == BUILD_PROMPT and not call["fast"] and not call["live"]  # may wait at the plan's limit
    assert "Topic: Demand\n" in call["text"] and "Y = C + I + G" in call["text"]
    assert "After it: The multiplier; IS-LM" in call["text"]

    lesson = ls.api.get(f"/v1/topics/{demand['public_id']}/lesson?plain=true&latex=true", headers=AUTH).json()
    assert lesson["status"] == "ready" and lesson["count"] == len(lesson["steps"]) == 2
    assert lesson["topic"] == {"id": demand["public_id"], "title": "Demand"} and lesson["at"] == 0
    step = lesson["steps"][0]
    assert step["say"] == "Y equals C plus I plus G." and step["answers"] == {}
    choice = step["checks"][0]
    assert "key" not in choice and all("why" not in o for o in choice["options"])  # nothing given away
    assert step["checks"][1] == {"n": 2, "type": "write",
                                 "question": "If G rises by 10, what happens to Y at first?"}

    raw = ls.store.lesson(lesson["id"])["content"]["steps"][0]["checks"][0]
    wrong = next(o["letter"] for o in raw["options"] if o["letter"] != raw["key"])
    got = ls.api.post(f"/v1/lessons/{lesson['id']}/check", json={"step": 1, "check": 1, "answer": wrong},
                      headers=AUTH).json()
    assert got["correct"] is False and got["key"] == raw["key"] and got["key_why"] == "Firms make what's bought."
    assert got["feedback"] in {o["why"] for o in raw["options"]}
    assert len(ls.ask.calls) == 1  # a choice needs no model

    ls.ask.answers[MARK_PROMPT].append(json.dumps({"points": 1, "feedback": "Right: times the multiplier."}))
    got = ls.api.post(f"/v1/lessons/{lesson['id']}/check",
                      json={"step": 1, "check": 2, "answer": "it goes up by more than 10"}, headers=AUTH).json()
    assert got["correct"] is True and got["awarded"] == 1 and got["feedback"] == "Right: times the multiplier."
    assert ls.ask.calls[-1]["fast"] and ls.ask.calls[-1]["live"]  # the fast model, never waiting
    assert "it goes up by more than 10" in ls.ask.calls[-1]["text"]

    ls.ask.answers[MARK_PROMPT].append(RuntimeError("down"))  # a mark that fails: what was expected, no verdict
    got = ls.api.post(f"/v1/lessons/{lesson['id']}/check", json={"step": 1, "check": 2, "answer": "more"},
                      headers=AUTH).json()
    assert got["correct"] is None and got["expected"].startswith("Y rises by 10")

    ls.ask.answers[ASK_PROMPT].append("Because each euro is spent again.")
    r = ls.api.post(f"/v1/lessons/{lesson['id']}/ask",
                    json={"step": 2, "question": "why above 1?", "history": [{"q": "and c1?", "a": "the MPC"}]},
                    headers=AUTH)
    assert r.json()["answer"] == "Because each euro is spent again."
    sent = ls.ask.calls[-1]
    assert sent["live"] and not sent["fast"] and "Their question: why above 1?" in sent["text"]
    assert "They asked: and c1?\nYou answered: the MPC" in sent["text"] and '"The multiplier"' in sent["text"]

    assert ls.api.post(f"/v1/lessons/{lesson['id']}/progress", json={"at": 1}, headers=AUTH).json()["at"] == 1
    assert ls.api.post(f"/v1/lessons/{lesson['id']}/progress", json={"at": 9}, headers=AUTH).status_code == 400
    again = ls.api.get(f"/v1/topics/{demand['public_id']}/lesson", headers=AUTH).json()
    assert again["at"] == 1 and again["started_at"] and again["steps"][0]["answers"]["1"]["correct"] is False

    ls.ask.answers[EXPLAIN_PROMPT].append(json.dumps({
        "verdict": "partly", "got": ["demand sets output"], "missing": ["the multiplier's formula"],
        "review": [2, 7], "feedback": "Good start. Look at the multiplier again."}))
    done = ls.api.post(f"/v1/lessons/{lesson['id']}/finish", json={"explanation": "Demand makes output."},
                       headers=AUTH).json()
    assert done["finished_at"] and done["at"] == 2 and done["verdict"] == "partly"
    assert done["explained"]["review"] == [2] and done["explained"]["missing"] == ["the multiplier's formula"]
    assert "1. Demand makes output: Output follows demand" in ls.ask.calls[-1]["text"]
    assert done["next"] == {"id": ls.topics[1]["public_id"], "title": "The multiplier"}
    # the next one is being written already
    assert ls.store.for_topic(ls.topics[1]["id"])["status"] == "building"


def test_the_path_through_a_course_and_lessons_written_again(ls):
    path = ls.api.get(f"/v1/lessons?course={ls.cid}", headers=AUTH).json()
    assert [t["title"] for t in path["topics"]] == ["Demand", "The multiplier", "IS-LM"]  # written topics only
    assert path["next"] == ls.topics[0]["public_id"] and all(t["lesson"] is None for t in path["topics"])
    no_notes = ls.api.post(f"/v1/topics/{ls.topics[2]['public_id']}/lesson", headers=AUTH)
    assert no_notes.status_code == 409

    ls.api.post(f"/v1/topics/{ls.topics[0]['public_id']}/lesson", headers=AUTH)
    build(ls)
    lesson = ls.store.for_topic(ls.topics[0]["id"])
    asyncio.run(ls.store.finish(lesson["public_id"], None))
    path = ls.api.get(f"/v1/lessons?course={ls.cid}", headers=AUTH).json()
    assert path["next"] == ls.topics[1]["public_id"]
    assert path["topics"][0]["lesson"]["finished_at"] and path["topics"][1]["lesson"]["status"] == "building"

    # notes changed: a lesson not started is written again when asked for; a started one stays, marked stale
    build(ls)
    second = ls.store.for_topic(ls.topics[1]["id"])
    ls.nb.notebook.set_body(ls.topics[1]["id"], "The multiplier, rewritten.")
    ls.nb.notebook.set_body(ls.topics[0]["id"], "Demand, rewritten.")
    r = ls.api.post(f"/v1/topics/{ls.topics[1]['public_id']}/lesson", headers=AUTH).json()
    assert r["id"] == second["public_id"] and r["status"] == "building"
    r = ls.api.post(f"/v1/topics/{ls.topics[0]['public_id']}/lesson", headers=AUTH).json()
    assert r["status"] == "ready" and r["stale"] and r["finished_at"]
    r = ls.api.post(f"/v1/topics/{ls.topics[0]['public_id']}/lesson", json={"restart": True}, headers=AUTH).json()
    assert r["at"] == 0 and r["finished_at"] is None and r["stale"]
    r = ls.api.post(f"/v1/topics/{ls.topics[0]['public_id']}/lesson", json={"again": True}, headers=AUTH)
    assert r.status_code == 202 and r.json()["status"] == "building"


def test_a_lesson_that_cant_be_read_fails_and_can_be_asked_again(ls):
    ls.ask.answers[BUILD_PROMPT] = ["Sorry, no.", LESSON]
    ls.api.post(f"/v1/topics/{ls.topics[3]['public_id']}/lesson", headers=AUTH)
    build(ls)
    r = ls.api.get(f"/v1/topics/{ls.topics[3]['public_id']}/lesson", headers=AUTH).json()
    assert r["status"] == "failed" and r["error"]
    r = ls.api.post(f"/v1/topics/{ls.topics[3]['public_id']}/lesson", headers=AUTH)
    assert r.status_code == 202
    build(ls)
    assert ls.store.for_topic(ls.topics[3]["id"])["status"] == "ready"


def test_known_topics_are_skipped_on_the_path(ls):
    ls.store.mastery = lambda cid: [{"id": ls.topics[0]["public_id"], "known": 4, "learning": 0, "unseen": 0}]
    assert ls.api.get(f"/v1/lessons?course={ls.cid}", headers=AUTH).json()["next"] == ls.topics[1]["public_id"]
