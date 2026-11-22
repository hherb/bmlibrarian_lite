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

"""A stand-in for MANTA's predictor, shared by the MANTA server tests."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_protocol as mp  # noqa: E402

FAKE_PROMPT_TOKENS = 100
FAKE_DESIGN_PROBABILITY = 0.9


class FakeManta:
    """Answers in the shape of ``Manta.predict``, and records each request."""

    def __init__(
        self,
        relevance: dict[str, float] | None = None,
        design: str = "rct",
        truncated: bool = False,
        fail_with: Exception | None = None,
    ) -> None:
        """Sets the answers.

        Args:
            relevance: Option id ("0".."4") to probability; uniform when None.
            design: The design option id answered.
            truncated: Whether the answers claim the prompt was truncated.
            fail_with: An exception ``predict`` raises instead of answering.
        """
        self.relevance = relevance or {str(i): 0.2 for i in range(len(mp.RELEVANCE_LEVELS))}
        self.design = design
        self.truncated = truncated
        self.fail_with = fail_with
        self.requests: list[dict[str, Any]] = []

    def predict(self, request: dict[str, Any]) -> dict[str, Any]:
        """Answers one request like MANTA does."""
        self.requests.append(request)
        if self.fail_with is not None:
            raise self.fail_with
        questions: dict[str, Any] = {}
        if "relevance" in request["questions"]:
            probs = dict(self.relevance)
            questions["relevance"] = {
                "type": "score",
                "options": list(probs),
                "probabilities": probs,
                "answer": max(probs, key=lambda k: probs[k]),
            }
        if "study_design" in request["questions"]:
            rest = (1 - FAKE_DESIGN_PROBABILITY) / (len(mp.DESIGN_OPTIONS) - 1)
            probs = {
                k: FAKE_DESIGN_PROBABILITY if k == self.design else rest for k in mp.DESIGN_OPTIONS
            }
            questions["study_design"] = {
                "type": "choice",
                "options": list(probs),
                "probabilities": probs,
                "answer": self.design,
            }
        return {
            "id": request["id"],
            "questions": questions,
            "prompt_tokens": FAKE_PROMPT_TOKENS,
            "truncated": self.truncated,
        }
