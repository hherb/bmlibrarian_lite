# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The record says which relevant documents could not be read (#310).

Since #303 an accepted document with no citation means one of two things:
the model read it and found nothing quotable, or its extraction failed after
every retry. ``CitationOutcome`` kept counts and causes but not *which*
documents failed, so the durable audit record -- accepted documents in one
list, citations in another -- could not tell the two apart: #261's harm (a
failure read as silence) survived in the record even though the report's
notice stated the count.

These tests carry the failed documents from the agent to every reader:
the audit file, the checkpoint a report is restored from, and the MCP
result's sources.
"""

from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite import mcp_server
from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.audit_records import (
    CHECKPOINT_EXTRACTION_FAILURES_KEY,
    CHECKPOINT_MIN_SCORE_KEY,
    checkpoint_metadata_with_extraction_failures,
    extraction_failure_entries,
    readable_extraction_failures,
    recorded_extraction_failures,
)
from bmlibrarian_lite.data_models import (
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    ExtractionFailure,
    LiteDocument,
    ScoredDocument,
    ScoringOutcome,
    SearchSession,
)

QUESTION = "Does aspirin prevent stroke?"
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR
TIMED_OUT = EvaluationErrorCode.API_TIMEOUT
QUOTABLE = '{"passages": [{"text": "Aspirin reduced stroke.", "relevance": "direct"}]}'


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


def relevant(pmid: str) -> ScoredDocument:
    """A document that met the relevance threshold."""
    return ScoredDocument(document=make_document(pmid), score=4, explanation="On topic.")


def citation_from(document: LiteDocument) -> Citation:
    """A passage extracted from a document."""
    return Citation(
        document=document,
        passage="Aspirin reduced stroke incidence.",
        relevance_score=4,
        context="direct",
    )


def could_not_read(pmid: str, cause: EvaluationErrorCode = UNREACHABLE) -> ExtractionFailure:
    """A relevant document whose extraction failed."""
    return ExtractionFailure(document=make_document(pmid), cause=cause)


class ScriptedLLM:
    """Answers each call from a script, in order."""

    def __init__(self, answers: list[Any]) -> None:
        """Script the answers.

        Args:
            answers: Each one a result to return or an exception to raise.
        """
        self.answers = list(answers)

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        """Answer one call.

        Args:
            *args: Ignored.
            **kwargs: Ignored.

        Returns:
            The next scripted result.

        Raises:
            Exception: The next scripted exception.
        """
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


class TestTheOutcomeNamesWhatFailed:
    """The count and the causes are read from the failed documents."""

    def test_the_counts_come_from_the_documents(self) -> None:
        """Kept apart, a count and a list can disagree; derived, they cannot."""
        outcome = CitationOutcome(
            citations=[],
            documents_attempted=3,
            failed=(could_not_read("1"), could_not_read("2", TIMED_OUT)),
        )

        assert outcome.documents_failed == 2
        assert outcome.causes == (UNREACHABLE, TIMED_OUT)

    def test_repeated_causes_are_one_cause(self) -> None:
        """Twenty timeouts are one reason, not twenty (the #301 rule)."""
        outcome = CitationOutcome(
            citations=[],
            documents_attempted=2,
            failed=(could_not_read("1"), could_not_read("2")),
        )

        assert outcome.causes == (UNREACHABLE,)

    def test_the_shortfall_is_unchanged(self) -> None:
        """What the report and the notice say still reads from the outcome."""
        outcome = CitationOutcome(
            citations=[], documents_attempted=4, failed=(could_not_read("1"),)
        )

        shortfall = outcome.shortfall

        assert shortfall is not None
        assert (shortfall.documents_failed, shortfall.documents_attempted) == (1, 4)
        assert shortfall.causes == (UNREACHABLE,)

    def test_nothing_failed_is_no_shortfall(self) -> None:
        """The ordinary case."""
        assert CitationOutcome(citations=[], documents_attempted=2).shortfall is None

    def test_a_document_cannot_fail_twice(self) -> None:
        """It was attempted once; counted twice, the notice overstates the loss."""
        with pytest.raises(ValueError, match="once"):
            CitationOutcome(
                citations=[],
                documents_attempted=3,
                failed=(could_not_read("1"), could_not_read("1", TIMED_OUT)),
            )

    def test_a_document_that_failed_was_not_cited(self) -> None:
        """Cited and failed would be two answers for one document."""
        with pytest.raises(ValueError, match="cited"):
            CitationOutcome(
                citations=[citation_from(make_document("1"))],
                documents_attempted=1,
                failed=(could_not_read("1"),),
            )

    def test_more_failed_than_attempted_is_refused(self) -> None:
        """A count that cannot be true is not repaired into one that could."""
        with pytest.raises(ValueError, match="attempted"):
            CitationOutcome(
                citations=[],
                documents_attempted=1,
                failed=(could_not_read("1"), could_not_read("2")),
            )

    def test_a_negative_attempted_count_is_refused(self) -> None:
        """Never fewer than none."""
        with pytest.raises(ValueError, match="never fewer than none"):
            CitationOutcome(citations=[], documents_attempted=-1)


class TestTheAgentRecordsWhichDocumentFailed:
    """Extraction names the document it could not read, and why."""

    def test_the_failed_document_is_named(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Counted only, the record could not say which relevant one it was."""
        agent = LiteCitationAgent()
        monkeypatch.setattr(
            agent,
            "_extract_with_retry",
            ScriptedLLM([[{"text": "Aspirin reduced stroke."}], ConnectionError("down")]),
        )

        outcome = agent.extract_all_citations(QUESTION, [relevant("1"), relevant("2")])

        assert [f.document.id for f in outcome.failed] == ["doc-2"]
        assert outcome.failed[0].cause == UNREACHABLE
        assert [c.document.id for c in outcome.citations] == ["doc-1"]

    def test_a_document_with_nothing_quotable_did_not_fail(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Silence is an answer (#303), and is not recorded as a failure."""
        agent = LiteCitationAgent()
        monkeypatch.setattr(agent, "_extract_with_retry", ScriptedLLM([[]]))

        outcome = agent.extract_all_citations(QUESTION, [relevant("1")])

        assert outcome.failed == ()
        assert outcome.citations == []


class TestADocumentListedTwice:
    """A relevant document listed twice is one document."""

    def test_it_is_read_once_and_nothing_raises(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Extraction never raises; counted twice, its failure would (review)."""
        agent = LiteCitationAgent()
        monkeypatch.setattr(
            agent, "_extract_with_retry", ScriptedLLM([ConnectionError("down")])
        )

        outcome = agent.extract_all_citations(QUESTION, [relevant("1"), relevant("1")])

        assert outcome.documents_attempted == 1
        assert [f.document.id for f in outcome.failed] == ["doc-1"]


class TestTheAuditRecordEntries:
    """What the audit file writes for each document it could not read."""

    def test_an_entry_names_the_document_and_why(self) -> None:
        """The same shape as a failed scoring's entry."""
        [entry] = extraction_failure_entries([could_not_read("1")])

        assert entry == {
            "id": "doc-1",
            "title": "Aspirin trial 1",
            "error_code": "API_CONNECTION_ERROR",
            "reason": UNREACHABLE.description,
        }

    def test_an_older_record_cannot_say(self) -> None:
        """A record without the list cannot tell silence from failure."""
        assert readable_extraction_failures({"citations": []}) is None
        assert readable_extraction_failures({"citation_extraction_failed": []}) == []

    @pytest.mark.parametrize("damaged", [None, "none", [None], ["entry"]])
    def test_a_list_that_cannot_be_read_whole_cannot_say(self, damaged: Any) -> None:
        """Read as empty, it would vouch that every uncited document was silent."""
        assert readable_extraction_failures({"citation_extraction_failed": damaged}) is None


class TestTheCheckpointKeepsThem:
    """A restored report can tell what its run could not read."""

    def test_they_survive_the_checkpoint(self) -> None:
        """What the run wrote, a restore reads back."""
        documents = {d.id: d for d in (make_document("1"), make_document("2"))}
        metadata = checkpoint_metadata_with_extraction_failures(
            {CHECKPOINT_MIN_SCORE_KEY: 4}, [could_not_read("2", TIMED_OUT)]
        )

        recorded = recorded_extraction_failures(metadata, documents)

        assert recorded == [ExtractionFailure(documents["doc-2"], TIMED_OUT)]

    def test_the_threshold_is_kept_beside_them(self) -> None:
        """Updating a checkpoint replaces its metadata whole."""
        metadata = checkpoint_metadata_with_extraction_failures(
            {CHECKPOINT_MIN_SCORE_KEY: 4}, []
        )

        assert metadata[CHECKPOINT_MIN_SCORE_KEY] == 4
        assert metadata[CHECKPOINT_EXTRACTION_FAILURES_KEY] == []

    def test_a_checkpoint_that_kept_none_did_not_record_them(self) -> None:
        """Older checkpoints: "not recorded", never "none failed"."""
        assert recorded_extraction_failures({CHECKPOINT_MIN_SCORE_KEY: 4}, {}) is None
        assert recorded_extraction_failures(None, {}) is None

    def test_a_cause_this_build_cannot_name_degrades_but_is_kept(self) -> None:
        """The reason degrades, the loss never does."""
        document = make_document("1")
        metadata = {
            CHECKPOINT_EXTRACTION_FAILURES_KEY: [{"document_id": "doc-1", "error_code": -99}]
        }

        recorded = recorded_extraction_failures(metadata, {"doc-1": document})

        assert recorded == [
            ExtractionFailure(document, EvaluationErrorCode.UNKNOWN_ERROR)
        ]

    @pytest.mark.parametrize(
        "damaged",
        [
            "not a list",
            [{"error_code": -4}],
            [{"document_id": "doc-unknown", "error_code": -4}],
            ["not an entry"],
        ],
    )
    def test_a_damaged_record_is_not_read_as_a_smaller_loss(self, damaged: Any) -> None:
        """Skipping the entries it cannot read would under-count what failed."""
        metadata = {CHECKPOINT_EXTRACTION_FAILURES_KEY: damaged}

        assert recorded_extraction_failures(metadata, {"doc-1": make_document("1")}) is None


class TestTheMcpSourcesSayWhichWereRead:
    """A calling agent can tell a silent source from an unread one."""

    def test_a_source_whose_extraction_failed_says_so(self) -> None:
        """A source with no citation was otherwise read as saying nothing."""
        context = mcp_server._AgentsContext(
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
        documents = [make_document("1"), make_document("2")]
        context.search_agent.search.return_value = (
            SearchSession(
                id="session-1",
                query="aspirin AND stroke",
                natural_language_query=QUESTION,
                created_at=datetime.now(),
                document_count=2,
                metadata={"provider": "pubmed"},
            ),
            documents,
        )
        context.scoring_agent.score_documents.return_value = ScoringOutcome(
            accepted=[relevant("1"), relevant("2")], failed=[], documents_attempted=2
        )
        context.citation_agent.extract_all_citations.return_value = CitationOutcome(
            citations=[citation_from(documents[0])],
            documents_attempted=2,
            failed=(could_not_read("2"),),
        )
        context.reporting_agent.generate_report.return_value = "## Findings"

        result = mcp_server._handle_fact_check({"claim": QUESTION}, context)

        errors = {
            s["document_id"]: s["citation_extraction_error"] for s in result["sources"]
        }
        assert errors == {"doc-1": None, "doc-2": UNREACHABLE.description}


class TestARestoreReadsItsOwnRun:
    """What a restore reads from storage belongs to the run it restores."""

    @pytest.fixture
    def storage(self, tmp_path: Any) -> Any:
        """A database this test owns."""
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return LiteStorage(config)

    def test_its_citations_are_its_own(self, storage: Any) -> None:
        """Counted per document, another run's citations misstated this one.

        A document this run read and found silent was listed as cited.
        """
        document = make_document("1")
        storage.add_document(document)
        earlier = storage.create_checkpoint(research_question=QUESTION)
        this_run = storage.create_checkpoint(research_question=QUESTION)
        storage.save_citation(citation_from(document), earlier.id)

        assert storage.get_citations_for_question(QUESTION, checkpoint_id=this_run.id) == []
        assert len(storage.get_citations_for_question(QUESTION)) == 1

    def test_the_checkpoint_restored_is_the_one_with_a_report(self, storage: Any) -> None:
        """A benchmark's later checkpoint hid the review: "No report found"."""
        review = storage.create_checkpoint(research_question=QUESTION)
        storage.update_checkpoint(checkpoint_id=review.id, report="## Findings", step="complete")
        storage.create_checkpoint(
            research_question=QUESTION, metadata={"type": "benchmark"}
        )

        restored = storage.get_checkpoint_for_question(QUESTION)

        assert restored is not None
        assert restored.id == review.id
