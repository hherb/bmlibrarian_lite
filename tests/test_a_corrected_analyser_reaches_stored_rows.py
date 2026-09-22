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
            "bmlibrarian_lite.transparency.transparency_manager."
            "StudyTransparencyAnalyzer"
        ):
            return TransparencyManager(
                storage=storage, config=config, email="test@example.com"
            )

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
        manager.stop()  # no executor: the queued work does not run here

        manager.analyze_document(DOC, pmid="12345678")

        assert results == [], "the stale row was handed back as a finding"


class TestTheStoreKnowsWhatStillNeedsAnalysing:
    """``get_documents_pending_transparency`` only looked for missing rows."""

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

    def test_a_stale_row_is_pending_and_a_current_one_is_not(
        self, tmp_path: Any
    ) -> None:
        """Both halves in one place: the fix, and the control beside it."""
        from bmlibrarian_lite.data_models import (
            DocumentSource,
            LiteDocument,
            ScoredDocument,
        )

        storage = self._storage(tmp_path)
        session = storage.create_search_session(
            query="q", natural_language_query="Q"
        )
        checkpoint = storage.create_checkpoint(research_question="Q")
        storage.update_checkpoint(
            checkpoint_id=checkpoint.id, search_session_id=session.id
        )
        for doc_id, version in (("old", LEGACY_ANALYZER_VERSION), ("new", None)):
            document = LiteDocument(
                id=doc_id,
                title="A study",
                abstract="An abstract.",
                authors=["A"],
                year=2024,
                source=DocumentSource.PUBMED,
            )
            storage.add_document(document)
            storage.save_scored_document(
                ScoredDocument(document=document, score=4, explanation="r"),
                checkpoint.id,
            )
            storage.save_transparency_result(
                a_result(
                    version=version or TRANSPARENCY_ANALYZER_VERSION,
                    document_id=doc_id,
                )
            )

        pending = storage.get_documents_pending_transparency(session.id)

        assert "old" in pending
        assert "new" not in pending

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
