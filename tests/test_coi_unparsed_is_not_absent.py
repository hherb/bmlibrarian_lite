# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A heading we failed to recognise is not the article declaring nothing (#359).

The review of PR #358 found the "unreachable is not absent" family one layer
down. #352 stopped charging a study for a source nobody read, and in doing so
made ``missing_coi_triggers_downgrade`` live for the first time -- on master
``coi_disclosed`` was always true, so the downgrade was dead code. What fed
that newly live downgrade was a fully anchored heading regex:

* "Declaration of Competing Interest" -- Elsevier's standard heading -- and
  "Conflict of Interest Statement" -- the standard PMC/JATS one -- both
  missed, so a paper disclosing industry ties was recorded ``NOT_STATED``,
  charged five points, given "No conflict of interest statement found" and
  forced to HIGH risk.

Two changes answer it, and both are pinned here: the patterns recognise the
real-world spellings, and a full text in which *no* end-matter section was
recognised is recorded as not assessed rather than as the article's answer.

The controls matter as much as the fixes. Widening a regex until everything
matches, or recording "not assessed" whenever the parse is imperfect, would
each pass every test about the defect while retiring the analysis. So a
heading that is merely prose about conflicts must still not match, and an
article whose end matter *was* read must still reach ``NOT_STATED`` with its
five-point charge and its indicator.

No test here touches the network.
"""

import dataclasses
import json
import sqlite3
import types
from datetime import datetime

import pytest

from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    RISK_INDICATOR_MISSING_COI_STATEMENT,
    COIDisclosureLevel,
    ConflictOfInterest,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    calculate_transparency_score,
    extract_fulltext_sections,
)
from bmlibrarian_lite.transparency import COI_NOT_ASSESSED, COI_NOT_STATED

#: Headings real journals actually print above a disclosure. Every one of
#: these is a live article's end matter, not a synthetic fixture: the repo
#: has been caught before by fixtures that agreed with the parser.
REAL_COI_HEADINGS = (
    "Declaration of Competing Interest",
    "Declaration of competing interests",
    "Conflict of Interest Statement",
    "Conflicts of Interest Statement",
    "COI statement",
    "Disclosure statement",
    "Conflict-of-interest disclosure",
    "Competing Interests",
    "Conflict of interest",
    "Declaration of interests",
    "Conflicts of Interest",
    "Disclosures",
    "Potential Conflicts of Interest",
    "Author Disclosures",
    "Competing financial interests",
)

DISCLOSURE = "Dr X reports personal fees from Pfizer and Novartis."


def _article(heading: str) -> str:
    """Build an article whose disclosure sits under ``heading``.

    Args:
        heading: The end-matter heading to print above the disclosure.

    Returns:
        Plain-text article content.
    """
    return (
        f"Methods\n\nWe did things.\n\n"
        f"Funding\n\nNIH grant R01.\n\n"
        f"{heading}\n\n{DISCLOSURE}\n\nReferences\n"
    )


class TestTheHeadingsRealJournalsPrint:
    """The extractor has to recognise the disclosure to read it."""

    @pytest.mark.parametrize("heading", REAL_COI_HEADINGS)
    def test_the_disclosure_is_found(self, heading: str) -> None:
        """Seven of these missed before #359, including the two commonest.

        Args:
            heading: The end-matter heading under test.
        """
        assert extract_fulltext_sections(_article(heading)).get("coi") == DISCLOSURE

    @pytest.mark.parametrize(
        "prose",
        [
            "Conflict of interest in surgical decision making",
            "Disclosures of the funding agencies were reviewed by the board",
            "We declare that competing interests were considered throughout",
        ],
    )
    def test_prose_about_conflicts_is_not_a_heading(self, prose: str) -> None:
        """The control: widening until everything matches finds nothing.

        A sentence that merely mentions conflicts would drag body text in as
        the disclosure, and ``analyze_coi_statement`` would grade it.

        Args:
            prose: A line that mentions conflicts without being a heading.
        """
        article = f"Intro\n\nx\n\n{prose}\n\nbody text\n\nReferences\n"
        assert not extract_fulltext_sections(article).get("coi")

    def test_the_data_availability_heading_is_found_too(self) -> None:
        """The same anchor hid the commonest data availability spelling."""
        article = (
            "Intro\n\nx\n\nData Availability Statement\n\n"
            "Data are in Dryad.\n\nReferences\n"
        )
        assert extract_fulltext_sections(article).get("data_sharing")


class TestWhatAnUnsegmentedFullTextRecords:
    """Full text that arrived is not the same as full text we could read."""

    @pytest.fixture
    def analyzer(self) -> StudyTransparencyAnalyzer:
        """An analyzer with nothing wired to the network.

        Returns:
            An uninitialised analyzer, for calling ``_analyze_conflicts`` on.
        """
        return StudyTransparencyAnalyzer.__new__(StudyTransparencyAnalyzer)

    def test_no_end_matter_recognised_is_not_assessed(self, analyzer) -> None:
        """The parse came up empty, so the parse is what we report."""
        report = TransparencyReport(pmid="1", pubmed_record_read=True)

        analyzer._analyze_conflicts(
            report, fulltext_sections={"methods": "..."}, fulltext_read=True
        )

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        assert any("end matter" in w for w in report.warnings)

    def test_end_matter_recognised_still_reaches_not_stated(self, analyzer) -> None:
        """The control: a read article that declares nothing still says so.

        Recording "not assessed" whenever the COI section is absent would
        pass the test above and retire the finding altogether.
        """
        report = TransparencyReport(pmid="1", pubmed_record_read=True)

        analyzer._analyze_conflicts(
            report,
            fulltext_sections={"funding": "NIH grant R01."},
            fulltext_read=True,
        )

        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED
        assert not report.warnings

    def test_the_not_stated_charge_survives(self, analyzer) -> None:
        """The control, priced: NOT_STATED still costs five points."""
        read = TransparencyReport(pmid="1")
        read.coi_info = ConflictOfInterest.not_stated()
        unread = TransparencyReport(pmid="1")
        unread.coi_info = ConflictOfInterest.not_assessed()

        assert calculate_transparency_score(read) == (
            calculate_transparency_score(unread) - 5
        )

    def test_the_not_stated_indicator_survives(self, analyzer) -> None:
        """The control: the article's own absence is still flagged."""
        read = TransparencyReport(pmid="1")
        read.coi_info = ConflictOfInterest.not_stated()
        unread = TransparencyReport(pmid="1")
        unread.coi_info = ConflictOfInterest.not_assessed()

        analyzer._identify_risk_indicators(read)
        analyzer._identify_risk_indicators(unread)

        assert RISK_INDICATOR_MISSING_COI_STATEMENT in read.risk_of_bias_indicators
        assert (
            RISK_INDICATOR_MISSING_COI_STATEMENT
            not in unread.risk_of_bias_indicators
        )

    def test_an_elsevier_paper_is_read_not_charged(self, analyzer) -> None:
        """End to end: the case the review found, through the real extractor.

        Before #359 this exact article was recorded as declaring no
        conflicts, charged five points and forced to HIGH risk.
        """
        sections = extract_fulltext_sections(
            _article("Declaration of Competing Interest")
        )
        report = TransparencyReport(pmid="1")

        analyzer._analyze_conflicts(report, sections, fulltext_read=True)

        assert report.coi_info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert report.coi_info.has_industry_ties


class TestTheReportSerialises:
    """A report that will not serialise is a report nobody downstream reads."""

    def test_to_dict_carries_the_level_as_a_string(self) -> None:
        """``asdict`` leaves enums alone, and ``coi_info`` is always set now."""
        report = TransparencyReport(pmid="1")
        report.coi_info = ConflictOfInterest.not_assessed()

        assert report.to_dict()["coi_info"]["disclosure_level"] == COI_NOT_ASSESSED

    def test_a_disclosed_report_is_json_serialisable(self) -> None:
        """The CLI's ``--output json`` raised TypeError for every report."""
        report = TransparencyReport(pmid="1")
        report.coi_info = ConflictOfInterest(
            statement=DISCLOSURE,
            disclosure_level=COIDisclosureLevel.DISCLOSED,
            has_industry_ties=True,
            confidence=0.8,
        )

        restored = json.loads(json.dumps(report.to_dict()))

        assert restored["coi_info"]["disclosure_level"] == "disclosed"


class TestTheObjectCannotBeTalkedOutOfItsInvariants:
    """``__post_init__`` is worth only as much as the object's lifetime."""

    def test_a_disclosure_cannot_be_relabelled_as_unread(self) -> None:
        """Mutation rebuilt the #352 shape in reverse."""
        coi = ConflictOfInterest(
            statement=DISCLOSURE, disclosure_level=COIDisclosureLevel.DISCLOSED
        )

        with pytest.raises(dataclasses.FrozenInstanceError):
            coi.disclosure_level = COIDisclosureLevel.NOT_ASSESSED

    def test_a_callers_list_cannot_grow_a_relationship_later(self) -> None:
        """The list was aliased, so a later append edited the finding."""
        relationships = ["Pfizer"]
        coi = ConflictOfInterest(
            statement=DISCLOSURE,
            disclosure_level=COIDisclosureLevel.DISCLOSED,
            disclosed_relationships=relationships,
        )

        relationships.append("injected later")

        assert coi.disclosed_relationships == ("Pfizer",)

    @pytest.mark.parametrize("confidence", [-5.0, 1.5, 42.0])
    def test_a_disclosed_confidence_outside_the_range_is_refused(
        self, confidence: float
    ) -> None:
        """The early return let a disclosed 42.0 through; the benchmark averages it.

        Args:
            confidence: An out-of-range confidence.
        """
        with pytest.raises(ValueError):
            ConflictOfInterest(
                statement=DISCLOSURE,
                disclosure_level=COIDisclosureLevel.DISCLOSED,
                confidence=confidence,
            )

    def test_a_valid_confidence_is_still_accepted(self) -> None:
        """The control: the range check must not refuse real analyses."""
        coi = ConflictOfInterest(
            statement=DISCLOSURE,
            disclosure_level=COIDisclosureLevel.DISCLOSED,
            confidence=0.76,
        )

        assert coi.confidence == 0.76


class TestTheUpgradeAUserActuallyExperiences:
    """The migration through ``LiteStorage``, not through its own method."""

    @staticmethod
    def _old_database(path) -> None:
        """Write a pre-#352 table carrying the fabricated indicator.

        Args:
            path: Where to create the database.
        """
        conn = sqlite3.connect(path)
        conn.execute(
            """
            CREATE TABLE transparency_results (
                document_id TEXT PRIMARY KEY,
                transparency_score REAL NOT NULL,
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
            (
                "old-doc",
                60.0,
                "high",
                1,
                json.dumps(
                    [
                        RISK_INDICATOR_MISSING_COI_STATEMENT,
                        "Industry funding detected",
                    ]
                ),
                datetime(2026, 1, 1).isoformat(),
            ),
        )
        conn.commit()
        conn.close()

    @staticmethod
    def _storage_over(path) -> LiteStorage:
        """Attach a storage object to an existing database file.

        Args:
            path: The database to open.

        Returns:
            A ``LiteStorage`` wired to that file.
        """
        storage = LiteStorage.__new__(LiteStorage)
        storage._storage_config = types.SimpleNamespace(sqlite_path=path)
        return storage

    def test_the_retracted_claim_is_removed_from_the_indicators(
        self, tmp_path
    ) -> None:
        """The badge renders indicators verbatim beside "Not assessed".

        Dropping the column but leaving the sentence shows a clinician the
        retracted claim next to its own retraction.
        """
        path = tmp_path / "old.db"
        self._old_database(path)
        storage = self._storage_over(path)

        storage._migrate_transparency_results()
        result = storage.get_transparency_result("old-doc")

        assert result.coi_disclosure == COI_NOT_ASSESSED
        assert RISK_INDICATOR_MISSING_COI_STATEMENT not in result.risk_indicators

    def test_the_other_indicators_are_kept(self, tmp_path) -> None:
        """The control: only the COI sentence was unestablished."""
        path = tmp_path / "old.db"
        self._old_database(path)
        storage = self._storage_over(path)

        storage._migrate_transparency_results()

        assert "Industry funding detected" in storage.get_transparency_result(
            "old-doc"
        ).risk_indicators

    def test_running_it_twice_changes_nothing(self, tmp_path) -> None:
        """Every start runs it; the second must be a no-op."""
        path = tmp_path / "old.db"
        self._old_database(path)
        storage = self._storage_over(path)

        storage._migrate_transparency_results()
        first = storage.get_transparency_result("old-doc")
        storage._migrate_transparency_results()

        assert storage.get_transparency_result("old-doc") == first


class TestWhatAStoredRowIsAllowedToSay:
    """Golden rule 1: a row is data, and the badge shows it to a clinician."""

    @staticmethod
    def _storage() -> LiteStorage:
        """A storage object with no database behind it.

        Returns:
            A ``LiteStorage`` for calling the pure readers on.
        """
        return LiteStorage.__new__(LiteStorage)

    def test_an_unrecognised_disclosure_reads_as_not_assessed(self) -> None:
        """A typo used to be title-cased into the tooltip as a finding."""
        assert (
            self._storage()._stored_coi_disclosure("Not_Stated", "doc")
            == COI_NOT_ASSESSED
        )

    def test_a_known_disclosure_is_passed_through(self) -> None:
        """The control: coercing everything would erase the distinction."""
        assert (
            self._storage()._stored_coi_disclosure(COI_NOT_STATED, "doc")
            == COI_NOT_STATED
        )

    def test_an_unreadable_json_column_does_not_take_down_the_batch(self) -> None:
        """One corrupt cache row used to lose a whole review's citations."""
        values, readable = self._storage()._stored_json_list(
            "{not json", "doc", "warnings"
        )

        assert values == []
        assert not readable

    def test_a_readable_json_column_is_returned(self) -> None:
        """The control: returning [] unconditionally would drop every caveat."""
        values, readable = self._storage()._stored_json_list(
            json.dumps(["a caveat"]), "doc", "warnings"
        )

        assert values == ["a caveat"]
        assert readable

    def test_an_empty_column_is_readable_not_lost(self) -> None:
        """The control: a study really can have no indicators."""
        assert self._storage()._stored_json_list(None, "doc", "warnings") == ([], True)

    def test_an_unreadable_column_earns_the_reader_a_caveat(self) -> None:
        """An empty list off a broken column is an absence nobody established.

        Logging it is not enough when the badge then shows a clinician "no
        risk indicators" for a study whose indicators simply would not parse.
        """
        row = {
            "document_id": "doc",
            "risk_indicators": "{not json",
            "warnings": json.dumps(["an earlier caveat"]),
        }

        indicators, caveats = LiteStorage._stored_transparency_lists(row)

        assert indicators == []
        assert "an earlier caveat" in caveats
        assert any("could not be read" in c for c in caveats)

    def test_readable_columns_earn_no_caveat(self) -> None:
        """The control: a caveat on every row would be noise, not reporting."""
        row = {
            "document_id": "doc",
            "risk_indicators": json.dumps(["Industry funding detected"]),
            "warnings": json.dumps([]),
        }

        indicators, caveats = LiteStorage._stored_transparency_lists(row)

        assert indicators == ["Industry funding detected"]
        assert caveats == []
