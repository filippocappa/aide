from datetime import timedelta

from aide.channels.discord_bot import split_message
from aide.db import Database


def test_wal_mode_on_disk(tmp_path):
    db = Database(tmp_path / "sub" / "aide.db")
    assert db.conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    db.close()


def test_idle_conversation_rolls_over():
    db = Database(":memory:")
    first = db.current_conversation("discord", timedelta(hours=6))
    assert db.current_conversation("discord", timedelta(hours=6)) == first
    assert db.current_conversation("discord", timedelta(0)) != first


def test_split_message_respects_limit():
    text = ("word " * 30 + "\n\n") * 40
    chunks = split_message(text, limit=200)
    assert all(len(c) <= 200 for c in chunks)
    assert "".join(chunks).replace("\n", "").replace(" ", "") == text.replace("\n", "").replace(" ", "")


def test_split_message_hard_cuts_long_lines():
    assert split_message("x" * 450, limit=200) == ["x" * 200, "x" * 200, "x" * 50]


def test_migrates_pre_think_database(tmp_path):
    import sqlite3
    path = tmp_path / "old.db"
    old = sqlite3.connect(path)
    old.execute("CREATE TABLE conversations (id INTEGER PRIMARY KEY, channel TEXT NOT NULL, "
                "started_at TEXT NOT NULL, last_active_at TEXT NOT NULL)")
    old.close()
    db = Database(path)
    conv = db.new_conversation("discord")
    db.set_conversation_model(conv, "smart")
    assert db.conversation_model(conv) == "smart"
