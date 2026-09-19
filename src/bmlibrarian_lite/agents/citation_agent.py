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
Lite citation extraction agent.

This agent extracts relevant passages from documents that help answer
a research question. It identifies specific quotes and findings that
can be used as citations in a research report.

Includes robust retry logic using tenacity for handling API failures and timeouts.
"""

import json
import logging
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Optional, Callable

from ..data_models import (
    Citation,
    CitationOutcome,
    EvaluationErrorCode,
    ExtractionFailure,
    ScoredDocument,
)
from ..exceptions import JSONParseError, RetryExhaustedError
from ..utils import llm_retry, classify_llm_exception, classify_exhausted_retries
from .base import LiteBaseAgent

logger = logging.getLogger(__name__)


def is_readable_passage(passage: object) -> bool:
    """Whether one passage carries text that can be quoted.

    Args:
        passage: One entry of the response's ``passages`` list.

    Returns:
        True for an object whose ``text`` is a string with something in it.
        ``{"text": null}`` would become a citation with no passage, which
        storage refuses -- ending the whole review over one quote.
    """
    if not isinstance(passage, dict):
        return False
    text = passage.get("text")
    return isinstance(text, str) and bool(text.strip())


def readable_passages(data: object) -> list[dict[str, Any]] | None:
    """The readable passages a parsed extraction response holds, or None.

    An empty list is an answer: the model read the text and found nothing
    quotable for the question (#303). Only a response holding no passage
    list, or one whose every passage arrived in a shape we cannot use, is a
    failure -- and only a failure is worth retrying. A partial answer keeps
    what it can, and the rest is logged.

    Args:
        data: Whatever parsing the response produced.

    Returns:
        The passages with quotable text, possibly none of them, or None if
        the response carries no readable answer.
    """
    if not isinstance(data, dict):
        return None
    passages = data.get("passages")
    if not isinstance(passages, list):
        return None
    readable = [p for p in passages if is_readable_passage(p)]
    if passages and not readable:
        return None
    if len(readable) < len(passages):
        logger.warning(
            f"Dropped {len(passages) - len(readable)} of {len(passages)} "
            f"passages in a shape that cannot be quoted: {passages!r}"
        )
    return readable


# System prompt for citation extraction
CITATION_SYSTEM_PROMPT = """You are a medical research citation extractor. Your task is to identify the most relevant passages from a document that help answer a research question.

Extract 1-3 key passages that:
1. Directly address the research question
2. Contain specific findings, data, or conclusions
3. Are self-contained and understandable out of context
4. Could be quoted in a research summary

Guidelines:
- Extract exact quotes from the abstract when possible
- Focus on passages with specific numbers, percentages, or outcomes
- Include key conclusions or recommendations
- Each passage should add unique value

Respond in JSON format:
{
    "passages": [
        {
            "text": "<exact or close quote from the abstract>",
            "relevance": "<brief explanation of why this passage is relevant>"
        }
    ]
}"""


class LiteCitationAgent(LiteBaseAgent):
    """
    Stateless citation extraction agent.

    Extracts relevant passages from documents that answer a research question.
    These passages can be used as citations in a research report.

    This agent:
    1. Takes a research question and scored document
    2. Uses LLM to identify relevant passages
    3. Returns citations with source attribution
    """

    TASK_ID = "citation_extraction"

    def extract_citations(
        self,
        question: str,
        scored_doc: ScoredDocument,
    ) -> list[Citation]:
        """
        Extract citations from a scored document.

        Uses tenacity-based retry logic for API failures. On complete failure
        after all retries, returns an empty list rather than a fallback
        citation. An empty list is therefore ambiguous here -- nothing
        quotable, or nothing readable -- so a caller that must tell the two
        apart uses :meth:`extract_all_citations`, whose outcome records the
        failures (#303).

        Args:
            question: Research question
            scored_doc: Document with relevance score

        Returns:
            List of extracted citations: empty when the document held nothing
            quotable, and also when it could not be read.
        """
        citations, _ = self._extract_with_cause(question, scored_doc)
        return citations

    def _extract_with_cause(
        self,
        question: str,
        scored_doc: ScoredDocument,
    ) -> tuple[list[Citation], EvaluationErrorCode | None]:
        """Extract citations from a document, keeping why it failed.

        The cause is what tells a failed extraction apart from a document
        with nothing to say (#261); :meth:`extract_citations` drops it, and
        :meth:`extract_all_citations` records it.

        Args:
            question: Research question
            scored_doc: Document with relevance score

        Returns:
            The citations and ``None``; or an empty list and the error code
            classifying the failure.
        """
        doc = scored_doc.document

        user_prompt = f"""Research Question: {question}

Document Title: {doc.title}
Authors: {doc.formatted_authors}
Year: {doc.year or 'Unknown'}
Journal: {doc.journal or 'Unknown'}
Relevance Score: {scored_doc.score}/5

Abstract:
{doc.abstract}

Extract the most relevant passages that help answer the research question."""

        messages = [
            self._create_system_message(CITATION_SYSTEM_PROMPT),
            self._create_user_message(user_prompt),
        ]

        try:
            passages = self._extract_with_retry(messages)

            citations = []
            for passage in passages:
                citation = Citation(
                    document=doc,
                    passage=passage["text"],
                    relevance_score=scored_doc.score,
                    context=passage.get("relevance", ""),
                )
                citations.append(citation)

            return citations, None

        except RetryExhaustedError as e:
            # See scoring_agent: the wrapper is not the cause, and only the
            # cause tells the user what to do (#301 review).
            error_code = classify_exhausted_retries(e)
            logger.error(
                f"Document {doc.id}: Citation extraction failed after all "
                f"retries with {error_code.name}: {e}"
            )
            return [], error_code
        except Exception as e:
            error_code = classify_llm_exception(e)
            logger.error(
                f"Document {doc.id}: Citation extraction failed with "
                f"{error_code.name}: {e}"
            )
            return [], error_code

    @llm_retry(max_retries=3, retry_on_json_error=True)
    def _extract_with_retry(self, messages: list) -> list[dict[str, Any]]:
        """
        Internal method that performs citation extraction with retry logic.

        This method is decorated with @llm_retry to automatically retry
        on API failures and JSON parse errors.

        Args:
            messages: LLM messages for extraction

        Returns:
            List of passage dictionaries with 'text' and optional 'relevance'

        Raises:
            JSONParseError: If response cannot be parsed
            RetryExhaustedError: If all retries exhausted
        """
        response = self._chat(messages, temperature=0.1, json_mode=True)
        passages = self._parse_citation_response(response)

        # An empty list is the model's answer that nothing here is quotable,
        # and retrying will not change it. Only a response we could not read
        # is a parse failure (#303).
        if passages is None:
            raise JSONParseError(
                "Could not read passages from response",
                raw_response=response,
            )

        return passages

    def extract_all_citations(
        self,
        question: str,
        scored_documents: list[ScoredDocument],
        min_score: int = 3,
        progress_callback: Optional[Callable[[int, int], None]] = None,
        max_workers: int = 1,
        cancelled: Optional[threading.Event] = None,
    ) -> CitationOutcome:
        """
        Extract citations from all scored documents, optionally in parallel.

        Extraction continues past a document it could not read, and the
        outcome says how many were lost and why (#261): a report built on no
        citations must not tell the reader the literature was silent when
        nobody could read it.

        Args:
            question: Research question
            scored_documents: Documents to extract from
            min_score: Minimum score to process
            progress_callback: Optional callback(current, total)
            max_workers: Number of parallel workers (1=sequential)
            cancelled: Optional threading.Event; when set, stops processing

        Returns:
            The outcome: the citations, how many documents were attempted,
            and which could not be read, with why.
        """
        all_citations: list[Citation] = []
        failed: list[ExtractionFailure] = []
        attempted = 0
        # Filter out documents with negative scores (error codes) and below
        # threshold. A document listed twice is one document: read twice, its
        # failure would be counted twice, which the outcome refuses -- and
        # extraction never raises (#310 review).
        eligible: list[ScoredDocument] = []
        seen_ids: set[str] = set()
        for scored_doc in scored_documents:
            if scored_doc.score >= min_score and scored_doc.document.id not in seen_ids:
                seen_ids.add(scored_doc.document.id)
                eligible.append(scored_doc)
        total = len(eligible)

        logger.info(
            f"Extracting citations from {total} documents (workers={max_workers})"
        )

        if max_workers <= 1:
            # Sequential path
            for i, scored_doc in enumerate(eligible):
                if cancelled and cancelled.is_set():
                    logger.info("Citation extraction cancelled")
                    break

                if progress_callback:
                    progress_callback(i + 1, total)

                citations, cause = self._extract_with_cause(question, scored_doc)
                attempted += 1

                if cause is not None:
                    failed.append(ExtractionFailure(scored_doc.document, cause))
                    logger.warning(
                        f"Document {scored_doc.document.id}: No citations extracted "
                        f"({i+1}/{total})"
                    )
                else:
                    all_citations.extend(citations)
                    logger.debug(
                        f"Extracted {len(citations)} citations from "
                        f"{scored_doc.document.id}"
                    )
        else:
            # Parallel path
            lock = threading.Lock()
            completed = 0

            def _extract_one(
                doc: ScoredDocument,
            ) -> tuple[list[Citation], EvaluationErrorCode | None]:
                return self._extract_with_cause(question, doc)

            with ThreadPoolExecutor(max_workers=max_workers) as executor:
                futures = {
                    executor.submit(_extract_one, scored_doc): i
                    for i, scored_doc in enumerate(eligible)
                }
                for future in as_completed(futures):
                    if cancelled and cancelled.is_set():
                        logger.info("Citation extraction cancelled, cancelling pending tasks")
                        for f in futures:
                            f.cancel()
                        break

                    idx = futures[future]
                    citations, cause = future.result()
                    document = eligible[idx].document
                    doc_id = document.id

                    with lock:
                        completed += 1
                        current = completed
                        attempted += 1
                        if cause is not None:
                            failed.append(ExtractionFailure(document, cause))
                            logger.warning(
                                f"Document {doc_id}: No citations extracted "
                                f"({current}/{total})"
                            )
                        else:
                            all_citations.extend(citations)
                            logger.debug(
                                f"Extracted {len(citations)} citations from {doc_id}"
                            )

                    if progress_callback:
                        progress_callback(current, total)

        if failed:
            logger.warning(
                f"Citation extraction complete: {len(all_citations)} citations from "
                f"{attempted - len(failed)} documents, {len(failed)} failed"
            )
        else:
            logger.info(
                f"Extracted {len(all_citations)} total citations from {attempted} documents"
            )
        return CitationOutcome(
            citations=all_citations,
            documents_attempted=attempted,
            failed=tuple(failed),
        )

    def _parse_citation_response(
        self, response: str
    ) -> list[dict[str, Any]] | None:
        """
        Parse LLM response to extract passages.

        Args:
            response: LLM response text

        Returns:
            The readable passage dictionaries the response holds -- an empty
            list when the model found nothing quotable -- or None when it
            carries no readable answer: no passage list, or none of its
            passages usable (#303). See :func:`readable_passages`.
        """
        # Strip markdown code fences if present
        cleaned = response.strip()
        if cleaned.startswith("```"):
            # Remove opening fence (```json or ```)
            cleaned = re.sub(r"^```(?:json)?\s*\n?", "", cleaned)
            # Remove closing fence
            cleaned = re.sub(r"\n?```\s*$", "", cleaned)

        try:
            # Try parsing the entire cleaned response as JSON first
            # This is the most reliable method
            passages = readable_passages(json.loads(cleaned))
            if passages is not None:
                return passages

        except (json.JSONDecodeError, ValueError, TypeError) as e:
            logger.debug(f"Direct JSON parsing failed: {e}")

        try:
            # Fallback: Find JSON object in response by matching braces
            # Find the first '{' and try to parse from there
            start_idx = response.find("{")
            if start_idx != -1:
                # Try progressively longer substrings to find valid JSON
                brace_count = 0
                for i, char in enumerate(response[start_idx:], start=start_idx):
                    if char == "{":
                        brace_count += 1
                    elif char == "}":
                        brace_count -= 1
                        if brace_count == 0:
                            # Found matching closing brace
                            json_str = response[start_idx:i + 1]
                            try:
                                passages = readable_passages(json.loads(json_str))
                                if passages is not None:
                                    return passages
                            except json.JSONDecodeError:
                                pass
                            break

        except Exception as e:
            logger.debug(f"Brace-matching JSON parsing failed: {e}")

        # Nothing here we can read as an answer; the caller retries.
        logger.warning(f"Could not parse citations from: {response}")
        return None

    def group_citations_by_document(
        self,
        citations: list[Citation],
    ) -> dict[str, list[Citation]]:
        """
        Group citations by their source document.

        Args:
            citations: List of citations

        Returns:
            Dictionary mapping document IDs to their citations
        """
        grouped: dict[str, list[Citation]] = {}
        for citation in citations:
            doc_id = citation.document.id
            if doc_id not in grouped:
                grouped[doc_id] = []
            grouped[doc_id].append(citation)
        return grouped

    def deduplicate_citations(
        self,
        citations: list[Citation],
    ) -> list[Citation]:
        """
        Remove duplicate citations based on passage text.

        Args:
            citations: List of citations

        Returns:
            Deduplicated list of citations
        """
        seen_passages: set[str] = set()
        unique_citations = []

        for citation in citations:
            # Normalize passage for comparison
            normalized = citation.passage.strip().lower()
            if normalized not in seen_passages:
                seen_passages.add(normalized)
                unique_citations.append(citation)

        return unique_citations
