# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Statistics shared by the MANTA benchmark and the server's report.

Standard library only, so a copy of tools/manta_server/ runs on its own.
"""

from __future__ import annotations

import math
from collections import defaultdict
from collections.abc import Sequence

ECE_BINS = 15
WILSON_Z = 1.959964


def average_ranks(values: Sequence[float]) -> list[float]:
    """Ranks starting at 1, ties given their mean rank.

    Args:
        values: The values to rank.

    Returns:
        One rank per value, in input order.
    """
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(order):
        j = i
        while j + 1 < len(order) and values[order[j + 1]] == values[order[i]]:
            j += 1
        mean_rank = (i + j) / 2 + 1
        for k in range(i, j + 1):
            ranks[order[k]] = mean_rank
        i = j + 1
    return ranks


def pearson(x: Sequence[float], y: Sequence[float]) -> float | None:
    """Pearson's correlation, or None when either side is constant.

    Args:
        x: First values.
        y: Second values, as many as ``x``.

    Returns:
        The correlation coefficient.
    """
    n = len(x)
    if n != len(y) or n < 2:
        return None
    mx = math.fsum(x) / n
    my = math.fsum(y) / n
    sxy = math.fsum((a - mx) * (b - my) for a, b in zip(x, y, strict=True))
    sxx = math.fsum((a - mx) ** 2 for a in x)
    syy = math.fsum((b - my) ** 2 for b in y)
    if sxx == 0 or syy == 0:
        return None
    return sxy / math.sqrt(sxx * syy)


def spearman(x: Sequence[float], y: Sequence[float]) -> float | None:
    """Spearman's rank correlation (Pearson's on average ranks).

    Args:
        x: First values.
        y: Second values, as many as ``x``.

    Returns:
        The coefficient, or None when either side is constant.
    """
    return pearson(average_ranks(x), average_ranks(y))


def wilson_interval(successes: int, n: int) -> tuple[float, float] | None:
    """Wilson's 95 % score interval for a proportion.

    Args:
        successes: Successes.
        n: Trials.

    Returns:
        (lower, upper), or None for no trials.
    """
    if n == 0:
        return None
    p = successes / n
    z2 = WILSON_Z**2
    centre = (p + z2 / (2 * n)) / (1 + z2 / n)
    half = WILSON_Z * math.sqrt(p * (1 - p) / n + z2 / (4 * n * n)) / (1 + z2 / n)
    return (centre - half, centre + half)


def expected_calibration_error(
    confidences: Sequence[float], correct: Sequence[bool]
) -> float | None:
    """ECE over ``ECE_BINS`` equal-width bins of the stated confidence.

    Args:
        confidences: The probability each answer was given (0-1).
        correct: Whether each answer was right.

    Returns:
        The ECE, or None for no answers.
    """
    n = len(confidences)
    if n == 0:
        return None
    bins: dict[int, list[int]] = defaultdict(list)
    for i, c in enumerate(confidences):
        bins[min(int(c * ECE_BINS), ECE_BINS - 1)].append(i)
    total = 0.0
    for members in bins.values():
        conf = math.fsum(confidences[i] for i in members) / len(members)
        acc = sum(1 for i in members if correct[i]) / len(members)
        total += len(members) / n * abs(acc - conf)
    return total
