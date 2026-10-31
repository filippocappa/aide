"""Moodle (UniTo's e-learning, AIDE_MOODLE_URL): the user's courses and their PDFs, synced into the study files
(material.py). The contract is docs/API.md, "Moodle".

Logging in: the university's login is single sign-on, so the server never sees a password. The app opens Moodle's
mobile launch page (the one the official Moodle app uses) in a browser sheet. After the user logs in there, Moodle
redirects to moodlemobile://token=…, carrying a web-service token signed with a one-time passport this server made.
The app hands that address over, the server checks the signature and keeps the token in .env (MOODLE_TOKEN).

Syncing: every 4 hours, and on demand. For each current Moodle course matched to an Aide course, the PDFs in its
sections are downloaded, only new or changed ones. A file the user deleted in Aide stays deleted. A few new files
close to a lecture become its slides, and its notes are written again with them. The course page's own text
(section summaries, labels, the announcement and textbook forums) is kept too, for the notebook's Introduction, and
new files go to the notebook (notebook.py), which proposes what to add from them. When a course's page or files
change, its dates (exams, mid-terms, sign-up deadlines) are read again.
"""

import asyncio
import base64
import hashlib
import hmac
import html
import json
import logging
import re
import secrets
import time
from collections.abc import Callable
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx

from .db import utcnow
from .material import MAX_FILE, SLIDES_PER_LECTURE, SLIDES_WINDOW, PdfError
from .study import StudyStore

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS moodle_courses (
    moodle_id INTEGER PRIMARY KEY,
    name      TEXT NOT NULL,
    short     TEXT NOT NULL DEFAULT '',
    course_id INTEGER REFERENCES courses(id),  -- the Aide course its files go to; NULL: not synced
    mapped    TEXT,  -- who matched it: 'auto', or 'user' (whose choice, NULL too, is kept)
    starts    INTEGER NOT NULL DEFAULT 0,  -- epoch seconds, 0 when Moodle has none
    ends      INTEGER NOT NULL DEFAULT 0,
    seen      INTEGER NOT NULL DEFAULT 1,  -- still in the user's Moodle courses
    text      TEXT NOT NULL DEFAULT ''  -- the course page's text: sections, labels, notices (for the notebook)
);
CREATE TABLE IF NOT EXISTS moodle_files (
    key     TEXT PRIMARY KEY,  -- moodle course/module/path/name
    time    INTEGER NOT NULL,  -- its timemodified when it was downloaded
    file_id TEXT  -- the study file (f_…); gone means the user deleted it
);
CREATE TABLE IF NOT EXISTS moodle_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""

SERVICE = "moodle_mobile_app"
SCHEME = "moodlemobile"
EVERY = timedelta(hours=4)
PASSPORT_TTL = 15 * 60  # seconds to finish logging in
MARGIN = timedelta(days=30)  # a course is current from a month before it starts to a month after it ends
COURSE_TEXT = 40_000  # characters of a course page's text kept
FORUM_POSTS = 8  # newest discussions read per forum
FORUM_POST = 2000  # characters of each
ANNOUNCE = 178  # characters of the push saying which files came
ANNOUNCE_FILES = 20  # file ids it carries, for the app to list
_FORUMS = re.compile(r"announce|annunc|avvis|news|notizi|textbook|book|libr|testi|exam|esam|mid-?term|appell|"
                     r"registration|iscrizion|info|aul[ae]\b|rooms?\b|calendar|date", re.I)


class MoodleError(Exception):
    pass


class LoginNeeded(MoodleError):
    """The token is missing, expired or revoked."""


class MoodleClient:
    def __init__(self, site: str, token: str, transport: httpx.AsyncBaseTransport | None = None):
        self.site = site.rstrip("/")
        self.token = token
        self.http = httpx.AsyncClient(timeout=120, transport=transport, follow_redirects=True)

    async def close(self) -> None:
        await self.http.aclose()

    async def call(self, function: str, **params) -> dict | list:
        try:
            r = await self.http.post(f"{self.site}/webservice/rest/server.php", data={
                "wstoken": self.token, "wsfunction": function, "moodlewsrestformat": "json", **params})
        except httpx.HTTPError as e:  # never the URL or the body: they carry the token
            raise MoodleError(f"Moodle didn't answer ({type(e).__name__})") from None
        if r.status_code != 200:
            raise MoodleError(f"Moodle answered {r.status_code}")
        try:
            data = r.json()
        except ValueError:
            raise MoodleError("Moodle sent something that isn't JSON") from None
        if isinstance(data, dict) and "exception" in data:
            if data.get("errorcode") == "invalidtoken":
                raise LoginNeeded("the Moodle login has expired")
            raise MoodleError(f"Moodle said: {data.get('message') or data.get('errorcode')}")
        return data

    async def download(self, url: str, dest: Path) -> int:
        """A file from Moodle, streamed to `dest`. Its size; MoodleError if it's not a file."""
        size = 0
        try:
            async with self.http.stream("GET", url + ("&" if "?" in url else "?") + "token=" + self.token) as r:
                kind = r.headers.get("content-type", "")
                if r.status_code != 200 or kind.startswith(("application/json", "text/html")):
                    body = (await r.aread())[:2000]
                    if b"invalidtoken" in body:
                        raise LoginNeeded("the Moodle login has expired")
                    raise MoodleError(f"Moodle didn't send the file ({r.status_code})")
                with dest.open("wb") as out:
                    async for chunk in r.aiter_bytes():
                        size += len(chunk)
                        if size > MAX_FILE:
                            raise MoodleError("the file is too big")
                        out.write(chunk)
        except httpx.HTTPError as e:
            raise MoodleError(f"the download failed ({type(e).__name__})") from None
        return size


def launch_url(site: str, passport: str) -> str:
    return (f"{site.rstrip('/')}/admin/tool/mobile/launch.php?service={SERVICE}&passport={passport}"
            f"&urlscheme={SCHEME}")


def token_from(callback: str, site: str, passport: str) -> str:
    """The token in Moodle's moodlemobile://token=… address, after checking it was signed for this passport.
    ValueError if it doesn't belong to this login."""
    _, sep, data = callback.partition("token=")
    if not callback.startswith(f"{SCHEME}://") or not sep:
        raise ValueError("that isn't the address Moodle sends back after logging in")
    try:
        parts = base64.b64decode(data.strip().rstrip("/") + "==").decode().split(":::")
    except ValueError:
        raise ValueError("the address Moodle sent back can't be read") from None
    want = hashlib.md5((site.rstrip("/") + passport).encode()).hexdigest()
    if len(parts) < 2 or not hmac.compare_digest(parts[0], want) or not parts[1]:
        raise ValueError("that login doesn't belong to this server's request; try again")
    return parts[1]


def _words(name: str) -> list[str]:
    return re.findall(r"\w+", name.casefold())


def _same(a: str, b: str) -> bool:
    a, b = sorted((a, b), key=len)
    stem = a[:-1] if len(a) > 4 and a.endswith("s") else a
    return a == b or (len(stem) >= 4 and b.startswith(stem))


def _text(markup: str | None) -> str:
    """Moodle's HTML as plain text, keeping its lines and lists."""
    t = re.sub(r"(?i)<br\s*/?>|</p>|</li>|</div>|</h\d>|</tr>", "\n", markup or "")
    t = re.sub(r"(?i)<li[^>]*>", "- ", t)
    t = html.unescape(re.sub(r"<[^>]+>", "", t))
    return re.sub(r"\n\s*\n+", "\n\n", re.sub(r"[ \t\xa0]+", " ", t)).strip()


def _pdf(content: dict) -> bool:
    return content.get("type") == "file" and (content.get("mimetype") == "application/pdf"
                                              or content.get("filename", "").lower().endswith(".pdf"))


class MoodleSync:
    def __init__(self, study: StudyStore, site: str | None, token: str | None,
                 save_token: Callable[[str | None], None] = lambda _: None, push=None, worker=None,
                 transport: httpx.AsyncBaseTransport | None = None, notebook=None):
        self.study = study
        self.files = study.files
        self.conn = study.conn
        self.conn.executescript(SCHEMA)
        if "text" not in {r["name"] for r in self.conn.execute("PRAGMA table_info(moodle_courses)")}:
            self.conn.execute("ALTER TABLE moodle_courses ADD COLUMN text TEXT NOT NULL DEFAULT ''")
        for r in self.conn.execute("SELECT id, name, section FROM study_files WHERE source = 'moodle' AND "
                                   "(name LIKE '%&%;%' OR section LIKE '%&%;%')").fetchall():
            self.conn.execute("UPDATE study_files SET name = ?, section = ? WHERE id = ?",  # synced before unescaping
                              (html.unescape(r["name"]), html.unescape(r["section"]), r["id"]))
        self.notebook = notebook  # NotebookStore: new files are offered to the course's notebook
        self.site = site.rstrip("/") if site else None
        self.token = token
        self.save_token = save_token
        self.push = push
        self.worker = worker
        self.transport = transport
        self._passports: dict[str, float] = {}
        self._wake = asyncio.Event()
        self._lock = asyncio.Lock()

    # -- state ---------------------------------------------------------------------

    def _get(self, key: str) -> str | None:
        row = self.conn.execute("SELECT value FROM moodle_state WHERE key = ?", (key,)).fetchone()
        return row["value"] if row else None

    def _set(self, key: str, value: str | None) -> None:
        if value is None:
            self.conn.execute("DELETE FROM moodle_state WHERE key = ?", (key,))
        else:
            self.conn.execute("INSERT INTO moodle_state (key, value) VALUES (?, ?) "
                              "ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))

    def _client(self) -> MoodleClient:
        if not self.token:
            raise LoginNeeded("not logged in to Moodle")
        return MoodleClient(self.site, self.token, self.transport)

    # -- logging in ----------------------------------------------------------------

    def login(self) -> dict:
        """Where the app sends the user to log in, with a fresh passport."""
        if not self.site:
            raise MoodleError("AIDE_MOODLE_URL isn't set on the server")
        now = time.monotonic()
        self._passports = {p: t for p, t in self._passports.items() if now - t < PASSPORT_TTL}
        passport = secrets.token_hex(8)
        self._passports[passport] = now
        return {"url": launch_url(self.site, passport), "scheme": SCHEME}

    async def connect(self, callback: str) -> dict:
        """The address Moodle sent the app back to: checked against the passports given out, then kept."""
        if not self.site:
            raise MoodleError("AIDE_MOODLE_URL isn't set on the server")
        token, now = None, time.monotonic()
        for passport, made in list(self._passports.items()):
            if now - made >= PASSPORT_TTL:
                continue
            try:
                token = token_from(callback, self.site, passport)
            except ValueError:
                continue
            del self._passports[passport]
            break
        if token is None:
            token_from(callback, self.site, "")  # raises the reason it can't be read, if that's it
            raise ValueError("that login doesn't belong to this server's request (or took too long); try again")
        client = MoodleClient(self.site, token, self.transport)
        try:
            info = await client.call("core_webservice_get_site_info")
        finally:
            await client.close()
        self.token = token
        self.save_token(token)
        self._set("user", json.dumps({"id": info["userid"], "name": info.get("fullname", ""),
                                      "site": info.get("sitename", "")}))
        self._set("error", None)
        self._set("asked_login", None)
        self.kick()
        return self.status()

    def logout(self) -> None:
        """Forgets the token. The files stay."""
        self.token = None
        self.save_token(None)
        self._set("user", None)
        self._set("error", None)

    # -- courses -------------------------------------------------------------------

    def courses(self, current_only: bool = True) -> list[dict]:
        rows = [dict(r) for r in self.conn.execute("SELECT * FROM moodle_courses WHERE seen = 1 ORDER BY name")]
        return [r for r in rows if not current_only or self._current(r) or r["course_id"]]

    @staticmethod
    def _current(row: dict) -> bool:
        now = datetime.now(timezone.utc)
        starts = datetime.fromtimestamp(row["starts"], timezone.utc) if row["starts"] else None
        ends = datetime.fromtimestamp(row["ends"], timezone.utc) if row["ends"] else None
        return (starts is None or starts - MARGIN <= now) and (ends is None or now <= ends + MARGIN)

    def course_json(self, row: dict) -> dict:
        count = self.conn.execute("SELECT COUNT(*) FROM moodle_files m JOIN study_files f ON f.public_id = m.file_id "
                                  "WHERE m.key LIKE ?", (f"{row['moodle_id']}/%",)).fetchone()[0]
        return {"id": row["moodle_id"], "name": row["name"], "course": row["course_id"],
                "matched": row["mapped"] or None, "files": count}

    def match(self, moodle_id: int, course_id: int | None) -> dict:
        """The user's choice of Aide course for a Moodle course (None: don't sync it)."""
        if self.conn.execute("SELECT 1 FROM moodle_courses WHERE moodle_id = ?", (moodle_id,)).fetchone() is None:
            raise KeyError(f"no Moodle course {moodle_id}")
        self.conn.execute("UPDATE moodle_courses SET course_id = ?, mapped = 'user' WHERE moodle_id = ?",
                          (course_id, moodle_id))
        if course_id is not None:
            self.kick()
        return dict(self.conn.execute("SELECT * FROM moodle_courses WHERE moodle_id = ?", (moodle_id,)).fetchone())

    async def _refresh_courses(self, client: MoodleClient, user_id: int) -> None:
        found = await client.call("core_enrol_get_users_courses", userid=user_id)
        aide = await self.study.courses()
        self.conn.execute("UPDATE moodle_courses SET seen = 0")
        for c in found:
            self.conn.execute(
                "INSERT INTO moodle_courses (moodle_id, name, short, starts, ends) VALUES (?, ?, ?, ?, ?) "
                "ON CONFLICT(moodle_id) DO UPDATE SET name = excluded.name, short = excluded.short, "
                "starts = excluded.starts, ends = excluded.ends, seen = 1",
                (c["id"], c.get("fullname") or c.get("shortname") or str(c["id"]), c.get("shortname") or "",
                 c.get("startdate") or 0, c.get("enddate") or 0))
        for row in self.courses():
            if row["mapped"] is None and (cid := self._guess(row, aide)):
                self.conn.execute("UPDATE moodle_courses SET course_id = ?, mapped = 'auto' WHERE moodle_id = ?",
                                  (cid, row["moodle_id"]))

    @staticmethod
    def _guess(row: dict, aide: list[dict]) -> int | None:
        """The Aide course whose every word is in the Moodle course's name, if exactly one is. Words match when
        equal, or when the shorter, without a plural s, begins the longer and has 4 letters or more ("maths" and
        "MATHEMATICS"); short ones like "II" must be equal, so "Mathematics for Economics I" isn't a match."""
        moodle = _words(f"{row['name']} {row['short']}")
        hits = [c["id"] for c in aide if (words := _words(c["name"]))
                and all(any(_same(w, m) for m in moodle) for w in words)]
        return hits[0] if len(hits) == 1 else None

    # -- syncing -------------------------------------------------------------------

    def kick(self) -> None:
        self._wake.set()

    async def run(self) -> None:
        while True:
            woken = self._wake.is_set()
            self._wake.clear()
            last = self._get("last_try")
            due = not last or datetime.now(timezone.utc) - datetime.fromisoformat(last) >= EVERY
            if self.token and self.site and (due or woken):
                try:
                    await self.sync()
                except Exception:
                    log.exception("Moodle sync failed")
            try:
                await asyncio.wait_for(self._wake.wait(), 600)
            except asyncio.TimeoutError:
                pass

    async def sync(self) -> dict:
        """Downloads what's new. Returns {"new": n, "updated": n}; records an error instead of raising one."""
        async with self._lock:
            self._set("last_try", utcnow().isoformat())
            try:
                client = self._client()
            except LoginNeeded as e:
                return await self._failed(e)
            try:
                user = json.loads(self._get("user") or "null") or {}
                if not user:
                    info = await client.call("core_webservice_get_site_info")
                    user = {"id": info["userid"], "name": info.get("fullname", ""), "site": info.get("sitename", "")}
                    self._set("user", json.dumps(user))
                await self._refresh_courses(client, user["id"])
                new: dict[int, list[dict]] = {}
                updated = 0
                changed: set[int] = set()  # courses whose page changed: their dates are read again
                touched: dict[int, list[dict]] = {}  # new or changed files: read again if one looks like it says when
                for row in self.courses():
                    if row["course_id"] is None:
                        continue
                    for f, was_new in await self._sync_course(client, row):
                        touched.setdefault(row["course_id"], []).append(f)
                        if was_new:
                            new.setdefault(row["course_id"], []).append(f)
                        else:
                            updated += 1
                    if self.conn.execute("SELECT text FROM moodle_courses WHERE moodle_id = ?",
                                         (row["moodle_id"],)).fetchone()[0] != row["text"]:
                        changed.add(row["course_id"])
            except MoodleError as e:
                return await self._failed(e)
            finally:
                await client.close()
            self._set("last_sync", utcnow().isoformat())
            self._set("error", None)
            for course_id, files in new.items():
                self._attach(course_id, files)
                if self.notebook is not None:
                    self.notebook.new_material(course_id, [{"file": f["public_id"]} for f in files])
            if self.notebook is not None:
                for course_id in changed:
                    self.notebook.reread_dates(course_id)
                for course_id, files in touched.items():
                    if course_id not in changed:
                        self.notebook.maybe_dates(course_id, files)
            count = sum(len(fs) for fs in new.values())
            if count:
                await self._announce(new)
            log.info("Moodle sync: %d new, %d updated", count, updated)
            return {"new": count, "updated": updated}

    async def _sync_course(self, client: MoodleClient, row: dict) -> list[tuple[dict, bool]]:
        out = []
        page: list[str] = []  # the course page's text
        for section in await client.call("core_course_get_contents", courseid=row["moodle_id"]):
            section["name"] = html.unescape(section.get("name") or "")
            page.append(f"## {section['name']}" + (f"\n{summary}" if (summary := _text(section.get("summary"))) else ""))
            for module in section.get("modules", []):
                if module.get("uservisible") is False:
                    continue
                module["name"] = html.unescape(module.get("name") or "")
                page.append(await self._module_text(client, module))
                pdfs = [c for c in module.get("contents") or [] if _pdf(c)]
                for c in pdfs:
                    key = f"{row['moodle_id']}/{module['id']}{c.get('filepath') or '/'}{c['filename']}"
                    stamp = int(c.get("timemodified") or 0)
                    seen = self.conn.execute("SELECT * FROM moodle_files WHERE key = ?", (key,)).fetchone()
                    if seen and (seen["time"] >= stamp or self.files.get(seen["file_id"] or "") is None):
                        continue  # unchanged, or deleted by the user
                    if (c.get("filesize") or 0) > MAX_FILE:
                        log.info("Moodle file too big to keep: %s", c["filename"])
                        continue
                    name = module["name"] if len(pdfs) == 1 and module["name"] else html.unescape(c["filename"])
                    if f := await self._fetch(client, c, key, stamp, name, row["course_id"],
                                              section.get("name") or ""):
                        out.append((f, seen is None))
        text = "\n\n".join(p for p in page if p)[:COURSE_TEXT]
        self.conn.execute("UPDATE moodle_courses SET text = ? WHERE moodle_id = ?", (text, row["moodle_id"]))
        return out

    async def _module_text(self, client: MoodleClient, module: dict) -> str:
        """A module on the course page as text: a label's text, a forum's latest posts when it's one for notices
        or textbooks, else its name and kind."""
        kind = module.get("modname") or ""
        if kind == "label":
            return _text(module.get("description"))
        line = f"- {module['name']}" + (f" ({kind})" if kind else "") + (f": {d}" if (d := _text(module.get("description"))) else "")
        if kind != "forum" or not _FORUMS.search(module["name"]) or not module.get("instance"):
            return line
        try:
            found = await client.call("mod_forum_get_forum_discussions", forumid=module["instance"],
                                      sortorder=1, perpage=FORUM_POSTS)
        except LoginNeeded:
            raise
        except MoodleError as e:
            log.info("Moodle forum %s not read: %s", module["name"], e)
            return line
        discussions = (found.get("discussions") if isinstance(found, dict) else None) or []
        posts = [f"### {html.unescape(d.get('subject') or d.get('name') or '')}\n{_text(d.get('message'))[:FORUM_POST]}"
                 for d in discussions[:FORUM_POSTS]]
        return "\n\n".join([line, *posts])

    async def _fetch(self, client: MoodleClient, content: dict, key: str, stamp: int, name: str, course_id: int,
                     section: str) -> dict | None:
        tmp = self.files.folder / f".moodle-{secrets.token_hex(6)}.tmp"
        try:
            await client.download(content["fileurl"], tmp)
            f = await self.files.add(tmp, name, course_id, section=section, source="moodle", source_key=key,
                                     source_time=stamp)
        except LoginNeeded:
            raise
        except (PdfError, MoodleError) as e:  # this file only; the next sync tries it again
            log.warning("Moodle file %s skipped: %s", content["filename"], e)
            return None
        finally:
            tmp.unlink(missing_ok=True)
        self.conn.execute("INSERT INTO moodle_files (key, time, file_id) VALUES (?, ?, ?) ON CONFLICT(key) DO "
                          "UPDATE SET time = excluded.time, file_id = excluded.file_id", (key, stamp, f["public_id"]))
        return f

    def _attach(self, course_id: int, files: list[dict]) -> None:
        """A few new files close to a lecture of their course become its slides (a whole term's worth at once
        doesn't), and its notes are written again with them."""
        if len(files) > SLIDES_PER_LECTURE:
            return
        lectures = self.study.lectures(course_id, limit=500)
        rewrite = set()
        for f in files:
            at = datetime.fromtimestamp(f["source_time"], timezone.utc)
            near = [lec for lec in lectures
                    if abs(datetime.fromisoformat(lec["recorded_at"]) - at) <= SLIDES_WINDOW
                    and len(self.files.files(lecture_id=lec["id"])) < SLIDES_PER_LECTURE]
            if near:
                lecture = min(near, key=lambda lec: abs(datetime.fromisoformat(lec["recorded_at"]) - at))
                self.files.update(f["public_id"], lecture_id=lecture["id"])
                rewrite.add(lecture["id"])
        for lecture_id in rewrite:
            self.study.rewrite(lecture_id)
        if rewrite and self.worker is not None:
            self.worker.kick()

    async def _announce(self, new: dict[int, list[dict]]) -> None:
        """Which files, a line per course; the push carries their ids, so a tap lists them."""
        if self.push is None:
            return
        count = sum(len(fs) for fs in new.values())
        lines = []
        for cid, files in new.items():
            name = (self.study.course(cid) or {}).get("name", "a course")
            lines.append(f"{name[:1].upper()}{name[1:]}: "
                         + ", ".join(re.sub(r"\.pdf$", "", f["name"], flags=re.I) for f in files))
        body = "\n".join(lines)
        if len(body) > ANNOUNCE:
            body = body[:ANNOUNCE - 1].rstrip(" ,") + "…"
        ids = [f["public_id"] for files in new.values() for f in files][:ANNOUNCE_FILES]
        await self.push.send_moodle("Moodle · " + ("1 new file" if count == 1 else f"{count} new files"), body,
                                    files=ids)

    async def _failed(self, error: MoodleError) -> dict:
        self._set("error", str(error))
        log.warning("Moodle sync: %s", error)
        if isinstance(error, LoginNeeded) and self.token and not self._get("asked_login"):
            self._set("asked_login", "1")  # once, until the next login
            if self.push is not None:
                await self.push.send_moodle("Moodle", "Log in again to keep getting course files.", login=True)
        return {"error": str(error)}

    # -- for the app -----------------------------------------------------------------

    def status(self) -> dict:
        if not self.site:
            return {"enabled": False}
        user = json.loads(self._get("user") or "null") if self.token else None
        last = self._get("last_sync")
        return {"enabled": True, "site": self.site, "connected": bool(self.token),
                "user": user["name"] if user else None,
                "last_sync": datetime.fromisoformat(last).astimezone(self.study.tz).isoformat() if last else None,
                "error": self._get("error") if self.token else None,
                "courses": [self.course_json(r) for r in self.courses()] if self.token else []}
