# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A missing statement is charged only when every end-matter heading is known (#428).

Once some end matter was recognised, the analyser charged a missing competing
interests or data availability statement -- five points and a risk
indicator -- unless the text used the statement's wording somewhere. A
statement under a heading the analyser does not know, worded in a way the
word list does not know either, was charged as absent. Diabetologia's
"Authors' relationships and activities" was one, listing pharmaceutical
ties; each such heading was added by name, leaving the next journal in the
same hole.

Now the JATS converter marks where the end matter begins, and the charge
needs every heading after the mark to be classified: a statement's, a known
neighbour's ("Publisher's note"), a part of the other statement, or a
catch-all or subsection whose text avoids the statement's vocabulary. A
text with no mark -- text extracted from a PDF -- is not charged at all.

Every fixture keeps the shape of a real article, named beside it. The
controls matter as much as the fixes: a fully classified end matter is still
charged, or the rule would retire the finding altogether.

No test here touches the network.
"""

import re

import pytest

from bmlibrarian_lite.jats_markdown import (
    END_MATTER_MARKER,
    JATS_MARKDOWN_CONVERTER_VERSION,
    jats_to_markdown,
)
from bmlibrarian_lite.study_transparency_analyzer.statement_headings import (
    COI_VOCABULARY_RE,
    DATA_VOCABULARY_RE,
    EndMatterSection,
    end_matter_sections,
    segment_unmarked_end_matter,
    statement_key_of_heading,
    unclassified_headings,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    END_MATTER_NOT_SEGMENTED,
    COIDisclosureLevel,
    DataDisclosureLevel,
    StudyTransparencyAnalyzer,
    end_matter_unrecognised_clause,
    extract_fulltext_sections,
)

#: The body every fixture shares.
BODY = """<body>
  <sec><title>Introduction</title><p>Background prose.</p></sec>
  <sec><title>Methods</title><p>Methods prose.</p></sec>
</body>"""

#: A reference list, so the end matter has something after it.
REFS = """<ref-list><ref><mixed-citation>Smith J. A paper. 2020.</mixed-citation></ref></ref-list>"""


def _article(back: str = "", body: str = BODY, front_extra: str = "") -> str:
    """A JATS article with the given back matter, body and front extras."""
    return f"""<article article-type="research-article"><front>
  <article-meta><title-group><article-title>T</article-title></title-group>
  {front_extra}
  <abstract><p>Abstract prose.</p></abstract></article-meta></front>
  {body}
  <back>{back}</back></article>"""


def _marked(end_matter: str, body: str = "## Methods\n\nWe did things.") -> str:
    """A full text as the converter writes it: body, mark, end matter."""
    return f"{body}\n\n{END_MATTER_MARKER}\n\n{end_matter}"


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    """An analyser whose lookups answer nothing and touch no network."""
    instance = StudyTransparencyAnalyzer(
        email="test@example.com", auto_discover_fulltext=False
    )
    instance._fetch_basic_metadata = lambda report: None
    instance._fetch_funder_info = lambda report: None
    instance._fetch_trial_info = lambda report: None
    return instance


# ---------------------------------------------------------------------------
# The converter marks where the end matter begins
# ---------------------------------------------------------------------------


class TestTheConverterMarksTheEndMatter:
    """The mark is the only way the analyser can tell end matter from body."""

    def test_the_mark_comes_after_the_body_and_before_the_back_matter(self) -> None:
        """Body, then the mark, then the statements."""
        back = "<ack><title>Acknowledgments</title><p>We thank all.</p></ack>" + REFS
        markdown = jats_to_markdown(_article(back))
        assert markdown.index("Methods prose.") < markdown.index(END_MATTER_MARKER)
        assert markdown.index(END_MATTER_MARKER) < markdown.index("## Acknowledgments")

    def test_front_matter_statements_come_after_the_mark(self) -> None:
        """PLOS keeps its competing interests footnote in the front matter."""
        front = """<author-notes><fn fn-type="COI-statement"><p>The authors have declared
          that no competing interests exist.</p></fn></author-notes>"""
        markdown = jats_to_markdown(_article(REFS, front_extra=front))
        assert markdown.index(END_MATTER_MARKER) < markdown.index("## Competing Interests")

    def test_an_article_without_end_matter_has_no_mark(self) -> None:
        """Nothing to mark: a mark before nothing would vouch for nothing."""
        assert END_MATTER_MARKER not in jats_to_markdown(_article(REFS))

    def test_end_matter_in_the_body_is_marked_where_it_begins(self) -> None:
        """A haematology journal (PMC12337216) keeps its footnotes in the body.

        Its competing interests statement, "利益冲突", stood before a mark
        placed only at the back matter, so its unknown heading was never
        looked at and the study was charged for a statement it printed.
        """
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec sec-type="fn-group"><title>Footnotes</title><fn-group>
            <fn><p><bold>利益冲突</bold> 所有作者声明无利益冲突</p></fn>
          </fn-group></sec></body>"""
        markdown = jats_to_markdown(_article(REFS, body=body))
        assert markdown.index(END_MATTER_MARKER) < markdown.index("利益冲突")
        assert markdown.index("Methods prose.") < markdown.index(END_MATTER_MARKER)

    def test_a_run_in_opening_the_end_matter_is_after_the_mark(self) -> None:
        """An untitled <notes> in the body whose first paragraph is empty.

        The empty paragraph gives the container no heading and renders to
        nothing, so the first piece rendered is the run-in paragraph after it.
        """
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <notes><p/><p><bold>Relationships with industry:</bold> AB reports fees.</p></notes>
          </body>"""
        markdown = jats_to_markdown(_article(REFS, body=body))
        assert markdown.index(END_MATTER_MARKER) < markdown.index("Relationships with industry")

    def test_the_converter_version_moved(self) -> None:
        """A cached conversion without the mark must be converted again."""
        assert JATS_MARKDOWN_CONVERTER_VERSION == 4


class TestTheMarkIsNoPartOfAStatement:
    """The extractor steps over the mark: it neither joins nor ends a section."""

    def test_a_body_statement_before_the_mark_does_not_take_it_in(self) -> None:
        """A data statement ending the body stops at the next heading, mark unread."""
        text = _marked("## Funding\n\nNIH.", body="## Data availability\n\nIn Dryad.")
        assert extract_fulltext_sections(text)["data_sharing"] == "In Dryad."

    def test_a_mark_inside_a_section_does_not_end_it(self) -> None:
        """A titled body section wrapping an untitled <ack> is still read."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Acknowledgments</title><ack><p>We thank all.</p></ack></sec></body>"""
        sections = extract_fulltext_sections(jats_to_markdown(_article(REFS, body=body)))
        assert sections["acknowledgments"] == "We thank all."


# ---------------------------------------------------------------------------
# Reading the end matter
# ---------------------------------------------------------------------------


class TestEndMatterSections:
    """What the classification is asked about."""

    def test_a_text_without_the_mark_has_no_known_end_matter(self) -> None:
        """Text extracted from a PDF: its end matter cannot be told from its body."""
        assert end_matter_sections("Methods\nWe did things.\nFunding\nNIH.") is None

    def test_the_pdf_segmenter_is_a_stub_for_now(self) -> None:
        """Where a model-based segmentation of PDF text will go; until then, unknown."""
        assert segment_unmarked_end_matter("Funding\nNIH.\nNotes\nText.") is None

    def test_a_heading_holding_no_text_is_not_asked_about(self) -> None:
        """BMC's "Declarations" wrapper holds only its subsections."""
        text = _marked("## Declarations\n\n### Funding\n\nNIH.\n\n### Ethics approval\n\nGiven.")
        sections = end_matter_sections(text)
        assert [section.words for section in sections] == ["Funding", "Ethics approval"]

    def test_a_subsection_knows_its_ancestors(self) -> None:
        """Cureus heads each author role under "Author Contributions"."""
        text = _marked("## Author Contributions\n\n### Supervision\n\nAB")
        (section,) = end_matter_sections(text)
        assert section.ancestors == ("## Author Contributions",)

    def test_the_first_mark_opens_the_end_matter(self) -> None:
        """End matter in the body is marked, and so is the back matter after it."""
        text = (f"## Methods\n\nProse.\n\n{END_MATTER_MARKER}\n\n## Footnotes\n\nA note.\n\n"
                f"{END_MATTER_MARKER}\n\n## Funding\n\nNIH.")
        assert [s.words for s in end_matter_sections(text)] == ["Footnotes", "Funding"]

    def test_body_headings_are_not_asked_about(self) -> None:
        """Only what follows the mark is end matter."""
        text = _marked("## Funding\n\nNIH.", body="## Results\n\nFindings.")
        assert [s.words for s in end_matter_sections(text)] == ["Funding"]


class TestWhichHeadingsAreClassified:
    """The classification each heading gets, for each statement sought."""

    @staticmethod
    def _unclassified(markdown: str, sought: str) -> tuple[str, ...]:
        """The unclassified headings of a marked end matter."""
        return unclassified_headings(end_matter_sections(_marked(markdown)), sought)

    @pytest.mark.parametrize("heading", [
        "Publisher's note", "Publisher’s Note", "Disclaimer/Publisher’s Note",
        "Institutional Review Board Statement", "Informed Consent Statement",
        "Ethics statement", "Generative AI statement", "Abbreviations",
        "Supplementary Material", "ORCID iDs", "Correspondence",
        "Contributor Information", "References", "Clinical trial registration",
        "Patient consent statement", "List of acronyms",
        "Use of artificial intelligence (AI)-assisted technology for manuscript preparation",
    ])
    def test_a_known_neighbour_is_classified(self, heading: str) -> None:
        """Headings from the survey whose name says what they hold."""
        assert self._unclassified(f"## {heading}\n\nText.", "coi") == ()

    def test_an_unknown_heading_is_not(self) -> None:
        """A journal's own name for its statement is exactly what is sought."""
        assert self._unclassified("## Industry relationships\n\nAB reports fees.", "coi") == (
            "Industry relationships",
        )

    @pytest.mark.parametrize("heading", ["Appendix A", "Declarations"])
    def test_a_heading_that_can_hold_a_statement_is_not_a_neighbour(self, heading: str) -> None:
        """Left out of the list on purpose."""
        assert self._unclassified(f"## {heading}\n\nText.", "coi") == (heading,)

    def test_a_catch_all_avoiding_the_vocabulary_is_classified(self) -> None:
        """The converter's "Author Notes" holding only a corresponding author."""
        assert self._unclassified("## Author Notes\n\nCorresponding author.", "coi") == ()

    def test_a_catch_all_using_the_vocabulary_is_not(self) -> None:
        """PMC12805416: "The author discloses no conflicts of research interest."."""
        markdown = "## Author Notes\n\nThe author discloses no conflicts of research interest."
        assert self._unclassified(markdown, "coi") == ("Author Notes",)

    def test_the_vocabulary_is_the_statement_sought(self) -> None:
        """RSC's footnote names where the data are, and nothing of conflicts."""
        markdown = "## Footnotes\n\nElectronic supplementary information (ESI) available."
        assert self._unclassified(markdown, "coi") == ()
        assert self._unclassified(markdown, "data_sharing") == ("Footnotes",)

    def test_a_subsection_of_a_known_section_is_known_by_its_text(self) -> None:
        """Cureus's author roles: names only."""
        markdown = "## Author Contributions\n\n### Supervision\n\nAB, CD"
        assert self._unclassified(markdown, "coi") == ()

    def test_a_subsection_using_the_vocabulary_is_not(self) -> None:
        """What the extractor reads as part of a statement could hide another."""
        markdown = "## Acknowledgments\n\n### Industry\n\nAB received speaker fees."
        assert self._unclassified(markdown, "coi") == ("Industry",)

    def test_a_subsection_of_an_unknown_section_is_not_classified_by_it(self) -> None:
        """Only a named section lends its subsections the text test."""
        markdown = "## Appendix A\n\nSee below.\n\n### Details\n\nNames only."
        assert self._unclassified(markdown, "coi") == ("Appendix A", "Details")

    def test_a_part_of_the_other_statement_is_classified(self) -> None:
        """Cureus heads the three parts of the ICMJE form as siblings of its COI run-in."""
        markdown = ("### Financial relationships\n\nAll authors have declared none.\n\n"
                    "### Payment/services info\n\nNo financial support was received.")
        assert self._unclassified(markdown, "data_sharing") == ()

    def test_a_part_of_the_statement_sought_is_not(self) -> None:
        """Under it is that statement, in a shape the extractor did not recognise."""
        markdown = "### Financial relationships\n\nAB reports fees from Pfizer."
        assert self._unclassified(markdown, "coi") == ("Financial relationships",)

    def test_a_neighbours_name_must_be_the_whole_heading(self) -> None:
        """A heading that only opens with a neighbour's name is not that neighbour."""
        heading = "Publisher's note and the authors' relationships with industry"
        assert self._unclassified(f"## {heading}\n\nText.", "coi") == (heading,)

    def test_a_statement_heading_the_extractor_skips_is_no_statement(self) -> None:
        """The extractor reads no heading line past its length limit; nor does this."""
        line = "##" + " " * 130 + "Funding"
        assert extract_fulltext_sections(f"{line}\n\nNIH.") == {}
        assert statement_key_of_heading(line) is None

    def test_each_vocabulary_covers_its_own_statement(self) -> None:
        """A sanity check on the two word lists, each against its statement."""
        assert COI_VOCABULARY_RE.search("The authors declare no competing interests.")
        assert COI_VOCABULARY_RE.search("所有作者声明无利益冲突")
        assert DATA_VOCABULARY_RE.search("Data are available on request.")
        assert not DATA_VOCABULARY_RE.search("Corresponding author.")

    def test_economic_prose_is_not_disclosure_vocabulary(self) -> None:
        """Springer economics footnotes (held-out survey): rates and returns, no disclosure."""
        prose = ("Interest rates follow the financial cycle; stock returns and equity "
                 "prices are deflated, and employment is measured quarterly.")
        assert not COI_VOCABULARY_RE.search(prose)
        assert COI_VOCABULARY_RE.search("No relevant financial interests to disclose.")


class TestHeadingsTheSurveyFound:
    """Statement headings the #428 survey found unrecognised."""

    @pytest.mark.parametrize("heading, key", [
        ("Funding sources", "funding"),
        ("Funding information", "funding"),
        ("Funding/Support", "funding"),
        ("Role of the Funder/Sponsor", "funding_role"),
        ("Authors' contributions", "contributors"),
        ("Authors’ contributions", "contributors"),
        ("Financial support & sponsorship", "funding"),
        ("Declaration of sources of funding", "funding"),
        ("Research data transparency and availability", "data_sharing"),
    ])
    def test_the_heading_is_recognised(self, heading: str, key: str) -> None:
        """Each names its statement."""
        assert statement_key_of_heading(f"## {heading}") == key
        assert extract_fulltext_sections(f"## {heading}\n\nText.") == {key: "Text."}


# ---------------------------------------------------------------------------
# What the analyser records
# ---------------------------------------------------------------------------


class TestTheAnalyserChargesOnlyAClassifiedEndMatter:
    """The rule, end to end through ``analyze``."""

    def test_an_unknown_heading_is_not_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """A statement under a journal's own heading, in words the guard does not know."""
        text = _marked("## Funding\n\nNIH.\n\n## Industry relationships\n\nAB reports fees from Pfizer.")
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        clause = end_matter_unrecognised_clause(("Industry relationships",))
        assert any(w.startswith(clause + ", so this study's conflict") for w in report.warnings)

    def test_a_classified_end_matter_is_still_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Control: every heading known, so the silence is the article's."""
        text = _marked("## Funding\n\nNIH.\n\n## Publisher's note\n\nClaims are not endorsed.\n\n"
                       "## Author Notes\n\nCorresponding author.")
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED
        assert report.data_availability.disclosure_level is DataDisclosureLevel.NOT_STATED
        assert not report.warnings

    def test_a_statement_in_a_catch_all_is_not_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """An author note naming ties, in no wording the guard knows."""
        text = _marked("## Funding\n\nNIH.\n\n## Author Notes\n\nAB received speaker fees from Pfizer.")
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        assert report.data_availability.disclosure_level is DataDisclosureLevel.NOT_STATED

    def test_the_data_statement_follows_the_same_rule(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """RSC Advances: "ESI available" in a footnote is where the data are."""
        text = _marked("## Funding\n\nNIH.\n\n## Footnotes\n\nElectronic supplementary information "
                       "(ESI) available. See DOI: 10.1039/x.\n\n## Competing Interests\n\nNone.")
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.data_availability.disclosure_level is DataDisclosureLevel.UNKNOWN
        clause = end_matter_unrecognised_clause(("Footnotes",))
        assert any(w.startswith(clause + ", so this study's data availability") for w in report.warnings)

    def test_unmarked_text_is_not_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Text extracted from a PDF: not assessed, and the caveat says why."""
        text = "Methods\nWe did things.\n\nFunding\nNIH grant R01.\n\nAcknowledgments\nWe thank all."
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        assert report.data_availability.disclosure_level is DataDisclosureLevel.UNKNOWN
        caveats = [w for w in report.warnings if w.startswith(END_MATTER_NOT_SEGMENTED + ", so")]
        assert len(caveats) == 2

    def test_a_statement_found_in_unmarked_text_is_still_read(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """Control: the rule is about absence; a statement found is read as ever."""
        text = "Methods\nProse.\n\nConflict of interest\nThe authors declare none.\n\nFunding\nNIH."
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.DISCLOSED

    def test_a_statement_in_body_end_matter_is_not_charged(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """PMC12337216, converted: its "利益冲突" statement is no longer charged as absent."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Funding Statement</title><p>National Natural Science Foundation.</p></sec>
          <sec sec-type="fn-group"><title>Footnotes</title><fn-group>
            <fn><p><bold>利益冲突</bold> 所有作者声明无利益冲突</p></fn>
          </fn-group></sec></body>"""
        report = analyzer.analyze(pmid="1", fulltext=jats_to_markdown(_article(REFS, body=body)))
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        assert any('"利益冲突"' in w for w in report.warnings)

    @pytest.mark.parametrize("sentence", [
        "Commercial relationships: none.",
        "The author discloses no conflicts of research interest.",
    ])
    def test_the_surveys_wording_is_not_charged(
        self, analyzer: StudyTransparencyAnalyzer, sentence: str
    ) -> None:
        """ARVO's plain-text form inside its acknowledgments, and PMC12805416's."""
        text = _marked(f"## Acknowledgments\n\nWe thank all. {sentence}")
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED


class TestTheReviewOfTheRule:
    """Three ways the first draft still charged a statement the article printed."""

    #: Back matter the converter marks, so that the article is read as marked.
    BACK = "<ack><title>Acknowledgments</title><p>We thank all.</p></ack>" + REFS

    def test_an_unheaded_footnote_in_a_titled_body_section_is_asked_about(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """The marker falls inside the section; its text is that section's."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Author statement</title><fn-group><fn><p>AB received consulting
          fees and speaker honoraria from Pfizer.</p></fn></fn-group></sec></body>"""
        text = jats_to_markdown(_article(self.BACK, body=body))
        assert [s.words for s in end_matter_sections(text)][0] == "Author statement"
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_an_unheaded_footnote_under_footnotes_is_known_by_its_text(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """Under a catch-all, the vocabulary decides: fees from Pfizer is a disclosure."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Footnotes</title><fn-group><fn><p>AB received consulting fees
          from Pfizer.</p></fn></fn-group></sec></body>"""
        report = analyzer.analyze(pmid="1", fulltext=jats_to_markdown(_article(self.BACK, body=body)))
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_an_innocent_unheaded_footnote_is_still_charged(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """Control: a footnote that discloses nothing leaves the charge standing."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Footnotes</title><fn-group><fn><p>Presented at a conference in
          Freiburg.</p></fn></fn-group></sec></body>"""
        report = analyzer.analyze(pmid="1", fulltext=jats_to_markdown(_article(self.BACK, body=body)))
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED

    def test_text_with_no_heading_at_all_is_known_by_its_text(self) -> None:
        """Nothing above the marker to continue: filed as unheaded, vocabulary decides."""
        text = f"{END_MATTER_MARKER}\n\nAB reports speaker fees.\n\n## Funding\n\nNIH."
        assert unclassified_headings(end_matter_sections(text), "coi") == (
            "text without a heading",
        )
        innocent = f"{END_MATTER_MARKER}\n\nPresented in Freiburg.\n\n## Funding\n\nNIH."
        assert unclassified_headings(end_matter_sections(innocent), "coi") == ()

    def test_a_statement_section_in_the_body_opens_the_end_matter(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """Body sections "Funding" and a disclosure heading nobody knows, then back matter."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Funding</title><p>NIH.</p></sec>
          <sec><title>Authors' disclosures of potential conflicts</title>
          <p>AB reports consulting fees from Pfizer.</p></sec></body>"""
        text = jats_to_markdown(_article(self.BACK, body=body))
        words = [s.words for s in end_matter_sections(text)]
        assert words[:2] == ["Funding", "Authors' disclosures of potential conflicts"]
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_known_body_statements_before_the_marker_are_still_charged(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """Control: a body "Funding" section and nothing unknown after it."""
        body = """<body><sec><title>Methods</title><p>Methods prose.</p></sec>
          <sec><title>Funding</title><p>NIH.</p></sec></body>"""
        report = analyzer.analyze(pmid="1", fulltext=jats_to_markdown(_article(self.BACK, body=body)))
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED

    @pytest.mark.parametrize("heading", ["Disclaimer", "Author disclaimer", "Biography",
                                         "Notes on contributors"])
    def test_a_heading_that_may_hold_a_disclosure_is_known_by_its_text(self, heading: str) -> None:
        """"The authors have no financial relationships to disclose" as a disclaimer."""
        disclosing = f"## {heading}\n\nThe authors have no financial relationships to disclose."
        innocent = f"## {heading}\n\nThe views expressed are the authors' own."
        assert unclassified_headings(end_matter_sections(_marked(disclosing)), "coi") == (heading,)
        assert unclassified_headings(end_matter_sections(_marked(innocent)), "coi") == ()


class TestTheCaveatNamesTheHeadings:
    """The reader is told which heading stopped the charge."""

    def test_one_heading(self) -> None:
        """Singular, quoted."""
        assert end_matter_unrecognised_clause(("Appendix A",)) == (
            'The article\'s end matter holds a section this analysis does not '
            'recognise ("Appendix A")'
        )

    def test_several_headings(self) -> None:
        """Plural, each quoted, in order."""
        clause = end_matter_unrecognised_clause(("利益冲突", "作者贡献声明"))
        assert re.search(r'holds sections .* \("利益冲突", "作者贡献声明"\)$', clause)

    def test_the_unsegmented_caveat_does_not_blame_a_pdf_alone(self) -> None:
        """A converted article whose statements are body sections has no mark either."""
        assert "PDF" not in END_MATTER_NOT_SEGMENTED


def test_an_end_matter_section_names_its_words() -> None:
    """The caveat quotes a heading without its ``#`` marks."""
    assert EndMatterSection("### Supervision", "AB").words == "Supervision"
