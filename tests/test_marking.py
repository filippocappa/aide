"""Marking a written study answer: the decision model alone when it's sure it's right, else the fast model's mark
and feedback, with the decision model's mark when the fast model fails."""

import asyncio

import httpx
import pytest

from aide.decide import Decider, Decision
from aide.quiz import mark

Q = {"text": "Define excess sensitivity.", "model_answer": "Consumption follows anticipated income, against the PIH.",
     "rubric": None, "points": 2.0}


class FakeDecider:
    def __init__(self, decision=None, error=None, delay=0.0):
        self.decision, self.error, self.delay, self.asked = decision, error, delay, []

    async def choose(self, criteria, instructions, state, name="answer", purpose=None):
        self.asked.append((criteria, state, name))
        await asyncio.sleep(self.delay)
        if self.error:
            raise self.error
        return self.decision


def fast(answer=None, error=None, delay=0.0):
    calls = []

    async def ask(system, content, tokens):
        calls.append(content)
        await asyncio.sleep(delay)
        if error:
            raise error
        return answer
    ask.calls = calls
    return ask


def run(coro):
    return asyncio.run(coro)


def test_a_sure_right_answer_is_marked_by_the_decision_model_alone():
    decider = FakeDecider(Decision("right", 0.93))
    ask = fast('{"points": 0.5, "feedback": "slow"}', delay=5)  # never waited for
    assert run(asyncio.wait_for(mark(ask, Q, {"text": "C reacts to income it saw coming"}, decider=decider), 1)) \
        == (2.0, None)
    ((criteria, state, name),) = decider.asked
    assert set(criteria) == {"right", "half", "wrong"} and name == "mark"
    assert state["student_answer"] == "C reacts to income it saw coming" and state["expected_answer"] == Q["model_answer"]


@pytest.mark.parametrize("decision", [Decision("half", 0.9), Decision("wrong", 0.99), Decision("right", 0.6), None])
def test_otherwise_the_fast_models_mark_and_feedback(decision):
    ask = fast('{"points": 0.5, "feedback": "You left out the PIH."}')
    assert run(mark(ask, Q, {"text": "it follows income"}, decider=FakeDecider(decision))) \
        == (1.0, "You left out the PIH.")


def test_when_the_fast_model_fails_the_decision_models_mark_stands():
    ask = fast(error=RuntimeError("cut off"))
    assert run(mark(ask, Q, {"text": "no idea"}, decider=FakeDecider(Decision("wrong", 0.7)))) == (0.0, None)
    assert run(mark(ask, Q, {"text": "half"}, decider=FakeDecider(Decision("half", 0.55)))) == (1.0, None)


def test_when_both_fail_the_mark_fails():
    with pytest.raises(RuntimeError):
        run(mark(fast(error=RuntimeError("502")), Q, {"text": "x"}, decider=FakeDecider(error=RuntimeError("alpha"))))


def test_a_slow_decision_model_isnt_waited_for(monkeypatch):
    monkeypatch.setattr("aide.quiz.DECIDE_WAIT", 0.05)
    ask = fast('{"points": 1, "feedback": "Right."}')
    assert run(mark(ask, Q, {"text": "x"}, decider=FakeDecider(Decision("right", 1.0), delay=2))) == (2.0, "Right.")


def test_photos_and_no_decider_go_to_the_fast_model_only():
    decider = FakeDecider(Decision("right", 1.0))
    ask = fast('{"points": 0, "feedback": "Not quite."}')
    assert run(mark(ask, Q, {"text": "", "photos": ["p_0123456789abcdef"]}, decider=decider)) == (0.0, "Not quite.")
    assert run(mark(ask, Q, {"text": "x"})) == (0.0, "Not quite.")
    assert decider.asked == []


def test_the_decider_reads_the_endpoints_answer(monkeypatch):
    from aide import usage
    spent = []
    monkeypatch.setattr(usage, "record", lambda engine, model, **kw: spent.append((model, kw["purpose"], kw["cost"])))
    answers = [{"answers": {"mark": {"type": "choice", "choice": "Half", "probabilities": {"Half": 0.7, "right": 0.3}}},
                "usage": {"input_tokens": 300, "output_tokens": 20, "cost": 1e-05}},
               {"answers": {"mark": {"type": "refusal"}}},
               {"answers": {"mark": {"type": "choice", "choice": "maybe", "probabilities": {"maybe": 1}}}}]
    sent = []

    def handle(request):
        sent.append(request)
        return httpx.Response(200, json=answers.pop(0))
    decider = Decider("k", http=httpx.AsyncClient(transport=httpx.MockTransport(handle)))
    criteria = {"right": "…", "half": "…", "wrong": "…"}
    assert run(decider.choose(criteria, "Mark it.", {"a": 1}, name="mark", purpose="mark")) == Decision("half", 0.7)
    assert run(decider.choose(criteria, "Mark it.", {"a": 1}, name="mark")) is None
    assert run(decider.choose(criteria, "Mark it.", {"a": 1}, name="mark")) is None
    assert str(sent[0].url) == "https://openrouter.ai/api/alpha/decisions"
    assert sent[0].headers["authorization"] == "Bearer k"
    assert spent[0] == ("typesafe/jev-1.13", "mark", 1e-05)
