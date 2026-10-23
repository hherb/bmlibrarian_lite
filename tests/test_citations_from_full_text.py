# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Citations read from full text, and *Retry Full Text*, on the desktop.

The apps' rules (iOS/macOS PR #611, Android PR #616): papers scored at or
above *Fetch Full Text From Score* (never below the review's threshold) have
their citations read from their full text; which text each paper was read
from is recorded; a retry asks again for those not read from it, replaces
their citations only when the text yields passages, and writes the report
again only when a full text was read. Every text a model analyses is read
in sliding 16,000-character windows overlapping by 250 and the answers
reduced (the maintainer's rule, 2026-10-23), never its reference list.
"""

import json
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest
from bmlib.publications.retraction_status import RetractionStatus

from bmlibrarian_lite import citation_full_texts
from bmlibrarian_lite.agents.citation_agent import (
    CITATION_SYSTEM_PROMPT,
    FULL_TEXT_SYSTEM_PROMPT,
    LiteCitationAgent,
    merged_window_citations,
)
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.analysis_failures import failure_cause_text
from bmlibrarian_lite.audit_records import (
    CHECKPOINT_EXTRACTION_FAILURES_KEY,
    CHECKPOINT_MIN_SCORE_KEY,
    CHECKPOINT_REPORT_METADATA_KEY,
    CHECKPOINT_RETRACTION_SNAPSHOT_KEY,
    recorded_report_metadata,
)
from bmlibrarian_lite.chunking import analysis_windows, without_references
from bmlibrarian_lite.citation_text import (
    full_text_min_score,
    full_text_summary,
    record_full_text_reads,
)
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    AnalysisShortfall,
    AnalysisStage,
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    ExtractionFailure,
    LiteDocument,
    PassFailure,
    ReportMetadata,
    ScoredDocument,
)
from bmlibrarian_lite.full_text_retry import (
    CANCELLED_TEXT,
    NO_NEW_FULL_TEXT_TEXT,
    NO_REPORT_TEXT,
    NOT_KEPT_TEXT,
    REPORT_PENDING_KEY,
    FullTextRetry,
    RetryNotPossible,
    retry_full_texts,
    retry_text,
)
from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.utils import classify_analysis_exception

QUESTION = "Does aspirin prevent stroke?"
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract=f"Abstract {pmid}: aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


def scored(pmid: str, score: int) -> ScoredDocument:
    """A scored document."""
    return ScoredDocument(document=make_document(pmid), score=score, explanation="On topic.")


class Recording:
    """Stands in for ``_extract_with_retry``: records prompts, answers from a script."""

    def __init__(self, answers: list[Any]) -> None:
        """Script the answers: each a passage list or an exception to raise."""
        self.answers = list(answers)
        self.calls: list[list[Any]] = []

    def __call__(self, messages: list[Any]) -> Any:
        """Answer one call."""
        self.calls.append(messages)
        answer = self.answers.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return answer


def passage(text: str) -> list[dict[str, str]]:
    """A one-passage answer."""
    return [{"text": text, "relevance": "direct"}]


# ---------------------------------------------------------------------------
# What is read of a full text
# ---------------------------------------------------------------------------


class TestTheReferenceListIsNeverRead:
    """A reference is another paper's claim, never this one's evidence."""

    def test_the_converters_reference_list_is_left_out(self) -> None:
        """``jats_to_markdown`` ends with ``## References``."""
        text = "# Title\n\nResults here.\n\n## References\n- Smith 2020."
        assert without_references(text) == "# Title\n\nResults here."

    def test_a_pdfs_numbered_heading_is_found(self) -> None:
        """A PDF carries "7. References" or "Bibliography:" as a line."""
        assert without_references("Body.\n7. References\n1. A.") == "Body."
        assert without_references("Body.\nBibliography:\n1. A.") == "Body."

    def test_the_last_heading_is_the_one_cut_at(self) -> None:
        """A "References" line in the body cannot take the rest with it."""
        text = "Intro.\nReferences\nMore body.\nReferences\n1. A."
        assert without_references(text) == "Intro.\nReferences\nMore body."

    def test_a_sentence_mentioning_references_is_not_a_heading(self) -> None:
        """Only a line that is the heading alone counts."""
        text = "We checked the references of each trial.\nResults."
        assert without_references(text) == text

    def test_a_text_without_one_is_read_whole(self) -> None:
        """Nothing is cut when nothing is found."""
        assert without_references("  Body only.  ") == "Body only."


class TestWindowsHoldAllOfTheText:
    """Every text is read in overlapping windows, never cut (golden rule 13)."""

    def test_the_defaults_are_16k_windows_overlapping_by_250(self) -> None:
        """Small enough for any provider; every sentence whole in some window."""
        sentences = [f"Sentence {i:05d} reports a finding about stroke." for i in range(1500)]
        text = " ".join(sentences)

        windows = analysis_windows(text)

        assert len(windows) > 1
        assert all(len(window) <= 16_000 for window in windows)
        assert all(any(s in window for window in windows) for s in sentences)
        for before, after in zip(windows, windows[1:], strict=False):
            assert before[-200:] in after[:400]

    def test_a_short_text_is_one_window(self) -> None:
        """The common case: one call, as before."""
        assert analysis_windows("One.\n\nTwo.") == ["One.\n\nTwo."]

    def test_the_reference_list_is_in_no_window(self) -> None:
        """However long the article."""
        text = "Body sentence. " * 2000 + "\n\n## References\n" + "- Ref. " * 2000

        windows = analysis_windows(text)

        assert len(windows) == 2
        assert not any("- Ref." in window for window in windows)

    def test_nothing_makes_no_window(self) -> None:
        """A text of blank lines, or only references, has nothing to read."""
        assert analysis_windows("\n\n  \n\n") == []
        assert analysis_windows("## References\n- X.") == []

    def test_a_window_is_longer_than_its_overlap(self) -> None:
        """Otherwise the window would never advance."""
        with pytest.raises(ValueError):
            analysis_windows("text " * 100, window_chars=10, overlap_chars=10)


class TestTheReduce:
    """Merge every window's passages, each once."""

    def test_a_passage_the_overlap_quotes_twice_is_kept_once(self) -> None:
        """Same sentence from two windows, or a part of it from one."""
        merged = merged_window_citations([
            cite("1", "Stroke fell by 20% (95% CI 10-30)."),
            cite("1", "stroke fell  by 20% (95% CI 10-30)."),
            cite("1", "Stroke fell by 20%"),
            cite("1", "Bleeding rose."),
        ])

        assert [c.passage for c in merged] == [
            "Stroke fell by 20% (95% CI 10-30).", "Bleeding rose."]


def test_the_full_text_score_is_never_below_the_threshold() -> None:
    """A paper below the review's threshold is not cited at all."""
    assert full_text_min_score(3, 4) == 4
    assert full_text_min_score(5, 4) == 5


# ---------------------------------------------------------------------------
# The setting
# ---------------------------------------------------------------------------


class TestTheSetting:
    """Off by default, as on the apps; kept across a save."""

    def test_it_is_off_at_score_four_by_default(self) -> None:
        """Every window is a call."""
        config = LiteConfig()
        assert config.discovery.citations_from_full_text is False
        assert config.discovery.full_text_min_score == 4

    def test_it_round_trips(self, tmp_path: Path) -> None:
        """Saved and loaded unchanged."""
        config = LiteConfig()
        config.discovery.citations_from_full_text = True
        config.discovery.full_text_min_score = 5
        path = tmp_path / "config.json"
        path.write_text(json.dumps(config.to_dict()))

        loaded = LiteConfig.load(path)

        assert loaded.discovery.citations_from_full_text is True
        assert loaded.discovery.full_text_min_score == 5

    @pytest.mark.parametrize(
        "stored", [{"citations_from_full_text": "yes"}, {"full_text_min_score": 9},
                   {"full_text_min_score": True}, {"full_text_min_score": "4"}]
    )
    def test_a_value_it_cannot_take_is_the_default(
        self, tmp_path: Path, stored: dict[str, Any]
    ) -> None:
        """Never a truthy string read as on, nor a score no paper has."""
        path = tmp_path / "config.json"
        path.write_text(json.dumps({"discovery": stored}))

        loaded = LiteConfig.load(path)

        assert loaded.discovery.citations_from_full_text is False
        assert loaded.discovery.full_text_min_score == 4


# ---------------------------------------------------------------------------
# The agent
# ---------------------------------------------------------------------------


class TestTheAgentReadsTheFullText:
    """A paper with a full text is read from it, window by window."""

    def test_each_window_is_one_call_and_their_passages_are_merged(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing of the text is left unread; a repeated quote is kept once."""
        monkeypatch.setattr(
            "bmlibrarian_lite.agents.citation_agent.analysis_windows",
            lambda text: analysis_windows(text, window_chars=24, overlap_chars=2),
        )
        agent = LiteCitationAgent()
        llm = Recording([passage("Stroke fell 20%."), passage("Stroke fell 20%."),
                         passage("Bleeding rose.")])
        monkeypatch.setattr(agent, "_extract_with_retry", llm)
        text = "First part of the body.\n\nSecond part here.\n\nThird.\n\n## References\n- X."

        outcome = agent.extract_all_citations(
            QUESTION, [scored("1", 5)], full_texts={"doc-1": text}
        )

        assert len(llm.calls) == 3
        prompts = [call[1].content for call in llm.calls]
        assert "Full Text (part 1 of 3):" in prompts[0]
        assert "Full Text (part 3 of 3):" in prompts[2]
        assert all("Abstract" not in p and "- X." not in p for p in prompts)
        assert llm.calls[0][0].content == FULL_TEXT_SYSTEM_PROMPT
        assert [c.passage for c in outcome.citations] == ["Stroke fell 20%.", "Bleeding rose."]
        assert outcome.read_full_text == {"doc-1"}

    def test_a_paper_without_one_is_read_from_its_abstract(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """As before: one call, the abstract prompt."""
        agent = LiteCitationAgent()
        llm = Recording([passage("Abstract quote.")])
        monkeypatch.setattr(agent, "_extract_with_retry", llm)

        outcome = agent.extract_all_citations(
            QUESTION, [scored("1", 5)], full_texts={"doc-2": "other paper"}
        )

        assert llm.calls[0][0].content == CITATION_SYSTEM_PROMPT
        assert "Abstract 1:" in llm.calls[0][1].content
        assert outcome.read_full_text == frozenset()

    def test_a_text_that_is_only_references_is_no_text(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing before the references: the abstract is read, and said to be."""
        agent = LiteCitationAgent()
        llm = Recording([passage("Abstract quote.")])
        monkeypatch.setattr(agent, "_extract_with_retry", llm)

        outcome = agent.extract_all_citations(
            QUESTION, [scored("1", 5)], full_texts={"doc-1": "## References\n- X."}
        )

        assert "Abstract 1:" in llm.calls[0][1].content
        assert outcome.read_full_text == frozenset()

    def test_a_window_that_fails_fails_the_paper(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Half a text read is not a full text read, and not a silent one."""
        monkeypatch.setattr(
            "bmlibrarian_lite.agents.citation_agent.analysis_windows",
            lambda text: analysis_windows(text, window_chars=10, overlap_chars=2),
        )
        agent = LiteCitationAgent()
        monkeypatch.setattr(
            agent, "_extract_with_retry",
            Recording([passage("First."), ConnectionError("down")]),
        )

        outcome = agent.extract_all_citations(
            QUESTION, [scored("1", 5)], full_texts={"doc-1": "Part one.\n\nPart two."}
        )

        assert [f.document.id for f in outcome.failed] == ["doc-1"]
        assert outcome.citations == []
        assert outcome.read_full_text == frozenset()

    def test_in_parallel_each_paper_is_recorded_by_its_own_text(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """In parallel, the record still names the paper read from full text.

        Cloud providers extract several papers at once.
        """
        agent = LiteCitationAgent()
        monkeypatch.setattr(agent, "_extract_with_retry",
                            Recording([passage("Quote.")] * 3))

        outcome = agent.extract_all_citations(
            QUESTION, [scored("1", 5), scored("2", 5), scored("3", 5)],
            max_workers=3, full_texts={"doc-2": "Body of paper two."},
        )

        assert outcome.read_full_text == {"doc-2"}
        assert len(outcome.citations) == 3


class TestTheOutcomeRefusesWhatCannotBe:
    """``read_full_text`` is checked like the counts."""

    def test_a_failed_paper_did_not_read_its_full_text(self) -> None:
        """Read and failed cannot both be true."""
        with pytest.raises(ValueError):
            CitationOutcome(
                citations=[], documents_attempted=1,
                failed=(ExtractionFailure(make_document("1"), UNREACHABLE),),
                read_full_text=frozenset({"doc-1"}),
            )

    def test_no_more_read_full_text_than_were_read(self) -> None:
        """A count is not inflated by an id nobody attempted."""
        with pytest.raises(ValueError):
            CitationOutcome(
                citations=[], documents_attempted=1,
                read_full_text=frozenset({"doc-1", "doc-2"}),
            )


# ---------------------------------------------------------------------------
# What the report says
# ---------------------------------------------------------------------------


class TestTheMethodologySaysWhatWasRead:
    """The reader can tell a report read from full text from one read from abstracts."""

    def test_a_run_that_did_not_look_says_nothing_new(self) -> None:
        """Reports as before."""
        assert full_text_summary(ReportMetadata()) is None

    def test_the_counts_are_taken_over_the_papers_scored_high_enough(self) -> None:
        """A paper below the full-text score is not counted as missing one."""
        metadata = ReportMetadata()
        record_full_text_reads(
            metadata, 4, [scored("1", 5), scored("2", 4), scored("3", 3)], {"doc-1"}
        )

        assert (metadata.full_text_papers_read, metadata.full_text_read_count) == (2, 1)
        assert full_text_summary(metadata) == (
            "The citations of 1 of the 2 papers scored 4 or higher were read "
            "from their full text; for the others no readable full text was "
            "obtained, and their abstracts were read."
        )

    def test_all_read(self) -> None:
        """Said plainly."""
        metadata = ReportMetadata()
        record_full_text_reads(metadata, 4, [scored("1", 5), scored("2", 4)], {"doc-1", "doc-2"})
        assert full_text_summary(metadata) == (
            "The citations of all 2 papers scored 4 or higher were read from their full text."
        )

    def test_it_reaches_the_methodology_section(self) -> None:
        """Where the reader looks for how the report was made."""
        metadata = ReportMetadata(full_text_min_score=4, full_text_papers_read=1,
                                  full_text_read_count=1)
        section = LiteReportingAgent().format_methodology_section(metadata)
        assert "- **Full Text:** The citations of the paper scored 4 or higher" in section

    def test_the_figures_survive_the_checkpoint(self) -> None:
        """A retry writes the report again from them."""
        metadata = ReportMetadata(full_text_min_score=4, full_text_papers_read=3,
                                  full_text_read_count=2)
        again = ReportMetadata.from_dict(json.loads(json.dumps(metadata.to_dict())))
        assert (again.full_text_min_score, again.full_text_papers_read,
                again.full_text_read_count) == (4, 3, 2)

    def test_the_score_distribution_survives_the_checkpoint(self) -> None:
        """JSON makes the scores strings; read back, they are ints again.

        A report written again looks them up as ints, and would print a
        table of zeros.
        """
        metadata = ReportMetadata(score_distribution={5: 2, 4: 3, 1: 7})
        again = ReportMetadata.from_dict(json.loads(json.dumps(metadata.to_dict())))
        assert again.score_distribution == {5: 2, 4: 3, 1: 7}

    @pytest.mark.parametrize("figures", [
        {"full_text_min_score": 4, "full_text_papers_read": 2, "full_text_read_count": 5},
        {"full_text_min_score": None, "full_text_papers_read": 2, "full_text_read_count": 1},
        {"full_text_min_score": "4", "full_text_papers_read": 2, "full_text_read_count": 1},
        {"full_text_min_score": 4, "full_text_papers_read": True, "full_text_read_count": 0},
        {"full_text_min_score": 4, "full_text_papers_read": 2, "full_text_read_count": -1},
    ])
    def test_figures_that_cannot_all_be_true_are_refused(self, figures: dict[str, Any]) -> None:
        """Not printed as "5 of the 2 papers"; the retry is refused instead."""
        with pytest.raises(ValueError):
            ReportMetadata.from_dict(figures)

    def test_one_paper_not_read_from_full_text(self) -> None:
        """Not "0 of the 1 papers"."""
        metadata = ReportMetadata(full_text_min_score=4, full_text_papers_read=1,
                                  full_text_read_count=0)
        assert full_text_summary(metadata) == (
            "The citations of the paper scored 4 or higher were read from its "
            "abstract; no readable full text was obtained."
        )


# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------


@pytest.fixture
def storage(tmp_path: Path) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def cite(pmid: str, text: str) -> Citation:
    """A passage of a paper."""
    return Citation(document=make_document(pmid), passage=text, relevance_score=5, context="c")


class TestTheRecord:
    """Which text each paper was read from, kept per run."""

    def test_it_is_recorded_and_replaced(self, storage: LiteStorage) -> None:
        """The last extraction's answer is the one kept."""
        storage.record_citation_reads("cp", {"doc-1": False, "doc-2": True})
        storage.record_citation_reads("cp", {"doc-1": True})

        assert storage.get_citation_reads("cp") == {"doc-1": True, "doc-2": True}
        assert storage.get_citation_reads("other") == {}

    def test_replacing_a_papers_citations_records_it_read(self, storage: LiteStorage) -> None:
        """Only that paper's, only that run's."""
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        for pmid in ("1", "2"):
            storage.upsert_document(make_document(pmid))
        storage.save_citation(cite("1", "Old one."), checkpoint.id)
        storage.save_citation(cite("2", "Other paper."), checkpoint.id)

        storage.replace_document_citations(checkpoint.id, "doc-1", [cite("1", "New one.")])

        passages = {c.passage for c in storage.get_citations_for_question(
            QUESTION, checkpoint_id=checkpoint.id)}
        assert passages == {"New one.", "Other paper."}
        assert storage.get_citation_reads(checkpoint.id) == {"doc-1": True}

    def test_no_citations_replace_none(self, storage: LiteStorage) -> None:
        """Empty would delete a paper's citations and call it read."""
        with pytest.raises(ValueError):
            storage.replace_document_citations("cp", "doc-1", [])
        with pytest.raises(ValueError):
            storage.replace_document_citations("cp", "doc-1", [cite("2", "Wrong paper.")])

    def test_deleting_the_run_deletes_its_record(self, storage: LiteStorage) -> None:
        """Nothing outlives the checkpoint it describes."""
        checkpoint = storage.create_checkpoint(research_question=QUESTION)
        storage.record_citation_reads(checkpoint.id, {"doc-1": True})

        storage.delete_checkpoint(checkpoint.id)

        assert storage.get_citation_reads(checkpoint.id) == {}


# ---------------------------------------------------------------------------
# Fetching
# ---------------------------------------------------------------------------


class TestFetching:
    """One paper at a time; a failed fetch leaves the abstract."""

    def test_a_failed_fetch_is_skipped_and_a_stop_stops(self) -> None:
        """Neither ends the review: the abstract still makes a report."""
        asked: list[str] = []

        def fetch(doc: LiteDocument) -> str | None:
            asked.append(doc.id)
            if doc.id == "doc-1":
                raise RuntimeError("chain broke")
            return None if doc.id == "doc-2" else "Text."

        texts = citation_full_texts.fetch_full_texts(
            fetch, [make_document(p) for p in "1234"], lambda: len(asked) >= 3
        )

        assert asked == ["doc-1", "doc-2", "doc-3"]
        assert texts == {"doc-3": "Text."}

    @pytest.mark.parametrize("success, content, expected", [
        (True, "The body.", "The body."),  # the control
        (False, "Landing page.", None),  # a failure's text is never the paper
        (True, "", None),
    ])
    def test_only_a_successful_discovery_is_a_text(
        self, monkeypatch: pytest.MonkeyPatch, success: bool, content: str,
        expected: str | None,
    ) -> None:
        """Whatever else a failed discovery carries is not read as the paper."""
        result = SimpleNamespace(success=success, markdown_content=content,
                                 set_aside_pdf_note=None,
                                 source_type=SimpleNamespace(value="not_found"))
        monkeypatch.setattr(citation_full_texts, "FulltextDiscoverer",
                            lambda **_: SimpleNamespace(discover_fulltext=lambda doc_dict: result))

        fetch = citation_full_texts.full_text_fetcher(LiteConfig())

        assert fetch(make_document("1")) == expected

    def test_a_paper_is_looked_up_by_its_identifiers(self) -> None:
        """The pmid- id prefix stands in for a missing PMID field."""
        doc = make_document("7")
        doc.pmid, doc.pmc_id = None, "PMC9"
        doc.id = "pmid-7"
        ids = citation_full_texts.discovery_identifiers(doc)
        assert (ids["pmid"], ids["pmcid"], ids["pmc_id"]) == ("7", "PMC9", "PMC9")


# ---------------------------------------------------------------------------
# The review
# ---------------------------------------------------------------------------


def run_review(monkeypatch: pytest.MonkeyPatch, enabled: bool) -> dict[str, Any]:
    """Run the review worker over three papers scored 5, 4 and 3."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.data_models import SearchSession
    from bmlibrarian_lite.gui import systematic_review_tab
    from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

    documents = [make_document(p) for p in "123"]
    scores = {"doc-1": 5, "doc-2": 4, "doc-3": 3}
    session = SearchSession(
        id="s", query="q", natural_language_query=QUESTION,
        created_at=datetime.now(), document_count=3, metadata={},
    )
    search_agent = MagicMock()
    search_agent.search.return_value = (session, documents)
    monkeypatch.setattr(systematic_review_tab, "LiteSearchAgent", lambda **_: search_agent)
    scoring_agent = MagicMock()
    scoring_agent.score_document.side_effect = lambda q, doc: ScoredDocument(
        document=doc, score=scores[doc.id], explanation="."
    )
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scoring_agent)
    citation_agent = MagicMock()
    citation_agent.extract_all_citations.return_value = CitationOutcome(
        citations=[], documents_attempted=3, read_full_text=frozenset({"doc-1"}) if enabled
        else frozenset(),
    )
    monkeypatch.setattr(systematic_review_tab, "LiteCitationAgent", lambda **_: citation_agent)
    reporting_agent = MagicMock()
    reporting_agent.generate_report.return_value = "## Findings"
    monkeypatch.setattr(systematic_review_tab, "LiteReportingAgent", lambda **_: reporting_agent)
    asked: list[str] = []
    monkeypatch.setattr(
        systematic_review_tab, "full_text_fetcher",
        lambda config: lambda doc: asked.append(doc.id) or ("Text." if doc.id == "doc-1" else None),
    )
    config = LiteConfig()
    config.discovery.citations_from_full_text = enabled
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    monkeypatch.setattr(config.parallel, "get_citation_workers", lambda provider: 1)
    monkeypatch.setattr(config.transparency, "enabled", False)
    storage = MagicMock()
    storage.create_checkpoint.return_value.id = "cp"
    worker = WorkflowWorker(question=QUESTION, config=config, storage=storage, min_score=3)
    finished: list[Any] = []
    worker.finished.connect(lambda report, metadata: finished.append(metadata))
    worker.run()
    return {
        "asked": asked,
        "extract": citation_agent.extract_all_citations.call_args,
        "storage": storage,
        "metadata": finished[0],
        "report_metadata": reporting_agent.generate_report.call_args.args[2],
    }


class TestTheReview:
    """With the setting on, papers scored high enough are read from full text."""

    def test_only_papers_at_the_full_text_score_are_fetched(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Score 4 by default, over a threshold of 3."""
        run = run_review(monkeypatch, enabled=True)

        assert run["asked"] == ["doc-1", "doc-2"]
        assert run["extract"].kwargs["full_texts"] == {"doc-1": "Text."}

    def test_what_each_paper_was_read_from_is_kept(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every paper read is recorded, full text or abstract."""
        run = run_review(monkeypatch, enabled=True)

        run["storage"].record_citation_reads.assert_called_once_with(
            "cp", {"doc-1": True, "doc-2": False, "doc-3": False}
        )
        metadata = run["report_metadata"]
        assert (metadata.full_text_min_score, metadata.full_text_papers_read,
                metadata.full_text_read_count) == (4, 2, 1)

    def test_the_report_metadata_is_kept_for_a_retry(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Beside what the checkpoint already kept."""
        run = run_review(monkeypatch, enabled=True)

        last = [c.kwargs["metadata"] for c in run["storage"].update_checkpoint.call_args_list
                if "metadata" in c.kwargs][-1]
        assert last[CHECKPOINT_MIN_SCORE_KEY] == 3
        assert recorded_report_metadata(last).full_text_read_count == 1

    def test_off_fetches_nothing(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Every paper is read from its abstract, as before."""
        run = run_review(monkeypatch, enabled=False)

        assert run["asked"] == []
        assert run["extract"].kwargs["full_texts"] == {}
        assert run["report_metadata"].full_text_min_score is None


# ---------------------------------------------------------------------------
# Retry Full Text
# ---------------------------------------------------------------------------


class FakeAgent:
    """A citation agent answering per paper from a script."""

    def __init__(self, answers: dict[str, Any]) -> None:
        """Each paper's passages, or an exception for a failed read."""
        self.answers = answers
        self.calls: list[tuple[str, dict[str, str]]] = []

    def extract_all_citations(self, question: str, docs: list[ScoredDocument],
                              min_score: int, full_texts: dict[str, str]) -> CitationOutcome:
        """Read one paper."""
        doc = docs[0].document
        self.calls.append((doc.id, full_texts))
        answer = self.answers[doc.id]
        if isinstance(answer, Exception):
            return CitationOutcome(citations=[], documents_attempted=1,
                                   failed=(ExtractionFailure(doc, UNREACHABLE),))
        return CitationOutcome(
            citations=[Citation(document=doc, passage=t, relevance_score=5, context="c")
                       for t in answer],
            documents_attempted=1, read_full_text=frozenset({doc.id}),
        )


def reviewed(storage: LiteStorage, keep_metadata: bool = True,
             failed: tuple[str, ...] = ()) -> str:
    """A reviewed run: papers 1 (5), 2 (5, read from full text), 3 (4), 4 (3)."""
    metadata = ReportMetadata(
        research_question=QUESTION, min_score_threshold=3, version=1,
        full_text_min_score=4, citations_extracted=3,
    )
    if failed:
        metadata.analysis_shortfalls = [AnalysisShortfall(
            stage=AnalysisStage.CITATION_EXTRACTION, documents_failed=len(failed),
            documents_attempted=4, causes=(UNREACHABLE,))]
    checkpoint = storage.create_checkpoint(research_question=QUESTION, metadata={
        CHECKPOINT_MIN_SCORE_KEY: 3,
        CHECKPOINT_EXTRACTION_FAILURES_KEY: [
            {"document_id": f"doc-{p}", "error_code": UNREACHABLE.value} for p in failed],
        **({CHECKPOINT_REPORT_METADATA_KEY: metadata.to_dict()} if keep_metadata else {}),
    })
    for pmid, score in (("1", 5), ("2", 5), ("3", 4), ("4", 3)):
        storage.upsert_document(make_document(pmid))
        storage.save_scored_document(scored(pmid, score), checkpoint.id)
        if pmid not in failed:
            storage.save_citation(cite(pmid, f"Abstract quote {pmid}."), checkpoint.id)
    storage.record_citation_reads(checkpoint.id, {
        "doc-1": False, "doc-2": True, "doc-3": False, "doc-4": False})
    storage.update_checkpoint(checkpoint_id=checkpoint.id, report="Old report.", step="complete")
    return checkpoint.id


def retry(storage: LiteStorage, texts: dict[str, str], answers: dict[str, Any],
          stop_after: int | None = None, assessed: list[Any] | None = None,
          assess: Any = None, report_error: Exception | None = None,
          ) -> tuple[FullTextRetry, FakeAgent, MagicMock]:
    """Retry with scripted fetches, extractions and reports."""
    agent = FakeAgent(answers)
    reporter = MagicMock()
    reporter.generate_report.return_value = "New report."
    if report_error is not None:
        reporter.generate_report.side_effect = report_error
    if assessed is not None:
        assess = lambda doc, text: assessed.append((doc.id, text))  # noqa: E731
    config = LiteConfig()
    config.discovery.citations_from_full_text = True
    fetched: list[str] = []

    def fetch(doc: LiteDocument) -> str | None:
        fetched.append(doc.id)
        return texts.get(doc.id)

    outcome = retry_full_texts(
        QUESTION, storage, config, fetch, agent, reporter, assess,
        lambda: stop_after is not None and len(agent.calls) >= stop_after,
    )
    agent.fetched = fetched  # type: ignore[attr-defined]
    return outcome, agent, reporter


def passages_of(storage: LiteStorage, checkpoint_id: str) -> dict[str, set[str]]:
    """Each paper's stored passages."""
    out: dict[str, set[str]] = {}
    for c in storage.get_citations_for_question(QUESTION, checkpoint_id=checkpoint_id):
        out.setdefault(c.document.id, set()).add(c.passage)
    return out


class TestRetryFullText:
    """The apps' Retry Full Text Fetching, over a reviewed question's run."""

    def test_it_asks_only_for_papers_scored_high_enough_and_unread(
        self, storage: LiteStorage
    ) -> None:
        """Not the paper already read from full text, not the one scored 3."""
        reviewed(storage)

        outcome, agent, _ = retry(storage, {}, {})

        assert agent.fetched == ["doc-1", "doc-3"]  # type: ignore[attr-defined]
        assert outcome == FullTextRetry(asked=2, unavailable=2)

    def test_a_text_with_passages_replaces_the_citations_and_the_report(
        self, storage: LiteStorage
    ) -> None:
        """Written again, a version later, and kept."""
        checkpoint_id = reviewed(storage)
        assessed: list[Any] = []

        outcome, agent, reporter = retry(
            storage, {"doc-1": "Full text 1."}, {"doc-1": ["From the text."]}, assessed=assessed
        )

        assert outcome == FullTextRetry(asked=2, read=1, replaced=1, unavailable=1,
                                        report="New report.")
        assert agent.calls == [("doc-1", {"doc-1": "Full text 1."})]
        assert passages_of(storage, checkpoint_id)["doc-1"] == {"From the text."}
        assert passages_of(storage, checkpoint_id)["doc-3"] == {"Abstract quote 3."}
        assert storage.get_citation_reads(checkpoint_id)["doc-1"] is True
        assert assessed == [("doc-1", "Full text 1.")]
        metadata = reporter.generate_report.call_args.args[2]
        assert metadata.version == 2
        assert (metadata.full_text_papers_read, metadata.full_text_read_count) == (3, 2)
        assert metadata.citations_extracted == 4
        stored = storage.get_checkpoint_for_question(QUESTION)
        assert stored.report == "New report."
        assert recorded_report_metadata(stored.metadata).version == 2
        assert stored.metadata[CHECKPOINT_MIN_SCORE_KEY] == 3

    def test_a_text_with_nothing_quotable_keeps_the_old_citations(
        self, storage: LiteStorage
    ) -> None:
        """Read, and recorded as read; the old ones stand."""
        checkpoint_id = reviewed(storage)

        outcome, _, _ = retry(storage, {"doc-1": "Full text 1."}, {"doc-1": []})

        assert (outcome.read, outcome.replaced) == (1, 0)
        assert outcome.report == "New report."
        assert passages_of(storage, checkpoint_id)["doc-1"] == {"Abstract quote 1."}
        assert storage.get_citation_reads(checkpoint_id)["doc-1"] is True

    def test_no_text_read_leaves_the_report(self, storage: LiteStorage) -> None:
        """No full text read, no report written."""
        reviewed(storage)

        outcome, _, reporter = retry(
            storage, {"doc-1": "Full text 1."}, {"doc-1": ConnectionError("down")}
        )

        assert (outcome.read, outcome.failed, outcome.report) == (0, 1, None)
        reporter.generate_report.assert_not_called()
        assert storage.get_checkpoint_for_question(QUESTION).report == "Old report."
        assert NO_NEW_FULL_TEXT_TEXT in retry_text(outcome)

    def test_a_paper_whose_extraction_failed_before_is_no_longer_counted_lost(
        self, storage: LiteStorage
    ) -> None:
        """Its failure leaves the checkpoint and the report's shortfall."""
        reviewed(storage, failed=("1",))

        outcome, _, reporter = retry(storage, {"doc-1": "Full text 1."},
                                     {"doc-1": ["From the text."]})

        assert outcome.read == 1
        metadata = reporter.generate_report.call_args.args[2]
        assert [s for s in metadata.analysis_shortfalls
                if s.stage is AnalysisStage.CITATION_EXTRACTION] == []
        stored = storage.get_checkpoint_for_question(QUESTION)
        assert stored.metadata[CHECKPOINT_EXTRACTION_FAILURES_KEY] == []

    def test_a_cancel_writes_no_report_and_the_next_retry_writes_it(
        self, storage: LiteStorage
    ) -> None:
        """What it replaced stays, and the next retry writes the report.

        Even one that reads nothing new: the report and the citations never
        stay out of step.
        """
        checkpoint_id = reviewed(storage)

        outcome, _, reporter = retry(
            storage, {"doc-1": "T1.", "doc-3": "T3."},
            {"doc-1": ["New 1."], "doc-3": ["New 3."]}, stop_after=1,
        )

        assert outcome.cancelled and outcome.report is None
        reporter.generate_report.assert_not_called()
        assert passages_of(storage, checkpoint_id)["doc-1"] == {"New 1."}
        assert "next Retry Full Text writes the report" in retry_text(outcome)

        again, agent, reporter = retry(storage, {}, {})

        assert agent.fetched == ["doc-3"]  # type: ignore[attr-defined]
        assert (again.read, again.report) == (0, "New report.")
        assert "an earlier retry read" in retry_text(again)
        metadata = reporter.generate_report.call_args.args[2]
        assert metadata.full_text_read_count == 2
        stored = storage.get_checkpoint_for_question(QUESTION)
        assert stored.report == "New report."
        assert REPORT_PENDING_KEY not in stored.metadata

    def test_a_report_that_failed_to_write_is_written_by_the_next_retry(
        self, storage: LiteStorage
    ) -> None:
        """A provider outage at report time leaves the mark, not a stale report."""
        reviewed(storage)
        with pytest.raises(ConnectionError):
            retry(storage, {"doc-1": "T1."}, {"doc-1": ["New 1."]},
                  report_error=ConnectionError("down"))
        assert storage.get_checkpoint_for_question(QUESTION).metadata[REPORT_PENDING_KEY] is True

        again, _, _ = retry(storage, {}, {})

        assert again.report == "New report."

    def test_a_cancel_while_fetching_counts_only_the_papers_asked(
        self, storage: LiteStorage
    ) -> None:
        """A paper never asked is not one whose full text was not obtained."""
        reviewed(storage)
        agent = FakeAgent({})
        asked: list[str] = []

        def fetch(doc: LiteDocument) -> str | None:
            asked.append(doc.id)
            return None

        config = LiteConfig()
        outcome = retry_full_texts(QUESTION, storage, config, fetch, agent, MagicMock(),
                                   None, lambda: len(asked) >= 1)

        assert outcome == FullTextRetry(asked=1, unavailable=1, cancelled=True)
        assert retry_text(outcome) == (
            "Asked for 1 full text: 0 read, 1 not obtained. " + CANCELLED_TEXT
        )

    def test_an_error_after_a_cancel_says_nothing_false(self) -> None:
        """Not "every paper was already read" for a retry that asked for none."""
        assert retry_text(FullTextRetry(cancelled=True)) == CANCELLED_TEXT

    def test_a_text_with_nothing_before_its_references_is_not_obtained(
        self, storage: LiteStorage
    ) -> None:
        """Not a paper that "could not be read", and no model call is spent on it."""
        reviewed(storage)

        outcome, agent, _ = retry(storage, {"doc-1": "## References\n- X."}, {})

        assert outcome == FullTextRetry(asked=2, unavailable=2)
        assert agent.calls == []

    def test_why_a_text_could_not_be_read_is_said(self, storage: LiteStorage) -> None:
        """The classified cause and what to do, never a bare count."""
        reviewed(storage)

        outcome, _, _ = retry(storage, {"doc-1": "T1."}, {"doc-1": ConnectionError("down")})

        assert outcome.failures == (PassFailure(document_id="doc-1", cause=UNREACHABLE),)
        assert UNREACHABLE.description in retry_text(outcome)

    def test_a_failed_transparency_analysis_is_said(self, storage: LiteStorage) -> None:
        """The paper is still read; the reader learns its assessment is the old one."""
        reviewed(storage)

        def assess(doc: LiteDocument, text: str) -> None:
            raise ConnectionError("down")

        outcome, _, _ = retry(storage, {"doc-1": "T1."}, {"doc-1": ["New 1."]}, assess=assess)

        assert outcome.read == 1 and outcome.report == "New report."
        assert [f.document_id for f in outcome.transparency_failures] == ["doc-1"]
        assert "Transparency could not be analysed again for 1 paper" in retry_text(outcome)

    def test_the_report_states_check_agains_retraction_answers(
        self, storage: LiteStorage
    ) -> None:
        """Not the ones the report was first written with.

        A paper found under an expression of concern since keeps its warning.
        """
        checkpoint_id = reviewed(storage)
        stored = storage.get_checkpoint(checkpoint_id)
        storage.update_checkpoint(checkpoint_id, metadata={
            **stored.metadata,
            CHECKPOINT_RETRACTION_SNAPSHOT_KEY: [{
                "document_id": "doc-1", "status": RetractionStatus.CONCERN.value,
                "excluded": False, "title": "Aspirin trial 1",
            }],
        }, touch=False)

        _, _, reporter = retry(storage, {"doc-1": "T1."}, {"doc-1": ["New 1."]})

        screen = reporter.generate_report.call_args.args[2].retraction_screen
        assert [r["status"] for r in screen.to_snapshot()] == [RetractionStatus.CONCERN.value]
        kept = storage.get_checkpoint(checkpoint_id).metadata
        assert kept[CHECKPOINT_RETRACTION_SNAPSHOT_KEY][0]["document_id"] == "doc-1"

    def test_a_question_without_a_report_cannot_be_retried(self, storage: LiteStorage) -> None:
        """Said to the reader, not a crash."""
        with pytest.raises(RetryNotPossible, match=NO_REPORT_TEXT):
            retry(storage, {}, {})

    def test_a_run_from_before_cannot_be_written_again(self, storage: LiteStorage) -> None:
        """Without the metadata the methodology would be invented."""
        reviewed(storage, keep_metadata=False)

        with pytest.raises(RetryNotPossible) as refused:
            retry(storage, {}, {})
        assert str(refused.value) == NOT_KEPT_TEXT

    def test_nothing_to_ask_says_so(self, storage: LiteStorage) -> None:
        """Every qualifying paper already read."""
        checkpoint_id = reviewed(storage)
        storage.record_citation_reads(checkpoint_id, {"doc-1": True, "doc-3": True})

        outcome, agent, _ = retry(storage, {}, {})

        assert outcome == FullTextRetry() and agent.calls == []
        assert retry_text(outcome).startswith("Every paper scored high enough")


class TestTheRetryWorker:
    """Exactly one ending, and the reader's words, never the provider's (#330)."""

    def run_worker(self, monkeypatch: pytest.MonkeyPatch, retry: Any,
                   cancel: bool = False) -> tuple[dict[str, list[tuple[Any, ...]]], list[Any]]:
        """Run the worker in this thread over a scripted retry."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite import agents, full_text_retry
        from bmlibrarian_lite.gui.workers import FullTextRetryWorker

        monkeypatch.setattr(agents, "LiteCitationAgent", lambda **_: MagicMock())
        monkeypatch.setattr(agents, "LiteReportingAgent", lambda **_: MagicMock())
        monkeypatch.setattr(citation_full_texts, "full_text_fetcher", lambda config: None)
        passed: list[Any] = []

        def scripted(*args: Any) -> FullTextRetry:
            passed.append(args)
            if cancel:
                worker.cancel()
            return retry()

        monkeypatch.setattr(full_text_retry, "retry_full_texts", scripted)
        config = LiteConfig()
        config.transparency.enabled = False
        worker = FullTextRetryWorker(QUESTION, config, MagicMock())
        ended: dict[str, list[tuple[Any, ...]]] = {}
        for name in ("finished", "error", "cancelled"):
            getattr(worker, name).connect(
                lambda *args, name=name: ended.setdefault(name, []).append(args))
        worker.run()
        return ended, passed

    def test_a_retry_that_ran_finishes(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """With transparency off, nothing is analysed again."""
        outcome = FullTextRetry(asked=1, read=1, report="New report.")
        ended, passed = self.run_worker(monkeypatch, lambda: outcome)
        assert ended == {"finished": [(outcome,)]}
        assert passed[0][6] is None

    def test_a_retry_that_cannot_run_says_why(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The refusal's own sentence."""
        def refuse() -> FullTextRetry:
            raise RetryNotPossible(NOT_KEPT_TEXT)

        ended, _ = self.run_worker(monkeypatch, refuse)
        assert ended == {"error": [(NOT_KEPT_TEXT,)]}

    def test_a_failure_is_told_in_the_readers_words(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The provider's text can carry the key; it stays in the log."""
        def fail() -> FullTextRetry:
            raise ConnectionError("POST https://api?key=sk-secret refused")

        ended, _ = self.run_worker(monkeypatch, fail)
        [(message,)] = ended["error"]
        assert "sk-secret" not in message
        assert message == failure_cause_text(classify_analysis_exception(
            ConnectionError("POST https://api?key=sk-secret refused")))

    def test_a_failure_after_a_cancel_is_a_cancel_that_names_it(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Not an orderly stop, and not "every paper was already read"."""
        def fail() -> FullTextRetry:
            raise ConnectionError("down")

        ended, _ = self.run_worker(monkeypatch, fail, cancel=True)
        [(outcome, error)] = ended["cancelled"]
        assert outcome == FullTextRetry(cancelled=True) and error
        assert retry_text(outcome) == CANCELLED_TEXT

    def test_a_cancelled_retry_is_cancelled(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """With what it did before the cancel."""
        outcome = FullTextRetry(asked=2, read=1, cancelled=True)
        ended, _ = self.run_worker(monkeypatch, lambda: outcome)
        assert ended == {"cancelled": [(outcome, "")]}


# ---------------------------------------------------------------------------
# The cross-platform contract
# ---------------------------------------------------------------------------

CONTRACT = Path(__file__).resolve().parents[1] / "doc/cross_platform/llm_parity/text_windows.json"


class TestTheContract:
    """``text_windows.json`` is what Python does; Swift and Kotlin read it too."""

    def contract(self) -> dict[str, Any]:
        """The shared rows."""
        return json.loads(CONTRACT.read_text(encoding="utf-8"))

    def test_the_bounds_are_the_constants(self) -> None:
        """16,000 and 250, on every platform."""
        from bmlibrarian_lite.constants import TEXT_WINDOW_CHARS, TEXT_WINDOW_OVERLAP_CHARS

        contract = self.contract()
        assert (contract["window_chars"], contract["overlap_chars"]) == (
            TEXT_WINDOW_CHARS, TEXT_WINDOW_OVERLAP_CHARS)

    def test_each_window_case(self) -> None:
        """The windows, character for character."""
        rows = self.contract()["windows"]
        assert rows
        for row in rows:
            assert analysis_windows(
                row["text"], row["window_chars"], row["overlap_chars"]) == row["windows"], row["name"]

    def test_each_reference_case(self) -> None:
        """Where the reference list is cut."""
        rows = self.contract()["references"]
        assert rows
        for row in rows:
            assert without_references(row["text"]) == row["without_references"], row["name"]

    def test_each_merge_case(self) -> None:
        """Which passages the reduce keeps."""
        rows = self.contract()["merge"]
        assert rows
        for row in rows:
            kept = merged_window_citations([cite("1", p) for p in row["passages"]])
            assert [c.passage for c in kept] == row["kept"], row["name"]
