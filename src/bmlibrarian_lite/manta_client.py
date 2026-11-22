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

"""Client of the local MANTA server (tools/manta_server): judge, then reference.

The server is on loopback, so a plain requests.Session is used, not the
polite (paced) one.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import requests

from .constants import MANTA_APP_NAME, MANTA_REQUEST_TIMEOUT_SECONDS
from .data_models import LiteDocument

JUDGE_PATH = "/v1/judge"
REFERENCE_PATH = "/v1/reference"
TASK_RELEVANCE = "relevance"
TASK_DESIGN = "design"
UNREADABLE_ANSWER = "unreadable answer"
HTTP_OK_MIN = 200
HTTP_OK_MAX = 299
HTTP_OK = 200


class MantaUnreachable(Exception):
    """The server could not be reached, or did not answer in time."""


class MantaRefused(Exception):
    """The server answered, but not with a usable result.

    Attributes:
        status: The HTTP status.
        message: What the server said.
    """

    def __init__(self, status: int, message: str) -> None:
        """Keeps the status and the server's message."""
        super().__init__(f"MANTA answered {status}: {message}")
        self.status = status
        self.message = message


@dataclass(frozen=True)
class MantaJudgement:
    """A /v1/judge answer, flattened."""

    judgement_id: str
    revision: str
    expected_score: float
    relevance_probabilities: dict[str, float]
    verdict: str
    cutoff: float
    design: str | None
    design_probability: float | None
    design_probabilities: dict[str, float] | None
    seconds: float
    truncated: bool


class MantaClient:
    """Posts documents to a MANTA server and posts the LLM's score back."""

    def __init__(
        self,
        base_url: str,
        session: requests.Session | None = None,
        timeout: float = MANTA_REQUEST_TIMEOUT_SECONDS,
    ) -> None:
        """Sets the server and the session.

        Args:
            base_url: The server's address, e.g. http://127.0.0.1:8765.
            session: A session to use; a plain one when None.
            timeout: Seconds to wait for an answer.
        """
        self._base = base_url.rstrip("/")
        self._session = session or requests.Session()
        self._timeout = timeout

    def _post(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        """POSTs and returns the answer's JSON object, or raises."""
        try:
            response = self._session.post(self._base + path, json=body, timeout=self._timeout)
        except (requests.ConnectionError, requests.Timeout) as exc:
            raise MantaUnreachable(type(exc).__name__) from None
        status = response.status_code
        try:
            answer = response.json()
        except ValueError:
            answer = None
        if not HTTP_OK_MIN <= status <= HTTP_OK_MAX:
            message = answer.get("error") if isinstance(answer, dict) else None
            raise MantaRefused(status, str(message or response.text))
        if not isinstance(answer, dict):
            raise MantaRefused(status, UNREADABLE_ANSWER)
        return answer

    def judge(self, question: str, document: LiteDocument) -> MantaJudgement:
        """Has MANTA judge one document against the question.

        Raises:
            MantaUnreachable: On a connection error or timeout.
            MantaRefused: On a non-2xx or an unreadable answer.
        """
        ids = {
            key: value
            for key, value in (
                ("pmid", document.pmid),
                ("doi", document.doi),
                ("pmc_id", document.pmc_id),
            )
            if value
        }
        answer = self._post(
            JUDGE_PATH,
            {
                "app": MANTA_APP_NAME,
                "question": question,
                "title": document.title,
                "abstract": document.abstract or "",
                "ids": ids,
                "tasks": [TASK_RELEVANCE, TASK_DESIGN],
            },
        )
        try:
            rel = answer["relevance"]
            design = answer.get("design")
            return MantaJudgement(
                judgement_id=str(answer["judgement_id"]),
                revision=str(answer["revision"]),
                expected_score=float(rel["expected_score"]),
                relevance_probabilities={str(k): float(v) for k, v in rel["probabilities"].items()},
                verdict=str(rel["verdict"]),
                cutoff=float(rel["cutoff"]),
                design=design["answer"] if design else None,
                design_probability=float(design["probability"]) if design else None,
                design_probabilities=(
                    {str(k): float(v) for k, v in design["probabilities"].items()}
                    if design
                    else None
                ),
                seconds=float(answer["seconds"]),
                truncated=bool(answer["truncated"]),
            )
        except (KeyError, TypeError, ValueError, AttributeError):
            raise MantaRefused(HTTP_OK, UNREADABLE_ANSWER) from None

    def reference(
        self, judgement_id: str, llm_model: str, llm_score: int, document: LiteDocument
    ) -> None:
        """Posts the LLM's score for a judged document.

        Raises:
            MantaUnreachable: On a connection error or timeout.
            MantaRefused: On a non-2xx answer (404: the judgement is unknown).
        """
        indexing = (
            {
                "publication_types": document.publication_types or [],
                "mesh_terms": document.mesh_terms,
                "medline_status": document.medline_status,
                "indexing_method": document.indexing_method,
            }
            if document.pmid
            else None
        )
        self._post(
            REFERENCE_PATH,
            {
                "judgement_id": judgement_id,
                "app": MANTA_APP_NAME,
                "llm_model": llm_model,
                "llm_score": llm_score,
                "llm_design": None,
                "indexing": indexing,
            },
        )
