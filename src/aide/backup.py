"""Nightly backup of data/ to ~/aide-backups. Run by deploy/aide-backup.timer; restore notes in README.md.

Each backup is one folder named by its local date. Databases are copied with SQLite's online backup
(safe while the service is writing) and checked with integrity_check. The Gmail refresh token lives
in .env, not the database, so its lines are copied too, readable by the owner only.
"""

import logging
import os
import re
import shutil
import sqlite3
import sys
from datetime import date, datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from dotenv import dotenv_values

log = logging.getLogger("aide.backup")

KEEP_DAILY = 14
KEEP_WEEKLY = 8
DATED = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SKIP_SUFFIXES = ("-wal", "-shm", "-journal")  # folded into the copy by the backup API


class BackupError(RuntimeError):
    pass


def copy_database(src: Path, dst: Path) -> None:
    """Online backup of one SQLite file, then integrity_check on the copy."""
    source = sqlite3.connect(src)  # read-write open: a read-only one can fail on a WAL file with no -shm
    target = sqlite3.connect(dst)
    try:
        source.backup(target)
        target.execute("PRAGMA journal_mode=DELETE")  # one self-contained file, no -wal next to it
    finally:
        target.close()
        source.close()
    check = sqlite3.connect(f"file:{dst}?mode=ro", uri=True)
    try:
        result = [r[0] for r in check.execute("PRAGMA integrity_check")]
    finally:
        check.close()
    if result != ["ok"]:
        raise BackupError(f"integrity_check failed on the copy of {src.name}: {'; '.join(result[:5])}")


def gmail_lines(env_file: Path) -> str:
    values = dotenv_values(env_file) if env_file.exists() else {}
    return "".join(f"{k}={v}\n" for k, v in values.items() if k.startswith("GMAIL_") and v)


def backup(data_dir: Path, dest_root: Path, env_file: Path, day: date) -> Path:
    """Write one backup folder for `day`, replacing an earlier one from the same day."""
    if not data_dir.is_dir():
        raise BackupError(f"no data folder at {data_dir}")
    dest_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(dest_root, 0o700)
    final = dest_root / day.isoformat()
    tmp = dest_root / f".{day.isoformat()}.tmp"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(mode=0o700)
    try:
        for path in sorted(data_dir.iterdir()):
            if not path.is_file() or path.name.endswith(SKIP_SUFFIXES):
                continue
            if path.suffix in (".db", ".sqlite", ".sqlite3"):
                copy_database(path, tmp / path.name)
            else:
                shutil.copy2(path, tmp / path.name)
        if token := gmail_lines(env_file):
            fd = os.open(tmp / "gmail.env", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(token)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    # Swap in only a complete, checked backup.
    shutil.rmtree(final, ignore_errors=True)
    tmp.rename(final)
    return final


def to_keep(days: list[date], daily: int = KEEP_DAILY, weekly: int = KEEP_WEEKLY) -> set[date]:
    """The newest `daily` backups, plus the newest backup of each of the newest `weekly` ISO weeks."""
    newest_first = sorted(days, reverse=True)
    keep = set(newest_first[:daily])
    weeks: dict[tuple[int, int], date] = {}
    for d in newest_first:
        weeks.setdefault(d.isocalendar()[:2], d)
    keep |= set(list(weeks.values())[:weekly])
    return keep


def prune(dest_root: Path) -> list[Path]:
    folders = {date.fromisoformat(p.name): p for p in dest_root.iterdir() if p.is_dir() and DATED.match(p.name)}
    keep = to_keep(list(folders))
    removed = [p for d, p in sorted(folders.items()) if d not in keep]
    for p in removed:
        shutil.rmtree(p)
    return removed


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    env_file = Path(".env").resolve()
    for key, value in dotenv_values(env_file).items() if env_file.exists() else ():
        os.environ.setdefault(key, value or "")
    data_dir = Path(os.environ.get("AIDE_DB_PATH") or "./data/aide.db").resolve().parent
    dest_root = Path(os.environ.get("AIDE_BACKUP_DIR") or "~/aide-backups").expanduser()
    try:
        folder = backup(data_dir, dest_root, env_file, datetime.now(ZoneInfo(os.environ.get("AIDE_TIMEZONE") or "UTC")).date())
        removed = prune(dest_root)
    except Exception as e:
        log.error("backup FAILED: %s", e, exc_info=not isinstance(e, BackupError))
        sys.exit(1)
    files = ", ".join(f"{p.name} {p.stat().st_size / 1024:.0f} kB" for p in sorted(folder.iterdir()))
    kept = sum(1 for p in dest_root.iterdir() if p.is_dir() and DATED.match(p.name))
    log.info("backup ok: %s (%s); integrity_check ok; %d kept, %d pruned", folder, files, kept, len(removed))


if __name__ == "__main__":
    main()
