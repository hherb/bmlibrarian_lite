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
from collections.abc import Callable
from dataclasses import dataclass
from functools import partial
from typing import Any

from mcp.server import Server
from mcp.server.session import ServerSession
from mcp.server.stdio import stdio_server
from mcp.types import TextContent, Tool

from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.agents.interrogation_agent import LiteInterrogationAgent
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import SearchProvider
from bmlibrarian_lite.exceptions import LiteError
from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer
from bmlibrarian_lite.llm import LLMClient
from bmlibrarian_lite.storage import LiteStorage

logger = logging.getLogger(__name__)

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
            "Long-running operation (1-5 minutes depending on result count)."
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
            "Does not score or analyse results."
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
            "subsequent ask_document calls."
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
            "Returns an answer grounded in the document content."
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
        Dictionary with report markdown, search metadata, and scored sources.
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

    if not documents:
        return {
            "report": "No documents found matching the query.",
            "search_query": session.query,
            "documents_found": 0,
            "documents_relevant": 0,
            "citations_extracted": 0,
            "sources": [],
        }

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

    # 2. Score
    scored_documents = ctx.scoring_agent.score_documents(
        question=claim,
        documents=documents,
        min_score=min_score,
        progress_callback=progress.make_callback("Scoring documents") if progress else None,
        max_workers=scoring_workers,
    )

    if not scored_documents:
        return {
            "report": (
                f"Found {len(documents)} documents but none scored above "
                f"the relevance threshold ({min_score}/5)."
            ),
            "search_query": session.query,
            "documents_found": len(documents),
            "documents_relevant": 0,
            "citations_extracted": 0,
            "sources": [],
        }

    # 3. Extract citations
    citations = ctx.citation_agent.extract_all_citations(
        question=claim,
        scored_documents=scored_documents,
        min_score=min_score,
        progress_callback=progress.make_callback("Extracting citations") if progress else None,
        max_workers=citation_workers,
    )

    # 4. Generate report
    if progress:
        progress.advance("Generating evidence report…")
    report = ctx.reporting_agent.generate_report(
        question=claim,
        citations=citations,
    )

    # Build source summaries
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
        })

    return {
        "report": report,
        "search_query": session.query,
        "documents_found": len(documents),
        "documents_relevant": len(scored_documents),
        "citations_extracted": len(citations),
        "sources": sources,
    }


def _handle_search(args: dict[str, Any], ctx: _AgentsContext) -> dict[str, Any]:
    """Search literature without scoring.

    Args:
        args: Tool arguments (query, max_results, search_provider,
            include_preprints).
        ctx: Shared agent context.

    Returns:
        Dictionary with generated query and list of document metadata dicts.
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

    return {
        "search_query": session.query,
        "total_results": len(documents),
        "documents": [doc.to_dict() for doc in documents],
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
        Dictionary with success flag, source type, document ID, and content.
    """
    pmid = args.get("pmid")
    doi = args.get("doi")
    pmc_id = args.get("pmc_id")

    if not any([pmid, doi, pmc_id]):
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

    if not result.success or not result.markdown_content:
        return {
            "success": False,
            "source": result.source_type.value,
            "error": "Full text not available for this article.",
        }

    # Build a document ID from available identifiers
    doc_id = f"pmid-{pmid}" if pmid else f"doi-{doi}" if doi else f"pmc-{pmc_id}"
    title = result.article_info.title if result.article_info else "Unknown"

    # Load into interrogation agent for subsequent ask_document calls
    try:
        loaded_id = ctx.interrogation_agent.load_document(
            text=result.markdown_content,
            document_id=doc_id,
            title=title,
        )
        doc_id = loaded_id
    except Exception as exc:
        logger.warning("Failed to load document for interrogation: %s", exc)

    return {
        "success": True,
        "source": result.source_type.value,
        "document_id": doc_id,
        "content_length": len(result.markdown_content),
        "content": result.markdown_content,
    }


def _handle_ask_document(args: dict[str, Any], ctx: _AgentsContext) -> dict[str, Any]:
    """Answer a question about a loaded document using RAG.

    Args:
        args: Tool arguments (question, document_id).
        ctx: Shared agent context.

    Returns:
        Dictionary with the answer, document ID, and source passages.
    """
    question = args["question"]
    document_id = args["document_id"]

    answer, source_passages = ctx.interrogation_agent.ask(
        question=question,
        document_id=document_id,
    )

    return {
        "answer": answer,
        "document_id": document_id,
        "source_passages": source_passages,
    }


# -- Dispatch ----------------------------------------------------------------

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
            unpaywall_email=config.pubmed.email,
            use_browser_fallback=False,
        ),
    )

    server = Server("bmlibrarian")

    @server.list_tools()
    async def list_tools() -> list[Tool]:
        return TOOLS

    @server.call_tool()
    async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
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
            payload = {"error": str(exc), "error_type": type(exc).__name__}
            return [TextContent(type="text", text=json.dumps(payload))]
        except Exception as exc:
            logger.exception("Unexpected error in tool %s", name)
            payload = {"error": str(exc), "error_type": type(exc).__name__}
            return [TextContent(type="text", text=json.dumps(payload))]

    return server, ctx


async def run_server() -> None:
    """Run the MCP server on stdio transport."""
    config = LiteConfig.load()
    config.ensure_directories()

    server, ctx = _make_server(config)
    try:
        async with stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream,
                write_stream,
                server.create_initialization_options(),
            )
    finally:
        ctx.storage.close()


def main() -> None:
    """Entry point for the bmlibrarian-lite-mcp command."""
    asyncio.run(run_server())


if __name__ == "__main__":
    main()
