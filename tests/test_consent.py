import pytest

from aide.consent import spoken_consent, spoken_goodbye


@pytest.mark.parametrize("said, answer", [
    ("Yes", True), ("yes.", True), ("Yeah, go ahead", True), ("go ahead", True), ("Okay, yes", True),
    ("ok do it", True), ("Sì", True), ("sì, fallo", True), ("Vai", True), ("allora sì", True), ("procedi", True),
    ("conferma", True), ("certo che sì", None), ("certo", True), ("thanks", None), ("um, yes please", True),
    ("No", False), ("no thanks", False), ("don't", False), ("Cancel that", False), ("wait", False),
    ("annulla", False), ("No, lascia stare", False), ("non farlo", False), ("yes, no wait", False),
    ("okay", None), ("ok", None), ("va bene", None), ("sure", None), ("", None), ("um", None),
    ("yes but make it at eleven", None), ("what time was it?", None), ("si ma alle undici", None),
])
def test_only_a_whole_yes_is_a_yes_and_any_no_is_a_no(said, answer):
    assert spoken_consent(said) is answer


@pytest.mark.parametrize("said, bye", [
    ("Bye", True), ("ok bye", True), ("thanks, bye", True), ("hang up", True), ("that's all, thanks", True),
    ("Ciao!", True), ("basta così, grazie", True), ("chiudi", True), ("ho finito", True),
    ("say bye to Marco for me", False), ("ciao Marco come stai", False), ("what's next", False), ("", False),
])
def test_a_goodbye_is_the_whole_utterance(said, bye):
    assert spoken_goodbye(said) is bye
