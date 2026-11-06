import pytest

from aide.agent import Agent
from aide.quiz import QuizStore
from aide.tools import ToolRegistry
from aide.tools.quiz import quiz_tools
from aide.voicequiz import VoiceQuiz, match_answer, spoken_reply
from test_api import FakeClient, call, done
from test_notebook import nb  # noqa: F401 (the fixture)
from test_quiz import notebook_with_questions
from test_study import ROME

OPTIONS = [{"letter": "A", "text": "More government spending"}, {"letter": "B", "text": "The money supply"},
           {"letter": "C", "text": "Lower taxes"}, {"letter": "D", "text": "A higher interest rate"}]


@pytest.mark.parametrize("said, letter", [
    ("B", "B"), ("b.", "B"), ("Bee", "B"), ("bi", "B"), ("la b", "B"), ("È la B", "B"), ("Lettera C", "C"),
    ("I think it's D", "D"), ("the answer is A", "A"), ("option two", "B"), ("the second one", "B"),
    ("La seconda", "B"), ("la terza", "C"), ("the last one", "D"), ("l'ultima", "D"), ("first", "A"),
    ("the money supply", "B"), ("money supply", "B"), ("lower taxes", "C"), ("lower taxis", "C"),
    ("B because the money supply moves LM", "B"), ("la C perché le tasse", "C"), ("E", None),
    ("I don't know", "blank"), ("Non lo so.", "blank"), ("boh", "blank"),
    ("what does LM mean?", None), ("can you repeat the question", None), ("wait", None), ("sì", None),
    ("B or C", None), ("", None), ("um", None),
])
def test_a_spoken_answer_is_matched_only_when_it_is_clear(said, letter):
    assert match_answer(OPTIONS, said) == letter


def test_the_reply_drops_the_hidden_answer_and_reads_the_next_question():
    out = ("Wrong: the answer is A. Why: G is part of demand. (0 of 1 right so far.)\n\n"
           "Question 2 of 3, The IS-LM model (multiple choice):\nWhat shifts LM up?\nA) one\nB) two\n"
           "[For you, not to say before they answer: the answer is B. Why: money.]")
    assert spoken_reply(out) == ("Wrong: the answer is A. Why: G is part of demand. (0 of 1 right so far.)\n\n"
                                 "Question 2 of 3, on The IS-LM model.\nWhat shifts LM up?\nA: one\nB: two")


def professor(nb, responses) -> Agent:
    quizzes = QuizStore(nb.notebook)
    agent = Agent(FakeClient(responses), nb.db, ToolRegistry(quiz_tools(quizzes, None, nb.study, nb.notebook, ROME)),
                  model="m", tz=ROME, delegate=False)
    agent.voice_quiz = VoiceQuiz(quizzes, nb.study)
    return agent


async def quiz_started(nb, agent) -> tuple[str, dict]:
    chat = nb.study.chat(nb.macro["id"])
    await agent.respond("app", "Quiz me", chat, voice=True)
    quiz = QuizStore(nb.notebook).open_chat(nb.macro["id"])
    return chat, quiz


async def test_a_spoken_answer_in_a_voice_quiz_needs_no_model_call(nb):
    notebook_with_questions(nb)
    agent = professor(nb, [call("quiz_me", course="macroeconomics", count=3, style="questions"), done("Question 1…")])
    chat, quiz = await quiz_started(nb, agent)
    first, second = quiz["questions"][:2]
    wrong = "ABCD".replace(first["key"], "")[0]

    streamed = []
    turn = await agent.respond("app", f"I think it's {wrong.lower()}", chat, voice=True,
                               on_text=lambda text, restart: streamed.append(text))
    assert agent.client.responses == []  # no model call: FakeClient had nothing left to give
    assert turn.reply.startswith(f"Wrong: the answer is {first['key']}.") and "Question 2 of 3, on " in turn.reply
    assert "[For you" not in turn.reply and f"the answer is {second['key']}" not in turn.reply.split("Question 2")[1]
    assert streamed == [turn.reply]
    assert QuizStore(nb.notebook).quiz(quiz["public_id"])["answers"] == {"1": wrong}

    # The next question's hidden answer is in the chat's history for the model, and the chat shows only the reply.
    history = nb.db.history(nb.db.app_conversation(chat)["id"])
    assert f"the answer is {second['key']}" in history[-2]["content"][0]["content"]
    shown = agent.visible_history("app", conversation=chat)
    assert [m["role"] for m in shown[-2:]] == ["user", "assistant"] and shown[-1]["text"] == turn.reply


async def test_anything_unclear_or_typed_goes_to_the_model(nb):
    notebook_with_questions(nb)
    agent = professor(nb, [call("quiz_me", course="macroeconomics", count=3, style="questions"), done("Question 1…"),
                           done("LM is the money market."), done("Recorded.")])
    chat, quiz = await quiz_started(nb, agent)
    assert (await agent.respond("app", "what does LM mean?", chat, voice=True)).reply == "LM is the money market."
    # The question before wasn't a quiz turn: a "B" now is the model's to read.
    assert (await agent.respond("app", "B", chat, voice=True)).reply == "Recorded."
    assert QuizStore(nb.notebook).quiz(quiz["public_id"])["answers"] == {}


async def test_a_typed_answer_still_goes_to_the_model(nb):
    notebook_with_questions(nb)
    agent = professor(nb, [call("quiz_me", course="macroeconomics", count=3, style="questions"), done("Question 1…"),
                           done("Right.")])
    chat, _ = await quiz_started(nb, agent)
    assert (await agent.respond("app", "B", chat)).reply == "Right."
    assert agent.client.responses == []
