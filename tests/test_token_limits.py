"""Output limits leave room for Claude 5.5's answers and thinking (#821)."""

from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.benchmarking.runner import BenchmarkRunner
from bmlibrarian_lite.config import BenchmarkModelConfig, LiteConfig
from bmlibrarian_lite.constants import (
    QUALITY_ASSESSOR_MAX_TOKENS,
    QUALITY_CLASSIFIER_MAX_TOKENS,
    SMART_SEARCH_MAX_TOKENS,
)
from bmlibrarian_lite.data_models import Citation, Evaluator, LiteDocument
from bmlibrarian_lite.llm.data_types import LLMResponse
from bmlibrarian_lite.query_converter import LiteQueryConverter

# The longest answer measured on the desktop's own prompts, Haiku 5.5 or Sonnet 5.5
LONGEST_SCORE = 603
LONGEST_QUERY = 747
LONGEST_CITATIONS = 1190
LONGEST_ALTERNATIVE_QUERIES = 1764
LONGEST_QUALITY_ASSESSMENT = 1347
LONGEST_CLASSIFICATION = 431
LONGEST_BRIEF_SUMMARY = 1326
LONGEST_REPORT = 2675

# Thinking varies from run to run, so a limit the longest answer only just fits
# is no room: the old report (4096) and query (1000) limits fitted that narrowly
HEADROOM = 2


def has_room(limit: int, longest: int) -> bool:
    """A limit that holds twice the longest answer measured."""
    return limit >= HEADROOM * longest


@pytest.mark.parametrize(("task_id", "longest"), [
    ("document_scoring", LONGEST_SCORE),
    ("citation_extraction", LONGEST_CITATIONS),
])
def test_an_unconfigured_task_gets_room_for_its_longest_answer(task_id: str, longest: int) -> None:
    """Scoring and citations call ``_chat`` with no limit, so the task default is what they send."""
    assert has_room(LiteConfig().models.get_task_config(task_id).max_tokens, longest)


@pytest.mark.parametrize(("limit", "longest"), [
    (SMART_SEARCH_MAX_TOKENS, LONGEST_ALTERNATIVE_QUERIES),
    (QUALITY_ASSESSOR_MAX_TOKENS, LONGEST_QUALITY_ASSESSMENT),
    (QUALITY_CLASSIFIER_MAX_TOKENS, LONGEST_CLASSIFICATION),
    (BenchmarkModelConfig().max_tokens, LONGEST_SCORE),
    (BenchmarkModelConfig.from_dict({"provider": "anthropic", "model": "m"}).max_tokens, LONGEST_SCORE),
    (Evaluator.from_model_config("anthropic", "m").max_tokens, LONGEST_SCORE),
])
def test_a_named_limit_has_room_for_its_longest_answer(limit: int, longest: int) -> None:
    """The limits the calls pass themselves, and the benchmark's scoring defaults."""
    assert has_room(limit, longest)


def test_query_conversion_sends_room_for_its_longest_answer() -> None:
    """The converter passes its own limit, not the task's."""
    client = MagicMock()
    client.chat.return_value = LLMResponse(content='{"query": "x"}')

    LiteQueryConverter(llm_client=client, model="anthropic:m").convert("Does aspirin prevent stroke?")

    assert has_room(client.chat.call_args.kwargs["max_tokens"], LONGEST_QUERY)


def test_report_and_summary_send_room_for_their_longest_answers() -> None:
    """Both pass their own limit to ``_chat_prose``."""
    agent = LiteReportingAgent(config=LiteConfig())
    agent._chat_prose = MagicMock(return_value="Text.")  # type: ignore[method-assign]
    citation = Citation(
        document=LiteDocument(id="d1", title="T", abstract="A", authors=["Smith J"], year=2020),
        passage="P", relevance_score=4,
    )

    agent.generate_report("Q?", [citation])
    assert has_room(agent._chat_prose.call_args.kwargs["max_tokens"], LONGEST_REPORT)

    agent.generate_brief_summary("Q?", [citation])
    assert has_room(agent._chat_prose.call_args.kwargs["max_tokens"], LONGEST_BRIEF_SUMMARY)


def test_a_benchmark_run_scores_with_room_for_its_longest_answer() -> None:
    """``run_benchmark`` builds its evaluators with the runner's own default."""
    runner = BenchmarkRunner(config=LiteConfig(), storage=MagicMock())

    (evaluator,) = runner.create_evaluators_from_models(["anthropic:m"])

    assert has_room(evaluator.max_tokens, LONGEST_SCORE)


def test_an_evaluator_without_a_limit_scores_with_room_for_its_longest_answer() -> None:
    """A stored evaluator whose limit is NULL falls back to the scoring limit."""
    runner = BenchmarkRunner(config=LiteConfig(), storage=MagicMock())
    runner._llm_client = MagicMock()
    runner._llm_client.chat.return_value = LLMResponse(content='{"score": 4, "explanation": "On topic."}')
    evaluator = Evaluator.from_model_config("anthropic", "m")
    evaluator.max_tokens = None

    runner._score_document(
        document=LiteDocument(id="d1", title="T", abstract="A"), question="Q?", evaluator=evaluator
    )

    assert has_room(runner._llm_client.chat.call_args.kwargs["max_tokens"], LONGEST_SCORE)
