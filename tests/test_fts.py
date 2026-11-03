import sqlite3

from aide import fts
from aide.fts import match_queries


def test_a_question_becomes_all_its_telling_words_then_any_long_ones_as_prefixes():
    assert match_queries("What is the crowding out effect?") == ['"crowding"* "effect"*', '"crowding"* OR "effect"*']
    assert match_queries("Cos'è il moltiplicatore della spesa") == \
        ['"cos" "moltiplicatore"* "spesa"*', '"cos" OR "moltiplicatore"* OR "spesa"*']
    assert match_queries("multiplier MULTIPLIER, multiplier") == ['"multiplier"*']
    assert match_queries("slides and multipliers, class")[1] == '"slide"* OR "multiplier"* OR "class"*'


def test_only_stopwords_need_them_all_operators_stay_words_and_no_words_is_nothing():
    assert match_queries("what is it") == ['"what"* "is" "it"']
    assert match_queries("IS AND LM") == ['"lm"']
    assert match_queries("NEAR") == ['"near"*']
    assert match_queries("what's the multiplier? l'IS") == ['"multiplier"*']  # single letters say nothing
    assert match_queries("") == [] and match_queries("?! …") == []


def test_rows_with_every_word_come_before_rows_with_some_each_once():
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    conn.execute("CREATE VIRTUAL TABLE t USING fts5(text)")
    conn.executemany("INSERT INTO t (rowid, text) VALUES (?, ?)", [
        (1, "fiscal policy, fiscal policy, fiscal policy"),  # one word many times
        (2, "crowding out: a fiscal expansion raises the interest rate"),  # both words, once each
        (3, "the rate"),
        (4, "nothing here")])
    sql = "SELECT rowid AS id, text FROM t WHERE t MATCH ? ORDER BY rank LIMIT ?"

    def ids(text, limit=8):
        return [r["id"] for r in fts.search(conn, sql, text, (), limit, lambda r: r["id"])]
    assert ids("what's the fiscal rate?")[0] == 2 and sorted(ids("what's the fiscal rate?")) == [1, 2, 3]
    assert ids("fiscal rate", limit=1) == [2]  # enough with every word: no second query
    assert sorted(ids("the")) == [2, 3] and ids("zebra") == []
