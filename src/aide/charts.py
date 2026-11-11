"""Charts an agent draws (#67): economics and science curves for the user's own case ("AD-AS after a tax cut"), as a
`charts` card under the reply. The contract is docs/API.md, "Chat", attachments, `charts`.

The model gives a spec (axes, curves as formulas in x, vertical lines or points, shifts before → after, equilibria
as the meeting of two curves, shaded areas); this module checks it and works the numbers out, so a curve the model
got wrong fails here with a reason it can fix instead of reaching the user drawn wrong. Formulas go through a small
evaluator (arithmetic and a few functions, no names but x), never eval.
"""

import ast
import hashlib
import json
import math
import operator

SAMPLES = 81  # points per curve across the x range
MAX_CURVES = 6
MAX_POINTS = 8
MAX_AREAS = 3
MAX_LABEL = 40
MAX_TITLE = 80
MAX_CAPTION = 300

_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
        ast.Pow: operator.pow}
_FUNCS = {"sqrt": math.sqrt, "log": math.log, "ln": math.log, "log10": math.log10, "exp": math.exp, "sin": math.sin,
          "cos": math.cos, "tan": math.tan, "abs": abs, "min": min, "max": max}
_NAMES = {"e": math.e, "pi": math.pi}


def formula(text: str):
    """`text` ("8 - 0.6*x", "2^x", "sqrt(x)") as a function of x. A ValueError when it isn't a formula in x."""
    source = str(text).strip().replace("^", "**").replace("−", "-").replace("·", "*")
    if not source or len(source) > 200:
        raise ValueError(f"not a formula: {text!r}")
    try:
        tree = ast.parse(source, mode="eval")
    except SyntaxError:
        raise ValueError(f"not a formula: {text!r}") from None

    def check(node) -> None:
        match node:
            case ast.Expression(body=b):
                check(b)
            case ast.BinOp(left=l, op=op, right=r) if type(op) in _OPS:
                check(l), check(r)
            case ast.UnaryOp(op=ast.USub() | ast.UAdd(), operand=o):
                check(o)
            case ast.Constant(value=v) if isinstance(v, (int, float)) and not isinstance(v, bool):
                pass
            case ast.Name(id=n) if n == "x" or n in _NAMES:
                pass
            case ast.Call(func=ast.Name(id=f), args=args, keywords=[]) if f in _FUNCS and args:
                for a in args:
                    check(a)
            case _:
                raise ValueError(f"not a formula in x: {text!r} (numbers, x, + - * / ^ and sqrt, log, exp, "
                                 "sin, cos, abs, min, max)")
    check(tree)

    def run(node, x: float) -> float:
        match node:
            case ast.Expression(body=b):
                return run(b, x)
            case ast.BinOp(left=l, op=op, right=r):
                a, b = run(l, x), run(r, x)
                if isinstance(op, ast.Pow) and abs(b) > 12:
                    raise ValueError("power too large")
                return _OPS[type(op)](a, b)
            case ast.UnaryOp(op=op, operand=o):
                return -run(o, x) if isinstance(op, ast.USub) else run(o, x)
            case ast.Constant(value=v):
                return float(v)
            case ast.Name(id=n):
                return x if n == "x" else _NAMES[n]
            case ast.Call(func=ast.Name(id=f), args=args):
                return float(_FUNCS[f](*(run(a, x) for a in args)))
        raise ValueError("bad formula")

    def f(x: float) -> float | None:
        try:
            y = run(tree, x)
        except (ArithmeticError, ValueError, OverflowError):
            return None
        return y if isinstance(y, float) and math.isfinite(y) else None
    return f


def _num(v, what: str) -> float:
    try:
        n = float(v)
    except (TypeError, ValueError):
        raise ValueError(f"{what} must be a number") from None
    if not math.isfinite(n):
        raise ValueError(f"{what} must be a number")
    return n


def _label(v, what: str, most: int = MAX_LABEL) -> str:
    text = str(v or "").strip()
    if not text:
        raise ValueError(f"{what} needs a label")
    if len(text) > most:
        raise ValueError(f"{what}: keep the label to {most} characters ({text[:20]!r}… is {len(text)})")
    return text


def _round(n: float) -> float:
    return float(f"{n:.4g}")


class _Curve:
    """One state of a curve: a formula, a vertical line (x = a) or points joined by lines."""

    def __init__(self, form, name: str, xs: tuple[float, float]):
        self.vertical: float | None = None
        self.pts: list[tuple[float, float]] | None = None
        self.fn = None
        if isinstance(form, (int, float)) and not isinstance(form, bool):
            self.vertical = _num(form, f"{name}'s x")
        elif isinstance(form, str):
            self.fn = formula(form)
        elif isinstance(form, list):
            pts = sorted((_num(p[0], f"{name}'s points"), _num(p[1], f"{name}'s points")) for p in form
                         if isinstance(p, (list, tuple)) and len(p) == 2)
            if len(pts) < 2 or len(pts) != len(form):
                raise ValueError(f"{name}: points are [[x, y], …], at least two")
            self.pts = pts
        else:
            raise ValueError(f"{name}: give fn (a formula in x), x (a vertical line) or points")
        if self.fn and not any(self.y(xs[0] + (xs[1] - xs[0]) * i / 10) is not None for i in range(11)):
            raise ValueError(f"{name}: the formula has no value anywhere from x = {xs[0]:g} to {xs[1]:g}")

    def y(self, x: float) -> float | None:
        if self.fn:
            return self.fn(x)
        if self.pts:
            for (x0, y0), (x1, y1) in zip(self.pts, self.pts[1:]):
                if x0 <= x <= x1:
                    return y0 if x1 == x0 else y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        return None

    def sample(self, x_axis: tuple[float, float], y_axis: tuple[float, float]) -> list[list[float | None]]:
        """[[x, y], …] to draw; y is null outside the y axis (a gap in the line)."""
        lo, hi = y_axis
        if self.vertical is not None:
            return [[_round(self.vertical), _round(lo)], [_round(self.vertical), _round(hi)]]
        if self.pts:
            return [[_round(x), _round(y) if lo <= y <= hi else None] for x, y in self.pts]
        out = []
        for i in range(SAMPLES):
            x = x_axis[0] + (x_axis[1] - x_axis[0]) * i / (SAMPLES - 1)
            y = self.y(x)
            out.append([_round(x), _round(y) if y is not None and lo <= y <= hi else None])
        return out


def _meet(a: _Curve, b: _Curve, xs: tuple[float, float]) -> tuple[float, float] | None:
    """Where two curves cross within the x range (the first crossing from the left)."""
    if a.vertical is not None and b.vertical is not None:
        return None
    if a.vertical is not None or b.vertical is not None:
        v, other = (a, b) if a.vertical is not None else (b, a)
        y = other.y(v.vertical)
        return (v.vertical, y) if y is not None else None
    steps = 400
    prev = None
    for i in range(steps + 1):
        x = xs[0] + (xs[1] - xs[0]) * i / steps
        ya, yb = a.y(x), b.y(x)
        if ya is None or yb is None:
            prev = None
            continue
        d = ya - yb
        if d == 0:
            return x, ya
        if prev is not None and (prev[1] < 0) != (d < 0):
            lo, hi = prev[0], x
            for _ in range(60):
                mid = (lo + hi) / 2
                ym, ymb = a.y(mid), b.y(mid)
                if ym is None or ymb is None:
                    break
                if (ym - ymb < 0) == (prev[1] < 0):
                    lo = mid
                else:
                    hi = mid
            x = (lo + hi) / 2
            return x, a.y(x)
        prev = (x, d)
    return None


def build(spec: dict) -> dict:
    """A checked chart for the `charts` card, from the draw_chart spec. A ValueError says what to fix."""
    title = _label(spec.get("title"), "the chart", MAX_TITLE)
    x_axis = (_num(spec.get("x_min", 0), "x_min"), _num(spec.get("x_max"), "x_max"))
    y_axis = (_num(spec.get("y_min", 0), "y_min"), _num(spec.get("y_max"), "y_max"))
    if x_axis[1] <= x_axis[0] or y_axis[1] <= y_axis[0]:
        raise ValueError("each axis needs max above min")
    raw_curves = spec.get("curves") or []
    if not raw_curves or len(raw_curves) > MAX_CURVES:
        raise ValueError(f"draw 1 to {MAX_CURVES} curves")
    curves, states = [], {}
    for i, c in enumerate(raw_curves):
        name = _label(c.get("label"), f"curve {i + 1}")
        if name.lower() in states:
            raise ValueError(f"two curves are called {name}")
        form = c.get("fn", c.get("x", c.get("points")))
        before = _Curve(form, name, x_axis)
        after = None
        if c.get("shift_to") is not None:
            after = _Curve(c["shift_to"], f"{name} after the shift", x_axis)
        states[name.lower()] = (before, after)
        drawn = before.sample(x_axis, y_axis)
        if not any(p[1] is not None for p in drawn) and before.vertical is None:
            raise ValueError(f"{name} is outside the y axis ({y_axis[0]:g} to {y_axis[1]:g}) everywhere")
        if before.vertical is not None and not x_axis[0] <= before.vertical <= x_axis[1]:
            raise ValueError(f"{name} is outside the x axis")
        curves.append({"label": name, "points": drawn,
                       "after": after.sample(x_axis, y_axis) if after else None,
                       "after_label": (_label(c.get("shift_label"), f"{name}'s shift") if c.get("shift_label")
                                       else name + "′") if after else None,
                       "dashed": bool(c.get("dashed"))})
    points = []
    for i, p in enumerate((spec.get("points") or [])[:MAX_POINTS + 1]):
        if i == MAX_POINTS:
            raise ValueError(f"at most {MAX_POINTS} points")
        name = _label(p.get("label"), f"point {i + 1}")
        after = bool(p.get("after"))
        if p.get("at"):
            pair = [str(n).lower() for n in p["at"]]
            if len(pair) != 2 or any(n not in states for n in pair):
                raise ValueError(f"{name}: at names two of the curves ({', '.join(c['label'] for c in curves)})")
            a, b = ((states[n][1] or states[n][0]) if after else states[n][0] for n in pair)
            found = _meet(a, b, x_axis)
            if found is None:
                raise ValueError(f"{name}: {p['at'][0]} and {p['at'][1]} don't meet within the x axis")
            x, y = found
        else:
            x, y = _num(p.get("x"), f"{name}'s x"), _num(p.get("y"), f"{name}'s y")
        if not (x_axis[0] <= x <= x_axis[1] and y_axis[0] <= y <= y_axis[1]):
            raise ValueError(f"{name} ({x:g}, {y:g}) is outside the axes")
        points.append({"label": name, "x": _round(x), "y": _round(y), "after": after})
    areas = []
    for i, a in enumerate((spec.get("areas") or [])[:MAX_AREAS + 1]):
        if i == MAX_AREAS:
            raise ValueError(f"at most {MAX_AREAS} shaded areas")
        name = _label(a.get("label"), f"area {i + 1}")
        if a.get("between"):
            pair = [str(n).lower() for n in a["between"]]
            if len(pair) != 2 or any(n not in states for n in pair):
                raise ValueError(f"{name}: between names two of the curves")
            after = bool(a.get("after"))
            top, bottom = ((states[n][1] or states[n][0]) if after else states[n][0] for n in pair)
            lo = _num(a.get("from", x_axis[0]), f"{name}'s from")
            hi = _num(a.get("to", x_axis[1]), f"{name}'s to")
            xs = [lo + (hi - lo) * k / 40 for k in range(41)]
            upper = [(x, top.y(x)) for x in xs]
            lower = [(x, bottom.y(x)) for x in xs]
            if any(y is None for _, y in upper + lower):
                raise ValueError(f"{name}: a curve has no value somewhere from {lo:g} to {hi:g}")
            poly = upper + lower[::-1]
        else:
            poly = [(_num(q[0], f"{name}'s points"), _num(q[1], f"{name}'s points")) for q in a.get("points") or []
                    if isinstance(q, (list, tuple)) and len(q) == 2]
            if len(poly) < 3:
                raise ValueError(f"{name}: give between (two curves, from and to) or points (three or more)")
        poly = [(min(max(x, x_axis[0]), x_axis[1]), min(max(y, y_axis[0]), y_axis[1])) for x, y in poly]
        areas.append({"label": name, "points": [[_round(x), _round(y)] for x, y in poly]})
    chart = {"title": title, "caption": str(spec.get("caption") or "").strip()[:MAX_CAPTION] or None,
             "x": {"label": _label(spec.get("x_label"), "the x axis"), "min": _round(x_axis[0]),
                   "max": _round(x_axis[1])},
             "y": {"label": _label(spec.get("y_label"), "the y axis"), "min": _round(y_axis[0]),
                   "max": _round(y_axis[1])},
             "curves": curves, "points": points, "areas": areas}
    chart["id"] = "ch_" + hashlib.sha1(json.dumps(chart, sort_keys=True).encode()).hexdigest()[:12]
    return chart


def describe(chart: dict) -> str:
    """What the model reads back: the numbers it can quote, so the text matches the picture."""
    parts = [f"Drawn: {chart['title']} ({chart['x']['label']} against {chart['y']['label']})."]
    shifted = [f"{c['label']} → {c['after_label']}" for c in chart["curves"] if c["after"]]
    if shifted:
        parts.append("Shifts: " + ", ".join(shifted) + ".")
    for p in chart["points"]:
        parts.append(f"{p['label']}{' (after)' if p['after'] else ''} at x = {p['x']:g}, y = {p['y']:g}.")
    parts.append("The app shows it as a card under your reply: don't describe the picture, say what it means.")
    return " ".join(parts)
