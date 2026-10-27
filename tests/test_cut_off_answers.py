"""An answer the model stopped at its token limit is never read as a whole one (#631).

The paths whose answer code reads (scoring, citations, the benchmarks) record
it as its own cause, asked once: asked again with the same limit, it is
likely cut off again, each time paid. The prose paths (the report, the
summaries, a document answer) keep what the model wrote and say it stopped.
"""

from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.agents.base import CUT_OFF_PROSE_NOTE, LiteBaseAgent
from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.agents.interrogation_agent import LiteInterrogationAgent
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.analysis_failures import advice_for_causes
from bmlibrarian_lite.data_models import (
    Citation,
    DocumentSource,
    EvaluationErrorCode,
    LiteChunk,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.exceptions import TruncatedResponseError
from bmlibrarian_lite.gui.report_tab import ReportTab
from bmlibrarian_lite.llm import LLMMessage, LLMResponse
from bmlibrarian_lite.llm.data_types import STOP_REASON_MAX_TOKENS

QUESTION = "Does aspirin prevent stroke?"
MESSAGES = [LLMMessage(role="user", content="q")]


def answers(*responses: LLMResponse) -> Any:
    """A ``_chat_response`` double answering each call with the next response, counting calls."""

    def chat_response(*_args: Any, **_kwargs: Any) -> LLMResponse:
        chat_response.calls += 1  # type: ignore[attr-defined]
        assert chat_response.calls <= len(responses), "More calls than scripted"  # type: ignore[attr-defined]
        return responses[chat_response.calls - 1]  # type: ignore[attr-defined]

    chat_response.calls = 0  # type: ignore[attr-defined]
    return chat_response


def cut_off(content: str) -> LLMResponse:
    """An answer stopped at its token limit."""
    return LLMResponse(content=content, model="m", output_tokens=1024, stop_reason=STOP_REASON_MAX_TOKENS)


def finished(content: str) -> LLMResponse:
    """An answer the model ended itself."""
    return LLMResponse(content=content, model="m", stop_reason="end_turn")


def make_document() -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id="doc-1", title="Aspirin trial", abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"], year=2024, journal="Journal", pmid="1", source=DocumentSource.EUROPEPMC,
    )


@pytest.fixture
def without_retry_delays(monkeypatch: pytest.MonkeyPatch) -> None:
    """Spend any retries without waiting out their backoff."""
    monkeypatch.setattr("tenacity.nap.time.sleep", lambda _seconds: None)


class TestTheBaseAgent:
    """``_chat`` refuses a cut-off answer; ``_chat_prose`` keeps it, marked."""

    @pytest.mark.parametrize("stop_reason", ["end_turn", "stop", None])
    def test_a_finished_answer_is_returned_as_written(self, stop_reason: str | None) -> None:
        """Only the token limit counts as cut off."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        response = LLMResponse(content="text", stop_reason=stop_reason)
        agent._chat_response = answers(response, response)  # type: ignore[method-assign]

        assert agent._chat(MESSAGES) == "text"
        assert agent._chat_prose(MESSAGES) == "text"

    def test_chat_refuses_a_cut_off_answer(self) -> None:
        """Half a JSON object never reaches a parser."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off('{"score": '))  # type: ignore[method-assign]

        with pytest.raises(TruncatedResponseError, match="token limit"):
            agent._chat(MESSAGES)

    def test_chat_prose_keeps_a_cut_off_answer_and_says_so(self) -> None:
        """What the model wrote is kept, and the note follows it."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off("Aspirin reduced"))  # type: ignore[method-assign]

        assert agent._chat_prose(MESSAGES) == f"Aspirin reduced\n\n{CUT_OFF_PROSE_NOTE}"

    @pytest.mark.parametrize("content", ["", "  \n", "<think>\nThe user asks about aspirin, so"])
    def test_a_cut_off_answer_with_no_prose_is_refused(self, content: str) -> None:
        """Nothing written, or only reasoning never closed, is not a report with a note."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off(content))  # type: ignore[method-assign]

        with pytest.raises(TruncatedResponseError, match="token limit"):
            agent._chat_prose(MESSAGES)

    def test_unclosed_reasoning_after_the_prose_is_dropped(self) -> None:
        """The provider strips a closed block only; an open one is not the answer."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off("Aspirin reduced stroke.\n<thinking>Now the next"))  # type: ignore[method-assign]

        assert agent._chat_prose(MESSAGES) == f"Aspirin reduced stroke.\n\n{CUT_OFF_PROSE_NOTE}"

    def test_a_cut_off_code_block_is_closed_before_the_note(self) -> None:
        """Otherwise the note and everything after it render as code."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off("Doses:\n```\n75 mg"))  # type: ignore[method-assign]

        assert agent._chat_prose(MESSAGES) == f"Doses:\n```\n75 mg\n```\n\n{CUT_OFF_PROSE_NOTE}"

    def test_a_cut_off_greeting_still_proves_a_connection(self) -> None:
        """The connection test asks for ten tokens; the limit is expected."""
        agent = LiteBaseAgent.__new__(LiteBaseAgent)
        agent._chat_response = answers(cut_off("Hello, how"))  # type: ignore[method-assign]

        assert agent.test_connection() is True


class TestTheJsonPaths:
    """A cut-off answer is its own cause, asked once, never "unreadable"."""

    def test_scoring_records_a_cut_off_and_asks_once(self, without_retry_delays: None) -> None:
        """The retry decorator retries unreadable answers; this one is not retried."""
        agent = LiteScoringAgent()
        chat = answers(cut_off('{"score": 4, "explanation": "On'))
        agent._chat_response = chat  # type: ignore[method-assign]

        scored = agent.score_document(QUESTION, make_document())

        assert scored.score == EvaluationErrorCode.RESPONSE_TOO_LARGE.value
        assert chat.calls == 1

    def test_citations_record_a_cut_off_and_ask_once(self, without_retry_delays: None) -> None:
        """The same, one stage later."""
        agent = LiteCitationAgent()
        chat = answers(cut_off('{"passages": [{"text": "Aspirin'))
        agent._chat_response = chat  # type: ignore[method-assign]
        scored = ScoredDocument(document=make_document(), score=4, explanation="On topic.")

        outcome = agent.extract_all_citations(QUESTION, [scored], min_score=3)

        assert outcome.causes == (EvaluationErrorCode.RESPONSE_TOO_LARGE,)
        assert chat.calls == 1

    def test_the_advice_is_not_the_unreadable_advice(self) -> None:
        """A cut-off answer was readable as far as it went; it ran out of room.

        No setting raises the scoring or citation limit (#633), so the advice
        names what the reader can change: the model.
        """
        advice = advice_for_causes([EvaluationErrorCode.RESPONSE_TOO_LARGE])

        assert advice == (
            "A model that writes out its reasoning first can use up the "
            "length limit: another model may finish within it."
        )

    def test_the_advice_comes_last_of_the_model_sentences(self) -> None:
        """Each sentence once, in the documented order, whatever order the causes came in."""
        advice = advice_for_causes([
            EvaluationErrorCode.RESPONSE_TOO_LARGE,
            EvaluationErrorCode.JSON_PARSE_ERROR,
            EvaluationErrorCode.API_TIMEOUT,
        ])

        assert advice.index("reachable") < advice.index("could not be read") < advice.index("length limit")


class TestTheReport:
    """A report cut off mid-sentence is never shown as complete."""

    def test_the_note_follows_the_body_before_the_references(self) -> None:
        """The reader learns the synthesis stopped before reading its sources."""
        agent = LiteReportingAgent()
        agent._chat_response = answers(cut_off("Aspirin reduced stroke in"))  # type: ignore[method-assign]
        citation = Citation(document=make_document(), passage="Aspirin reduced stroke.", relevance_score=4)

        report = agent.generate_report(QUESTION, [citation])

        assert report.index("Aspirin reduced stroke in") < report.index(CUT_OFF_PROSE_NOTE)
        assert report.index(CUT_OFF_PROSE_NOTE) < report.index("## References")


class TestDocumentInterrogation:
    """A document answer is prose; its query expansion keeps what it can."""

    @staticmethod
    def agent_with(response: LLMResponse) -> LiteInterrogationAgent:
        """An agent with one loaded chunk, answering with ``response``."""
        agent = LiteInterrogationAgent.__new__(LiteInterrogationAgent)
        agent._current_document_id = "d"
        agent._embedder = object()  # type: ignore[assignment]
        agent.storage = MagicMock()
        chunk = LiteChunk(id="d_0", document_id="d", text="Aspirin reduced stroke.", chunk_index=0, start_char=0, end_char=23)
        agent.storage.search_chunks.return_value = [(chunk, 0.1)]
        agent._chat_response = answers(response)  # type: ignore[method-assign]
        return agent

    def test_a_cut_off_answer_is_shown_with_the_note(self) -> None:
        """Not raised at the reader: what the model wrote is still read."""
        agent = self.agent_with(cut_off("Aspirin reduced"))

        answer, _ = agent.ask(QUESTION, use_query_expansion=False)

        assert answer == f"Aspirin reduced\n\n{CUT_OFF_PROSE_NOTE}"

    def test_a_cut_off_expansion_keeps_its_complete_lines(self) -> None:
        """The last line may stop mid-query; the ones before it are whole."""
        agent = self.agent_with(cut_off("Aspirin and stroke risk\nAntiplatelet therapy in stroke\nAcetylsal"))

        assert agent._expand_query(QUESTION) == [
            QUESTION, "Aspirin and stroke risk", "Antiplatelet therapy in stroke",
        ]

    def test_a_cut_off_expansion_still_reasoning_adds_nothing(self) -> None:
        """Reasoning lines are not search queries."""
        agent = self.agent_with(cut_off("<think>\nThe user wants\nalternatives for"))

        assert agent._expand_query(QUESTION) == [QUESTION]


class TestTheReportTab:
    """The note survives the tab's citation links."""

    def test_a_link_cut_off_mid_id_does_not_swallow_the_note(self) -> None:
        """An unclosed ``(docid:`` once matched up to the first year's ``)``."""
        tab = SimpleNamespace(_citations_by_doc_id={}, _find_document_by_citation=lambda _text: None)
        report = (
            f"Aspirin lowered risk [Smith et al., 2021](docid:pmid-1234\n\n{CUT_OFF_PROSE_NOTE}"
            "\n\n## References\n\n1. Smith J (2021). Title."
        )

        html = ReportTab._make_citations_clickable(tab, report)  # type: ignore[arg-type]

        assert "stopped at its length limit" in html
        assert "References</h2>" in html
