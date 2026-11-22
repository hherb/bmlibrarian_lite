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

"""The MANTA judging service and its localhost-only HTTP API."""

from __future__ import annotations

import json
import logging
import math
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Protocol

import manta_ledger as ml
import manta_protocol as mp

logger = logging.getLogger(__name__)

DEFAULT_PORT = 8765
BIND_HOST = "127.0.0.1"
SELF_TEST_TOLERANCE = 0.05
TASK_RELEVANCE = "relevance"
TASK_DESIGN = "design"
ALL_TASKS = (TASK_RELEVANCE, TASK_DESIGN)
Q_RELEVANCE = "relevance"
Q_DESIGN = "study_design"
HTTP_OK = 200
HTTP_BAD_REQUEST = 400
HTTP_NOT_FOUND = 404
HTTP_ERROR = 500
HTTP_UNAVAILABLE = 503


class Predictor(Protocol):
    """The shape of ``Manta.predict``."""

    def predict(self, request: dict) -> dict:
        """Answers one MANTA request."""
        ...


class BadRequest(ValueError):
    """A request body that is not valid."""


class NotReady(RuntimeError):
    """The service's self-test failed, so it judges nothing."""


def _now() -> str:
    return datetime.now(UTC).isoformat()


@dataclass(frozen=True)
class SelfTestResult:
    """The outcome of the start-up self-test."""

    passed: bool
    detail: str
    at: str


def _finite(probs: dict[str, float]) -> bool:
    return all(isinstance(p, (int, float)) and math.isfinite(p) for p in probs.values())


def self_test(
    predictor: Predictor, cases: list[dict], tolerance: float = SELF_TEST_TOLERANCE
) -> SelfTestResult:
    """Runs known cases through the predictor.

    Args:
        predictor: The model.
        cases: Dicts with ``task`` ("relevance" | "design"), ``title``, ``abstract``,
            and ``question`` / ``expected_score`` (relevance) or ``answer`` (design).
        tolerance: The largest accepted gap from an expected score.

    Returns:
        A failed result naming the first bad case, else a passed one.
    """

    def fail(i: int, why: str) -> SelfTestResult:
        return SelfTestResult(False, f"case {i}: {why}", _now())

    for i, case in enumerate(cases):
        try:
            if case["task"] == TASK_RELEVANCE:
                req = mp.relevance_request(
                    f"selftest-{i}", case["question"], case["title"], case["abstract"]
                )
                probs = predictor.predict(req)["questions"][Q_RELEVANCE]["probabilities"]
                if not _finite(probs):
                    return fail(i, "NaN probabilities")
                got = mp.expected_score(probs)
                if "expected_score" in case and abs(got - case["expected_score"]) > tolerance:
                    return fail(i, f"expected score {got:.3f}, wanted {case['expected_score']}")
            else:
                req = mp.design_request(f"selftest-{i}", case["title"], case["abstract"])
                q = predictor.predict(req)["questions"][Q_DESIGN]
                if not _finite(q["probabilities"]):
                    return fail(i, "NaN probabilities")
                if "answer" in case and q["answer"] != case["answer"]:
                    return fail(i, f"design {q['answer']}, wanted {case['answer']}")
        except Exception as exc:  # a crashing model fails the test, with its reason
            return fail(i, f"{type(exc).__name__}: {exc}")
    return SelfTestResult(True, f"{len(cases)} cases passed", _now())


def _text(payload: dict, key: str, required: bool = True) -> str:
    value = payload.get(key)
    if value is None and not required:
        return ""
    if not isinstance(value, str) or (required and not value.strip()):
        raise BadRequest(
            f"{key} must be a non-empty string" if required else f"{key} must be a string"
        )
    return value


class MantaService:
    """Judges papers with MANTA and records everything to the ledger."""

    def __init__(
        self,
        predictor: Predictor,
        ledger: sqlite3.Connection,
        revision: str,
        info: dict[str, Any],
        self_test: SelfTestResult,
    ) -> None:
        """Sets the service up.

        Args:
            predictor: The model (or a stand-in).
            ledger: An open ledger connection.
            revision: The model revision answered with each judgement.
            info: ``torch``, ``device`` and ``fla_kernel``, for /health.
            self_test: The start-up self-test's result.
        """
        self._predictor = predictor
        self._ledger = ledger
        self._revision = revision
        self._info = info
        self._self_test = self_test
        # One lock for the model and the ledger: record_reference is check-then-insert.
        self._lock = threading.Lock()

    def health(self) -> dict[str, Any]:
        """The service's state, answered even when the self-test failed."""
        t = self._self_test
        return {
            "ready": t.passed,
            "revision": self._revision,
            **self._info,
            "self_test": {"passed": t.passed, "detail": t.detail, "at": t.at},
        }

    def judge(self, payload: dict) -> dict[str, Any]:
        """Judges one paper and records it.

        Args:
            payload: The /v1/judge body.

        Returns:
            The /v1/judge answer.

        Raises:
            NotReady: The self-test failed.
            BadRequest: A field is missing or mistyped.
        """
        if not self._self_test.passed:
            raise NotReady(f"self-test failed: {self._self_test.detail}")
        app = _text(payload, "app")
        question = _text(payload, "question")
        title = _text(payload, "title")
        abstract = _text(payload, "abstract", required=False)
        ids = payload.get("ids") or {}
        if not isinstance(ids, dict) or not all(
            isinstance(k, str) and isinstance(v, str) for k, v in ids.items()
        ):
            raise BadRequest("ids must map strings to strings")
        tasks = payload.get("tasks", list(ALL_TASKS))
        if not isinstance(tasks, list) or not set(tasks) <= set(ALL_TASKS):
            raise BadRequest(f"tasks must be a list of {list(ALL_TASKS)}")
        if TASK_RELEVANCE not in tasks:  # the ledger's verdict columns need a relevance run
            raise BadRequest("tasks must include 'relevance'")

        jid = str(uuid.uuid4())
        started = time.monotonic()
        answer: dict[str, Any] = {"judgement_id": jid, "revision": self._revision}
        tokens, truncated = 0, False
        rel_probs: dict[str, float] = {}
        design: dict[str, Any] | None = None
        score = 0.0
        with self._lock:
            if TASK_RELEVANCE in tasks:
                out = self._predictor.predict(mp.relevance_request(jid, question, title, abstract))
                raw = out["questions"][Q_RELEVANCE]["probabilities"]
                if not _finite(raw):
                    raise ArithmeticError("model gave non-finite relevance probabilities")
                score = mp.expected_score(raw)
                rel_probs = mp.app_scale(raw)
                tokens, truncated = max(tokens, out["prompt_tokens"]), truncated or out["truncated"]
            if TASK_DESIGN in tasks:
                out = self._predictor.predict(mp.design_request(jid, title, abstract))
                q = out["questions"][Q_DESIGN]
                if not _finite(q["probabilities"]):
                    raise ArithmeticError("model gave non-finite design probabilities")
                design = {
                    "probabilities": q["probabilities"],
                    "answer": q["answer"],
                    "probability": q["probabilities"][q["answer"]],
                }
                tokens, truncated = max(tokens, out["prompt_tokens"]), truncated or out["truncated"]
            seconds = time.monotonic() - started
            ml.record_judgement(
                self._ledger,
                ml.Judgement(
                    judgement_id=jid,
                    app=app,
                    question=question,
                    title=title,
                    ids=ids,
                    revision=self._revision,
                    relevance_probabilities=rel_probs,
                    expected_score=score,
                    verdict=mp.verdict(score),
                    cutoff=mp.SHADOW_CUTOFF,
                    design=design["answer"] if design else None,
                    design_probability=design["probability"] if design else None,
                    design_probabilities=design["probabilities"] if design else None,
                    prompt_tokens=tokens,
                    truncated=truncated,
                    seconds=seconds,
                    created_at=_now(),
                ),
            )
        answer.update(seconds=seconds, prompt_tokens=tokens, truncated=truncated)
        if TASK_RELEVANCE in tasks:
            answer["relevance"] = {
                "probabilities": rel_probs,
                "expected_score": score,
                "verdict": mp.verdict(score),
                "cutoff": mp.SHADOW_CUTOFF,
            }
        if design:
            answer["design"] = design
        return answer

    def reference(self, payload: dict) -> bool:
        """Records an app's LLM verdict on a judged paper.

        Args:
            payload: The /v1/reference body.

        Returns:
            False when the judgement is unknown (nothing written).

        Raises:
            BadRequest: A field is missing or mistyped.
        """
        score = payload.get("llm_score")
        design = payload.get("llm_design")
        indexing = payload.get("indexing")
        if score is not None and (isinstance(score, bool) or not isinstance(score, int)):
            raise BadRequest("llm_score must be an integer or null")
        if design is not None and not isinstance(design, str):
            raise BadRequest("llm_design must be a string or null")
        if indexing is not None and not isinstance(indexing, dict):
            raise BadRequest("indexing must be an object or null")
        ref_design, human = mp.indexing_design(indexing)
        ref = ml.Reference(
            judgement_id=_text(payload, "judgement_id"),
            app=_text(payload, "app"),
            llm_model=_text(payload, "llm_model"),
            llm_score=score,
            llm_design=design,
            indexing=indexing,
            indexing_design=ref_design,
            human_indexed=human,
            created_at=_now(),
        )
        with self._lock:
            return ml.record_reference(self._ledger, ref)


def make_server(service: MantaService, port: int = DEFAULT_PORT) -> ThreadingHTTPServer:
    """Builds the HTTP server, bound to loopback only.

    Args:
        service: The service answering requests.
        port: The port; 0 picks a free one.

    Returns:
        A server not yet serving.
    """

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
            logger.debug(format, *args)

        def _send(self, status: int, body: dict) -> None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self) -> None:  # noqa: N802
            if self.path == "/health":
                self._send(HTTP_OK, service.health())
            else:
                self._send(HTTP_NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:  # noqa: N802
            if self.path not in ("/v1/judge", "/v1/reference"):
                self._send(HTTP_NOT_FOUND, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                try:
                    payload = json.loads(self.rfile.read(length) or b"null")
                except ValueError as exc:
                    raise BadRequest(f"bad JSON: {exc}") from exc
                if not isinstance(payload, dict):
                    raise BadRequest("body must be a JSON object")
                if self.path == "/v1/judge":
                    self._send(HTTP_OK, service.judge(payload))
                elif service.reference(payload):
                    self._send(HTTP_OK, {"ok": True})
                else:
                    self._send(HTTP_NOT_FOUND, {"error": "unknown judgement"})
            except BadRequest as exc:
                self._send(HTTP_BAD_REQUEST, {"error": str(exc)})
            except NotReady as exc:
                self._send(HTTP_UNAVAILABLE, {"error": str(exc)})
            except Exception as exc:  # the model or ledger failed: say so, keep serving
                logger.exception("request failed")
                self._send(HTTP_ERROR, {"error": f"{type(exc).__name__}: {exc}"})

    return ThreadingHTTPServer((BIND_HOST, port), Handler)
