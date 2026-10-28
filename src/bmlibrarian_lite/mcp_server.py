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

"""MCP server: exposes bmlibrarian_lite as an expert medical fact-checker.

Tools:
    fact_check_claim   – Full pipeline (search → score → cite → report)
    search_literature  – Search PubMed/Europe PMC for articles
    get_document_fulltext – Retrieve full text by PMID/DOI/PMC ID
    ask_document       – RAG-based Q&A on a loaded document
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from functools import partial
from typing import Any

from bmlib.publications.retraction_status import RetractionStatus
from mcp.server import Server
from mcp.server.session import ServerSession
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.agents.interrogation_agent import LiteInterrogationAgent
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.analysis_failures import (
    advice_for_causes,
    analysis_failure_advice,
    with_analysis_shortfall_notice,
    without_analysis_shortfall_notice,
)
from bmlibrarian_lite.browser_rescue import RescueSubject, queue_challenged_copies
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    AnalysisShortfall,
    DocumentSource,
    LiteDocument,
    RetrievalShortfall,
    SearchProvider,
)
from bmlibrarian_lite.elsevier_api import ElsevierCredentials
from bmlibrarian_lite.exceptions import (
    AnalysisFailedError,
    LiteError,
    RefusedResponseError,
    SearchFailedError,
    TruncatedResponseError,
)
from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer
from bmlibrarian_lite.identifiers import canonical_pmid, read_caller_ids
from bmlibrarian_lite.llm import LLMClient
from bmlibrarian_lite.retraction_checks import RetractionChecker, build_retraction_checker
from bmlibrarian_lite.retraction_screen import (
    RetractionScreen,
    UnbuiltChecker,
    screen_with_fallback,
    unchecked_check,
)
from bmlibrarian_lite.retraction_store import PaperCheck
from bmlibrarian_lite.retraction_text import (
    paper_status_line,
    with_retraction_notice,
    without_retraction_notice,
)
from bmlibrarian_lite.search_failures import (
    retrieval_shortfalls_from_metadata,
    search_failure_advice,
    with_search_shortfall_notice,
)
from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.utils import classify_llm_exception

logger = logging.getLogger(__name__)

# Tells a calling agent how an incomplete search is reported (#247).
_INCOMPLETE_SEARCH_DESCRIPTION = (
    "If a literature source or part of a retrieval fails, the result lists "
    "what is missing in retrieval_shortfalls; if failures leave nothing "
    "retrieved, an error is returned rather than an empty result."
)

# Tells a calling agent how a failed scoring or citation extraction is
# reported (#261, #262).
_INCOMPLETE_ANALYSIS_DESCRIPTION = (
    "If the model cannot score or read some of the documents, the result "
    "lists what was lost in analysis_shortfalls and the report opens with a "
    "notice; if no document could be scored at all, an error is returned "
    "rather than a report saying nothing was relevant."
)

# Tells a calling agent how retracted papers are handled.
_RETRACTION_SCREEN_DESCRIPTION = (
    "Retracted papers are left out before anything else; retraction lists them "
    "(left_out) and counts the papers whose status could not be checked "
    "(unchecked). Each remaining paper carries its retraction_status: one "
    "under an expression of concern, or not checked, says so."
)
_RETRACTION_STATUS_DESCRIPTION = (
    "The result opens with retraction_status; unless the paper is clear, the "
    "text opens with its status line (e.g. 'Retracted on ...', 'Retraction "
    "status not checked ...'). Never cite a paper whose status says Retracted."
)

_PROVIDER_MAP = {
    "pubmed": SearchProvider.PUBMED,
    "europepmc": SearchProvider.EUROPEPMC,
    "both": SearchProvider.BOTH,
}

# Total progress steps for fact_check_claim pipeline.
# search(1) + score(N) + cite(N) + report(1) — N determined at runtime.
_FC_SEARCH_STEP = 1
_FC_REPORT_STEP = 1


class _ProgressReporter:
    """Bridge sync progress callbacks to async MCP progress notifications.

    Created per-request when the client supplies a progress token.
    Callable from any thread — uses ``run_coroutine_threadsafe`` to post
    the async notification back to the event loop.
    """

    def __init__(
        self,
        loop: asyncio.AbstractEventLoop,
        session: ServerSession,
        token: str | int,
    ) -> None:
        self._loop = loop
        self._session = session
        self._token = token
        self._current: float = 0
        self._total: float | None = None

    def set_total(self, total: float) -> None:
        """Set the total number of progress steps."""
        self._total = total

    def advance(self, message: str, steps: float = 1) -> None:
        """Advance progress and send a notification."""
        self._current += steps
        coro = self._session.send_progress_notification(
            progress_token=self._token,
            progress=self._current,
            total=self._total,
            message=message,
        )
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        try:
            future.result(timeout=5)
        except Exception:
            logger.debug("Failed to send progress notification", exc_info=True)

    def make_callback(self, prefix: str) -> Callable[[int, int], None]:
        """Return a callback compatible with agent ``progress_callback`` signatures.

        Args:
            prefix: Label prepended to each notification (e.g. "Scoring").

        Returns:
            A ``(current, total) -> None`` callback.
        """
        def _cb(current: int, total: int) -> None:
            self.advance(f"{prefix} ({current}/{total})")
        return _cb


@dataclass
class _AgentsContext:
    """Shared resources for all MCP tool handlers."""

    config: LiteConfig
    storage: LiteStorage
    llm_client: LLMClient
    search_agent: LiteSearchAgent
    scoring_agent: LiteScoringAgent
    citation_agent: LiteCitationAgent
    reporting_agent: LiteReportingAgent
    interrogation_agent: LiteInterrogationAgent
    fulltext_discoverer: FulltextDiscoverer


# -- Tool definitions --------------------------------------------------------

TOOLS = [
    Tool(
        name="fact_check_claim",
        description=(
            "Check a medical claim or research question against biomedical "
            "literature. Searches PubMed/Europe PMC, scores documents for "
            "relevance, extracts supporting citations, and generates an "
            "evidence synthesis report with references. "
            "Long-running operation (1-5 minutes depending on result count). "
            "An incomplete search's report opens with a notice saying what is missing. "
            + _INCOMPLETE_SEARCH_DESCRIPTION
            + " "
            + _INCOMPLETE_ANALYSIS_DESCRIPTION
            + " "
            + _RETRACTION_SCREEN_DESCRIPTION
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "claim": {
                    "type": "string",
                    "description": "Medical claim or research question to fact-check",
                },
                "max_results": {
                    "type": "integer",
                    "default": 20,
                    "description": "Maximum articles to retrieve (5-100)",
                },
                "min_score": {
                    "type": "integer",
                    "default": 3,
                    "description": "Minimum relevance score 1-5 to include in report",
                },
                "search_provider": {
                    "type": "string",
                    "enum": ["pubmed", "europepmc", "both"],
                    "default": "pubmed",
                    "description": "Literature database to search",
                },
                "include_preprints": {
                    "type": "boolean",
                    "default": False,
                    "description": "Include preprints (Europe PMC only)",
                },
            },
            "required": ["claim"],
        },
    ),
    Tool(
        name="search_literature",
        description=(
            "Search biomedical literature databases (PubMed, Europe PMC) for "
            "articles matching a research question. Returns document metadata "
            "including title, authors, abstract, and identifiers. "
            "Does not score or analyse results; total_results counts the "
            "papers that were not left out as retracted. "
            + _INCOMPLETE_SEARCH_DESCRIPTION
            + " "
            + _RETRACTION_SCREEN_DESCRIPTION
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Research question or search query",
                },
                "max_results": {
                    "type": "integer",
                    "default": 20,
                    "description": "Maximum number of results (5-100)",
                },
                "search_provider": {
                    "type": "string",
                    "enum": ["pubmed", "europepmc", "both"],
                    "default": "pubmed",
                    "description": "Literature database to search",
                },
                "include_preprints": {
                    "type": "boolean",
                    "default": False,
                    "description": "Include preprints (Europe PMC only)",
                },
            },
            "required": ["query"],
        },
    ),
    Tool(
        name="get_document_fulltext",
        description=(
            "Retrieve the full text of a biomedical article by its identifier. "
            "Tries Europe PMC XML, cached PDFs, and PDF download in order. "
            "Returns markdown-formatted content. Also loads the document for "
            "subsequent ask_document calls: interrogation_available says "
            "whether that succeeded, and interrogation_error why it did not. "
            "On failure, absence_established says whether this article was "
            "shown to have no retrievable full text. When it is false, the "
            "sources were not all asked or did not all answer, so the absence "
            "is ours and not the article's: do not report that no full text "
            "exists. "
            + _RETRACTION_STATUS_DESCRIPTION
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "pmid": {
                    "type": "string",
                    "description": "PubMed ID (e.g. '39521399')",
                },
                "doi": {
                    "type": "string",
                    "description": "Digital Object Identifier",
                },
                "pmc_id": {
                    "type": "string",
                    "description": "PubMed Central ID (e.g. 'PMC1234567')",
                },
            },
        },
    ),
    Tool(
        name="ask_document",
        description=(
            "Ask a question about a specific biomedical article using RAG. "
            "The document must first be loaded via get_document_fulltext. "
            "Returns an answer grounded in the document content. "
            + _RETRACTION_STATUS_DESCRIPTION
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "question": {
                    "type": "string",
                    "description": "Question to ask about the document",
                },
                "document_id": {
                    "type": "string",
                    "description": (
                        "Document ID (returned by get_document_fulltext or "
                        "fact_check_claim, e.g. 'pmid-39521399')"
                    ),
                },
            },
            "required": ["question", "document_id"],
        },
    ),
]


# -- Handlers ----------------------------------------------------------------


def _shortfalls_payload(shortfalls: Sequence[RetrievalShortfall]) -> list[dict[str, Any]]:
    """Describe what a search is missing, for a calling agent.

    Args:
        shortfalls: What the search is missing.

    Returns:
        One entry per shortfall: its stored fields plus a sentence-ready
        ``description``. Empty when the search was complete.
    """
    return [{**shortfall.to_dict(), "description": shortfall.describe()} for shortfall in shortfalls]


def _analysis_shortfalls_payload(
    shortfalls: Sequence[AnalysisShortfall],
) -> list[dict[str, Any]]:
    """Describe what the analysis lost, for a calling agent.

    Args:
        shortfalls: What scoring and citation extraction could not read.

    Returns:
        One entry per shortfall: its stored fields plus a sentence-ready
        ``description``. Empty when every document was analysed.
    """
    return [
        {**shortfall.to_dict(), "description": shortfall.describe()}
        for shortfall in shortfalls
    ]


# Where a failure carries what the analysis had already lost before it. The
# shortfalls are a local of the handler, so an exception raised after them --
# report generation, since #263 made it raise -- would otherwise return an
# error naming only itself, and the documents scoring lost would go with it.
_CARRIED_SHORTFALLS_ATTR = "_bmll_carried_analysis_shortfalls"


def _carrying_analysis_shortfalls(
    exc: Exception, shortfalls: Sequence[AnalysisShortfall]
) -> Exception:
    """Attach what the analysis already lost to a failure that came after it.

    Args:
        exc: The failure to report.
        shortfalls: What scoring and extraction had lost by then.

    Returns:
        The same exception, for raising, carrying the shortfalls so
        :func:`_error_payload` can report them beside it.
    """
    if shortfalls:
        setattr(exc, _CARRIED_SHORTFALLS_ATTR, tuple(shortfalls))
    return exc


def _carried_analysis_shortfalls(exc: Exception) -> list[AnalysisShortfall]:
    """Read what a failure carries from the stages before it.

    Args:
        exc: The failure being reported.

    Returns:
        The shortfalls attached by :func:`_carrying_analysis_shortfalls`, or
        an empty list.
    """
    return list(getattr(exc, _CARRIED_SHORTFALLS_ATTR, ()))


def _build_checker(ctx: _AgentsContext, *, refresh_export: bool = False) -> RetractionChecker:
    """Build a retraction checker for one tool call; ``screen_with_fallback`` closes it.

    Args:
        ctx: Shared agent context (config and storage).
        refresh_export: Whether the checker may download the export (the
            fact-check workflow does; a single-paper tool does not).

    Returns:
        A checker with its own session, so none is held across calls.
    """
    return build_retraction_checker(ctx.config, ctx.storage, refresh_export=refresh_export)


def _screen(
    ctx: _AgentsContext, documents: Sequence[LiteDocument], *, refresh_export: bool = False
) -> RetractionScreen:
    """Check the documents once and leave the retracted ones out.

    Args:
        ctx: Shared agent context.
        documents: The documents.
        refresh_export: Passed to the checker.

    Returns:
        The screen; a failed check leaves every document unchecked but
        those the record's own label retracts.
    """
    checker: RetractionChecker | UnbuiltChecker
    try:
        checker = _build_checker(ctx, refresh_export=refresh_export)
    except Exception as exc:
        # the type only: provider text never reaches the reader or the log
        logger.warning(
            "Retraction checker not built (%s); every document unchecked", type(exc).__name__
        )
        checker = UnbuiltChecker()
    return screen_with_fallback(checker, documents)


def _retraction_payload(screen: RetractionScreen | None) -> dict[str, Any]:
    """Describe what a screen left out, for a tool result.

    Args:
        screen: The call's screen; ``None`` when nothing was found to check.

    Returns:
        ``left_out`` (title, doi, pmid, retraction_date, notice_doi),
        ``unchecked`` and ``checked_at`` (ISO or ``None``).
    """
    if screen is None:
        return {"left_out": [], "unchecked": 0, "checked_at": None}
    left_out = []
    for doc in screen.excluded:
        deciding = screen.checks[doc.id].verdict.deciding
        left_out.append(
            {
                "title": doc.title,
                "doi": doc.doi,
                "pmid": doc.pmid,
                "retraction_date": deciding.date if deciding else None,
                "notice_doi": deciding.notice_doi if deciding else None,
            }
        )
    checked_at = screen.checked_at
    return {
        "left_out": left_out,
        "unchecked": screen.unchecked_count,
        "checked_at": checked_at.isoformat() if checked_at else None,
    }


def _status_first(
    payload: dict[str, Any], check: PaperCheck, text_key: str
) -> dict[str, Any]:
    """Put one paper's retraction status first in a result and on its text.

    Args:
        payload: The tool result.
        check: The paper's check.
        text_key: The key holding the text to qualify (``content``/``answer``).

    Returns:
        A new result with ``retraction_status`` first; the text starts with the
        status line unless the paper is clear.
    """
    entry = _status_entry(check)
    out: dict[str, Any] = {"retraction_status": entry}
    out.update(payload)
    if check.verdict.status is not RetractionStatus.CLEAR and text_key in out:
        out[text_key] = f"{entry['line']}\n\n{out[text_key]}"
    return out


def _status_entry(check: PaperCheck | None) -> dict[str, str]:
    """One paper's retraction status for a tool result.

    Args:
        check: The paper's check; ``None`` when a cancelled check never
            reached it, which reads as unchecked.

    Returns:
        ``status`` (a ``RetractionStatus`` value) and ``line`` (the reader's
        sentence).
    """
    check = check or unchecked_check()
    return {"status": check.verdict.status.value, "line": paper_status_line(check)}


def _paper_check(ctx: _AgentsContext, document: LiteDocument | None) -> PaperCheck:
    """Check one paper; an unknown paper is unchecked.

    A paper without a DOI or PMID still goes to the checker, which reads its
    record's PubMed label.

    Args:
        ctx: Shared agent context.
        document: The paper, or ``None`` when it is unknown.

    Returns:
        Its check.
    """
    if document is None:
        return unchecked_check()
    return _screen(ctx, [document]).checks.get(document.id) or unchecked_check()


def _fact_check_result(
    report: str,
    search_query: str,
    shortfalls: Sequence[RetrievalShortfall],
    *,
    documents_found: int,
    documents_relevant: int = 0,
    citations_extracted: int = 0,
    sources: list[dict[str, Any]] | None = None,
    analysis_shortfalls: Sequence[AnalysisShortfall] = (),
    screen: RetractionScreen | None = None,
) -> dict[str, Any]:
    """Build a fact-check result, qualified when part of it is missing.

    Every exit of the fact check goes through here, so none can return a
    report without the incomplete-search notice or the shortfalls (#247), nor
    without what the analysis could not read (#261, #262).

    Args:
        report: The report, or a message standing in for one.
        search_query: The query the search ran.
        shortfalls: What the search is missing.
        documents_found: Documents the search returned.
        documents_relevant: Documents that scored at or above the threshold.
        citations_extracted: Citations extracted from them.
        sources: Summaries of the relevant documents.
        analysis_shortfalls: What scoring and citation extraction could not
            read.
        screen: The retraction screen, ``None`` when no documents were
            found; its notice goes on the report and its payload under
            ``retraction``.

    Returns:
        The tool result.
    """
    # Text order: search notice, analysis notice, retraction notice, body. A
    # generated report already carries the last two, so each is put on once.
    qualified = without_retraction_notice(without_analysis_shortfall_notice(report))
    if screen is not None:
        qualified = with_retraction_notice(qualified, screen)
    qualified = with_analysis_shortfall_notice(qualified, analysis_shortfalls)
    qualified = with_search_shortfall_notice(qualified, shortfalls)
    return {
        "report": qualified,
        "search_query": search_query,
        "documents_found": documents_found,
        "documents_relevant": documents_relevant,
        "citations_extracted": citations_extracted,
        "sources": sources or [],
        "retrieval_shortfalls": _shortfalls_payload(shortfalls),
        "analysis_shortfalls": _analysis_shortfalls_payload(analysis_shortfalls),
        "retraction": _retraction_payload(screen),
    }


def _handle_fact_check(
    args: dict[str, Any],
    ctx: _AgentsContext,
    progress: _ProgressReporter | None = None,
) -> dict[str, Any]:
    """Run the full fact-checking pipeline.

    Executes search, scoring, citation extraction, and report generation.
    Sends MCP progress notifications at each stage when *progress* is provided.

    Args:
        args: Tool arguments (claim, max_results, min_score, search_provider,
            include_preprints).
        ctx: Shared agent context.
        progress: Optional progress reporter for client notifications.

    Returns:
        Dictionary with report markdown, search metadata, scored sources
        (each with its ``retraction_status``), ``retrieval_shortfalls``,
        ``analysis_shortfalls`` and ``retraction`` (``left_out``,
        ``unchecked``, ``checked_at``). ``documents_found`` counts what the
        search returned, before retracted papers were left out. When the
        search was incomplete, or a stage could not read part of what it
        found, every report text opens with a notice saying what is missing;
        the retraction notice follows those.

    Raises:
        SearchFailedError: If failures left the search with nothing; the
            server returns it as an error, never as "No documents found".
        AnalysisFailedError: If no document could be scored at all; the
            server returns it as an error, never as "none scored above the
            relevance threshold" (#262).
    """
    claim = args["claim"]
    max_results = int(args.get("max_results", 20))
    min_score = int(args.get("min_score", 3))
    provider = _PROVIDER_MAP.get(args.get("search_provider", "pubmed"), SearchProvider.PUBMED)
    include_preprints = bool(args.get("include_preprints", False))

    # 1. Search
    if progress:
        progress.advance("Searching literature databases…")
    session, documents = ctx.search_agent.search(
        question=claim,
        max_results=max_results,
        provider=provider,
        include_preprints=include_preprints,
    )
    shortfalls = retrieval_shortfalls_from_metadata(session.metadata)

    if not documents:
        return _fact_check_result(
            "No documents found matching the query.",
            session.query,
            shortfalls,
            documents_found=0,
        )

    # Retracted papers are never scored or cited
    found = len(documents)
    screen = _screen(ctx, documents, refresh_export=True)
    documents = list(screen.kept)
    if not documents:
        return _fact_check_result(
            # the notice states the count
            "Every document found was retracted and left out.",
            session.query,
            shortfalls,
            documents_found=found,
            screen=screen,
        )

    # Now we know document count — set total for remaining steps.
    # Total = search(done) + score(N) + cite(N) + report(1)
    n_docs = len(documents)
    if progress:
        progress.set_total(_FC_SEARCH_STEP + n_docs + n_docs + _FC_REPORT_STEP)

    # Resolve parallel worker counts from config
    scoring_provider = ctx.config.models.get_task_config("document_scoring").provider
    citation_provider = ctx.config.models.get_task_config("citation_extraction").provider
    scoring_workers = ctx.config.parallel.get_scoring_workers(scoring_provider)
    citation_workers = ctx.config.parallel.get_citation_workers(citation_provider)

    # 2. Score. Scoring raises rather than answering with nothing when it
    # could score no document at all (#262).
    scoring = ctx.scoring_agent.score_documents(
        question=claim,
        documents=documents,
        min_score=min_score,
        progress_callback=progress.make_callback("Scoring documents") if progress else None,
        max_workers=scoring_workers,
    )
    scored_documents = scoring.accepted
    analysis_shortfalls: list[AnalysisShortfall] = []
    if scoring.shortfall is not None:
        analysis_shortfalls.append(scoring.shortfall)

    if not scored_documents:
        return _fact_check_result(
            f"Found {len(documents)} documents but none scored above "
            f"the relevance threshold ({min_score}/5).",
            session.query,
            shortfalls,
            documents_found=found,
            analysis_shortfalls=analysis_shortfalls,
            screen=screen,
        )

    # 3. Extract citations
    extraction = ctx.citation_agent.extract_all_citations(
        question=claim,
        scored_documents=scored_documents,
        min_score=min_score,
        progress_callback=progress.make_callback("Extracting citations") if progress else None,
        max_workers=citation_workers,
    )
    citations = extraction.citations
    if extraction.shortfall is not None:
        analysis_shortfalls.append(extraction.shortfall)

    # 4. Generate report. The shortfalls travel with the citations, so a
    # report built on none of them says the extraction failed rather than
    # that the literature is silent (#261); the accepted count lets one whose
    # relevant documents held nothing quotable say that instead (#303).
    if progress:
        progress.advance("Generating evidence report…")
    try:
        report = ctx.reporting_agent.generate_report(
            question=claim,
            citations=citations,
            analysis_shortfalls=analysis_shortfalls,
            documents_accepted=len(scored_documents),
            retraction_screen=screen,
        )
    except Exception as exc:
        # The report failing does not un-lose what scoring and extraction
        # lost. Reporting only the report's own error would tell the caller
        # nothing about the documents already gone (#301 review).
        _carrying_analysis_shortfalls(exc, analysis_shortfalls)
        raise

    # Build source summaries. A source with no citation was either read and
    # found silent, or never read; the error says which (#310).
    extraction_errors = {
        failure.document.id: failure.cause.description for failure in extraction.failed
    }
    sources = []
    for sd in scored_documents:
        doc = sd.document
        sources.append({
            "title": doc.title,
            "authors": doc.formatted_authors,
            "year": doc.year,
            "journal": doc.journal,
            "doi": doc.doi,
            "pmid": doc.pmid,
            "pmc_id": doc.pmc_id,
            "score": sd.score,
            "explanation": sd.explanation,
            "document_id": doc.id,
            "citation_extraction_error": extraction_errors.get(doc.id),
            "retraction_status": _status_entry(screen.checks.get(doc.id)),
        })

    return _fact_check_result(
        report,
        session.query,
        shortfalls,
        documents_found=found,
        documents_relevant=len(scored_documents),
        citations_extracted=len(citations),
        sources=sources,
        analysis_shortfalls=analysis_shortfalls,
        screen=screen,
    )


def _handle_search(args: dict[str, Any], ctx: _AgentsContext) -> dict[str, Any]:
    """Search literature without scoring.

    Args:
        args: Tool arguments (query, max_results, search_provider,
            include_preprints).
        ctx: Shared agent context.

    Returns:
        Dictionary with generated query, the documents not left out as
        retracted (each with its ``retraction_status``; ``total_results``
        counts them), ``retraction`` (what was left out or could not be
        checked) and ``retrieval_shortfalls``.

    Raises:
        SearchFailedError: If failures left the search with nothing.
    """
    query = args["query"]
    max_results = int(args.get("max_results", 20))
    provider = _PROVIDER_MAP.get(args.get("search_provider", "pubmed"), SearchProvider.PUBMED)
    include_preprints = bool(args.get("include_preprints", False))

    session, documents = ctx.search_agent.search(
        question=query,
        max_results=max_results,
        provider=provider,
        include_preprints=include_preprints,
    )

    screen = _screen(ctx, documents) if documents else None
    kept = screen.kept if screen else documents

    return {
        "search_query": session.query,
        "total_results": len(kept),
        "documents": [
            {
                **doc.to_dict(),
                "retraction_status": _status_entry(screen.checks.get(doc.id) if screen else None),
            }
            for doc in kept
        ],
        "retraction": _retraction_payload(screen),
        "retrieval_shortfalls": _shortfalls_payload(
            retrieval_shortfalls_from_metadata(session.metadata)
        ),
    }


def _handle_fulltext(args: dict[str, Any], ctx: _AgentsContext) -> dict[str, Any]:
    """Retrieve full text and load for interrogation.

    Tries multiple sources in priority order: Europe PMC XML, cached PDF,
    PDF download. Also loads the document into the interrogation agent
    for subsequent ``ask_document`` calls.

    Args:
        args: Tool arguments (pmid, doi, pmc_id — at least one required).
        ctx: Shared agent context.

    Returns:
        Dictionary with success flag, source type, document ID, content, and
        ``interrogation_available``: whether ``ask_document`` can answer
        about it. A load failure used to be logged and nothing else, so the
        caller's next call failed with nothing having said why (#264).
        ``set_aside_pdf_note``, on success and failure alike, when a PDF in
        the library or a download was another article's and was not read
        (#541). On success, ``retraction_status`` comes first and
        ``content`` opens with the status line unless the paper is clear
        (``content_length`` counts it). The document is stored under
        ``document_id`` with what discovery learned, so ``ask_document`` can
        check the same paper.
    """
    given_pmid = args.get("pmid")
    doi = args.get("doi")
    # The PMID is read before anything is asked with it: a padded one finds
    # nothing and "1 OR 2" widens the query (bmlib#470, bmlib#472, bmlib#478). A
    # refused one is the caller's, so the call goes on without it if a DOI
    # or PMC ID remains, and names it if none does
    pmid, pmc_id = read_caller_ids(given_pmid, args.get("pmc_id"))

    if not any([pmid, doi, pmc_id]):
        # Refused, not merely blank: whitespace is no PMID, not a wrong one
        if canonical_pmid(given_pmid).refused:
            return {
                "success": False,
                "source": "invalid_request",
                "error": (
                    f"The pmid {given_pmid!r} is not a PubMed ID (ASCII "
                    "digits), so nothing was asked about it. Provide a "
                    "valid pmid, or a doi or pmc_id."
                ),
            }
        return {
            "success": False,
            "source": "invalid_request",
            "error": "At least one of pmid, doi, or pmc_id must be provided.",
        }

    result = ctx.fulltext_discoverer.discover_fulltext(
        pmid=pmid,
        pmcid=pmc_id,
        doi=doi,
    )

    # Built from the identifiers asked with; also the ID a walled copy is
    # queued under, which storage may not hold (#480, stage 2)
    doc_id = f"pmid-{pmid}" if pmid else f"doi-{doi}" if doi else f"pmc-{pmc_id}"

    if not result.success or not result.markdown_content:
        # The GUI's hidden browser tries the walled copies; a later request
        # finds the PDF in the cache (#480, stage 2)
        queue_challenged_copies(
            ctx.storage,
            RescueSubject(
                doc_id, doi, pmid, result.article_info.title if result.article_info else ""
            ),
            result.lookups,
        )
        # "Not available" is a claim about the article, and a calling agent
        # reads it as the literature's answer -- which is the harm #262 was
        # opened for. It may only be made where every lookup that could be
        # made was made and answered (#354).
        failed: dict[str, Any] = {
            "success": False,
            "source": result.source_type.value,
            "absence_established": result.absence_established,
            "error": (
                "Full text not available for this article."
                if result.absence_established
                else result.error
                or "Whether a full text is available was not established."
            ),
        }
        if result.set_aside_pdf_note:
            failed["set_aside_pdf_note"] = result.set_aside_pdf_note
        return failed

    title = result.article_info.title if result.article_info else "Unknown"
    info = result.article_info

    payload: dict[str, Any] = {
        "success": True,
        "source": result.source_type.value,
        "document_id": doc_id,
        "content_length": len(result.markdown_content),
        "content": result.markdown_content,
        "interrogation_available": True,
    }
    # A PDF filed for this article that is another article's was not read
    # (#541): the agent can tell its user where it went
    if result.set_aside_pdf_note:
        payload["set_aside_pdf_note"] = result.set_aside_pdf_note

    # Load into interrogation agent for subsequent ask_document calls. The
    # text was retrieved either way, so this is not a failed retrieval -- but
    # a caller that is told nothing calls ask_document and fails (#264).
    try:
        payload["document_id"] = ctx.interrogation_agent.load_document(
            text=result.markdown_content,
            document_id=doc_id,
            title=title,
        )
    except Exception as exc:
        logger.warning("Failed to load document for interrogation: %s", exc)
        payload["interrogation_available"] = False
        payload["interrogation_error"] = (
            f"The full text was retrieved but could not be prepared for "
            f"ask_document: {exc}"
        )

    # What discovery learned stands in for an identifier the request lacked
    document = LiteDocument(
        id=doc_id,
        source=DocumentSource.EUROPEPMC,  # found by Europe PMC's discovery; ArticleInfo is its record
        title=info.title if info else "",
        abstract=info.abstract if info else "",
        authors=list(info.authors) if info else [],
        year=info.year if info else None,
        journal=(info.journal or None) if info else None,
        doi=doi or (info.doi if info else None),
        pmid=pmid or (info.pmid if info else None),
        pmc_id=pmc_id or (info.pmcid if info else None),
        publication_types=info.publication_types if info else None,
    )
    try:
        # Under the id ask_document is called with, so it can check the paper
        # too; an upsert, so it never erases a stored fact
        stored_row = ctx.storage.get_document(payload["document_id"])
        ctx.storage.add_document(
            replace(
                document,
                id=payload["document_id"],
                source=stored_row.source if stored_row else document.source,
            )
        )
    except Exception as exc:
        # the type only: the check still runs on the document in hand
        logger.warning("Fulltext document not stored (%s)", type(exc).__name__)
    out = _status_first(payload, _paper_check(ctx, document), "content")
    # the length of the content returned, status line included
    out["content_length"] = len(out["content"])
    return out


def _handle_ask_document(args: dict[str, Any], ctx: _AgentsContext) -> dict[str, Any]:
    """Answer a question about a loaded document using RAG.

    Args:
        args: Tool arguments (question, document_id).
        ctx: Shared agent context.

    Returns:
        Dictionary with ``retraction_status`` first, then the answer (opening
        with the status line unless the paper is clear), document ID and
        source passages.
    """
    question = args["question"]
    document_id = args["document_id"]

    answer, source_passages = ctx.interrogation_agent.ask(
        question=question,
        document_id=document_id,
    )

    check = _paper_check(ctx, ctx.storage.get_document(document_id))
    return _status_first(
        {
            "answer": answer,
            "document_id": document_id,
            "source_passages": source_passages,
        },
        check,
        "answer",
    )


# -- Dispatch ----------------------------------------------------------------


class _ToolCallFailedError(Exception):
    """Carries a failed tool call's JSON payload to the MCP server.

    The MCP server turns an exception raised from ``call_tool`` into a result
    with ``isError`` set and the exception's message as its text. Returned as
    ordinary content, a failure read as a successful call (#247).
    """


def _error_payload(exc: Exception) -> dict[str, Any]:
    """Describe a failed tool call for the calling agent.

    Args:
        exc: What the tool raised.

    Returns:
        The error message and type; for a failed search also what failed
        (``retrieval_shortfalls``) and what to do about it (``advice``); for
        a failed analysis, the same in ``analysis_shortfalls``; for an answer
        cut off or declined, the ``advice`` alone. A failure
        that came after an incomplete stage carries that stage's shortfalls
        too, so what was already lost is not lost again with it.
    """
    payload: dict[str, Any] = {"error": str(exc), "error_type": type(exc).__name__}
    if isinstance(exc, SearchFailedError):
        payload["retrieval_shortfalls"] = _shortfalls_payload(exc.shortfalls)
        payload["advice"] = search_failure_advice(exc.shortfalls)
    if isinstance(exc, AnalysisFailedError):
        payload["analysis_shortfalls"] = _analysis_shortfalls_payload([exc.shortfall])
        payload["advice"] = analysis_failure_advice([exc.shortfall])
    if isinstance(exc, (TruncatedResponseError, RefusedResponseError)):
        payload["advice"] = advice_for_causes([classify_llm_exception(exc)])
    carried = _carried_analysis_shortfalls(exc)
    if carried and "analysis_shortfalls" not in payload:
        payload["analysis_shortfalls"] = _analysis_shortfalls_payload(carried)
        payload.setdefault("advice", analysis_failure_advice(carried))
    return payload


_HANDLERS: dict[str, Any] = {
    "fact_check_claim": _handle_fact_check,
    "search_literature": _handle_search,
    "get_document_fulltext": _handle_fulltext,
    "ask_document": _handle_ask_document,
}


def _dispatch(
    name: str,
    args: dict[str, Any],
    ctx: _AgentsContext,
    progress: _ProgressReporter | None = None,
) -> Any:
    """Route a tool call to the appropriate handler (sync).

    Args:
        name: Tool name.
        args: Tool arguments.
        ctx: Shared agent context.
        progress: Optional progress reporter (passed to fact_check_claim).
    """
    handler = _HANDLERS.get(name)
    if handler is None:
        raise ValueError(f"Unknown tool: {name}")
    if name == "fact_check_claim":
        return handler(args, ctx, progress=progress)
    return handler(args, ctx)


# -- Server setup ------------------------------------------------------------


def _make_server(config: LiteConfig) -> tuple[Server, _AgentsContext]:
    """Create the MCP server with all agents and handlers.

    Args:
        config: Application configuration.

    Returns:
        Tuple of (Server, _AgentsContext) for lifecycle management.
    """
    storage = LiteStorage(config)
    llm_client = LLMClient()

    ctx = _AgentsContext(
        config=config,
        storage=storage,
        llm_client=llm_client,
        search_agent=LiteSearchAgent(storage=storage, config=config, llm_client=llm_client),
        scoring_agent=LiteScoringAgent(config=config, llm_client=llm_client),
        citation_agent=LiteCitationAgent(config=config, llm_client=llm_client),
        reporting_agent=LiteReportingAgent(config=config, llm_client=llm_client),
        interrogation_agent=LiteInterrogationAgent(storage=storage, config=config, llm_client=llm_client),
        fulltext_discoverer=FulltextDiscoverer(
            # The Unpaywall setting first, as the transparency analysis reads
            # it (#435): it is the one the configuration advice names.
            unpaywall_email=config.discovery.unpaywall_email or config.pubmed.email,
            openalex_email=config.pubmed.email,
            core_api_key=config.discovery.core_api_key,
            elsevier_credentials=ElsevierCredentials.from_config(config.discovery),
        ),
    )

    server = Server("bmlibrarian")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return TOOLS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
        failure: dict[str, Any] | None = None
        try:
            loop = asyncio.get_running_loop()

            # Build a progress reporter if the client sent a progressToken.
            progress: _ProgressReporter | None = None
            try:
                req_ctx = server.request_context
                token = req_ctx.meta.progressToken if req_ctx.meta else None
                if token is not None:
                    progress = _ProgressReporter(loop, req_ctx.session, token)
            except LookupError:
                pass

            result = await loop.run_in_executor(
                None, partial(_dispatch, name, arguments, ctx, progress)
            )
            return [TextContent(type="text", text=json.dumps(result, indent=2))]
        except LiteError as exc:
            logger.warning("Tool %s failed: %s", name, exc)
            failure = _error_payload(exc)
        except Exception as exc:
            logger.exception("Unexpected error in tool %s", name)
            failure = _error_payload(exc)
        # Raised outside the except blocks, so the original exception is not
        # kept as context; the server reports it with isError set.
        raise _ToolCallFailedError(json.dumps(failure))

    return server, ctx


async def run_server() -> None:
    """Run the MCP server on stdio transport."""
    config = LiteConfig.load()
    config.ensure_directories()

    # LiteStorage opens a connection per operation, so there is nothing to
    # close on the way out.
    server, _ = _make_server(config)
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


def main() -> None:
    """Entry point for the bmlibrarian-lite-mcp command."""
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
