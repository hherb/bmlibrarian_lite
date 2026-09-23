# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""One stored transparency row this build cannot decode is one row (#374).

``_transparency_result_from_row`` built ``TransparencyRisk(row["risk_level"])``,
which raises for a value this build does not know -- a risk level a newer
build wrote into a shared ``~/.bmlibrarian_lite``. The batch reader did not
catch it, so one row failed the read for every document asked about: a
review's report failed, and a reloaded question lost every badge.

The row is now carried as an :class:`UndecodableTransparencyRow` beside the
rows that decoded, and withheld at every surface on its own. What may be
done with it is the user's call (2026-09-23), decided by the one column that
survives: a row whose ``analyzer_version`` is strictly newer than this
build's is a newer build's finding and is never overwritten; any other is
damaged, stays pending, and re-analysis replaces it.
"""

from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.analysis_failures import (
    damaged_assessment_caveat,
    reanalysis_advice,
    superseded_assessment_caveat,
    transparency_failure_text,
)
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ReportMetadata,
    TransparencyAnalysisFailure,
    TransparencyFailureKind,
)
from bmlibrarian_lite.transparency import (
    TRANSPARENCY_ANALYZER_VERSION,
    TransparencyResult,
    TransparencyRisk,
    TransparencySettings,
    TransparencyUnassessed,
    UndecodableTransparencyRow,
    count_transparency_over,
    pending_transparency_ids,
    stored_transparency_outcomes,
    undecodable_row_caveat,
)

#: A version no build has reached yet, so the row reads as a newer build's.
NEWER_VERSION = "99.0"


def a_row(document_id: str, risk: TransparencyRisk = TransparencyRisk.LOW) -> Any:
    """Build a current stored assessment.

    Args:
        document_id: The document it belongs to.
        risk: The risk level it found.

    Returns:
        The result.
    """
    return TransparencyResult(
        document_id=document_id, transparency_score=80, risk_level=risk
    )


def a_document(document_id: str, pmid: str | None = "12345678") -> LiteDocument:
    """Build a document.

    Args:
        document_id: Its id.
        pmid: Its PubMed ID, or None for a record carrying no identifier.

    Returns:
        The document.
    """
    return LiteDocument(
        id=document_id,
        title="A study",
        abstract="An abstract.",
        authors=["Author A"],
        year=2024,
        source=DocumentSource.PUBMED,
        pmid=pmid,
    )


NEWER = UndecodableTransparencyRow("newer", NEWER_VERSION)
DAMAGED = UndecodableTransparencyRow("damaged", TRANSPARENCY_ANALYZER_VERSION)


class TestTheStoreWithholdsOneRowAlone:
    """Against a real database, with the row corrupted underneath it."""

    @staticmethod
    def _storage(tmp_path: Any) -> Any:
        """Build a storage over a temporary database, with question "Q".

        Args:
            tmp_path: The pytest temporary directory.

        Returns:
            The storage, holding documents ``a`` and ``b`` with current rows.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)
        for doc_id in ("a", "b"):
            storage.add_document(a_document(doc_id))
            storage.save_transparency_result(a_row(doc_id))
        storage.add_question_documents("Q", ["a", "b"])
        return storage

    @staticmethod
    def _corrupt(storage: Any, doc_id: str, column: str, value: Any) -> None:
        """Write a value straight into a stored row, as another build could.

        Args:
            storage: The storage.
            doc_id: Whose row.
            column: Which column; a fixed name from this test, never input.
            value: What to write.
        """
        with storage._sqlite_connection() as conn:
            conn.execute(
                f"UPDATE transparency_results SET {column} = ? "
                "WHERE document_id = ?",
                (value, doc_id),
            )
            conn.commit()

    def test_every_row_decodes_when_none_is_damaged(self, tmp_path: Any) -> None:
        """The control: the fixture itself reads clean."""
        storage = self._storage(tmp_path)

        stored = storage.get_transparency_results_batch(["a", "b"])

        assert all(isinstance(row, TransparencyResult) for row in stored.values())

    def test_a_newer_builds_risk_level_fails_only_its_own_row(
        self, tmp_path: Any
    ) -> None:
        """The case the issue names: the rest of the batch still reads."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "risk_level", "extreme")
        self._corrupt(storage, "b", "analyzer_version", NEWER_VERSION)

        stored = storage.get_transparency_results_batch(["a", "b"])

        assert isinstance(stored["a"], TransparencyResult)
        assert stored["b"] == UndecodableTransparencyRow("b", NEWER_VERSION)
        assert stored["b"].written_by_newer_build

    def test_a_timestamp_that_will_not_parse_is_damage(
        self, tmp_path: Any
    ) -> None:
        """This build's version, so nothing says another build wrote it."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "analyzed_at", "last Tuesday")

        stored = storage.get_transparency_results_batch(["a", "b"])

        assert stored["b"] == UndecodableTransparencyRow(
            "b", TRANSPARENCY_ANALYZER_VERSION
        )
        assert not stored["b"].written_by_newer_build

    def test_a_value_of_the_wrong_type_is_withheld_too(
        self, tmp_path: Any
    ) -> None:
        """A TypeError, not a ValueError: a TEXT column still keeps a BLOB."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "analyzed_at", b"\x00")

        stored = storage.get_transparency_results_batch(["a", "b"])

        assert isinstance(stored["b"], UndecodableTransparencyRow)

    @pytest.mark.parametrize("column", ["risk_level", "data_availability_level"])
    def test_text_that_is_not_utf8_fails_only_its_own_row(
        self, tmp_path: Any, column: str
    ) -> None:
        """sqlite3 raised this from the cursor, before any row could be held.

        ``data_availability_level`` is the quieter half: nothing decodes it,
        so it would have reached a badge as a ``bytes`` value.
        """
        storage = self._storage(tmp_path)
        with storage._sqlite_connection() as conn:
            conn.execute(
                f"UPDATE transparency_results SET {column} = CAST(X'FF' AS TEXT) "
                "WHERE document_id = 'b'"
            )
            conn.commit()

        stored = storage.get_transparency_results_batch(["a", "b"])

        assert isinstance(stored["a"], TransparencyResult)
        assert stored["b"] == UndecodableTransparencyRow(
            "b", TRANSPARENCY_ANALYZER_VERSION
        )
        assert isinstance(
            storage.get_transparency_result("b"), UndecodableTransparencyRow
        )

    def test_a_newer_builds_row_is_logged_without_a_traceback(
        self, tmp_path: Any, caplog: Any
    ) -> None:
        """Expected and permanent, so not an error on every read."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "risk_level", "extreme")
        self._corrupt(storage, "b", "analyzer_version", NEWER_VERSION)

        storage.get_transparency_results_batch(["b"])

        [record] = [r for r in caplog.records if "document b" in r.getMessage()]
        assert record.levelname == "WARNING"
        assert record.exc_info is None

    def test_a_damaged_row_is_logged_as_an_error(
        self, tmp_path: Any, caplog: Any
    ) -> None:
        """The control: damage is worth a traceback."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "risk_level", "extreme")

        storage.get_transparency_results_batch(["b"])

        [record] = [r for r in caplog.records if "document b" in r.getMessage()]
        assert record.levelname == "ERROR"
        assert record.exc_info is not None

    def test_the_single_reader_withholds_it_as_well(self, tmp_path: Any) -> None:
        """The manager's cache check reads one row at a time."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "risk_level", "extreme")

        assert isinstance(
            storage.get_transparency_result("b"), UndecodableTransparencyRow
        )
        assert isinstance(storage.get_transparency_result("a"), TransparencyResult)

    def test_a_damaged_row_is_pending_and_a_newer_one_is_not(
        self, tmp_path: Any
    ) -> None:
        """The user's split, read off the store the pass asks."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "a", "risk_level", "extreme")
        self._corrupt(storage, "b", "risk_level", "extreme")
        self._corrupt(storage, "b", "analyzer_version", NEWER_VERSION)

        assert storage.get_documents_pending_transparency("Q") == ["a"]

    def test_a_re_analysis_replaces_a_damaged_row(self, tmp_path: Any) -> None:
        """Pending is only worth something if the save then reads back."""
        storage = self._storage(tmp_path)
        self._corrupt(storage, "b", "risk_level", "extreme")

        storage.save_transparency_result(a_row("b", TransparencyRisk.HIGH))

        reread = storage.get_transparency_result("b")
        assert isinstance(reread, TransparencyResult)
        assert reread.risk_level is TransparencyRisk.HIGH


class TestTheRowAndItsVerdict:
    """The value, and the ordering that decides what may be done with it."""

    def test_a_row_names_its_document(self) -> None:
        """A row about nobody could not be withheld from anyone."""
        with pytest.raises(ValueError):
            UndecodableTransparencyRow("", NEWER_VERSION)

    def test_a_newer_version_is_a_newer_builds_row(self) -> None:
        """Strictly newer, so it is not ours to overwrite."""
        assert NEWER.written_by_newer_build

    def test_this_builds_version_is_damage(self) -> None:
        """Equal is not newer: this build wrote it, and it will not read."""
        assert not DAMAGED.written_by_newer_build

    def test_an_empty_or_unreadable_version_is_damage(self) -> None:
        """An unknown provenance sorts oldest, as it does for is_current."""
        assert not UndecodableTransparencyRow("x", None).written_by_newer_build
        assert not UndecodableTransparencyRow("x", "draft").written_by_newer_build

    def test_only_the_damaged_row_is_pending(self) -> None:
        """The same verdict the store gave, from the pure function."""
        stored = {"newer": NEWER, "damaged": DAMAGED, "current": a_row("current")}

        assert pending_transparency_ids(
            stored, ["newer", "damaged", "current"]
        ) == ["damaged"]


class TestWhatTheReaderIsTold:
    """Withheld with its reason, and never called an earlier analyser's."""

    def test_a_newer_builds_row_says_so(self) -> None:
        """The reader learns why the badge is blank, and that it stays so."""
        caveat = undecodable_row_caveat(NEWER)

        assert "newer version of BMLibrarian Lite" in caveat
        assert "not a finding against the study" in caveat
        assert caveat != superseded_assessment_caveat()

    def test_a_damaged_row_says_so(self) -> None:
        """Not superseded: nothing says an earlier analyser wrote it."""
        caveat = undecodable_row_caveat(DAMAGED)

        assert caveat == damaged_assessment_caveat()
        assert "earlier version" not in caveat
        assert "newer version" not in caveat

    def test_the_newer_builds_failure_asks_nothing_of_a_provider(self) -> None:
        """Nothing was asked, so no provider can have failed."""
        with pytest.raises(ValueError):
            TransparencyAnalysisFailure(
                document_id="x",
                kind=TransparencyFailureKind.WRITTEN_BY_NEWER_BUILD,
                cause=EvaluationErrorCode.API_CONNECTION_ERROR,
            )

    def test_the_newer_builds_failure_reads_as_its_caveat(self) -> None:
        """One sentence for the badge a review draws and the one a load draws."""
        assert transparency_failure_text(
            TransparencyAnalysisFailure.written_by_newer_build("x")
        ) == undecodable_row_caveat(NEWER)

    def test_a_reloaded_question_badges_each_row_on_its_own(self) -> None:
        """The rest of the question keeps its badges."""
        documents = [a_document("current"), a_document("newer"), a_document("damaged")]
        current = a_row("current")

        outcomes = stored_transparency_outcomes(
            documents, {"current": current, "newer": NEWER, "damaged": DAMAGED}
        )

        assert outcomes["current"] is current
        # Advice only where the pass would act on it: it leaves a newer
        # build's row alone, so sending the reader to it would be false.
        assert outcomes["newer"] == TransparencyUnassessed(
            undecodable_row_caveat(NEWER)
        )
        assert outcomes["damaged"] == TransparencyUnassessed(
            damaged_assessment_caveat() + reanalysis_advice()
        )

    def test_a_document_with_no_identifier_says_that_first(self) -> None:
        """No pass can help it, whatever its row holds."""
        outcomes = stored_transparency_outcomes(
            [a_document("damaged", pmid=None)], {"damaged": DAMAGED}
        )

        assert outcomes["damaged"] == TransparencyUnassessed(
            transparency_failure_text(
                TransparencyAnalysisFailure.no_identifier("damaged")
            )
        )


class TestTheReportCountsAndAnnotatesIt:
    """The report step the batch read used to take down."""

    def test_it_is_counted_as_not_assessed(self) -> None:
        """In a bucket, so the population the report names still adds up."""
        counts = count_transparency_over(
            {"a": a_row("a"), "newer": NEWER, "damaged": DAMAGED},
            ["a", "newer", "damaged"],
        )

        assert counts.low == 1
        assert counts.undecodable == 2
        assert counts.not_assessed == 2
        assert counts.superseded == 0
        assert counts.considered == 3

    def test_the_workflow_records_it(self) -> None:
        """The worker that fills the report's numbers."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = {
            "a": a_row("a"),
            "damaged": DAMAGED,
        }
        metadata = ReportMetadata(research_question="Q")

        WorkflowWorker._record_transparency_counts(
            worker, metadata, ["a", "damaged"], ["damaged"]
        )

        assert metadata.transparency_low_risk_count == 1
        assert metadata.transparency_unassessed_count == 1
        assert metadata.transparency_unassessed_cited_count == 1
        assert metadata.transparency_documents_considered == 2

    def test_each_kind_is_annotated_in_the_references(self) -> None:
        """Every cited study the count names can be found in the list."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            withheld_reference_caveats,
        )

        caveats = withheld_reference_caveats(
            ["newer", "damaged", "a"],
            {"newer": NEWER, "damaged": DAMAGED, "a": a_row("a")},
            True,
        )

        assert caveats == {
            "newer": undecodable_row_caveat(NEWER),
            "damaged": undecodable_row_caveat(DAMAGED),
        }

    def test_a_report_citing_it_is_written(self) -> None:
        """End to end: the report no longer fails over one row."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import Citation

        config = MagicMock()
        config.transparency = TransparencySettings(enabled=True)
        citation = Citation(
            document=a_document("newer"), passage="P.", relevance_score=4
        )
        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True

        with patch.object(
            LiteReportingAgent, "_chat", return_value="Body [A](docid:newer)."
        ):
            report = LiteReportingAgent(config=config).generate_report(
                "Q", [citation], metadata, transparency_results={"newer": NEWER}
            )

        assert "TRANSPARENCY NOT ASSESSED" in report
        assert "newer version of BMLibrarian Lite" in report

    def test_the_methodology_names_it_among_the_reasons(self) -> None:
        """The count may not list reasons that exclude the row it counts."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent

        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True
        metadata.transparency_unassessed_count = 1

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "its stored assessment could not be read" in section


class TestTheManagerLeavesANewerBuildsRowAlone:
    """The cache check, which read one row and raised out of the review."""

    @staticmethod
    def _manager(stored: Any, cache_results: bool = True) -> Any:
        """Build a manager whose store holds one row, and a stand-in pool.

        Args:
            stored: What the store returns for the document.
            cache_results: The user's "Cache results" setting.

        Returns:
            The manager, whose ``_executor.submit`` records what was queued.
        """
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.transparency import TransparencyManager

        storage = MagicMock()
        storage.get_transparency_result.return_value = stored
        config = MagicMock()
        config.transparency = TransparencySettings(cache_results=cache_results)
        with patch(
            "bmlibrarian_lite.transparency.assessment.StudyTransparencyAnalyzer"
        ):
            manager = TransparencyManager(
                storage=storage, config=config, email="test@example.com"
            )
        manager._executor = MagicMock()
        manager.start = lambda: None
        return manager

    def test_a_newer_builds_row_is_reported_and_not_redone(self) -> None:
        """Re-analysing it would overwrite that build's finding."""
        manager = self._manager(UndecodableTransparencyRow("x", NEWER_VERSION))
        failures: list[Any] = []
        manager.analysis_failed.connect(lambda _id, failure: failures.append(failure))

        manager.analyze_document("x", pmid="12345678")

        assert failures == [TransparencyAnalysisFailure.written_by_newer_build("x")]
        manager._executor.submit.assert_not_called()

    def test_switching_the_cache_off_does_not_overwrite_it(self) -> None:
        """Not reusing this build's results is not leave to replace another's."""
        manager = self._manager(
            UndecodableTransparencyRow("x", NEWER_VERSION), cache_results=False
        )
        failures: list[Any] = []
        manager.analysis_failed.connect(lambda _id, failure: failures.append(failure))

        manager.analyze_document("x", pmid="12345678")

        assert failures == [TransparencyAnalysisFailure.written_by_newer_build("x")]
        manager._executor.submit.assert_not_called()

    def test_with_the_cache_off_a_current_row_is_still_redone(self) -> None:
        """The control: the setting still means what it says."""
        manager = self._manager(a_row("x"), cache_results=False)

        manager.analyze_document("x", pmid="12345678")

        assert manager._executor.submit.called

    def test_a_damaged_row_is_redone(self) -> None:
        """Nothing is lost by replacing it, and nothing else will."""
        manager = self._manager(
            UndecodableTransparencyRow("x", TRANSPARENCY_ANALYZER_VERSION)
        )
        failures: list[Any] = []
        manager.analysis_failed.connect(lambda _id, failure: failures.append(failure))

        manager.analyze_document("x", pmid="12345678")

        assert failures == []
        assert manager._executor.submit.called

    def test_the_review_tabs_getter_returns_no_finding_for_it(self) -> None:
        """A caller asking for a finding gets none, rather than a crash."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        tab = MagicMock()
        tab.storage.get_transparency_result.return_value = NEWER

        assert SystematicReviewTab.get_transparency_result(tab, "newer") is None
