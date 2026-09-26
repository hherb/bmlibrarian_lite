"""Inline markup inside a PubMed title, abstract or COI statement is its text.

efetch carries ``<i>``, ``<b>``, ``<sup>`` and ``<sub>`` as child elements.
``Element.findtext`` returns only the text before the first child, so the
transparency analyzer read PMID 42357316's title as "... Optimization, ".
Europe PMC's JATS captions lost their text the same way.
"""

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
    PubMedClient,
)

RECORD = (
    "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
    "<PMID>42357316</PMID>"
    "<Article><Journal><Title>Pharmaceutics</Title></Journal>"
    "<ArticleTitle>Formulation, <i>In Vitro</i> and <i>In Vivo</i>"
    " Evaluation.</ArticleTitle>"
    "<Abstract>"
    "<AbstractText Label='BACKGROUND'>Levels of CO<sub>2</sub> rose.</AbstractText>"
    "<AbstractText Label='RESULTS'><b>Both</b> groups improved.</AbstractText>"
    "</Abstract></Article>"
    "<CoiStatement>Funded by <i>Acme</i> Pharma.</CoiStatement>"
    "</MedlineCitation></PubmedArticle></PubmedArticleSet>"
)


def _record() -> dict:
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(RECORD)
    assert fetch.record is not None
    return fetch.record


def test_a_title_keeps_the_text_around_its_inline_markup() -> None:
    """A title keeps the words around its italics."""
    assert _record()["title"] == "Formulation, In Vitro and In Vivo Evaluation."


def test_an_abstract_keeps_every_section_and_its_inline_markup() -> None:
    """Every abstract section is read, markup included."""
    assert _record()["abstract"] == "Levels of CO2 rose. Both groups improved."


def test_a_coi_statement_keeps_the_text_around_its_inline_markup() -> None:
    """A COI statement keeps the funder named in italics."""
    assert _record()["coi_statement"] == "Funded by Acme Pharma."


def test_absent_elements_are_still_none() -> None:
    """The control: a record without an abstract or COI statement."""
    fetch = PubMedClient("t@example.com")._parse_pubmed_xml(
        "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
        "<PMID>1</PMID><Article><ArticleTitle>T</ArticleTitle></Article>"
        "</MedlineCitation></PubmedArticle></PubmedArticleSet>"
    )
    assert fetch.record is not None
    assert fetch.record["title"] == "T"
    assert fetch.record["abstract"] is None
    assert fetch.record["coi_statement"] is None


def test_a_figure_caption_keeps_the_text_around_its_inline_markup() -> None:
    """Europe PMC's Markdown rendering reads the whole caption."""
    from bmlibrarian_lite.europepmc import EuropePMCClient

    markdown = EuropePMCClient().xml_to_markdown(
        "<article><body><sec><title>Results</title>"
        "<fig><caption><p>Growth of <italic>S. mutans</italic> over"
        " 24 h.</p></caption></fig>"
        "<table-wrap><caption><p>Levels of CO<sub>2</sub> by"
        " group.</p></caption></table-wrap>"
        "</sec></body></article>"
    )

    assert "over 24 h." in markdown
    assert "by group." in markdown
