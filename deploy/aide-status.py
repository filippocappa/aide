#!/usr/bin/env python3
"""What's happening on cappa, for the app's status glyph (docs/API.md, "Host status").

Every 10 s: Aide's and the voice's service state, the Claude Code sessions of this user (the project each works in,
busy or idle), whatever else holds Aide's port 8787, what's running for app development (an Android emulator, Expo, Metro, Gradle: roenlabs) and the memory
left, written to ~/.local/state/aide-status/host.json. tailscaled serves that folder itself at /aide-status/, so the
app can read it while Aide is stopped, restarting or broken. Standard library only, run by the system python3, so a
venv being re-synced doesn't stop it. `--once` prints one reading and writes nothing.
Install: README.md, "Running as a service".
"""

import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

OUT = Path.home() / ".local/state/aide-status/host.json"
EVERY = 10
PORT = 8787  # Aide's API (tailscale serve's / proxies it)
# A Claude session using more than this share of a core (with what it runs) is busy; it stays busy for LINGER
# seconds after, so the wait for the model between two steps doesn't flicker.
BUSY_SHARE = 0.03
LINGER = 60
DEV = [  # what each is called in the app, and the command line that gives it away
    ("Android emulator", re.compile(r"qemu-system|Android/Sdk/emulator")),
    ("Expo", re.compile(r"expo start|expo run")),
    ("Metro", re.compile(r"metro")),
    ("Gradle", re.compile(r"GradleDaemon|KotlinCompileDaemon")),
]
# Never these: earlyoom's own command line names qemu-system, and so does Aide's budget watcher.
NOT_DEV = re.compile(r"earlyoom|aide-budget|aide-status")
TICK = os.sysconf("SC_CLK_TCK")
UID = os.getuid()
HOME = str(Path.home())


def processes() -> dict[int, dict]:
    """Every process: parent, name, command line, owner, CPU ticks so far."""
    out = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            stat = Path(entry.path, "stat").read_text()
            cmd = Path(entry.path, "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            uid = entry.stat().st_uid
        except OSError:
            continue  # gone meanwhile
        name = stat[stat.index("(") + 1:stat.rindex(")")]
        rest = stat[stat.rindex(")") + 2:].split()
        out[int(entry.name)] = {"ppid": int(rest[1]), "name": name, "cmd": cmd, "uid": uid,
                                "ticks": int(rest[11]) + int(rest[12])}
    return out


def tree_ticks(procs: dict[int, dict], root: int) -> int:
    """CPU ticks of a process and everything it started (a session running tests counts as busy)."""
    children: dict[int, list[int]] = {}
    for pid, p in procs.items():
        children.setdefault(p["ppid"], []).append(pid)
    total, todo = 0, [root]
    while todo:
        pid = todo.pop()
        total += procs[pid]["ticks"]
        todo.extend(children.get(pid, []))
    return total


def project(pid: int) -> str:
    """The folder a session works in: the first under ~/Developer (~/Developer/apps/aide is "aide"), else its name."""
    try:
        cwd = os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return "?"
    try:
        rest = Path(cwd).relative_to(Path(HOME, "Developer")).parts
    except ValueError:
        return Path(cwd).name or "/"
    if not rest:
        return "Developer"
    return rest[1] if rest[0] == "apps" and len(rest) > 1 else rest[0]


def service(unit: str) -> dict:
    """A user unit's state ("active", "activating", "inactive", "failed", …) and since when (UTC)."""
    try:
        text = subprocess.run(
            ["systemctl", "--user", "show", unit, "-p", "ActiveState",
             "-p", "StateChangeTimestampMonotonic"],
            capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {"state": "unknown"}
    props = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    out = {"state": props.get("ActiveState", "unknown")}
    mono = int(props.get("StateChangeTimestampMonotonic") or 0)
    if mono:
        ago = time.monotonic() - mono / 1e6
        out["since"] = iso(time.time() - ago)
    return out


def port_holder(procs: dict[int, dict], aide: int) -> dict | None:
    """Who listens on Aide's port when it isn't Aide (a test server left there keeps Aide from starting, and gets the
    apps' requests): the project it runs in and the script or program, e.g. {"project": "roenlabs",
    "command": "local_engine.py"}. Only this user's processes show their pid."""
    try:
        text = subprocess.run(["ss", "-ltnpH", f"sport = :{PORT}"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    if not text.strip():
        return None
    pids = [int(m) for m in re.findall(r"pid=(\d+)", text)]
    if aide and (aide in pids or any(is_child(procs, pid, aide) for pid in pids)):
        return None
    if not pids:
        return {"project": "?", "command": "another user's program"}
    pid = pids[0]
    args = procs.get(pid, {}).get("cmd", "").split()
    script = next((a for a in args[1:] if re.search(r"\.(py|js|ts|mjs)$", a)), args[0] if args else "?")
    return {"project": project(pid), "command": Path(script).name}


def is_child(procs: dict[int, dict], pid: int, ancestor: int) -> bool:
    while pid > 1 and pid in procs:
        if pid == ancestor:
            return True
        pid = procs[pid]["ppid"]
    return False


def main_pid(unit: str) -> int:
    try:
        out = subprocess.run(["systemctl", "--user", "show", unit, "-p", "MainPID", "--value"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return int(out or 0)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return 0


def memory() -> dict:
    info = {}
    for line in Path("/proc/meminfo").read_text().splitlines():
        key, value = line.split(":", 1)
        info[key] = int(value.split()[0])
    out = {"total_mb": info["MemTotal"] // 1024, "available_mb": info["MemAvailable"] // 1024}
    slice_max = Path(f"/sys/fs/cgroup/user.slice/user-{UID}.slice/user@{UID}.service/aide.slice/memory.max")
    try:
        raw = slice_max.read_text().strip()
        if raw.isdigit():
            out["aide_max_mb"] = int(raw) // 2**20
    except OSError:
        pass
    return out


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def reading(before: dict[int, tuple[float, int]], busy_until: dict[int, float]) -> dict:
    """One look. `before` holds each session's (time, ticks) from the last look, `busy_until` its linger."""
    now = time.time()
    procs = processes()
    sessions = []
    for pid, p in procs.items():
        if p["uid"] != UID or p["name"] != "claude":
            continue
        ticks = tree_ticks(procs, pid)
        if pid in before:
            then, old = before[pid]
            if (ticks - old) / TICK > BUSY_SHARE * max(now - then, 1):
                busy_until[pid] = now + LINGER
        before[pid] = (now, ticks)
        sessions.append({"project": project(pid), "busy": busy_until.get(pid, 0) > now})
    for pid in set(before) - {pid for pid, p in procs.items() if p["name"] == "claude"}:
        before.pop(pid, None)
        busy_until.pop(pid, None)
    dev = []
    for label, pattern in DEV:
        if any(p["uid"] == UID and pattern.search(p["cmd"]) and not NOT_DEV.search(p["cmd"]) for p in procs.values()):
            dev.append(label)
    sessions.sort(key=lambda s: (not s["busy"], s["project"]))
    out = {"at": iso(now), "aide": service("aide"), "voice": service("aide-voice"),
           "claude": sessions, "dev": dev, "memory": memory()}
    holder = port_holder(procs, main_pid("aide"))
    if holder:
        out["port"] = holder
    return out


def write(data: dict) -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, separators=(",", ":")))
    tmp.chmod(0o644)
    os.replace(tmp, OUT)


def main() -> None:
    before: dict[int, tuple[float, int]] = {}
    busy_until: dict[int, float] = {}
    if "--once" in sys.argv:
        reading(before, busy_until)
        time.sleep(3)
        print(json.dumps(reading(before, busy_until), indent=2))
        return
    while True:
        try:
            write(reading(before, busy_until))
        except Exception as error:  # a bad look is skipped, never the end of the watcher
            print(f"aide-status: {error!r}", file=sys.stderr, flush=True)
        time.sleep(EVERY)


if __name__ == "__main__":
    main()
