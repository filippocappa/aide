"""Voice quiz answers marked with no model call (#34). In a course chat with a chat quiz open, a spoken answer to a
multiple-choice question ("B", "the second one", "la seconda", the option's own words, "I don't know") is matched in
code and answered through quiz_answer, as the model would have; anything unclear goes to the model as before.
Flashcards always go to the model: their answers need judging."""

import re
import unicodedata
from difflib import SequenceMatcher

from .quiz import QuizStore
from .study import StudyStore

# How a letter comes back from the transcriber, alone: "B", "bee", "bi" (Italian), "ci", "di".
LETTERS = {
    "a": "A", "ay": "A", "ei": "A",
    "b": "B", "be": "B", "bee": "B", "bi": "B",
    "c": "C", "see": "C", "sea": "C", "ci": "C",  # not "si": that's an Italian yes
    "d": "D", "dee": "D", "di": "D",
    "e": "E", "ee": "E",
    "f": "F", "ef": "F", "eff": "F", "effe": "F",
}
ORDINALS = {
    "first": 0, "one": 0, "1": 0, "primo": 0, "prima": 0, "uno": 0,
    "second": 1, "two": 1, "2": 1, "secondo": 1, "seconda": 1, "due": 1,
    "third": 2, "three": 2, "3": 2, "terzo": 2, "terza": 2, "tre": 2,
    "fourth": 3, "four": 3, "4": 3, "quarto": 3, "quarta": 3, "quattro": 3,
    "fifth": 4, "five": 4, "5": 4, "quinto": 4, "quinta": 4, "cinque": 4,
    "last": -1, "ultimo": -1, "ultima": -1,
}
DONT_KNOW = {"i don't know", "i dont know", "don't know", "dont know", "no idea", "i have no idea", "pass", "skip",
             "skip it", "non lo so", "non so", "boh", "passo", "salta", "non ne ho idea", "blank"}
# Words around the answer that say nothing: "I think it's B", "la risposta è la b", "option two". Matched on plain
# text (_plain: no accents), and only when more than one word was said: "E" alone is the letter, not "è".
FILLER = re.compile(
    r"\b(?:um+|uh+|er+|ehm+|hmm+|so|well|okay|ok|i think|i'd say|i guess|maybe|probably|it's|it is|its|"
    r"the answer is|my answer is|answer|i choose|i pick|i'll go with|go with|letter|option|number|the|one|"
    r"allora|penso|credo|direi|forse|la risposta e|risposta|scelgo|opzione|lettera|numero|e|la|il|lo|quella|"
    r"quello)\b")
BECAUSE = re.compile(r"^(?P<head>.+?)\s+(?:because|since|cause|'cause|perché|perche|visto che|dato che)\b.*$")


def _plain(text: str) -> str:
    """Lower case, accents and punctuation off ("È la B." -> "e la b"), one space between words."""
    text = unicodedata.normalize("NFKD", text.lower().replace("’", "'"))
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"\b[ld]'", "", text)  # "l'opzione", "dell'" -> the word
    return " ".join(re.sub(r"[^\w' ]+", " ", text).split())


def match_answer(options: list[dict], spoken: str) -> str | None:
    """The letter a spoken answer picks among `options` ({letter, text}), "blank" for "I don't know", else None.

    Only a clear answer counts: the whole utterance is a letter, an ordinal or an option's words (a reason after
    "because" or "perché" is let through). Anything else (a question, "wait", "repeat that") is None, and the model
    takes the turn."""
    letters = [o["letter"].upper() for o in options]
    said = _plain(spoken)
    if not said:
        return None
    if said in {_plain(d) for d in DONT_KNOW}:
        return "blank"
    if m := BECAUSE.match(said):
        said = m["head"]
    # The option's own words first: "the money supply" shouldn't be cut to "money supply" by the fillers.
    if (picked := _by_text(options, said)) is not None:
        return picked
    words = said.split()
    core = " ".join(FILLER.sub(" ", f" {said} ").split()) if len(words) > 1 else said
    if len(core.split()) == 1:
        if (letter := LETTERS.get(core)) and letter in letters:
            return letter
        if (n := ORDINALS.get(core)) is not None and -len(letters) <= n < len(letters):
            return letters[n]
    return _by_text(options, core) if core and core != said else None


def _by_text(options: list[dict], said: str) -> str | None:
    """The option whose words were said: the same words, or close (a transcription slip) with no other close."""
    if len(said) < 3:
        return None
    scores = sorted(((SequenceMatcher(None, said, _plain(o["text"])).ratio(), o["letter"].upper())
                     for o in options), reverse=True)
    best, letter = scores[0]
    second = scores[1][0] if len(scores) > 1 else 0.0
    return letter if best >= 0.85 and best - second >= 0.15 else None


class VoiceQuiz:
    """Finds the quiz a course chat has open and matches a spoken answer to its question."""

    def __init__(self, quizzes: QuizStore, study: StudyStore):
        self.quizzes = quizzes
        self.study = study

    def match(self, conversation: str | None, spoken: str) -> tuple[str, str] | None:
        """(quiz id, answer for quiz_answer) when the chat's open quiz waits on a multiple-choice question and the
        words are a clear answer to it; None otherwise."""
        if conversation is None or (course := self.study.chat_course(conversation)) is None:
            return None
        if (quiz := self.quizzes.open_chat(course)) is None or (n := self.quizzes.current(quiz)) is None:
            return None
        q = quiz["questions"][n - 1]
        if q.get("type") == "card" or not q.get("options"):
            return None
        answer = match_answer(q["options"], spoken)
        return (quiz["public_id"], answer) if answer else None


def spoken_reply(result: str) -> str:
    """quiz_answer's result as the reply to read aloud: the hidden answer and the note for the model taken out, the
    next question said as a sentence ("Question 4 of 10, on The IS-LM model.") with its options."""
    result = re.sub(r"\n?\[For you, not to say before they answer:[^\]]*\]", "", result)
    result = result.replace(" Tell the user, and offer to go through what they missed.",
                            " Want to go through what you missed?")
    result = re.sub(r"^(Question \d+ of \d+), (.+?) \((?:multiple choice|a flashcard: they answer in their own "
                    r"words)\):$", r"\1, on \2.", result, flags=re.M)
    result = re.sub(r"^([A-F])\) (.+)$", r"\1: \2", result, flags=re.M)
    return result.strip()
