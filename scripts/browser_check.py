"""What Aide's browser looks like to bot checks (#76). Read-only: public test pages and a few shops' front pages.

One variant per run, each in a throwaway profile (never data/browser/ or data/reading/):

    uv run python scripts/browser_check.py --variant phone            # as errands run now
    uv run python scripts/browser_check.py --variant desktop          # Chromium's own identity, nothing invented
    uv run python scripts/browser_check.py --variant chrome --chrome ~/browser-check/chrome/opt/google/chrome/chrome
    xvfb-run -a -s "-screen 0 1280x1024x24" uv run python scripts/browser_check.py --variant desktop-xvfb
    xvfb-run -a -s "-screen 0 1280x1024x24" uv run python scripts/browser_check.py --variant chrome-xvfb --chrome …
    uv run python scripts/browser_check.py --summary                  # summary.md over every variant run so far

Writes <out>/<variant>/results.json, a screenshot and the text of each page; <out> defaults to
~/browser-check/<today>/.
"""

import argparse
import asyncio
import json
import os
import re
import shutil
import sys
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from aide.browser import _UA, SCALE, VIEWPORT  # noqa: E402

VARIANTS = {
    "phone": {"chrome": False, "headed": False, "phone": True},
    "desktop": {"chrome": False, "headed": False, "phone": False},
    "chrome": {"chrome": True, "headed": False, "phone": False},
    "desktop-xvfb": {"chrome": False, "headed": True, "phone": False},
    "chrome-xvfb": {"chrome": True, "headed": True, "phone": False},
    "phone-xvfb": {"chrome": False, "headed": True, "phone": True},
    # Chrome under Xvfb with the leftovers fixed: workers in Italian too, the display's own screen size (not the
    # page's), and the GPU asked for instead of SwiftShader.
    "chrome-xvfb-tuned": {"chrome": True, "headed": True, "phone": False, "tuned": True},
}

# Public bot-test pages: (name, url, seconds to let it finish, words that mark a line worth keeping)
TESTS = [
    ("sannysoft", "https://bot.sannysoft.com/", 6, None),
    ("creepjs", "https://abrahamjuliot.github.io/creepjs/", 25,
     r"headless|stealth|like headless|bot|lies|trust|platform|userAgent|webgl|gpu|worker"),
    ("pixelscan", "https://pixelscan.net/fingerprint-check", 25,
     r"consisten|automat|mask|headless|webdriver|navigator|platform|user ?agent|webgl|time ?zone|spoof|detected|ok"),
    ("pixelscan-bot", "https://pixelscan.net/bot-check", 20,
     r"bot|human|automat|headless|webdriver|cdp|detected|passed|failed"),
    ("browserscan", "https://www.browserscan.net/bot-detection", 20,
     r"normal|robot|bot|webdriver|headless|cdp|automat|selenium|playwright|puppeteer|user ?agent|platform|navigator"),
    ("browserleaks-hints", "https://browserleaks.com/client-hints", 8,
     r"sec-ch|platform|mobile|model|brand|version|architecture|bitness|user-agent|form"),
    ("httpbin-headers", "https://httpbin.org/headers", 2, None),
    # Google's reCAPTCHA v3 score for this browser (0.1 a bot … 0.9 a person): what Glovo's login is guarded by.
    ("recaptcha-score", "https://antcpt.com/score_detector/", 12, r"score|0\.\d"),
]

# Errand sites, front pages only. A challenge page is what a refusal looks like.
SITES = [
    ("glovo", "https://glovoapp.com/it/it/torino/"),
    ("amazon", "https://www.amazon.it/s?k=cavo+usb-c"),
    ("nike", "https://www.nike.com/it/"),
    ("trenitalia", "https://www.trenitalia.com/it.html"),
    ("google", "https://www.google.com/search?q=meteo+torino&hl=it"),
]
# Matched against what shows (title, text, address), not the HTML: a reCAPTCHA or Turnstile script sits on many
# ordinary pages. The HTML markers only appear on a challenge.
CHALLENGES = [
    ("cloudflare", r"just a moment|checking your browser|verify you are human", r"/cdn-cgi/challenge-platform/h/|cf-chl-"),
    ("datadome", r"$^", r"geo\.captcha-delivery\.com|ct\.captcha-delivery\.com"),
    ("akamai", r"access denied|you don't have permission to access", r"errors\.edgesuite\.net"),
    ("perimeterx", r"press & hold|premi e tieni premuto", r"px-captcha"),
    ("google", r"unusual traffic|traffico insolito|/sorry/", r"$^"),
    ("generic", r"are you a robot|robot or human|sei un robot|bot detected|automated access|request blocked|"
                r"pardon our interruption", r"$^"),
]

PROBE_JS = r"""async () => {
  const n = navigator, out = {};
  out.userAgent = n.userAgent; out.platform = n.platform; out.vendor = n.vendor; out.webdriver = n.webdriver;
  out.languages = n.languages; out.hardwareConcurrency = n.hardwareConcurrency; out.deviceMemory = n.deviceMemory;
  out.maxTouchPoints = n.maxTouchPoints; out.pdfViewerEnabled = n.pdfViewerEnabled;
  out.plugins = Array.from(n.plugins || []).map(p => p.name); out.mimeTypes = (n.mimeTypes || []).length;
  out.screen = {width: screen.width, height: screen.height, availWidth: screen.availWidth,
    availHeight: screen.availHeight, colorDepth: screen.colorDepth, dpr: devicePixelRatio,
    outer: [outerWidth, outerHeight], inner: [innerWidth, innerHeight], screenX, screenY};
  out.timezone = Intl.DateTimeFormat().resolvedOptions().timeZone; out.locale = Intl.DateTimeFormat().resolvedOptions().locale;
  out.windowChrome = typeof window.chrome; out.chromeKeys = window.chrome ? Object.keys(window.chrome) : [];
  try { out.notifications = Notification.permission + ' / ' + (await n.permissions.query({name: 'notifications'})).state; }
  catch (e) { out.notifications = String(e); }
  out.connectionRtt = n.connection ? n.connection.rtt : null;
  out.touchEvent = 'ontouchstart' in window;
  out.matchPointer = {coarse: matchMedia('(pointer: coarse)').matches, fine: matchMedia('(pointer: fine)').matches,
    hover: matchMedia('(hover: hover)').matches};
  if (n.userAgentData) {
    out.uaData = {brands: n.userAgentData.brands, mobile: n.userAgentData.mobile, platform: n.userAgentData.platform};
    try { out.uaHigh = await n.userAgentData.getHighEntropyValues(['architecture', 'bitness', 'model',
      'platformVersion', 'fullVersionList', 'uaFullVersion', 'wow64', 'formFactors']); }
    catch (e) { out.uaHigh = String(e); }
  }
  const gl = document.createElement('canvas').getContext('webgl');
  if (gl) {
    const d = gl.getExtension('WEBGL_debug_renderer_info');
    out.webgl = {vendor: gl.getParameter(gl.VENDOR), renderer: gl.getParameter(gl.RENDERER),
      unmaskedVendor: d && gl.getParameter(d.UNMASKED_VENDOR_WEBGL),
      unmaskedRenderer: d && gl.getParameter(d.UNMASKED_RENDERER_WEBGL)};
  } else out.webgl = null;
  // Installed fonts, by width against the generic fallbacks.
  const probe = document.createElement('span'); probe.textContent = 'mmmmmmmmmmlli10OO'; probe.style.fontSize = '72px';
  document.body.appendChild(probe);
  const width = f => { probe.style.fontFamily = f; return probe.offsetWidth; };
  const base = ['monospace', 'serif', 'sans-serif'].map(width);
  const fonts = ['Arial', 'Helvetica', 'Times New Roman', 'Courier New', 'Verdana', 'Georgia', 'Roboto', 'Noto Sans',
    'DejaVu Sans', 'Liberation Sans', 'Ubuntu', 'Cantarell', 'Segoe UI', 'Helvetica Neue', 'Droid Sans',
    'Noto Color Emoji', 'Calibri', 'Tahoma'];
  out.fonts = fonts.filter(f => ['monospace', 'serif', 'sans-serif'].some((g, i) => width(`"${f}", ${g}`) !== base[i]));
  probe.remove();
  // A dedicated worker: what it says, and the headers its fetch carries.
  const src = `self.onmessage = async () => { const n = navigator; let h = null, r = null;
    try { h = n.userAgentData && await n.userAgentData.getHighEntropyValues(['platform', 'platformVersion', 'model', 'fullVersionList']); } catch (e) { h = String(e); }
    try { r = (await (await fetch('https://httpbin.org/headers')).json()).headers; } catch (e) { r = String(e); }
    postMessage({userAgent: n.userAgent, platform: n.platform,
      uaData: n.userAgentData && {brands: n.userAgentData.brands, mobile: n.userAgentData.mobile, platform: n.userAgentData.platform},
      uaHigh: h, fetchHeaders: r}); };`;
  try {
    const w = new Worker(URL.createObjectURL(new Blob([src], {type: 'text/javascript'})));
    out.worker = await new Promise((ok, no) => { w.onmessage = e => ok(e.data); w.onerror = e => no(e.message);
      setTimeout(() => no('timeout'), 15000); w.postMessage(1); });
  } catch (e) { out.worker = String(e); }
  // The page's own fetch, for its headers.
  try { out.fetchHeaders = (await (await fetch('https://httpbin.org/headers')).json()).headers; }
  catch (e) { out.fetchHeaders = String(e); }
  return out;
}"""

FRAME_JS = r"""async () => { const n = navigator; let h = null;
  try { h = n.userAgentData && await n.userAgentData.getHighEntropyValues(['platform', 'platformVersion', 'model', 'fullVersionList']); } catch (e) { h = String(e); }
  return {userAgent: n.userAgent, platform: n.platform, webdriver: n.webdriver,
    uaData: n.userAgentData && {brands: n.userAgentData.brands, mobile: n.userAgentData.mobile, platform: n.userAgentData.platform},
    uaHigh: h, body: document.body ? document.body.innerText.slice(0, 3000) : ''}; }"""

SANNYSOFT_JS = r"""() => Array.from(document.querySelectorAll('tr')).map(tr => Array.from(tr.cells)).filter(cs => cs.length >= 2)
  .map(cs => ({name: cs[0].innerText.trim(), value: cs[cs.length - 1].innerText.trim().slice(0, 200),
    result: (cs[cs.length - 1].className || '').trim()}))"""


def launch_options(variant: dict, chrome: str | None) -> dict:
    opts = {"headless": not variant["headed"], "viewport": VIEWPORT, "screen": VIEWPORT, "device_scale_factor": SCALE,
            "locale": "it-IT", "timezone_id": "Europe/Rome",
            "args": ["--disable-blink-features=AutomationControlled"],
            "ignore_default_args": ["--enable-automation"]}
    if variant["chrome"]:
        if not chrome or not Path(chrome).exists():
            sys.exit(f"--chrome must point at Google Chrome's binary (got {chrome!r})")
        opts["executable_path"] = chrome
    else:
        opts["channel"] = "chromium"
    if variant["phone"]:
        opts.update(is_mobile=True, has_touch=True)
    if variant.get("tuned"):
        opts["screen"] = {"width": 1280, "height": 1024}  # the display's (xvfb-run -s), not the page's
        opts["args"] += ["--lang=it-IT", "--accept-lang=it-IT", "--ignore-gpu-blocklist", "--enable-gpu-rasterization",
                         "--use-angle=vulkan", "--enable-features=Vulkan"]
    return opts


async def version(executable: str) -> str:
    proc = await asyncio.create_subprocess_exec(executable, "--version", stdout=asyncio.subprocess.PIPE,
                                                stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    return out.decode().strip()


def keep_lines(text: str, words: str | None, limit: int = 80) -> list[str]:
    lines = [" ".join(line.split()) for line in text.splitlines()]
    lines = [line for line in lines if line]
    if words:
        rx = re.compile(words, re.I)
        lines = [line for line in lines if rx.search(line)]
    seen, out = set(), []
    for line in lines:
        if line not in seen:
            seen.add(line)
            out.append(line[:300])
    return out[:limit]


async def run(name: str, out: Path, chrome: str | None) -> None:
    from playwright.async_api import async_playwright

    variant = VARIANTS[name]
    dest = out / name
    dest.mkdir(parents=True, exist_ok=True)
    profile = Path.home() / "browser-check" / "profiles" / name
    shutil.rmtree(profile, ignore_errors=True)
    opts = launch_options(variant, chrome)
    results: dict = {"variant": name, "display": os.environ.get("DISPLAY")}
    async with async_playwright() as pw:
        executable = opts.get("executable_path") or pw.chromium.executable_path
        results["browser"] = await version(executable)
        if variant["phone"]:
            opts["user_agent"] = _UA.format(v=re.search(r"(\d+)\.\d+\.\d+\.\d+", results["browser"]).group(1) + ".0.0.0")
        results["launch"] = {k: v for k, v in opts.items() if k not in ("viewport", "screen")}
        context = await pw.chromium.launch_persistent_context(str(profile), **opts)
        context.set_default_navigation_timeout(45_000)
        page = context.pages[0] if context.pages else await context.new_page()

        # Every request's real headers, by kind (document, subframe, worker fetch).
        seen_headers: list[dict] = []

        async def record(request):
            try:
                headers = await request.all_headers()
            except Exception:
                return
            keep = {k: v for k, v in headers.items() if k == "user-agent" or k.startswith("sec-ch-")}
            frame = None
            try:
                frame = request.frame.url if request.frame else None
            except Exception:
                frame = "(worker)"
            seen_headers.append({"url": request.url[:120], "type": request.resource_type, "frame": frame,
                                 "headers": keep})

        context.on("request", lambda r: asyncio.ensure_future(record(r)))

        # The own probe, on example.com with a cross-site frame.
        try:
            await page.goto("https://example.com/", wait_until="load")
            await page.evaluate("""() => { const f = document.createElement('iframe');
              f.src = 'https://httpbin.org/headers'; f.width = 300; f.height = 200; document.body.appendChild(f); }""")
            await asyncio.sleep(3)
            results["probe"] = await page.evaluate(PROBE_JS)
            frames = [f for f in page.frames if "httpbin.org" in f.url]
            results["cross_site_frame"] = await frames[0].evaluate(FRAME_JS) if frames else "no frame"
        except Exception as e:
            results["probe_error"] = repr(e)
        await asyncio.sleep(1)
        results["request_headers"] = seen_headers[:]

        results["tests"] = {}
        for test, url, wait, words in TESTS:
            got: dict = {"url": url}
            try:
                response = await page.goto(url, wait_until="domcontentloaded")
                got["status"] = response.status if response else None
                await asyncio.sleep(wait)
                if test == "sannysoft":
                    rows = await page.evaluate(SANNYSOFT_JS)
                    got["failed"] = [r for r in rows if re.search(r"failed|warn", r["result"], re.I)]
                    got["rows"] = rows
                text = await page.evaluate("() => document.body ? document.body.innerText : ''")
                (dest / f"{test}.txt").write_text(text)
                got["lines"] = keep_lines(text, words)
                await page.screenshot(path=str(dest / f"{test}.png"), full_page=True, timeout=20_000)
            except Exception as e:
                got["error"] = repr(e)
            results["tests"][test] = got
            print(f"{name}: {test} done", flush=True)

        results["sites"] = {}
        for site, url in SITES:
            got = {"url": url}
            try:
                response = await page.goto(url, wait_until="domcontentloaded")
                got["status"] = response.status if response else None
                await asyncio.sleep(6)
                got["final_url"] = page.url
                got["title"] = await page.title()
                html = await page.content()
                text = await page.evaluate("() => document.body ? document.body.innerText : ''")
                got["text_length"] = len(text)
                shown = f"{got['title']}\n{page.url}\n{text}"
                got["challenge"] = [kind for kind, seen, marker in CHALLENGES
                                    if re.search(seen, shown, re.I) or re.search(marker, html, re.I)]
                got["first_lines"] = keep_lines(text, None, 12)
                (dest / f"site-{site}.txt").write_text(text)
                await page.screenshot(path=str(dest / f"site-{site}.png"), timeout=20_000)
            except Exception as e:
                got["error"] = repr(e)
            results["sites"][site] = got
            print(f"{name}: {site} done", flush=True)

        # Glovo's login: where every Glovo errand stopped. Opens the login view and reads it; types nothing.
        got = {}
        try:
            await page.goto("https://glovoapp.com/it/it/torino/", wait_until="domcontentloaded")
            await asyncio.sleep(4)
            for label in ("Rifiuta", "Rifiuta tutto", "Reject"):  # the cookie banner, the most private choice
                button = page.get_by_role("button", name=label, exact=True)
                if await button.count():
                    await button.first.click()
                    break
            await page.get_by_text("Login", exact=True).filter(visible=True).first.click(timeout=8_000)
            await asyncio.sleep(6)
            got["url"] = page.url
            text = await page.evaluate("() => document.body ? document.body.innerText : ''")
            got["lines"] = keep_lines(text, r"accedi|login|password|email|telefono|google|apple|facebook|metod|"
                                            r"errore|error|riprova|robot|captcha|verific", 30)
            (dest / "glovo-login.txt").write_text(text)
            await page.screenshot(path=str(dest / "glovo-login.png"), timeout=20_000)
        except Exception as e:
            got["error"] = repr(e)
        results["glovo_login"] = got
        print(f"{name}: glovo login done", flush=True)

        await context.close()
    (dest / "results.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(f"wrote {dest}")


def short(value) -> str:
    if value is None:
        return "—"
    if isinstance(value, (dict, list)):
        value = json.dumps(value, ensure_ascii=False)
    return str(value).replace("|", "\\|").replace("\n", " ")[:160]


def summary(out: Path) -> None:
    runs = {}
    for name in VARIANTS:
        f = out / name / "results.json"
        if f.exists():
            runs[name] = json.loads(f.read_text())
    if not runs:
        sys.exit(f"no results under {out}")
    names = list(runs)
    rows: list[tuple[str, list[str]]] = []

    def row(label, get):
        cells = []
        for n in names:
            try:
                cells.append(short(get(runs[n])))
            except Exception:
                cells.append("—")
        rows.append((label, cells))

    row("browser", lambda r: r["browser"])
    row("userAgent", lambda r: r["probe"]["userAgent"])
    row("platform", lambda r: r["probe"]["platform"])
    row("webdriver", lambda r: r["probe"]["webdriver"])
    row("uaData platform / mobile", lambda r: f'{r["probe"]["uaData"]["platform"]} / {r["probe"]["uaData"]["mobile"]}')
    row("uaData brands", lambda r: [b["brand"] for b in r["probe"]["uaData"]["brands"]])
    row("high-entropy model / platformVersion", lambda r: f'{r["probe"]["uaHigh"].get("model")!r} / '
                                                         f'{r["probe"]["uaHigh"].get("platformVersion")}')
    row("plugins", lambda r: len(r["probe"]["plugins"]))
    row("screen / outer / inner", lambda r: f'{r["probe"]["screen"]["width"]}x{r["probe"]["screen"]["height"]} / '
                                            f'{r["probe"]["screen"]["outer"]} / {r["probe"]["screen"]["inner"]}')
    row("touch points / pointer", lambda r: f'{r["probe"]["maxTouchPoints"]} / {r["probe"]["matchPointer"]}')
    row("WebGL", lambda r: f'{r["probe"]["webgl"]["unmaskedVendor"]} · {r["probe"]["webgl"]["unmaskedRenderer"]}')
    row("fonts", lambda r: r["probe"]["fonts"])
    row("notifications", lambda r: r["probe"]["notifications"])
    row("window.chrome keys", lambda r: r["probe"]["chromeKeys"])
    row("worker userAgent", lambda r: r["probe"]["worker"]["userAgent"])
    row("worker platform / uaData", lambda r: f'{r["probe"]["worker"]["platform"]} / '
                                              f'{r["probe"]["worker"]["uaData"]}')
    row("worker fetch UA", lambda r: r["probe"]["worker"]["fetchHeaders"].get("User-Agent"))
    row("worker fetch Sec-Ch-Ua-Platform", lambda r: r["probe"]["worker"]["fetchHeaders"].get("Sec-Ch-Ua-Platform"))
    row("page fetch Sec-Ch-Ua-Platform / Mobile", lambda r: f'{r["probe"]["fetchHeaders"].get("Sec-Ch-Ua-Platform")} / '
                                                            f'{r["probe"]["fetchHeaders"].get("Sec-Ch-Ua-Mobile")}')
    row("cross-site frame UA", lambda r: r["cross_site_frame"]["userAgent"])
    row("cross-site frame platform", lambda r: f'{r["cross_site_frame"]["platform"]} / '
                                               f'{r["cross_site_frame"]["uaData"]}')
    row("sannysoft failed", lambda r: [f["name"] for f in r["tests"]["sannysoft"].get("failed", [])] or "none")
    for test in ("creepjs", "pixelscan", "pixelscan-bot", "browserscan", "recaptcha-score"):
        row(f"{test} (first lines)", lambda r, t=test: r["tests"][t].get("error") or r["tests"][t]["lines"][:6])
    for site, _ in SITES:
        row(f"site {site}", lambda r, s=site: r["sites"][s].get("error") or
            f'{r["sites"][s]["status"]} · {r["sites"][s]["challenge"] or "no challenge"} · '
            f'{r["sites"][s]["title"][:50]}')

    row("glovo login", lambda r: r["glovo_login"].get("error") or r["glovo_login"]["lines"][:8])

    lines = [f"# Browser check, {out.name}", "", "| | " + " | ".join(names) + " |",
             "|---|" + "---|" * len(names)]
    lines += [f"| {label} | " + " | ".join(cells) + " |" for label, cells in rows]
    (out / "summary.md").write_text("\n".join(lines) + "\n")
    print(out / "summary.md")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--variant", choices=list(VARIANTS))
    parser.add_argument("--out", type=Path, default=Path.home() / "browser-check" / date.today().isoformat())
    parser.add_argument("--chrome", default=str(Path.home() / "browser-check/chrome/opt/google/chrome/chrome"))
    parser.add_argument("--summary", action="store_true")
    a = parser.parse_args()
    if a.summary:
        summary(a.out)
    elif a.variant:
        if VARIANTS[a.variant]["headed"] and not os.environ.get("DISPLAY"):
            sys.exit("a headed variant needs a display: run it under xvfb-run")
        asyncio.run(run(a.variant, a.out, a.chrome))
    else:
        parser.error("--variant or --summary")


if __name__ == "__main__":
    main()
