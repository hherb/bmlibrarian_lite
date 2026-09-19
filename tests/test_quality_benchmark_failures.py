# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A quality benchmark failure is not an "unclassified" study (#314).

``QualityBenchmarkRunner`` recorded a call that raised, and an answer it
could not read, as ``QualityAssessment.unclassified()`` -- the "unknown"
design a model gives when it reads the abstract and cannot tell. So an
outage became the model's verdict: counted in its design and tier
distributions, and compared as a disagreement ("unknown" against "RCT") on
every document the other model classified. The review's quality filter
records its own failures the same way, and those assessments were replayed
into the benchmark as the baseline model's answers.

The relevance benchmark was held to the rule in #306; these tests hold the
quality benchmark to it, from the runner to the tab's cells.
"""

import json
from typing import Any

import pytest

from bmlibrarian_lite.benchmarking.display import FAILED_SCORE_TEXT, NOT_AVAILABLE
from bmlibrarian_lite.benchmarking.quality_display import (
    NO_ASSESSMENT_TEXT,
    design_cell,
    design_distribution_cell,
    design_label,
    export_design_value,
    failed_assessments_sentence,
    format_tier_difference,
    matrix_value,
    quality_agreement_background,
)
from bmlibrarian_lite.benchmarking.quality_models import (
    QUALITY_TASK_QUALITY_ASSESSMENT,
    QUALITY_TASK_STUDY_CLASSIFICATION,
    QualityBenchmarkResult,
    QualityEvaluation,
)
from bmlibrarian_lite.benchmarking.quality_runner import (
    QualityBenchmarkRunner,
    is_reusable_assessment,
    parse_study_design,
)
from bmlibrarian_lite.benchmarking.quality_statistics import (
    compute_design_agreement,
    compute_design_agreement_matrix,
    compute_quality_document_comparison,
    compute_quality_evaluator_stats,
    compute_tier_agreement,
    find_tier_disagreement_documents,
)
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
)
from bmlibrarian_lite.exceptions import APIError, RetryExhaustedError
from bmlibrarian_lite.llm import LLMResponse
from bmlibrarian_lite.quality.data_models import (
    QualityAssessment,
    QualityTier,
    StudyClassification,
    StudyDesign,
)
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Does aspirin prevent stroke?"
MODEL = "ollama:classifier"
OTHER_MODEL = "ollama:second-classifier"
RCT_ANSWER = json.dumps({"study_design": "rct", "confidence": 0.9})
COHORT_ANSWER = json.dumps({"study_design": "cohort_prospective", "confidence": 0.7})
#: Provider error text prints the request, which can carry a credential.
LEAKY_ERROR = "Connection refused: http://localhost:11434/api/chat?key=SECRET"


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Patients were randomised to aspirin or placebo.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


def make_evaluator(model: str = MODEL) -> Evaluator:
    """The evaluator a model string names."""
    provider, name = model.split(":", 1)
    return Evaluator.from_model_config(provider=provider, model_name=name)


def assessment(design: StudyDesign, tier: QualityTier, tier_number: int = 2) -> QualityAssessment:
    """An assessment a model made."""
    return QualityAssessment(
        assessment_tier=tier_number,
        extraction_method=f"llm:{MODEL}",
        study_design=design,
        quality_tier=tier,
        quality_score=5.0,
        confidence=0.8,
    )


RCT = assessment(StudyDesign.RCT, QualityTier.TIER_4_EXPERIMENTAL)
COHORT = assessment(StudyDesign.COHORT_PROSPECTIVE, QualityTier.TIER_3_CONTROLLED)
CASE_REPORT = assessment(StudyDesign.CASE_REPORT, QualityTier.TIER_1_ANECDOTAL)


def evaluated(
    document_id: str,
    answer: QualityAssessment,
    evaluator: Evaluator | None = None,
    latency_ms: float = 400.0,
) -> QualityEvaluation:
    """A document the evaluator assessed."""
    return QualityEvaluation(
        document_id=document_id,
        evaluator=evaluator or make_evaluator(),
        assessment=answer,
        latency_ms=latency_ms,
        tokens_input=100,
        tokens_output=20,
        cost_usd=0.01,
    )


def failed(
    document_id: str,
    evaluator: Evaluator | None = None,
    code: EvaluationErrorCode = EvaluationErrorCode.API_CONNECTION_ERROR,
    latency_ms: float = 30000.0,
    cost_usd: float = 0.0,
) -> QualityEvaluation:
    """A document the evaluator could not assess."""
    return QualityEvaluation(
        document_id=document_id,
        evaluator=evaluator or make_evaluator(),
        failure=code,
        latency_ms=latency_ms,
        cost_usd=cost_usd,
    )


class ScriptedClient:
    """An LLM client answering each call from a script, recording the calls."""

    def __init__(self, *answers: "str | Exception") -> None:
        """Answer the calls in order; the last answer repeats.

        Args:
            answers: A response body to return, or an exception to raise.
        """
        self._answers = list(answers)
        self.calls: list[str] = []

    def chat(self, messages: Any, model: str, **_: Any) -> LLMResponse:
        """Answer one call.

        Args:
            messages: Ignored.
            model: The model the call is for.

        Returns:
            The scripted response, with token counts.

        Raises:
            Exception: When the script says this call fails.
        """
        self.calls.append(model)
        answer = self._answers[min(len(self.calls), len(self._answers)) - 1]
        if isinstance(answer, Exception):
            raise answer
        return LLMResponse(content=answer, input_tokens=100, output_tokens=20)


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def runner_with(storage: Any, client: ScriptedClient) -> QualityBenchmarkRunner:
    """A runner calling the scripted client."""
    config = storage.config if isinstance(storage, LiteStorage) else LiteConfig()
    runner = QualityBenchmarkRunner(config=config, storage=storage)
    runner._llm_client = client  # type: ignore[assignment]
    return runner


def classify_once(client: ScriptedClient) -> QualityEvaluation:
    """Classify one document with one evaluator through the runner."""
    runner = runner_with(object(), client)
    return runner._classify_document(document=make_document("1"), evaluator=make_evaluator())


def assess_once(client: ScriptedClient) -> QualityEvaluation:
    """Assess one document in detail with one evaluator through the runner."""
    runner = runner_with(object(), client)
    return runner._assess_document(document=make_document("1"), evaluator=make_evaluator())


class TestAnEvaluationIsAnAnswerOrAFailure:
    """The record cannot hold both, or neither."""

    def test_neither_is_refused(self) -> None:
        """An evaluation with nothing in it would read as neither."""
        with pytest.raises(ValueError):
            QualityEvaluation(document_id="doc-1", evaluator=make_evaluator())

    def test_both_are_refused(self) -> None:
        """An answer with a failure attached would be counted twice."""
        with pytest.raises(ValueError):
            QualityEvaluation(
                document_id="doc-1",
                evaluator=make_evaluator(),
                assessment=RCT,
                failure=EvaluationErrorCode.API_TIMEOUT,
            )

    def test_success_is_not_a_failure(self) -> None:
        """A failure recorded as SUCCESS would name no cause."""
        with pytest.raises(ValueError):
            QualityEvaluation(
                document_id="doc-1",
                evaluator=make_evaluator(),
                failure=EvaluationErrorCode.SUCCESS,
            )

    def test_a_failure_has_no_design(self) -> None:
        """Not "unknown": no answer at all."""
        evaluation = failed("doc-1")
        assert evaluation.is_failure
        assert (evaluation.study_design, evaluation.quality_tier, evaluation.confidence) == (
            None,
            None,
            None,
        )

    def test_a_failure_serialises_as_one(self) -> None:
        """The exported record names the failure, and no design."""
        data = failed("doc-1").to_dict()
        assert data["failure"] == "API_CONNECTION_ERROR"
        assert data["study_design"] is None

    def test_an_unclassified_tier_is_still_serialised(self) -> None:
        """Tier 0 is falsy: it must not be written as missing."""
        answer = assessment(StudyDesign.OTHER, QualityTier.UNCLASSIFIED)
        assert evaluated("doc-1", answer).to_dict()["quality_tier"] == QualityTier.UNCLASSIFIED.value


class TestAFailureIsRecordedAsOne:
    """What the runner records when the call or the answer fails."""

    def test_an_answer_is_its_design(self) -> None:
        """The control: a readable answer is the model's classification."""
        evaluation = classify_once(ScriptedClient(RCT_ANSWER))
        assert evaluation.study_design is StudyDesign.RCT
        assert evaluation.failure is None

    def test_a_provider_failure_is_its_error_code(self) -> None:
        """An outage is a failure, not the model's "unknown"."""
        evaluation = classify_once(ScriptedClient(ConnectionError(LEAKY_ERROR)))
        assert evaluation.failure is EvaluationErrorCode.API_CONNECTION_ERROR
        assert evaluation.assessment is None

    def test_spent_retries_are_classified_by_what_they_were_spent_on(self) -> None:
        """RETRY_EXHAUSTED is the one cause the user cannot act on."""
        exhausted = RetryExhaustedError(
            "retries spent", attempts=3, last_error=APIError("rate limited", status_code=429)
        )
        evaluation = classify_once(ScriptedClient(exhausted))
        assert evaluation.failure is EvaluationErrorCode.API_RATE_LIMIT

    def test_the_detailed_assessment_records_a_failure_too(self) -> None:
        """Tier 3 shares the path."""
        evaluation = assess_once(ScriptedClient(TimeoutError("timed out")))
        assert evaluation.failure is EvaluationErrorCode.API_TIMEOUT

    @pytest.mark.parametrize(
        "answer",
        [
            "",
            "I think it is a trial.",
            "[]",
            "{}",
            json.dumps({"study_design": None}),
            json.dumps({"study_design": 3}),
            json.dumps({"study_design": "unknown"}),
            json.dumps({"study_design": "phase 2 umbrella trial"}),
        ],
        ids=[
            "empty",
            "prose",
            "not-an-object",
            "no-design",
            "null-design",
            "number-design",
            "unknown",
            "off-the-list",
        ],
    )
    def test_an_answer_naming_no_design_is_a_parse_failure(self, answer: str) -> None:
        """Read as "unknown", an unreadable answer became the model's verdict."""
        evaluation = classify_once(ScriptedClient(answer))
        assert evaluation.failure is EvaluationErrorCode.JSON_PARSE_ERROR

    def test_the_detailed_parser_refuses_the_same_answers(self) -> None:
        """Tier 3 reads the design by the same rule."""
        evaluation = assess_once(ScriptedClient(json.dumps({"study_design": "unknown"})))
        assert evaluation.failure is EvaluationErrorCode.JSON_PARSE_ERROR

    def test_an_unreadable_answer_still_costs_what_it_cost(self) -> None:
        """The call was made and billed."""
        evaluation = classify_once(ScriptedClient("not json"))
        assert (evaluation.tokens_input, evaluation.tokens_output) == (100, 20)

    @pytest.mark.parametrize(
        "label, design",
        [
            ("RCT", StudyDesign.RCT),
            ("randomized controlled trial", StudyDesign.RCT),
            (" Cohort_Prospective ", StudyDesign.COHORT_PROSPECTIVE),
            ("other", StudyDesign.OTHER),
        ],
    )
    def test_a_design_on_the_list_is_read_however_it_is_written(
        self, label: str, design: StudyDesign
    ) -> None:
        """The recognised spellings still read."""
        assert parse_study_design({"study_design": label}) is design


class TestAReviewAssessmentIsReusedOnlyIfTheModelMadeIt:
    """The baseline model's review assessments stand in for its answers."""

    def test_a_classification_is_reused_for_classification(self) -> None:
        """What reuse is for."""
        assert is_reusable_assessment(RCT, QUALITY_TASK_STUDY_CLASSIFICATION)

    def test_the_review_classifier_failure_is_not(self) -> None:
        """The classifier records a failed call as an "unknown" design."""
        failure = QualityAssessment.from_classification(
            StudyClassification(study_design=StudyDesign.UNKNOWN, confidence=0.0),
            model_name=MODEL,
        )
        assert not is_reusable_assessment(failure, QUALITY_TASK_STUDY_CLASSIFICATION)

    def test_the_review_assessor_failure_is_not(self) -> None:
        """The assessor records a failed call as "unclassified"."""
        assert not is_reusable_assessment(
            QualityAssessment.unclassified(), QUALITY_TASK_QUALITY_ASSESSMENT
        )

    def test_a_design_from_publication_types_is_not(self) -> None:
        """PubMed's metadata is no model's answer."""
        from_metadata = assessment(StudyDesign.RCT, QualityTier.TIER_4_EXPERIMENTAL, tier_number=1)
        assert not is_reusable_assessment(from_metadata, QUALITY_TASK_STUDY_CLASSIFICATION)

    def test_a_classification_does_not_answer_a_detailed_assessment(self) -> None:
        """A tier 2 answer is not the tier 3 task's."""
        assert not is_reusable_assessment(RCT, QUALITY_TASK_QUALITY_ASSESSMENT)

    def test_the_runner_asks_again_rather_than_replay_a_failure(
        self, storage: LiteStorage
    ) -> None:
        """Replayed, the review's outage stood as the baseline's verdict."""
        document = make_document("1")
        baseline = storage.config.models.get_model_string("study_classification")
        client = ScriptedClient(RCT_ANSWER)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[document],
            models=[baseline],
            existing_assessments={document.id: QualityAssessment.unclassified()},
        )

        assert client.calls == [baseline]
        assert result.evaluator_stats[0].design_distribution == {"rct": 1}

    def test_the_runner_still_reuses_an_answer(self, storage: LiteStorage) -> None:
        """A classification the model already made costs nothing."""
        document = make_document("1")
        baseline = storage.config.models.get_model_string("study_classification")
        client = ScriptedClient(RCT_ANSWER)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[document],
            models=[baseline],
            existing_assessments={document.id: COHORT},
        )

        assert client.calls == []
        assert result.evaluator_stats[0].design_distribution == {"cohort_prospective": 1}


class TestEvaluatorStatistics:
    """A failure is counted apart from the assessments."""

    evaluations = [
        evaluated("doc-1", RCT),
        evaluated("doc-2", COHORT),
        failed("doc-3", cost_usd=0.02),
    ]

    def test_failures_are_counted(self) -> None:
        """One of three failed."""
        stats = compute_quality_evaluator_stats(make_evaluator(), self.evaluations)
        assert (stats.total_evaluations, stats.failed_evaluations) == (2, 1)

    def test_the_distributions_hold_assessments_only(self) -> None:
        """No "unknown" or tier 0 appears for the failure."""
        stats = compute_quality_evaluator_stats(make_evaluator(), self.evaluations)
        assert stats.design_distribution == {"rct": 1, "cohort_prospective": 1}
        assert QualityTier.UNCLASSIFIED.value not in stats.tier_distribution

    def test_the_latency_is_of_assessments_only(self) -> None:
        """A timed-out call does not say how fast the model answers."""
        stats = compute_quality_evaluator_stats(make_evaluator(), self.evaluations)
        assert stats.mean_latency_ms == 400.0

    def test_failed_calls_still_count_towards_cost(self) -> None:
        """What a failed call cost was still billed."""
        stats = compute_quality_evaluator_stats(make_evaluator(), self.evaluations)
        assert stats.total_cost_usd == pytest.approx(0.04)
        assert stats.cost_per_evaluation == pytest.approx(0.02)

    def test_an_evaluator_that_assessed_nothing_has_no_figures(self) -> None:
        """Not a confidence of 0, a latency of 30s, or a cost of $0.00."""
        stats = compute_quality_evaluator_stats(make_evaluator(), [failed("doc-1")])
        assert stats.mean_confidence is None
        assert stats.mean_latency_ms is None
        assert stats.cost_per_evaluation is None
        assert stats.tokens_per_evaluation is None


class TestAgreement:
    """Only documents both evaluators assessed are compared."""

    def test_a_failure_is_not_a_disagreement(self) -> None:
        """Compared as "unknown", an outage disagreed with every RCT."""
        assert compute_design_agreement(
            [StudyDesign.RCT, None], [StudyDesign.RCT, StudyDesign.RCT]
        ) == 1.0

    def test_nothing_in_common_is_no_figure(self) -> None:
        """Not 100%, which two outages scored before."""
        assert compute_design_agreement([None, StudyDesign.RCT], [StudyDesign.RCT, None]) is None

    def test_tier_agreement_skips_failures_too(self) -> None:
        """Tier 0 for a failure was up to four tiers from any answer."""
        assert compute_tier_agreement(
            [QualityTier.TIER_4_EXPERIMENTAL, None],
            [QualityTier.TIER_4_EXPERIMENTAL, QualityTier.TIER_4_EXPERIMENTAL],
        ) == 1.0

    def test_a_model_that_assessed_nothing_agrees_with_nobody(self) -> None:
        """Itself included: its diagonal is no figure either."""
        matrix = compute_design_agreement_matrix(
            {"a": [StudyDesign.RCT], "b": [None]}
        )
        assert matrix[("a", "a")] == 1.0
        assert matrix[("b", "b")] is None
        assert matrix[("a", "b")] is None

    def test_the_run_compares_assessed_documents(self, storage: LiteStorage) -> None:
        """The first model answered; the second's provider was down on one document."""
        documents = [make_document("1"), make_document("2")]
        client = ScriptedClient(
            RCT_ANSWER, RCT_ANSWER, RCT_ANSWER, ConnectionError(LEAKY_ERROR)
        )

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=documents, models=[MODEL, OTHER_MODEL]
        )

        first, second = (s.evaluator.display_name for s in result.evaluator_stats)
        assert result.design_agreement_matrix[(first, second)] == 1.0
        assert result.tier_agreement_matrix[(first, second)] == 1.0
        assert result.evaluator_stats[1].failed_evaluations == 1
        assert result.failed_evaluations == 1
        assert result.design_disagreement_rate == 0.0


class TestDocumentComparison:
    """A document one model could not assess."""

    def comparison(self) -> Any:
        """The first model says RCT; the second failed."""
        return compute_quality_document_comparison(
            make_document("1"),
            {"a": evaluated("doc-1", RCT), "b": failed("doc-1")},
        )

    def test_the_failure_is_not_among_the_designs(self) -> None:
        """No "unknown" for b."""
        comparison = self.comparison()
        assert comparison.designs == {"a": StudyDesign.RCT}
        assert "b" not in comparison.tiers

    def test_the_failure_is_named_without_provider_text(self) -> None:
        """Why, in the fixed description, never the provider's words."""
        reason = self.comparison().failures["b"]
        assert reason == EvaluationErrorCode.API_CONNECTION_ERROR.description
        assert "SECRET" not in json.dumps(self.comparison().to_dict())

    def test_one_assessment_is_not_a_disagreement(self) -> None:
        """Nor full agreement: there is no difference to measure."""
        comparison = self.comparison()
        assert not comparison.is_comparable
        assert not comparison.has_design_disagreement
        assert comparison.max_tier_difference is None
        assert not comparison.has_tier_disagreement

    def test_high_disagreement_skips_what_was_not_compared(self) -> None:
        """A document with one assessment has no tier difference to flag."""
        assert find_tier_disagreement_documents([self.comparison()], threshold=0) == []

    def test_a_rate_is_over_comparable_documents_only(self) -> None:
        """No comparable document is no rate, not 0%."""
        result = QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[],
            document_comparisons=[self.comparison()],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )
        assert result.design_disagreement_rate is None
        assert result.tier_disagreement_rate is None

    def test_a_disagreement_is_still_one(self) -> None:
        """The control: two assessments that differ disagree."""
        comparison = compute_quality_document_comparison(
            make_document("1"),
            {"a": evaluated("doc-1", RCT), "b": evaluated("doc-1", CASE_REPORT)},
        )
        assert comparison.has_design_disagreement
        assert comparison.max_tier_difference == 3


class TestRankings:
    """An evaluator with no figure is ranked last, never first."""

    def result(self) -> QualityBenchmarkResult:
        """One model answered; the other was billed and answered nothing."""
        answered = compute_quality_evaluator_stats(
            make_evaluator(MODEL), [evaluated("doc-1", RCT)]
        )
        silent = compute_quality_evaluator_stats(
            make_evaluator(OTHER_MODEL), [failed("doc-1", cost_usd=0.0)]
        )
        return QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[silent, answered],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )

    @pytest.mark.parametrize(
        "ranking", ["get_ranking_by_cost", "get_ranking_by_speed", "get_ranking_by_confidence"]
    )
    def test_a_model_that_assessed_nothing_comes_last(self, ranking: str) -> None:
        """As $0.00, 0ms or no confidence it ranked cheapest, fastest -- or crashed."""
        ranked = getattr(self.result(), ranking)()
        assert ranked[-1][1] is None
        assert ranked[0][0].model_string == MODEL


class TestWhatTheResultsTabShows:
    """The Quality Benchmark tab's cells."""

    def comparison(self) -> Any:
        """Model a says RCT, b failed, c was not asked."""
        return compute_quality_document_comparison(
            make_document("1"),
            {"a": evaluated("doc-1", RCT), "b": failed("doc-1")},
        )

    def test_a_failed_cell_says_so_and_why(self) -> None:
        """Not "Unknown", which is an answer."""
        text, tooltip = design_cell(self.comparison(), "b")
        assert text == FAILED_SCORE_TEXT
        assert tooltip == EvaluationErrorCode.API_CONNECTION_ERROR.description

    def test_an_assessed_cell_is_its_design(self) -> None:
        """The control."""
        text, tooltip = design_cell(self.comparison(), "a")
        assert (text, tooltip) == ("Randomized Controlled Trial", None)

    def test_a_cell_never_asked_is_empty(self) -> None:
        """Neither an answer nor a failure."""
        assert design_cell(self.comparison(), "c") == (NO_ASSESSMENT_TEXT, None)

    def test_the_export_writes_a_failure_as_one(self) -> None:
        """An empty cell read as "not asked"."""
        comparison = self.comparison()
        assert [export_design_value(comparison, n) for n in "abc"] == ["rct", "failed", ""]

    def test_a_missing_tier_difference_is_not_zero(self) -> None:
        """Shown as 0, one model's outage read as full agreement."""
        assert format_tier_difference(None) == NOT_AVAILABLE
        assert format_tier_difference(2) == "2"

    def test_a_model_that_assessed_nothing_has_no_distribution(self) -> None:
        """Not "0 (0%)" in every column."""
        stats = compute_quality_evaluator_stats(make_evaluator(), [failed("doc-1")])
        assert design_distribution_cell(stats, "rct") == NOT_AVAILABLE

    def test_a_distribution_cell_counts_assessments(self) -> None:
        """The control: the share is of what the model assessed."""
        stats = compute_quality_evaluator_stats(
            make_evaluator(), [evaluated("doc-1", RCT), failed("doc-2")]
        )
        assert design_distribution_cell(stats, "rct") == "1 (100%)"

    def test_a_missing_agreement_has_no_colour(self) -> None:
        """Coloured as low agreement, no figure still read as a finding."""
        assert quality_agreement_background(None, is_design=True) is None
        assert quality_agreement_background(1.0, is_design=False) is not None

    def test_a_missing_agreement_is_not_zero(self) -> None:
        """A pair with no figure is None in either order, never 0.0."""
        matrix: dict[tuple[str, str], float | None] = {("a", "b"): None, ("a", "c"): 0.5}
        assert matrix_value(matrix, "b", "a") is None
        assert matrix_value(matrix, "c", "a") == 0.5
        assert matrix_value(matrix, "x", "y") is None

    def test_the_failures_are_announced(self) -> None:
        """The header says how many assessments failed."""
        stats = compute_quality_evaluator_stats(
            make_evaluator(), [evaluated("doc-1", RCT), failed("doc-2")]
        )
        result = QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[stats],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )
        assert failed_assessments_sentence(result) == (
            "1 of 2 assessments failed (see the Failed column)"
        )

    def test_no_failure_is_not_announced(self) -> None:
        """Nothing to say."""
        stats = compute_quality_evaluator_stats(make_evaluator(), [evaluated("doc-1", RCT)])
        result = QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[stats],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )
        assert failed_assessments_sentence(result) is None

    def test_a_design_is_shown_by_its_label(self) -> None:
        """Looked up by value, the labels were never found."""
        assert design_label("case_report") == "Case Report"
        assert design_label("not-a-design") == "not-a-design"
