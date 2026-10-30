"""YouTube videos (docs/API.md, "Videos"): a link in, a brief out.

A video is read in the background, one at a time: yt-dlp gives the details and the captions (the video's own, else
YouTube's automatic ones); a video with neither is transcribed with Whisper on the GPU. One model call writes the
brief from the transcript (the gist, a TL;DR, what to know, the key moments with their times, a takeaway), in
English. A frame is taken at each key moment straight from the stream (ffmpeg seeks, nothing is downloaded whole),
and a quick look keeps only the frames that show something (a slide, a chart, code, a product), not someone talking.
The brief is posted in the chat the link came from, with a `videos` card, and pushed.
"""

import asyncio
import base64
import json
import logging
import re
import secrets
import shutil
import sqlite3
import tempfile
from datetime import datetime
from pathlib import Path
from typing import TYPE_CHECKING, Awaitable, Callable
from urllib.parse import parse_qs, urlparse
from zoneinfo import ZoneInfo

import httpx

from .db import utcnow
from .notebook import parse_json
from .study import stamp

if TYPE_CHECKING:
    from .agent import Agent
    from .engine import Engine
    from .photos import PhotoStore
    from .push import Push

log = logging.getLogger(__name__)

STATUSES = ("queued", "working", "ready", "failed")
MAX_SECONDS = 4 * 3600  # longer videos aren't read
PARAGRAPH = 30  # seconds: a [m:ss] mark starts a paragraph of the transcript about this often
MAX_MOMENTS = 10
FRAME_AFTER = 3  # seconds into a moment: past the cut that starts it
FRAME_WIDTH = 1280
FRAMES_AT_ONCE = 4
FRAME_TIMEOUT = 60  # seconds for one ffmpeg seek
LOOK_TOKENS = 4000  # Haiku thinks first: 300 went on the thinking and the answer came back empty
NOTE = "[Video #"  # the note before a video's post: the app doesn't show it (agent.py)

ID = re.compile(r"^[A-Za-z0-9_-]{11}$")
HOSTS = ("youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be",
         "youtube-nocookie.com", "www.youtube-nocookie.com")
LINK = re.compile(r"https?://(?:[a-z]+\.)?(?:youtube\.com|youtu\.be|youtube-nocookie\.com)/\S+", re.I)

WRITE = """You write a brief of a YouTube video for one person, from its transcript, so they know what happened in \
it and what they should know without watching it. Write in English, whatever the video's language (names, titles \
and quotes stay as they are). Be concrete: the actual claims, numbers, steps, names and advice, not "the speaker \
talks about". No filler, no praise of the video.

Answer with JSON only:
{"gist": "one or two sentences: what the video is and its main point",
 "tldr": "three to five sentences",
 "know": ["what the person should know or remember: 3 to 7 points, each one sentence"],
 "moments": [{"t": 130, "title": "three to six words", "text": "one to three sentences on what happens or is said"}],
 "takeaway": "one line to remember",
 "answer": "their question answered from the video, or null when there's no question"}

Moments: the key moments in order, spread over the whole video: 4 to 10 (2 to 4 for a video under 3 minutes). `t` is \
in seconds, where the moment starts, from the [m:ss] marks and the chapters. If the video doesn't say something \
they asked, `answer` says so."""

LOOK = """These are frames from a YouTube video, one at each key moment. Keep the frames worth showing next to the \
moment's summary: a slide, a diagram, a chart, code, text on screen, a product, a demo, a map, a place or an object \
the moment is about. Drop someone just talking to the camera, a blank or blurred frame, a transition, a logo or an \
intro card. Answer with JSON only: {"keep": [the numbers of the frames to keep]}"""


def parse_url(text: str) -> tuple[str, int | None] | None:
    """A YouTube link's video id and its start time in seconds (&t=), or None when it isn't one."""
    try:
        u = urlparse(text.strip())
    except ValueError:
        return None
    host = (u.hostname or "").lower()
    if u.scheme not in ("http", "https") or host not in HOSTS:
        return None
    q = parse_qs(u.query)
    parts = [p for p in u.path.split("/") if p]
    if host.endswith("youtu.be"):
        vid = parts[0] if parts else None
    elif parts[:1] == ["watch"]:
        vid = (q.get("v") or [None])[0]
    elif len(parts) >= 2 and parts[0] in ("shorts", "embed", "live", "v", "e"):
        vid = parts[1]
    else:
        vid = None
    if not vid or not ID.match(vid):
        return None
    return vid, _seconds((q.get("t") or q.get("start") or [None])[0])


def _seconds(t: str | None) -> int | None:
    """YouTube's t: 90, 90s or 1m30s."""
    if not t:
        return None
    if t.isdigit():
        return int(t)
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", t)
    if not m or not any(m.groups()):
        return None
    h, mi, s = (int(g or 0) for g in m.groups())
    return h * 3600 + mi * 60 + s


def find_link(text: str) -> str | None:
    """The first YouTube video link in a message."""
    for m in LINK.finditer(text):
        if parse_url(m.group(0).rstrip(".,;:!?)]>\"'")):
            return m.group(0).rstrip(".,;:!?)]>\"'")
    return None


def watch_url(youtube_id: str, at: float | None = None) -> str:
    return f"https://www.youtube.com/watch?v={youtube_id}" + (f"&t={int(at)}s" if at else "")


# -- captions -----------------------------------------------------------------------------------


def json3_segments(data: dict) -> list[tuple[float, str]]:
    """YouTube's json3 captions as (start in seconds, text), empty lines left out."""
    out = []
    for ev in data.get("events") or []:
        text = "".join(s.get("utf8", "") for s in ev.get("segs") or []).replace("\n", " ").strip()
        if text:
            out.append((ev.get("tStartMs", 0) / 1000, " ".join(text.split())))
    return out


def transcript(segments: list[tuple[float, str]], every: int = PARAGRAPH) -> str:
    """Segments as paragraphs, each starting with its [m:ss] mark, a new one about every `every` seconds."""
    paras: list[str] = []
    mark = -every
    for start, text in segments:
        if start - mark >= every or not paras:
            mark = start
            paras.append(f"[{stamp(start)}] {text}")
        else:
            paras[-1] += " " + text
    return "\n\n".join(paras)


def _caption_track(info: dict) -> tuple[str, list[dict]] | None:
    """The best captions: the video's own in its language (else any of its own), else YouTube's automatic ones in
    the spoken language. (language, formats)"""
    lang = (info.get("language") or "").split("-")[0].lower()
    own = {k: v for k, v in (info.get("subtitles") or {}).items() if k != "live_chat"}
    auto = info.get("automatic_captions") or {}

    def pick(tracks: dict, keys: list[str]) -> tuple[str, list[dict]] | None:
        for k in keys:
            if tracks.get(k):
                return k, tracks[k]
        return None

    if own:
        mine = [k for k in own if lang and k.split("-")[0].lower() == lang]
        return pick(own, mine + ["en", *own])
    orig = [k for k in auto if k.endswith("-orig")]
    return pick(auto, orig + ([lang] if lang else []) + ["en"])


# -- the store ----------------------------------------------------------------------------------


class VideoStore:
    SCHEMA = """
    CREATE TABLE IF NOT EXISTS videos (
        id           INTEGER PRIMARY KEY,
        public_id    TEXT NOT NULL UNIQUE,  -- v_<hex>
        youtube_id   TEXT NOT NULL,
        url          TEXT NOT NULL,
        conversation TEXT,              -- the chat it's posted in (a public id)
        question     TEXT,              -- what the user wanted from it, if they said
        status       TEXT NOT NULL,     -- see STATUSES
        step         TEXT,              -- working: what it's doing now
        error        TEXT,              -- failed: why, for the user
        title        TEXT,
        channel      TEXT,
        duration     INTEGER,           -- seconds
        thumbnail    TEXT,              -- a URL on i.ytimg.com
        published    TEXT,              -- YYYY-MM-DD
        language     TEXT,              -- the video's
        source       TEXT,              -- where the transcript came from: captions, auto or whisper
        chapters     TEXT,              -- JSON [{t, title}]
        transcript   TEXT,              -- [m:ss] paragraphs
        summary      TEXT,              -- JSON: gist, tldr, know, moments [{t, title, text, frame}], takeaway, answer
        created_at   TEXT NOT NULL,
        updated_at   TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS videos_created ON videos (created_at);
    """

    def __init__(self, conn: sqlite3.Connection, tz: ZoneInfo):
        self.conn, self.tz = conn, tz
        conn.executescript(self.SCHEMA)
        self.on_ready: list[Callable[[], None]] = []  # the vault, to write the note

    def create(self, url: str, youtube_id: str, conversation: str | None, question: str | None) -> dict:
        now = utcnow().isoformat()
        public_id = "v_" + secrets.token_hex(6)
        self.conn.execute(
            "INSERT INTO videos (public_id, youtube_id, url, conversation, question, status, step, thumbnail, "
            "created_at, updated_at) VALUES (?, ?, ?, ?, ?, 'queued', 'Waiting to start', ?, ?, ?)",
            (public_id, youtube_id, url, conversation, (question or "").strip() or None,
             f"https://i.ytimg.com/vi/{youtube_id}/hqdefault.jpg", now, now))
        return self.get(public_id)

    def get(self, public_id: str) -> dict | None:
        row = self.conn.execute("SELECT * FROM videos WHERE public_id = ?", (public_id,)).fetchone()
        return self._row(row) if row else None

    def update(self, public_id: str, **fields) -> dict:
        for k in ("chapters", "summary"):
            if k in fields and fields[k] is not None:
                fields[k] = json.dumps(fields[k])
        fields["updated_at"] = utcnow().isoformat()
        self.conn.execute(f"UPDATE videos SET {', '.join(f'{k} = ?' for k in fields)} WHERE public_id = ?",
                          (*fields.values(), public_id))
        return self.get(public_id)

    def search(self, q: str | None = None, limit: int = 100, ready: bool = False) -> list[dict]:
        sql, args = "SELECT * FROM videos", []
        where = []
        if ready:
            where.append("status = 'ready'")
        if q and q.strip():
            where.append("(title LIKE ? OR channel LIKE ? OR summary LIKE ?)")
            args += [f"%{q.strip()}%"] * 3
        if where:
            sql += " WHERE " + " AND ".join(where)
        rows = self.conn.execute(sql + " ORDER BY id DESC LIMIT ?", (*args, limit)).fetchall()
        return [self._row(r) for r in rows]

    def by_status(self, *statuses: str) -> list[dict]:
        rows = self.conn.execute(f"SELECT * FROM videos WHERE status IN ({','.join('?' * len(statuses))}) "
                                 "ORDER BY id", statuses).fetchall()
        return [self._row(r) for r in rows]

    def delete(self, public_id: str) -> dict | None:
        v = self.get(public_id)
        if v is not None:
            self.conn.execute("DELETE FROM videos WHERE public_id = ?", (public_id,))
        return v

    @staticmethod
    def _row(row: sqlite3.Row) -> dict:
        d = dict(row)
        d["chapters"] = json.loads(d["chapters"]) if d["chapters"] else []
        d["summary"] = json.loads(d["summary"]) if d["summary"] else None
        return d

    # -- what the app gets --------------------------------------------------------------------

    def card(self, v: dict) -> dict:
        """A `videos` card item (docs/API.md, "Videos")."""
        s = v["summary"] or {}
        moments = s.get("moments") or []
        return {"id": v["public_id"], "youtube_id": v["youtube_id"], "url": v["url"], "status": v["status"],
                "step": v["step"] if v["status"] in ("queued", "working") else None, "error": v["error"],
                "title": v["title"], "channel": v["channel"], "duration": v["duration"],
                "thumbnail": v["thumbnail"], "gist": s.get("gist"), "moments": len(moments),
                "frames": sum(1 for m in moments if m.get("frame")),
                "cover": next((m["frame"] for m in moments if m.get("frame")), None),
                "created_at": datetime.fromisoformat(v["created_at"]).astimezone(self.tz).isoformat(timespec="seconds")}

    def full(self, v: dict) -> dict:
        s = v["summary"] or {}
        return {**self.card(v), "question": v["question"], "published": v["published"], "language": v["language"],
                "source": v["source"], "conversation_id": v["conversation"], "chapters": v["chapters"],
                "tldr": s.get("tldr"), "know": s.get("know") or [], "takeaway": s.get("takeaway"),
                "answer": s.get("answer"),
                "moments": [{**m, "url": watch_url(v["youtube_id"], m["t"])} for m in s.get("moments") or []]}


# -- reading a video ----------------------------------------------------------------------------


class VideoError(Exception):
    """Why a video can't be read, in words for the user."""


def _ydl_options(**more) -> dict:
    return {"quiet": True, "no_warnings": True, "noprogress": True, "skip_download": True, "noplaylist": True,
            "socket_timeout": 30, **more}


def _info(url: str) -> dict:
    """yt-dlp's details for one video (blocking)."""
    import yt_dlp

    try:
        with yt_dlp.YoutubeDL(_ydl_options(format="bv*[height<=720][vcodec^=avc1]/bv*[height<=720]/b")) as ydl:
            return ydl.sanitize_info(ydl.extract_info(url, download=False))
    except yt_dlp.utils.DownloadError as e:
        text = str(e)
        if "Private video" in text:
            raise VideoError("The video is private.") from None
        if "Sign in to confirm your age" in text or "age" in text.lower() and "restrict" in text.lower():
            raise VideoError("The video is age-restricted, so YouTube won't show it without a login.") from None
        if "unavailable" in text.lower():
            raise VideoError("YouTube says the video isn't available.") from None
        if "members" in text.lower():
            raise VideoError("The video is for the channel's members only.") from None
        log.warning("yt-dlp couldn't read %s: %s", url, text)
        raise VideoError("YouTube wouldn't give me the video (yt-dlp may need an update on the server).") from None


def _audio(url: str, folder: Path) -> Path:
    """The video's sound, downloaded (blocking): for a video with no captions."""
    import yt_dlp

    opts = _ydl_options(skip_download=False, format="bestaudio[abr<=160]/bestaudio/b",
                        outtmpl=str(folder / "audio.%(ext)s"))
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.download([url])
    found = [p for p in folder.iterdir() if p.name.startswith("audio.") and not p.name.endswith(".part")]
    if not found:
        raise VideoError("I couldn't download the video's sound to transcribe it.")
    return found[0]


def _stream(info: dict) -> tuple[str, dict] | None:
    """The chosen video stream's URL and headers, for ffmpeg to seek in."""
    fmt = (info.get("requested_formats") or [info])[0]
    if not fmt.get("url") or fmt.get("vcodec") in (None, "none"):
        return None
    return fmt["url"], fmt.get("http_headers") or info.get("http_headers") or {}


async def grab_frame(url: str, headers: dict, at: float) -> bytes | None:
    """One JPEG frame at `at` seconds, sought straight in the stream."""
    head = "".join(f"{k}: {v}\r\n" for k, v in headers.items())
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-v", "error", *(["-headers", head] if head else []), "-ss", f"{at:.1f}", "-i", url,
        "-frames:v", "1", "-vf", f"scale='min({FRAME_WIDTH},iw)':-2", "-q:v", "3", "-f", "image2", "-c:v", "mjpeg",
        "pipe:1", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), FRAME_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        return None
    if proc.returncode != 0 or not out:
        log.info("no frame at %.0f s: %s", at, err.decode(errors="replace")[-200:])
        return None
    return out


Transcribe = Callable[[Path], Awaitable[tuple[str, str | None, int | None]]]


class VideoWorker:
    """Reads the videos one at a time and posts each brief in its chat."""

    def __init__(self, store: VideoStore, engine: "Engine", photos: "PhotoStore", push: "Push | None" = None,
                 transcribe: Transcribe | None = None, http: httpx.AsyncClient | None = None):
        self.store, self.engine, self.photos, self.push = store, engine, photos, push
        self.transcribe = transcribe  # Whisper, when it's installed
        self.http = http or httpx.AsyncClient(timeout=30, follow_redirects=True)
        self.agent: "Agent | None" = None  # set by the app: posts in the chats
        self.queue: asyncio.Queue[str] = asyncio.Queue()
        # Seams for the tests: yt-dlp and ffmpeg.
        self.info: Callable[[str], dict] = _info
        self.audio: Callable[[str, Path], Path] = _audio
        self.frame = grab_frame

    def start(self, url: str, conversation: str | None, question: str | None = None) -> dict:
        found = parse_url(url)
        if found is None:
            raise ValueError("that isn't a YouTube video link")
        v = self.store.create(url.strip(), found[0], conversation, question)
        self.queue.put_nowait(v["public_id"])
        return v

    async def run(self) -> None:
        for v in self.store.by_status("queued", "working"):  # a restart cut these off: start them again
            self.queue.put_nowait(v["public_id"])
        while True:
            vid = await self.queue.get()
            v = self.store.get(vid)
            if v is None or v["status"] not in ("queued", "working"):
                continue
            try:
                await self.process(v)
            except VideoError as e:
                await self._failed(v, str(e))
            except Exception:
                log.exception("video %s failed", vid)
                await self._failed(v, "Something went wrong while I was reading the video.")

    def _step(self, v: dict, step: str) -> None:
        self.store.update(v["public_id"], status="working", step=step)

    async def process(self, v: dict) -> dict:
        vid = v["public_id"]
        self._step(v, "Reading the video")
        info = await asyncio.to_thread(self.info, watch_url(v["youtube_id"]))
        duration = int(info.get("duration") or 0)
        published = info.get("upload_date")
        chapters = [{"t": int(c.get("start_time") or 0), "title": c.get("title") or ""}
                    for c in info.get("chapters") or []]
        thumb = f"https://i.ytimg.com/vi/{v['youtube_id']}/hqdefault.jpg"
        if any(t.get("id") == "maxresdefault" or "maxresdefault.jpg" in (t.get("url") or "")
               for t in info.get("thumbnails") or []):
            thumb = f"https://i.ytimg.com/vi/{v['youtube_id']}/maxresdefault.jpg"
        v = self.store.update(vid, title=info.get("title"), channel=info.get("channel") or info.get("uploader"),
                              duration=duration or None, thumbnail=thumb, chapters=chapters,
                              published=f"{published[:4]}-{published[4:6]}-{published[6:]}" if published else None)
        if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
            raise VideoError("It's a live stream: I can read it once it's over.")
        if duration > MAX_SECONDS:
            raise VideoError(f"It's {stamp(duration)} long: I read videos up to {MAX_SECONDS // 3600} hours.")
        if self.agent is not None and v["conversation"] and v["title"]:  # a shared video's chat has no title yet
            row = self.agent.db.app_conversation(v["conversation"])
            if row is not None and row["title"] is None:
                self.agent.db.set_conversation_title(row["id"], v["title"][:60])

        text, source, language = await self._transcript(v, info)
        if not text.strip():
            raise VideoError("The video has no speech I could read.")
        v = self.store.update(vid, transcript=text, source=source, language=language)

        self._step(v, "Writing the brief")
        summary = await self._write(v, info, text)

        self._step(v, "Picking frames")
        summary["moments"] = await self._frames(info, summary["moments"], duration)
        v = self.store.update(vid, status="ready", step=None, summary=summary)
        for hook in self.store.on_ready:
            hook()
        await self._post(v)
        return v

    async def _transcript(self, v: dict, info: dict) -> tuple[str, str, str | None]:
        language = (info.get("language") or "").split("-")[0] or None
        if track := _caption_track(info):
            lang, formats = track
            auto = lang not in (info.get("subtitles") or {})
            if url := next((f["url"] for f in formats if f.get("ext") == "json3"), None):
                try:
                    r = await self.http.get(url)
                    r.raise_for_status()
                    if segments := json3_segments(r.json()):
                        return transcript(segments), "auto" if auto else "captions", \
                            lang.removesuffix("-orig").split("-")[0] or language
                except (httpx.HTTPError, ValueError) as e:
                    log.warning("captions for %s: %s", v["public_id"], e)
        if self.transcribe is None:
            raise VideoError("The video has no captions, and Whisper isn't installed on the server to transcribe it.")
        self._step(v, "Transcribing")
        folder = Path(tempfile.mkdtemp(prefix="aide-video-"))
        try:
            path = await asyncio.to_thread(self.audio, watch_url(v["youtube_id"]), folder)
            text, lang, _ = await self.transcribe(path)
        finally:
            shutil.rmtree(folder, ignore_errors=True)
        return text, "whisper", lang or language

    async def _write(self, v: dict, info: dict, text: str) -> dict:
        head = [f"Title: {v['title']}", f"Channel: {v['channel']}", f"Length: {stamp(v['duration'] or 0)}"]
        if v["chapters"]:
            head.append("Chapters: " + "; ".join(f"[{stamp(c['t'])}] {c['title']}" for c in v["chapters"]))
        if desc := (info.get("description") or "").strip():
            head.append("Description: " + desc[:1500])
        if v["question"]:
            head.append(f"What they want from it: {v['question']}")
        prompt = "\n".join(head) + "\n\nTranscript:\n" + text
        answer = await self.engine.ask(WRITE, [{"type": "text", "text": prompt}], 4000, background=True)
        data = parse_json(answer)
        if not isinstance(data, dict) or not data.get("gist"):
            raise RuntimeError("the brief came back without a gist")
        end = v["duration"] or 0
        moments = []
        for m in data.get("moments") or []:
            if not isinstance(m, dict) or not m.get("title"):
                continue
            t = max(0, int(float(m.get("t") or 0)))
            moments.append({"t": min(t, end) if end else t, "title": str(m["title"]), "text": str(m.get("text") or "")})
        moments.sort(key=lambda m: m["t"])
        return {"gist": str(data["gist"]), "tldr": str(data.get("tldr") or ""),
                "know": [str(k) for k in data.get("know") or [] if k],
                "moments": moments[:MAX_MOMENTS], "takeaway": data.get("takeaway") or None,
                "answer": data.get("answer") or None}

    async def _frames(self, info: dict, moments: list[dict], duration: int) -> list[dict]:
        """A frame for each moment that shows something; the others have none."""
        stream = _stream(info)
        if not moments or stream is None:
            return moments
        url, headers = stream
        gate = asyncio.Semaphore(FRAMES_AT_ONCE)

        async def one(m: dict) -> bytes | None:
            at = m["t"] + FRAME_AFTER
            if duration:
                at = min(at, max(0, duration - 1))
            async with gate:
                return await self.frame(url, headers, at)

        frames = await asyncio.gather(*(one(m) for m in moments))
        shots = [(i, f) for i, f in enumerate(frames) if f]
        if not shots:
            return moments
        content: list[dict] = []
        for n, (i, f) in enumerate(shots, 1):
            content += [{"type": "text", "text": f"Frame {n} ({stamp(moments[i]['t'])}, {moments[i]['title']})"},
                        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                     "data": base64.b64encode(f).decode()}}]
        try:
            keep = parse_json(await self.engine.ask(LOOK, content, LOOK_TOKENS, fast=True, background=True)).get("keep") or []
        except Exception as e:
            log.warning("couldn't pick the frames: %s", e)
            return moments
        out = [dict(m) for m in moments]
        for n, (i, f) in enumerate(shots, 1):
            if n in keep:
                try:
                    out[i]["frame"] = self.photos.save(f, "image/jpeg")
                except ValueError as e:
                    log.info("frame %d not saved: %s", n, e)
        return out

    def delete(self, public_id: str) -> None:
        """The video and its frames (only its own: they're saved for it alone)."""
        if (v := self.store.delete(public_id)) is not None:
            for m in (v["summary"] or {}).get("moments") or []:
                if m.get("frame"):
                    self.photos.delete(m["frame"])

    # -- telling the user ---------------------------------------------------------------------

    async def _post(self, v: dict) -> None:
        s = v["summary"] or {}
        lines = [f"**{v['title']}**", s.get("gist") or ""]
        if s.get("answer"):
            lines.append(s["answer"])
        if s.get("know"):
            lines.append("\n".join(f"- {k}" for k in s["know"]))
        text = "\n\n".join(x for x in lines if x)
        await self._send(v, f"{NOTE}{v['public_id']}: the brief is ready]", text,
                         f"Summary ready: {v['title']}", s.get("gist") or "")

    async def _failed(self, v: dict, reason: str) -> None:
        v = self.store.update(v["public_id"], status="failed", step=None, error=reason)
        title = v["title"] or "the video"
        await self._send(v, f"{NOTE}{v['public_id']}: couldn't read it]", f"I couldn't read {title}. {reason}",
                         "Couldn't read the video", reason)

    async def _send(self, v: dict, note: str, text: str, push_title: str, push_body: str) -> None:
        if self.agent is None or not v["conversation"]:
            return
        try:
            await self.agent.post(v["conversation"], note, text,
                                  [{"type": "videos", "videos": [self.store.card(v)]}])
        except Exception:
            log.exception("video %s: couldn't post in its chat", v["public_id"])
            return
        if self.push is not None:
            try:
                await self.push.send_message(v["conversation"], push_title, push_body[:180])
            except Exception:
                log.exception("video %s: couldn't push", v["public_id"])

    # -- for follow-ups -----------------------------------------------------------------------

    def read(self, public_id: str, query: str | None = None, limit: int = 6000) -> str:
        """The brief, or with a query the transcript's paragraphs that mention it (with their times)."""
        v = self.store.get(public_id)
        if v is None:
            raise LookupError(f"no video {public_id}")
        if v["status"] != "ready":
            return f"{v['title'] or v['url']}: {v['status']}" + (f" ({v['error']})" if v["error"] else "")
        head = f"{v['title']} ({v['channel']}, {stamp(v['duration'] or 0)}), {v['url']}"
        paras = (v["transcript"] or "").split("\n\n")
        if query and query.strip():
            words = [w for w in re.findall(r"\w+", query.casefold()) if len(w) > 2] or [query.casefold()]
            scored = sorted(((sum(p.casefold().count(w) for w in words), i) for i, p in enumerate(paras)),
                            reverse=True)
            hits = sorted(i for score, i in scored[:8] if score)
            if not hits:
                return f"{head}\nNothing in the transcript mentions {query!r}."
            out = "\n\n".join(paras[i] for i in hits)
            return f"{head}\nTranscript, where it mentions {query!r}:\n\n{out[:limit]}"
        s = v["summary"] or {}
        moments = "\n".join(f"[{stamp(m['t'])}] {m['title']}: {m['text']}" for m in s.get("moments") or [])
        whole = "\n\n".join(paras)
        return (f"{head}\nGist: {s.get('gist')}\nTL;DR: {s.get('tldr')}\nKey moments:\n{moments}\n\n"
                f"Transcript (start):\n{whole[:limit]}" + (" […]" if len(whole) > limit else ""))
