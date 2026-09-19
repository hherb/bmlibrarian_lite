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

import dataclasses
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
    quality_benchmark_finished_text,
)
from bmlibrarian_lite.benchmarking.quality_models import (
    QUALITY_TASK_QUALITY_ASSESSMENT,
    QUALITY_TASK_STUDY_CLASSIFICATION,
    QualityBenchmarkResult,
    QualityDocumentComparison,
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
from bmlibrarian_lite.config import LiteConfig, TaskModelConfig
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
    llm_extraction_method,
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

    def test_an_unknown_design_is_refused(self) -> None:
        """No prompt offers it: it is how a failure was recorded (#314)."""
        with pytest.raises(ValueError):
            evaluated("doc-1", assessment(StudyDesign.UNKNOWN, QualityTier.UNCLASSIFIED))

    def test_a_failure_cannot_be_reused(self) -> None:
        """Only an answer is replayed from the review."""
        with pytest.raises(ValueError):
            QualityEvaluation(
                document_id="doc-1",
                evaluator=make_evaluator(),
                failure=EvaluationErrorCode.API_TIMEOUT,
                reused=True,
            )

    def test_the_rule_holds_after_construction(self) -> None:
        """Emptied afterwards, it would be neither an answer nor a failure."""
        evaluation = failed("doc-1")
        with pytest.raises(dataclasses.FrozenInstanceError):
            evaluation.failure = None  # type: ignore[misc]

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
        "answer, code",
        [
            ("", EvaluationErrorCode.EMPTY_RESPONSE),
            ("  \n", EvaluationErrorCode.EMPTY_RESPONSE),
            ("I think it is a trial.", EvaluationErrorCode.JSON_PARSE_ERROR),
            ('{"study_design": "rct",', EvaluationErrorCode.JSON_PARSE_ERROR),
            ("[]", EvaluationErrorCode.INVALID_RESPONSE_FORMAT),
            ("{}", EvaluationErrorCode.INVALID_RESPONSE_FORMAT),
            (json.dumps({"study_design": None}), EvaluationErrorCode.INVALID_RESPONSE_FORMAT),
            (json.dumps({"study_design": 3}), EvaluationErrorCode.INVALID_RESPONSE_FORMAT),
            (json.dumps({"study_design": "unknown"}), EvaluationErrorCode.INVALID_RESPONSE_FORMAT),
            (
                json.dumps({"study_design": "phase 2 umbrella trial"}),
                EvaluationErrorCode.INVALID_RESPONSE_FORMAT,
            ),
        ],
        ids=[
            "empty",
            "blank",
            "prose",
            "broken-json",
            "not-an-object",
            "no-design",
            "null-design",
            "number-design",
            "unknown",
            "off-the-list",
        ],
    )
    def test_an_answer_naming_no_design_is_a_failure_with_its_cause(
        self, answer: str, code: EvaluationErrorCode
    ) -> None:
        """Read as "unknown", an unreadable answer became the model's verdict.

        Well-formed JSON naming no design is not reported as unparseable.
        """
        evaluation = classify_once(ScriptedClient(answer))
        assert evaluation.failure is code

    def test_the_detailed_parser_refuses_the_same_answers(self) -> None:
        """Tier 3 reads the design by the same rule."""
        evaluation = assess_once(ScriptedClient(json.dumps({"study_design": "unknown"})))
        assert evaluation.failure is EvaluationErrorCode.INVALID_RESPONSE_FORMAT

    @pytest.mark.parametrize(
        "answer",
        [
            {"study_design": "rct", "design_characteristics": "yes"},
            {"study_design": "rct", "bias_risk": ["low"]},
        ],
        ids=["characteristics-not-an-object", "bias-risk-not-an-object"],
    )
    def test_a_malformed_field_is_that_document_s_failure(self, answer: dict[str, Any]) -> None:
        """A named design with a malformed field is a failure, not a crash."""
        evaluation = assess_once(ScriptedClient(json.dumps(answer)))
        assert evaluation.failure is EvaluationErrorCode.INVALID_RESPONSE_FORMAT

    def test_an_infinite_sample_size_is_no_sample_size(self) -> None:
        """JSON reads 1e999 as infinity, which int() cannot take."""
        evaluation = classify_once(
            ScriptedClient(json.dumps({"study_design": "rct", "sample_size": 1e999}))
        )
        assert evaluation.study_design is StudyDesign.RCT
        assert evaluation.assessment is not None
        assert evaluation.assessment.sample_size is None

    def test_a_nan_is_not_read_as_the_top_of_the_scale(self) -> None:
        """Clamped, NaN became full confidence and a perfect score."""
        answer = '{"study_design": "rct", "confidence": NaN, "quality_score": NaN}'
        evaluation = assess_once(ScriptedClient(answer))
        assert evaluation.assessment is not None
        assert evaluation.assessment.confidence != 1.0
        assert evaluation.assessment.quality_score == 0.0

    def test_an_answer_the_parser_did_not_foresee_does_not_end_the_run(
        self, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """One document's unreadable answer is its failure; the rest are read."""
        runner = runner_with(storage, ScriptedClient(RCT_ANSWER))
        parse = runner._parse_classification_response
        calls: list[str] = []

        def parse_once_badly(response: str) -> Any:
            """Raise what no parser foresees on the first answer only."""
            calls.append(response)
            if len(calls) == 1:
                raise KeyError("unforeseen")
            return parse(response)

        monkeypatch.setattr(runner, "_parse_classification_response", parse_once_badly)
        result = runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document("1"), make_document("2")],
            models=[MODEL],
        )

        [stats] = result.evaluator_stats
        assert (stats.total_evaluations, stats.failed_evaluations) == (1, 1)

    def test_an_unreadable_answer_still_costs_what_it_cost(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The call was made and billed."""
        from bmlibrarian_lite.benchmarking import quality_runner

        monkeypatch.setattr(quality_runner, "calculate_cost", lambda *_: 0.003)
        evaluation = classify_once(ScriptedClient("not json"))
        assert (evaluation.tokens_input, evaluation.tokens_output) == (100, 20)
        assert evaluation.cost_usd == 0.003

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
        assert is_reusable_assessment(RCT, QUALITY_TASK_STUDY_CLASSIFICATION, MODEL)

    def test_another_model_s_answer_is_not(self) -> None:
        """Credited to this model, another's answer fabricated its agreement."""
        assert not is_reusable_assessment(RCT, QUALITY_TASK_STUDY_CLASSIFICATION, OTHER_MODEL)

    def test_an_answer_naming_no_model_is_not(self) -> None:
        """Whose it was cannot be told."""
        anonymous = dataclasses.replace(RCT, extraction_method="llm")
        assert not is_reusable_assessment(anonymous, QUALITY_TASK_STUDY_CLASSIFICATION, MODEL)

    def test_a_human_evaluator_answers_for_no_review_assessment(self) -> None:
        """A human has no model string."""
        assert not is_reusable_assessment(RCT, QUALITY_TASK_STUDY_CLASSIFICATION, None)

    def test_a_transparency_downgrade_is_not_the_model_s_tier(self) -> None:
        """The review lowered the tier; the model did not answer it."""
        downgraded = dataclasses.replace(
            RCT,
            quality_tier=QualityTier.TIER_2_OBSERVATIONAL,
            original_quality_tier=QualityTier.TIER_4_EXPERIMENTAL,
            transparency_adjusted=True,
        )
        assert not is_reusable_assessment(downgraded, QUALITY_TASK_STUDY_CLASSIFICATION, MODEL)

    def test_the_review_classifier_failure_is_not(self) -> None:
        """The classifier records a failed call as an "unknown" design."""
        failure = QualityAssessment.from_classification(
            StudyClassification(study_design=StudyDesign.UNKNOWN, confidence=0.0),
            model_name=MODEL,
        )
        assert not is_reusable_assessment(failure, QUALITY_TASK_STUDY_CLASSIFICATION, MODEL)

    def test_the_review_assessor_failure_is_not(self) -> None:
        """The assessor records a failed call as "unclassified"."""
        assert not is_reusable_assessment(
            QualityAssessment.unclassified(), QUALITY_TASK_QUALITY_ASSESSMENT, MODEL
        )

    def test_a_design_from_publication_types_is_not(self) -> None:
        """PubMed's metadata is no model's answer."""
        from_metadata = assessment(StudyDesign.RCT, QualityTier.TIER_4_EXPERIMENTAL, tier_number=1)
        assert not is_reusable_assessment(
            from_metadata, QUALITY_TASK_STUDY_CLASSIFICATION, MODEL
        )

    def test_a_classification_does_not_answer_a_detailed_assessment(self) -> None:
        """A tier 2 answer is not the tier 3 task's."""
        assert not is_reusable_assessment(RCT, QUALITY_TASK_QUALITY_ASSESSMENT, MODEL)

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
            existing_assessments={
                document.id: dataclasses.replace(
                    COHORT, extraction_method=llm_extraction_method(baseline)
                )
            },
        )

        assert client.calls == []
        assert result.evaluator_stats[0].design_distribution == {"cohort_prospective": 1}
        assert result.evaluator_stats[0].reused_evaluations == 1

    def test_the_review_s_detailed_assessment_names_its_model(self) -> None:
        """Recorded as "llm_sonnet", it could be credited to no model -- or any."""
        from bmlibrarian_lite.quality.quality_agent import LiteQualityAgent

        config = LiteConfig()
        config.models.tasks["quality_assessment"] = TaskModelConfig(
            provider="ollama", model="assessor"
        )
        agent = LiteQualityAgent(config=config)

        answer = agent._parse_response(RCT_ANSWER)

        assert answer.extraction_method == llm_extraction_method("ollama:assessor")
        assert is_reusable_assessment(
            answer, QUALITY_TASK_QUALITY_ASSESSMENT, "ollama:assessor"
        )

    def test_the_quality_model_s_assessment_is_not_the_classifier_s(
        self, storage: LiteStorage
    ) -> None:
        """The detailed assessment's baseline is the model that made it."""
        document = make_document("1")
        models = storage.config.models
        models.tasks["study_classification"] = TaskModelConfig(provider="ollama", model="classifier")
        models.tasks["quality_assessment"] = TaskModelConfig(provider="ollama", model="assessor")
        classifier = models.get_model_string("study_classification")
        assessor = models.get_model_string("quality_assessment")
        by_assessor = dataclasses.replace(
            assessment(StudyDesign.RCT, QualityTier.TIER_4_EXPERIMENTAL, tier_number=3),
            extraction_method=llm_extraction_method(assessor),
        )
        client = ScriptedClient(COHORT_ANSWER)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[document],
            models=[classifier, assessor],
            task_type=QUALITY_TASK_QUALITY_ASSESSMENT,
            existing_assessments={document.id: by_assessor},
        )

        assert client.calls == [classifier]
        assert result.baseline_evaluator_name == make_evaluator(assessor).display_name


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

    def test_a_replayed_assessment_was_not_bought(self) -> None:
        """At $0 and 0ms, the review's answers made the baseline look cheap and fast."""
        replayed = QualityEvaluation(
            document_id="doc-4", evaluator=make_evaluator(), assessment=RCT, reused=True
        )
        stats = compute_quality_evaluator_stats(
            make_evaluator(), [*self.evaluations, replayed]
        )
        assert (stats.total_evaluations, stats.reused_evaluations) == (3, 1)
        assert stats.cost_per_evaluation == pytest.approx(0.02)
        assert stats.tokens_per_evaluation == pytest.approx(120.0)
        assert stats.mean_latency_ms == 400.0

    def test_an_evaluator_that_only_replayed_has_no_cost_figure(self) -> None:
        """It bought nothing in this run; $0.00 would rank it cheapest."""
        replayed = QualityEvaluation(
            document_id="doc-1", evaluator=make_evaluator(), assessment=RCT, reused=True
        )
        stats = compute_quality_evaluator_stats(make_evaluator(), [replayed])
        assert stats.cost_per_evaluation is None
        assert stats.mean_latency_ms is None

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

    def test_the_export_counts_the_failures(self, storage: LiteStorage) -> None:
        """The saved summary says how many failed and how many were replayed."""
        client = ScriptedClient(RCT_ANSWER, ConnectionError(LEAKY_ERROR))
        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document("1"), make_document("2")],
            models=[MODEL],
        )
        data = result.to_dict()
        assert data["failed_evaluations"] == 1
        [stats] = data["evaluator_stats"]
        assert (stats["failed_evaluations"], stats["reused_evaluations"]) == (1, 0)

    def test_the_status_line_names_the_failures(self, storage: LiteStorage) -> None:
        """Its cost alone read as success when every assessment had failed."""
        client = ScriptedClient(ConnectionError(LEAKY_ERROR))
        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=[make_document("1")], models=[MODEL]
        )
        assert quality_benchmark_finished_text(result) == (
            "Quality benchmark complete - 1 of 1 assessments failed - Total cost: $0.0000"
        )

    def test_a_clean_run_s_status_line_is_its_cost(self, storage: LiteStorage) -> None:
        """The control."""
        result = runner_with(storage, ScriptedClient(RCT_ANSWER)).run_quick_benchmark(
            question=QUESTION, documents=[make_document("1")], models=[MODEL]
        )
        assert quality_benchmark_finished_text(result) == (
            f"Quality benchmark complete - Total cost: ${result.total_cost_usd:.4f}"
        )

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

    def test_a_rate_s_denominator_leaves_out_what_was_not_compared(self) -> None:
        """One of two comparable documents disagrees: 50%, not a third."""
        disagreeing = compute_quality_document_comparison(
            make_document("2"),
            {"a": evaluated("doc-2", RCT), "b": evaluated("doc-2", CASE_REPORT)},
        )
        agreeing = compute_quality_document_comparison(
            make_document("3"),
            {"a": evaluated("doc-3", RCT), "b": evaluated("doc-3", RCT)},
        )
        result = QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[],
            document_comparisons=[self.comparison(), disagreeing, agreeing],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )
        assert result.design_disagreement_rate == 0.5
        assert result.tier_disagreement_rate == 0.5

    def test_an_evaluator_cannot_both_assess_and_fail(self) -> None:
        """The table showed the design; the dialog showed the failure."""
        with pytest.raises(ValueError):
            QualityDocumentComparison(
                document=make_document("1"),
                assessments={"a": RCT},
                designs={"a": RCT.study_design},
                tiers={"a": RCT.quality_tier},
                confidences={"a": RCT.confidence},
                failures={"a": EvaluationErrorCode.API_TIMEOUT.description},
            )

    def test_a_design_without_its_assessment_is_refused(self) -> None:
        """Counted as comparable by designs, it had no tier to compare."""
        with pytest.raises(ValueError):
            QualityDocumentComparison(
                document=make_document("1"),
                assessments={"a": RCT},
                designs={"a": RCT.study_design, "b": StudyDesign.RCT},
                tiers={"a": RCT.quality_tier},
                confidences={"a": RCT.confidence},
            )

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

    def ranked_with_figures(self) -> QualityBenchmarkResult:
        """Two models with figures, cheap-fast-unsure and dear-slow-sure, and one without."""
        cheap = compute_quality_evaluator_stats(
            make_evaluator(MODEL),
            [
                QualityEvaluation(
                    document_id="doc-1",
                    evaluator=make_evaluator(MODEL),
                    assessment=dataclasses.replace(RCT, confidence=0.4),
                    latency_ms=100.0,
                    cost_usd=0.01,
                )
            ],
        )
        dear = compute_quality_evaluator_stats(
            make_evaluator(OTHER_MODEL),
            [
                QualityEvaluation(
                    document_id="doc-1",
                    evaluator=make_evaluator(OTHER_MODEL),
                    assessment=dataclasses.replace(RCT, confidence=0.9),
                    latency_ms=900.0,
                    cost_usd=0.05,
                )
            ],
        )
        silent = compute_quality_evaluator_stats(
            make_evaluator("ollama:silent"), [failed("doc-1")]
        )
        return QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type=QUALITY_TASK_STUDY_CLASSIFICATION,
            evaluator_stats=[silent, dear, cheap],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
        )

    @pytest.mark.parametrize(
        "ranking, first",
        [
            ("get_ranking_by_cost", MODEL),
            ("get_ranking_by_speed", MODEL),
            ("get_ranking_by_confidence", OTHER_MODEL),
        ],
    )
    def test_the_best_figure_ranks_first(self, ranking: str, first: str) -> None:
        """Cheapest, fastest, and most confident first; no figure last."""
        ranked = getattr(self.ranked_with_figures(), ranking)()
        assert [e.model_string for e, _ in ranked] == [
            first,
            OTHER_MODEL if first == MODEL else MODEL,
            "ollama:silent",
        ]

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
