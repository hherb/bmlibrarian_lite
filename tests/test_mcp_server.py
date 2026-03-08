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

"""Tests for the MCP server module."""

from __future__ import annotations

import asyncio
from datetime import datetime
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.data_models import (
    Citation,
    DocumentSource,
    LiteDocument,
    ScoredDocument,
    SearchProvider,
    SearchSession,
)
from bmlibrarian_lite.fulltext_discovery import FulltextResult, FulltextSourceType
from bmlibrarian_lite.mcp_server import (
    TOOLS,
    _AgentsContext,
    _dispatch,
    _handle_ask_document,
    _handle_fact_check,
    _handle_fulltext,
    _handle_search,
    _ProgressReporter,
)

# -- Fixtures ----------------------------------------------------------------


def _make_document(
    doc_id: str = "pmid-12345",
    title: str = "Test Article",
    pmid: str = "12345",
) -> LiteDocument:
    """Create a minimal LiteDocument for testing."""
    return LiteDocument(
        id=doc_id,
        title=title,
        abstract="This is a test abstract about metformin and CKD.",
        authors=["Smith J", "Doe A"],
        year=2024,
        journal="Test Journal",
        doi="10.1234/test",
        pmid=pmid,
        pmc_id=None,
        url="https://pubmed.ncbi.nlm.nih.gov/12345",
        source=DocumentSource.PUBMED,
    )


def _make_scored_document(doc: LiteDocument | None = None, score: int = 4) -> ScoredDocument:
    """Create a minimal ScoredDocument for testing."""
    if doc is None:
        doc = _make_document()
    return ScoredDocument(
        document=doc,
        score=score,
        explanation="Highly relevant to the research question.",
    )


def _make_citation(doc: LiteDocument | None = None) -> Citation:
    """Create a minimal Citation for testing."""
    if doc is None:
        doc = _make_document()
    return Citation(
        document=doc,
        passage="Metformin was associated with reduced mortality in CKD patients.",
        relevance_score=0.9,
        context="Key finding from the study.",
    )


def _make_session() -> SearchSession:
    """Create a minimal SearchSession for testing."""
    return SearchSession(
        id="session-1",
        query="metformin AND CKD",
        natural_language_query="Does metformin help CKD patients?",
        created_at=datetime.now(),
        document_count=5,
    )


def _make_context() -> _AgentsContext:
    """Create an _AgentsContext with all agents mocked."""
    return _AgentsContext(
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


# -- Tool listing tests ------------------------------------------------------


class TestToolListing:
    """Tests for MCP tool definitions."""

    def test_tool_count(self) -> None:
        """All four tools are defined."""
        assert len(TOOLS) == 4

    def test_tool_names(self) -> None:
        """Tool names match expected values."""
        names = {t.name for t in TOOLS}
        assert names == {
            "fact_check_claim",
            "search_literature",
            "get_document_fulltext",
            "ask_document",
        }

    def test_fact_check_requires_claim(self) -> None:
        """fact_check_claim requires the 'claim' parameter."""
        tool = next(t for t in TOOLS if t.name == "fact_check_claim")
        assert "claim" in tool.inputSchema["required"]

    def test_search_requires_query(self) -> None:
        """search_literature requires the 'query' parameter."""
        tool = next(t for t in TOOLS if t.name == "search_literature")
        assert "query" in tool.inputSchema["required"]

    def test_ask_document_requires_question_and_id(self) -> None:
        """ask_document requires both question and document_id."""
        tool = next(t for t in TOOLS if t.name == "ask_document")
        assert set(tool.inputSchema["required"]) == {"question", "document_id"}

    def test_fulltext_has_no_required_fields(self) -> None:
        """get_document_fulltext has no required fields (validated in handler)."""
        tool = next(t for t in TOOLS if t.name == "get_document_fulltext")
        assert "required" not in tool.inputSchema


# -- Dispatch tests ----------------------------------------------------------


class TestDispatch:
    """Tests for tool dispatch routing."""

    def test_dispatch_unknown_tool(self) -> None:
        """Unknown tool name raises ValueError."""
        ctx = _make_context()
        with pytest.raises(ValueError, match="Unknown tool"):
            _dispatch("nonexistent_tool", {}, ctx)

    def test_dispatch_routes_to_fact_check(self) -> None:
        """fact_check_claim routes to the correct handler."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        result = _dispatch("fact_check_claim", {"claim": "test"}, ctx)
        assert result["documents_found"] == 0
        ctx.search_agent.search.assert_called_once()

    def test_dispatch_routes_to_search(self) -> None:
        """search_literature routes to the correct handler."""
        ctx = _make_context()
        session = _make_session()
        doc = _make_document()
        ctx.search_agent.search.return_value = (session, [doc])

        result = _dispatch("search_literature", {"query": "test"}, ctx)
        assert result["total_results"] == 1
        ctx.search_agent.search.assert_called_once()

    def test_dispatch_routes_to_fulltext(self) -> None:
        """get_document_fulltext routes to the correct handler."""
        ctx = _make_context()
        ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
        )

        result = _dispatch("get_document_fulltext", {"pmid": "12345"}, ctx)
        assert result["success"] is False

    def test_dispatch_routes_to_ask_document(self) -> None:
        """ask_document routes to the correct handler."""
        ctx = _make_context()
        ctx.interrogation_agent.ask.return_value = ("Test answer", ["passage 1"])

        result = _dispatch(
            "ask_document",
            {"question": "What?", "document_id": "pmid-12345"},
            ctx,
        )
        assert result["answer"] == "Test answer"


# -- fact_check_claim tests --------------------------------------------------


class TestFactCheck:
    """Tests for the fact_check_claim handler."""

    def test_no_documents_found(self) -> None:
        """Returns appropriate message when no documents are found."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        result = _handle_fact_check({"claim": "test claim"}, ctx)

        assert result["documents_found"] == 0
        assert result["documents_relevant"] == 0
        assert "No documents found" in result["report"]

    def test_no_relevant_documents(self) -> None:
        """Returns message when documents found but none score above threshold."""
        ctx = _make_context()
        session = _make_session()
        doc = _make_document()
        ctx.search_agent.search.return_value = (session, [doc])
        ctx.scoring_agent.score_documents.return_value = []

        result = _handle_fact_check({"claim": "test", "min_score": 4}, ctx)

        assert result["documents_found"] == 1
        assert result["documents_relevant"] == 0

    def test_full_pipeline(self) -> None:
        """Full pipeline executes all steps in order."""
        ctx = _make_context()
        session = _make_session()
        doc = _make_document()
        scored = _make_scored_document(doc)
        citation = _make_citation(doc)

        ctx.search_agent.search.return_value = (session, [doc])
        ctx.scoring_agent.score_documents.return_value = [scored]
        ctx.citation_agent.extract_all_citations.return_value = [citation]
        ctx.reporting_agent.generate_report.return_value = "# Report\nFindings here."

        result = _handle_fact_check({"claim": "test claim"}, ctx)

        assert result["documents_found"] == 1
        assert result["documents_relevant"] == 1
        assert result["citations_extracted"] == 1
        assert result["report"] == "# Report\nFindings here."
        assert len(result["sources"]) == 1
        assert result["sources"][0]["pmid"] == "12345"
        assert result["sources"][0]["score"] == 4

    def test_search_provider_mapping(self) -> None:
        """search_provider argument maps to SearchProvider enum."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        _handle_fact_check(
            {"claim": "test", "search_provider": "europepmc"},
            ctx,
        )

        _, kwargs = ctx.search_agent.search.call_args
        assert kwargs["provider"] == SearchProvider.EUROPEPMC


# -- search_literature tests -------------------------------------------------


class TestSearch:
    """Tests for the search_literature handler."""

    def test_returns_documents(self) -> None:
        """Returns serialized documents."""
        ctx = _make_context()
        session = _make_session()
        doc = _make_document()
        ctx.search_agent.search.return_value = (session, [doc])

        result = _handle_search({"query": "metformin CKD"}, ctx)

        assert result["total_results"] == 1
        assert result["documents"][0]["pmid"] == "12345"
        assert result["search_query"] == "metformin AND CKD"

    def test_empty_results(self) -> None:
        """Returns empty list when no documents found."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        result = _handle_search({"query": "nonexistent topic"}, ctx)

        assert result["total_results"] == 0
        assert result["documents"] == []


# -- get_document_fulltext tests ---------------------------------------------


class TestFulltext:
    """Tests for the get_document_fulltext handler."""

    def test_no_identifiers(self) -> None:
        """Returns consistent error shape when no identifiers provided."""
        ctx = _make_context()

        result = _handle_fulltext({}, ctx)

        assert result["success"] is False
        assert "error" in result

    def test_fulltext_not_available(self) -> None:
        """Returns success=False when full text not found."""
        ctx = _make_context()
        ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
        )

        result = _handle_fulltext({"pmid": "99999"}, ctx)

        assert result["success"] is False

    def test_fulltext_success(self) -> None:
        """Returns content and loads document for interrogation."""
        ctx = _make_context()
        article_info = MagicMock()
        article_info.title = "Test Article"
        ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_XML,
            markdown_content="# Article\nContent here.",
            article_info=article_info,
        )
        ctx.interrogation_agent.load_document.return_value = "pmid-12345"

        result = _handle_fulltext({"pmid": "12345"}, ctx)

        assert result["success"] is True
        assert result["source"] == "europepmc_xml"
        assert result["document_id"] == "pmid-12345"
        assert "Content here" in result["content"]
        ctx.interrogation_agent.load_document.assert_called_once()

    def test_fulltext_with_doi(self) -> None:
        """Accepts DOI as identifier."""
        ctx = _make_context()
        ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
        )

        _handle_fulltext({"doi": "10.1234/test"}, ctx)

        ctx.fulltext_discoverer.discover_fulltext.assert_called_once_with(
            pmid=None, pmcid=None, doi="10.1234/test"
        )

    def test_interrogation_load_failure_nonfatal(self) -> None:
        """Failure to load for interrogation does not fail the tool."""
        ctx = _make_context()
        article_info = MagicMock()
        article_info.title = "Test"
        ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_XML,
            markdown_content="# Content",
            article_info=article_info,
        )
        ctx.interrogation_agent.load_document.side_effect = ValueError("too short")

        result = _handle_fulltext({"pmid": "12345"}, ctx)

        assert result["success"] is True
        assert result["document_id"] == "pmid-12345"


# -- ask_document tests ------------------------------------------------------


class TestAskDocument:
    """Tests for the ask_document handler."""

    def test_returns_answer(self) -> None:
        """Returns answer and source passages."""
        ctx = _make_context()
        ctx.interrogation_agent.ask.return_value = (
            "Metformin helps CKD patients.",
            ["passage 1", "passage 2"],
        )

        result = _handle_ask_document(
            {"question": "Does metformin help?", "document_id": "pmid-12345"},
            ctx,
        )

        assert result["answer"] == "Metformin helps CKD patients."
        assert result["document_id"] == "pmid-12345"
        assert len(result["source_passages"]) == 2

    def test_passes_document_id(self) -> None:
        """Document ID is forwarded to the interrogation agent."""
        ctx = _make_context()
        ctx.interrogation_agent.ask.return_value = ("answer", [])

        _handle_ask_document(
            {"question": "test", "document_id": "doi-10.1234"},
            ctx,
        )

        _, kwargs = ctx.interrogation_agent.ask.call_args
        assert kwargs["document_id"] == "doi-10.1234"


# -- Progress reporting tests ------------------------------------------------


def _make_progress() -> _ProgressReporter:
    """Create a _ProgressReporter with a mock session and a running event loop."""
    import threading

    loop = asyncio.new_event_loop()
    # Run the loop in a background thread so run_coroutine_threadsafe works.
    thread = threading.Thread(target=loop.run_forever, daemon=True)
    thread.start()

    session = MagicMock(spec_set=["send_progress_notification"])
    # Make the coroutine return immediately.
    async def _noop(*args: object, **kwargs: object) -> None:
        pass
    session.send_progress_notification = MagicMock(side_effect=_noop)
    reporter = _ProgressReporter(loop, session, token="tok-1")
    # Stash thread for cleanup.
    reporter._thread = thread  # type: ignore[attr-defined]
    return reporter


def _cleanup_progress(reporter: _ProgressReporter) -> None:
    """Stop the event loop and join the thread."""
    reporter._loop.call_soon_threadsafe(reporter._loop.stop)
    reporter._thread.join(timeout=2)  # type: ignore[attr-defined]
    reporter._loop.close()


class TestProgressReporter:
    """Tests for _ProgressReporter sync-to-async bridge."""

    def test_advance_sends_notification(self) -> None:
        """advance() calls send_progress_notification via the event loop."""
        reporter = _make_progress()
        reporter.set_total(10)
        reporter.advance("step one")

        reporter._session.send_progress_notification.assert_called_once()
        call_kwargs = reporter._session.send_progress_notification.call_args[1]
        assert call_kwargs["progress_token"] == "tok-1"
        assert call_kwargs["progress"] == 1.0
        assert call_kwargs["total"] == 10
        assert call_kwargs["message"] == "step one"
        _cleanup_progress(reporter)

    def test_advance_accumulates(self) -> None:
        """Multiple advance calls accumulate progress."""
        reporter = _make_progress()
        reporter.set_total(5)
        reporter.advance("a")
        reporter.advance("b", steps=2)

        assert reporter._current == 3.0
        assert reporter._session.send_progress_notification.call_count == 2
        _cleanup_progress(reporter)

    def test_make_callback_returns_callable(self) -> None:
        """make_callback returns a (current, total) -> None callable."""
        reporter = _make_progress()
        reporter.set_total(20)
        cb = reporter.make_callback("Scoring")
        cb(1, 5)
        cb(2, 5)

        assert reporter._current == 2.0
        last_kwargs = reporter._session.send_progress_notification.call_args[1]
        assert "Scoring (2/5)" in last_kwargs["message"]
        _cleanup_progress(reporter)


class TestFactCheckProgress:
    """Tests for progress integration in _handle_fact_check."""

    def test_full_pipeline_sends_progress(self) -> None:
        """Full pipeline sends progress notifications at each stage."""
        ctx = _make_context()
        session = _make_session()
        doc = _make_document()
        scored = _make_scored_document(doc)
        citation = _make_citation(doc)

        ctx.search_agent.search.return_value = (session, [doc])
        ctx.scoring_agent.score_documents.return_value = [scored]
        ctx.citation_agent.extract_all_citations.return_value = [citation]
        ctx.reporting_agent.generate_report.return_value = "# Report"

        reporter = _make_progress()
        result = _handle_fact_check({"claim": "test"}, ctx, progress=reporter)

        assert result["report"] == "# Report"
        # At minimum: search + report = 2 direct advance calls.
        # Scoring/citation callbacks are passed to agents (mocked, so not called).
        assert reporter._session.send_progress_notification.call_count >= 2

        # Verify scoring agent received a progress_callback.
        _, score_kwargs = ctx.scoring_agent.score_documents.call_args
        assert score_kwargs["progress_callback"] is not None

        # Verify citation agent received a progress_callback.
        _, cite_kwargs = ctx.citation_agent.extract_all_citations.call_args
        assert cite_kwargs["progress_callback"] is not None
        _cleanup_progress(reporter)

    def test_no_progress_still_works(self) -> None:
        """Pipeline works fine with progress=None (no client token)."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        result = _handle_fact_check({"claim": "test"}, ctx, progress=None)
        assert result["documents_found"] == 0

    def test_dispatch_passes_progress_to_fact_check(self) -> None:
        """_dispatch routes progress to fact_check_claim."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        reporter = _make_progress()
        result = _dispatch("fact_check_claim", {"claim": "test"}, ctx, progress=reporter)

        assert result["documents_found"] == 0
        # Search step notification should have been sent.
        reporter._session.send_progress_notification.assert_called()
        _cleanup_progress(reporter)

    def test_dispatch_ignores_progress_for_other_tools(self) -> None:
        """_dispatch does not pass progress to non-fact-check tools."""
        ctx = _make_context()
        session = _make_session()
        ctx.search_agent.search.return_value = (session, [])

        reporter = _make_progress()
        result = _dispatch("search_literature", {"query": "test"}, ctx, progress=reporter)

        assert result["total_results"] == 0
        # No progress sent for search_literature.
        reporter._session.send_progress_notification.assert_not_called()
        _cleanup_progress(reporter)
