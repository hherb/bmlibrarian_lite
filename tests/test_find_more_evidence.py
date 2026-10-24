# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Find More Evidence: the apps' ``fetchMoreEvidence`` on the desktop's reviewed run.

Also the review's own smart search, when too few documents are relevant.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    CHECKPOINT_REPORT_METADATA_KEY,
    CHECKPOINT_RETRACTION_SNAPSHOT_KEY,
    recorded_report_metadata,
)
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    AnalysisStage,
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    ExtractionFailure,
    LiteDocument,
    PassFailure,
    ReportMetadata,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    ScoredDocument,
    SearchProvider,
    SearchSession,
    ShortfallQuery,
)
from bmlibrarian_lite.exceptions import SearchFailedError
from bmlibrarian_lite.full_text_retry import NO_REPORT_TEXT, REPORT_PENDING_KEY, RetryNotPossible
from bmlibrarian_lite.more_evidence import (
    CANCELLED_UNCHANGED_TEXT,
    CAUGHT_UP_TEXT,
    UNSCORED_KEY,
    MoreEvidence,
    find_more_evidence,
    more_evidence_text,
)
from bmlibrarian_lite.quality.data_models import QualityFilter, QualityTier
from bmlibrarian_lite.retraction_screen import RetractionScreen, unchecked_check
from bmlibrarian_lite.smart_search import (
    NO_NEW_EVIDENCE_TEXT,
    NO_USABLE_QUERY_TEXT,
    SmartSearchContext,
    SmartSearchError,
    SmartSearchRound,
)
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Does aspirin prevent stroke?"
SCORES = {"1": 5, "2": 4, "3": 2, "5": 5, "6": 2, "7": 4}


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}", title=f"Aspirin trial {pmid}", abstract=f"Abstract {pmid}.",
        authors=["Smith J"], year=2024, pmid=pmid, source=DocumentSource.PUBMED,
    )


@pytest.fixture
def storage(tmp_path: Path) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def reviewed(storage: LiteStorage, keep_metadata: bool = True,
             quality: dict[str, Any] | None = None) -> str:
    """A reviewed run: papers 1 (5), 2 (4) cited, 3 (2) rejected."""
    metadata = ReportMetadata(
        quality_filter_applied=quality is not None, quality_filter_settings=quality,
        research_question=QUESTION, pubmed_query="aspirin AND stroke", min_score_threshold=3,
        total_results_available=3, documents_retrieved=3, documents_scored=3,
        documents_accepted=2, documents_rejected=1, score_distribution={5: 1, 4: 1, 2: 1},
        citations_extracted=2,
    )
    checkpoint = storage.create_checkpoint(research_question=QUESTION, metadata={
        CHECKPOINT_MIN_SCORE_KEY: 3,
        **({CHECKPOINT_REPORT_METADATA_KEY: metadata.to_dict()} if keep_metadata else {}),
    })
    for pmid in ("1", "2", "3"):
        storage.upsert_document(make_document(pmid))
        storage.save_scored_document(
            ScoredDocument(make_document(pmid), SCORES[pmid], "On topic."), checkpoint.id)
    for pmid in ("1", "2"):
        storage.save_citation(cite(pmid), checkpoint.id)
    storage.record_citation_reads(checkpoint.id, {"doc-1": False, "doc-2": False})
    storage.add_question_documents(QUESTION, ["doc-1", "doc-2", "doc-3"])
    storage.update_checkpoint(checkpoint_id=checkpoint.id, report="Old report.", step="complete")
    return checkpoint.id


def cite(pmid: str) -> Citation:
    """A passage of a paper."""
    return Citation(document=make_document(pmid), passage=f"Quote {pmid}.",
                    relevance_score=5, context="c")


def found(storage: LiteStorage, *pmids: str) -> list[LiteDocument]:
    """Documents a search stored and linked to the question."""
    documents = [make_document(p) for p in pmids]
    for d in documents:
        storage.upsert_document(d)
    storage.add_question_documents(QUESTION, [d.id for d in documents])
    return documents


class Scorer:
    """Scores from ``SCORES``; a pmid in ``failing`` fails."""

    def __init__(self, failing: tuple[str, ...] = ()) -> None:
        """Fail the papers named."""
        self.failing = failing
        self.scored: list[str] = []

    def score_document(self, question: str, doc: LiteDocument) -> ScoredDocument:
        """Score one paper."""
        self.scored.append(doc.id)
        if doc.pmid in self.failing:
            return ScoredDocument(doc, EvaluationErrorCode.API_CONNECTION_ERROR.value, "")
        return ScoredDocument(doc, SCORES[doc.pmid], "On topic.")


class Extractor:
    """Quotes each paper it reads; a pmid in ``failing`` cannot be read."""

    def __init__(self, failing: tuple[str, ...] = ()) -> None:
        """Nothing read yet."""
        self.read: list[str] = []
        self.failing = failing

    def extract_all_citations(self, question: str, docs: list[ScoredDocument], min_score: int,
                              **kwargs: Any) -> CitationOutcome:
        """Quote each paper."""
        self.read.extend(d.document.id for d in docs)
        return CitationOutcome(
            citations=[cite(d.document.pmid or "") for d in docs
                       if d.document.pmid not in self.failing],
            documents_attempted=len(docs),
            failed=[ExtractionFailure(d.document, EvaluationErrorCode.API_CONNECTION_ERROR)
                    for d in docs if d.document.pmid in self.failing],
        )


class Run:
    """One Find More Evidence, its agents scripted."""

    def __init__(self, storage: LiteStorage, *, rounds: list[SmartSearchRound] | None = None,
                 screen: Any = None, failing: tuple[str, ...] = (),
                 stop: Any = None, assessed: list[str] | None = None,
                 unreadable: tuple[str, ...] = (), assess: Any = None) -> None:
        """Script the rounds, the screen, the failures, the stop and the assessments."""
        self.storage = storage
        self.rounds = list(rounds or [])
        self.contexts: list[tuple[SmartSearchContext, set[str]]] = []
        self.scorer = Scorer(failing)
        self.extractor = Extractor(unreadable)
        self.reporter = MagicMock()
        self.reporter.generate_report.return_value = "New report."
        self.screen = screen
        self.stop = stop or (lambda run: False)
        self.assessed = assessed
        self.assess = assess
        self.filtered: list[tuple[list[str], QualityFilter]] = []

    def quality_filter(self, documents: list[LiteDocument],
                       settings: QualityFilter) -> list[LiteDocument]:
        """Pass every paper but 6."""
        self.filtered.append(([d.id for d in documents], settings))
        return [d for d in documents if d.pmid != "6"]

    def smart_search(self, context: SmartSearchContext, known: Any) -> SmartSearchRound:
        """Answer one round."""
        self.contexts.append((context, set(known)))
        return self.rounds.pop(0)

    def __call__(self, documents: list[LiteDocument],
                 lost: list[RetrievalShortfall] | None = None) -> MoreEvidence:
        """Run once."""
        assess = self.assess
        if self.assessed is not None:
            assess = lambda doc, text: self.assessed.append(doc.id)  # noqa: E731
        return find_more_evidence(
            QUESTION, self.storage, LiteConfig(), documents, lost or [],
            smart_search=self.smart_search, screen=self.screen,
            quality_filter=self.quality_filter,
            scoring_agent=self.scorer, citation_agent=self.extractor,
            reporting_agent=self.reporter, fetch=lambda doc: None,
            assess_transparency=assess, should_stop=lambda: self.stop(self),
        )

    @property
    def metadata(self) -> ReportMetadata:
        """The metadata the report was written with."""
        return self.reporter.generate_report.call_args.args[2]


def cited(storage: LiteStorage, checkpoint_id: str) -> list[str]:
    """The cited papers, in order."""
    return sorted({c.document.id for c in storage.get_citations_for_question(
        QUESTION, checkpoint_id=checkpoint_id)})


class TestMoreAlongTheQuestionsOwnQuery:
    """The documents paging found are scored into the run, and the report written again."""

    def test_they_are_scored_read_and_reported_with_the_rest(self, storage: LiteStorage) -> None:
        """Every citation of the run, the counts added to, a version later."""
        checkpoint_id = reviewed(storage)
        run = Run(storage)

        outcome = run(found(storage, "5", "6"))

        assert outcome == MoreEvidence(found=2, scored=2, relevant=1, report="New report.")
        assert run.contexts == []  # no paid round
        assert run.extractor.read == ["doc-5"]
        assert cited(storage, checkpoint_id) == ["doc-1", "doc-2", "doc-5"]
        metadata = run.metadata
        assert (metadata.documents_retrieved, metadata.documents_scored) == (5, 5)
        assert (metadata.documents_accepted, metadata.documents_rejected) == (3, 2)
        assert metadata.score_distribution == {5: 2, 4: 1, 2: 2}
        assert (metadata.version, metadata.citations_extracted) == (2, 3)
        stored = storage.get_checkpoint_for_question(QUESTION)
        assert stored.report == "New report."
        assert REPORT_PENDING_KEY not in stored.metadata
        assert UNSCORED_KEY not in stored.metadata
        assert recorded_report_metadata(stored.metadata).documents_scored == 5

    def test_what_paging_lost_reaches_the_report(self, storage: LiteStorage) -> None:
        """Beside what the review's own search lost."""
        reviewed(storage)
        lost = RetrievalShortfall(SearchProvider.PUBMED,
                                  RequestFailure(RequestFailureKind.TIMEOUT), records_missing=3)
        run = Run(storage)

        outcome = run(found(storage, "5"), [lost])

        assert outcome.search_shortfalls == (lost,)
        assert run.metadata.search_shortfalls == [lost]
        assert "Incomplete search: 3 PubMed records" in more_evidence_text(outcome)

    def test_a_question_without_a_report_is_refused(self, storage: LiteStorage) -> None:
        """Run the review first."""
        with pytest.raises(RetryNotPossible) as raised:
            Run(storage)(found(storage, "5"))
        assert str(raised.value) == NO_REPORT_TEXT

    def test_a_document_the_model_could_not_score_is_no_rejection(
        self, storage: LiteStorage
    ) -> None:
        """Counted as lost, beside the documents scored."""
        reviewed(storage)
        run = Run(storage, failing=("6",))

        outcome = run(found(storage, "5", "6"))

        assert (outcome.scored, len(outcome.scoring_failures)) == (1, 1)
        shortfall = next(s for s in run.metadata.analysis_shortfalls
                         if s.stage is AnalysisStage.SCORING)
        assert (shortfall.documents_failed, shortfall.documents_attempted) == (1, 5)
        assert run.metadata.documents_rejected == 1


class TestAlternativeQueries:
    """With nothing new along its own query, a round of alternative queries runs."""

    def test_the_round_is_told_of_the_search_so_far(self, storage: LiteStorage) -> None:
        """Its query, its results, how many were relevant, what is already known, its run."""
        checkpoint_id = reviewed(storage)
        run = Run(storage, rounds=[SmartSearchRound((make_document("5"),), ("(q[tiab])",))])
        found(storage, "5")

        outcome = run([])

        context, known = run.contexts[0]
        assert context == SmartSearchContext(QUESTION, "aspirin AND stroke", 3, 2, checkpoint_id)
        assert known == {"doc-1", "doc-2", "doc-3"}
        assert outcome.queries == ("(q[tiab])",)
        assert run.metadata.alternative_queries == ["(q[tiab])"]
        assert outcome.report == "New report."

    def test_a_round_finding_nothing_leaves_the_report(self, storage: LiteStorage) -> None:
        """And says so."""
        reviewed(storage)
        run = Run(storage, rounds=[SmartSearchRound((), ("(q[tiab])",))])

        outcome = run([])

        assert outcome.notice == NO_NEW_EVIDENCE_TEXT
        assert outcome.report is None
        run.reporter.generate_report.assert_not_called()
        assert storage.get_checkpoint_for_question(QUESTION).report == "Old report."

    def test_what_the_round_lost_is_marked_as_an_alternative_searchs(
        self, storage: LiteStorage
    ) -> None:
        """As the round hands it on."""
        reviewed(storage)
        lost = RetrievalShortfall(SearchProvider.EUROPEPMC,
                                  RequestFailure(RequestFailureKind.TIMEOUT),
                                  query=ShortfallQuery.ALTERNATIVE)
        run = Run(storage, rounds=[SmartSearchRound((make_document("5"),), ("q",), (lost,))])
        found(storage, "5")

        run([])

        assert run.metadata.search_shortfalls == [lost]

    def test_what_paging_lost_is_kept_beside_the_rounds(self, storage: LiteStorage) -> None:
        """Paging found only known documents, and lost a page: both losses are said."""
        reviewed(storage)
        paged = RetrievalShortfall(SearchProvider.PUBMED,
                                   RequestFailure(RequestFailureKind.TIMEOUT), records_missing=3)
        alternative = RetrievalShortfall(SearchProvider.EUROPEPMC,
                                         RequestFailure(RequestFailureKind.TIMEOUT),
                                         query=ShortfallQuery.ALTERNATIVE)
        run = Run(storage, rounds=[SmartSearchRound((make_document("5"),), ("q",), (alternative,))])
        found(storage, "5")

        outcome = run([make_document("1")], [paged])

        assert set(outcome.search_shortfalls) == {paged, alternative}
        assert set(run.metadata.search_shortfalls) == {paged, alternative}

    def test_a_cancelled_round_is_a_cancel_not_nothing_new(self, storage: LiteStorage) -> None:
        """A stop is never read as the searches having found nothing."""
        reviewed(storage)
        run = Run(storage, rounds=[SmartSearchRound(stopped=True)])

        outcome = run([])

        assert outcome.cancelled and outcome.notice is None
        assert more_evidence_text(outcome) == CANCELLED_UNCHANGED_TEXT


class TestWhatIsFoundIsScreened:
    """Retracted papers stay out of the run, and its snapshot gains the new rows."""

    def test_a_retracted_paper_is_not_scored(self, storage: LiteStorage) -> None:
        """Left out, and its row kept with the run's."""
        checkpoint_id = reviewed(storage)

        def screen(documents: list[LiteDocument]) -> RetractionScreen:
            return RetractionScreen(
                kept=tuple(d for d in documents if d.pmid != "6"),
                excluded=tuple(d for d in documents if d.pmid == "6"),
                checks={"doc-5": unchecked_check()},
            )

        run = Run(storage, screen=screen)
        outcome = run(found(storage, "5", "6"))

        assert (outcome.left_out, run.scorer.scored) == (1, ["doc-5"])
        rows = storage.get_checkpoint(checkpoint_id).metadata[CHECKPOINT_RETRACTION_SNAPSHOT_KEY]
        assert {(r["document_id"], r["excluded"]) for r in rows} == {
            ("doc-5", False), ("doc-6", True)}
        assert "1 left out as retracted." in more_evidence_text(outcome)

    def test_a_row_a_stopped_screen_wrote_is_replaced(self, storage: LiteStorage) -> None:
        """Held over unchecked, then found retracted: the report reads it as left out."""
        checkpoint_id = reviewed(storage)
        screens: list[bool] = []

        def unchecked(documents: list[LiteDocument]) -> RetractionScreen:
            screens.append(True)
            return RetractionScreen(kept=tuple(documents), excluded=(), checks={})

        Run(storage, screen=unchecked, stop=lambda run: bool(screens))(found(storage, "5"))
        assert storage.get_checkpoint(checkpoint_id).metadata[UNSCORED_KEY] == ["doc-5"]

        def retracted(documents: list[LiteDocument]) -> RetractionScreen:
            return RetractionScreen(kept=(), excluded=tuple(documents), checks={})

        outcome = Run(storage, screen=retracted)([])

        rows = storage.get_checkpoint(checkpoint_id).metadata[CHECKPOINT_RETRACTION_SNAPSHOT_KEY]
        assert [(r["document_id"], r["excluded"]) for r in rows] == [("doc-5", True)]
        assert outcome.left_out == 1


class TestTheRunsQualityFilter:
    """New documents pass the filter the review applied, or are left out."""

    def test_a_filtered_run_filters_the_new_documents(self, storage: LiteStorage) -> None:
        """By the criteria it kept."""
        reviewed(storage, quality={"minimum_tier": "TIER_4_EXPERIMENTAL",
                                   "require_randomization": True, "require_blinding": False,
                                   "minimum_sample_size": 50})
        run = Run(storage)

        outcome = run(found(storage, "5", "6"))

        assert run.filtered == [(["doc-5", "doc-6"], QualityFilter(
            minimum_tier=QualityTier.TIER_4_EXPERIMENTAL, require_randomization=True,
            minimum_sample_size=50))]
        assert (outcome.filtered_out, run.scorer.scored) == (1, ["doc-5"])
        assert run.metadata.documents_filtered_by_quality == 1
        assert "1 left out by the review's quality filter." in more_evidence_text(outcome)

    def test_an_unfiltered_run_filters_nothing(self, storage: LiteStorage) -> None:
        """No filter asked for."""
        reviewed(storage)
        run = Run(storage)
        run(found(storage, "5", "6"))
        assert run.filtered == []

    @pytest.mark.parametrize("settings", [
        None, {}, {"minimum_tier": "TIER_9"}, {"minimum_tier": 4},
        {"minimum_tier": "TIER_4_EXPERIMENTAL", "minimum_sample_size": "50"},
        {"minimum_tier": "TIER_4_EXPERIMENTAL", "require_blinding": "yes"},
    ])
    def test_a_filter_that_cannot_be_read_back_is_refused(
        self, storage: LiteStorage, settings: Any
    ) -> None:
        """Never read as no filter."""
        reviewed(storage, quality=settings if settings is not None else {})
        if settings is None:
            checkpoint = storage.get_checkpoint_for_question(QUESTION)
            stored = recorded_report_metadata(checkpoint.metadata)
            stored.quality_filter_settings = None
            storage.update_checkpoint(checkpoint_id=checkpoint.id, metadata={
                **checkpoint.metadata, CHECKPOINT_REPORT_METADATA_KEY: stored.to_dict()})
        before = storage.get_checkpoint_for_question(QUESTION).metadata

        run = Run(storage, rounds=[SmartSearchRound((make_document("5"),), ("q",))])
        with pytest.raises(RetryNotPossible):
            run(found(storage, "5"))
        assert run.contexts == []  # nothing paid for
        assert storage.get_checkpoint_for_question(QUESTION).metadata == before


class TestWhatTheRunAlreadyHolds:
    """Never new again, so never counted again (review of the first draft)."""

    def test_a_paper_left_out_before_is_not_found_again(self, storage: LiteStorage) -> None:
        """Screened or filtered out once: known."""
        reviewed(storage, quality={"minimum_tier": "TIER_2_OBSERVATIONAL"})
        Run(storage)(found(storage, "5", "6"))  # 6 filtered out

        from bmlibrarian_lite.more_evidence import known_document_ids

        assert {"doc-5", "doc-6"} <= known_document_ids(storage, QUESTION)
        run = Run(storage, rounds=[SmartSearchRound((), ("q",))])
        outcome = run(found(storage, "6"))

        assert outcome.notice == NO_NEW_EVIDENCE_TEXT
        assert "doc-6" in run.contexts[0][1]

    def test_a_report_owed_is_written_before_any_paid_round(self, storage: LiteStorage) -> None:
        """A run stopped after scoring left relevant papers unread."""
        checkpoint_id = reviewed(storage)
        documents = found(storage, "5")
        # Stopped once its one paper is scored, before it is read
        Run(storage, stop=lambda run: len(run.scorer.scored) >= 1)(documents)
        assert storage.get_checkpoint(checkpoint_id).report == "Old report."

        run = Run(storage)
        outcome = run([])

        assert run.contexts == []
        assert run.extractor.read == ["doc-5"]
        assert outcome.report == "New report."
        assert CAUGHT_UP_TEXT in more_evidence_text(outcome)

    def test_a_report_owed_after_extraction_is_written_without_reading_again(
        self, storage: LiteStorage
    ) -> None:
        """The report failed once its papers were read: only the flag owes it."""
        checkpoint_id = reviewed(storage)
        failing = Run(storage)
        failing.reporter.generate_report.side_effect = RuntimeError("model gone")
        with pytest.raises(RuntimeError):
            failing(found(storage, "5"))
        assert storage.get_checkpoint(checkpoint_id).metadata[REPORT_PENDING_KEY] is True

        run = Run(storage)
        outcome = run([])

        assert run.contexts == [] and run.extractor.read == []
        assert outcome.report == "New report."
        quotes = storage.get_citations_for_question(QUESTION, checkpoint_id=checkpoint_id)
        assert sorted(c.document.id for c in quotes) == ["doc-1", "doc-2", "doc-5"]


class TestAnExtractionThatFailed:
    """Said, never read as read, and never in the way of a search."""

    def test_it_is_said_and_retried_with_the_next_runs_papers(self, storage: LiteStorage) -> None:
        """A paper that always fails would otherwise block every round."""
        checkpoint_id = reviewed(storage)
        first = Run(storage, unreadable=("5",))

        outcome = first(found(storage, "5"))

        assert outcome.extraction_failures == (
            PassFailure(document_id="doc-5", cause=EvaluationErrorCode.API_CONNECTION_ERROR),)
        assert "Citations could not be extracted from 1 relevant paper." in more_evidence_text(outcome)
        assert "doc-5" not in storage.get_citation_reads(checkpoint_id)

        searching = Run(storage, rounds=[SmartSearchRound((make_document("7"),), ("q",))])
        found(storage, "7")
        searching([])

        assert len(searching.contexts) == 1
        assert sorted(searching.extractor.read) == ["doc-5", "doc-7"]


class TestAStop:
    """What was found and scored is kept; the next run carries on from it."""

    def test_the_next_run_scores_what_a_stop_left_and_writes_the_report(
        self, storage: LiteStorage
    ) -> None:
        """Without a paid round on top of it."""
        checkpoint_id = reviewed(storage)
        documents = found(storage, "5", "6", "7")
        first = Run(storage, stop=lambda run: len(run.scorer.scored) >= 1)

        stopped = first(documents)

        assert stopped.cancelled and stopped.scored == 1
        kept = storage.get_checkpoint(checkpoint_id).metadata
        assert kept[UNSCORED_KEY] == ["doc-6", "doc-7"]
        assert kept[REPORT_PENDING_KEY] is True
        assert recorded_report_metadata(kept).documents_scored == 4
        assert storage.get_checkpoint(checkpoint_id).report == "Old report."

        second = Run(storage)
        outcome = second([])

        assert second.contexts == []
        assert second.scorer.scored == ["doc-6", "doc-7"]
        assert sorted(second.extractor.read) == ["doc-5", "doc-7"]
        assert outcome.report == "New report."
        assert second.metadata.documents_scored == 6
        assert UNSCORED_KEY not in storage.get_checkpoint(checkpoint_id).metadata
        assert (outcome.found, outcome.resumed) == (0, 2)
        assert "Carried on with 2 documents an earlier stop left unscored." in (
            more_evidence_text(outcome))

    def test_held_over_documents_paging_finds_again_are_scored_once(
        self, storage: LiteStorage
    ) -> None:
        """The tab's known ids leave them out, so paging hands them back."""
        checkpoint_id = reviewed(storage)
        Run(storage, stop=lambda run: len(run.scorer.scored) >= 1)(found(storage, "5", "6", "7"))

        second = Run(storage)
        outcome = second(found(storage, "6", "7"))

        assert second.scorer.scored == ["doc-6", "doc-7"]
        assert outcome.found == 0
        assert (second.metadata.documents_retrieved, second.metadata.documents_scored) == (6, 6)
        assert UNSCORED_KEY not in storage.get_checkpoint(checkpoint_id).metadata

    def test_a_stopped_extraction_keeps_nothing(self, storage: LiteStorage) -> None:
        """What it read is not known paper by paper: the next run reads them."""
        checkpoint_id = reviewed(storage)

        stopped = Run(storage, stop=lambda run: bool(run.extractor.read))(found(storage, "5"))

        assert stopped.cancelled
        assert "doc-5" not in storage.get_citation_reads(checkpoint_id)
        assert cited(storage, checkpoint_id) == ["doc-1", "doc-2"]
        run = Run(storage)
        run([])
        assert run.contexts == [] and run.extractor.read == ["doc-5"]

    def test_a_stop_before_anything_was_found_leaves_the_report(self) -> None:
        """Said plainly."""
        assert more_evidence_text(MoreEvidence(cancelled=True)) == (
            "Cancelled, so the report is unchanged.")


class TestTransparency:
    """The new documents without a stored result are analysed."""

    def test_each_new_document_is_analysed_once(self, storage: LiteStorage) -> None:
        """Relevant or not, as the review analyses every document it finds."""
        reviewed(storage)
        assessed: list[str] = []

        Run(storage, assessed=assessed)(found(storage, "5", "6"))

        assert assessed == ["doc-5", "doc-6"]

    def test_a_failure_is_counted_in_the_readers_words(self, storage: LiteStorage) -> None:
        """Its cause, never the provider's text (#330)."""
        reviewed(storage)

        def assess(doc: LiteDocument, text: str | None) -> None:
            if doc.id == "doc-6":
                raise ConnectionError("https://api.example/?key=sk-secret")

        outcome = Run(storage, assess=assess)(found(storage, "5", "6"))

        assert outcome.transparency_failures == (
            PassFailure(document_id="doc-6", cause=EvaluationErrorCode.API_CONNECTION_ERROR),)
        text = more_evidence_text(outcome)
        assert "Transparency could not be analysed for 1 document." in text
        assert "sk-secret" not in text


# ---------------------------------------------------------------------------
# The review's own smart search
# ---------------------------------------------------------------------------


def review(monkeypatch: pytest.MonkeyPatch, scores: dict[str, int],
           answers: list[str], results: dict[str, Any] | None = None, *,
           checker: Any = None, screens: list[Any] | None = None,
           rerun_judged: set[str] | None = None) -> Any:
    """Run a review whose agents are scripted; returns (search agent, scorer, finished, notices).

    A query's result is its documents, an exception it raises, or the
    shortfalls it lost. ``rerun_judged`` runs it as *Re-run Search*'s review,
    the question's earlier runs having judged those documents.
    """
    from bmlibrarian_lite.gui import systematic_review_tab
    from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker
    from bmlibrarian_lite.search_failures import retrieval_shortfalls_to_metadata

    documents = [make_document(p) for p in scores if p in ("1", "2", "3")]
    session = SearchSession(id="s", query="aspirin AND stroke", natural_language_query=QUESTION,
                            created_at=datetime.now(UTC), document_count=len(documents),
                            metadata={"provider": "pubmed"})
    agent = MagicMock()
    agent.search.return_value = (session, documents)
    agent.ask.side_effect = list(answers)

    def search_with_query(query: str, **_: Any) -> Any:
        result = (results or {}).get(query, [])
        if isinstance(result, Exception):
            raise result
        if result and isinstance(result[0], RetrievalShortfall):
            lost = SearchSession(id="s2", query=query, natural_language_query=QUESTION,
                                 created_at=datetime.now(UTC), document_count=0,
                                 metadata={"provider": "pubmed",
                                           **retrieval_shortfalls_to_metadata(result)})
            return lost, []
        return session, list(result)

    agent.search_with_query.side_effect = search_with_query
    monkeypatch.setattr(systematic_review_tab, "LiteSearchAgent", lambda **_: agent)
    scorer = MagicMock()
    scorer.score_document.side_effect = lambda question, doc: ScoredDocument(
        doc, scores[doc.pmid], "On topic.")
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scorer)
    extractor = MagicMock()
    extractor.extract_all_citations.return_value = CitationOutcome(citations=[], documents_attempted=0)
    monkeypatch.setattr(systematic_review_tab, "LiteCitationAgent", lambda **_: extractor)
    reporter = MagicMock()
    reporter.generate_report.return_value = "## Findings"
    monkeypatch.setattr(systematic_review_tab, "LiteReportingAgent", lambda **_: reporter)

    config = LiteConfig()
    config.transparency.enabled = False
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    storage = MagicMock()
    storage.get_smart_search_queries.return_value = []
    storage.get_uploaded_full_texts.return_value = {}
    storage.get_rerun_document_ids_for_question.return_value = (rerun_judged or set(), set())
    if checker is not None:
        monkeypatch.setattr(WorkflowWorker, "_fresh_retraction_checker", lambda self: checker)
    worker = WorkflowWorker(
        question=QUESTION, config=config, storage=storage, min_score=3,
        retraction_checker=checker,
        preloaded_documents=documents if rerun_judged is not None else None,
        pubmed_query="aspirin AND stroke" if rerun_judged is not None else None,
    )
    finished: list[Any] = []
    notices: list[str] = []
    worker.finished.connect(lambda report, metadata: finished.append(metadata))
    worker.smart_search_notice.connect(notices.append)
    if screens is not None:
        worker.retraction_screened.connect(screens.append)
    worker.run()
    return agent, scorer, finished, notices


class RetractingChecker:
    """Says the papers named are retracted, every other one clear."""

    def __init__(self, *retracted: str) -> None:
        """Retract these document ids."""
        self.retracted = retracted

    def check(self, documents: list[LiteDocument], **_: Any) -> dict[str, Any]:
        """Each document's verdict."""
        from bmlib.publications.retraction_status import (
            RetractionEvidence,
            RetractionKind,
            RetractionSource,
            RetractionStatus,
            RetractionVerdict,
        )

        from bmlibrarian_lite.retraction_store import PaperCheck

        evidence = RetractionEvidence(source=RetractionSource.RETRACTION_WATCH_EXPORT,
                                      kind=RetractionKind.RETRACTION, date="2026-03-09",
                                      notice_doi="10.9/notice")
        return {
            d.id: PaperCheck(
                RetractionVerdict(RetractionStatus.RETRACTED, evidence) if d.id in self.retracted
                else RetractionVerdict(RetractionStatus.CLEAR),
                datetime.now(UTC), None, None,
            )
            for d in documents
        }

    def close(self) -> None:
        """Nothing to close."""


ALTERNATIVE = '[{"concepts": [{"name": "aspirin", "mesh_terms": ["Aspirin"], "keywords": []}]}]'


class TestTheReviewsOwnSmartSearch:
    """Too few relevant documents: a round runs, and what it finds is scored."""

    def test_too_few_relevant_runs_a_round(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Its documents scored with the rest, its query in the report."""
        query = '(("Aspirin"[mh])) AND humans[mh] AND hasabstract'
        agent, scorer, finished, notices = review(
            monkeypatch, {"1": 5, "2": 2, "5": 5}, [ALTERNATIVE],
            {query: [make_document("1"), make_document("5")]},
        )

        assert [c.args[1].id for c in scorer.score_document.call_args_list] == [
            "doc-1", "doc-2", "doc-5"]
        metadata = finished[0]
        assert metadata.alternative_queries == [query]
        assert (metadata.documents_retrieved, metadata.documents_accepted) == (3, 2)
        assert notices == []

    def test_enough_relevant_runs_none(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Nothing asked, nothing paid."""
        agent, _, finished, _ = review(monkeypatch, {"1": 5, "2": 4, "3": 3}, [])

        agent.ask.assert_not_called()
        assert finished[0].alternative_queries == []

    def test_a_round_that_cannot_run_is_said_and_the_review_goes_on(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """No usable query, after asking twice more."""
        agent, _, finished, notices = review(monkeypatch, {"1": 5, "2": 2}, ["[]", "[]", "[]"])

        assert agent.ask.call_count == 3
        assert len(notices) == 1 and "no usable alternative search query" in notices[0]
        assert finished and finished[0].documents_accepted == 1

    def test_a_retracted_paper_it_finds_is_never_scored(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Screened like the search's, and the run's screen covers both."""
        query = '(("Aspirin"[mh])) AND humans[mh] AND hasabstract'
        screens: list[Any] = []
        _, scorer, finished, _ = review(
            monkeypatch, {"1": 5, "2": 2, "5": 5, "6": 4}, [ALTERNATIVE],
            {query: [make_document("5"), make_document("6")]},
            checker=RetractingChecker("doc-5"), screens=screens,
        )

        assert "doc-5" not in [c.args[1].id for c in scorer.score_document.call_args_list]
        merged = screens[-1]
        assert [d.id for d in merged.excluded] == ["doc-5"]
        assert {"doc-1", "doc-2", "doc-6"} <= {d.id for d in merged.kept}
        assert finished[0].retraction_screen is merged

    def test_after_a_rerun_earlier_runs_papers_are_not_scored_again(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Re-run Search scores only what no run has judged (#316)."""
        query = '(("Aspirin"[mh])) AND humans[mh] AND hasabstract'
        _, scorer, _, _ = review(
            monkeypatch, {"1": 5, "2": 2, "5": 5, "9": 5}, [ALTERNATIVE],
            {query: [make_document("9"), make_document("5")]}, rerun_judged={"doc-9"},
        )

        assert [c.args[1].id for c in scorer.score_document.call_args_list] == [
            "doc-1", "doc-2", "doc-5"]

    def test_a_round_that_breaks_is_said_and_the_review_goes_on(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Its idea, not the reader's: never the review's end, nor the provider's text."""
        query = '(("Aspirin"[mh])) AND humans[mh] AND hasabstract'
        _, _, finished, notices = review(
            monkeypatch, {"1": 5, "2": 2}, [ALTERNATIVE],
            {query: RuntimeError("https://api.example/?key=sk-secret")},
        )

        assert finished and finished[0].documents_accepted == 1
        assert len(notices) == 1 and notices[0].startswith("Alternative searches could not")
        assert "sk-secret" not in notices[0]

    def test_what_its_queries_lose_is_kept(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Recorded as an alternative search's, and the review goes on."""
        query = '(("Aspirin"[mh])) AND humans[mh] AND hasabstract'
        lost = RetrievalShortfall(SearchProvider.EUROPEPMC,
                                  RequestFailure(RequestFailureKind.TIMEOUT), records_missing=4)
        _, _, finished, _ = review(monkeypatch, {"1": 5, "2": 2}, [ALTERNATIVE], {query: [lost]})

        assert finished[0].search_shortfalls == [
            RetrievalShortfall(SearchProvider.EUROPEPMC, RequestFailure(RequestFailureKind.TIMEOUT),
                               records_missing=4, query=ShortfallQuery.ALTERNATIVE)]
        assert finished[0].alternative_queries == [query]


class TestTheWorker:
    """Exactly one ending, and the reader's words, never the provider's (#330)."""

    def run_worker(self, monkeypatch: pytest.MonkeyPatch, find: Any,
                   cancel: bool = False) -> dict[str, list[tuple[Any, ...]]]:
        """Run the worker in this thread over a scripted run."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite import agents, citation_full_texts, more_evidence
        from bmlibrarian_lite.gui.workers import MoreEvidenceWorker

        for name in ("LiteCitationAgent", "LiteReportingAgent", "LiteScoringAgent",
                     "LiteSearchAgent"):
            monkeypatch.setattr(agents, name, lambda **_: MagicMock())
        monkeypatch.setattr(citation_full_texts, "full_text_fetcher", lambda config: None)

        def scripted(*args: Any, **kwargs: Any) -> MoreEvidence:
            if cancel:
                worker.cancel()
            return find()

        monkeypatch.setattr(more_evidence, "find_more_evidence", scripted)
        config = LiteConfig()
        config.transparency.enabled = False
        worker = MoreEvidenceWorker(QUESTION, [], [], config, MagicMock())
        ended: dict[str, list[tuple[Any, ...]]] = {}
        for name in ("finished", "error", "cancelled"):
            getattr(worker, name).connect(
                lambda *args, name=name: ended.setdefault(name, []).append(args))
        worker.run()
        return ended

    def test_a_run_that_ended_finishes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """With what it did."""
        outcome = MoreEvidence(found=1, report="New report.")
        assert self.run_worker(monkeypatch, lambda: outcome) == {"finished": [(outcome,)]}

    @pytest.mark.parametrize("refusal", [
        RetryNotPossible(NO_REPORT_TEXT),
        SmartSearchError(NO_USABLE_QUERY_TEXT),
    ], ids=["no report", "no query"])
    def test_one_that_cannot_run_says_why(self, monkeypatch: pytest.MonkeyPatch,
                                          refusal: Exception) -> None:
        """The refusal's own sentence."""
        def refuse() -> MoreEvidence:
            raise refusal

        assert self.run_worker(monkeypatch, refuse) == {"error": [(str(refusal),)]}

    def test_a_failed_search_says_what_failed_and_what_to_do(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The search's sentence and its advice."""
        lost = RetrievalShortfall(SearchProvider.PUBMED,
                                  RequestFailure(RequestFailureKind.TIMEOUT),
                                  query=ShortfallQuery.ALTERNATIVE)

        def fail() -> MoreEvidence:
            raise SearchFailedError([lost])

        ended = self.run_worker(monkeypatch, fail)
        assert list(ended) == ["error"]
        assert "an alternative search of PubMed could not be completed" in ended["error"][0][0]

    def test_a_failure_is_told_in_the_readers_words(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Never the provider's."""
        def fail() -> MoreEvidence:
            raise ConnectionError("https://api.example/?key=sk-secret")

        ended = self.run_worker(monkeypatch, fail)
        assert list(ended) == ["error"] and "sk-secret" not in ended["error"][0][0]

    def test_a_cancel_is_a_cancel(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Not a finish."""
        outcome = MoreEvidence(found=1, cancelled=True)
        ended = self.run_worker(monkeypatch, lambda: outcome, cancel=True)
        assert ended == {"cancelled": [(outcome, "")]}

    def test_a_failed_search_after_a_cancel_is_still_said(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A cancel does not excuse reporting a failure (rule 8)."""
        lost = RetrievalShortfall(SearchProvider.PUBMED,
                                  RequestFailure(RequestFailureKind.TIMEOUT),
                                  query=ShortfallQuery.ALTERNATIVE)

        def fail() -> MoreEvidence:
            raise SearchFailedError([lost])

        ended = self.run_worker(monkeypatch, fail, cancel=True)
        assert list(ended) == ["cancelled"]
        assert "an alternative search of PubMed could not be completed" in ended["cancelled"][0][1]


# ---------------------------------------------------------------------------
# The Research Questions tab
# ---------------------------------------------------------------------------


class Recording:
    """Stands in for a worker: every attribute is one mock, the arguments kept."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        """Keep what it was built with."""
        self.__dict__["args"] = args
        self.__dict__["kwargs"] = kwargs
        self.__dict__["_mocks"] = {}

    def __getattr__(self, name: str) -> MagicMock:
        """The same mock for a name every time."""
        return self.__dict__["_mocks"].setdefault(name, MagicMock())


@pytest.fixture
def tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Any:
    """A Research Questions tab over one reviewed question, selected."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    from bmlibrarian_lite.gui import research_questions_tab as tab_module

    QApplication.instance() or QApplication([])
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = LiteStorage(config)
    reviewed(storage)
    storage.create_search_session("aspirin AND stroke", QUESTION, document_count=3)
    monkeypatch.setattr(tab_module, "IncrementalSearchWorker", Recording)
    monkeypatch.setattr(tab_module, "MoreEvidenceWorker", Recording)
    box = MagicMock()
    box.question.return_value = box.StandardButton.Yes
    monkeypatch.setattr(tab_module, "QMessageBox", box)
    monkeypatch.setattr(tab_module.QTimer, "singleShot", MagicMock())
    widget = tab_module.ResearchQuestionsTab(config=config, storage=storage)
    widget.questions_table.selectRow(0)
    return widget


class TestTheTab:
    """The question's own query is paged, then the rest runs in its own worker."""

    def test_the_search_skips_every_document_scored_and_hands_on_what_it_found(
        self, tab: Any
    ) -> None:
        """Cancel then reaches the worker that is running."""
        tab._on_find_more_clicked()
        search = tab._worker
        assert search.kwargs["already_scored_ids"] == {"doc-1", "doc-2", "doc-3"}
        assert not tab.more_btn.isEnabled() and not tab.rerun_btn.isEnabled()

        documents = [make_document("5")]
        tab._on_more_search_finished(tab._get_selected_question(), documents, [])

        assert tab._worker is None
        evidence = tab._evidence_worker
        assert evidence.args[:3] == (QUESTION, documents, [])
        assert evidence.kwargs["max_results"] == tab.target_spin.value()
        evidence.start.assert_called_once_with()
        tab._on_cancel_clicked()
        evidence.cancel.assert_called_once_with()

    def test_a_cancel_as_the_paging_ends_runs_nothing_paid(self, tab: Any) -> None:
        """The paging finished despite the cancel: no second worker starts."""
        tab._on_find_more_clicked()
        tab._worker.__dict__["_cancelled"] = True

        tab._on_more_search_finished(tab._get_selected_question(), [make_document("5")], [])

        assert tab._evidence_worker is None
        assert tab.progress_label.text() == CANCELLED_UNCHANGED_TEXT
        assert tab.more_btn.isEnabled()

    def test_a_report_written_again_is_loaded(self, tab: Any) -> None:
        """And the tab is ready again."""
        loaded: list[tuple[str, str]] = []
        tab.question_selected.connect(lambda q, p: loaded.append((q, p)))
        tab._on_find_more_clicked()
        tab._on_more_search_finished(tab._get_selected_question(), [], [])

        tab._on_more_finished(MoreEvidence(found=1, report="New report."), QUESTION, "q")
        tab._cleanup_evidence_worker()

        assert loaded == [(QUESTION, "q")]
        assert tab.more_btn.isEnabled()
        assert tab._evidence_worker is None
