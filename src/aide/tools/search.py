"""Web search and page reading through Tavily. All read-only and run immediately: web_search for a quick fact,
research for a question that needs several sources (it reads the top sites in one call), fetch_page for one page."""

import re
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
SITES = 5  # sites research reads, by default
MAX_SITES = 8
SITE_LIMIT = 2500  # what research keeps of each site: its parts closest to the question
CHUNK = 400  # research cuts a page into pieces about this long, then keeps the ones that match the question
_LINK = re.compile(r"!?\[([^\]]*)\]\([^)]*\)")


def _obj(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


def _clip(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[:limit].rstrip() + f" [… {len(text) - limit} more characters]"


def _snippet(text: str) -> str:
    text = " ".join(text.split())
    return text if len(text) <= SNIPPET_LIMIT else text[:SNIPPET_LIMIT].rstrip() + "…"


def _words(text: str) -> set[str]:
    return {w for w in re.findall(r"\w+", text.lower()) if len(w) >= 3}


def _excerpt(text: str, query: str, limit: int = SITE_LIMIT) -> str:
    """The parts of a page closest to the question, in page order, about `limit` characters. Menus and link lists
    (lines that are mostly links) go first; pieces sharing the most words with the question are kept."""
    lines = []
    for line in text.splitlines():
        plain, bare = line, line
        for _ in range(2):  # a link around an image is two deep
            plain, bare = _LINK.sub(r"\1", plain), _LINK.sub("", bare)
        plain = " ".join(plain.split())
        if len(plain) >= 25 and len(bare.strip(" *-|#>[]()")) >= 15:
            lines.append(plain)
    chunks, piece = [], ""
    for line in lines:
        if piece and len(piece) + len(line) > CHUNK:
            chunks.append(piece)
            piece = ""
        piece = f"{piece}\n{line}" if piece else line
    if piece:
        chunks.append(piece)
    asked = _words(query)
    ranked = sorted(range(len(chunks)), key=lambda i: (-len(asked & _words(chunks[i])), i))
    keep, size = set(), 0
    for i in ranked:
        if size and size + len(chunks[i]) > limit:
            break
        keep.add(i)
        size += len(chunks[i])
    out = "\n".join(chunks[i] for i in sorted(keep))
    return _clip(out, limit + CHUNK)


def _site(url: str) -> str:
    host = re.sub(r"^https?://", "", url).split("/")[0]
    return host.removeprefix("www.")


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

    async def search(self, query: str, max_results: int, topic: str, pages: bool = False) -> dict:
        """`pages`: each result also carries its page's text (`raw_content`), so one call reads them all."""
        return await self._post("/search", {"query": query, "max_results": max_results, "topic": topic,
                                            "include_answer": True, **({"include_raw_content": True} if pages else {})})

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

    async def research(query: str, sites: int | None = None) -> str:
        n = max(2, min(sites or SITES, MAX_SITES))
        found = await tavily.search(query, min(n + 2, MAX_RESULTS), "general", pages=True)
        results = found.get("results", [])
        read = [r for r in results if (r.get("raw_content") or "").strip()][:n]
        if not read:
            return await web_search(query, n)
        lines = [f"Answer (from the search, check it against the sites): {found['answer']}\n"] \
            if found.get("answer") else []
        lines.append(f"Read {len(read)} sites. What each says about it, the parts closest to the question:")
        for i, r in enumerate(read, 1):
            text = _excerpt(r["raw_content"], query) or _snippet(r.get("content", ""))
            lines.append(f"\n{i}. {r.get('title') or '(no title)'}{published(r)}\n   {r['url']}\n{text}")
        if rest := [r for r in results if r not in read]:
            lines.append("\nAlso found, not read:\n" + "\n".join(f"- {r.get('title') or r['url']}: {r['url']}"
                                                                for r in rest))
        return "\n".join(lines)

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
                  ["query"]), web_search,
             step=lambda a: f"Searching the web for \u201c{a.get('query', '')}\u201d"),
        Tool("research", f"Research a question on the web: searches and reads the top sites (default {SITES}) in "
             "one call, returning what each says, the parts closest to the question, with its link. Use it for "
             "anything that needs more than one quick fact: does X work with Y, what to buy, comparisons, how to do "
             "something, reviews, a problem to fix.",
             _obj({"query": {"type": "string", "description": "the question, as you'd search it"},
                   "sites": {"type": "integer", "description": f"2–{MAX_SITES}, default {SITES}"}},
                  ["query"]), research,
             step=lambda a: f"Reading {max(2, min(a.get('sites') or SITES, MAX_SITES))} sites on "
                            f"\u201c{a.get('query', '')}\u201d"),
        Tool("fetch_page", "Read one web page in full (as clean text), when a search snippet isn't enough.",
             _obj({"url": {"type": "string"}}, ["url"]), fetch_page,
             step=lambda a: f"Reading {_site(a.get('url', ''))}"),
    ]
