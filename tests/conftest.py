"""Tests run at any hour: the stamp's before-dawn hint (agent._small_hours) is left out unless a test asks for it."""
import pytest

from aide import agent

_SMALL_HOURS = agent._small_hours


@pytest.fixture(autouse=True)
def _daytime_stamp(monkeypatch):
    monkeypatch.setattr(agent, "_small_hours", lambda now: "")


@pytest.fixture
def small_hours():
    return _SMALL_HOURS
