"""Tests for quality assessment benchmarking module."""

import pytest
from datetime import datetime
from unittest.mock import MagicMock, patch

from bmlibrarian_lite.benchmarking.quality_models import (
    QualityEvaluatorStats,
    QualityDocumentComparison,
    QualityBenchmarkResult,
    QualityEvaluation,
)
from bmlibrarian_lite.benchmarking.quality_statistics import (
    compute_quality_evaluator_stats,
    compute_design_agreement,
    compute_tier_agreement,
    compute_design_agreement_matrix,
    compute_tier_agreement_matrix,
    compute_quality_document_comparison,
    find_design_disagreement_documents,
    find_tier_disagreement_documents,
    compute_confidence_correlation,
    compute_mean_tier_difference,
)
from bmlibrarian_lite.data_models import Evaluator, EvaluatorType, LiteDocument
from bmlibrarian_lite.quality.data_models import (
    QualityAssessment,
    StudyDesign,
    QualityTier,
)


@pytest.fixture
def sample_evaluator() -> Evaluator:
    """Create a sample evaluator for testing."""
    return Evaluator.from_model_config(
        provider="anthropic",
        model_name="claude-sonnet-4-20250514",
        temperature=0.1,
    )


@pytest.fixture
def sample_document() -> LiteDocument:
    """Create a sample document for testing."""
    return LiteDocument(
        id="doc-001",
        title="Sample RCT Study",
        abstract="This is a randomized controlled trial...",
        authors=["Smith J", "Jones K"],
        journal="Test Journal",
        year=2024,
    )


@pytest.fixture
def sample_assessment() -> QualityAssessment:
    """Create a sample quality assessment."""
    return QualityAssessment(
        assessment_tier=3,
        extraction_method="llm_classification",
        study_design=StudyDesign.RCT,
        quality_tier=QualityTier.TIER_3_CONTROLLED,
        quality_score=0.8,
        confidence=0.85,
        strengths=["Good randomization", "Proper blinding"],
        limitations=["Small sample size"],
    )


@pytest.fixture
def sample_evaluation(
    sample_document: LiteDocument,
    sample_evaluator: Evaluator,
    sample_assessment: QualityAssessment,
) -> QualityEvaluation:
    """Create a sample quality evaluation."""
    return QualityEvaluation(
        document_id=sample_document.id,
        evaluator=sample_evaluator,
        assessment=sample_assessment,
        latency_ms=500.0,
        tokens_input=200,
        tokens_output=100,
        cost_usd=0.001,
    )


class TestQualityEvaluatorStats:
    """Tests for QualityEvaluatorStats dataclass."""

    def test_total_evaluations(
        self,
        sample_evaluator: Evaluator,
        sample_assessment: QualityAssessment,
    ):
        """Test total evaluations count."""
        stats = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment, sample_assessment],
            design_distribution={"rct": 2},
            tier_distribution={3: 2},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=400,
            total_tokens_output=200,
            total_cost_usd=0.002,
        )
        assert stats.total_evaluations == 2

    def test_cost_per_evaluation(
        self,
        sample_evaluator: Evaluator,
        sample_assessment: QualityAssessment,
    ):
        """Test cost per evaluation calculation."""
        stats = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment, sample_assessment],
            design_distribution={"rct": 2},
            tier_distribution={3: 2},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=400,
            total_tokens_output=200,
            total_cost_usd=0.004,
        )
        assert stats.cost_per_evaluation == pytest.approx(0.002)

    def test_cost_per_evaluation_zero_evals(
        self,
        sample_evaluator: Evaluator,
    ):
        """Test cost per evaluation with zero evaluations."""
        stats = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[],
            design_distribution={},
            tier_distribution={},
            mean_confidence=0.0,
            mean_latency_ms=0.0,
            total_tokens_input=0,
            total_tokens_output=0,
            total_cost_usd=0.0,
        )
        assert stats.cost_per_evaluation == 0.0

    def test_to_dict(
        self,
        sample_evaluator: Evaluator,
        sample_assessment: QualityAssessment,
    ):
        """Test serialization to dictionary."""
        stats = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment],
            design_distribution={"rct": 1},
            tier_distribution={3: 1},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=200,
            total_tokens_output=100,
            total_cost_usd=0.001,
        )
        result = stats.to_dict()

        assert "evaluator_id" in result
        assert result["total_evaluations"] == 1
        assert result["mean_confidence"] == 0.85


class TestQualityDocumentComparison:
    """Tests for QualityDocumentComparison dataclass."""

    def test_has_design_disagreement_true(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test design disagreement detection."""
        assessment2 = QualityAssessment(
            assessment_tier=3,
            extraction_method="llm_classification",
            study_design=StudyDesign.COHORT_PROSPECTIVE,
            quality_tier=QualityTier.TIER_3_CONTROLLED,
            quality_score=0.7,
            confidence=0.80,
        )

        comparison = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": assessment2},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.COHORT_PROSPECTIVE},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_3_CONTROLLED},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        assert comparison.has_design_disagreement is True

    def test_has_design_disagreement_false(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test no design disagreement."""
        comparison = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_3_CONTROLLED},
            confidences={"eval1": 0.85, "eval2": 0.90},
        )

        assert comparison.has_design_disagreement is False

    def test_max_tier_difference(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test max tier difference calculation."""
        comparison = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_5_SYNTHESIS, "eval2": QualityTier.TIER_2_OBSERVATIONAL},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        assert comparison.max_tier_difference == 3  # |5-2| = 3

    def test_has_tier_disagreement(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test tier disagreement detection (>1 difference)."""
        comparison = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_4_EXPERIMENTAL, "eval2": QualityTier.TIER_1_ANECDOTAL},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        assert comparison.has_tier_disagreement is True

        # Small difference should not be flagged
        comparison2 = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_4_EXPERIMENTAL},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        assert comparison2.has_tier_disagreement is False


class TestQualityBenchmarkResult:
    """Tests for QualityBenchmarkResult dataclass."""

    def test_total_evaluations(
        self,
        sample_evaluator: Evaluator,
        sample_assessment: QualityAssessment,
    ):
        """Test total evaluations across all evaluators."""
        stats1 = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment, sample_assessment],
            design_distribution={"rct": 2},
            tier_distribution={3: 2},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=400,
            total_tokens_output=200,
            total_cost_usd=0.002,
        )

        result = QualityBenchmarkResult(
            run_id="test-run",
            question="Test question",
            task_type="study_classification",
            evaluator_stats=[stats1],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )

        assert result.total_evaluations == 2

    def test_total_cost(
        self,
        sample_evaluator: Evaluator,
        sample_assessment: QualityAssessment,
    ):
        """Test total cost across evaluators."""
        stats1 = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment],
            design_distribution={"rct": 1},
            tier_distribution={3: 1},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=200,
            total_tokens_output=100,
            total_cost_usd=0.001,
        )
        stats2 = QualityEvaluatorStats(
            evaluator=sample_evaluator,
            assessments=[sample_assessment],
            design_distribution={"rct": 1},
            tier_distribution={3: 1},
            mean_confidence=0.85,
            mean_latency_ms=500.0,
            total_tokens_input=200,
            total_tokens_output=100,
            total_cost_usd=0.002,
        )

        result = QualityBenchmarkResult(
            run_id="test-run",
            question="Test question",
            task_type="study_classification",
            evaluator_stats=[stats1, stats2],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )

        assert result.total_cost_usd == pytest.approx(0.003)


class TestComputeDesignAgreement:
    """Tests for compute_design_agreement function."""

    def test_perfect_agreement(self):
        """Test 100% agreement."""
        designs1 = [StudyDesign.RCT, StudyDesign.RCT, StudyDesign.COHORT_PROSPECTIVE]
        designs2 = [StudyDesign.RCT, StudyDesign.RCT, StudyDesign.COHORT_PROSPECTIVE]

        assert compute_design_agreement(designs1, designs2) == 1.0

    def test_no_agreement(self):
        """Test 0% agreement."""
        designs1 = [StudyDesign.RCT, StudyDesign.RCT, StudyDesign.RCT]
        designs2 = [StudyDesign.COHORT_PROSPECTIVE, StudyDesign.CASE_CONTROL, StudyDesign.UNKNOWN]

        assert compute_design_agreement(designs1, designs2) == 0.0

    def test_partial_agreement(self):
        """Test partial agreement."""
        designs1 = [StudyDesign.RCT, StudyDesign.RCT, StudyDesign.COHORT_PROSPECTIVE]
        designs2 = [StudyDesign.RCT, StudyDesign.COHORT_PROSPECTIVE, StudyDesign.COHORT_PROSPECTIVE]

        agreement = compute_design_agreement(designs1, designs2)
        assert agreement == pytest.approx(2/3)  # 2 out of 3 match

    def test_empty_lists(self):
        """Test with empty lists (perfect agreement)."""
        assert compute_design_agreement([], []) == 1.0

    def test_mismatched_lengths_raises(self):
        """Test that mismatched lengths raise ValueError."""
        designs1 = [StudyDesign.RCT]
        designs2 = [StudyDesign.RCT, StudyDesign.RCT]

        with pytest.raises(ValueError):
            compute_design_agreement(designs1, designs2)


class TestComputeTierAgreement:
    """Tests for compute_tier_agreement function."""

    def test_exact_agreement(self):
        """Test 100% agreement with exact matches."""
        tiers1 = [QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_4_EXPERIMENTAL, QualityTier.TIER_2_OBSERVATIONAL]
        tiers2 = [QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_4_EXPERIMENTAL, QualityTier.TIER_2_OBSERVATIONAL]

        assert compute_tier_agreement(tiers1, tiers2) == 1.0

    def test_within_tolerance(self):
        """Test agreement within ±1 tolerance."""
        tiers1 = [QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_3_CONTROLLED]
        tiers2 = [QualityTier.TIER_2_OBSERVATIONAL, QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_4_EXPERIMENTAL]

        # All within ±1
        assert compute_tier_agreement(tiers1, tiers2, tolerance=1) == 1.0

    def test_outside_tolerance(self):
        """Test disagreement outside tolerance."""
        tiers1 = [QualityTier.TIER_5_SYNTHESIS, QualityTier.TIER_5_SYNTHESIS, QualityTier.TIER_5_SYNTHESIS]
        tiers2 = [QualityTier.TIER_1_ANECDOTAL, QualityTier.TIER_2_OBSERVATIONAL, QualityTier.TIER_4_EXPERIMENTAL]

        # |5-1|=4 (out), |5-2|=3 (out), |5-4|=1 (in) - only 1 of 3 within ±1
        assert compute_tier_agreement(tiers1, tiers2, tolerance=1) == pytest.approx(1/3)

    def test_custom_tolerance(self):
        """Test with custom tolerance."""
        tiers1 = [QualityTier.TIER_5_SYNTHESIS, QualityTier.TIER_4_EXPERIMENTAL]
        tiers2 = [QualityTier.TIER_2_OBSERVATIONAL, QualityTier.TIER_2_OBSERVATIONAL]

        # |5-2|=3, |4-2|=2 - neither within ±1
        assert compute_tier_agreement(tiers1, tiers2, tolerance=1) == 0.0
        # Both within ±3
        assert compute_tier_agreement(tiers1, tiers2, tolerance=3) == 1.0


class TestComputeDesignAgreementMatrix:
    """Tests for compute_design_agreement_matrix function."""

    def test_matrix_symmetry(self):
        """Test that matrix is symmetric."""
        evaluator_designs = {
            "eval1": [StudyDesign.RCT, StudyDesign.RCT],
            "eval2": [StudyDesign.RCT, StudyDesign.COHORT_PROSPECTIVE],
        }

        matrix = compute_design_agreement_matrix(evaluator_designs)

        # Self-agreement should be 1.0
        assert matrix[("eval1", "eval1")] == 1.0
        assert matrix[("eval2", "eval2")] == 1.0

        # Cross-agreement should be symmetric
        assert matrix[("eval1", "eval2")] == matrix[("eval2", "eval1")]


class TestComputeQualityDocumentComparison:
    """Tests for compute_quality_document_comparison function."""

    def test_creates_comparison(
        self,
        sample_document: LiteDocument,
        sample_evaluation: QualityEvaluation,
    ):
        """Test creating a document comparison."""
        evaluations_by_evaluator = {
            "Eval1": sample_evaluation,
        }

        comparison = compute_quality_document_comparison(
            sample_document, evaluations_by_evaluator
        )

        assert comparison.document == sample_document
        assert "Eval1" in comparison.designs
        assert comparison.designs["Eval1"] == StudyDesign.RCT


class TestFindDisagreementDocuments:
    """Tests for disagreement finding functions."""

    def test_find_design_disagreements(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test finding documents with design disagreement."""
        # Document with disagreement
        disagreement = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.COHORT_PROSPECTIVE},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_3_CONTROLLED},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        # Document with agreement
        agreement = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_3_CONTROLLED},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        results = find_design_disagreement_documents([disagreement, agreement])

        assert len(results) == 1
        assert results[0] == disagreement

    def test_find_tier_disagreements(
        self,
        sample_document: LiteDocument,
        sample_assessment: QualityAssessment,
    ):
        """Test finding documents with tier disagreement."""
        # Document with big tier difference
        disagreement = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_5_SYNTHESIS, "eval2": QualityTier.TIER_1_ANECDOTAL},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        # Document with small tier difference
        agreement = QualityDocumentComparison(
            document=sample_document,
            assessments={"eval1": sample_assessment, "eval2": sample_assessment},
            designs={"eval1": StudyDesign.RCT, "eval2": StudyDesign.RCT},
            tiers={"eval1": QualityTier.TIER_3_CONTROLLED, "eval2": QualityTier.TIER_4_EXPERIMENTAL},
            confidences={"eval1": 0.85, "eval2": 0.80},
        )

        # Default threshold is 2
        results = find_tier_disagreement_documents([disagreement, agreement], threshold=2)

        assert len(results) == 1
        assert results[0] == disagreement


class TestComputeMeanTierDifference:
    """Tests for compute_mean_tier_difference function."""

    def test_zero_difference(self):
        """Test with identical tiers."""
        tiers1 = [QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_3_CONTROLLED]
        tiers2 = [QualityTier.TIER_3_CONTROLLED, QualityTier.TIER_3_CONTROLLED]

        assert compute_mean_tier_difference(tiers1, tiers2) == 0.0

    def test_nonzero_difference(self):
        """Test with different tiers."""
        tiers1 = [QualityTier.TIER_5_SYNTHESIS, QualityTier.TIER_3_CONTROLLED]
        tiers2 = [QualityTier.TIER_2_OBSERVATIONAL, QualityTier.TIER_1_ANECDOTAL]

        # |5-2| + |3-1| = 3 + 2 = 5, mean = 2.5
        assert compute_mean_tier_difference(tiers1, tiers2) == 2.5


class TestComputeConfidenceCorrelation:
    """Tests for compute_confidence_correlation function."""

    def test_perfect_positive_correlation(self):
        """Test perfect positive correlation."""
        conf1 = [0.5, 0.6, 0.7, 0.8]
        conf2 = [0.5, 0.6, 0.7, 0.8]

        correlation = compute_confidence_correlation(conf1, conf2)
        assert correlation == pytest.approx(1.0)

    def test_zero_variance_returns_none(self):
        """Test that zero variance returns None."""
        conf1 = [0.5, 0.5, 0.5]
        conf2 = [0.6, 0.7, 0.8]

        correlation = compute_confidence_correlation(conf1, conf2)
        assert correlation is None

    def test_mismatched_lengths_returns_none(self):
        """Test that mismatched lengths return None."""
        conf1 = [0.5, 0.6]
        conf2 = [0.5, 0.6, 0.7]

        correlation = compute_confidence_correlation(conf1, conf2)
        assert correlation is None


class TestQualityEvaluation:
    """Tests for QualityEvaluation dataclass."""

    def test_property_accessors(
        self,
        sample_evaluation: QualityEvaluation,
    ):
        """Test property accessors for assessment fields."""
        assert sample_evaluation.study_design == StudyDesign.RCT
        assert sample_evaluation.quality_tier == QualityTier.TIER_3_CONTROLLED
        assert sample_evaluation.confidence == 0.85

    def test_to_dict(
        self,
        sample_evaluation: QualityEvaluation,
    ):
        """Test serialization to dictionary."""
        result = sample_evaluation.to_dict()

        assert result["document_id"] == "doc-001"
        assert result["study_design"] == "rct"
        assert result["quality_tier"] == 3
        assert result["confidence"] == 0.85
        assert result["latency_ms"] == 500.0


class TestComputeQualityEvaluatorStats:
    """Tests for compute_quality_evaluator_stats function."""

    def test_computes_stats(
        self,
        sample_evaluator: Evaluator,
        sample_evaluation: QualityEvaluation,
    ):
        """Test computing evaluator statistics."""
        evaluations = [sample_evaluation, sample_evaluation]

        stats = compute_quality_evaluator_stats(sample_evaluator, evaluations)

        assert stats.evaluator == sample_evaluator
        assert stats.total_evaluations == 2
        assert stats.mean_confidence == 0.85
        assert stats.mean_latency_ms == 500.0
        assert stats.total_tokens_input == 400
        assert stats.total_tokens_output == 200
        assert stats.total_cost_usd == 0.002
        assert stats.design_distribution == {"rct": 2}
        assert stats.tier_distribution == {3: 2}

    def test_empty_evaluations(
        self,
        sample_evaluator: Evaluator,
    ):
        """Test with empty evaluations list."""
        stats = compute_quality_evaluator_stats(sample_evaluator, [])

        assert stats.total_evaluations == 0
        assert stats.mean_confidence == 0.0
        assert stats.design_distribution == {}
