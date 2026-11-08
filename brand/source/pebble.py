"""Generate the Pebble logo, expressions, the agents' family and the idle animation from one set of geometry.

    python3 brand/source/pebble.py              # SVGs only, no dependencies
    uv run --no-project --with cairosvg --with pillow python3 brand/source/pebble.py --gif

render.py turns these into the PNGs and the promo images.

Eyes are real holes in the body (fill-rule evenodd), so every file works in one colour
and on any background.
"""

import argparse
import math
from pathlib import Path

OUT = Path(__file__).parent.parent / "logo"
# The app icon is an Icon Composer document: its colours per appearance live in its icon.json.
APP_ICON = Path(__file__).parent.parent.parent / "ios" / "Aide" / "Aide" / "AppIcon.icon" / "Assets"

SLATE = "#34413F"  # Pebble
SAND = "#ECE5D8"   # background tile

# Body: a horizontal stadium, 160 x 136, sitting optically centred on a 256 canvas.
BODY = "M116 62H140A68 68 0 0 1 140 198H116A68 68 0 0 1 116 62Z"
EYE_Y = 124
EYE_DX = 28  # eye centres at 128 -/+ 28


def _pt(cx, cy, r, deg):
    a = math.radians(deg)
    return f"{cx + r * math.cos(a):.2f} {cy + r * math.sin(a):.2f}"


def arc_eye(cx, cy, r=15, t=11, a0=20, a1=160):
    """A thick arc with round caps. 20..160 deg is a smile-shaped (closed, content) eye; 200..340 is a happy one."""
    ro, ri, c = r + t / 2, r - t / 2, t / 2
    return (
        f"M{_pt(cx, cy, ro, a0)}A{ro} {ro} 0 0 1 {_pt(cx, cy, ro, a1)}"
        f"A{c} {c} 0 0 1 {_pt(cx, cy, ri, a1)}"
        f"A{ri} {ri} 0 0 0 {_pt(cx, cy, ri, a0)}"
        f"A{c} {c} 0 0 1 {_pt(cx, cy, ro, a0)}Z"
    )


def dot_eye(cx, cy, rx=10.0, ry=10.0):
    return f"M{cx - rx:.2f} {cy}a{rx:.2f} {ry:.2f} 0 1 0 {2 * rx:.2f} 0a{rx:.2f} {ry:.2f} 0 1 0 {-2 * rx:.2f} 0Z"


def line_eye(cx, cy, w=26, t=8):
    """Closed, flat eye (asleep)."""
    h = t / 2
    return f"M{cx - w / 2 + h} {cy - h}H{cx + w / 2 - h}A{h} {h} 0 0 1 {cx + w / 2 - h} {cy + h}H{cx - w / 2 + h}A{h} {h} 0 0 1 {cx - w / 2 + h} {cy - h}Z"


def both(fn, dx=0, dy=0, **kw):
    return fn(128 - EYE_DX + dx, EYE_Y + dy, **kw) + fn(128 + EYE_DX + dx, EYE_Y + dy, **kw)


EXPRESSIONS = {
    "calm": both(arc_eye),                          # the logo: content, at rest
    "awake": both(dot_eye),                         # listening
    "thinking": both(dot_eye, dx=8, dy=-10, rx=9, ry=9),  # looking up and away
    "happy": both(arc_eye, dy=6, a0=200, a1=340),   # done
    "sleeping": both(line_eye, dy=8),               # offline / quiet hours
}


# -- the family: each agent its own creature with Pebble's eyes (ios/Aide/Aide/Support/Figure.swift) -----------


def _ingot() -> str:
    """A trapezoid with its corners rounded by 28: the outline pushed out by 28, arcs at the corners."""
    v = [(96, 100), (160, 100), (180, 168), (76, 168)]
    r, out = 28, []
    normals = []
    for i in range(4):
        (x0, y0), (x1, y1) = v[i], v[(i + 1) % 4]
        d = math.hypot(x1 - x0, y1 - y0)
        normals.append(((y1 - y0) / d, -(x1 - x0) / d))
    for i in range(4):
        (x0, y0), (x1, y1), (nx, ny) = v[i], v[(i + 1) % 4], normals[i]
        mx, my = normals[(i + 1) % 4]
        if i == 0:
            out.append(f"M{x0 + r * nx:.2f} {y0 + r * ny:.2f}")
        out.append(f"L{x1 + r * nx:.2f} {y1 + r * ny:.2f}A{r} {r} 0 0 1 {x1 + r * mx:.2f} {y1 + r * my:.2f}")
    return "".join(out) + "Z"


# id: (name, colour, body, eye height, eye distance from the middle, eye size next to Pebble's)
FAMILY = {
    "aide": ("Aide", SLATE, BODY, 124, 28, 1.0),
    "secretary": ("Secretary", "#3B6FD8",
                  "M104 58H152A46 46 0 0 1 198 104V152A46 46 0 0 1 152 198H104A46 46 0 0 1 58 152V104A46 46 0 0 1 104 58Z",
                  122, 28, 1.0),
    "professor": ("Professor", "#7A4FD0", "M60 122A68 68 0 0 1 196 122V166A34 34 0 0 1 162 200H94A34 34 0 0 1 60 166Z",
                  128, 25, 0.92),
    "coach": ("Coach", "#23A26D", "M54 128A74 74 0 1 1 202 128A74 74 0 1 1 54 128Z", 120, 30, 1.05),
    "finance": ("Finance", "#B8921C", _ingot(), 138, 27, 0.95),
}


def family_path(agent: str) -> str:
    """The agent's body with calm eyes cut out, as one path (fill-rule evenodd)."""
    _, _, body, y, dx, k = FAMILY[agent]
    return body + arc_eye(128 - dx, y, r=15 * k, t=11 * k) + arc_eye(128 + dx, y, r=15 * k, t=11 * k)


def svg(eyes: str, fill: str = "#000", tile: str | None = None, scale: float = 1.0,
        body_transform: str = "", title: str = "Aide", body: str = BODY) -> str:
    group = []
    if scale != 1.0:
        group.append(f"translate(128 128) scale({scale}) translate(-128 -128)")
    if body_transform:
        group.append(body_transform)
    transform = f' transform="{" ".join(group)}"' if group else ""
    bg = f'<rect width="256" height="256" fill="{tile}"/>' if tile else ""
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><title>{title}</title>{bg}'
        f'<path fill="{fill}" fill-rule="evenodd"{transform} d="{body}{eyes}"/></svg>\n'
    )


# Small-size cut: bigger body, heavier eyes, for 16-32 px (the Mac menu bar).
def small_svg(fill: str = "#000") -> str:
    eyes = arc_eye(128 - 30, 126, r=17, t=16) + arc_eye(128 + 30, 126, r=17, t=16)
    return svg(eyes, fill=fill, scale=1.3, title="Aide (small)")


def write_svgs() -> None:
    (OUT / "expressions").mkdir(parents=True, exist_ok=True)
    (OUT / "pebble.svg").write_text(svg(EXPRESSIONS["calm"]))
    (OUT / "pebble-slate.svg").write_text(svg(EXPRESSIONS["calm"], fill=SLATE))
    (OUT / "pebble-white.svg").write_text(svg(EXPRESSIONS["calm"], fill="#fff"))
    (OUT / "pebble-small.svg").write_text(small_svg())
    for name, eyes in EXPRESSIONS.items():
        (OUT / "expressions" / f"{name}.svg").write_text(svg(eyes, fill=SLATE, tile=SAND, scale=1.2))
    (OUT / "family").mkdir(exist_ok=True)
    for agent, (name, colour, *_rest) in FAMILY.items():
        (OUT / "family" / f"{agent}.svg").write_text(svg("", fill=colour, body=family_path(agent), title=name))
    # The app icon's one layer: Pebble alone on Icon Composer's 1024 canvas, no tile.
    APP_ICON.mkdir(parents=True, exist_ok=True)
    (APP_ICON / "pebble.svg").write_text(
        svg(EXPRESSIONS["calm"], fill=SLATE, scale=1.2).replace("<svg ", '<svg width="1024" height="1024" ', 1)
    )


# -- idle animation: slow breathing, a blink every few seconds ------------------

FRAMES, FRAME_MS = 48, 80  # 3.84 s loop
BLINK = {38: 0.55, 39: 0.15, 40: 0.15, 41: 0.55}  # frame -> eye openness


def idle_frame(i: int) -> str:
    s = math.sin(2 * math.pi * i / FRAMES)
    sx, sy = 1 - 0.012 * s, 1 + 0.03 * s  # breathe, anchored at the base
    breathe = f"translate(128 198) scale({sx:.4f} {sy:.4f}) translate(-128 -198)"
    open_ = BLINK.get(i, 1.0)
    eyes = both(dot_eye, rx=10, ry=10 * open_)
    return svg(eyes, fill=SLATE, tile=SAND, scale=1.2, body_transform=breathe)


def write_animated_svg() -> None:
    """CSS-animated SVG for web pages (the README)."""
    eyes = both(dot_eye)
    doc = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256"><title>Aide</title>
<style>
  .body {{ transform-origin: 128px 198px; animation: breathe 3.84s ease-in-out infinite; }}
  .eyes {{ transform-origin: 128px {EYE_Y}px; animation: blink 3.84s infinite; }}
  @keyframes breathe {{ 0%,100% {{ transform: scale(1,1); }} 25% {{ transform: scale(.988,1.03); }} 75% {{ transform: scale(1.012,.97); }} }}
  @keyframes blink {{ 0%,78%,88%,100% {{ transform: scaleY(1); }} 82%,84% {{ transform: scaleY(.15); }} }}
  @media (prefers-reduced-motion: reduce) {{ .body, .eyes {{ animation: none; }} }}
</style>
<rect width="256" height="256" fill="{SAND}"/>
<g transform="translate(128 128) scale(1.2) translate(-128 -128)">
  <g class="body"><path fill="{SLATE}" d="{BODY}"/>
    <path class="eyes" fill="{SAND}" d="{eyes}"/></g>
</g></svg>
"""
    (OUT / "idle.svg").write_text(doc)


def write_gif(size: int = 512) -> None:
    import io

    import cairosvg
    from PIL import Image

    frames = [
        Image.open(io.BytesIO(cairosvg.svg2png(bytestring=idle_frame(i).encode(), output_width=size, output_height=size))).convert("RGB")
        for i in range(FRAMES)
    ]
    frames[0].save(OUT / "idle.gif", save_all=True, append_images=frames[1:], duration=FRAME_MS, loop=0, optimize=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--gif", action="store_true", help="also render idle.gif (needs cairosvg and pillow)")
    args = ap.parse_args()
    write_svgs()
    write_animated_svg()
    if args.gif:
        write_gif()
    print(f"wrote {OUT}")
