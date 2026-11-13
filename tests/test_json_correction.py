"""A reply JSON does not define is unreadable, and its retry asks again differently (#761).

``NaN``, ``Infinity`` and a number past binary64 make the whole reply
unreadable (bmlib#572): no field beside them, no span around them and no
prose score is read instead. The retry after an unreadable reply carries
bmlib's ``JSON_CORRECTION_NOTE`` rather than re-sending the identical request
(bmlib#717), so even a temperature-0 retry can answer differently.
"""

import json
from pathlib import Path
from typing import Any

import pytest
from bmlib.agents import JSON_CORRECTION_NOTE

from bmlibrarian_lite.agents.base import with_json_correction
from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent, parse_score_response
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import DocumentSource, EvaluationErrorCode, LiteDocument
from bmlibrarian_lite.exceptions import JSONParseError
from bmlibrarian_lite.llm import LLMMessage, LLMResponse
from bmlibrarian_lite.quality.data_models import StudyDesign
from bmlibrarian_lite.quality.quality_agent import LiteQualityAgent
from bmlibrarian_lite.quality.study_classifier import LiteStudyClassifier
from bmlibrarian_lite.utils import json_correction_due, llm_retry

CONTRACT = (
    Path(__file__).resolve().parent.parent
    / "doc" / "cross_platform" / "llm_parity" / "json_correction.json"
)
QUESTION = "Does aspirin prevent stroke?"
REFUSED = ["NaN", "Infinity", "-Infinity", "1e999", "1" + "0" * 400]


def make_document() -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id="doc-1", title="Aspirin trial", abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"], year=2024, journal="Journal", pmid="1", source=DocumentSource.EUROPEPMC,
    )


def recording(*contents: str | Exception) -> Any:
    """A ``_chat_response`` double answering in turn and keeping each request's turns."""

    def chat_response(messages: list[LLMMessage], *_args: Any, **_kwargs: Any) -> LLMResponse:
        chat_response.sent.append(list(messages))  # type: ignore[attr-defined]
        answer = contents[len(chat_response.sent) - 1]  # type: ignore[attr-defined]
        if isinstance(answer, Exception):
            raise answer
        return LLMResponse(content=answer, model="m", stop_reason="end_turn")

    chat_response.sent = []  # type: ignore[attr-defined]
    return chat_response


@pytest.fixture
def without_retry_delays(monkeypatch: pytest.MonkeyPatch) -> None:
    """Spend any retries without waiting out their backoff."""
    monkeypatch.setattr("tenacity.nap.time.sleep", lambda _seconds: None)


def test_the_note_is_the_contracts_and_bmlibs() -> None:
    """The apps hold the same words through the shared fixture."""
    assert json.loads(CONTRACT.read_text(encoding="utf-8"))["note"] == JSON_CORRECTION_NOTE


class TestRefusedValues:
    """A value JSON does not define makes the reply unreadable as a whole."""

    @pytest.mark.parametrize("value", REFUSED)
    def test_a_score_beside_a_refused_value_is_no_score(self, value: str) -> None:
        """The fields beside it are not read."""
        assert parse_score_response(f'{{"score": 4, "confidence": {value}}}') is None

    def test_no_prose_score_is_read_around_a_refused_value(self) -> None:
        """The desktop's prose fallback is not asked once the object was refused."""
        assert parse_score_response('Score: 4/5 {"score": 4, "confidence": NaN}') is None

    def test_a_syntax_error_still_reaches_the_prose_fallback(self) -> None:
        """Control: only a refusal skips it."""
        assert parse_score_response('Score: 4/5 {"score": 4,, }') is not None

    @pytest.mark.parametrize("value", REFUSED)
    def test_no_passages_are_read_around_a_refused_value(self, value: str) -> None:
        """Neither the whole reply nor the brace span inside it."""
        agent = LiteCitationAgent()
        reply = f'Here: {{"passages": [{{"text": "Aspirin reduced stroke.", "score": {value}}}]}}'

        assert agent._parse_citation_response(reply) is None

    def test_no_object_is_read_out_of_a_refused_array(self) -> None:
        """The brace span would be readable on its own; the reply around it was refused."""
        agent = LiteCitationAgent()
        reply = '[{"passages": [{"text": "Aspirin reduced stroke."}]}, NaN]'

        assert agent._parse_citation_response(reply) is None

    def test_passages_beside_a_finite_number_are_read(self) -> None:
        """Control: the same reply with a number JSON defines."""
        agent = LiteCitationAgent()
        reply = 'Here: {"passages": [{"text": "Aspirin reduced stroke.", "score": 1e300}]}'

        assert agent._parse_citation_response(reply)

    @pytest.mark.parametrize("value", REFUSED)
    def test_a_quality_assessment_beside_a_refused_value_is_unreadable(self, value: str) -> None:
        """Raised as a parse failure, which the retry then corrects."""
        reply = f'{{"study_design": "randomized_controlled_trial", "confidence": {value}}}'

        with pytest.raises(JSONParseError):
            LiteQualityAgent(config=LiteConfig())._parse_response(reply)

    @pytest.mark.parametrize("value", REFUSED)
    def test_a_classification_beside_a_refused_value_is_unknown(self, value: str) -> None:
        """Never the design the fields beside it name."""
        reply = f'{{"study_design": "randomized_controlled_trial", "confidence": {value}}}'

        result = LiteStudyClassifier(config=LiteConfig())._parse_response(reply)

        assert result.study_design == StudyDesign.UNKNOWN


class TestTheCorrectedRetry:
    """The attempts after an unreadable reply carry the note; nothing else does."""

    def test_the_retry_after_an_unreadable_reply_carries_the_note(
        self, without_retry_delays: None
    ) -> None:
        """Appended to the last user turn, and kept on every later attempt."""
        agent = LiteScoringAgent()
        chat = recording('{"score": 4, "confidence": NaN}', "no score here", '{"score": 3}')
        agent._chat_response = chat  # type: ignore[method-assign]

        scored = agent.score_document(QUESTION, make_document())

        assert scored.score == 3
        first, second, third = (sent[-1].content for sent in chat.sent)
        assert JSON_CORRECTION_NOTE not in first
        assert second == f"{first}\n\n{JSON_CORRECTION_NOTE}"
        assert third == second
        assert [m.role for m in chat.sent[1]] == [m.role for m in chat.sent[0]]

    def test_a_retry_after_a_network_failure_asks_the_same(
        self, without_retry_delays: None
    ) -> None:
        """Control: only an unreadable reply adds the note."""
        agent = LiteScoringAgent()
        chat = recording(ConnectionError("down"), '{"score": 3}')
        agent._chat_response = chat  # type: ignore[method-assign]

        assert agent.score_document(QUESTION, make_document()).score == 3
        assert chat.sent[0] == chat.sent[1]

    def test_the_next_document_starts_uncorrected(self, without_retry_delays: None) -> None:
        """The note belongs to one call, not to the agent or the thread."""
        agent = LiteScoringAgent()
        chat = recording("unreadable", '{"score": 3}', '{"score": 2}')
        agent._chat_response = chat  # type: ignore[method-assign]

        agent.score_document(QUESTION, make_document())
        agent.score_document(QUESTION, make_document())

        assert JSON_CORRECTION_NOTE not in chat.sent[2][-1].content
        assert json_correction_due() is False

    def test_an_exhausted_retry_is_still_a_parse_failure(self, without_retry_delays: None) -> None:
        """The note changes the request, not how a failure is recorded."""
        agent = LiteScoringAgent()
        chat = recording(*["{\"score\": NaN}"] * 4)
        agent._chat_response = chat  # type: ignore[method-assign]

        scored = agent.score_document(QUESTION, make_document())

        assert scored.score == EvaluationErrorCode.JSON_PARSE_ERROR.value
        assert len(chat.sent) == 4

    def test_a_nested_call_starts_uncorrected(self, without_retry_delays: None) -> None:
        """An inner request was never answered unreadably, so it is asked as written."""
        seen: list[bool] = []

        @llm_retry(max_retries=1)
        def inner() -> None:
            seen.append(json_correction_due())

        @llm_retry(max_retries=1, retry_on_json_error=True)
        def outer() -> None:
            inner()
            if len(seen) == 1:
                raise JSONParseError("unreadable")
            seen.append(json_correction_due())

        outer()

        assert seen == [False, False, True]


class TestWithJsonCorrection:
    """The turns sent: the note on the last user turn, or a turn of its own."""

    def test_the_last_user_turn_gains_the_note(self) -> None:
        """After a blank line; the turns given are not changed."""
        messages = [LLMMessage(role="system", content="sys"), LLMMessage(role="user", content="task")]

        sent = with_json_correction(messages)

        assert sent == [messages[0], LLMMessage(role="user", content=f"task\n\n{JSON_CORRECTION_NOTE}")]
        assert messages[1].content == "task"

    def test_a_last_turn_not_the_users_gains_a_user_turn(self) -> None:
        """The note is never folded into the model's own turn."""
        messages = [LLMMessage(role="assistant", content="a")]

        assert with_json_correction(messages) == [
            messages[0], LLMMessage(role="user", content=JSON_CORRECTION_NOTE)
        ]
