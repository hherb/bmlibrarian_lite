# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
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

"""
Lite document scoring agent.

This agent evaluates document relevance to a research question using LLM inference.
Documents are scored on a 1-5 scale indicating how relevant they are to answering
the research question.

Includes robust retry logic using tenacity for handling API failures and timeouts.
Errors are reported via negative score values (EvaluationErrorCode enum).
"""

import json
import logging
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, Callable

from ..constants import SCORE_MAX, SCORE_MIN
from ..data_models import (
    LiteDocument,
    ScoredDocument,
    ScoringOutcome,
)
from ..exceptions import AnalysisFailedError, JSONParseError, APIError, RetryExhaustedError
from ..utils import llm_retry, classify_llm_exception, classify_exhausted_retries
from .base import LiteBaseAgent

logger = logging.getLogger(__name__)

# System prompt for document scoring
SCORING_SYSTEM_PROMPT = """You are a medical research relevance assessor. Your task is to evaluate how relevant a document is to answering a specific research question.

Score each document on a scale of 1-5:
- 5: Directly answers the question with strong evidence
- 4: Highly relevant, provides substantial supporting information
- 3: Moderately relevant, contains useful related information
- 2: Marginally relevant, tangentially related
- 1: Not relevant to the research question

Consider:
- How directly the abstract addresses the research question
- The quality and strength of evidence presented
- The specificity of findings to the question topic
- Whether the document provides actionable information

Respond in JSON format:
{
    "score": <1-5>,
    "explanation": "<brief explanation of relevance>"
}"""


def _first_json_object(response: str) -> str | None:
    """The first balanced ``{...}`` in a response, nested objects included.

    Args:
        response: LLM response text.

    Returns:
        The object's text, or None when the response holds no balanced one.
    """
    start_idx = response.find("{")
    if start_idx == -1:
        return None
    depth = 0
    for i, char in enumerate(response[start_idx:], start_idx):
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return response[start_idx:i + 1]
    return None


# "score" and a whole number, then what follows it: a scale ("/10",
# "out of 10") or a range ("1-5"). Either can make the number something
# other than a score on this scale.
_PROSE_SCORE = re.compile(
    r"\bscore\b[:\s]+(?P<value>\d+)(?!\d)"
    r"(?:\s*(?:/|out\s+of)\s*(?P<scale>\d+)|(?P<range>\s*[-–]\s*\d))?",
    re.IGNORECASE,
)


def _score_on_scale(raw: object) -> int | None:
    """A JSON ``score`` value as a score on the scale, if it is one.

    Args:
        raw: The value the model gave.

    Returns:
        The score, or None for a value that is not a whole number on the
        scale. Clamped, "0", "-3" and "42" each became a confident verdict
        the model never gave, and ``int(True)`` read "true" as a 1.
    """
    if isinstance(raw, bool):
        return None
    if isinstance(raw, int):
        value = raw
    elif isinstance(raw, float) and raw.is_integer():
        value = int(raw)
    elif isinstance(raw, str) and raw.strip().isdigit():
        value = int(raw.strip())
    else:
        return None
    return value if SCORE_MIN <= value <= SCORE_MAX else None


def _prose_score(response: str) -> int | None:
    """A score stated in prose, if the first one stated is on the scale.

    Args:
        response: LLM response text.

    Returns:
        The score, or None. "Score: 10/10" read as a 1, and "a score 1-5"
        in a refusal read as one too.
    """
    match = _PROSE_SCORE.search(response)
    if match is None or match.group("range") is not None:
        return None
    scale = match.group("scale")
    if scale is not None and int(scale) != SCORE_MAX:
        return None
    value = int(match.group("value"))
    return value if SCORE_MIN <= value <= SCORE_MAX else None


def parse_score_response(response: str) -> tuple[int, str] | None:
    """Read a relevance score and its explanation from a model's answer.

    The review and the benchmark read answers here, so the two cannot drift:
    the benchmark's own copy turned an answer with no ``score`` -- or none at
    all -- into a 1, a verdict nobody gave (#306).

    An answer that is a JSON object is read as that object alone: a
    ``score`` that is missing, null, not a number or off the scale makes it
    unreadable, and the prose fallback is never searched in it -- that found
    a digit in the explanation of an answer that declined to score.

    Args:
        response: LLM response text.

    Returns:
        The score and the explanation; or None when the answer holds no score
        on the scale, which the caller records as a failure and never as a
        score.
    """
    json_str = _first_json_object(response)
    if json_str is not None:
        try:
            data = json.loads(json_str)
        except json.JSONDecodeError:
            data = None
        if isinstance(data, dict):
            score = _score_on_scale(data.get("score"))
            if score is None:
                logger.warning(f"No score on the scale in: {response}")
                return None
            explanation = data.get("explanation", "")
            if explanation is None:
                explanation = ""
            elif not isinstance(explanation, str):
                explanation = json.dumps(explanation)
            return score, explanation

    # Fallback: a score stated in prose
    prose_score = _prose_score(response)
    if prose_score is not None:
        return prose_score, response

    logger.warning(f"Could not parse score from: {response}")
    return None


class LiteScoringAgent(LiteBaseAgent):
    """
    Stateless document scoring agent.

    Evaluates document relevance to a research question using LLM inference.
    Each document is scored independently on a 1-5 scale.

    This agent:
    1. Takes a research question and document
    2. Uses LLM to evaluate relevance
    3. Returns a score (1-5) with explanation

    The agent is stateless - each scoring call is independent.
    """

    TASK_ID = "document_scoring"

    def score_document(
        self,
        question: str,
        document: LiteDocument,
    ) -> ScoredDocument:
        """
        Score a single document's relevance to the research question.

        Uses tenacity-based retry logic for API failures. On failure after
        all retries, returns a ScoredDocument with a negative score
        representing the error code (see EvaluationErrorCode enum).

        Args:
            question: Research question
            document: Document to score

        Returns:
            ScoredDocument with score and explanation.
            Score will be negative (EvaluationErrorCode value) on failure.
        """
        user_prompt = f"""Research Question: {question}

Document Title: {document.title}
Authors: {document.formatted_authors}
Year: {document.year or 'Unknown'}
Journal: {document.journal or 'Unknown'}

Abstract:
{document.abstract}

Evaluate the relevance of this document to the research question."""

        messages = [
            self._create_system_message(SCORING_SYSTEM_PROMPT),
            self._create_user_message(user_prompt),
        ]

        try:
            result = self._score_with_retry(messages)
            return ScoredDocument(
                document=document,
                score=result["score"],
                explanation=result["explanation"],
            )
        except RetryExhaustedError as e:
            # The retries were spent on something -- an unreachable provider,
            # a refused key -- and only that says what the user can do about
            # it. Recording the wrapper instead left every outage advising
            # "try again later" (#301 review).
            error_code = classify_exhausted_retries(e)
            logger.error(
                f"Document {document.id}: Scoring failed after all retries "
                f"with {error_code.name}: {e}"
            )
            return ScoredDocument(
                document=document,
                score=error_code.value,
                explanation=f"Scoring failed after retries: {error_code.description}",
            )
        except Exception as e:
            error_code = classify_llm_exception(e)
            logger.error(
                f"Document {document.id}: Scoring failed with {error_code.name}: {e}"
            )
            return ScoredDocument(
                document=document,
                score=error_code.value,
                explanation=f"Scoring failed: {error_code.description}",
            )

    @llm_retry(max_retries=3, retry_on_json_error=True)
    def _score_with_retry(self, messages: list) -> dict:
        """
        Internal method that performs the actual scoring with retry logic.

        This method is decorated with @llm_retry to automatically retry
        on API failures, timeouts, and connection errors.

        Args:
            messages: LLM messages for scoring

        Returns:
            Dictionary with 'score' and 'explanation' keys

        Raises:
            JSONParseError: If response cannot be parsed
            APIError: If API call fails
            RetryExhaustedError: If all retries exhausted
        """
        response = self._chat(messages, temperature=0.1, json_mode=True)
        parsed = parse_score_response(response)

        # An answer holding no score is retried, and never recorded as one
        if parsed is None:
            raise JSONParseError(
                "Could not parse score from response",
                raw_response=response,
            )

        score, explanation = parsed
        return {"score": score, "explanation": explanation}

    def score_documents(
        self,
        question: str,
        documents: list[LiteDocument],
        min_score: int = 1,
        progress_callback: Optional[Callable[[int, int], None]] = None,
        max_workers: int = 1,
        cancelled: Optional[threading.Event] = None,
    ) -> ScoringOutcome:
        """
        Score multiple documents, optionally in parallel.

        Documents the model could not score are kept apart from documents it
        scored below the threshold (#262): both are missing from the result,
        but only the second is the literature's answer. When no document
        could be scored at all there is nothing to proceed on, so this raises
        rather than answering with an empty result.

        Args:
            question: Research question
            documents: Documents to score
            min_score: Minimum score to include in the accepted list (1-5)
            progress_callback: Optional callback(current, total) for progress
            max_workers: Number of parallel workers (1=sequential)
            cancelled: Optional threading.Event; when set, stops processing

        Returns:
            The outcome: the documents that met the threshold, sorted by score
            descending; the documents that failed; and how many were
            attempted.

        Raises:
            AnalysisFailedError: If every document attempted failed to score.
                "No documents scored 3 or higher" would read as the
                literature's answer.
        """
        scored: list[ScoredDocument] = []
        failed: list[ScoredDocument] = []
        attempted = 0
        total = len(documents)

        logger.info(
            f"Scoring {total} documents for question: {question[:50]}... "
            f"(workers={max_workers})"
        )

        if max_workers <= 1:
            # Sequential path — no threading overhead
            for i, doc in enumerate(documents):
                if cancelled and cancelled.is_set():
                    logger.info("Scoring cancelled")
                    break

                if progress_callback:
                    progress_callback(i + 1, total)

                scored_doc = self.score_document(question, doc)
                attempted += 1
                self._collect_scored(scored_doc, scored, failed, min_score, i, total)
        else:
            # Parallel path
            lock = threading.Lock()
            completed = 0

            def _score_one(doc: LiteDocument) -> ScoredDocument:
                return self.score_document(question, doc)

            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                futures = {
                    executor.submit(_score_one, doc): i
                    for i, doc in enumerate(documents)
                }
                for future in as_completed(futures):
                    if cancelled and cancelled.is_set():
                        logger.info("Scoring cancelled, cancelling pending tasks")
                        for f in futures:
                            f.cancel()
                        break

                    idx = futures[future]
                    scored_doc = future.result()

                    with lock:
                        completed += 1
                        current = completed
                        attempted += 1
                        self._collect_scored(scored_doc, scored, failed, min_score, idx, total)

                    if progress_callback:
                        progress_callback(current, total)

        # Sort by score descending
        scored.sort(key=lambda x: x.score, reverse=True)

        outcome = ScoringOutcome(accepted=scored, failed=failed, documents_attempted=attempted)
        shortfall = outcome.shortfall
        if shortfall is not None:
            logger.warning(
                f"Scoring complete: {len(scored)} passed (score >= {min_score}), "
                f"{len(failed)} failed, {attempted - len(scored) - len(failed)} below threshold"
            )
            if shortfall.nothing_survived and not (cancelled and cancelled.is_set()):
                # Answering with an empty result here is what made an
                # unreachable provider read as a literature with nothing
                # relevant in it (#262). A cancelled run is exempt: its
                # attempted set is whatever the user stopped it after, so one
                # timed-out document before a cancel would otherwise report
                # the stage as a total failure (#301 review).
                raise AnalysisFailedError(shortfall)
        else:
            logger.info(
                f"Scored {attempted} documents, {len(scored)} with score >= {min_score}"
            )
        return outcome

    def _collect_scored(
        self,
        scored_doc: ScoredDocument,
        scored: list[ScoredDocument],
        failed: list[ScoredDocument],
        min_score: int,
        index: int,
        total: int,
    ) -> None:
        """Collect a scored document result, logging as appropriate.

        Args:
            scored_doc: The result to collect.
            scored: The documents that met the threshold, appended to.
            failed: The documents that could not be scored, appended to.
            min_score: Minimum score to accept.
            index: The document's position, for the log line.
            total: How many documents there are, for the log line.
        """
        if scored_doc.score < 0:
            failed.append(scored_doc)
            logger.warning(
                f"Document {scored_doc.document.id}: scoring failed with error code "
                f"{scored_doc.score} ({index+1}/{total})"
            )
            return

        if scored_doc.score >= min_score:
            scored.append(scored_doc)

        logger.debug(
            f"Document {scored_doc.document.id}: score={scored_doc.score} "
            f"({index+1}/{total})"
        )

    def filter_by_score(
        self,
        scored_documents: list[ScoredDocument],
        min_score: int = 3,
    ) -> list[ScoredDocument]:
        """
        Filter scored documents by minimum score.

        Args:
            scored_documents: List of scored documents
            min_score: Minimum score to include

        Returns:
            Filtered list of scored documents
        """
        return [d for d in scored_documents if d.score >= min_score]

    def get_top_documents(
        self,
        scored_documents: list[ScoredDocument],
        n: int = 10,
    ) -> list[ScoredDocument]:
        """
        Get top N scoring documents.

        Args:
            scored_documents: List of scored documents
            n: Number of documents to return

        Returns:
            Top N documents by score
        """
        sorted_docs = sorted(scored_documents, key=lambda x: x.score, reverse=True)
        return sorted_docs[:n]
