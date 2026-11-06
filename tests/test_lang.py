import pytest

from aide.lang import language


@pytest.mark.parametrize("text,lang", [
    ("How did I sleep last night?", "en"),  # none of the old list's words: a call answered it in Italian
    ("ok thanks, and the day after?", "en"),
    ("Read me my last email", "en"),
    ("Is there a pharmacy open near me?", "en"),
    ("Lock my phone for an hour, I need to focus", "en"),
    ("yes, do it", "en"),
    ("Ciao, che cosa ho domani?", "it"),
    ("Che cosa ho nel calendar oggi pomeriggio?", "it"),
    ("Allora sposta la corsa lunga a sabato mattina", "it"),
    ("Ho preso un altro caffè", "it"),
    ("Domani piove?", "it"),
    ("E in cosa ho speso di più?", "it"),
    ("no, lascia stare", "it"),
])
def test_a_short_question_gives_its_language_away(text, lang):
    assert language(text, "?") == lang


def test_a_letter_alone_keeps_the_language_before():
    assert language("B", "it") == "it"
