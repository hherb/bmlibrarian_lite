# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The quality analyses read a whole abstract, window by window.

The maintainer's rule (2026-10-23): every text a model analyses is read in
sliding 16,000-character windows overlapping by 250, and the answers
reduced; never cut. The detailed assessment cut abstracts at 4,000
characters and the quality benchmark at 3,000 and 4,000; the classifier had
its own 4,000/500 splitter, which skipped a window it could not classify.
Now all three map over ``analysis_windows`` and reduce by one design vote,
and a window that fails fails the paper.
"""

import json
from typing import Any

import pytest

from bmlibrarian_lite.benchmarking.quality_runner import QualityBenchmarkRunner
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import DocumentSource, Evaluator, LiteDocument
from bmlibrarian_lite.llm import LLMResponse
from bmlibrarian_lite.quality.data_models import StudyClassification, StudyDesign
from bmlibrarian_lite.quality.quality_agent import LiteQualityAgent
from bmlibrarian_lite.quality.study_classifier import LiteStudyClassifier
from bmlibrarian_lite.quality.window_reduce import reduce_by_design_vote

RCT = json.dumps({"study_design": "rct", "is_randomized": True, "sample_size": 100,
                  "confidence": 0.8, "quality_score": 7})
COHORT = json.dumps({"study_design": "cohort_prospective", "sample_size": 300,
                     "confidence": 0.4, "quality_score": 5})
#: Two windows' worth: 20,000 characters of sentences
LONG_ABSTRACT = " ".join(f"Sentence {i:04d} of a long abstract." for i in range(700))
#: Longer than the old 4,000-character cut, within one window
MEDIUM_ABSTRACT = " ".join(f"Sentence {i:04d} of an abstract." for i in range(200)) + " LAST WORDS."


def make_document(abstract: str) -> LiteDocument:
    """A document with the given abstract."""
    return LiteDocument(id="doc-1", title="A trial", abstract=abstract, pmid="1",
                        source=DocumentSource.PUBMED)


class Chat:
    """Stands in for ``_chat``: answers from a script, records the prompts."""

    def __init__(self, *answers: "str | Exception") -> None:
        """Answer in order; the last answer repeats."""
        self.answers = list(answers)
        self.prompts: list[str] = []

    def __call__(self, messages: Any, **_: Any) -> str:
        """Answer one call."""
        self.prompts.append(messages[-1].content)
        answer = self.answers[min(len(self.prompts), len(self.answers)) - 1]
        if isinstance(answer, Exception):
            raise answer
        return answer


class TestTheVote:
    """One answer from every window's."""

    def test_a_single_window_is_its_own_answer(self) -> None:
        """Nothing to reduce; its confidence is not inflated to 1."""
        only = StudyClassification(StudyDesign.RCT, confidence=0.6)
        assert reduce_by_design_vote([only]) is only

    def test_agreeing_windows_keep_their_confidence(self) -> None:
        """Two windows saying RCT at 0.6 are 0.6, not 1.0 (the old share of the vote)."""
        answer = reduce_by_design_vote([
            StudyClassification(StudyDesign.RCT, confidence=0.6, sample_size=80),
            StudyClassification(StudyDesign.RCT, confidence=0.6, sample_size=120),
        ])
        assert (answer.study_design, answer.confidence, answer.sample_size) == (
            StudyDesign.RCT, 0.6, 120)

    def test_a_disagreeing_window_lowers_it(self) -> None:
        """The heavier design wins, with its support over every window."""
        answer = reduce_by_design_vote([
            StudyClassification(StudyDesign.RCT, confidence=0.8, is_randomized=True),
            StudyClassification(StudyDesign.COHORT_PROSPECTIVE, confidence=0.4),
        ])
        assert answer.study_design is StudyDesign.RCT
        assert answer.confidence == pytest.approx(0.4)
        assert answer.is_randomized is True

    def test_no_answers_are_no_vote(self) -> None:
        """A caller with nothing read has nothing to reduce."""
        with pytest.raises(ValueError):
            reduce_by_design_vote([])


class TestTheClassifier:
    """Its long-abstract path is the shared windows."""

    def test_a_long_abstract_is_classified_window_by_window(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Two windows, two calls, one vote."""
        classifier = LiteStudyClassifier(config=LiteConfig())
        chat = Chat(RCT, COHORT)
        monkeypatch.setattr(classifier, "_chat", chat)

        result = classifier.classify(make_document(LONG_ABSTRACT))

        assert len(chat.prompts) == 2
        assert "Section 1/2" in chat.prompts[0] and "Section 2/2" in chat.prompts[1]
        assert "Sentence 0699" in chat.prompts[1]
        assert result.study_design is StudyDesign.RCT
        assert result.sample_size == 300

    def test_a_window_it_cannot_classify_fails_the_paper(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Not a vote over the half that was read."""
        classifier = LiteStudyClassifier(config=LiteConfig())
        monkeypatch.setattr(classifier, "_chat", Chat(RCT, RuntimeError("down")))

        result = classifier.classify(make_document(LONG_ABSTRACT))

        assert (result.study_design, result.confidence) == (StudyDesign.UNKNOWN, 0.0)

    def test_an_abstract_within_a_window_is_one_call(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Up to 16,000 characters: as before the windows, whole."""
        classifier = LiteStudyClassifier(config=LiteConfig())
        chat = Chat(RCT)
        monkeypatch.setattr(classifier, "_chat", chat)

        classifier.classify(make_document(MEDIUM_ABSTRACT))

        assert len(chat.prompts) == 1 and "LAST WORDS." in chat.prompts[0]


class TestTheDetailedAssessment:
    """No longer cut at 4,000 characters."""

    def test_an_abstract_past_the_old_cut_is_read_to_its_end(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Its last words reached the model only since the windows."""
        agent = LiteQualityAgent(config=LiteConfig())
        chat = Chat(RCT)
        monkeypatch.setattr(agent, "_chat", chat)

        agent.assess_quality(make_document(MEDIUM_ABSTRACT))

        assert len(MEDIUM_ABSTRACT) > 4000
        assert len(chat.prompts) == 1 and "LAST WORDS." in chat.prompts[0]

    def test_a_long_abstract_is_assessed_window_by_window(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Two calls, one vote."""
        agent = LiteQualityAgent(config=LiteConfig())
        chat = Chat(RCT, COHORT)
        monkeypatch.setattr(agent, "_chat", chat)

        result = agent.assess_quality(make_document(LONG_ABSTRACT))

        assert len(chat.prompts) == 2 and "(section 2 of 2)" in chat.prompts[1]
        assert result.study_design is StudyDesign.RCT
        assert result.sample_size == 300

    def test_a_window_that_fails_fails_the_assessment(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The unclassified sentinel, never half an abstract's verdict."""
        agent = LiteQualityAgent(config=LiteConfig())
        answers = iter([agent._parse_response(RCT), RuntimeError("down")])

        def assess(_messages: Any) -> Any:
            answer = next(answers)
            if isinstance(answer, Exception):
                raise answer
            return answer

        monkeypatch.setattr(agent, "_assess_with_retry", assess)

        result = agent.assess_quality(make_document(LONG_ABSTRACT))

        assert result.study_design is StudyDesign.UNKNOWN
        assert result.confidence == 0.0


class ScriptedClient:
    """An LLM client answering from a script, recording the prompts."""

    def __init__(self, *answers: "str | Exception") -> None:
        """Answer in order; the last answer repeats."""
        self.answers = list(answers)
        self.prompts: list[str] = []

    def chat(self, messages: Any, model: str, **_: Any) -> LLMResponse:
        """Answer one call."""
        self.prompts.append(messages[-1].content)
        answer = self.answers[min(len(self.prompts), len(self.answers)) - 1]
        if isinstance(answer, Exception):
            raise answer
        return LLMResponse(content=answer, input_tokens=100, output_tokens=20)


def benchmark(client: ScriptedClient) -> QualityBenchmarkRunner:
    """A benchmark runner over the scripted client."""
    runner = QualityBenchmarkRunner(config=LiteConfig(), storage=object())  # type: ignore[arg-type]
    runner._llm_client = client  # type: ignore[assignment]
    return runner


EVALUATOR = Evaluator.from_model_config(provider="ollama", model_name="classifier")


class TestTheBenchmark:
    """The benchmark reads what the review reads."""

    @pytest.mark.parametrize("method", ["_classify_document", "_assess_document"])
    def test_an_abstract_past_the_old_cuts_is_read_to_its_end(self, method: str) -> None:
        """It was cut at 3,000 and 4,000 characters."""
        client = ScriptedClient(RCT)

        getattr(benchmark(client), method)(make_document(MEDIUM_ABSTRACT), EVALUATOR)

        assert len(client.prompts) == 1 and "LAST WORDS." in client.prompts[0]

    @pytest.mark.parametrize("method", ["_classify_document", "_assess_document"])
    def test_every_window_is_counted_and_reduced(self, method: str) -> None:
        """Two billed calls: their tokens summed, their answers voted."""
        client = ScriptedClient(RCT, COHORT)

        evaluation = getattr(benchmark(client), method)(
            make_document(LONG_ABSTRACT), EVALUATOR)

        assert len(client.prompts) == 2
        assert (evaluation.tokens_input, evaluation.tokens_output) == (200, 40)
        assert evaluation.assessment.study_design is StudyDesign.RCT
        assert evaluation.assessment.sample_size == 300

    def test_a_window_that_fails_fails_the_paper_and_stops(self) -> None:
        """No later window is paid for; the call made is still counted."""
        client = ScriptedClient("not json", RCT)

        evaluation = benchmark(client)._classify_document(
            make_document(LONG_ABSTRACT), EVALUATOR)

        assert len(client.prompts) == 1
        assert evaluation.failure is not None and evaluation.assessment is None
        assert evaluation.tokens_input == 100
