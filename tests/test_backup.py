import os
import sqlite3
import stat
from datetime import date, timedelta

import pytest

from aide.backup import BackupError, backup, prune, to_keep
from aide.db import Database


@pytest.fixture
def live(tmp_path):
    """A WAL database with writes still in the -wal file, as when the service is running."""
    data = tmp_path / "data"
    db = Database(data / "aide.db")
    db.add_memory("Vegetarian")
    env = tmp_path / ".env"
    env.write_text("DISCORD_TOKEN=nope\nGMAIL_CLIENT_ID=cid\nGMAIL_REFRESH_TOKEN=rt\nGMAIL_CLIENT_SECRET=\n")
    yield data, env
    db.close()


def test_backup_copies_uncheckpointed_writes_and_the_gmail_token(live, tmp_path):
    data, env = live
    assert (data / "aide.db-wal").stat().st_size > 0
    folder = backup(data, tmp_path / "backups", env, date(2026, 10, 18))
    assert sorted(p.name for p in folder.iterdir()) == ["aide.db", "gmail.env"]
    copy = sqlite3.connect(folder / "aide.db")
    assert copy.execute("SELECT text FROM memory").fetchall() == [("Vegetarian",)]
    assert copy.execute("PRAGMA journal_mode").fetchone()[0] == "delete"
    copy.close()
    token = folder / "gmail.env"
    assert token.read_text() == "GMAIL_CLIENT_ID=cid\nGMAIL_REFRESH_TOKEN=rt\n"  # nothing else from .env
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert stat.S_IMODE((tmp_path / "backups").stat().st_mode) == 0o700


def test_same_day_backup_replaces_the_earlier_one(live, tmp_path):
    data, env = live
    backup(data, tmp_path / "b", env, date(2026, 10, 18))
    (data / "notes.txt").write_text("x")
    folder = backup(data, tmp_path / "b", env, date(2026, 10, 18))
    assert (folder / "notes.txt").exists()
    assert [p.name for p in (tmp_path / "b").iterdir()] == ["2026-10-18"]


def test_corrupt_database_fails_and_leaves_no_folder(tmp_path):
    data = tmp_path / "data"
    data.mkdir()
    (data / "aide.db").write_bytes(b"not a database at all" * 100)
    with pytest.raises((BackupError, sqlite3.DatabaseError)):
        backup(data, tmp_path / "b", tmp_path / ".env", date(2026, 10, 18))
    assert list((tmp_path / "b").iterdir()) == []


def test_keeps_14_daily_and_8_weekly():
    days = [date(2026, 10, 18) - timedelta(days=i) for i in range(120)]
    keep = to_keep(days)
    assert set(days[:14]) <= keep
    weekly = sorted(keep - set(days[:14]), reverse=True)
    # 14 daily backups are exactly 2 ISO weeks (Mon 5 Oct to Sun 18 Oct); 6 more Sundays make 8 weeks.
    assert weekly == [date(2026, 10, 4) - timedelta(weeks=i) for i in range(6)]
    assert len(keep) == 20


def test_prune_removes_only_dated_folders_outside_the_policy(tmp_path):
    for i in range(30):
        (tmp_path / (date(2026, 10, 18) - timedelta(days=i)).isoformat()).mkdir()
    (tmp_path / "manual-copy").mkdir()
    removed = prune(tmp_path)
    assert len(removed) == 30 - len(to_keep([date(2026, 10, 18) - timedelta(days=i) for i in range(30)]))
    assert (tmp_path / "manual-copy").exists()
    assert os.path.exists(tmp_path / "2026-10-18")
