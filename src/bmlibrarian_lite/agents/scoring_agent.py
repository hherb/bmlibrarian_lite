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

from ..data_models import LiteDocument, ScoredDocument, EvaluationErrorCode
from ..exceptions import JSONParseError, APIError, RetryExhaustedError
from ..utils import llm_retry, classify_llm_exception
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
            error_code = EvaluationErrorCode.RETRY_EXHAUSTED
            logger.error(
                f"Document {document.id}: Scoring failed after all retries: {e}"
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
        result = self._parse_score_response(response)

        # If parsing returned the default failure, raise to trigger retry
        if result.get("parse_failed", False):
            raise JSONParseError(
                "Could not parse score from response",
                raw_response=response,
            )

        return result

    def score_documents(
        self,
        question: str,
        documents: list[LiteDocument],
        min_score: int = 1,
        progress_callback: Optional[Callable[[int, int], None]] = None,
        max_workers: int = 1,
        cancelled: Optional[threading.Event] = None,
    ) -> list[ScoredDocument]:
        """
        Score multiple documents, optionally in parallel.

        Documents that fail scoring (negative scores) are excluded from results
        but logged for visibility. Use get_failed_documents() on the result
        to identify failures if needed.

        Args:
            question: Research question
            documents: Documents to score
            min_score: Minimum score to include in results (1-5)
            progress_callback: Optional callback(current, total) for progress
            max_workers: Number of parallel workers (1=sequential)
            cancelled: Optional threading.Event; when set, stops processing

        Returns:
            List of scored documents (filtered by min_score), sorted by score descending.
            Failed documents (negative scores) are excluded.
        """
        scored = []
        failed_count = 0
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
                self._collect_scored(scored_doc, scored, min_score, i, total)
                if scored_doc.score < 0:
                    failed_count += 1
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
                        self._collect_scored(scored_doc, scored, min_score, idx, total)
                        if scored_doc.score < 0:
                            failed_count += 1

                    if progress_callback:
                        progress_callback(current, total)

        # Sort by score descending
        scored.sort(key=lambda x: x.score, reverse=True)

        if failed_count > 0:
            logger.warning(
                f"Scoring complete: {len(scored)} passed (score >= {min_score}), "
                f"{failed_count} failed, {total - len(scored) - failed_count} below threshold"
            )
        else:
            logger.info(
                f"Scored {total} documents, {len(scored)} with score >= {min_score}"
            )
        return scored

    def _collect_scored(
        self,
        scored_doc: ScoredDocument,
        scored: list[ScoredDocument],
        min_score: int,
        index: int,
        total: int,
    ) -> None:
        """Collect a scored document result, logging as appropriate."""
        if scored_doc.score < 0:
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

    def _parse_score_response(self, response: str) -> dict:
        """
        Parse LLM response to extract score and explanation.

        Args:
            response: LLM response text

        Returns:
            Dictionary with 'score', 'explanation', and optionally 'parse_failed'.
            If 'parse_failed' is True, the caller should consider retrying.
        """
        # Try to parse as JSON - handle nested objects
        try:
            # Find the outermost JSON object by matching balanced braces
            start_idx = response.find("{")
            if start_idx != -1:
                # Find matching closing brace
                depth = 0
                end_idx = start_idx
                for i, char in enumerate(response[start_idx:], start_idx):
                    if char == "{":
                        depth += 1
                    elif char == "}":
                        depth -= 1
                        if depth == 0:
                            end_idx = i + 1
                            break

                if depth == 0 and end_idx > start_idx:
                    json_str = response[start_idx:end_idx]
                    data = json.loads(json_str)
                    raw_score = data.get("score")
                    # A missing/None score means the model did not actually
                    # score the document. Do NOT default to a valid score here -
                    # fall through to the text/parse-failure handling so the
                    # caller can retry instead of recording a fabricated score.
                    if raw_score is not None:
                        score = int(raw_score)
                        score = max(1, min(5, score))  # Clamp to 1-5

                        # Handle explanation that might be a nested object
                        explanation = data.get("explanation", "")
                        if isinstance(explanation, dict):
                            # Convert nested explanation to string
                            explanation = json.dumps(explanation)

                        return {
                            "score": score,
                            "explanation": explanation,
                        }
        except (json.JSONDecodeError, ValueError, TypeError):
            pass

        # Fallback: try to extract score from text
        score_match = re.search(r'score[:\s]+(\d)', response, re.IGNORECASE)
        if score_match:
            score = int(score_match.group(1))
            score = max(1, min(5, score))
            return {"score": score, "explanation": response}

        # Parse failed - signal this to caller
        logger.warning(f"Could not parse score from: {response}")
        return {
            "score": EvaluationErrorCode.JSON_PARSE_ERROR.value,
            "explanation": "Could not parse response",
            "parse_failed": True,
        }

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
