# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""An incomplete search is told to the reader, wherever the result goes (#247).

The search service records what failures left out; these tests follow that
record to the places a person or an agent reads: the search session the agent
saves, the report and its Methodology section, and the MCP payloads. A failed
search must also stay a failure on the way, never becoming "No documents
found".
"""

import asyncio
import json
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

import pytest
from mcp import types

from bmlibrarian_lite import mcp_server
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.search_agent import LiteSearchAgent
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    Citation,
    CitationOutcome,
    DocumentSource,
    LiteDocument,
    ReportMetadata,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    ScoredDocument,
    ScoringOutcome,
    SearchProvider,
    SearchSession,
)
from bmlibrarian_lite.exceptions import SearchFailedError
from bmlibrarian_lite.mcp_server import (
    _AgentsContext,
    _handle_fact_check,
    _handle_search,
    _make_server,
)
from bmlibrarian_lite.pubmed.data_types import PubMedQuery
from bmlibrarian_lite.search_failures import (
    retrieval_shortfalls_from_metadata,
    retrieval_shortfalls_to_metadata,
    with_search_shortfall_notice,
)
from bmlibrarian_lite.search_service import UnifiedSearchResult

RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)
PUBMED_DOWN_TEXT = "PubMed could not be searched (HTTP 429 Too Many Requests)"
NOTICE_START = "> **Incomplete search:**"
QUESTION = "Does aspirin prevent stroke?"


def make_document(pmid: str = "12345") -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


class TestTheNoticeHelper:
    """One helper puts the notice in front of any text a reader sees."""

    def test_an_incomplete_search_puts_the_notice_first(self) -> None:
        """The reader meets the qualification before the findings."""
        text = with_search_shortfall_notice("## Findings", [PUBMED_DOWN])

        assert text.startswith(NOTICE_START)
        assert PUBMED_DOWN_TEXT in text
        assert text.endswith("\n\n## Findings")

    def test_a_complete_search_leaves_the_text_alone(self) -> None:
        """No failure, no qualification."""
        assert with_search_shortfall_notice("## Findings", []) == "## Findings"


class TestTheReport:
    """The report says the search was incomplete, and its Methodology says why."""

    def test_the_methodology_records_what_is_missing(self) -> None:
        """The reproducibility record includes the failures, not just the counts."""
        agent = LiteReportingAgent(config=MagicMock())
        metadata = ReportMetadata(search_shortfalls=[PUBMED_DOWN])

        section = agent.format_methodology_section(metadata)

        assert f"- **Search Completeness:** Incomplete: {PUBMED_DOWN_TEXT}" in section

    def test_a_complete_search_adds_no_completeness_line(self) -> None:
        """Reports of complete searches read as they did before #247."""
        agent = LiteReportingAgent(config=MagicMock())

        section = agent.format_methodology_section(ReportMetadata())

        assert "Search Completeness" not in section

    def test_a_report_without_evidence_leads_with_the_notice(self) -> None:
        """'No relevant evidence was found' is weaker when half the search failed."""
        agent = LiteReportingAgent(config=MagicMock())
        metadata = ReportMetadata(search_shortfalls=[PUBMED_DOWN])

        report = agent.generate_report(QUESTION, [], metadata)

        assert report.startswith(NOTICE_START)
        assert "No relevant evidence was found" in report

    def test_a_synthesised_report_leads_with_the_notice(self) -> None:
        """The LLM's summary follows the notice; the notice is not left to the LLM."""
        agent = LiteReportingAgent(config=MagicMock())
        agent._chat = MagicMock(return_value="Aspirin reduced stroke.")  # type: ignore[method-assign]
        document = make_document()
        citation = Citation(document=document, passage="Aspirin reduced stroke.", relevance_score=5)
        metadata = ReportMetadata(search_shortfalls=[PUBMED_DOWN])

        report = agent.generate_report(QUESTION, [citation], metadata)

        assert report.startswith(NOTICE_START)
        assert "Aspirin reduced stroke." in report

    def test_the_shortfalls_survive_the_metadata_round_trip(self) -> None:
        """Report metadata saved with a checkpoint keeps the shortfalls."""
        metadata = ReportMetadata(search_shortfalls=[PUBMED_DOWN])

        restored = ReportMetadata.from_dict(metadata.to_dict())

        assert restored.search_shortfalls == [PUBMED_DOWN]


class FakeStorage:
    """Records the calls the search agent makes, and creates real sessions."""

    def __init__(self) -> None:
        """Start with nothing recorded."""
        self.sessions: list[SearchSession] = []
        self.added: list[LiteDocument] = []

    def create_search_session(
        self,
        query: str,
        natural_language_query: str,
        document_count: int = 0,
        metadata: dict[str, Any] | None = None,
    ) -> SearchSession:
        """Create and record a session."""
        session = SearchSession(
            id=f"session-{len(self.sessions)}",
            query=query,
            natural_language_query=natural_language_query,
            created_at=datetime.now(),
            document_count=document_count,
            metadata=metadata or {},
        )
        self.sessions.append(session)
        return session

    def add_documents(self, documents: list[LiteDocument], embedding_function: Any = None) -> list[str]:
        """Record the documents."""
        self.added.extend(documents)
        return [document.id for document in documents]

    def add_question_documents(
        self, question: str, document_ids: list[str], search_session_id: str | None = None
    ) -> int:
        """Accept the association."""
        return len(document_ids)


def make_agent(storage: FakeStorage, search: UnifiedSearchResult | Exception) -> LiteSearchAgent:
    """A search agent whose search service answers as scripted."""
    agent = LiteSearchAgent(storage=storage, config=LiteConfig(), llm_client=MagicMock())  # type: ignore[arg-type]
    agent.search_service = MagicMock()
    if isinstance(search, Exception):
        agent.search_service.search.side_effect = search
    else:
        agent.search_service.search.return_value = search
    agent._query_converter = MagicMock()
    agent._query_converter.convert.return_value = PubMedQuery(
        original_question=QUESTION, query_string="aspirin AND stroke"
    )
    agent._embedder = MagicMock()
    return agent


SEARCH_ENTRY_POINTS = [
    pytest.param(lambda agent: agent.search(QUESTION), id="search"),
    pytest.param(lambda agent: agent.search_with_query("aspirin AND stroke"), id="search_with_query"),
]


class TestTheSearchAgent:
    """The agent saves the shortfalls with the session, and never saves a failed search."""

    @pytest.mark.parametrize("run", SEARCH_ENTRY_POINTS)
    def test_a_failed_search_saves_no_session(self, run: Any) -> None:
        """#247: a session with document_count=0 recorded a failure as an absence."""
        storage = FakeStorage()
        agent = make_agent(storage, SearchFailedError([PUBMED_DOWN]))

        with pytest.raises(SearchFailedError):
            run(agent)

        assert storage.sessions == []

    @pytest.mark.parametrize("run", SEARCH_ENTRY_POINTS)
    def test_the_session_records_what_the_search_is_missing(self, run: Any) -> None:
        """What the GUI and MCP read back is what the service reported."""
        storage = FakeStorage()
        document = make_document()
        agent = make_agent(
            storage,
            UnifiedSearchResult(
                documents=[document],
                total_count=30,
                fetched_count=1,
                provider=SearchProvider.BOTH,
                europepmc_count=1,
                shortfalls=[PUBMED_DOWN],
            ),
        )

        session, documents = run(agent)

        assert documents == [document]
        assert retrieval_shortfalls_from_metadata(session.metadata) == [PUBMED_DOWN]


def mcp_context(session: SearchSession, documents: list[LiteDocument]) -> _AgentsContext:
    """An MCP context whose search agent returns the given session and documents."""
    context = _AgentsContext(
        config=MagicMock(),
        storage=MagicMock(),
        llm_client=MagicMock(),
        search_agent=MagicMock(),
        scoring_agent=MagicMock(),
        citation_agent=MagicMock(),
        reporting_agent=MagicMock(),
        interrogation_agent=MagicMock(),
        fulltext_discoverer=MagicMock(),
    )
    context.search_agent.search.return_value = (session, documents)
    return context


def incomplete_session() -> SearchSession:
    """A session whose search lost PubMed."""
    return SearchSession(
        id="session-1",
        query="aspirin AND stroke",
        natural_language_query=QUESTION,
        created_at=datetime.now(),
        document_count=1,
        metadata={"provider": "both", **retrieval_shortfalls_to_metadata([PUBMED_DOWN])},
    )


EXPECTED_PAYLOAD_SHORTFALLS = [
    {
        "provider": "pubmed",
        "failure": {"kind": "http_status", "status_code": 429},
        "records_missing": None,
        "description": PUBMED_DOWN_TEXT,
    }
]


class TestTheMcpTools:
    """An agent calling MCP learns the search was incomplete, in words and in data."""

    def test_a_fact_check_report_leads_with_the_notice(self) -> None:
        """The calling agent reads the qualification with the verdict."""
        document = make_document()
        context = mcp_context(incomplete_session(), [document])
        context.scoring_agent.score_documents.return_value = ScoringOutcome(
            accepted=[ScoredDocument(document=document, score=5, explanation="Relevant.")],
            failed=[],
            documents_attempted=1,
        )
        context.citation_agent.extract_all_citations.return_value = CitationOutcome(
            citations=[], documents_attempted=1
        )
        context.reporting_agent.generate_report.return_value = "## Findings"

        result = _handle_fact_check({"claim": QUESTION}, context)

        assert result["report"].startswith(NOTICE_START)
        assert result["report"].endswith("## Findings")
        assert result["retrieval_shortfalls"] == EXPECTED_PAYLOAD_SHORTFALLS

    def test_a_fact_check_with_nothing_relevant_leads_with_the_notice(self) -> None:
        """'None scored above the threshold' is qualified too."""
        context = mcp_context(incomplete_session(), [make_document()])
        context.scoring_agent.score_documents.return_value = ScoringOutcome(
            accepted=[], failed=[], documents_attempted=1
        )

        result = _handle_fact_check({"claim": QUESTION}, context)

        assert result["report"].startswith(NOTICE_START)
        assert result["retrieval_shortfalls"] == EXPECTED_PAYLOAD_SHORTFALLS

    def test_a_complete_fact_check_carries_an_empty_list(self) -> None:
        """The field is always present, so a caller need not guess its absence."""
        session = incomplete_session()
        session.metadata = {"provider": "pubmed"}
        context = mcp_context(session, [])

        result = _handle_fact_check({"claim": QUESTION}, context)

        assert result["retrieval_shortfalls"] == []
        assert result["report"] == "No documents found matching the query."

    def test_a_failed_fact_check_search_stays_a_failure(self) -> None:
        """The handler raises; it does not return a report."""
        context = mcp_context(incomplete_session(), [])
        context.search_agent.search.side_effect = SearchFailedError([PUBMED_DOWN])

        with pytest.raises(SearchFailedError):
            _handle_fact_check({"claim": QUESTION}, context)

    def test_a_literature_search_carries_the_shortfalls(self) -> None:
        """search_literature reports them beside the documents."""
        context = mcp_context(incomplete_session(), [make_document()])

        result = _handle_search({"query": QUESTION}, context)

        assert result["retrieval_shortfalls"] == EXPECTED_PAYLOAD_SHORTFALLS
        assert result["total_results"] == 1


class TestTheMcpServer:
    """A failed tool call is an MCP error result, carrying what failed (#247)."""

    @pytest.fixture
    def server_and_context(self, tmp_path: Any) -> Any:
        """A real MCP server over a throwaway data directory."""
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return _make_server(config)

    def call(self, server: Any, name: str, arguments: dict[str, Any]) -> Any:
        """Invoke a tool through the server's own request handler."""
        request = types.CallToolRequest(
            method="tools/call",
            params=types.CallToolRequestParams(name=name, arguments=arguments),
        )
        return asyncio.run(server.request_handlers[types.CallToolRequest](request)).root

    def test_a_failed_search_is_an_error_result_with_its_shortfalls(
        self, server_and_context: Any
    ) -> None:
        """A client checking isError sees the failure; an agent reads what and why."""
        server, context = server_and_context
        context.search_agent = MagicMock()
        context.search_agent.search.side_effect = SearchFailedError([PUBMED_DOWN])

        result = self.call(server, "search_literature", {"query": QUESTION})

        assert result.isError is True
        payload = json.loads(result.content[0].text)
        assert payload["error_type"] == "SearchFailedError"
        assert PUBMED_DOWN_TEXT in payload["error"]
        assert payload["retrieval_shortfalls"] == EXPECTED_PAYLOAD_SHORTFALLS
        assert payload["advice"].startswith("The service is limiting")

    def test_a_failed_fact_check_is_an_error_result_too(self, server_and_context: Any) -> None:
        """fact_check_claim fails the same way search_literature does."""
        server, context = server_and_context
        context.search_agent = MagicMock()
        context.search_agent.search.side_effect = SearchFailedError([PUBMED_DOWN])

        result = self.call(server, "fact_check_claim", {"claim": QUESTION})

        assert result.isError is True
        assert json.loads(result.content[0].text)["retrieval_shortfalls"] == (
            EXPECTED_PAYLOAD_SHORTFALLS
        )

    def test_a_complete_search_carries_an_empty_list(self, server_and_context: Any) -> None:
        """The field is always present, so a caller need not guess its absence."""
        server, context = server_and_context
        session = incomplete_session()
        session.metadata = {"provider": "pubmed"}
        context.search_agent = MagicMock()
        context.search_agent.search.return_value = (session, [make_document()])

        result = self.call(server, "search_literature", {"query": QUESTION})

        assert result.isError is False
        assert json.loads(result.content[0].text)["retrieval_shortfalls"] == []

    def test_a_successful_call_is_not_an_error_result(self, server_and_context: Any) -> None:
        """The error flag is not set on every result."""
        server, context = server_and_context
        context.search_agent = MagicMock()
        context.search_agent.search.return_value = (incomplete_session(), [make_document()])

        result = self.call(server, "search_literature", {"query": QUESTION})

        assert result.isError is False

    def test_shutdown_does_not_mask_the_error_that_ended_the_server(
        self, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Storage holds no connection to close; calling a missing close() raised instead."""
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        monkeypatch.setattr(mcp_server.LiteConfig, "load", classmethod(lambda cls: config))

        @asynccontextmanager
        async def broken_stdio() -> Any:
            raise RuntimeError("transport failed")
            yield  # pragma: no cover

        monkeypatch.setattr(mcp_server, "stdio_server", broken_stdio)

        with pytest.raises(RuntimeError, match="transport failed"):
            asyncio.run(mcp_server.run_server())
