"""Spaced repetition (#63): a schedule per notebook question and flashcard, worked out from the answers already
recorded (quiz.py's `quiz_answers`), so there is nothing to back-fill and nothing to drift: practice exams, chat
quizzes, the Study page and focus's "What stuck" all count, as they always have.

The scheduler is FSRS (4.5, its published default weights): each item has a stability (the days until the chance of
recalling it falls to 90%) and a difficulty (1–10), moved by every day it was answered. A day is one review: its
grade is the worst answer that day (missed in round 1 and right in round 2 is still a miss, so it comes back
tomorrow). Grades: wrong or blank is Again, an open answer worth half is Hard, right is Good (Easy isn't asked yet).
An item is due on the day its chance of being recalled reaches 90%, at most MAX_DAYS on; a missed one is due the
next day whatever its stability (a relearning step), and grows from there.

The Obsidian vault's Spaced Repetition cards keep the plugin's own schedule (`<!--SR:…-->`): Aide neither reads nor
writes it, since its schedule comes from answers given in the app and in chat.
"""

import math
from dataclasses import dataclass
from datetime import date

# FSRS-4.5's default weights.
W = (0.4872, 1.4003, 3.7145, 13.8206, 5.1618, 1.2298, 0.8975, 0.031, 1.6474, 0.1367, 1.0461, 2.1072, 0.0793,
     0.3246, 1.587, 0.2272, 2.8755)
DECAY, FACTOR = -0.5, 19 / 81  # the forgetting curve: R = (1 + FACTOR·t/S)^DECAY, 90% at t = S
RETENTION = 0.9  # due when the chance of recalling it falls to this
MAX_DAYS = 180
AGAIN, HARD, GOOD, EASY = 1, 2, 3, 4


@dataclass
class Schedule:
    stability: float  # days
    difficulty: float  # 1–10
    last: date  # the last day it was answered
    due: date
    grade: int  # that day's
    reviews: int  # days answered
    lapses: int  # days missed after the first

    def retention(self, today: date) -> float:
        """The chance of recalling it today, 0–1."""
        return recall((today - self.last).days, self.stability)

    def is_due(self, today: date) -> bool:
        return self.due <= today

    def known(self, today: date) -> bool:
        """Not due, and not missed the last time."""
        return self.grade >= HARD and not self.is_due(today)


def recall(days: float, stability: float) -> float:
    return (1 + FACTOR * max(0.0, days) / stability) ** DECAY


def interval(stability: float) -> int:
    """Days until the chance of recalling it is RETENTION."""
    days = stability / FACTOR * (RETENTION ** (1 / DECAY) - 1)
    return min(MAX_DAYS, max(1, round(days)))


def _d0(grade: int) -> float:
    return min(10.0, max(1.0, W[4] - (grade - 3) * W[5]))


def grade_of(correct: bool, part: float | None = None) -> int:
    """An answer's grade: `part` is an open answer's share of its points (None for the others)."""
    if part is not None:
        return GOOD if part >= 1 else HARD if part >= 0.5 else AGAIN
    return GOOD if correct else AGAIN


def schedule(days: list[tuple[date, int]]) -> Schedule | None:
    """The schedule after these reviews: (day, grade), one a day, oldest first. None before any."""
    out = None
    for day, g in days:
        if out is None:
            s, d = W[g - 1], _d0(g)
            out = Schedule(s, d, day, day, g, 0, 0)
        else:
            s, d = out.stability, out.difficulty
            r = recall((day - out.last).days, s)
            if g == AGAIN:
                s = min(s, W[11] * d ** -W[12] * ((s + 1) ** W[13] - 1) * math.exp(W[14] * (1 - r)))
                out.lapses += 1
            else:
                s *= 1 + (math.exp(W[8]) * (11 - d) * s ** -W[9] * (math.exp(W[10] * (1 - r)) - 1)
                          * (W[15] if g == HARD else 1) * (W[16] if g == EASY else 1))
            d = min(10.0, max(1.0, W[7] * _d0(3) + (1 - W[7]) * (d - W[6] * (g - 3))))
        out.stability, out.difficulty = max(0.1, s), d
        out.last, out.grade = day, g
        out.reviews += 1
        out.due = day.fromordinal(day.toordinal() + (1 if g == AGAIN else interval(out.stability)))
    return out


def by_day(answers: list[tuple[date, int]]) -> list[tuple[date, int]]:
    """Answers (day, grade) in time order as one review a day: the day's worst grade."""
    days: dict[date, int] = {}
    for day, g in answers:
        days[day] = min(g, days.get(day, EASY))
    return sorted(days.items())
