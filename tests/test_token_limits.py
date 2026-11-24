"""Output limits leave room for Claude 5.5's answers and thinking (#821)."""

from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
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


@pytest.mark.parametrize(("task_id", "longest"), [
    ("document_scoring", LONGEST_SCORE),
    ("citation_extraction", LONGEST_CITATIONS),
    ("query_conversion", LONGEST_QUERY),
    ("quality_assessment", LONGEST_QUALITY_ASSESSMENT),
    ("study_classification", LONGEST_CLASSIFICATION),
    ("report_generation", LONGEST_REPORT),
])
def test_an_unconfigured_task_gets_room_for_its_longest_answer(task_id: str, longest: int) -> None:
    """Scoring and citations call ``_chat`` with no limit, so the task default is what they send."""
    assert LiteConfig().models.get_task_config(task_id).max_tokens > longest


@pytest.mark.parametrize(("limit", "longest"), [
    (SMART_SEARCH_MAX_TOKENS, LONGEST_ALTERNATIVE_QUERIES),
    (QUALITY_ASSESSOR_MAX_TOKENS, LONGEST_QUALITY_ASSESSMENT),
    (QUALITY_CLASSIFIER_MAX_TOKENS, LONGEST_CLASSIFICATION),
    (BenchmarkModelConfig().max_tokens, LONGEST_SCORE),
    (Evaluator.from_model_config("anthropic", "m").max_tokens, LONGEST_SCORE),
])
def test_a_named_limit_has_room_for_its_longest_answer(limit: int, longest: int) -> None:
    """The limits the calls pass themselves, and the benchmark's scoring default."""
    assert limit > longest


def test_query_conversion_sends_room_for_its_longest_answer() -> None:
    """The converter passes its own limit, not the task's."""
    client = MagicMock()
    client.chat.return_value = LLMResponse(content='{"query": "x"}')

    LiteQueryConverter(llm_client=client, model="anthropic:m").convert("Does aspirin prevent stroke?")

    assert client.chat.call_args.kwargs["max_tokens"] > LONGEST_QUERY


def test_report_and_summary_send_room_for_their_longest_answers() -> None:
    """Both pass their own limit to ``_chat_prose``."""
    agent = LiteReportingAgent(config=LiteConfig())
    agent._chat_prose = MagicMock(return_value="Text.")  # type: ignore[method-assign]
    citation = Citation(
        document=LiteDocument(id="d1", title="T", abstract="A", authors=["Smith J"], year=2020),
        passage="P", relevance_score=4,
    )

    agent.generate_report("Q?", [citation])
    agent.generate_brief_summary("Q?", [citation])

    report, summary = (c.kwargs["max_tokens"] for c in agent._chat_prose.call_args_list)
    assert report > LONGEST_REPORT
    assert summary > LONGEST_BRIEF_SUMMARY
