import json

import httpx
import pytest
from fastapi.testclient import TestClient

from aide.agent import CONVERSATION, Agent, _merge
from aide.agents import AGENTS, connectors
from aide.channels.api import create_app
from aide.db import Database
from aide.photos import PhotoStore
from aide.reminders import ReminderStore
from aide.study import StudyStore
from aide.tools import ToolRegistry
from aide.tools.videos import video_tools
from aide.vault import Vault
from aide.videos import (VideoError, VideoStore, VideoWorker, find_link, json3_segments, parse_url, transcript,
                         _caption_track)
from test_agents import AUTH, ROME, FakeClient

JPEG = b"\xff\xd8\xff\xe0" + b"frame" * 50

INFO = {
    "title": "How neural networks learn", "channel": "3Blue1Brown", "duration": 1260, "upload_date": "20171103",
    "language": "en", "description": "Gradient descent, explained.",
    "chapters": [{"start_time": 0, "title": "Intro"}, {"start_time": 300, "title": "Gradient descent"}],
    "thumbnails": [{"id": "maxresdefault", "url": "https://i.ytimg.com/vi/IHZwWFHWa-w/maxresdefault.jpg"}],
    "subtitles": {},
    "automatic_captions": {"en-orig": [{"ext": "json3", "url": "https://captions/en-orig"}],
                           "it": [{"ext": "json3", "url": "https://captions/it"}]},
    "requested_formats": [{"url": "https://stream/video", "vcodec": "avc1", "http_headers": {"User-Agent": "x"}},
                          {"url": "https://stream/audio", "vcodec": "none"}],
}
CAPTIONS = {"events": [
    {"tStartMs": 0, "segs": [{"utf8": "Last video I laid out"}, {"utf8": " the structure"}]},
    {"tStartMs": 4000, "segs": [{"utf8": "\n"}]},
    {"tStartMs": 12000, "segs": [{"utf8": "of a neural network."}]},
    {"tStartMs": 310000, "segs": [{"utf8": "Gradient descent finds a local minimum of the cost."}]},
]}
BRIEF = {"gist": "How a network learns by gradient descent on a cost function.",
         "tldr": "The network's weights are tuned to lower a cost.", "know": ["The cost averages over examples."],
         "moments": [{"t": 305, "title": "Gradient descent", "text": "Walk downhill on the cost."},
                     {"t": 2, "title": "Recap", "text": "The structure of the network."},
                     {"t": 9999, "title": "Outro", "text": "Thanks."}],
         "takeaway": "Learning is minimising a cost.", "answer": None}


class FakeEngine:
    def __init__(self, *answers):
        self.answers = list(answers)
        self.asked = []

    async def ask(self, system, content, max_tokens, fast=False, wait=True, background=False, effort=None):
        self.asked.append({"system": system, "content": content, "fast": fast})
        return self.answers.pop(0)


def captions_http(payload=CAPTIONS):
    def handler(request):
        return httpx.Response(200, json=payload) if request.url.host == "captions" else httpx.Response(404)
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


@pytest.fixture
def env(tmp_path):
    db = Database(":memory:")
    photos = PhotoStore(tmp_path / "photos")

    def make(*answers, info=INFO, http=None, transcribe=None):
        store = VideoStore(db.conn, ROME)
        engine = FakeEngine(*answers)
        worker = VideoWorker(store, engine, photos, transcribe=transcribe, http=http or captions_http())
        worker.info = lambda url: info
        grabbed = []

        async def frame(url, headers, at):
            grabbed.append((url, at))
            return JPEG
        worker.frame = frame
        worker.grabbed = grabbed
        agent = Agent(FakeClient([]), db, ToolRegistry(video_tools(worker, lambda: CONVERSATION)), model="m", tz=ROME,
                      photos=photos)
        worker.agent = agent
        return worker, agent, engine
    yield make, db, photos
    db.close()


def test_youtube_links():
    assert parse_url("https://www.youtube.com/watch?v=IHZwWFHWa-w&t=1m30s") == ("IHZwWFHWa-w", 90)
    assert parse_url("https://youtu.be/IHZwWFHWa-w?si=abc&t=42") == ("IHZwWFHWa-w", 42)
    assert parse_url("https://m.youtube.com/shorts/IHZwWFHWa-w") == ("IHZwWFHWa-w", None)
    assert parse_url("https://music.youtube.com/watch?v=IHZwWFHWa-w") == ("IHZwWFHWa-w", None)
    assert parse_url("https://www.youtube.com/channel/UCYO_jab_esuFRV4b17AJtAw") is None
    assert parse_url("https://vimeo.com/123") is None and parse_url("not a link") is None
    assert parse_url("https://www.youtube.com/watch?v=short") is None
    assert find_link("Guarda questo: https://youtu.be/IHZwWFHWa-w?si=x.") == "https://youtu.be/IHZwWFHWa-w?si=x"
    assert find_link("https://www.youtube.com/@3blue1brown") is None


def test_captions_become_marked_paragraphs():
    segments = json3_segments(CAPTIONS)
    assert segments[0] == (0, "Last video I laid out the structure") and len(segments) == 3
    text = transcript(segments)
    assert text == ("[0:00] Last video I laid out the structure of a neural network.\n\n"
                    "[5:10] Gradient descent finds a local minimum of the cost.")
    # Captions: the video's own in its language first, else YouTube's in the spoken language.
    assert _caption_track(INFO)[0] == "en-orig"
    own = {**INFO, "language": "it", "subtitles": {"en": [{}], "it": [{}], "live_chat": [{}]}}
    assert _caption_track(own)[0] == "it"


async def test_a_video_is_read_briefed_and_posted_with_its_frames(env):
    make, db, photos = env
    worker, agent, engine = make(json.dumps(BRIEF), '```json\n{"keep": [2]}\n```')
    out = await agent.registries["aide"].get("summarize_video").handler(
        url="https://youtu.be/IHZwWFHWa-w", question=None)
    card = out.attachment["videos"][0]
    assert out.attachment["type"] == "videos" and card["status"] == "queued" and card["title"] is None
    assert card["thumbnail"] == "https://i.ytimg.com/vi/IHZwWFHWa-w/hqdefault.jpg"

    v = await worker.process(worker.store.get(worker.queue.get_nowait()))
    assert v["status"] == "ready" and v["source"] == "auto" and v["language"] == "en"
    assert v["title"] == "How neural networks learn" and v["published"] == "2017-11-03"
    assert v["thumbnail"].endswith("/maxresdefault.jpg") and v["chapters"][1] == {"t": 300, "title": "Gradient descent"}
    # The brief is asked in English from the marked transcript, with the chapters.
    prompt = engine.asked[0]["content"][0]["text"]
    assert "[5:10] Gradient descent" in prompt and "Chapters: [0:00] Intro; [5:00] Gradient descent" in prompt
    assert "Write in English" in engine.asked[0]["system"]
    # Moments in order, clamped to the video; a frame at each, the quick look keeps the second.
    s = v["summary"]
    assert [m["t"] for m in s["moments"]] == [2, 305, 1260]
    assert [round(at) for _, at in worker.grabbed] == [5, 308, 1259]
    assert engine.asked[1]["fast"] and sum(b["type"] == "image" for b in engine.asked[1]["content"]) == 3
    assert [bool(m.get("frame")) for m in s["moments"]] == [False, True, False]
    assert photos.load(s["moments"][1]["frame"])[0] == JPEG

    full = worker.store.full(v)
    assert full["moments"][1]["url"] == "https://www.youtube.com/watch?v=IHZwWFHWa-w&t=305s"
    assert full["frames"] == 1 and full["cover"] == s["moments"][1]["frame"] and full["moments"] == full["moments"]
    # Posted in the chat with its card; the note before it stays out of sight.
    last = agent.visible_history(CONVERSATION)[-1]
    assert last["role"] == "assistant" and "**How neural networks learn**" in last["text"]
    assert last["attachments"][0]["videos"][0]["status"] == "ready"
    assert not any(m["text"].startswith("[Video #") for m in agent.visible_history(CONVERSATION))

    # Follow-ups read the transcript where it mentions something, with its times.
    found = worker.read(v["public_id"], "gradient descent")
    assert "[5:10] Gradient descent finds" in found and "[0:00]" not in found
    assert "Nothing in the transcript" in worker.read(v["public_id"], "banana")
    assert "Gist: How a network learns" in worker.read(v["public_id"])
    listed = await agent.registries["aide"].get("list_videos").handler(query="neural")
    assert v["public_id"] in listed and "21:00" in listed


async def test_no_captions_goes_to_whisper(env, tmp_path):
    make, *_ = env
    heard = []

    async def transcribe(path):
        heard.append(path.name)
        return "[0:00] Ciao a tutti.", "it", 60

    def audio(url, folder):
        path = folder / "audio.webm"
        path.write_bytes(b"sound")
        return path
    info = {**INFO, "language": "it", "automatic_captions": {}, "duration": 60}
    worker, agent, engine = make(json.dumps({**BRIEF, "moments": []}), info=info, transcribe=transcribe)
    worker.audio = audio
    v = worker.start("https://www.youtube.com/watch?v=IHZwWFHWa-w", CONVERSATION)
    v = await worker.process(v)
    assert heard == ["audio.webm"] and v["source"] == "whisper" and v["language"] == "it"
    assert v["transcript"] == "[0:00] Ciao a tutti." and worker.grabbed == []  # no moments, no frames

    worker, *_ = make(info=info)  # and without Whisper, it says so
    v = worker.start("https://youtu.be/IHZwWFHWa-w", CONVERSATION)
    with pytest.raises(VideoError, match="no captions"):
        await worker.process(v)


async def test_what_cant_be_read_fails_in_plain_words(env):
    make, *_ = env
    worker, agent, _ = make(info={**INFO, "is_live": True})
    worker.start("https://youtu.be/IHZwWFHWa-w", CONVERSATION)
    queued = worker.queue.get_nowait()
    worker.queue.put_nowait(queued)

    async def once():  # the worker's loop, for one video
        vid = await worker.queue.get()
        try:
            await worker.process(worker.store.get(vid))
        except VideoError as e:
            await worker._failed(worker.store.get(vid), str(e))
    await once()
    v = worker.store.get(queued)
    assert v["status"] == "failed" and "live stream" in v["error"]
    last = agent.visible_history(CONVERSATION)[-1]
    assert last["text"].startswith("I couldn't read How neural networks learn. It's a live stream")
    assert last["attachments"][0]["videos"][0]["error"] == v["error"]

    worker, *_ = make(info={**INFO, "duration": 5 * 3600})
    with pytest.raises(VideoError, match="up to 4 hours"):
        await worker.process(worker.start("https://youtu.be/IHZwWFHWa-w", CONVERSATION))
    with pytest.raises(ValueError):
        worker.start("https://vimeo.com/1", CONVERSATION)


def test_the_card_merges_and_only_aide_and_professor_read_videos():
    a = {"type": "videos", "videos": [{"id": "v_1", "status": "queued"}]}
    b = {"type": "videos", "videos": [{"id": "v_1", "status": "ready"}]}
    assert _merge([a, b]) == [{"type": "videos", "videos": [{"id": "v_1", "status": "ready"}]}]
    who = {a for a, d in AGENTS.items() if "summarize_video" in d.tools}
    assert who == {"aide", "professor"}
    youtube, = [c for c in connectors(list(AGENTS["aide"].tools)) if c["id"] == "youtube"]
    assert youtube["name"] == "YouTube"


async def test_the_api_shares_a_video_into_a_new_chat(env):
    make, db, photos = env
    worker, agent, _ = make(json.dumps(BRIEF), '{"keep": [1]}')
    client = TestClient(create_app(agent, ReminderStore(db.conn), None, ROME, "t", videos=worker))
    assert client.post("/v1/videos", json={"url": "https://vimeo.com/1"}, headers=AUTH).status_code == 400
    got = client.post("/v1/videos", json={"url": "Look https://youtu.be/IHZwWFHWa-w", "question": "Is it hard?"},
                      headers=AUTH).json()
    chat, video = got["conversation_id"], got["video"]
    assert chat.startswith("c_") and video["status"] == "queued" and video["question"] == "Is it hard?"
    assert db.app_conversation(chat)["agent"] == "aide"
    history = client.get("/v1/history", params={"conversation_id": chat}, headers=AUTH).json()["messages"]
    assert history[0]["role"] == "user" and history[0]["text"] == "https://youtu.be/IHZwWFHWa-w\n\nIs it hard?"
    assert history[1]["attachments"][0]["videos"][0]["id"] == video["id"]

    await worker.process(worker.store.get(worker.queue.get_nowait()))
    assert db.app_conversation(chat)["title"] == "How neural networks learn"
    history = client.get("/v1/history", params={"conversation_id": chat}, headers=AUTH).json()["messages"]
    # One card, on the brief; the "on it" line before it shows none.
    assert [len(m["attachments"]) for m in history] == [0, 0, 1]
    assert history[2]["attachments"][0]["videos"][0]["status"] == "ready"

    listed = client.get("/v1/videos", params={"q": "neural"}, headers=AUTH).json()
    assert listed["enabled"] and listed["videos"][0]["id"] == video["id"]
    assert client.get("/v1/videos", params={"q": "cooking"}, headers=AUTH).json()["videos"] == []
    full = client.get(f"/v1/videos/{video['id']}", headers=AUTH).json()
    assert full["tldr"] == BRIEF["tldr"] and full["moments"][0]["url"].endswith("&t=2s")
    frame = full["moments"][0]["frame"]
    assert photos.exists(frame) and full["cover"] == frame
    assert client.delete(f"/v1/videos/{video['id']}", headers=AUTH).json() == {"ok": True}
    assert not photos.exists(frame)  # its frames go with it
    assert client.get(f"/v1/videos/{video['id']}", headers=AUTH).status_code == 404
    history = client.get("/v1/history", params={"conversation_id": chat}, headers=AUTH).json()["messages"]
    assert all(not m["attachments"] for m in history)  # a deleted video's card goes


async def test_a_ready_video_is_a_page_in_the_vault(env, tmp_path):
    make, db, photos = env
    worker, agent, _ = make(json.dumps({**BRIEF, "answer": "Not very."}), '{"keep": [1]}')
    v = await worker.process(worker.start("https://youtu.be/IHZwWFHWa-w", CONVERSATION, "Is it hard?"))
    vault = Vault(tmp_path / "vault", StudyStore(db, ROME, files_dir=tmp_path / "files"))
    vault.videos, vault.photos = worker.store, photos
    assert await vault.sync() == {"written": 2, "removed": 0}
    page = (vault.folder / "Aide/Videos/How neural networks learn.md").read_text()
    frame = v["summary"]["moments"][0]["frame"]
    assert page.startswith("---\nurl: https://youtu.be/IHZwWFHWa-w\nchannel: \"3Blue1Brown\"\npublished: 2017-11-03\n")
    assert "> [!question] Is it hard?\n> Not very." in page and "## TL;DR\n" in page
    assert ("### [0:02](https://www.youtube.com/watch?v=IHZwWFHWa-w&t=2s) Recap\nThe structure of the network.\n\n"
            f"![[Aide/Videos/Frames/{frame}.jpg]]") in page
    assert "> [!quote]- Transcript\n> [0:00] Last video" in page and "automatic captions" in page
    assert (vault.folder / f"Aide/Videos/Frames/{frame}.jpg").read_bytes() == JPEG
    assert await vault.sync() == {"written": 0, "removed": 0}
    worker.store.delete(v["public_id"])  # deleted: its page and frame go
    assert await vault.sync() == {"written": 0, "removed": 2}
