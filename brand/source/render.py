"""Render the brand kit's PNGs and promo images: each is a small HTML page, photographed by headless Chrome.

    python3 brand/source/render.py              # everything (needs Google Chrome; no Python packages)
    python3 brand/source/render.py promo/team   # just the ones whose path starts with that

The SVGs come from pebble.py (run it first after changing the geometry); the screenshots from brand/screenshots/.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

import pebble
from pebble import BODY, EXPRESSIONS, FAMILY, SAND, SLATE, family_path

BRAND = Path(__file__).resolve().parent.parent
SHOTS = BRAND / "screenshots"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

INK = SLATE
DARK = "#1F2726"     # Slate at night: the promo images' dark ground
SAGE = "#94ADA8"     # Pebble on the dark app icon (AppIcon.icon)
FONT = "-apple-system, 'SF Pro Display', 'Helvetica Neue', sans-serif"

ROLES = {
    "aide": "Talks to all of them",
    "secretary": "Calendar, reminders and mail",
    "professor": "Study and lectures",
    "coach": "Sleep, training, food and habits",
    "finance": "Money and budgets",
}
FACES = {
    "calm": "The logo. At rest",
    "awake": "Listening, replying",
    "thinking": "Working on something",
    "happy": "Done",
    "sleeping": "Offline, quiet hours",
}


# -- pieces ----------------------------------------------------------------------------------------------------


def mark(d: str, fill: str, size: float, shade: bool = False, scale: float = 1.0) -> str:
    """An inline SVG of one path. `shade` lights it from above as the app does (Figure.swift, `shaded()`)."""
    t = f' transform="translate(128 128) scale({scale}) translate(-128 -128)"' if scale != 1 else ""
    gid = f"g{abs(hash((d, fill, size))) % 10**8}"
    grad = (
        f'<defs><linearGradient id="{gid}" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="#fff" stop-opacity=".3"/><stop offset=".55" stop-color="#fff" stop-opacity="0"/>'
        f'<stop offset="1" stop-color="#000" stop-opacity=".12"/></linearGradient></defs>'
        f'<path fill="url(#{gid})" fill-rule="evenodd"{t} d="{d}"/>'
        if shade else ""
    )
    return (
        f'<svg viewBox="0 0 256 256" width="{size}" height="{size}" style="display:block;overflow:visible">'
        f'<path fill="{fill}" fill-rule="evenodd"{t} d="{d}"/>{grad}</svg>'
    )


def pebble_d(face: str = "calm") -> str:
    return BODY + EXPRESSIONS[face]


def phone(name: str, width: float, tilt: float = 0, extra: str = "") -> str:
    """An iPhone screenshot in a thin dark bezel."""
    src = (SHOTS / "iphone" / f"{name}.webp").as_uri()
    pad = width * 0.035
    return (
        f'<div class="phone" style="width:{width}px;padding:{pad}px;border-radius:{width * 0.16}px;'
        f'transform:rotate({tilt}deg);{extra}"><img src="{src}" style="width:100%;display:block;'
        f'border-radius:{width * 0.13}px"></div>'
    )


def window(name: str, width: float, extra: str = "") -> str:
    src = (SHOTS / "mac" / f"{name}.webp").as_uri()
    return f'<img class="window" src="{src}" style="width:{width}px;{extra}">'


def wordmark(size: float, color: str) -> str:
    return (f'<span style="font:700 {size}px/1 {FONT};letter-spacing:-0.035em;color:{color}">Aide</span>')


BASE_CSS = f"""
* {{ box-sizing: border-box; margin: 0; }}
html, body {{ width: 100%; height: 100%; background: transparent; overflow: hidden; }}
body {{ font-family: {FONT}; -webkit-font-smoothing: antialiased; }}
.phone {{ background: #0B0B0C; box-shadow: 0 0 0 1.5px #3A3A3D inset, 0 40px 80px -20px rgba(20,26,25,.45),
          0 12px 30px -10px rgba(20,26,25,.35); }}
.window {{ display: block; filter: drop-shadow(0 30px 50px rgba(0,0,0,.35)) drop-shadow(0 8px 16px rgba(0,0,0,.25)); }}
.over {{ font: 600 13px/1 {FONT}; letter-spacing: .12em; text-transform: uppercase; }}
"""

SAND_BG = f"background: radial-gradient(120% 90% at 30% 20%, #F5F0E7 0%, {SAND} 55%, #E2D9C8 100%);"
DARK_BG = f"background: radial-gradient(110% 90% at 50% 0%, #34413F 0%, {DARK} 60%, #161C1B 100%);"


# -- the images ------------------------------------------------------------------------------------------------
# Each is (path under brand/, width, height, device scale, html body).


def logo_pngs():
    for name, fill in [("pebble-slate", SLATE), ("pebble-black", "#000"), ("pebble-white", "#fff")]:
        yield f"png/{name}.png", 512, 512, 2, mark(pebble_d(), fill, 512)
    yield "png/avatar.png", 512, 512, 2, f'<div style="background:{SAND}">{mark(pebble_d(), SLATE, 512, scale=1.2)}</div>'
    for face in EXPRESSIONS:
        yield (f"png/expressions/{face}.png", 256, 256, 2,
               f'<div style="background:{SAND}">{mark(pebble_d(face), SLATE, 256, scale=1.2)}</div>')
    for agent, (name, colour, *_r) in FAMILY.items():
        yield f"png/family/{agent}.png", 256, 256, 2, mark(family_path(agent), colour, 256, shade=True)
    # The app icon, flat (iOS and macOS add the glass): Slate on Sand in light, sage on near-black in dark.
    for look, bg, fill in [("light", f"linear-gradient(#F4EFE6, {SAND} 60%, #E3DACA)", SLATE),
                           ("dark", "linear-gradient(#2A2D2D, #121414)", SAGE)]:
        yield (f"png/app-icon-{look}.png", 512, 512, 2,
               f'<div style="margin:16px;width:480px;height:480px;border-radius:108px;background:{bg};'
               f'box-shadow:0 0 0 1px rgba(0,0,0,.06) inset">'
               f'<div style="filter:drop-shadow(0 6px 10px rgba(0,0,0,.18))">{mark(pebble_d(), fill, 480, scale=1.2)}'
               f'</div></div>')
    for look, colour in [("slate", SLATE), ("white", "#fff")]:
        yield (f"png/lockup-{look}.png", 760, 256, 2,
               f'<div style="display:flex;align-items:center;gap:8px;height:256px">{mark(pebble_d(), colour, 256)}'
               f'{wordmark(150, colour)}</div>')


def promo():
    # GitHub's social preview (Settings → General → Social preview): 1280 × 640, under 1 MB.
    yield "promo/social-preview.png", 1280, 640, 1, f"""
<div style="position:absolute;inset:0;{SAND_BG}"></div>
<div style="position:absolute;left:96px;top:0;bottom:0;width:560px;display:flex;flex-direction:column;justify-content:center">
  <div style="display:flex;align-items:center;gap:6px;margin-left:-14px">{mark(pebble_d(), INK, 150)}{wordmark(112, INK)}</div>
  <p style="margin-top:22px;font:500 30px/1.32 {FONT};color:{INK};letter-spacing:-0.01em;max-width:520px">
    A personal assistant and its team, for one person, through chat.</p>
  <p style="margin-top:18px;font:400 21px/1.45 {FONT};color:rgba(52,65,63,.62)">
    Calendar, mail, study, health, food and money.<br>On your own server, iPhone and Mac.</p>
  <div style="display:flex;gap:6px;margin-top:30px;margin-left:-6px">
    {''.join(mark(family_path(a), FAMILY[a][1], 46, shade=True) for a in FAMILY)}</div>
</div>
<div style="position:absolute;left:820px;top:96px">{phone("health", 250, 6)}</div>
<div style="position:absolute;left:676px;top:52px">{phone("study", 262, -4)}</div>
"""

    yield "promo/iphone.png", 1600, 900, 2, f"""
<div style="position:absolute;inset:0;{SAND_BG}"></div>
<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;gap:28px;padding-top:10px">
  {phone("food", 236, 0, "margin-top:120px")}
  {phone("health", 262, 0, "margin-top:40px")}
  {phone("study", 290)}
  {phone("course", 262, 0, "margin-top:40px")}
  {phone("screen", 236, 0, "margin-top:120px")}
</div>
<div style="position:absolute;left:48px;bottom:40px;display:flex;align-items:center;gap:2px">
  {mark(pebble_d(), INK, 64)}{wordmark(44, INK)}</div>
"""

    yield "promo/mac.png", 1400, 860, 2, f"""
<div style="position:absolute;inset:0;{DARK_BG}"></div>
<div style="position:absolute;left:96px;top:70px">{window("health", 720, "opacity:.96")}</div>
<div style="position:absolute;left:520px;top:300px">{window("study", 800)}</div>
<div style="position:absolute;left:96px;bottom:70px;width:380px">
  <div style="display:flex;align-items:center;gap:2px;margin-left:-10px">{mark(pebble_d(), SAND, 84)}{wordmark(60, SAND)}</div>
  <p style="margin-top:14px;font:400 20px/1.45 {FONT};color:rgba(236,229,216,.7)">
    The same app on the Mac: a glass sidebar, the menu bar Pebble, and Screen Time it enforces itself.</p>
</div>
"""

    cells = "".join(
        f"""<div style="flex:1;display:flex;flex-direction:column;align-items:center;text-align:center">
          {mark(family_path(a), FAMILY[a][1], 170, shade=True, scale=1.1)}
          <div style="margin-top:18px;font:700 26px/1 {FONT};color:{FAMILY[a][1]};letter-spacing:-0.01em">{FAMILY[a][0]}</div>
          <div style="margin-top:10px;font:400 17px/1.35 {FONT};color:rgba(52,65,63,.6);max-width:250px">{ROLES[a]}</div>
        </div>"""
        for a in FAMILY
    )
    yield "promo/team.png", 1400, 440, 2, f"""
<div style="position:absolute;inset:0;{SAND_BG}"></div>
<div class="over" style="position:absolute;top:52px;width:100%;text-align:center;color:rgba(52,65,63,.55)">The team</div>
<div style="position:absolute;left:40px;right:40px;top:100px;display:flex">{cells}</div>
"""

    tiles = "".join(
        f"""<div style="flex:1;display:flex;flex-direction:column;align-items:center">
          <div style="border-radius:44px;overflow:hidden;background:{SAND};box-shadow:0 1px 0 rgba(0,0,0,.04)">
            {mark(pebble_d(f), SLATE, 196, scale=1.2)}</div>
          <div style="margin-top:20px;font:700 22px/1 {FONT};color:{SAND};text-transform:capitalize">{f}</div>
          <div style="margin-top:8px;font:400 16px/1.3 {FONT};color:rgba(236,229,216,.55)">{FACES[f]}</div>
        </div>"""
        for f in EXPRESSIONS
    )
    yield "promo/faces.png", 1400, 410, 2, f"""
<div style="position:absolute;inset:0;{DARK_BG}"></div>
<div class="over" style="position:absolute;top:50px;width:100%;text-align:center;color:rgba(236,229,216,.5)">Pebble's faces</div>
<div style="position:absolute;left:60px;right:60px;top:104px;display:flex">{tiles}</div>
"""

    swatches = [("Slate", SLATE, "Pebble, ink, buttons", "#fff"), ("Sand", SAND, "Tiles, eyes on Slate", SLATE),
                ("Sage", SAGE, "Pebble at night", SLATE)] + [
        (FAMILY[a][0], FAMILY[a][1], ROLES[a].split(",")[0].split(" and ")[0], "#fff") for a in FAMILY if a != "aide"]

    def rgb(h):
        return ", ".join(str(int(h[i:i + 2], 16)) for i in (1, 3, 5))

    chips = "".join(
        f"""<div style="flex:1;border-radius:22px;overflow:hidden;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.06)">
          <div style="height:150px;background:{c};{'box-shadow:0 0 0 1px rgba(0,0,0,.06) inset;' if c == SAND else ''}
               display:flex;align-items:flex-end;padding:16px;font:700 20px/1 {FONT};color:{ink}">{n}</div>
          <div style="padding:14px 16px 16px;font:500 15px/1.5 ui-monospace,Menlo,monospace;color:{INK}">{c.upper()}
            <div style="color:rgba(52,65,63,.5)">{rgb(c)}</div>
            <div style="font:400 14px/1.3 {FONT};color:rgba(52,65,63,.6);margin-top:6px">{use}</div></div>
        </div>"""
        for n, c, use, ink in swatches
    )
    yield "promo/palette.png", 1400, 344, 2, f"""
<div style="position:absolute;inset:0;background:#F6F3EE"></div>
<div style="position:absolute;left:48px;right:48px;top:48px;display:flex;gap:16px">{chips}</div>
"""


# -- rendering -------------------------------------------------------------------------------------------------


def render(rel: str, w: int, h: int, scale: int, body: str, tmp: Path) -> None:
    out = BRAND / rel
    out.parent.mkdir(parents=True, exist_ok=True)
    page = tmp / (rel.replace("/", "_") + ".html")
    page.write_text(f"<!doctype html><meta charset=utf-8><style>{BASE_CSS}</style>"
                    f'<body><div style="position:relative;width:{w}px;height:{h}px">{body}</div></body>')
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--allow-file-access-from-files",
         "--default-background-color=00000000", f"--force-device-scale-factor={scale}",
         f"--window-size={w},{h}", "--virtual-time-budget=3000", f"--screenshot={out}", page.as_uri()],
        check=True, capture_output=True,
    )
    print(f"{rel}  {w * scale}×{h * scale}  {out.stat().st_size // 1024} KB")


if __name__ == "__main__":
    pebble.write_svgs()
    only = sys.argv[1:]
    with tempfile.TemporaryDirectory() as tmp:
        for rel, w, h, scale, body in [*logo_pngs(), *promo()]:
            if not only or any(rel.startswith(o) for o in only):
                render(rel, w, h, scale, body, Path(tmp))
