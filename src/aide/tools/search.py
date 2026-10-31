"""Web search and page reading through Tavily. Both are read-only and run immediately."""

import time
from datetime import datetime
from email.utils import parsedate_to_datetime
from zoneinfo import ZoneInfo

import httpx

from .. import usage
from . import Tool

API = "https://api.tavily.com"
MAX_RESULTS = 10
SNIPPET_LIMIT = 300  # one result in the list
PAGE_LIMIT = 12000  # a whole page from fetch_page


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def _clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit].rstrip() + f" [… {len(text) - limit} more characters]"


def _snippet(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= SNIPPET_LIMIT else text[:SNIPPET_LIMIT].rstrip() + "…"


class Tavily:
    def __init__(self, api_key: str, http: httpx.AsyncClient | None = None):
        self._key = api_key
        self._http = http or httpx.AsyncClient(timeout=30)

    async def _post(self, path: str, body: dict) -> dict:
        started = time.monotonic()
        r = await self._http.post(API + path, json=body, headers={"Authorization": f"Bearer {self._key}"})
        usage.record("tavily", path.strip("/"), ms=round((time.monotonic() - started) * 1000), ok=not r.is_error)
        if r.status_code in (401, 403):
            raise RuntimeError("Tavily rejected the API key (TAVILY_API_KEY).")
        if r.status_code in (429, 432):  # 432: plan's monthly credits used up
            raise RuntimeError("Tavily's search limit is used up for now.")
        r.raise_for_status()
        return r.json()

    async def search(self, query: str, max_results: int, topic: str) -> dict:
        return await self._post("/search", {"query": query, "max_results": max_results, "topic": topic,
                                            "include_answer": True})

    async def extract(self, url: str) -> dict:
        return await self._post("/extract", {"urls": [url]})


def search_tools(tavily: Tavily, tz: ZoneInfo) -> list[Tool]:
    def published(result: dict) -> str:
        raw = result.get("published_date")
        if not raw:
            return ""
        try:  # ISO, or the RFC 2822 form news results use ("Mon, 19 Oct 2026 08:00:00 GMT")
            dt = datetime.fromisoformat(raw)
        except ValueError:
            try:
                dt = parsedate_to_datetime(raw)
            except (TypeError, ValueError):
                return f" · {raw}"
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=ZoneInfo("UTC"))
        return f" · {dt.astimezone(tz):%a %d %b %Y %H:%M}"

    async def web_search(query: str, max_results: int | None = None, topic: str | None = None) -> str:
        found = await tavily.search(query, max(1, min(max_results or 5, MAX_RESULTS)), topic or "general")
        lines = [f"Answer: {found['answer']}\n"] if found.get("answer") else []
        for i, r in enumerate(found.get("results", []), 1):
            lines.append(f"{i}. {r.get('title') or '(no title)'}{published(r)}\n   {r['url']}\n"
                         f"   {_snippet(r.get('content', ''))}")
        return "\n".join(lines) if lines else "No results."

    async def fetch_page(url: str) -> str:
        if not url.startswith(("http://", "https://")):
            raise ValueError("give a full http(s) URL")
        found = await tavily.extract(url)
        for r in found.get("results", []):
            if text := (r.get("raw_content") or "").strip():
                return f"{r.get('url', url)}\n\n{_clip(text, PAGE_LIMIT)}"
        return f"Couldn't read {url}."

    return [
        Tool("web_search", "Search the web. Use it for anything current (news, prices, opening dates, results) or "
             "any fact you aren't sure of. Returns a short answer when there is one, then numbered results with "
             "title, URL and a snippet.",
             _obj({"query": {"type": "string"},
                   "max_results": {"type": "integer", "description": f"1–{MAX_RESULTS}, default 5"},
                   "topic": {"type": "string", "enum": ["general", "news"],
                             "description": "news for recent events and headlines; default general"}},
                  ["query"]), web_search),
        Tool("fetch_page", "Read one web page in full (as clean text), when a search snippet isn't enough.",
             _obj({"url": {"type": "string"}}, ["url"]), fetch_page),
    ]
