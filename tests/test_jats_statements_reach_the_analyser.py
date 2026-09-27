# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A statement the article prints must reach the analyser under its heading (#420).

The JATS converter used to keep the front matter's title, authors and
abstract, the body and the reference list, and nothing else. The competing
interests, data availability and funding statements that journals put in
``<back>`` -- and that PLOS puts in ``<front>`` -- never reached the markdown,
so the analyser recognised no section, and since #386 such an article is
rated as though its full text had not been read. A 2026-09-27 survey of 150
PLOS ONE research articles found the competing interests statement
recognised in none of them.

Every fixture below keeps the shape of a real article, named beside it. The
controls matter as much as the fixes: a corresponding author's address is
not a statement, a Publisher's note is not part of the competing interests
statement before it, and an italic citation opening a footnote is not a
heading.

No test here touches the network.
"""

import pytest

from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.jats_markdown import (
    JATS_MARKDOWN_CONVERTER_VERSION,
    jats_to_markdown,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    COIDisclosureLevel,
    DataDisclosureLevel,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    extract_fulltext_sections,
)

#: The body every fixture shares, so that a statement found is one the
#: fixture's own front or back matter supplied.
BODY = """<body>
  <sec><title>Introduction</title><p>Background prose.</p></sec>
  <sec><title>Methods</title><p>Methods prose.</p></sec>
</body>"""

#: A reference list, so the tests can check statements come before it.
REFS = """<ref-list><ref><mixed-citation>Smith J. A paper. 2020.</mixed-citation></ref></ref-list>"""


def _article(front_extra: str = "", back: str = "", body: str = BODY) -> str:
    """A JATS article with the given front-matter extras and back matter."""
    return f"""<article article-type="research-article"><front>
  <journal-meta><journal-title-group><journal-title>J</journal-title></journal-title-group></journal-meta>
  <article-meta><title-group><article-title>T</article-title></title-group>
  {front_extra}
  <abstract><p>Abstract prose.</p></abstract></article-meta></front>
  {body}
  <back>{back}</back></article>"""


def _sections(xml: str) -> dict[str, str]:
    """What the analyser recognises in the converted article."""
    return extract_fulltext_sections(jats_to_markdown(xml))


# ---------------------------------------------------------------------------
# PLOS: the statements live in the front matter
# ---------------------------------------------------------------------------

#: PLOS ONE since 2023 (PMC10659153): a typed competing interests footnote,
#: a titled <notes> data statement, and a <funding-statement>.
PLOS_CURRENT_FRONT = """
<author-notes>
  <fn fn-type="COI-statement" id="coi001"><p><bold>Competing Interests: </bold>The authors have declared that no competing interests exist.</p></fn>
  <fn fn-type="other" id="econtrib001"><p>‡ LLL and LFCP also contributed equally to this work.</p></fn>
  <corresp id="cor001">* E-mail: <email>someone@example.org</email></corresp>
</author-notes>
<funding-group><award-group id="award001"><funding-source><institution>CAPES</institution></funding-source></award-group>
  <funding-statement>This research was financed in part by CAPES, Finance Code 001.</funding-statement></funding-group>
<notes notes-type="article-notes"><sec sec-type="history"><p>Received 2023 May 2; Accepted 2023 Nov 6.</p></sec></notes>
<notes><title>Data Availability</title><p>All relevant data are within the manuscript.</p></notes>
"""

#: PLOS ONE before 2023 (PMC10659152): an untyped footnote whose only
#: heading is its bold run-in.
PLOS_OLDER_FRONT = """
<author-notes>
  <fn id="coi001"><p><bold>Competing Interests: </bold>The author has declared that no competing interests exist.</p></fn>
  <fn id="cor001"><label>✉</label><p>* E-mail: <email>someone@example.org</email></p></fn>
</author-notes>
"""


class TestPlosFrontMatterStatements:
    """PLOS keeps its statements in ``<front>``, which was never rendered."""

    def test_the_current_competing_interests_footnote_is_recognised(self) -> None:
        """The current competing interests footnote is recognised."""
        sections = _sections(_article(PLOS_CURRENT_FRONT, REFS))
        assert sections["coi"] == (
            "The authors have declared that no competing interests exist."
        )

    def test_the_current_data_statement_is_recognised(self) -> None:
        """The current data statement is recognised."""
        sections = _sections(_article(PLOS_CURRENT_FRONT, REFS))
        assert sections["data_sharing"] == "All relevant data are within the manuscript."

    def test_the_funding_statement_is_recognised(self) -> None:
        """The funding statement is recognised."""
        sections = _sections(_article(PLOS_CURRENT_FRONT, REFS))
        assert sections["funding"] == (
            "This research was financed in part by CAPES, Finance Code 001."
        )

    def test_the_older_run_in_heading_is_recognised(self) -> None:
        """The older bold run-in heading is recognised."""
        sections = _sections(_article(PLOS_OLDER_FRONT, REFS))
        assert sections["coi"] == (
            "The author has declared that no competing interests exist."
        )

    def test_the_run_in_heading_is_not_repeated_in_the_statement(self) -> None:
        """The run-in heading is not repeated in the statement."""
        markdown = jats_to_markdown(_article(PLOS_OLDER_FRONT, REFS))
        assert "## Competing Interests\n\nThe author has declared" in markdown
        assert "**Competing Interests:**" not in markdown

    def test_footnotes_without_a_heading_are_kept_as_author_notes(self) -> None:
        """Kept, and not read as a statement: BMJ's bare "None declared." lives here."""
        xml = _article(PLOS_CURRENT_FRONT, REFS)
        markdown = jats_to_markdown(xml)
        assert "## Author Notes\n\n‡ LLL and LFCP also contributed equally" in markdown
        assert "someone@example.org" not in markdown  # <corresp> is not a note
        sections = _sections(xml)
        assert "contributed equally" not in " ".join(sections.values())

    def test_the_article_history_is_left_out(self) -> None:
        """Control: PLOS's untitled front <notes> is history, not a statement."""
        markdown = jats_to_markdown(_article(PLOS_CURRENT_FRONT, REFS))
        assert "Received 2023" not in markdown

    def test_award_metadata_alone_is_not_a_funding_statement(self) -> None:
        """Control: an <award-group> is metadata, not the article's words.

        A ``funding`` section counts as evidence that the end matter was
        read, and with it a missing COI statement is charged; it must come
        from text the article printed.
        """
        front = """<funding-group><award-group><funding-source>
          <institution>CAPES</institution></funding-source></award-group></funding-group>"""
        assert "funding" not in _sections(_article(front, REFS))

    def test_statements_come_after_the_body_and_before_the_references(self) -> None:
        """Statements come after the body and before the references."""
        markdown = jats_to_markdown(_article(PLOS_CURRENT_FRONT, REFS))
        body = markdown.index("Methods prose.")
        coi = markdown.index("## Competing Interests")
        refs = markdown.index("## References")
        assert body < coi < refs

    def test_a_statement_already_in_the_body_is_not_repeated(self) -> None:
        """A statement already in the body is not repeated."""
        body = """<body><sec><title>Funding</title>
          <p>This research was financed in part by CAPES, Finance Code 001.</p></sec></body>"""
        markdown = jats_to_markdown(_article(PLOS_CURRENT_FRONT, REFS, body=body))
        assert markdown.count("financed in part by CAPES") == 1


# ---------------------------------------------------------------------------
# Back matter: where most journals put their statements
# ---------------------------------------------------------------------------

#: Frontiers (2025): titled back-matter <sec>s in a fixed order, with a
#: Publisher's note straight after the competing interests statement. The
#: note mentions a "manufacturer", which INDUSTRY_KEYWORDS matches.
FRONTIERS_BACK = """
<sec><title>Data availability statement</title><p>The raw data will be made available by the authors.</p></sec>
<sec><title>Funding</title><p>The author(s) declare that no financial support was received.</p></sec>
<sec><title>Conflict of interest</title><p>The authors declare that the research was conducted in the absence of any commercial or financial relationships that could be construed as a potential conflict of interest.</p></sec>
<sec><title>Publisher's note</title><p>Any product that may be evaluated in this article, or claim that may be made by its manufacturer, is not guaranteed or endorsed by the publisher.</p></sec>
""" + REFS

#: ACS (PMC12044553, PMC13235547): untitled <notes> typed by notes-type.
ACS_BACK = """
<notes notes-type="data-availability"><p>The raw data has been deposited at NCBI/SRA (PRJNA1022459).</p></notes>
<notes notes-type="COI-statement" id="notes3"><p>The authors declare no competing financial interest.</p></notes>
""" + REFS

#: BMC: a titled "Declarations" section whose statements are subsections.
BMC_BACK = """
<sec><title>Declarations</title>
  <sec><title>Ethics approval</title><p>Approved by the committee.</p></sec>
  <sec><title>Competing interests</title><p>The authors declare no competing interests.</p></sec>
</sec>""" + REFS

#: Springer/Elsevier footnotes: an untitled <fn-group> of run-ins.
FOOTNOTE_BACK = """
<fn-group>
  <fn><p><bold>Funding:</bold> Supported by grant 123.</p></fn>
  <fn fn-type="COI-statement"><p><bold>Conflict of Interest</bold> None declared.</p></fn>
  <fn><p><bold>Disclaimer/Publisher’s Note:</bold> The statements are solely those of the authors.</p></fn>
  <fn><p><italic>Hippiatrica Berolinensia</italic> is cited from the 1935 edition.</p></fn>
</fn-group>""" + REFS


class TestBackMatterStatements:
    """Everything in ``<back>`` but the reference list used to be dropped."""

    def test_a_titled_back_section_is_recognised(self) -> None:
        """A titled back section is recognised."""
        sections = _sections(_article(back=FRONTIERS_BACK))
        assert sections["data_sharing"] == "The raw data will be made available by the authors."

    def test_the_publishers_note_is_not_read_as_the_coi_statement(self) -> None:
        """The Publisher's note is not read as the COI statement."""
        coi = _sections(_article(back=FRONTIERS_BACK))["coi"]
        assert coi.startswith("The authors declare that the research was conducted")
        assert "manufacturer" not in coi

    def test_an_untitled_typed_notes_is_recognised(self) -> None:
        """An untitled <notes> typed by notes-type is recognised."""
        sections = _sections(_article(back=ACS_BACK))
        assert sections["coi"] == "The authors declare no competing financial interest."
        assert sections["data_sharing"].startswith("The raw data has been deposited")

    def test_a_statement_nested_in_declarations_is_recognised(self) -> None:
        """A statement nested in declarations is recognised."""
        coi = _sections(_article(back=BMC_BACK))["coi"]
        assert coi == "The authors declare no competing interests."

    def test_footnote_run_ins_head_their_statements(self) -> None:
        """Footnote run-ins head their statements."""
        sections = _sections(_article(back=FOOTNOTE_BACK))
        assert sections["funding"] == "Supported by grant 123."
        # The stated type names the heading; the printed one is kept, bold.
        assert sections["coi"] == "**Conflict of Interest** None declared."

    def test_an_italic_citation_is_not_a_heading(self) -> None:
        """Control: italic openings in the surveyed footnotes are cited titles."""
        markdown = jats_to_markdown(_article(back=FOOTNOTE_BACK))
        assert "# Hippiatrica" not in markdown
        assert "*Hippiatrica Berolinensia* is cited" in markdown

    def test_an_italic_paragraph_is_not_a_heading(self) -> None:
        """Control: only a bold paragraph standing alone is read as a heading."""
        back = """<fn-group><fn><p><italic>Published online 1 May 2025.</italic></p></fn>
          </fn-group>""" + REFS
        markdown = jats_to_markdown(_article(back=back))
        assert "# Published online" not in markdown
        assert "*Published online 1 May 2025.*" in markdown

    def test_an_untitled_ack_gets_its_heading(self) -> None:
        """An untitled <ack> gets its heading."""
        back = "<ack><p>We thank the participants.</p></ack>" + REFS
        sections = _sections(_article(back=back))
        assert sections["acknowledgments"] == "We thank the participants."

    def test_an_ack_wrapping_titled_sections_gets_no_empty_heading(self) -> None:
        """Control: some publishers wrap their declarations in an untitled <ack>."""
        back = """<ack><sec><title>Ethics approval</title><p>Approved.</p></sec>
          <sec><title>Acknowledgements</title><p>We thank the participants.</p></sec></ack>""" + REFS
        markdown = jats_to_markdown(_article(back=back))
        assert "## Acknowledgments" not in markdown
        assert _sections(_article(back=back))["acknowledgments"] == "We thank the participants."

    def test_a_glossary_is_rendered_as_definitions(self) -> None:
        """A glossary is rendered as definitions."""
        back = """<glossary><title>Abbreviations</title><def-list>
          <def-item><term>BMI</term><def><p>body mass index</p></def></def-item>
        </def-list></glossary>""" + REFS
        assert "- BMI: body mass index" in jats_to_markdown(_article(back=back))

    def test_the_references_are_still_last(self) -> None:
        """The references are still last."""
        markdown = jats_to_markdown(_article(back=FRONTIERS_BACK))
        assert markdown.rstrip().endswith("- Smith J. A paper. 2020.")


# ---------------------------------------------------------------------------
# The body: order and nesting
# ---------------------------------------------------------------------------


class TestBodyOrder:
    """The body used to be walked as ``.//sec``: out of order and twice over."""

    NESTED = """<body><p>Lead paragraph.</p>
      <sec><title>Methods</title><p>M.</p><sec><title>Sub</title><p>S.</p></sec></sec></body>"""

    def test_paragraphs_before_the_first_section_are_kept(self) -> None:
        """Paragraphs before the first section are kept."""
        markdown = jats_to_markdown(_article(body=self.NESTED))
        assert markdown.index("Lead paragraph.") < markdown.index("## Methods")

    def test_a_nested_section_is_rendered_once(self) -> None:
        """A nested section is rendered once."""
        markdown = jats_to_markdown(_article(body=self.NESTED))
        assert markdown.count("Sub") == 1
        assert "### Sub\n\nS." in markdown

    def test_a_body_of_unknown_wrappers_still_yields_its_paragraphs(self) -> None:
        """A body of unknown wrappers still yields its paragraphs."""
        body = "<body><unknown-wrapper><p>Only prose.</p></unknown-wrapper></body>"
        assert "Only prose." in jats_to_markdown(_article(body=body))

    def test_the_client_delegates_to_the_converter(self) -> None:
        """The client delegates to the converter."""
        xml = _article(PLOS_CURRENT_FRONT, REFS)
        assert EuropePMCClient().xml_to_markdown(xml) == jats_to_markdown(xml)

    def test_the_converter_version_moved(self) -> None:
        """Cached markdown from before #420 must not be read as current."""
        assert JATS_MARKDOWN_CONVERTER_VERSION >= 2


# ---------------------------------------------------------------------------
# The extractor: where a section ends
# ---------------------------------------------------------------------------


class TestSectionBoundaries:
    """A markdown heading at a section's level or above ends it."""

    def test_an_unrecognised_sibling_heading_ends_the_section(self) -> None:
        """An unrecognised sibling heading ends the section."""
        text = "## Conflict of interest\n\nNone.\n\n## Generative AI statement\n\nNo AI was used."
        assert extract_fulltext_sections(text)["coi"] == "None."

    def test_a_subsection_does_not_end_its_section(self) -> None:
        """Cureus: the COI run-in sits inside a subsection of "Disclosures"."""
        text = (
            "## Disclosures\n\n### Human subjects\n\nConsent was obtained.\n\n"
            "**Conflicts of interest:** The authors declare none.\n\n## References\n"
        )
        coi = extract_fulltext_sections(text)["coi"]
        assert "The authors declare none." in coi

    def test_a_plain_text_heading_still_runs_to_the_next_recognised_one(self) -> None:
        """Control: PDF text has no markdown headings, and is read as before."""
        text = "Conflict of interest\nNone declared.\nAuthor notes\nMore text.\nFunding\nGrant 1."
        sections = extract_fulltext_sections(text)
        assert sections["coi"] == "None declared. Author notes More text."
        assert sections["funding"] == "Grant 1."

    @pytest.mark.parametrize(
        "heading",
        [
            "Acknowledgements",
            "ACKNOWLEDGEMENTS",
            "Acknowledgement",
            "Acknowledgments",
        ],
    )
    def test_both_spellings_of_acknowledgments_are_recognised(self, heading: str) -> None:
        """Both spellings of acknowledgments are recognised."""
        assert extract_fulltext_sections(f"## {heading}\n\nThanks.")["acknowledgments"] == "Thanks."

    @pytest.mark.parametrize(
        "heading",
        [
            "Declaration of Conflicts of Interest",
            "Potential Competing Interests",
            "Conflicts of interest and source of funding",
        ],
    )
    def test_coi_headings_found_in_the_survey_are_recognised(self, heading: str) -> None:
        """COI headings found in the survey are recognised."""
        assert extract_fulltext_sections(f"## {heading}\n\nNone.")["coi"] == "None."


# ---------------------------------------------------------------------------
# The analyser: an article read in full is rated as read
# ---------------------------------------------------------------------------


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


class TestAPlosArticleIsRatedAsRead:
    """The harm #420 names: a PLOS article read in full, rated as unread."""

    def test_its_full_text_counts_as_analysed(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Its full text counts as analysed."""
        markdown = jats_to_markdown(_article(PLOS_CURRENT_FRONT, REFS))
        report: TransparencyReport = analyzer.analyze(pmid="1", fulltext=markdown)
        assert report.full_text_analyzed

    def test_its_statements_are_the_articles_own(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Its statements are the articles own."""
        markdown = jats_to_markdown(_article(PLOS_CURRENT_FRONT, REFS))
        report: TransparencyReport = analyzer.analyze(pmid="1", fulltext=markdown)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.DISCLOSED
        assert not report.coi_info.has_industry_ties
        # How "within the manuscript" is classified is the data classifier's
        # question, not this one: what matters here is that the statement
        # was read, rather than recorded as not stated or not assessed.
        assert report.data_availability.statement == (
            "All relevant data are within the manuscript."
        )
        assert not any("data availability" in w for w in report.warnings)

    def test_a_restricted_data_statement_is_classified(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Control: a statement the classifier knows moves the level."""
        front = PLOS_CURRENT_FRONT.replace(
            "All relevant data are within the manuscript.",
            "Data are available from the corresponding author on reasonable request.",
        )
        report = analyzer.analyze(pmid="1", fulltext=jats_to_markdown(_article(front, REFS)))
        assert report.data_availability.disclosure_level is not DataDisclosureLevel.UNKNOWN


# ---------------------------------------------------------------------------
# The review of #420: recognising more end matter makes a missed statement
# cost the study five points, so every statement shape it found is pinned.
# ---------------------------------------------------------------------------


class TestNoStatementIsMissedIntoACharge:
    """A funding section recognised beside a COI statement missed is a false charge."""

    @pytest.mark.parametrize("fn_type", [' fn-type="COI-statement"', ""], ids=["typed", "untyped"])
    def test_a_short_statement_is_not_dropped_as_a_duplicate(self, fn_type: str) -> None:
        """ABCD Arq Bras Cir Dig (PMC13543687): "None" also answered the funding."""
        front = f"""<author-notes><fn{fn_type}><p><bold>Conflict of interests:</bold> None</p></fn></author-notes>"""
        back = "<sec><title>Financial source</title><p>None</p></sec>" + REFS
        coi = _sections(_article(front, back))["coi"]
        assert coi.endswith("None")

    def test_a_typed_statement_under_an_unrecognised_heading_is_found(self) -> None:
        """Springer (PMC13529850): the slash defeats every anchored COI pattern."""
        back = """<notes notes-type="COI-statement"><title>Conflicts of interest/Competing interests</title>
          <p>The authors declare no competing interests.</p></notes>""" + REFS
        markdown = jats_to_markdown(_article(back=back))
        assert "## Competing Interests\n\n**Conflicts of interest/Competing interests**" in markdown
        assert _sections(_article(back=back))["coi"].endswith("declare no competing interests.")

    def test_a_typed_statement_in_another_language_is_found(self) -> None:
        """Journal der DDG (PMC12697329): a German title on a COI-statement sec."""
        body = """<body><sec><title>Methoden</title><p>Prosa.</p></sec>
          <sec sec-type="COI-statement"><title>INTERESSENKONFLIKT</title><p>Keiner.</p></sec></body>"""
        assert _sections(_article(body=body))["coi"] == "**INTERESSENKONFLIKT** Keiner."

    def test_a_typed_wrapper_does_not_rename_its_sections(self) -> None:
        """Control: a typed "Declarations" wrapper keeps its subsections' own headings."""
        back = """<sec sec-type="COI-statement"><title>Declarations</title>
          <sec><title>Funding</title><p>Pfizer funded this work.</p></sec>
          <sec><title>Competing interests</title><p>None.</p></sec></sec>""" + REFS
        sections = _sections(_article(back=back))
        assert sections["coi"] == "None."
        assert "Pfizer" not in sections["coi"]

    def test_every_run_in_in_a_footnote_heads_its_own_statement(self) -> None:
        """Jaypee (PMC13585079): two statements in one footnote."""
        back = """<fn-group><fn><p><bold>Source of support:</bold> Nil</p>
          <p><bold>Conflict of interest:</bold> None</p></fn></fn-group>""" + REFS
        sections = _sections(_article(back=back))
        assert sections["coi"] == "None"
        assert "Conflict" not in sections.get("funding", "")

    @pytest.mark.parametrize(
        ("front", "back"),
        [
            # SAGE (PMC13530448): a bare back-matter footnote.
            ("", """<fn-group><fn id="fn4"><p>The authors declared no potential conflicts
              of interest with respect to the research.</p></fn></fn-group>"""),
            # PMC13532567: a bare author-notes footnote.
            ("""<author-notes><fn id="fn1"><p>None of the authors have any conflicts of
              interest to declare.</p></fn></author-notes>""", ""),
        ],
        ids=["sage-back", "front-author-notes"],
    )
    def test_a_bare_footnote_that_speaks_of_conflicts_is_the_statement(
        self, front: str, back: str
    ) -> None:
        """A footnote with no heading or type is headed by what it says."""
        assert "conflicts of interest" in _sections(_article(front, back + REFS))["coi"]


class TestTheAnalyserChargesOnlyASilentText:
    """The analyser's own guard, for the shapes no converter rule can head."""

    #: A text whose end matter is recognised, so a charge is reachable.
    READ = "## Methods\n\nWe did things.\n\n## Funding\n\nNIH grant R01.\n\n"

    def test_a_bare_none_declared_is_not_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """BMJ (PMC13536077): "Competing interests: None declared." deposited headless."""
        report = analyzer.analyze(pmid="1", fulltext=self.READ + "## Author Notes\n\nNone declared.")
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED
        assert any("mentions conflicts of interest" in w for w in report.warnings)

    def test_coi_wording_outside_any_section_is_not_charged(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """The words are there, so the statement is ours to have missed."""
        text = self.READ + "## Notes\n\nThe authors report no conflicts of interest."
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_ASSESSED

    def test_data_wording_outside_any_section_is_not_charged(
        self, analyzer: StudyTransparencyAnalyzer
    ) -> None:
        """The same rule for data availability."""
        text = self.READ + "## Notes\n\nOur data sharing plan is described online."
        report = analyzer.analyze(pmid="1", fulltext=text)
        assert report.data_availability.disclosure_level is DataDisclosureLevel.UNKNOWN
        assert any("mentions data availability" in w for w in report.warnings)

    def test_a_silent_text_is_still_charged(self, analyzer: StudyTransparencyAnalyzer) -> None:
        """Control: without the words, a read text's silence is the article's."""
        report = analyzer.analyze(pmid="1", fulltext=self.READ)
        assert report.coi_info.disclosure_level is COIDisclosureLevel.NOT_STATED
        assert report.data_availability.disclosure_level is DataDisclosureLevel.NOT_STATED
