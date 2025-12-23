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

    @llm_retry(max_retries=3)
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
    ) -> list[ScoredDocument]:
        """
        Score multiple documents.

        Documents that fail scoring (negative scores) are excluded from results
        but logged for visibility. Use get_failed_documents() on the result
        to identify failures if needed.

        Args:
            question: Research question
            documents: Documents to score
            min_score: Minimum score to include in results (1-5)
            progress_callback: Optional callback(current, total) for progress

        Returns:
            List of scored documents (filtered by min_score), sorted by score descending.
            Failed documents (negative scores) are excluded.
        """
        scored = []
        failed_count = 0
        total = len(documents)

        logger.info(f"Scoring {total} documents for question: {question[:50]}...")

        for i, doc in enumerate(documents):
            if progress_callback:
                progress_callback(i + 1, total)

            scored_doc = self.score_document(question, doc)

            # Check for error (negative score)
            if scored_doc.score < 0:
                failed_count += 1
                logger.warning(
                    f"Document {doc.id}: scoring failed with error code "
                    f"{scored_doc.score} ({i+1}/{total})"
                )
                continue

            if scored_doc.score >= min_score:
                scored.append(scored_doc)

            logger.debug(
                f"Document {doc.id}: score={scored_doc.score} "
                f"({i+1}/{total})"
            )

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

    def _parse_score_response(self, response: str) -> dict:
        """
        Parse LLM response to extract score and explanation.

        Args:
            response: LLM response text

        Returns:
            Dictionary with 'score', 'explanation', and optionally 'parse_failed'.
            If 'parse_failed' is True, the caller should consider retrying.
        """
        # Try to parse as JSON
        try:
            # Extract JSON from response (handles markdown code blocks)
            json_match = re.search(r'\{[^}]+\}', response, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group())
                score = int(data.get("score", 1))
                score = max(1, min(5, score))  # Clamp to 1-5
                return {
                    "score": score,
                    "explanation": data.get("explanation", ""),
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
        logger.warning(f"Could not parse score from: {response[:100]}")
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
