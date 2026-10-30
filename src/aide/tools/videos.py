"""The agents' YouTube tools (videos.py): read a video in the background, look into one already read, list them."""

from typing import Callable

from ..study import stamp
from ..videos import VideoWorker
from . import Tool, ToolOutput
from .search import _obj


def video_tools(worker: VideoWorker, current_conversation: Callable[[], str | None]) -> list[Tool]:
    store = worker.store

    async def summarize_video(url: str, question: str | None = None) -> ToolOutput:
        v = worker.start(url, current_conversation(), question)
        return ToolOutput(f"Video {v['public_id']} is being read in the background (a few minutes for a long one); "
                          "the brief comes to this chat by itself, with its card. Tell the user in a line, and don't "
                          "write a summary yourself.",
                          {"type": "videos", "videos": [store.card(v)]})

    async def read_video(video: str, query: str | None = None) -> ToolOutput | str:
        out = worker.read(video, query)
        v = store.get(video)
        return ToolOutput(out, {"type": "videos", "videos": [store.card(v)]}) if v and not query else out

    async def list_videos(query: str | None = None) -> str:
        rows = store.search(query, limit=15)
        if not rows:
            return "No videos" + (f" match {query!r}." if query else " yet.")
        return "\n".join(f"{v['public_id']} {v['created_at'][:10]} {v['title'] or v['url']}"
                         + (f" ({v['channel']}, {stamp(v['duration'])})" if v["duration"] else "")
                         + ("" if v["status"] == "ready" else f": {v['status']}") for v in rows)

    return [
        Tool("summarize_video", "Read a YouTube video for the user (any youtube.com or youtu.be link): its "
             "transcript, a brief of what happens and what to know, the key moments with their times and frames. "
             "It runs in the background and posts the brief in this chat with a card. Pass what the user wants from "
             "it in `question`, if they said.",
             _obj({"url": {"type": "string"},
                   "question": {"type": ["string", "null"],
                                "description": "e.g. \"what does he say about creatine?\""}}, ["url", "question"]),
             summarize_video),
        Tool("read_video", "A video already read: its brief and the start of its transcript, or with `query` the "
             "parts of the transcript about it, with their [m:ss] times. For follow-ups on a video.",
             _obj({"video": {"type": "string", "description": "v_…"},
                   "query": {"type": ["string", "null"]}}, ["video", "query"]),
             read_video),
        Tool("list_videos", "The YouTube videos read for the user, newest first, or those matching `query`.",
             _obj({"query": {"type": ["string", "null"]}}, ["query"]), list_videos),
    ]
