# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The COI path states no finding it never established (#352, #348, #351).

Three defects, one code path:

* **#352** ``coi_disclosed`` was ``report.coi_info.statement is not None``,
  and ``analyze_coi_statement(None)`` returned ``statement=""`` -- never
  ``None`` -- so the value was *always true*. Every study's badge read
  "Conflicts of Interest: Disclosed", including studies for which no COI
  statement was ever found, and including studies whose own report carried
  the contradictory "No conflict of interest statement found" risk
  indicator. ``missing_coi_triggers_downgrade`` (a user-facing setting,
  default on) and three branches in ``report_risk_helpers`` were dead code
  in consequence.
* **#348** the path fetched a ``resultType=core`` Europe PMC record once per
  document with no COI statement, never read the response -- a core result
  carries no conflict of interest field at all -- and then named Europe PMC
  among the report's data sources.
* **#351** the method that fetch called, ``EuropePMCClient.get_article``,
  answered "Europe PMC holds no record" and "we could not reach Europe PMC"
  with the same ``None``.

The rule is in ``doc/cross_platform/analysis_failure_reporting.md``: a
source we could not read is not a finding, and neither is a source nobody
read. The control tests matter as much as the fixes -- recording every study
as "not assessed" would satisfy every test about the unassessed path while
quietly retiring the whole COI analysis.

No test here touches the network.
"""

import json
import sqlite3
from datetime import datetime

import pytest

from bmlibrarian_lite.agents.report_risk_helpers import (
    build_risk_context_for_prompt,
    format_reference_risk_annotation,
)
from bmlibrarian_lite.analysis_failures import (
    coi_not_assessed_caveat,
    unassessed_caveat,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    RISK_INDICATOR_MISSING_COI_STATEMENT,
    COIDisclosureLevel,
    ConflictOfInterest,
    EuropePMCClient,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    analyze_coi_statement,
    calculate_transparency_score,
    coi_disclosure_summary,
)
from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_ASSESSED,
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
)

DISCLOSURE = "The authors declare no competing interests."


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    """An analyzer that makes no network call on construction."""
    return StudyTransparencyAnalyzer(
        email="test@example.com",
        use_browser_fallback=False,
        auto_discover_fulltext=False,
    )


class ExplodingSession:
    """A session that fails the test if anything asks it for a request."""

    def get(self, *_args, **_kwargs):
        """Refuse to make the request.

        Raises:
            AssertionError: Always.
        """
        raise AssertionError("the COI path must make no request here (#348)")


class TestTheThreeStatesAreNotCollapsible:
    """The ambiguity #352 is about is not representable."""

    def test_a_disclosure_needs_the_statement_it_came_from(self) -> None:
        """"Disclosed" with nothing to show for it is the original bug."""
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement="", disclosure_level=COIDisclosureLevel.DISCLOSED
            )

    def test_a_blank_statement_is_refused_even_when_it_is_whitespace(self) -> None:
        """A page of spaces is not a disclosure."""
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement="   \n ", disclosure_level=COIDisclosureLevel.DISCLOSED
            )

    def test_an_absence_cannot_carry_a_statement(self) -> None:
        """If a statement was read, the level is not an absence."""
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement=DISCLOSURE,
                disclosure_level=COIDisclosureLevel.NOT_STATED,
            )

    def test_an_unread_statement_concludes_nothing_about_industry(self) -> None:
        """A finding needs something it was found in."""
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement="",
                disclosure_level=COIDisclosureLevel.NOT_ASSESSED,
                has_industry_ties=True,
            )

    def test_an_unread_statement_carries_no_confidence(self) -> None:
        """Confidence in nothing is not zero-cost: the benchmark averages it."""
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement="",
                disclosure_level=COIDisclosureLevel.NOT_ASSESSED,
                confidence=0.5,
            )

    def test_not_stated_and_not_assessed_are_different_values(self) -> None:
        """The control for every test below: the two states are distinct."""
        assert (
            ConflictOfInterest.not_stated().disclosure_level
            is not ConflictOfInterest.not_assessed().disclosure_level
        )

    def test_analysing_an_absent_statement_is_refused(self) -> None:
        """Returning an empty disclosure for ``None`` is what started this."""
        with pytest.raises(ValueError):
            analyze_coi_statement("")

    def test_analysing_a_read_statement_still_works(self) -> None:
        """The control: a real statement is analysed as before."""
        info = analyze_coi_statement(DISCLOSURE)

        assert info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert info.has_industry_ties is False

    def test_a_disclosed_industry_tie_is_still_found(self) -> None:
        """The control that matters most: the analysis itself is unchanged."""
        info = analyze_coi_statement("Dr Smith has received fees from Pfizer.")

        assert info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert info.has_industry_ties is True


class TestWhatTheAnalyserRecords:
    """``_analyze_conflicts`` picks the state from what was actually read."""

    def test_nothing_read_is_not_assessed(self, analyzer) -> None:
        """No full text and no PubMed record establishes nothing."""
        report = TransparencyReport(doi="10.1/x")

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_a_pubmed_record_without_a_statement_is_not_assessed(
        self, analyzer
    ) -> None:
        """PubMed's silence is the publisher's, not the article's.

        Measured over samples of PubMed records, ``CoiStatement`` is present
        for 36.5% of 2018 articles and 79.7% of 2024 ones, so its absence
        does not mean the paper carries no disclosure.
        """
        report = TransparencyReport(pmid="1", pubmed_record_read=True)

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_the_article_read_without_a_statement_is_not_stated(
        self, analyzer
    ) -> None:
        """The control: the article's own answer is still a finding.

        Recording "not assessed" here as well would pass every test about
        the unassessed path and retire the COI analysis altogether.
        """
        report = TransparencyReport(pmid="1", pubmed_record_read=True)

        analyzer._analyze_conflicts(
            report, fulltext_sections={"methods": "..."}, fulltext_read=True
        )

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED

    def test_a_statement_in_the_full_text_is_read(self, analyzer) -> None:
        """The success control: a disclosure that arrived is used."""
        report = TransparencyReport(pmid="1")

        analyzer._analyze_conflicts(
            report, fulltext_sections={"coi": DISCLOSURE}, fulltext_read=True
        )

        assert report.coi_info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert report.coi_info.statement == DISCLOSURE

    def test_a_statement_from_pubmed_is_read(self, analyzer) -> None:
        """The second success control: PubMed's positive is a disclosure."""
        report = TransparencyReport(pmid="1", pubmed_record_read=True)
        report._coi_statement = DISCLOSURE

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert report.coi_info.statement == DISCLOSURE

    def test_a_blank_pubmed_statement_is_not_a_disclosure(self, analyzer) -> None:
        """An empty ``CoiStatement`` element is nothing, not a declaration."""
        report = TransparencyReport(pmid="1", pubmed_record_read=True)
        report._coi_statement = "   "

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_the_reader_is_told_when_nothing_was_read(self, analyzer) -> None:
        """Logging is not reporting (golden rule 8)."""
        report = TransparencyReport(doi="10.1/x")

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert any("not assessed" in w for w in report.warnings)

    def test_the_caveat_names_which_sources_were_asked(self, analyzer) -> None:
        """A reader deciding whether to open the PDF needs to know."""
        asked = TransparencyReport(pmid="1", pubmed_record_read=True)
        unasked = TransparencyReport(doi="10.1/x")

        analyzer._analyze_conflicts(asked, fulltext_sections={}, fulltext_read=False)
        analyzer._analyze_conflicts(unasked, fulltext_sections={}, fulltext_read=False)

        assert asked.warnings != unasked.warnings

    def test_a_finding_raises_no_caveat(self, analyzer) -> None:
        """The control: a study that was read is not caveated."""
        report = TransparencyReport(pmid="1", pubmed_record_read=True)

        analyzer._analyze_conflicts(
            report, fulltext_sections={"coi": DISCLOSURE}, fulltext_read=True
        )

        assert report.warnings == []

    def test_an_unread_statement_cannot_contradict_the_funding(
        self, analyzer
    ) -> None:
        """"COI does not mention industry ties" needs a COI statement.

        Industry funding plus an unread disclosure used to produce the
        warning that the disclosure omits the industry ties -- a claim about
        a document nobody had.
        """
        report = TransparencyReport(doi="10.1/x", industry_funding_detected=True)

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert not any("does not mention industry" in w for w in report.warnings)

    def test_a_read_statement_still_contradicts_the_funding(
        self, analyzer
    ) -> None:
        """The control: the cross-check survives for statements we have."""
        report = TransparencyReport(pmid="1", industry_funding_detected=True)

        analyzer._analyze_conflicts(
            report,
            fulltext_sections={"coi": DISCLOSURE},
            fulltext_read=True,
        )

        assert any("does not mention industry" in w for w in report.warnings)


class TestTheEuropePMCFetchIsGone:
    """#348 and #351: a request that read nothing, through an ambiguous API."""

    def test_the_coi_path_makes_no_europe_pmc_request(self, analyzer) -> None:
        """A core result carries no COI field, so the fetch bought nothing.

        It was made once per document with no COI statement, against a
        service paced at one request a second.
        """
        analyzer.europepmc.session = ExplodingSession()
        report = TransparencyReport(pmid="1", pmcid="PMC1")

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_europe_pmc_is_not_credited_for_contributing_nothing(
        self, analyzer
    ) -> None:
        """``data_sources_used`` is reader-facing provenance."""
        analyzer.europepmc.session = ExplodingSession()
        report = TransparencyReport(pmid="1", pmcid="PMC1")

        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)

        assert "Europe PMC" not in report.data_sources_used

    def test_the_ambiguous_get_article_no_longer_exists(self) -> None:
        """#351: its ``None`` meant "no record" and "unreachable" alike."""
        assert not hasattr(EuropePMCClient, "get_article")

    def test_the_full_text_fetch_is_still_there(self) -> None:
        """The control: the method that does report honestly is untouched."""
        assert hasattr(EuropePMCClient, "get_full_text_xml")


class TestWhatItCostsTheStudy:
    """A study is charged for what it did, not for what nobody checked."""

    def _report(self, coi_info: ConflictOfInterest) -> TransparencyReport:
        """A report carrying only a COI finding.

        Args:
            coi_info: The finding to score.

        Returns:
            The report.
        """
        return TransparencyReport(coi_info=coi_info)

    def test_not_assessed_costs_nothing(self) -> None:
        """UNKNOWN-style neutrality: the base score, unchanged."""
        score = calculate_transparency_score(
            self._report(ConflictOfInterest.not_assessed())
        )

        assert score == calculate_transparency_score(TransparencyReport())

    def test_not_stated_still_costs_five(self) -> None:
        """The control: the article's own absence is still a finding."""
        stated = calculate_transparency_score(
            self._report(ConflictOfInterest.not_stated())
        )
        assessed = calculate_transparency_score(
            self._report(ConflictOfInterest.not_assessed())
        )

        assert stated == assessed - 5

    def test_a_disclosure_still_earns_five(self) -> None:
        """The second control: credit for a statement is unchanged."""
        disclosed = calculate_transparency_score(
            self._report(analyze_coi_statement(DISCLOSURE))
        )
        assessed = calculate_transparency_score(
            self._report(ConflictOfInterest.not_assessed())
        )

        assert disclosed == assessed + 5


class TestWhatTheReaderIsTold:
    """No risk indicator is raised from a statement nobody read."""

    def _indicators(self, coi_info: ConflictOfInterest, analyzer) -> list[str]:
        """Run the risk indicator pass over one COI finding.

        Args:
            coi_info: The finding.
            analyzer: The analyzer whose pass to run.

        Returns:
            The indicators raised.
        """
        report = TransparencyReport(coi_info=coi_info)
        analyzer._identify_risk_indicators(report)
        return report.risk_of_bias_indicators

    def test_not_assessed_raises_no_missing_coi_indicator(self, analyzer) -> None:
        """A risk of bias drawn from an unread source is invented."""
        assert RISK_INDICATOR_MISSING_COI_STATEMENT not in self._indicators(
            ConflictOfInterest.not_assessed(), analyzer
        )

    def test_not_stated_still_raises_it(self, analyzer) -> None:
        """The control: the indicator is not simply gone."""
        assert RISK_INDICATOR_MISSING_COI_STATEMENT in self._indicators(
            ConflictOfInterest.not_stated(), analyzer
        )

    def test_a_disclosure_raises_it_for_nobody(self, analyzer) -> None:
        """The second control: a study that disclosed is not flagged."""
        assert RISK_INDICATOR_MISSING_COI_STATEMENT not in self._indicators(
            analyze_coi_statement(DISCLOSURE), analyzer
        )

    def test_the_summary_line_tells_the_three_apart(self) -> None:
        """"COI Disclosed: NO/None stated" said the same for two states."""
        lines = {
            coi_disclosure_summary(analyze_coi_statement(DISCLOSURE)),
            coi_disclosure_summary(ConflictOfInterest.not_stated()),
            coi_disclosure_summary(ConflictOfInterest.not_assessed()),
        }

        assert len(lines) == 3


class TestTheDowngradeSettingIsAliveAgain:
    """``missing_coi_triggers_downgrade`` was dead code while the bit was true."""

    class _Settings:
        """The two thresholds ``calculate_risk_level`` reads."""

        score_threshold = 40
        industry_funding_triggers_downgrade = True
        missing_coi_triggers_downgrade = True

    def _risk(self, coi_disclosure: str) -> TransparencyRisk:
        """Risk level for a transparent, well-scoring study.

        Args:
            coi_disclosure: The COI state to judge.

        Returns:
            The risk level.
        """
        return calculate_risk_level(
            score=90,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosure=coi_disclosure,
            settings=self._Settings(),
        )

    def test_not_assessed_downgrades_nothing(self) -> None:
        """Nothing was established, so nothing can be held against it."""
        assert self._risk(COI_NOT_ASSESSED) is TransparencyRisk.LOW

    def test_not_stated_downgrades_to_high(self) -> None:
        """The control: the setting does what its label promises."""
        assert self._risk(COI_NOT_STATED) is TransparencyRisk.HIGH

    def test_a_disclosure_downgrades_nothing(self) -> None:
        """The second control."""
        assert self._risk(COI_DISCLOSED) is TransparencyRisk.LOW

    def test_the_setting_still_switches_off(self) -> None:
        """The third control: an off switch that is on is not tested by this."""
        settings = self._Settings()
        settings.missing_coi_triggers_downgrade = False

        assert (
            calculate_risk_level(
                score=90,
                industry_funding=False,
                data_availability="full_open",
                coi_disclosure=COI_NOT_STATED,
                settings=settings,
            )
            is TransparencyRisk.LOW
        )


class TestWhatTheReportSays:
    """The report helpers no longer accuse a study nobody checked."""

    def _result(self, coi_disclosure: str) -> TransparencyResult:
        """A high-risk result differing only in its COI state.

        Args:
            coi_disclosure: The COI state.

        Returns:
            The result.
        """
        return TransparencyResult(
            document_id="doc-1",
            transparency_score=30,
            risk_level=TransparencyRisk.HIGH,
            coi_disclosure=coi_disclosure,
        )

    def test_an_unassessed_study_is_not_listed_as_undisclosed(self) -> None:
        """This text reaches the LLM writing the report, and the reader."""
        context = build_risk_context_for_prompt(
            {1: ("Smith et al.", self._result(COI_NOT_ASSESSED))}
        )

        assert "Conflicts of interest not disclosed" not in context

    def test_a_study_read_to_declare_nothing_still_is(self) -> None:
        """The control."""
        context = build_risk_context_for_prompt(
            {1: ("Smith et al.", self._result(COI_NOT_STATED))}
        )

        assert "Conflicts of interest not disclosed" in context

    def test_the_reference_annotation_makes_the_same_distinction(self) -> None:
        """Three call sites read the flag; all three had to move."""
        unassessed = format_reference_risk_annotation(self._result(COI_NOT_ASSESSED))
        not_stated = format_reference_risk_annotation(self._result(COI_NOT_STATED))

        assert "COI disclosure: Not stated" not in unassessed
        assert "COI disclosure: Not stated" in not_stated


class TestTheStoredValues:
    """The constants, the round trip, and the rows an older build wrote."""

    def test_the_stored_strings_match_the_enum(self) -> None:
        """``transparency_models`` copies them to avoid an import cycle."""
        assert {COI_DISCLOSED, COI_NOT_STATED, COI_NOT_ASSESSED} == {
            level.value for level in COIDisclosureLevel
        }

    def test_the_serialised_form_round_trips(self) -> None:
        """A caveat and a state that do not survive storage are not reporting."""
        result = TransparencyResult(
            document_id="doc-1",
            transparency_score=55,
            risk_level=TransparencyRisk.MEDIUM,
            coi_disclosure=COI_NOT_ASSESSED,
            warnings=["Nothing was read."],
            analyzed_at=datetime(2026, 1, 1),
        )

        restored = TransparencyResult.from_dict(result.to_dict())

        assert restored.coi_disclosure == COI_NOT_ASSESSED
        assert restored.warnings == ["Nothing was read."]

    def test_a_disclosure_round_trips_too(self) -> None:
        """The control: the state is stored, not defaulted."""
        result = TransparencyResult(
            document_id="doc-1",
            transparency_score=80,
            risk_level=TransparencyRisk.LOW,
            coi_disclosure=COI_DISCLOSED,
            analyzed_at=datetime(2026, 1, 1),
        )

        assert TransparencyResult.from_dict(result.to_dict()).coi_disclosure == (
            COI_DISCLOSED
        )


class TestTheStorageRoundTrip:
    """What the reader sees after a reload is what was stored.

    There was no test over ``save_transparency_result`` at all, so nothing
    would have noticed that ``warnings`` -- every caveat this slice and #346
    produce -- was serialised by ``to_dict`` and written to no column.
    """

    def _storage(self, tmp_path):
        """A real SQLite store in a temporary directory.

        Args:
            tmp_path: pytest's per-test directory.

        Returns:
            The store.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return LiteStorage(config)

    def _saved(self, tmp_path, **kwargs) -> TransparencyResult:
        """Save a result and read it back.

        Args:
            tmp_path: pytest's per-test directory.
            **kwargs: Fields overriding the defaults.

        Returns:
            The reloaded result.
        """
        storage = self._storage(tmp_path)
        fields = {
            "document_id": "doc-1",
            "transparency_score": 55,
            "risk_level": TransparencyRisk.MEDIUM,
            "analyzed_at": datetime(2026, 1, 1),
        }
        fields.update(kwargs)
        storage.save_transparency_result(TransparencyResult(**fields))
        return storage.get_transparency_result("doc-1")

    def test_not_assessed_survives_a_reload(self, tmp_path) -> None:
        """Otherwise the badge goes back to claiming a disclosure."""
        assert self._saved(
            tmp_path, coi_disclosure=COI_NOT_ASSESSED
        ).coi_disclosure == COI_NOT_ASSESSED

    def test_not_stated_survives_a_reload(self, tmp_path) -> None:
        """The control: the state is stored, not defaulted."""
        assert self._saved(
            tmp_path, coi_disclosure=COI_NOT_STATED
        ).coi_disclosure == COI_NOT_STATED

    def test_a_disclosure_survives_a_reload(self, tmp_path) -> None:
        """The second control."""
        assert self._saved(
            tmp_path, coi_disclosure=COI_DISCLOSED
        ).coi_disclosure == COI_DISCLOSED

    def test_the_caveats_survive_a_reload(self, tmp_path) -> None:
        """A caveat that cannot be read again is not reporting."""
        assert self._saved(
            tmp_path, warnings=["Europe PMC could not be read."]
        ).warnings == ["Europe PMC could not be read."]

    def test_the_batch_reader_agrees_with_the_single_one(self, tmp_path) -> None:
        """Two readers of the same row, and the grid uses the batch one."""
        storage = self._storage(tmp_path)
        storage.save_transparency_result(
            TransparencyResult(
                document_id="doc-1",
                transparency_score=55,
                risk_level=TransparencyRisk.MEDIUM,
                coi_disclosure=COI_NOT_ASSESSED,
                warnings=["Nothing was read."],
                analyzed_at=datetime(2026, 1, 1),
            )
        )

        batched = storage.get_transparency_results_batch(["doc-1"])["doc-1"]

        assert batched.coi_disclosure == COI_NOT_ASSESSED
        assert batched.warnings == ["Nothing was read."]


class TestTheMigration:
    """Rows written before this change say "disclosed" and mean nothing."""

    def _old_table(self, path) -> None:
        """Write a transparency_results table in the pre-#352 shape.

        Args:
            path: Where to create the database.
        """
        conn = sqlite3.connect(path)
        conn.execute(
            """
            CREATE TABLE transparency_results (
                document_id TEXT PRIMARY KEY,
                transparency_score INTEGER NOT NULL,
                risk_level TEXT NOT NULL,
                industry_funding_detected INTEGER NOT NULL DEFAULT 0,
                industry_funding_confidence REAL DEFAULT 0.0,
                data_availability_level TEXT DEFAULT 'unknown',
                coi_disclosed INTEGER DEFAULT 1,
                trial_registered INTEGER DEFAULT 0,
                trial_results_compliant INTEGER DEFAULT 0,
                outcome_switching_detected INTEGER DEFAULT 0,
                risk_indicators TEXT,
                tier_downgrade_applied INTEGER DEFAULT 0,
                analyzed_at TEXT NOT NULL,
                analyzer_version TEXT DEFAULT '1.0',
                full_text_analyzed INTEGER DEFAULT 0
            )
            """
        )
        conn.execute(
            "INSERT INTO transparency_results (document_id, transparency_score, "
            "risk_level, coi_disclosed, risk_indicators, analyzed_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            ("old-doc", 60, "medium", 1, json.dumps([]), datetime(2026, 1, 1).isoformat()),
        )
        conn.commit()
        conn.close()

    def _migrate(self, path) -> sqlite3.Connection:
        """Run the migration the way ``LiteStorage`` does, and reopen.

        Args:
            path: The database to migrate.

        Returns:
            An open connection with row access by name.
        """
        from bmlibrarian_lite.storage import LiteStorage

        storage = LiteStorage.__new__(LiteStorage)
        storage._storage_config = type("Cfg", (), {"sqlite_path": path})()
        storage._migrate_transparency_coi_and_warnings()
        conn = sqlite3.connect(path)
        conn.row_factory = sqlite3.Row
        return conn

    def test_the_fabricated_column_is_dropped(self, tmp_path) -> None:
        """Left behind, a later reader picks the always-1 value back up."""
        path = tmp_path / "old.db"
        self._old_table(path)

        conn = self._migrate(path)
        columns = {row["name"] for row in conn.execute(
            "PRAGMA table_info(transparency_results)"
        )}
        conn.close()

        assert "coi_disclosed" not in columns

    def test_an_old_row_reads_as_not_assessed(self, tmp_path) -> None:
        """A bit that was 1 for every row carries no information."""
        path = tmp_path / "old.db"
        self._old_table(path)

        conn = self._migrate(path)
        row = conn.execute(
            "SELECT coi_disclosure FROM transparency_results WHERE document_id = ?",
            ("old-doc",),
        ).fetchone()
        conn.close()

        assert (row["coi_disclosure"] or COI_NOT_ASSESSED) == COI_NOT_ASSESSED

    def test_the_caveats_gain_somewhere_to_live(self, tmp_path) -> None:
        """``warnings`` was serialised by ``to_dict`` and stored nowhere."""
        path = tmp_path / "old.db"
        self._old_table(path)

        conn = self._migrate(path)
        columns = {row["name"] for row in conn.execute(
            "PRAGMA table_info(transparency_results)"
        )}
        conn.close()

        assert "warnings" in columns

    def test_the_row_itself_survives(self, tmp_path) -> None:
        """The control: a migration that empties the table passes the rest."""
        path = tmp_path / "old.db"
        self._old_table(path)

        conn = self._migrate(path)
        row = conn.execute(
            "SELECT transparency_score FROM transparency_results "
            "WHERE document_id = ?",
            ("old-doc",),
        ).fetchone()
        conn.close()

        assert row["transparency_score"] == 60


class TestTheWiringItself:
    """The facts reach the decision, and the decision reaches the report.

    Without these, a mutation that stops ``analyze`` passing on whether the
    full text was read -- or stops ``_fetch_basic_metadata`` recording that
    PubMed answered -- leaves every test above passing while every study in
    the library goes back to one state.
    """

    def _quiet(self, analyzer) -> None:
        """Silence the clients so ``analyze`` makes no request.

        Args:
            analyzer: The analyzer to stub.
        """
        analyzer.pubmed.fetch_article = lambda pmid: None
        analyzer.pubmed.convert_ids = lambda *a, **k: {}
        analyzer.crossref.get_work = lambda doi: None
        analyzer.clinicaltrials.get_study = lambda nct: None
        analyzer.europepmc.session = ExplodingSession()

    def test_reading_the_article_reaches_the_decision(self, analyzer) -> None:
        """A full text without a COI section is the article's own answer."""
        self._quiet(analyzer)

        report = analyzer.analyze(doi="10.1/x", fulltext="# Methods\n\nWe did things.")

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED

    def test_not_reading_it_reaches_the_decision(self, analyzer) -> None:
        """The control: the same call without a full text establishes nothing."""
        self._quiet(analyzer)

        report = analyzer.analyze(doi="10.1/x")

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_a_pubmed_answer_is_recorded_as_read(self, analyzer) -> None:
        """``pubmed_record_read`` is what the caveat's two forms turn on."""
        analyzer.crossref.get_work = lambda doi: None
        analyzer.pubmed.fetch_article = lambda pmid: {"title": "A study"}

        report = TransparencyReport(pmid="1")
        analyzer._fetch_basic_metadata(report)

        assert report.pubmed_record_read is True

    def test_no_pubmed_answer_is_not(self, analyzer) -> None:
        """The control: an efetch that yielded no article read nothing (#250)."""
        analyzer.crossref.get_work = lambda doi: None
        analyzer.pubmed.fetch_article = lambda pmid: None
        analyzer.pubmed.convert_ids = lambda *a, **k: {}

        report = TransparencyReport(pmid="1")
        analyzer._fetch_basic_metadata(report)

        assert report.pubmed_record_read is False


class TestTheCaveatText:
    """Pure, testable without the network, and carrying no provider text."""

    def test_both_reasons_end_in_the_same_reassurance(self) -> None:
        """The reader must not read a caveat as a finding."""
        for asked in (True, False):
            assert coi_not_assessed_caveat(asked).endswith(
                "It is recorded as not assessed, which is not a finding "
                "against the study."
            )

    def test_the_two_reasons_differ(self) -> None:
        """A study PubMed was asked about and one it was not are different."""
        assert coi_not_assessed_caveat(True) != coi_not_assessed_caveat(False)

    def test_a_pubmed_record_that_was_read_is_named(self) -> None:
        """So the reader knows the PDF is the remaining place to look."""
        assert "PubMed record" in coi_not_assessed_caveat(True)

    def test_the_sentence_shape_is_shared(self) -> None:
        """One shape, so the "not a finding" promise cannot drift."""
        assert unassessed_caveat("Something failed", "the thing").endswith(
            "It is recorded as not assessed, which is not a finding "
            "against the study."
        )
