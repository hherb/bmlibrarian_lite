# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A finding an analyser we have since corrected made is not a finding (#360).

``analyze_document`` returned the stored row unconditionally, and
``analyzer_version`` -- written, read back, and compared by nobody -- had been
``"1.0"`` since it was introduced. So every semantic fix to the analyser
reached only documents analysed after it: after #352, #359 and #353--#356, a
user with a year of stored results keeps studies charged five points for a
disclosure the old extractor could not read, and studies badged HIGH risk for
a data availability statement nobody ever looked for.

Document ids are still ``pmid-<id>`` (#229), so the store is hit across
sessions: this is every article the user has ever searched, not a corner case.

Two halves, both here: a stale row is re-analysed on the path that already
queues and paces that work, and until it is, no surface presents it as a
finding -- the badge, the citation risk warnings, the report's counts, the
quality tier downgrade and the quality filter alike.
"""

from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.analysis_failures import superseded_assessment_caveat
from bmlibrarian_lite.transparency import (
    LEGACY_ANALYZER_VERSION,
    TRANSPARENCY_ANALYZER_VERSION,
    TransparencyResult,
    TransparencyRisk,
    TransparencySettings,
    count_transparency_results,
)

DOC = "pmid-12345678"


def a_result(
    version: str = TRANSPARENCY_ANALYZER_VERSION,
    risk: TransparencyRisk = TransparencyRisk.HIGH,
    document_id: str = DOC,
) -> TransparencyResult:
    """Build a stored assessment.

    Args:
        version: The analyser version that wrote it.
        risk: The risk level it found.
        document_id: The document it belongs to.

    Returns:
        The result.
    """
    return TransparencyResult(
        document_id=document_id,
        transparency_score=20,
        risk_level=risk,
        analyzer_version=version,
    )


def an_assessment() -> Any:
    """Build a quality assessment a high transparency risk would downgrade.

    Returns:
        The assessment, at the experimental tier.
    """
    from bmlibrarian_lite.quality.data_models import (
        QualityAssessment,
        QualityTier,
        StudyDesign,
    )

    return QualityAssessment(
        assessment_tier=2,
        extraction_method="llm_haiku",
        study_design=StudyDesign.RCT,
        quality_tier=QualityTier.TIER_4_EXPERIMENTAL,
        quality_score=8.0,
        confidence=0.9,
    )


class TestWhatCountsAsCurrent:
    """One constant decides it, and a row carries the version that wrote it."""

    def test_a_new_result_carries_this_build_s_version(self) -> None:
        """A result written now is this analyser's finding."""
        assert TransparencyResult(
            document_id=DOC,
            transparency_score=50,
            risk_level=TransparencyRisk.LOW,
        ).analyzer_version == TRANSPARENCY_ANALYZER_VERSION

    def test_the_version_moved_past_the_rows_the_defect_left(self) -> None:
        """Every stored row said 1.0, so 1.0 can no longer mean current."""
        assert TRANSPARENCY_ANALYZER_VERSION != LEGACY_ANALYZER_VERSION

    def test_a_row_from_an_older_analyser_is_not_current(self) -> None:
        """The comparison #360 found nobody making."""
        assert not a_result(version=LEGACY_ANALYZER_VERSION).is_current

    def test_a_row_from_this_analyser_is_current(self) -> None:
        """The control: the predicate is not simply always false."""
        assert a_result().is_current


class TestTheCaveatTheReaderSees:
    """A superseded row is reported, not silently dropped."""

    def test_it_says_the_assessment_is_being_redone(self) -> None:
        """The reader is told why a badge went blank, and that it will return."""
        caveat = superseded_assessment_caveat()

        assert "not a finding against the study" in caveat
        assert "re-analys" in caveat


class TestTheManagerRedoesAStaleRow:
    """The cache hit that kept every corrected analysis away from the store."""

    @staticmethod
    def _manager(storage: Any) -> Any:
        """Build a manager over the given storage.

        Args:
            storage: The store to read the cache from.

        Returns:
            The manager, with a stand-in analyzer.
        """
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.transparency import TransparencyManager

        config = MagicMock()
        config.transparency = TransparencySettings()
        with patch(
            "bmlibrarian_lite.transparency.assessment."
            "StudyTransparencyAnalyzer"
        ):
            return TransparencyManager(
                storage=storage, config=config, email="test@example.com"
            )

    @staticmethod
    def _stub_executor(manager: Any) -> Any:
        """Stand in for the thread pool, so queueing is observable at once.

        Args:
            manager: The manager to stub.

        Returns:
            The stand-in executor, whose ``submit`` records the call.

        Asserting on ``get_pending_count`` instead would race the worker
        thread: the stand-in analyzer fails immediately, which pops the
        entry again.
        """
        executor = MagicMock()
        manager._executor = executor
        manager.start = lambda: None
        return executor

    def test_a_current_row_is_served_from_the_cache(self) -> None:
        """The control: a paced network path is not walked for nothing."""
        storage = MagicMock()
        storage.get_transparency_result.return_value = a_result()
        manager = self._manager(storage)
        results: list[Any] = []
        manager.analysis_complete.connect(
            lambda doc_id, result: results.append(result)
        )

        manager.analyze_document(DOC, pmid="12345678")

        assert results and results[0].is_current
        assert manager.get_pending_count() == 0

    def test_a_stale_row_is_not_served_as_a_finding(self) -> None:
        """A row written before the corrections is re-analysed, not returned."""
        storage = MagicMock()
        storage.get_transparency_result.return_value = a_result(
            version=LEGACY_ANALYZER_VERSION
        )
        manager = self._manager(storage)
        results: list[Any] = []
        manager.analysis_complete.connect(
            lambda doc_id, result: results.append(result)
        )
        submitted = self._stub_executor(manager)

        manager.analyze_document(DOC, pmid="12345678")

        assert results == [], "the stale row was handed back as a finding"
        # Withheld, not dropped. Without this the row could simply vanish:
        # no finding served *and* no re-analysis queued, so the badge never
        # comes back and the whole suite stays green.
        assert submitted.submit.called, "nothing was queued to redo the row"

    def test_a_provisional_row_is_re_analysed_too(self) -> None:
        """A row whose analysis could not reach a source is a miss (#346)."""
        stored = a_result()
        stored.sources_unreachable = True
        storage = MagicMock()
        storage.get_transparency_result.return_value = stored
        manager = self._manager(storage)
        results: list[Any] = []
        manager.analysis_complete.connect(
            lambda doc_id, result: results.append(result)
        )
        submitted = self._stub_executor(manager)

        manager.analyze_document(DOC, pmid="12345678")

        assert results == [], "a provisional row was served as a settled one"
        assert submitted.submit.called, "the provisional row was not redone"


class TestTheStoreKnowsWhatStillNeedsAnalysing:
    """``get_documents_pending_transparency`` only looked for missing rows.

    It also had no caller (#373); the Research Questions tab's re-analysis
    now asks it, over the documents a reloaded question shows.
    """

    @staticmethod
    def _storage(tmp_path: Any) -> Any:
        """Build a storage over a temporary database.

        Args:
            tmp_path: The pytest temporary directory.

        Returns:
            The storage.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return LiteStorage(config)

    @staticmethod
    def _add_document(storage: Any, doc_id: str, **ids: Any) -> None:
        """Store a document and record it as found for question "Q".

        Args:
            storage: The storage.
            doc_id: The document's id.
            **ids: Its ``pmid`` and ``doi``, if any.
        """
        from bmlibrarian_lite.data_models import DocumentSource, LiteDocument

        storage.add_document(
            LiteDocument(
                id=doc_id,
                title="A study",
                abstract="An abstract.",
                authors=["A"],
                year=2024,
                source=DocumentSource.PUBMED,
                **ids,
            )
        )
        storage.add_question_documents("Q", [doc_id])

    def test_a_stale_row_is_pending_and_a_current_one_is_not(
        self, tmp_path: Any
    ) -> None:
        """Both halves in one place: the fix, and the control beside it."""
        storage = self._storage(tmp_path)
        for doc_id, version in (
            ("old", LEGACY_ANALYZER_VERSION),
            ("new", TRANSPARENCY_ANALYZER_VERSION),
        ):
            self._add_document(storage, doc_id)
            storage.save_transparency_result(
                a_result(version=version, document_id=doc_id)
            )

        pending = storage.get_documents_pending_transparency("Q")

        assert pending == ["old"]

    def test_a_document_with_no_row_is_pending(self, tmp_path: Any) -> None:
        """The case the query was written for, still answered."""
        storage = self._storage(tmp_path)
        self._add_document(storage, "never")

        assert storage.get_documents_pending_transparency("Q") == ["never"]

    def test_a_newer_analysers_row_is_not_pending(self, tmp_path: Any) -> None:
        """Ordered, not matched: re-analysing it would overwrite a better row."""
        storage = self._storage(tmp_path)
        self._add_document(storage, "later")
        storage.save_transparency_result(
            a_result(version="10.0", document_id="later")
        )

        assert storage.get_documents_pending_transparency("Q") == []

    def test_another_questions_documents_are_not_pending_here(
        self, tmp_path: Any
    ) -> None:
        """Scoped by question: a pass may not reach documents it cannot show."""
        storage = self._storage(tmp_path)
        self._add_document(storage, "mine")
        storage.add_question_documents("Another question", ["elsewhere"])

        assert storage.get_documents_pending_transparency("Q") == ["mine"]

    def test_a_provisional_row_is_pending_and_round_trips(
        self, tmp_path: Any
    ) -> None:
        """A current row whose sources were unreadable is still work to do."""
        storage = self._storage(tmp_path)
        self._add_document(storage, "throttled")
        provisional = a_result(document_id="throttled")
        provisional.sources_unreachable = True
        storage.save_transparency_result(provisional)

        reloaded = storage.get_transparency_result("throttled")

        assert reloaded.sources_unreachable, "the flag did not survive storage"
        assert not reloaded.is_final
        assert storage.get_documents_pending_transparency("Q") == ["throttled"]

    def test_a_stored_row_keeps_the_version_that_wrote_it(
        self, tmp_path: Any
    ) -> None:
        """A version that does not round-trip makes every row look current."""
        storage = self._storage(tmp_path)
        storage.save_transparency_result(a_result(version=LEGACY_ANALYZER_VERSION))

        stored = storage.get_transparency_result(DOC)

        assert stored is not None
        assert stored.analyzer_version == LEGACY_ANALYZER_VERSION
        assert not stored.is_current


class TestNoSurfacePresentsASupersededFinding:
    """Five places read a stored row and made a claim from it."""

    def test_a_superseded_row_raises_no_citation_warning(self) -> None:
        """A pre-correction HIGH risk no longer qualifies a clinician's report."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            should_warn_for_citation,
        )
        from bmlibrarian_lite.transparency.transparency_settings import (
            ReportRiskThreshold,
        )

        settings = TransparencySettings()
        settings.report_risk_threshold = ReportRiskThreshold.LOW

        assert not should_warn_for_citation(
            a_result(version=LEGACY_ANALYZER_VERSION), settings
        )

    def test_a_current_row_still_raises_one(self) -> None:
        """The control: the report has not stopped warning altogether."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            should_warn_for_citation,
        )

        assert should_warn_for_citation(a_result(), TransparencySettings())

    def test_a_superseded_row_downgrades_no_quality_tier(self) -> None:
        """A tier the corrected analyser would not have taken stays."""
        from bmlibrarian_lite.quality.data_models import QualityTier
        from bmlibrarian_lite.quality.quality_manager import QualityManager

        config = MagicMock()
        config.quality = MagicMock()
        config.transparency = TransparencySettings()
        manager = QualityManager(config)

        adjusted = manager.get_adjusted_quality(
            an_assessment(), a_result(version=LEGACY_ANALYZER_VERSION)
        )

        assert adjusted.quality_tier == QualityTier.TIER_4_EXPERIMENTAL

    def test_a_current_row_still_downgrades(self) -> None:
        """The control: the downgrade still happens for a finding that stands."""
        from bmlibrarian_lite.quality.data_models import QualityTier
        from bmlibrarian_lite.quality.quality_manager import QualityManager

        config = MagicMock()
        config.quality = MagicMock()
        config.transparency = TransparencySettings()
        manager = QualityManager(config)

        adjusted = manager.get_adjusted_quality(an_assessment(), a_result())

        assert adjusted.quality_tier != QualityTier.TIER_4_EXPERIMENTAL

    def test_a_superseded_row_excludes_no_document_from_the_review(self) -> None:
        """Filtering a study out on a retracted finding is the worst of these."""
        from bmlibrarian_lite.quality.quality_manager import QualityManager

        settings = TransparencySettings()
        settings.filtering_enabled = True
        config = MagicMock()
        config.quality = MagicMock()
        config.transparency = settings
        manager = QualityManager(config)

        assert not manager.should_filter_document(
            a_result(version=LEGACY_ANALYZER_VERSION)
        )
        assert manager.should_filter_document(a_result())

    def test_the_report_counts_superseded_rows_apart(self) -> None:
        """A count that includes them reports an analysis that did not run."""
        counts = count_transparency_results(
            [
                a_result(risk=TransparencyRisk.LOW, document_id="a"),
                a_result(risk=TransparencyRisk.HIGH, document_id="b"),
                a_result(
                    risk=TransparencyRisk.HIGH,
                    version=LEGACY_ANALYZER_VERSION,
                    document_id="c",
                ),
            ]
        )

        assert counts.low == 1
        assert counts.high == 1
        assert counts.medium == 0
        assert counts.superseded == 1

    def test_the_report_says_how_many_await_re_analysis(self) -> None:
        """A document left out of the counts is reported, not dropped."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import ReportMetadata

        metadata = ReportMetadata(
            research_question="Q",
            transparency_analysis_applied=True,
            transparency_low_risk_count=1,
            transparency_superseded_count=2,
        )

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "2" in section
        assert "re-analys" in section

    def test_the_badge_shows_a_superseded_row_as_unassessed(self) -> None:
        """What the reader sees where the finding used to be."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.gui.transparency_badge import (
            UNASSESSED_LABEL,
            TransparencyBadge,
        )
        from bmlibrarian_lite.transparency import transparency_outcome

        QApplication.instance() or QApplication([])
        badge = TransparencyBadge(
            transparency_outcome(a_result(version=LEGACY_ANALYZER_VERSION))
        )

        assert badge.label.text() == UNASSESSED_LABEL
        assert "re-analys" in badge.toolTip()

    def test_a_current_row_still_shows_its_risk(self) -> None:
        """The control, one layer up from the badge's own."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.gui.transparency_badge import (
            RISK_LABELS,
            TransparencyBadge,
        )
        from bmlibrarian_lite.transparency import transparency_outcome

        QApplication.instance() or QApplication([])
        badge = TransparencyBadge(transparency_outcome(a_result()))

        assert badge.label.text() == RISK_LABELS[TransparencyRisk.HIGH]


class TestTheGatesAreActuallyAsked:
    """A predicate nobody calls is the defect one layer up (#349's lesson)."""

    def test_the_audit_trail_draws_a_superseded_result_as_unassessed(self) -> None:
        """The production path, not the pure function it is built from."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.data_models import DocumentSource, LiteDocument
        from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

        QApplication.instance() or QApplication([])
        tab = AuditTrailTab(config=MagicMock(), storage=MagicMock())
        tab.literature_tab._add_document_card(
            LiteDocument(
                id=DOC,
                title="A study",
                abstract="An abstract.",
                authors=["A"],
                year=2024,
                source=DocumentSource.PUBMED,
            )
        )

        tab.on_transparency_outcome(DOC, a_result(version=LEGACY_ANALYZER_VERSION))

        card = tab.literature_tab._cards_by_doc_id[DOC]
        assert card.get_transparency_result() is None
        assert "re-analys" in card._transparency_badge.toolTip()

    def test_the_audit_trail_still_draws_a_current_result(self) -> None:
        """The control: the badge has not gone blank for everything."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.data_models import DocumentSource, LiteDocument
        from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

        QApplication.instance() or QApplication([])
        tab = AuditTrailTab(config=MagicMock(), storage=MagicMock())
        tab.literature_tab._add_document_card(
            LiteDocument(
                id=DOC,
                title="A study",
                abstract="An abstract.",
                authors=["A"],
                year=2024,
                source=DocumentSource.PUBMED,
            )
        )

        tab.on_transparency_outcome(DOC, a_result())

        card = tab.literature_tab._cards_by_doc_id[DOC]
        assert card.get_transparency_result() is not None
        assert card.transparency_risk == TransparencyRisk.HIGH.value

    def test_the_workflow_counts_superseded_rows_apart(self) -> None:
        """The report's own numbers, from the worker that fills them."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.data_models import ReportMetadata
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = {
            "a": a_result(risk=TransparencyRisk.LOW, document_id="a"),
            "b": a_result(version=LEGACY_ANALYZER_VERSION, document_id="b"),
        }
        metadata = ReportMetadata(research_question="Q")

        WorkflowWorker._record_transparency_counts(worker, metadata, ["a", "b"])

        assert metadata.transparency_analysis_applied
        assert metadata.transparency_low_risk_count == 1
        assert metadata.transparency_high_risk_count == 0
        assert metadata.transparency_superseded_count == 1


class TestAVersionIsOrderedNotMatched:
    """Strictly older, not merely different.

    Equality also called a row stamped with a *newer* version superseded.
    ``save_transparency_result`` is ``INSERT OR REPLACE``, so re-analysing it
    overwrote a better finding with this build's worse one -- and the caveat
    shown for it says an *earlier* analyser made it, which only an ordering
    establishes. Swift settled this first, under CloudKit sync.
    """

    def test_an_older_analysers_row_is_superseded(self) -> None:
        """The case the gates exist for."""
        assert not a_result(version=LEGACY_ANALYZER_VERSION).is_current

    def test_this_builds_row_stands(self) -> None:
        """The control."""
        assert a_result().is_current

    def test_a_newer_analysers_row_is_not_superseded(self) -> None:
        """Two builds over one store must not re-analyse each other's work."""
        assert a_result(version="99.0").is_current

    def test_ten_sorts_after_two(self) -> None:
        """The trap a textual comparison walks into."""
        from bmlibrarian_lite.transparency import analyzer_version_ordinal

        assert analyzer_version_ordinal("2.0") < analyzer_version_ordinal("10.0")

    def test_an_unreadable_version_sorts_oldest(self) -> None:
        """An unknown provenance is re-analysed, never trusted."""
        assert not a_result(version="not-a-version").is_current

    def test_a_dict_with_no_version_is_not_current(self) -> None:
        """``from_dict``'s legacy default, pinned.

        A stored dict written before the field was compared to anything has
        no version key. Defaulting it to this build's would let every gate
        wave it through.
        """
        data = a_result().to_dict()
        del data["analyzer_version"]

        assert not TransparencyResult.from_dict(data).is_current

    def test_a_dict_carrying_an_explicit_null_still_reads_as_a_string(
        self,
    ) -> None:
        """``or``, not a ``get`` default: no ``None`` in a field typed str."""
        data = a_result().to_dict()
        data["analyzer_version"] = None

        assert TransparencyResult.from_dict(data).analyzer_version == (
            LEGACY_ANALYZER_VERSION
        )


class TestAProvisionalFindingIsNotASettledOne:
    """A source that could not be read makes the finding provisional (#346).

    Neither fetch raises: a throttled PubMed returns "unreachable" and the
    analysis finishes, with a caveat and a score that fell because nothing
    could be established. Stamped with the current version, that row
    answered ``is_current`` forever -- a transient outage became a permanent
    risk claim no re-analysis would ever revisit.
    """

    @staticmethod
    def _provisional() -> TransparencyResult:
        """Build a current row whose analysis could not reach a source.

        Returns:
            The provisional result.
        """
        result = a_result()
        result.sources_unreachable = True
        return result

    def test_a_provisional_row_is_not_final(self) -> None:
        """The predicate the cache asks."""
        assert not self._provisional().is_final

    def test_a_complete_row_is_final(self) -> None:
        """The control: every source answered."""
        assert a_result().is_final

    def test_a_superseded_row_is_not_final_either(self) -> None:
        """Both halves of the question, one predicate."""
        assert not a_result(version=LEGACY_ANALYZER_VERSION).is_final

    def test_a_provisional_row_is_still_a_finding_to_present(self) -> None:
        """It is re-analysed, not withheld: the caveat is what qualifies it."""
        assert self._provisional().is_current

    def test_the_annotation_says_the_finding_rests_on_less(self) -> None:
        """The reference list never showed the analysis caveats (#346)."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            format_reference_risk_annotation,
        )

        annotation = format_reference_risk_annotation(self._provisional())

        assert "provisional" in annotation

    def test_a_complete_findings_annotation_says_no_such_thing(self) -> None:
        """The control."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            format_reference_risk_annotation,
        )

        assert "provisional" not in format_reference_risk_annotation(a_result())


class TestEveryDocumentAskedAboutIsAccountedFor:
    """A failed analysis is not a study with nothing to declare (#361, #249).

    ``_record_transparency_counts`` returned early when nothing had been
    stored, so the report said "Transparency analysis was not applied" over
    an analysis that ran against every study and failed on every one. A
    partial outage was quieter and no better: the denominator simply shrank.
    """

    @staticmethod
    def _metadata_over(stored: dict, document_ids: list[str]) -> Any:
        """Fill report metadata from a stored batch.

        Args:
            stored: What the store holds, by document id.
            document_ids: Every document the review found.

        Returns:
            The filled metadata.
        """
        from bmlibrarian_lite.data_models import ReportMetadata
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = stored
        metadata = ReportMetadata(research_question="Q")
        WorkflowWorker._record_transparency_counts(worker, metadata, document_ids)
        return metadata

    def test_a_total_outage_is_still_an_analysis_that_was_applied(self) -> None:
        """The false statement: "Transparency analysis was not applied"."""
        pytest.importorskip("PySide6")

        metadata = self._metadata_over({}, ["a", "b", "c"])

        assert metadata.transparency_analysis_applied
        assert metadata.transparency_unassessed_count == 3

    def test_a_partial_outage_names_what_did_not_come_back(self) -> None:
        """The denominator may not quietly shrink."""
        pytest.importorskip("PySide6")

        metadata = self._metadata_over(
            {"a": a_result(risk=TransparencyRisk.LOW, document_id="a")},
            ["a", "b", "c"],
        )

        assert metadata.transparency_low_risk_count == 1
        assert metadata.transparency_unassessed_count == 2

    def test_a_complete_run_leaves_nothing_unassessed(self) -> None:
        """The control."""
        pytest.importorskip("PySide6")

        metadata = self._metadata_over(
            {
                "a": a_result(risk=TransparencyRisk.LOW, document_id="a"),
                "b": a_result(risk=TransparencyRisk.HIGH, document_id="b"),
            },
            ["a", "b"],
        )

        assert metadata.transparency_unassessed_count == 0

    def test_the_report_names_them(self) -> None:
        """The sentence the reader actually gets."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import ReportMetadata

        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True
        metadata.transparency_unassessed_count = 4

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "Not assessed:** 4" in section
        assert "Transparency analysis was not applied" not in section

    def test_a_clean_run_says_nothing_about_them(self) -> None:
        """The control: no line when nothing went unassessed."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import ReportMetadata

        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True
        metadata.transparency_low_risk_count = 2

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "Not assessed:" not in section


class TestAnUnknownLevelIsCountedSomewhere:
    """The distribution may not quietly lose a row (#360)."""

    def test_a_current_unknown_row_is_counted(self) -> None:
        """It fell through every bucket, so nothing could report it at all."""
        counts = count_transparency_results([a_result(risk=TransparencyRisk.UNKNOWN)])

        assert counts.unknown == 1
        # Not among the named levels: there is no level to name. It is
        # reported under the studies that came back without a finding.
        assert counts.assessed == 0

    def test_an_unknown_row_is_reported_as_not_assessed(self) -> None:
        """Whatever bucket it lands in, it may not vanish."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.data_models import ReportMetadata
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = {
            DOC: a_result(risk=TransparencyRisk.UNKNOWN)
        }
        metadata = ReportMetadata(research_question="Q")

        WorkflowWorker._record_transparency_counts(worker, metadata, [DOC])

        assert metadata.transparency_unassessed_count == 1

    def test_a_named_level_is_still_counted_as_itself(self) -> None:
        """The control."""
        counts = count_transparency_results([a_result(risk=TransparencyRisk.HIGH)])

        assert counts.high == 1
        assert counts.unknown == 0


class TestAWithheldFindingIsNamedInTheReferences:
    """A withheld study must not read as one with no concerns found (#360).

    ``should_warn_for_citation`` answering False silences the inline marker,
    the reference annotation and the prompt's risk block at once, so a
    superseded HIGH-risk study appeared in the reference list byte-identical
    to one this build had assessed as low risk. The aggregate "Awaiting
    re-analysis" line is counted over every document the review found, while
    the annotations follow the cited ones, so it could not be mapped onto
    any reference.
    """

    @staticmethod
    def _references(stored: dict) -> str:
        """Render a one-document reference list against a stored batch.

        Args:
            stored: What the store holds, by document id.

        Returns:
            The formatted reference list.
        """
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import (
            Citation,
            DocumentSource,
            LiteDocument,
        )

        document = LiteDocument(
            id=DOC,
            title="A study",
            abstract="An abstract.",
            authors=["Author A"],
            year=2024,
            source=DocumentSource.PUBMED,
        )
        citation = Citation(
            document=document,
            passage="A passage.",
            relevance_score=4,
        )
        withheld = {
            doc_id: superseded_assessment_caveat()
            for doc_id, r in stored.items()
            if not r.is_current
        }
        risky = {
            doc_id: r for doc_id, r in stored.items() if r.is_current
        }
        return LiteReportingAgent._format_references_with_risk(
            MagicMock(), [citation], risky, withheld
        )

    def test_a_superseded_study_says_so(self) -> None:
        """Bare is not neutral: it reads as "nothing found against it"."""
        references = self._references(
            {DOC: a_result(version=LEGACY_ANALYZER_VERSION)}
        )

        assert "TRANSPARENCY NOT ASSESSED" in references
        assert "re-analys" in references

    def test_a_current_finding_still_carries_its_risk(self) -> None:
        """The control."""
        references = self._references({DOC: a_result()})

        assert "HIGH RISK" in references
        assert "TRANSPARENCY NOT ASSESSED" not in references


class TestTheGatesTheReviewFound:
    """Surfaces that read a stored row without asking whose it was."""

    def test_the_tab_withholds_a_superseded_row(self) -> None:
        """Its caller cannot tell a retracted finding from a current one."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        tab = MagicMock()
        tab.storage.get_transparency_result.return_value = a_result(
            version=LEGACY_ANALYZER_VERSION
        )

        assert SystematicReviewTab.get_transparency_result(tab, DOC) is None

    def test_the_tab_still_returns_a_current_row(self) -> None:
        """The control."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        tab = MagicMock()
        tab.storage.get_transparency_result.return_value = a_result()

        assert SystematicReviewTab.get_transparency_result(tab, DOC) is not None

    def test_the_small_badge_does_not_draw_a_retracted_level(self) -> None:
        """The one class beside the fixed badge that could still show one."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.gui.transparency_badge import TransparencyBadgeSmall

        QApplication.instance() or QApplication([])
        badge = TransparencyBadgeSmall(
            result=a_result(version=LEGACY_ANALYZER_VERSION)
        )

        assert badge.text() == "?"
        assert "re-analys" in badge.toolTip()

    def test_the_small_badge_still_draws_a_current_one(self) -> None:
        """The control."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.gui.transparency_badge import TransparencyBadgeSmall

        QApplication.instance() or QApplication([])

        assert TransparencyBadgeSmall(result=a_result()).text() == "H"
