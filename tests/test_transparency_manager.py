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

"""Tests for TransparencyManager."""

from datetime import datetime
from unittest.mock import MagicMock, patch
import time

import pytest

from bmlibrarian_lite.transparency import (
    TransparencyManager,
    TransparencyResult,
    TransparencyRisk,
    TransparencySettings,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    TransparencyReport,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ConflictOfInterest,
    ResultsComplianceStatus,
)


@pytest.fixture
def mock_storage():
    """Create a mock storage object."""
    storage = MagicMock()
    storage.get_transparency_result.return_value = None
    storage.save_transparency_result.return_value = None
    return storage


@pytest.fixture
def mock_config():
    """Create a mock config object with transparency settings."""
    config = MagicMock()
    config.transparency = TransparencySettings()
    return config


@pytest.fixture
def mock_report():
    """Create a mock TransparencyReport."""
    return TransparencyReport(
        pmid="12345678",
        doi="10.1234/test",
        title="Test Study",
        transparency_score=75.0,
        industry_funding_detected=False,
        industry_funding_confidence=0.1,
        data_availability=DataAvailabilityInfo(
            statement="Data available on request",
            disclosure_level=DataDisclosureLevel.AVAILABLE_ON_REQUEST,
        ),
        coi_info=ConflictOfInterest(
            statement="No conflicts declared",
            has_industry_ties=False,
        ),
        trial_registrations=[],
        results_compliance=ResultsComplianceStatus.NOT_REQUIRED,
        outcome_switching_detected=False,
        risk_of_bias_indicators=[],
    )


@pytest.fixture
def manager(mock_storage, mock_config):
    """Create a TransparencyManager with mocked dependencies."""
    with patch(
        "bmlibrarian_lite.transparency.transparency_manager.StudyTransparencyAnalyzer"
    ) as mock_analyzer_class:
        manager = TransparencyManager(
            storage=mock_storage,
            config=mock_config,
            email="test@example.com",
        )
        yield manager
        manager.stop()


class TestTransparencyManagerInit:
    """Tests for TransparencyManager initialization."""

    def test_init_creates_analyzer(self, mock_storage, mock_config):
        """Test that init creates the analyzer."""
        with patch(
            "bmlibrarian_lite.transparency.transparency_manager.StudyTransparencyAnalyzer"
        ) as mock_cls:
            manager = TransparencyManager(
                storage=mock_storage,
                config=mock_config,
                email="test@example.com",
                pubmed_api_key="test_key",
            )
            mock_cls.assert_called_once_with(
                email="test@example.com",
                pubmed_api_key="test_key",
            )
            manager.stop()

    def test_init_sets_settings_from_config(self, mock_storage, mock_config):
        """Test that settings are loaded from config."""
        mock_config.transparency.score_threshold = 50
        with patch(
            "bmlibrarian_lite.transparency.transparency_manager.StudyTransparencyAnalyzer"
        ):
            manager = TransparencyManager(
                storage=mock_storage,
                config=mock_config,
                email="test@example.com",
            )
            assert manager.settings.score_threshold == 50
            manager.stop()


class TestTransparencyManagerStartStop:
    """Tests for start/stop functionality."""

    def test_start_creates_executor(self, manager):
        """Test that start creates a thread pool."""
        assert manager._executor is None
        manager.start()
        assert manager._executor is not None

    def test_start_is_idempotent(self, manager):
        """Test that multiple starts don't create multiple executors."""
        manager.start()
        executor1 = manager._executor
        manager.start()
        assert manager._executor is executor1

    def test_stop_clears_executor(self, manager):
        """Test that stop clears the executor."""
        manager.start()
        manager.stop()
        assert manager._executor is None

    def test_stop_clears_pending_futures(self, manager):
        """Test that stop clears pending futures."""
        manager.start()
        manager._pending_futures["test"] = MagicMock()
        manager.stop()
        assert len(manager._pending_futures) == 0


class TestAnalyzeDocument:
    """Tests for analyze_document method."""

    def test_disabled_does_nothing(self, manager, mock_storage):
        """Test that disabled manager doesn't analyze."""
        manager.settings.enabled = False
        manager.analyze_document("doc1", pmid="12345678")
        mock_storage.get_transparency_result.assert_not_called()

    def test_no_pmid_or_doi_fails(self, manager):
        """Test that missing identifiers emits failure signal."""
        signals = []
        manager.analysis_failed.connect(lambda doc_id, msg: signals.append((doc_id, msg)))

        manager.analyze_document("doc1")

        assert len(signals) == 1
        assert signals[0][0] == "doc1"
        assert "No PMID or DOI" in signals[0][1]

    def test_cached_result_returned(self, manager, mock_storage):
        """Test that cached results are returned without re-analysis."""
        cached_result = TransparencyResult(
            document_id="doc1",
            transparency_score=80,
            risk_level=TransparencyRisk.LOW,
        )
        mock_storage.get_transparency_result.return_value = cached_result

        signals = []
        manager.analysis_complete.connect(lambda doc_id, result: signals.append((doc_id, result)))

        manager.analyze_document("doc1", pmid="12345678")

        assert len(signals) == 1
        assert signals[0][0] == "doc1"
        assert signals[0][1] == cached_result

    def test_caching_disabled_skips_cache(self, manager, mock_storage):
        """Test that disabled caching doesn't check cache."""
        manager.settings.cache_results = False
        manager.analyze_document("doc1", pmid="12345678")
        mock_storage.get_transparency_result.assert_not_called()

    def test_already_queued_not_duplicated(self, manager):
        """Test that same document isn't queued twice."""
        manager.start()
        manager._pending_futures["doc1"] = MagicMock()

        # This should not add another entry
        with patch.object(manager._executor, "submit") as mock_submit:
            manager.analyze_document("doc1", pmid="12345678")
            mock_submit.assert_not_called()


class TestAnalyzeWorker:
    """Tests for the background worker."""

    def test_worker_creates_result(self, manager, mock_storage, mock_report):
        """Test that worker creates correct TransparencyResult."""
        manager._analyzer.analyze = MagicMock(return_value=mock_report)

        result = manager._analyze_worker("doc1", "12345678", None, None)

        assert result.document_id == "doc1"
        assert result.transparency_score == 75
        assert result.industry_funding_detected is False
        assert result.coi_disclosed is True
        assert result.data_availability_level == "on_request"

    def test_worker_saves_result(self, manager, mock_storage, mock_report):
        """Test that worker saves result to storage."""
        manager._analyzer.analyze = MagicMock(return_value=mock_report)

        manager._analyze_worker("doc1", "12345678", None, None)

        mock_storage.save_transparency_result.assert_called_once()

    def test_worker_calculates_high_risk(self, manager, mock_storage):
        """Test high risk calculation for low score."""
        low_score_report = TransparencyReport(
            transparency_score=30.0,  # Below threshold
            industry_funding_detected=False,
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN,
            ),
            coi_info=ConflictOfInterest(statement="None declared"),
        )
        manager._analyzer.analyze = MagicMock(return_value=low_score_report)

        result = manager._analyze_worker("doc1", "12345678", None, None)

        assert result.risk_level == TransparencyRisk.HIGH
        assert result.tier_downgrade_applied == 1  # Default downgrade amount

    def test_worker_calculates_low_risk(self, manager, mock_storage):
        """Test low risk calculation for high transparency."""
        high_score_report = TransparencyReport(
            transparency_score=85.0,
            industry_funding_detected=False,
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN,
            ),
            coi_info=ConflictOfInterest(statement="None declared"),
        )
        manager._analyzer.analyze = MagicMock(return_value=high_score_report)

        result = manager._analyze_worker("doc1", "12345678", None, None)

        assert result.risk_level == TransparencyRisk.LOW
        assert result.tier_downgrade_applied == 0

    def test_worker_handles_missing_coi(self, manager, mock_storage):
        """Test handling of missing COI info."""
        report = TransparencyReport(
            transparency_score=75.0,
            industry_funding_detected=False,
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN,
            ),
            coi_info=None,  # Missing COI
        )
        manager._analyzer.analyze = MagicMock(return_value=report)

        result = manager._analyze_worker("doc1", "12345678", None, None)

        assert result.coi_disclosed is False
        # Missing COI triggers high risk by default
        assert result.risk_level == TransparencyRisk.HIGH


class TestAnalyzeBatch:
    """Tests for batch analysis."""

    def test_batch_queues_all_documents(self, manager):
        """Test that batch queues all documents."""
        documents = [
            {"id": "doc1", "pmid": "11111111"},
            {"id": "doc2", "pmid": "22222222"},
            {"id": "doc3", "doi": "10.1234/test"},
        ]

        with patch.object(manager, "analyze_document") as mock_analyze:
            manager.analyze_batch(documents)

            assert mock_analyze.call_count == 3

    def test_batch_emits_progress(self, manager):
        """Test that batch emits progress signals."""
        documents = [
            {"id": "doc1", "pmid": "11111111"},
            {"id": "doc2", "pmid": "22222222"},
        ]

        progress_signals = []
        manager.progress_updated.connect(
            lambda current, total: progress_signals.append((current, total))
        )

        with patch.object(manager, "analyze_document"):
            manager.analyze_batch(documents)

        assert len(progress_signals) == 2
        assert progress_signals[0] == (1, 2)
        assert progress_signals[1] == (2, 2)

    def test_batch_calls_progress_callback(self, manager):
        """Test that batch calls progress callback."""
        documents = [
            {"id": "doc1", "pmid": "11111111"},
            {"id": "doc2", "pmid": "22222222"},
        ]

        callback_calls = []

        def callback(current, total):
            callback_calls.append((current, total))

        with patch.object(manager, "analyze_document"):
            manager.analyze_batch(documents, progress_callback=callback)

        assert len(callback_calls) == 2

    def test_batch_disabled_does_nothing(self, manager):
        """Test that disabled manager skips batch."""
        manager.settings.enabled = False

        with patch.object(manager, "analyze_document") as mock_analyze:
            manager.analyze_batch([{"id": "doc1", "pmid": "11111111"}])
            mock_analyze.assert_not_called()


class TestUpdateSettings:
    """Tests for settings updates."""

    def test_update_settings_changes_settings(self, manager):
        """Test that settings are updated."""
        new_settings = TransparencySettings(score_threshold=60)
        manager.update_settings(new_settings)
        assert manager.settings.score_threshold == 60

    def test_update_concurrency_restarts_executor(self, manager):
        """Test that changing concurrency restarts executor."""
        manager.start()
        old_executor = manager._executor

        new_settings = TransparencySettings(max_concurrent_analyses=5)
        manager.update_settings(new_settings)

        # Executor should be recreated
        manager.start()
        assert manager._executor is not old_executor


class TestUtilityMethods:
    """Tests for utility methods."""

    def test_get_pending_count(self, manager):
        """Test pending count."""
        manager._pending_futures = {"a": MagicMock(), "b": MagicMock()}
        assert manager.get_pending_count() == 2

    def test_is_analysis_pending(self, manager):
        """Test checking if analysis is pending."""
        manager._pending_futures = {"doc1": MagicMock()}
        assert manager.is_analysis_pending("doc1") is True
        assert manager.is_analysis_pending("doc2") is False

    def test_cancel_all(self, manager):
        """Test cancelling all pending."""
        mock_future1 = MagicMock()
        mock_future2 = MagicMock()
        manager._pending_futures = {"a": mock_future1, "b": mock_future2}

        manager.cancel_all()

        mock_future1.cancel.assert_called_once()
        mock_future2.cancel.assert_called_once()
        assert len(manager._pending_futures) == 0
