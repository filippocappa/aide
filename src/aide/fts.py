"""Searching an SQLite FTS5 table with a question: the rows with all its words first, then those with any.

A page needn't have every word ("what is the crowding out effect" would need "what", "is" and "the"): the words
that say nothing are dropped, the pages with all the rest come first, then the pages with some of them, each group
best first by FTS5's rank (BM25).
"""

import re
import sqlite3
from collections.abc import Callable, Hashable

_WORD = re.compile(r"\w+")
PREFIX_FROM = 4  # words this long also match longer ones: multiplier finds multipliers

# Words that say nothing about what's being looked for, English and Italian.
STOPWORDS = set("""
a an the is are was were be been am i im me my you your we our it its this that these those there here
he she him her his they them their one ones someone something anything
of to in on at for with and or by as from into about over than then so if not no do does did done
out up off down also just only very more most much many some any all each other
what which who whom whose when where why how can could should would will shall may might must
has have had tell say said explain show find look give me us ll re ve dont doesnt isnt
il lo la i gli le un uno una di da del dello della dei degli delle al allo alla ai agli alle dal nel nella
sul sulla che chi cosa come dove quando perché perche quale quali e ed o non si mi ti ci è sono era per con tra fra
""".split())


def _term(word: str) -> str:
    """A word quoted, so AND, OR and NEAR stay words; a long one as a prefix, a plural's s dropped first
    (multipliers finds multiplier)."""
    if len(word) > PREFIX_FROM and word.endswith("s") and not word.endswith("ss"):
        word = word[:-1]
    return f'"{word}"*' if len(word) >= PREFIX_FROM else f'"{word}"'


def match_queries(text: str) -> list[str]:
    """FTS5 MATCH expressions to try in turn: every word of `text` that says something, then any of them. When
    none says anything, just every word. Empty when there are no words."""
    words = list(dict.fromkeys(w.casefold() for w in _WORD.findall(text)))
    telling = [w for w in words if len(w) > 1 and w not in STOPWORDS]  # single letters: what's, l'IS
    if len(telling) < 2:
        return [" ".join(map(_term, telling or words))] if words else []
    return [" ".join(map(_term, telling)), " OR ".join(map(_term, telling))]


def search(conn: sqlite3.Connection, sql: str, text: str, params: tuple, limit: int,
           key: Callable[[sqlite3.Row], Hashable]) -> list[dict]:
    """Rows for `text`, the ones with all its words first: `sql` takes the MATCH, then `params`, then the limit,
    and orders by rank; `key` tells rows apart, so a row found by both queries comes once."""
    found: dict[Hashable, dict] = {}
    for match in match_queries(text):
        for row in conn.execute(sql, (match, *params, limit)).fetchall():
            found.setdefault(key(row), dict(row))
        if len(found) >= limit:
            break
    return list(found.values())[:limit]
