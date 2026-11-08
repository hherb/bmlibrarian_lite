"""Tests for the citation highlight's passage finder (#642)."""

from bmlibrarian_lite.constants import CITATION_NEAR_MATCH_NOTE
from bmlibrarian_lite.gui.card_utils import escape_html
from bmlibrarian_lite.gui.text_highlighting import (
    create_highlighted_html,
    find_passage_in_abstract,
    highlight_multiple_passages,
)

ABSTRACT = (
    "Background: Statins are widely used.\n\n  Methods: We enrolled  "
    "1200 adults with high cholesterol. Results: Mortality fell by 12%."
)
NOTE = escape_html(CITATION_NEAR_MATCH_NOTE)


def test_whitespace_run_before_passage_keeps_the_abstracts_own_span() -> None:
    """A collapsed whitespace run never shifts the span."""
    passage = "We enrolled 1200 adults with high cholesterol."
    match = find_passage_in_abstract(ABSTRACT, passage)
    assert match is not None and match.exact
    assert ABSTRACT[match.start : match.end] == (
        "We enrolled  1200 adults with high cholesterol."
    )


def test_exact_match_is_highlighted_without_a_note() -> None:
    """A verbatim quote (case aside) is highlighted with no note."""
    html = create_highlighted_html(ABSTRACT, "mortality fell by 12%")
    assert "Mortality fell by 12%</span>" in html
    assert NOTE not in html


def test_near_match_is_highlighted_with_the_note() -> None:
    """A near quote is highlighted and said not to be verbatim."""
    # The quote drops a word the abstract has.
    passage = "We enrolled 1200 adults with cholesterol."
    match = find_passage_in_abstract(ABSTRACT, passage)
    assert match is not None and not match.exact
    html = create_highlighted_html(ABSTRACT, passage)
    assert NOTE in html
    assert "<span" in html


def test_unrelated_passage_is_shown_separately() -> None:
    """A quote the abstract lacks is shown above it."""
    passage = "Aspirin reduced the risk of stroke in elderly women."
    assert find_passage_in_abstract(ABSTRACT, passage) is None
    html = create_highlighted_html(ABSTRACT, passage)
    assert "Cited Passage:" in html


def test_word_inside_a_word_is_not_exact() -> None:
    """A word found inside another word is never an exact match."""
    match = find_passage_in_abstract("The drug was ineffective.", "effective")
    assert match is None or not match.exact


def test_multiple_passages_note_only_when_one_is_near() -> None:
    """The note appears once any highlighted passage is near."""
    exact = ["Statins are widely used", "Mortality fell by 12%"]
    html = highlight_multiple_passages(ABSTRACT, exact)
    assert html.count("<span") == 2 and NOTE not in html
    near = exact + ["We enrolled 1200 adults with cholesterol."]
    assert NOTE in highlight_multiple_passages(ABSTRACT, near)
