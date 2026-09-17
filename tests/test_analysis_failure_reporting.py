# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A failed analysis is not an empty one (#261, #262, #263, #264).

#247 stopped a failed *search* from reading as a literature with nothing in
it. The stages after the search still do exactly that: an unreachable model
ends a review with "No documents scored 3 or higher", a citation extraction
that failed for every document produces "No relevant evidence was found in the
searched literature", and a report that could not be generated is returned,
checkpointed and auto-saved as a finished report.

These tests follow a failed scoring, citation extraction or report generation
to every surface a person or a calling agent reads.
"""

from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite import mcp_server
from bmlibrarian_lite.agents.citation_agent import LiteCitationAgent
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.analysis_failures import (
    analysis_failure_advice,
    describe_analysis_shortfalls,
    format_analysis_shortfall_notice,
    with_analysis_shortfall_notice,
    without_analysis_shortfall_notice,
)
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    AnalysisShortfall,
    AnalysisStage,
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ReportMetadata,
    ScoredDocument,
    ScoringOutcome,
    SearchSession,
)
from bmlibrarian_lite.exceptions import AnalysisFailedError, APIError

TIMED_OUT = EvaluationErrorCode.API_TIMEOUT
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR
NOTICE_START = "> **Incomplete analysis:**"
QUESTION = "Does aspirin prevent stroke?"


def scoring_shortfall(failed: int = 3, attempted: int = 20) -> AnalysisShortfall:
    """A scoring shortfall whose documents timed out."""
    return AnalysisShortfall(
        stage=AnalysisStage.SCORING,
        documents_failed=failed,
        documents_attempted=attempted,
        causes=(TIMED_OUT,),
    )


def make_document(pmid: str = "12345") -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


def unreachable() -> APIError:
    """What a provider nobody can reach raises, once its retries are spent."""
    return APIError("Connection refused")


class ScriptedLLM:
    """Answers each call with the next scripted result, raising an exception."""

    def __init__(self, answers: list[Any]) -> None:
        """Take the answers, in the order the calls will come.

        Args:
            answers: Each one a result to return or an exception to raise.
        """
        self.answers = list(answers)

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        """Answer one call.

        Args:
            *args: Ignored.
            **kwargs: Ignored.

        Returns:
            The next scripted result.

        Raises:
            Exception: The next scripted exception.
            AssertionError: If called more often than it was scripted for.
        """
        assert self.answers, "The agent made more calls than the test scripted"
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def scoring_agent(
    monkeypatch: pytest.MonkeyPatch, answers: list[Any]
) -> LiteScoringAgent:
    """A scoring agent whose model answers as scripted, without retrying."""
    agent = LiteScoringAgent()
    monkeypatch.setattr(agent, "_score_with_retry", ScriptedLLM(answers))
    return agent


def citation_agent(
    monkeypatch: pytest.MonkeyPatch, answers: list[Any]
) -> LiteCitationAgent:
    """A citation agent whose model answers as scripted, without retrying."""
    agent = LiteCitationAgent()
    monkeypatch.setattr(agent, "_extract_with_retry", ScriptedLLM(answers))
    return agent


def reporting_agent(monkeypatch: pytest.MonkeyPatch, answer: str) -> LiteReportingAgent:
    """A reporting agent whose model answers with the given report body."""
    agent = LiteReportingAgent()
    monkeypatch.setattr(agent, "_chat", ScriptedLLM([answer]))
    return agent


def relevant(pmid: int, score: int = 4) -> ScoredDocument:
    """A document that met the relevance threshold."""
    return ScoredDocument(
        document=make_document(str(pmid)), score=score, explanation="On topic."
    )


def irrelevant(pmid: int) -> ScoredDocument:
    """A document the model scored below the threshold."""
    return relevant(pmid, score=1)


FULL_TEXT = "# Aspirin trial\n\nAspirin reduced stroke incidence."


def mcp_context() -> mcp_server._AgentsContext:
    """An MCP context whose every agent is a mock."""
    return mcp_server._AgentsContext(
        config=MagicMock(),
        storage=MagicMock(),
        llm_client=MagicMock(),
        search_agent=MagicMock(),
        scoring_agent=MagicMock(),
        citation_agent=MagicMock(),
        reporting_agent=MagicMock(),
        interrogation_agent=MagicMock(),
        fulltext_discoverer=MagicMock(),
    )


def fact_check_context() -> mcp_server._AgentsContext:
    """A context whose search, scoring and extraction all succeed."""
    context = mcp_context()
    document = make_document("1")
    session = SearchSession(
        id="session-1",
        query="aspirin AND stroke",
        natural_language_query=QUESTION,
        created_at=datetime.now(),
        document_count=1,
        metadata={"provider": "pubmed"},
    )
    context.search_agent.search.return_value = (session, [document])
    context.scoring_agent.score_documents.return_value = ScoringOutcome(
        accepted=[relevant(1)], failed=[], documents_attempted=1
    )
    context.citation_agent.extract_all_citations.return_value = CitationOutcome(
        citations=[make_citation()], documents_attempted=1
    )
    context.reporting_agent.generate_report.return_value = "## Findings"
    return context


def fulltext_context(load_error: Exception | None) -> mcp_server._AgentsContext:
    """A context whose full-text discovery succeeds, loading as given."""
    context = mcp_context()
    discovered = MagicMock()
    discovered.success = True
    discovered.markdown_content = FULL_TEXT
    discovered.source_type.value = "europepmc_xml"
    discovered.article_info.title = "Aspirin trial"
    context.fulltext_discoverer.discover_fulltext.return_value = discovered
    if load_error is None:
        context.interrogation_agent.load_document.return_value = "pmid-1"
    else:
        context.interrogation_agent.load_document.side_effect = load_error
    return context


def make_citation() -> Citation:
    """A citation from a relevant document."""
    return Citation(
        document=make_document("1"),
        passage="Aspirin reduced stroke incidence.",
        relevance_score=4,
    )


class TestTheShortfall:
    """What a stage could not analyse, said in the reader's words."""

    def test_a_scoring_shortfall_names_how_many_failed_and_why(self) -> None:
        """"3 of 20 rejected" and "3 of 20 unscorable" are different facts."""
        assert scoring_shortfall().describe() == (
            "3 of 20 documents could not be scored (API request timed out)"
        )

    def test_a_citation_shortfall_names_the_stage_that_failed(self) -> None:
        """A document nobody could read is not a document with nothing to say."""
        shortfall = AnalysisShortfall(
            stage=AnalysisStage.CITATION_EXTRACTION,
            documents_failed=1,
            documents_attempted=4,
            causes=(UNREACHABLE,),
        )

        assert shortfall.describe() == (
            "1 of 4 documents could not be read for citations (Failed to connect to API)"
        )

    def test_every_cause_is_named_once_in_the_order_it_first_occurred(self) -> None:
        """Twenty timeouts and one refusal are two causes, not twenty-one."""
        shortfall = AnalysisShortfall(
            stage=AnalysisStage.SCORING,
            documents_failed=3,
            documents_attempted=3,
            causes=(TIMED_OUT, UNREACHABLE, TIMED_OUT),
        )

        assert shortfall.describe().endswith(
            "(API request timed out, Failed to connect to API)"
        )

    def test_a_shortfall_with_no_cause_still_says_what_was_lost(self) -> None:
        """The count degrades to a count; it is never dropped."""
        shortfall = AnalysisShortfall(
            stage=AnalysisStage.SCORING, documents_failed=2, documents_attempted=5
        )

        assert shortfall.describe() == "2 of 5 documents could not be scored"

    def test_a_shortfall_that_lost_nothing_is_refused(self) -> None:
        """It would tell the user a complete analysis was incomplete."""
        with pytest.raises(ValueError):
            AnalysisShortfall(
                stage=AnalysisStage.SCORING, documents_failed=0, documents_attempted=5
            )

    def test_more_failures_than_attempts_is_refused(self) -> None:
        """A count that cannot be true would misstate what is missing."""
        with pytest.raises(ValueError):
            AnalysisShortfall(
                stage=AnalysisStage.SCORING, documents_failed=6, documents_attempted=5
            )

    def test_a_stage_that_lost_everything_says_so(self) -> None:
        """Nothing was analysed, so there is nothing to proceed on."""
        assert AnalysisShortfall(
            stage=AnalysisStage.SCORING, documents_failed=5, documents_attempted=5
        ).nothing_survived
        assert not scoring_shortfall().nothing_survived

    def test_a_shortfall_survives_a_round_trip_through_its_dictionary(self) -> None:
        """Report metadata and the MCP payload carry it as JSON."""
        shortfall = scoring_shortfall()

        assert AnalysisShortfall.from_dict(shortfall.to_dict()) == shortfall

    def test_a_stored_shortfall_with_an_unknown_cause_keeps_its_count(self) -> None:
        """A newer build's error code degrades the reason, never the loss."""
        stored = {
            "stage": "scoring",
            "documents_failed": 3,
            "documents_attempted": 20,
            "causes": [-9999, "nonsense"],
        }

        restored = AnalysisShortfall.from_dict(stored)

        assert restored.documents_failed == 3
        assert restored.causes == ()

    def test_a_stored_shortfall_naming_no_stage_is_refused(self) -> None:
        """Which stage failed cannot be guessed, so it is not read at all."""
        with pytest.raises(ValueError):
            AnalysisShortfall.from_dict(
                {"stage": "haruspicy", "documents_failed": 1, "documents_attempted": 2}
            )


class TestTheNotice:
    """What precedes a report that rests on an incomplete analysis."""

    def test_the_reader_meets_the_qualification_before_the_findings(self) -> None:
        """A report qualified at the end is read unqualified."""
        text = with_analysis_shortfall_notice("## Findings", [scoring_shortfall()])

        assert text.startswith(NOTICE_START)
        assert text.endswith("## Findings")

    def test_a_text_that_is_already_qualified_is_left_alone(self) -> None:
        """Two notices in front of one report say the loss happened twice."""
        once = with_analysis_shortfall_notice("## Findings", [scoring_shortfall()])

        assert with_analysis_shortfall_notice(once, [scoring_shortfall()]) == once

    def test_a_complete_analysis_is_never_qualified(self) -> None:
        """No failure, no notice."""
        assert format_analysis_shortfall_notice([]) == ""
        assert with_analysis_shortfall_notice("## Findings", []) == "## Findings"

    def test_the_body_can_be_read_back_from_behind_the_notice(self) -> None:
        """Deciding whether a text is a report reads what the notice precedes."""
        text = with_analysis_shortfall_notice("## Findings", [scoring_shortfall()])

        assert without_analysis_shortfall_notice(text) == "## Findings"
        assert without_analysis_shortfall_notice("## Findings") == "## Findings"

    def test_every_shortfall_is_named_in_the_notice(self) -> None:
        """Losing documents twice is worse than losing them once."""
        citations = AnalysisShortfall(
            stage=AnalysisStage.CITATION_EXTRACTION,
            documents_failed=2,
            documents_attempted=4,
            causes=(UNREACHABLE,),
        )

        described = describe_analysis_shortfalls([scoring_shortfall(), citations])

        assert described == (
            "3 of 20 documents could not be scored (API request timed out); "
            "2 of 4 documents could not be read for citations (Failed to connect to API)"
        )


class TestTheAdvice:
    """What the user can do about a failed analysis."""

    def test_a_refused_key_sends_the_user_to_the_settings(self) -> None:
        """"Try again later" cannot help a key the provider refuses."""
        advice = analysis_failure_advice(
            [
                AnalysisShortfall(
                    stage=AnalysisStage.SCORING,
                    documents_failed=5,
                    documents_attempted=5,
                    causes=(EvaluationErrorCode.API_AUTH_ERROR,),
                )
            ]
        )

        assert "Settings" in advice

    def test_an_unreachable_provider_is_named_as_such(self) -> None:
        """The model provider, not the literature, is what failed."""
        advice = analysis_failure_advice(
            [
                AnalysisShortfall(
                    stage=AnalysisStage.SCORING,
                    documents_failed=5,
                    documents_attempted=5,
                    causes=(UNREACHABLE,),
                )
            ]
        )

        assert "reachable" in advice

    def test_an_unclassified_failure_still_gets_a_next_step(self) -> None:
        """Advice that names nothing is still better than none."""
        assert analysis_failure_advice([scoring_shortfall(failed=1, attempted=1)])


class TestScoring:
    """A document nobody could score is not a document scored low."""

    def test_a_provider_that_answered_nothing_is_not_a_literature_that_says_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The #262 symptom was "No documents scored 3 or higher"."""
        agent = scoring_agent(monkeypatch, [unreachable(), unreachable(), unreachable()])

        with pytest.raises(AnalysisFailedError) as raised:
            agent.score_documents(QUESTION, [make_document(str(i)) for i in range(3)])

        shortfall = raised.value.shortfall
        assert shortfall.stage is AnalysisStage.SCORING
        assert shortfall.nothing_survived
        assert shortfall.causes == (UNREACHABLE,)
        assert "3 of 3 documents could not be scored" in str(raised.value)

    def test_documents_that_failed_are_kept_apart_from_documents_turned_down(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Both are missing from the result; only one is the literature's answer."""
        agent = scoring_agent(
            monkeypatch,
            [unreachable(), {"score": 1, "explanation": "Off topic."},
             {"score": 4, "explanation": "On topic."}],
        )

        outcome = agent.score_documents(
            QUESTION, [make_document(str(i)) for i in range(3)], min_score=3
        )

        assert [d.score for d in outcome.accepted] == [4]
        assert [d.document.pmid for d in outcome.failed] == ["0"]
        assert outcome.documents_attempted == 3
        assert outcome.shortfall is not None
        assert outcome.shortfall.describe() == (
            "1 of 3 documents could not be scored (Failed to connect to API)"
        )

    def test_an_analysis_that_lost_nothing_is_not_qualified(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every document was scored, so there is nothing to tell the reader."""
        agent = scoring_agent(monkeypatch, [{"score": 4, "explanation": "On topic."}])

        outcome = agent.score_documents(QUESTION, [make_document("1")], min_score=3)

        assert outcome.shortfall is None
        assert outcome.failed == []
        assert [d.score for d in outcome.accepted] == [4]

    def test_a_scored_document_that_failed_never_reaches_the_accepted_list(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A negative score sorts below every threshold, but say it explicitly."""
        agent = scoring_agent(
            monkeypatch, [unreachable(), {"score": 3, "explanation": "On topic."}]
        )

        outcome = agent.score_documents(
            QUESTION, [make_document("0"), make_document("1")], min_score=1
        )

        assert all(d.score > 0 for d in outcome.accepted)


class TestCitationExtraction:
    """A passage nobody could extract is not a document with nothing to say."""

    def test_an_extraction_that_failed_everywhere_is_not_a_silent_literature(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The #261 symptom was "No relevant evidence was found"."""
        agent = citation_agent(monkeypatch, [unreachable(), unreachable()])

        outcome = agent.extract_all_citations(QUESTION, [relevant(0), relevant(1)])

        assert outcome.citations == []
        assert outcome.shortfall is not None
        assert outcome.shortfall.nothing_survived
        assert outcome.shortfall.stage is AnalysisStage.CITATION_EXTRACTION
        assert outcome.shortfall.causes == (UNREACHABLE,)

    def test_a_partial_failure_names_what_was_lost(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A report on half the evidence says which half is missing."""
        agent = citation_agent(
            monkeypatch, [unreachable(), [{"text": "Aspirin reduced stroke."}]]
        )

        outcome = agent.extract_all_citations(QUESTION, [relevant(0), relevant(1)])

        assert len(outcome.citations) == 1
        assert outcome.shortfall is not None
        assert outcome.shortfall.describe() == (
            "1 of 2 documents could not be read for citations (Failed to connect to API)"
        )

    def test_an_extraction_that_lost_nothing_is_not_qualified(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every document was read, so there is nothing to tell the reader."""
        agent = citation_agent(monkeypatch, [[{"text": "Aspirin reduced stroke."}]])

        outcome = agent.extract_all_citations(QUESTION, [relevant(0)])

        assert outcome.shortfall is None
        assert [c.passage for c in outcome.citations] == ["Aspirin reduced stroke."]

    def test_documents_below_the_threshold_were_never_attempted(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A document nobody tried to read did not fail to be read."""
        agent = citation_agent(monkeypatch, [unreachable()])

        outcome = agent.extract_all_citations(
            QUESTION, [relevant(0), irrelevant(1)], min_score=3
        )

        assert outcome.documents_attempted == 1
        assert outcome.shortfall is not None
        assert outcome.shortfall.documents_attempted == 1


class TestTheReport:
    """A report never claims the literature is silent about a failure."""

    def test_a_failed_extraction_is_not_reported_as_an_empty_literature(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """What MCP fact_check_claim returned before #261."""
        agent = reporting_agent(monkeypatch, "## Findings")

        report = agent.generate_report(
            QUESTION,
            [],
            analysis_shortfalls=[
                AnalysisShortfall(AnalysisStage.CITATION_EXTRACTION, 2, 2, (UNREACHABLE,))
            ],
        )

        assert "No relevant evidence was found" not in report
        assert "citation extraction" in report
        assert "2 of 2 documents could not be read for citations" in report

    def test_a_literature_that_really_is_silent_still_says_so(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing failed, so the absence of evidence is the evidence base's."""
        agent = reporting_agent(monkeypatch, "## Findings")

        report = agent.generate_report(QUESTION, [])

        assert "No relevant evidence was found" in report

    def test_a_report_on_part_of_the_evidence_opens_with_the_notice(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The reader meets the qualification before the findings."""
        agent = reporting_agent(monkeypatch, "## Findings")

        report = agent.generate_report(
            QUESTION,
            [make_citation()],
            analysis_shortfalls=[scoring_shortfall(failed=1, attempted=4)],
        )

        assert report.startswith(NOTICE_START)
        assert "## Findings" in report

    def test_the_methodology_section_records_what_the_analysis_lost(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The audit said "Rejected: 1" where one document was never scored."""
        agent = reporting_agent(monkeypatch, "## Findings")
        metadata = ReportMetadata(
            research_question=QUESTION,
            documents_scored=4,
            documents_accepted=3,
            documents_rejected=0,
            analysis_shortfalls=[scoring_shortfall(failed=1, attempted=4)],
        )

        section = agent.format_methodology_section(metadata)

        assert (
            "- **Analysis Completeness:** Incomplete: 1 of 4 documents could not "
            "be scored (API request timed out)" in section
        )

    def test_a_complete_analysis_adds_no_methodology_line(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A complete review never reads as a qualified one."""
        agent = reporting_agent(monkeypatch, "## Findings")

        section = agent.format_methodology_section(ReportMetadata(documents_scored=4))

        assert "Analysis Completeness" not in section

    def test_a_report_that_could_not_be_generated_is_not_a_report(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """#263: the error text was checkpointed, auto-saved and returned as one."""
        agent = LiteReportingAgent()
        monkeypatch.setattr(agent, "_chat", ScriptedLLM([unreachable()]))

        with pytest.raises(APIError):
            agent.generate_report(QUESTION, [make_citation()])

    def test_a_summary_that_could_not_be_generated_is_not_a_summary(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The same defect, one method over."""
        agent = LiteReportingAgent()
        monkeypatch.setattr(agent, "_chat", ScriptedLLM([unreachable()]))

        with pytest.raises(APIError):
            agent.generate_brief_summary(QUESTION, [make_citation()])


class TestTheMcpFactCheck:
    """An agent fact-checking a claim never reads a failure as a finding."""

    def test_scoring_that_failed_everywhere_is_an_error_not_a_verdict(self) -> None:
        """The #262 symptom: "none scored above the relevance threshold"."""
        context = fact_check_context()
        context.scoring_agent.score_documents.side_effect = AnalysisFailedError(
            AnalysisShortfall(AnalysisStage.SCORING, 2, 2, (UNREACHABLE,))
        )

        with pytest.raises(AnalysisFailedError):
            mcp_server._handle_fact_check({"claim": QUESTION}, context)

    def test_a_failed_analysis_tells_the_caller_what_to_do(self) -> None:
        """The error result carries the shortfall and the next step."""
        error = AnalysisFailedError(
            AnalysisShortfall(AnalysisStage.SCORING, 2, 2, (UNREACHABLE,))
        )

        payload = mcp_server._error_payload(error)

        assert payload["analysis_shortfalls"] == [
            {
                "stage": "scoring",
                "documents_failed": 2,
                "documents_attempted": 2,
                "causes": [UNREACHABLE.value],
                "description": "2 of 2 documents could not be scored "
                "(Failed to connect to API)",
            }
        ]
        assert "reachable" in payload["advice"]

    def test_an_extraction_that_failed_everywhere_is_not_an_empty_literature(
        self,
    ) -> None:
        """The #261 symptom: "No relevant evidence was found"."""
        context = fact_check_context()
        context.citation_agent.extract_all_citations.return_value = CitationOutcome(
            citations=[], documents_attempted=2, documents_failed=2, causes=(UNREACHABLE,)
        )
        context.reporting_agent.generate_report = LiteReportingAgent(
            config=LiteConfig()
        ).generate_report

        result = mcp_server._handle_fact_check({"claim": QUESTION}, context)

        assert "No relevant evidence was found" not in result["report"]
        assert result["analysis_shortfalls"] == [
            {
                "stage": "citation_extraction",
                "documents_failed": 2,
                "documents_attempted": 2,
                "causes": [UNREACHABLE.value],
                "description": "2 of 2 documents could not be read for citations "
                "(Failed to connect to API)",
            }
        ]

    def test_the_report_is_qualified_once(self) -> None:
        """The agent qualifies the report; the result must not do it again."""
        context = fact_check_context()
        context.citation_agent.extract_all_citations.return_value = CitationOutcome(
            citations=[], documents_attempted=2, documents_failed=2, causes=(UNREACHABLE,)
        )
        context.reporting_agent.generate_report = LiteReportingAgent(
            config=LiteConfig()
        ).generate_report

        result = mcp_server._handle_fact_check({"claim": QUESTION}, context)

        assert result["report"].count(NOTICE_START) == 1

    def test_a_complete_analysis_carries_an_empty_list(self) -> None:
        """The field is always present, so a caller need not guess its absence."""
        context = fact_check_context()

        result = mcp_server._handle_fact_check({"claim": QUESTION}, context)

        assert result["analysis_shortfalls"] == []

    def test_a_partial_scoring_failure_reaches_the_caller(self) -> None:
        """A verdict that rests on half the documents says which half."""
        context = fact_check_context()
        context.scoring_agent.score_documents.return_value = ScoringOutcome(
            accepted=[relevant(0)],
            failed=[
                ScoredDocument(
                    document=make_document("1"),
                    score=UNREACHABLE.value,
                    explanation="Scoring failed.",
                )
            ],
            documents_attempted=2,
        )

        result = mcp_server._handle_fact_check({"claim": QUESTION}, context)

        assert result["report"].startswith(NOTICE_START)
        assert [s["stage"] for s in result["analysis_shortfalls"]] == ["scoring"]


class TestTheMcpFullText:
    """A document that could not be loaded is not ready to be asked about."""

    def test_a_document_that_could_not_be_loaded_says_so(self) -> None:
        """#264: ask_document then failed, and nothing had said why."""
        context = fulltext_context(ValueError("Document produced no chunks"))

        result = mcp_server._handle_fulltext({"pmid": "1"}, context)

        assert result["interrogation_available"] is False
        assert "no chunks" in result["interrogation_error"]
        assert result["content"] == FULL_TEXT

    def test_a_loaded_document_is_reported_as_ready(self) -> None:
        """The caller can tell the two apart without trying."""
        context = fulltext_context(None)

        result = mcp_server._handle_fulltext({"pmid": "1"}, context)

        assert result["interrogation_available"] is True
        assert "interrogation_error" not in result
