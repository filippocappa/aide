"""A spoken yes or no to a queued action, and a spoken goodbye, decided in code (#34), never by the voice model.

From OpenMausBot's live calls: hedges are stripped first ("okay, yes" is a yes); a yes must be the whole utterance
(a yes inside a longer sentence, or a bare "okay", is unclear and asked again); a no anywhere wins. English and
Italian, as the user speaks both."""

import re
import unicodedata

HEDGES = ("um", "uh", "er", "ehm", "hmm", "so", "well", "ok", "okay", "sure", "fine", "alright", "all right",
          "allora", "va bene", "dai", "beh", "mah", "ecco")
YES = ("yes", "yeah", "yep", "yup", "please", "go ahead", "do it", "go for it", "confirm", "confirmed", "please do",
       "absolutely", "of course", "correct", "that's right", "right", "si", "fallo", "vai", "procedi", "conferma",
       "confermo", "certo", "esatto", "giusto", "grazie", "thanks")
POLITE = ("please", "thanks", "grazie")  # a yes word only next to another
NO = re.compile(r"\b(?:no|nope|nah|don't|do not|dont|stop|cancel|never mind|nevermind|not now|wait|hold on|"
                r"annulla|lascia stare|lascia perdere|non farlo|non|aspetta|fermo|ferma|niente|nulla)\b")
BYE = ("bye", "goodbye", "bye bye", "hang up", "that's all", "thats all", "that's it", "thats it", "end the call",
       "we're done", "were done", "thanks bye", "thank you bye", "ciao", "ciao ciao", "basta cosi", "basta",
       "chiudi", "chiudi la chiamata", "a dopo", "grazie ciao", "ho finito", "e tutto", "abbiamo finito")


def plain(text: str) -> str:
    """Lower case, no accents or punctuation, one space between words ("Sì, fallo!" -> "si fallo")."""
    text = unicodedata.normalize("NFKD", text.lower().replace("’", "'"))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^\w' ]+", " ", text).split())


def _alternation(words) -> str:
    return "|".join(re.escape(w) for w in sorted(words, key=len, reverse=True))


_HEDGED = re.compile(rf"^(?:(?:{_alternation(HEDGES)})(?:\s+|$))*(?P<core>.*?)(?:\s+(?:{_alternation(HEDGES)}))*$")
_ALL_YES = re.compile(rf"^(?:(?:{_alternation(YES)})(?:\s+|$))+$")


def _strip_hedges(said: str) -> str:
    """Hedges off both ends ("okay, so, yes" -> "yes"); a hedge alone is nothing."""
    return _HEDGED.match(said)["core"].strip()


def spoken_consent(text: str) -> bool | None:
    """True for a clear yes, False for a no, None when it isn't clear (ask again)."""
    said = plain(text)
    if not said:
        return None
    if NO.search(said):
        return False
    core = _strip_hedges(said)
    # Every word a yes ("yeah, go ahead", "sì, fallo"), and not only "please" or "thanks".
    return True if core and _ALL_YES.match(core) and core not in POLITE else None


def spoken_goodbye(text: str) -> bool:
    """The whole utterance is a goodbye ("ok bye", "basta così, grazie"): the call ends."""
    core = _strip_hedges(plain(text))
    for polite in (" grazie", " thanks", " thank you"):
        core = core.removesuffix(polite)
    return core in BYE
