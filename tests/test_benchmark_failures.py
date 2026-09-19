# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A benchmark failure is not a score of 1 (#306).

``BenchmarkRunner`` recorded a scoring call that raised as a score of 1, with
the raw exception as the model's explanation, and its own parser turned an
unreadable answer -- or one with no ``score`` in it -- into a 1 as well. So an
outage became a confident "not relevant": a model whose provider was flaky
looked like a harsh judge, the agreement matrix compared error codes and
missing scores (recorded as 0) as though they were judgements, and cross-run
reuse replayed a stored failure into every later benchmark of the question.

The review path already records a failure as a negative
:class:`EvaluationErrorCode` (#262); these tests hold the benchmark to the
same rule, and follow it into the statistics.
"""

import json
from collections.abc import Callable
from typing import Any

import pytest

from bmlibrarian_lite.agents.scoring_agent import parse_score_response
from bmlibrarian_lite.audit_records import (
    as_recorded_failure,
    is_scoring_failure,
    scoring_failure_sql,
)
from bmlibrarian_lite.benchmarking.display import (
    FAILED_SCORE_TEXT,
    NOT_AVAILABLE,
    NOT_RECORDED,
    agreement_background,
    cost_ranking,
    documents_left_to_score,
    failed_count_text,
    failed_scorings_sentence,
    failures_note,
    format_agreement,
    format_statistic,
    mean_score_ranking,
    reusable_documents_by_model,
    score_cell,
)
from bmlibrarian_lite.benchmarking.models import (
    BenchmarkResult,
    DocumentComparison,
    EvaluatorStats,
)
from bmlibrarian_lite.benchmarking.runner import BenchmarkRunner
from bmlibrarian_lite.benchmarking.statistics import (
    compute_agreement,
    compute_agreement_matrix,
    compute_document_comparison,
    compute_evaluator_stats,
    compute_inclusion_agreement,
)
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import BENCHMARK_AGREEMENT_MEDIUM
from bmlibrarian_lite.data_models import (
    BenchmarkStatus,
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.exceptions import APIError, RetryExhaustedError
from bmlibrarian_lite.llm import LLMResponse
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Does aspirin prevent stroke?"
MODEL = "ollama:judge"
OTHER_MODEL = "ollama:second-judge"
ON_TOPIC = '{"score": 4, "explanation": "On topic."}'
#: What provider error text looks like on the path this runner calls: it
#: prints the request, and a request can carry a credential (#196).
LEAKY_ERROR = "Connection refused: http://localhost:11434/api/chat?key=SECRET"


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin reduced stroke incidence.",
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


def judged(document: LiteDocument, score: int, evaluator: Evaluator) -> ScoredDocument:
    """A document the evaluator read and scored."""
    return ScoredDocument(
        document=document,
        score=score,
        explanation="Read and judged.",
        evaluator_id=evaluator.id,
        evaluator=evaluator,
    )


def failure(
    document: LiteDocument,
    evaluator: Evaluator,
    code: EvaluationErrorCode = EvaluationErrorCode.API_CONNECTION_ERROR,
) -> ScoredDocument:
    """A document the evaluator could not score."""
    return ScoredDocument(
        document=document,
        score=code.value,
        explanation=f"Scoring failed: {code.description}",
        evaluator_id=evaluator.id,
        evaluator=evaluator,
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


def runner_with(storage: LiteStorage, client: ScriptedClient) -> BenchmarkRunner:
    """A runner calling the scripted client."""
    runner = BenchmarkRunner(config=storage.config, storage=storage)
    runner._llm_client = client
    return runner


def score_once(client: ScriptedClient) -> ScoredDocument:
    """Score one document with one evaluator through the runner."""
    runner = BenchmarkRunner(config=LiteConfig(), storage=object())
    runner._llm_client = client
    return runner._score_document(
        document=make_document("1"), question=QUESTION, evaluator=make_evaluator()
    )


class TestTheAnswerIsReadOnce:
    """The runner and the review read an answer the same way."""

    def test_a_well_formed_answer_is_its_score(self) -> None:
        """The ordinary case."""
        assert parse_score_response(ON_TOPIC) == (4, "On topic.")

    def test_an_answer_without_a_score_is_unreadable(self) -> None:
        """The runner defaulted a missing score to 1: a verdict nobody gave."""
        assert parse_score_response('{"explanation": "Hmm."}') is None

    def test_an_answer_that_is_not_one_is_unreadable(self) -> None:
        """The runner turned this into "Could not parse response" with a 1."""
        assert parse_score_response("I cannot help with that.") is None

    def test_a_score_stated_in_prose_is_read(self) -> None:
        """The text fallback both parsers had."""
        assert parse_score_response("Score: 2 -- tangential.") == (
            2,
            "Score: 2 -- tangential.",
        )

    def test_a_structured_explanation_is_kept_as_text(self) -> None:
        """The runner's parser could not read a nested object at all."""
        score, explanation = parse_score_response(
            '{"score": 5, "explanation": {"summary": "Direct evidence."}}'
        ) or (None, "")

        assert score == 5
        assert "Direct evidence." in explanation


class TestAFailureIsRecordedAsOne:
    """A call that did not produce a score records why, never a score."""

    def test_a_provider_failure_is_its_error_code(self) -> None:
        """Recorded as 1, an outage read as a confident "not relevant"."""
        scored = score_once(ScriptedClient(ConnectionError(LEAKY_ERROR)))

        assert scored.score == EvaluationErrorCode.API_CONNECTION_ERROR.value

    def test_the_provider_error_text_is_not_the_explanation(self) -> None:
        """The raw exception was stored and shown as the model's reasoning."""
        scored = score_once(ScriptedClient(ConnectionError(LEAKY_ERROR)))

        assert "SECRET" not in scored.explanation
        assert EvaluationErrorCode.API_CONNECTION_ERROR.description in scored.explanation

    def test_spent_retries_are_classified_by_what_they_were_spent_on(self) -> None:
        """The wrapper is not the cause (#301 review)."""
        refused = APIError("Unauthorized", status_code=401)
        scored = score_once(
            ScriptedClient(RetryExhaustedError("gave up", last_error=refused))
        )

        assert scored.score == EvaluationErrorCode.API_AUTH_ERROR.value

    def test_an_unreadable_answer_is_a_parse_failure(self) -> None:
        """Defaulted to 1, the model's garbled answer read as a judgement."""
        scored = score_once(ScriptedClient("I cannot help with that."))

        assert scored.score == EvaluationErrorCode.JSON_PARSE_ERROR.value

    def test_an_unreadable_answer_still_costs_what_it_cost(self) -> None:
        """The call was made and billed; only its answer was unusable."""
        scored = score_once(ScriptedClient("I cannot help with that."))

        assert (scored.tokens_input, scored.tokens_output) == (100, 20)

    def test_the_failure_names_its_evaluator(self) -> None:
        """Stored beside the evaluator's scores, it must say whose it is."""
        scored = score_once(ScriptedClient(TimeoutError("slow")))

        assert scored.evaluator_id == make_evaluator().id


class TestAnOlderFailureIsRecognised:
    """Rows written as a 1 by older builds are failures, not judgements."""

    @pytest.mark.parametrize(
        "explanation",
        [f"Scoring failed: {LEAKY_ERROR}", "Could not parse response"],
    )
    def test_the_forms_older_builds_wrote_are_failures(self, explanation: str) -> None:
        """Both the runner and, before 2025-12-23, the review wrote these."""
        row = ScoredDocument(document=make_document("1"), score=1, explanation=explanation)

        assert is_scoring_failure(row)

    def test_a_negative_score_is_a_failure(self) -> None:
        """The form every build since writes."""
        assert is_scoring_failure(failure(make_document("1"), make_evaluator()))

    def test_a_judged_one_is_a_judgement(self) -> None:
        """The model may well answer 1, and say why."""
        row = judged(make_document("1"), 1, make_evaluator())

        assert not is_scoring_failure(row)

    def test_an_older_failure_is_read_as_one_it_cannot_name(self) -> None:
        """#315: restored as it stands, it was a rejection giving provider text."""
        row = ScoredDocument(
            document=make_document("1"), score=1, explanation=f"Scoring failed: {LEAKY_ERROR}"
        )

        read = as_recorded_failure(row)

        assert read.score == EvaluationErrorCode.UNKNOWN_ERROR.value
        assert "SECRET" not in read.explanation

    def test_anything_else_is_read_as_it_stands(self) -> None:
        """A judgement, and a failure already stored as one, are unchanged."""
        judged_one = judged(make_document("1"), 1, make_evaluator())
        stored_failure = failure(make_document("2"), make_evaluator())

        assert as_recorded_failure(judged_one) is judged_one
        assert as_recorded_failure(stored_failure) is stored_failure

    def test_the_prefix_alone_does_not_make_a_higher_score_a_failure(self) -> None:
        """Only a 1 was ever written with it."""
        row = ScoredDocument(
            document=make_document("1"), score=2, explanation="Scoring failed: x"
        )

        assert not is_scoring_failure(row)


class TestEvaluatorStatistics:
    """A failure is counted apart from the scores, never among them."""

    def stats(self, *scores: int) -> EvaluatorStats:
        """An evaluator's statistics over documents given these scores."""
        evaluator = make_evaluator()
        rows = [
            judged(make_document(str(i)), s, evaluator)
            if s > 0
            else failure(make_document(str(i)), evaluator, EvaluationErrorCode(s))
            for i, s in enumerate(scores)
        ]
        return compute_evaluator_stats(evaluator, rows)

    def test_the_mean_is_of_judgements_only(self) -> None:
        """As a 1, one outage pulled a model's mean down by a third here."""
        stats = self.stats(4, 2, EvaluationErrorCode.API_TIMEOUT.value)

        assert stats.mean_score == 3.0
        assert stats.scores == [4, 2]

    def test_failures_are_counted(self) -> None:
        """Dropped silently, a model that answered half the time looks fine."""
        stats = self.stats(4, EvaluationErrorCode.API_TIMEOUT.value)

        assert stats.failed_evaluations == 1
        assert stats.total_evaluations == 1

    def test_the_distribution_holds_judgements_only(self) -> None:
        """An outage is not a vote for 1."""
        stats = self.stats(4, EvaluationErrorCode.API_TIMEOUT.value)

        assert stats.score_distribution == {1: 0, 2: 0, 3: 0, 4: 1, 5: 0}

    def test_an_evaluator_that_judged_nothing_has_no_mean(self) -> None:
        """A mean of 0.0 -- or of 1.0, as before -- would rank it."""
        stats = self.stats(EvaluationErrorCode.API_TIMEOUT.value)

        assert stats.mean_score is None
        assert stats.std_dev is None

    def test_failed_calls_still_count_towards_cost(self) -> None:
        """A parse failure was billed; the cost is what was spent."""
        evaluator = make_evaluator()
        row = failure(make_document("1"), evaluator, EvaluationErrorCode.JSON_PARSE_ERROR)
        row.cost_usd = 0.25
        stats = compute_evaluator_stats(evaluator, [row])

        assert stats.total_cost_usd == 0.25

    def test_the_count_survives_being_stored(self) -> None:
        """The summary is what a later session reads back."""
        stats = self.stats(4, EvaluationErrorCode.API_TIMEOUT.value)

        assert stats.to_dict()["failed_evaluations"] == 1


class TestAgreement:
    """Only documents both evaluators judged can agree or disagree."""

    def test_a_failure_is_not_compared(self) -> None:
        """-4 against 3 was counted as a disagreement of seven points."""
        assert compute_agreement([4, None, 2], [4, 3, 2]) == 1.0

    def test_nothing_in_common_is_no_agreement_figure(self) -> None:
        """Empty lists "agreed perfectly": two outages scored 100%."""
        assert compute_agreement([None, 4], [3, None]) is None

    def test_inclusion_agreement_skips_failures_too(self) -> None:
        """A failure below the threshold read as a decision to exclude."""
        assert compute_inclusion_agreement([4, None], [5, 1]) == 1.0

    def test_the_matrix_carries_no_figure_where_none_exists(self) -> None:
        """The pair that shared no judged document states nothing."""
        matrix = compute_agreement_matrix({"a": [4, None], "b": [None, 2]})

        assert matrix[("a", "b")] is None


class TestDocumentComparison:
    """A document's comparison holds the judgements and names the failures."""

    def comparison(self) -> DocumentComparison:
        """A document one evaluator judged and another could not score."""
        document = make_document("1")
        return compute_document_comparison(
            document=document,
            scored_by_evaluator={
                "first": judged(document, 4, make_evaluator()),
                "second": failure(document, make_evaluator(OTHER_MODEL)),
            },
        )

    def test_a_failure_is_not_among_the_scores(self) -> None:
        """It made the document's "max difference" 8."""
        comparison = self.comparison()

        assert comparison.scores == {"first": 4}
        assert comparison.max_score_difference is None

    def test_a_failure_is_not_an_inclusion_disagreement(self) -> None:
        """A negative score read as a vote to exclude."""
        assert not self.comparison().has_inclusion_disagreement(3)

    def test_the_failure_is_named(self) -> None:
        """Dropped silently, the column would read as a model never asked."""
        assert self.comparison().failures == {
            "second": EvaluationErrorCode.API_CONNECTION_ERROR.description
        }

    def test_the_failure_survives_being_stored(self) -> None:
        """The summary is what a later session reads back."""
        assert self.comparison().to_dict()["failures"] == {
            "second": EvaluationErrorCode.API_CONNECTION_ERROR.description
        }


class TestAStoredFailureIsNotReused:
    """A failure is retried by the next benchmark, never replayed into it."""

    def completed_run_with(self, storage: LiteStorage, row: ScoredDocument) -> None:
        """A finished benchmark of the question that stored this row."""
        assert row.evaluator is not None
        storage.upsert_evaluator(row.evaluator)
        storage.upsert_document(row.document)
        run = storage.create_benchmark_run(
            name="Earlier",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_ids=[row.evaluator.id],
            document_ids=[row.document.id],
        )
        storage.update_benchmark_run(run.id, status=BenchmarkStatus.COMPLETED)
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        storage.save_scored_document(row, checkpoint.id)

    @pytest.mark.parametrize(
        "make_row",
        [
            lambda d, e: failure(d, e),
            lambda d, e: ScoredDocument(
                d, 1, f"Scoring failed: {LEAKY_ERROR}", evaluator_id=e.id, evaluator=e
            ),
            lambda d, e: ScoredDocument(
                d, 1, "Could not parse response", evaluator_id=e.id, evaluator=e
            ),
        ],
        ids=["error-code", "older-exception", "older-unparsed"],
    )
    def test_across_runs(
        self,
        storage: LiteStorage,
        make_row: Callable[[LiteDocument, Evaluator], ScoredDocument],
    ) -> None:
        """Reused, one outage stood as the model's verdict in every rerun."""
        document = make_document("1")
        self.completed_run_with(storage, make_row(document, make_evaluator()))
        client = ScriptedClient(ON_TOPIC)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=[document], models=[MODEL]
        )

        assert client.calls == [MODEL]
        assert result.evaluator_stats[0].scores == [4]

    def test_a_judgement_is_still_reused(self, storage: LiteStorage) -> None:
        """What reuse is for: a score the model already gave costs nothing."""
        document = make_document("1")
        self.completed_run_with(storage, judged(document, 2, make_evaluator()))
        client = ScriptedClient(ON_TOPIC)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=[document], models=[MODEL]
        )

        assert client.calls == []
        assert result.evaluator_stats[0].scores == [2]

    def test_within_the_run(self, storage: LiteStorage) -> None:
        """The checkpoint's own earlier attempt is not its answer either."""
        document = make_document("1")
        evaluator = make_evaluator()
        storage.upsert_evaluator(evaluator)
        storage.upsert_document(document)
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        storage.save_scored_document(failure(document, evaluator), checkpoint.id)
        client = ScriptedClient(ON_TOPIC)

        runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[document],
            models=[MODEL],
            checkpoint_id=checkpoint.id,
            reuse_cross_run=False,
        )

        assert client.calls == [MODEL]

    def test_from_the_review(self, storage: LiteStorage) -> None:
        """The review's own scores are reused for its model, but not a failure."""
        document = make_document("1")
        baseline = storage.config.models.get_model_string("document_scoring")
        client = ScriptedClient(ON_TOPIC)

        runner_with(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[document],
            models=[baseline],
            existing_scores=[failure(document, make_evaluator(baseline))],
            reuse_cross_run=False,
        )

        assert client.calls == [baseline]


class TestTheResultsSayWhatFailed:
    """The finished benchmark counts its failures and reads them back."""

    def test_a_run_with_an_outage_counts_it(self, storage: LiteStorage) -> None:
        """The first model answered; the second's provider was down."""
        documents = [make_document("1"), make_document("2")]
        client = ScriptedClient(
            ON_TOPIC, ON_TOPIC, ConnectionError(LEAKY_ERROR)
        )

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=documents, models=[MODEL, OTHER_MODEL]
        )

        first, second = result.evaluator_stats
        assert (first.total_evaluations, first.failed_evaluations) == (2, 0)
        assert (second.total_evaluations, second.failed_evaluations) == (0, 2)
        assert second.mean_score is None
        assert result.agreement_matrix[
            (first.evaluator.display_name, second.evaluator.display_name)
        ] is None

    def test_the_counts_are_read_back(self, storage: LiteStorage) -> None:
        """A later session shows the stored summary, not a recomputation."""
        documents = [make_document("1")]
        client = ScriptedClient(ON_TOPIC, ConnectionError(LEAKY_ERROR))
        runner = runner_with(storage, client)
        result = runner.run_quick_benchmark(
            question=QUESTION, documents=documents, models=[MODEL, OTHER_MODEL]
        )

        stored = runner.get_benchmark_result(result.run_id)

        assert stored is not None
        assert [s.failed_evaluations for s in stored.evaluator_stats] == [0, 1]
        assert stored.document_comparisons[0].failures == {
            stored.evaluator_stats[1].evaluator.display_name: (
                EvaluationErrorCode.API_CONNECTION_ERROR.description
            )
        }
        assert stored.failures_recorded

    def test_an_older_summary_says_it_cannot_tell(self, storage: LiteStorage) -> None:
        """Written before failures were told apart, its 1s may be outages.

        Read as "0 failed", it would vouch for every one of them.
        """
        runner = runner_with(storage, ScriptedClient(ON_TOPIC))
        result = runner.run_quick_benchmark(
            question=QUESTION, documents=[make_document("1")], models=[MODEL]
        )
        summary = json.loads(result.to_json())
        for stats in summary["evaluator_stats"]:
            del stats["failed_evaluations"]
        for comparison in summary["document_comparisons"]:
            del comparison["failures"]
        storage.update_benchmark_run(result.run_id, results_summary=json.dumps(summary))

        older = runner.get_benchmark_result(result.run_id)

        assert older is not None
        assert not older.failures_recorded
        assert older.evaluator_stats[0].failed_evaluations is None

    def test_a_result_built_in_this_build_records_its_failures(self) -> None:
        """Every stats entry the runner builds states its count, zero or not."""
        result = BenchmarkResult(
            run_id="new",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_stats=[
                compute_evaluator_stats(
                    make_evaluator(), [judged(make_document("1"), 4, make_evaluator())]
                )
            ],
            document_comparisons=[],
            agreement_matrix={},
        )

        assert result.failures_recorded


class TestWhatTheResultsTabShows:
    """The tab states a missing figure as missing, never as a number."""

    def result_with_an_outage(self) -> BenchmarkResult:
        """One evaluator judged the document; the other could not score it."""
        document = make_document("1")
        answered, down = make_evaluator(), make_evaluator(OTHER_MODEL)
        first = judged(document, 4, answered)
        second = failure(document, down)
        return BenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_stats=[
                compute_evaluator_stats(answered, [first]),
                compute_evaluator_stats(down, [second]),
            ],
            document_comparisons=[
                compute_document_comparison(
                    document,
                    {answered.display_name: first, down.display_name: second},
                )
            ],
            agreement_matrix={(answered.display_name, down.display_name): None},
        )

    def test_a_missing_mean_is_not_a_number(self) -> None:
        """Formatting None crashed the tab; 0.00 would rank the evaluator."""
        assert format_statistic(None) == NOT_AVAILABLE
        assert format_statistic(3.0) == "3.00"

    def test_a_missing_agreement_is_not_a_percentage(self) -> None:
        """Shown as 0%, two evaluators that shared nothing "disagreed"."""
        assert format_agreement(None) == NOT_AVAILABLE
        assert format_agreement(0.9) == "90%"

    def test_a_missing_agreement_has_no_colour(self) -> None:
        """Coloured as low agreement, it would still read as a finding."""
        assert agreement_background(None, 0.9, 0.75, "#low") is None
        assert agreement_background(0.8, 0.9, 0.75, "#low") == BENCHMARK_AGREEMENT_MEDIUM

    def test_a_failed_cell_says_so_and_why(self) -> None:
        """Shown as "-", the evaluator looked as though it was never asked."""
        result = self.result_with_an_outage()
        comparison = result.document_comparisons[0]
        down = result.evaluator_stats[1].evaluator.display_name

        assert score_cell(comparison, down) == (
            FAILED_SCORE_TEXT,
            EvaluationErrorCode.API_CONNECTION_ERROR.description,
        )

    def test_a_judged_cell_is_its_score(self) -> None:
        """The ordinary case."""
        result = self.result_with_an_outage()
        comparison = result.document_comparisons[0]
        answered = result.evaluator_stats[0].evaluator.display_name

        assert score_cell(comparison, answered) == ("4", None)

    def test_an_evaluator_that_judged_nothing_is_ranked_last_without_a_mean(
        self,
    ) -> None:
        """Sorting a None mean crashed the tab."""
        result = self.result_with_an_outage()

        assert mean_score_ranking(result).endswith(f"({NOT_AVAILABLE})")

    def test_cost_is_ranked_per_judgement(self) -> None:
        """Dividing by no judgements crashed the tab; "$0/eval" would lie."""
        result = self.result_with_an_outage()
        down = result.evaluator_stats[1].evaluator.display_name

        ranking = cost_ranking(result.evaluator_stats)

        assert down not in ranking.split(", ")[0]
        assert f"{down} ({NOT_AVAILABLE})" in ranking

    def test_the_failed_count_is_shown(self) -> None:
        """A model that could not answer is visible without opening each row."""
        result = self.result_with_an_outage()

        assert [failed_count_text(s) for s in result.evaluator_stats] == ["0", "1"]

    def test_a_count_nobody_kept_is_not_zero(self) -> None:
        """Shown as 0 for an older result, it would vouch for its 1s."""
        stats = self.result_with_an_outage().evaluator_stats[0]
        stats.failed_evaluations = None

        assert failed_count_text(stats) == NOT_RECORDED

    def test_an_older_result_carries_a_note(self) -> None:
        """Its 1s cannot be told apart from outages, and the reader is told."""
        result = self.result_with_an_outage()
        assert failures_note(result) is None

        result.evaluator_stats[0].failed_evaluations = None

        note = failures_note(result)
        assert note is not None and "score of 1" in note


class TestOnlyComparableDocumentsAreCompared:
    """A document fewer than two models judged has no disagreement figure."""

    def comparison(self, *scores: int) -> DocumentComparison:
        """A document the given scores -- negative for a failure -- were given."""
        document = make_document("1")
        rows = {}
        for i, score in enumerate(scores):
            evaluator = make_evaluator(f"ollama:judge-{i}")
            rows[f"judge-{i}"] = (
                judged(document, score, evaluator)
                if score > 0
                else failure(document, evaluator)
            )
        return compute_document_comparison(document, rows)

    def result(self, *comparisons: DocumentComparison) -> BenchmarkResult:
        """A result over these comparisons."""
        return BenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_stats=[],
            document_comparisons=list(comparisons),
            agreement_matrix={},
        )

    def test_one_judgement_has_no_spread(self) -> None:
        """Its "Max Diff" read 0: full agreement, with nothing to agree with."""
        comparison = self.comparison(4, -4)

        assert comparison.max_score_difference is None
        assert not comparison.has_disagreement

    def test_no_comparable_document_is_no_rate(self) -> None:
        """"0.0% disagreement" under a matrix that says n/a (review)."""
        result = self.result(self.comparison(4, -4), self.comparison(2, -4))

        assert result.disagreement_rate is None
        assert result.inclusion_disagreement_rate is None
        assert result.to_dict()["inclusion_disagreement_rate"] is None

    def test_the_rate_is_over_comparable_documents(self) -> None:
        """Documents only one model judged diluted the rate."""
        result = self.result(
            self.comparison(5, 2), self.comparison(4, 4), self.comparison(4, -4)
        )

        assert result.disagreement_rate == 0.5
        assert result.inclusion_disagreement_rate == 0.5

    def test_high_disagreement_skips_what_was_not_compared(self) -> None:
        """Comparing a missing spread with the threshold raised a TypeError."""
        from bmlibrarian_lite.benchmarking.statistics import (
            find_high_disagreement_documents,
        )

        wide = self.comparison(5, 1)

        assert find_high_disagreement_documents([wide, self.comparison(4, -4)]) == [wide]

    def test_a_model_that_judged_nothing_agrees_with_nobody(self) -> None:
        """The diagonal was 100% even for a model that scored no document."""
        matrix = compute_agreement_matrix({"down": [None, None], "up": [4, 3]})

        assert matrix[("down", "down")] is None
        assert matrix[("up", "up")] == 1.0

    def test_a_model_that_judged_nothing_has_no_latency(self) -> None:
        """"0ms" read as the fastest model of all."""
        evaluator = make_evaluator()
        stats = compute_evaluator_stats(
            evaluator, [failure(make_document("1"), evaluator)]
        )

        assert stats.mean_latency_ms is None


class TestAStoredResultIsReadBackTruthfully:
    """What a later session shows of a stored benchmark."""

    def stored(self, storage: LiteStorage) -> tuple[BenchmarkRunner, str]:
        """A benchmark of one document by two models, the second down."""
        runner = runner_with(storage, ScriptedClient(ON_TOPIC, ConnectionError(LEAKY_ERROR)))
        result = runner.run_quick_benchmark(
            question=QUESTION, documents=[make_document("1")], models=[MODEL, OTHER_MODEL]
        )
        return runner, result.run_id

    def test_the_distribution_survives_being_stored(self, storage: LiteStorage) -> None:
        """Its keys came back as strings, so every loaded result showed 0 (0%)."""
        runner, run_id = self.stored(storage)

        stored = runner.get_benchmark_result(run_id)

        assert stored is not None
        assert stored.evaluator_stats[0].score_distribution[4] == 1

    def test_an_older_failure_is_read_as_one(self, storage: LiteStorage) -> None:
        """Stored before #306 as a 1 with the raw exception.

        The details and the export then showed it as the model's reasoning.
        """
        runner, run_id = self.stored(storage)
        run = storage.get_benchmark_run(run_id)
        summary = json.loads(run.results_summary)
        down = summary["evaluator_stats"][1]["evaluator_display_name"]
        comparison = summary["document_comparisons"][0]
        comparison["scores"][down] = 1
        comparison["explanations"][down] = f"Scoring failed: {LEAKY_ERROR}"
        del comparison["failures"]
        storage.update_benchmark_run(run_id, results_summary=json.dumps(summary))

        stored = runner.get_benchmark_result(run_id)

        assert stored is not None
        [read] = stored.document_comparisons
        assert down not in read.scores
        assert down in read.failures
        assert "SECRET" not in json.dumps(read.to_dict())

    def test_a_score_for_another_question_is_not_reused(self, storage: LiteStorage) -> None:
        """One question's relevance judgement stood as another's (review).

        Cross-run reuse read every score the model ever gave the document.
        """
        document = make_document("1")
        runner_with(storage, ScriptedClient('{"score": 2, "explanation": "Off."}')).run_quick_benchmark(
            question="A different question", documents=[document], models=[MODEL]
        )
        client = ScriptedClient(ON_TOPIC)

        result = runner_with(storage, client).run_quick_benchmark(
            question=QUESTION, documents=[document], models=[MODEL]
        )

        assert client.calls == [MODEL]
        assert result.evaluator_stats[0].scores == [4]


class TestAnAnswerThatOverflows:
    """An unreadable answer is a parse failure, never the end of the run."""

    def test_an_infinite_score_is_unreadable(self) -> None:
        """Python's json accepts Infinity, and int() of it raised."""
        assert parse_score_response('{"score": Infinity, "explanation": "x"}') is None

    def test_it_is_recorded_as_a_failure(self) -> None:
        """Raised outside the try, it ended the whole benchmark."""
        scored = score_once(ScriptedClient('{"score": Infinity}'))

        assert scored.score == EvaluationErrorCode.JSON_PARSE_ERROR.value


class TestWhatTheRunSaysWhenItFinishes:
    """The completion message says when scorings failed."""

    def test_failures_are_named(self) -> None:
        """"Benchmark complete" alone hid a model that answered nothing."""
        evaluator = make_evaluator()
        result = BenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_stats=[
                compute_evaluator_stats(
                    evaluator,
                    [
                        judged(make_document("1"), 4, evaluator),
                        failure(make_document("2"), evaluator),
                    ],
                )
            ],
            document_comparisons=[],
            agreement_matrix={},
        )

        assert failed_scorings_sentence(result) == (
            "1 of 2 scorings failed (see the Failed column)"
        )

    def test_nothing_is_added_when_nothing_failed(self) -> None:
        """The ordinary case."""
        evaluator = make_evaluator()
        result = BenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type="document_scoring",
            evaluator_stats=[
                compute_evaluator_stats(evaluator, [judged(make_document("1"), 4, evaluator)])
            ],
            document_comparisons=[],
            agreement_matrix={},
        )

        assert failed_scorings_sentence(result) is None


class TestWhatCanBeReused:
    """The confirm dialog's estimate counts judgements, not earlier runs."""

    def test_a_failure_is_not_reusable(self, storage: LiteStorage) -> None:
        """A run that failed everywhere was promised as "$0.00 (reusing existing)"."""
        document = make_document("1")
        runner_with(storage, ScriptedClient(ConnectionError(LEAKY_ERROR))).run_quick_benchmark(
            question=QUESTION, documents=[document], models=[MODEL]
        )
        runner_with(storage, ScriptedClient(ON_TOPIC)).run_quick_benchmark(
            question=QUESTION, documents=[make_document("2")], models=[MODEL]
        )

        reusable = reusable_documents_by_model(
            storage.get_all_scores_for_question(QUESTION, ["doc-1", "doc-2"])
        )

        assert reusable == {MODEL: {"doc-2"}}


class TestHowManyDocumentsAreLeftToScore:
    """The estimate's arithmetic."""

    def test_every_document_reusable_leaves_none(self) -> None:
        """The case that is actually free."""
        assert documents_left_to_score(10, 10, 10) == 0

    def test_all_documents_less_the_reusable(self) -> None:
        """Using every document, the reusable ones are exactly known."""
        assert documents_left_to_score(10, 10, 4) == 6

    def test_a_sample_expects_its_share(self) -> None:
        """Which documents a random sample draws is not known in advance."""
        assert documents_left_to_score(5, 10, 4) == 3


class TestTheSqlFormAgrees:
    """Scripts select stored failures in SQL; it must match the Python rule."""

    def test_it_selects_exactly_what_is_scoring_failure_does(
        self, storage: LiteStorage
    ) -> None:
        """A script that missed the older form re-ran none of those failures."""
        rows = [
            (-4, "Scoring failed: Failed to connect to API"),
            (1, f"Scoring failed: {LEAKY_ERROR}"),
            (1, "Could not parse response"),
            (1, "Off topic entirely."),
            (1, "Scoring failed_ but not really"),
            (1, "scoring failed: said the model, in lower case"),
            (2, "Scoring failed: x"),
            (4, "On topic."),
        ]
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        for i, (score, explanation) in enumerate(rows):
            document = make_document(str(i))
            storage.upsert_document(document)
            storage.save_scored_document(
                ScoredDocument(document, score, explanation), checkpoint.id
            )

        with storage._sqlite_connection() as conn:
            selected = {
                row["document_id"]
                for row in conn.execute(
                    f"SELECT sd.document_id FROM scored_documents sd "
                    f"WHERE {scoring_failure_sql('sd')}"
                )
            }

        expected = {
            f"doc-{i}"
            for i, (score, explanation) in enumerate(rows)
            if is_scoring_failure(ScoredDocument(make_document(str(i)), score, explanation))
        }
        assert selected == expected == {"doc-0", "doc-1", "doc-2"}
