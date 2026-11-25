"""Sharing cappa with app development (#83): Aide steps back on purpose when Roen (roenlabs: the Android emulator, Expo,
Metro, Gradle) needs the memory, before the kernel or earlyoom picks a victim.

What holds the host is a claim or a process seen running:
- A claim is a file in `CLAIMS` (one per claim, `<pid>.<n>.json`), written by `deploy/host-claim` around a command
  (`host-claim emulator -- emulator -avd Pixel`) and removed when it ends; one whose process is gone counts for
  nothing and is swept.
- Processes started without it are still seen (`DEV`, the patterns aide-status.py shows), up to `SCAN` s late.

While anything holds it, Aide (`HostWatcher`) lets the live call voice go (the models and Chatterbox, ~5 GB), takes
no new calls (the phone uses its turn-at-a-time voice), and holds back Whisper (a lecture stays queued, the app says
behind what); a call already going is finished first. Once stepped back it says so in `STATE` (`ready` lists the claims
it answered), which host-claim waits for (up to a minute, then it goes ahead anyway). When nothing has held it for
`QUIET` s, the voice is loaded again if Live calls are on.

Standard library only: deploy/aide-status.py and deploy/host-claim import it with the system python."""

import asyncio
import contextlib
import json
import logging
import os
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Awaitable, Callable

log = logging.getLogger(__name__)

STATE_DIR = Path(os.environ.get("AIDE_HOST_STATE") or Path.home() / ".local/state/aide-host")
CLAIMS = STATE_DIR / "claims"
STATE = STATE_DIR / "aide.json"  # Aide's side: what it stepped back for, and the claims it answered
TICK = 1.0  # claims are read this often (a directory listing)
SCAN = 5.0  # and the processes this often
QUIET = 120  # seconds with nothing holding the host before the voice comes back (Expo restarts often)

DEV = [  # what each is called in the app, and the command line that gives it away
    ("Android emulator", re.compile(r"qemu-system|Android/Sdk/emulator")),
    ("Expo", re.compile(r"expo start|expo run")),
    ("Metro", re.compile(r"metro")),
    ("Gradle", re.compile(r"GradleDaemon|KotlinCompileDaemon")),
]
# Never these: earlyoom's own command line names qemu-system, Aide's watchers name the patterns, and a Claude
# session's arguments can say anything ("metro" in a prompt).
NOT_DEV = re.compile(r"earlyoom|aide-budget|aide-status|host-claim")
NOT_DEV_NAMES = {"claude"}
NAMES = {"roenlabs": "Roen"}  # a project's folder → what it's called


def iso(t: float | None = None) -> str:
    return datetime.fromtimestamp(time.time() if t is None else t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def project(pid: int) -> str:
    """The folder a process works in: the first under ~/Developer (~/Developer/apps/aide is "aide"), else its name."""
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return "?"
    try:
        rest = Path(cwd).relative_to(Path.home() / "Developer").parts
    except ValueError:
        return Path(cwd).name or "/"
    if not rest:
        return "Developer"
    return rest[1] if rest[0] == "apps" and len(rest) > 1 else rest[0]


def name(who: str) -> str:
    return NAMES.get(who, who)


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# -- claims --


def claim(what: str, who: str, mb: int | None = None, pid: int | None = None) -> str:
    """Writes a claim and returns its id; it holds until `release(id)` or its process ends."""
    pid = pid or os.getpid()
    CLAIMS.mkdir(parents=True, exist_ok=True)
    n = 0
    while (CLAIMS / f"{pid}.{n}.json").exists():
        n += 1
    cid = f"{pid}.{n}"
    data = {"id": cid, "who": who, "what": what, "pid": pid, "since": iso()}
    if mb:
        data["mb"] = mb
    tmp = CLAIMS / f".{cid}.tmp"
    tmp.write_text(json.dumps(data))
    os.replace(tmp, CLAIMS / f"{cid}.json")
    return cid


def release(cid: str) -> None:
    with contextlib.suppress(FileNotFoundError):
        (CLAIMS / f"{cid}.json").unlink()


def claims() -> list[dict]:
    """The claims holding now, oldest first; ones whose process is gone are swept."""
    out = []
    try:
        files = list(CLAIMS.glob("*.json"))
    except OSError:
        return []
    for f in files:
        try:
            data = json.loads(f.read_text())
            pid = int(data["pid"])
        except (OSError, ValueError, KeyError, TypeError):
            continue  # half-written or gone meanwhile
        if alive(pid):
            out.append(data)
        else:
            with contextlib.suppress(OSError):
                f.unlink()
    return sorted(out, key=lambda c: (c.get("since", ""), c.get("id", "")))


# -- processes --


def dev_processes() -> list[dict]:
    """App development seen running for this user: [{"what": "Android emulator", "who": "roenlabs"}], one per kind."""
    uid = os.getuid()
    found: dict[str, str] = {}
    try:
        entries = list(os.scandir("/proc"))
    except OSError:  # not Linux
        return []
    for entry in entries:
        if not entry.name.isdigit():
            continue
        try:
            if entry.stat().st_uid != uid:
                continue
            comm = Path(entry.path, "comm").read_text().strip()
            cmd = Path(entry.path, "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
        except OSError:
            continue  # gone meanwhile
        if comm in NOT_DEV_NAMES or NOT_DEV.search(cmd):
            continue
        for label, pattern in DEV:
            if label not in found and pattern.search(cmd):
                found[label] = project(int(entry.name))
    return [{"what": label, "who": found[label]} for label, _ in DEV if label in found]


def describe(holders: list[dict]) -> str:
    """"Roen's Android emulator and Metro"."""
    by: dict[str, list[str]] = {}
    for h in holders:
        whats = by.setdefault(name(h["who"]), [])
        if h["what"] not in whats:
            whats.append(h["what"])
    parts = [f"{who}'s {_and(whats)}" if who not in ("?", "") else _and(whats) for who, whats in by.items()]
    return _and(parts)


def _and(items: list[str]) -> str:
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + " and " + items[-1] if items else ""


def read_state() -> dict | None:
    """Aide's side as it last wrote it, or None (not running, or nothing written)."""
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return None


# -- Aide's side --

_watcher: "HostWatcher | None" = None


class HostWatcher:
    """Follows what holds the host and makes Aide step back and come back.

    `step_back(why)` lets the memory go (the voice: it waits for a call to end itself), `come_back()` takes it again,
    `finishing()` says what Aide is still finishing before it can step back ("a live call"), or None."""

    def __init__(self, step_back: Callable[[str], Awaitable[None]] | None = None,
                 come_back: Callable[[], Awaitable[None]] | None = None,
                 finishing: Callable[[], str | None] | None = None, quiet: float = QUIET):
        self.step_back, self.come_back, self.finishing, self.quiet = step_back, come_back, finishing, quiet
        self.holders: list[dict] = []
        self.since: float | None = None  # held since
        self.stepped = False  # stepped back (the voice let go)
        self._quiet_since: float | None = None
        self._free = asyncio.Event()
        self._free.set()
        self._task: asyncio.Task | None = None
        self._dev: list[dict] = []
        self._scanned: float | None = None
        self.last = ""  # what last held it, said while the quiet period runs
        global _watcher
        _watcher = self

    @property
    def held(self) -> str | None:
        """What holds the host, said for the app ("Roen's Android emulator"), or None."""
        return describe(self.holders) if self.holders else None

    def look(self, now: float | None = None) -> None:
        """Reads the claims (and the processes every SCAN s) into `holders`; at the service's start too, before the
        voice is loaded."""
        now = time.monotonic() if now is None else now
        if self._scanned is None or now - self._scanned >= SCAN:
            self._dev = dev_processes()
            self._scanned = now
        explicit = [{"who": c.get("who") or "?", "what": c.get("what") or "something", "claim": c["id"]}
                    for c in claims()]
        seen = {h["what"] for h in explicit}
        self.holders = explicit + [d for d in self._dev if d["what"] not in seen]
        if self.holders:
            self.last = describe(self.holders)
            self._quiet_since = None
            if self.since is None:
                self.since = time.time()
                self._free.clear()
        elif self.since is not None and self._quiet_since is None:
            self._quiet_since = now

    async def tick(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        before = self.held
        self.look(now)
        if self.held != before and self.held:
            log.info("host: %s holds cappa; Aide steps back", self.held)
        if self.holders and not self.stepped and self._task is None:
            self._task = asyncio.create_task(self._step_back(self.held))
        if (not self.holders and self.since is not None and self._task is None
                and self._quiet_since is not None and now - self._quiet_since >= self.quiet):
            await self._come_back()
        self.write()

    async def _step_back(self, why: str) -> None:
        try:
            if self.step_back:
                await self.step_back(why)
            self.stepped = True
            log.info("host: stepped back for %s", why)
        except Exception:
            log.exception("host: stepping back failed")
            self.stepped = True  # said ready all the same: the claim shouldn't wait for a fault here
        finally:
            self._task = None

    async def _come_back(self) -> None:
        log.info("host: nothing has held cappa for %d s; Aide takes its memory back", self.quiet)
        self.since = self._quiet_since = None
        self.stepped = False
        self._free.set()
        if self.come_back:
            try:
                await self.come_back()
            except Exception:
                log.exception("host: coming back failed")

    def write(self) -> None:
        data = {"at": iso(), "held_by": self.holders, "since": iso(self.since) if self.since else None,
                "stepped_back": self.stepped,
                "finishing": self.finishing() if self.finishing and self.holders and not self.stepped else None,
                "ready": [h["claim"] for h in self.holders if h.get("claim")] if self.stepped else []}
        try:
            STATE_DIR.mkdir(parents=True, exist_ok=True)
            tmp = STATE.with_suffix(".tmp")
            tmp.write_text(json.dumps(data))
            tmp.chmod(0o644)
            os.replace(tmp, STATE)
        except OSError as e:
            log.warning("host: can't write %s: %s", STATE, e)

    async def wait_free(self) -> None:
        await self._free.wait()

    async def run(self) -> None:
        while True:
            try:
                await self.tick()
            except Exception:
                log.exception("host: a look failed")
            await asyncio.sleep(TICK)


def holder() -> str | None:
    """What Aide is stepping back for now, or None (no watcher, or nothing)."""
    if _watcher is None or _watcher.since is None:
        return None
    return _watcher.held or _watcher.last or None


async def until_free() -> None:
    """Before a big job (Whisper): waits while something holds the host and until Aide has come back."""
    if _watcher is not None and _watcher.since is not None:
        log.info("host: a transcription waits for %s", _watcher.held or "the host")
        await _watcher.wait_free()
