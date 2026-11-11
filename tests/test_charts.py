import pytest

from aide.charts import build, describe, formula
from aide.tools.charts import chart_tools

AD_AS = {"title": "AD-AS after a tax cut", "x_label": "Output (Y)", "y_label": "Price level (P)", "x_max": 10,
         "y_max": 10, "curves": [{"label": "AD", "fn": "8 - 0.6*x", "shift_to": "9.5 - 0.6*x"},
                                 {"label": "SRAS", "fn": "1 + 0.5*x"}, {"label": "LRAS", "x": 6}],
         "points": [{"label": "E₀", "at": ["AD", "SRAS"]}, {"label": "E₁", "at": ["AD", "SRAS"], "after": True}],
         "areas": [{"label": "Gap", "between": ["AD", "SRAS"], "from": 2, "to": 4}]}


def test_formulas_are_arithmetic_in_x_only():
    assert formula("8 - 0.6*x")(5) == 5
    assert formula("2^x")(3) == 8
    assert formula("sqrt(x) + max(x, 1)")(4) == 6
    assert formula("1/x")(0) is None  # no value there, not an error
    for bad in ("__import__('os')", "x.real", "y + 1", "[1, 2]", "lambda: 1", "x if x else 1", ""):
        with pytest.raises(ValueError):
            formula(bad)
    assert formula("2^(10^10)")(1) is None  # too large a power: no value


def test_ad_as_shift_and_equilibria_are_worked_out():
    chart = build(AD_AS)
    ad, sras, lras = chart["curves"]
    assert ad["after_label"] == "AD′" and len(ad["points"]) == len(ad["after"]) == 81
    assert sras["after"] is None and lras["points"] == [[6, 0], [6, 10]]
    assert ad["points"][-1] == [10, 2]
    e0, e1 = chart["points"]
    assert (e0["x"], e0["y"]) == (pytest.approx(6.364, abs=0.01), pytest.approx(4.182, abs=0.01))
    assert e1["after"] and e1["x"] == pytest.approx(7.727, abs=0.01)  # output rises past LRAS in the short run
    assert len(chart["areas"][0]["points"]) == 82
    assert chart["id"].startswith("ch_") and build(AD_AS)["id"] == chart["id"]
    said = describe(chart)
    assert "AD → AD′" in said and "E₁ (after) at x = 7.727" in said


def test_points_outside_the_axes_leave_a_gap():
    chart = build({"title": "1/x", "x_label": "x", "y_label": "y", "x_max": 4, "y_max": 4,
                   "curves": [{"label": "f", "fn": "1/x"}]})
    pts = chart["curves"][0]["points"]
    assert pts[0] == [0, None] and pts[1][1] is None and pts[-1] == [4, 0.25]


@pytest.mark.parametrize("change, error", [
    ({"x_max": 0}, "max above min"),
    ({"curves": []}, "1 to 6 curves"),
    ({"curves": [{"label": "AD", "fn": "import os"}]}, "not a formula"),
    ({"curves": [{"label": "AD", "fn": "50 + x"}]}, "outside the y axis"),
    ({"points": [{"label": "E", "at": ["AD", "Nope"]}]}, "names two of the curves"),
    ({"points": [{"label": "E", "at": ["SRAS", "SRAS"]}]}, "names two of the curves"),
    ({"curves": [{"label": "A", "fn": "1 + x"}, {"label": "B", "fn": "2 + x"}], "areas": [],
      "points": [{"label": "E", "at": ["A", "B"]}]}, "don't meet"),
    ({"points": [{"label": "E", "x": 20, "y": 1}]}, "outside the axes"),
    ({"title": "x" * 100}, "80 characters"),
])
def test_bad_specs_say_what_to_fix(change, error):
    with pytest.raises(ValueError, match=error):
        build({**AD_AS, **change})


async def test_the_tool_puts_a_card_under_the_reply():
    (tool,) = chart_tools()
    out = await tool.handler(**AD_AS)
    assert out.attachment["type"] == "charts" and out.attachment["charts"][0]["title"] == "AD-AS after a tax cut"
    assert out.startswith("Drawn: AD-AS after a tax cut")
