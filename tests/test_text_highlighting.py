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
    passage = "We enrolled 1200 with high cholesterol."
    match = find_passage_in_abstract(ABSTRACT, passage)
    assert match is not None and not match.exact
    own = "We enrolled  1200 adults with high cholesterol."
    assert ABSTRACT[match.start : match.end] == own
    html = create_highlighted_html(ABSTRACT, passage)
    assert NOTE in html
    assert f"{escape_html(own)}</span>" in html


def test_quote_contradicting_the_abstract_is_never_highlighted() -> None:
    """A changed number or a dropped negation is shown apart, unhighlighted."""
    cases = [
        (ABSTRACT, "Mortality fell by 21%."),
        ("The drug was not effective in adults.", "The drug was effective in adults."),
    ]
    for abstract, passage in cases:
        assert find_passage_in_abstract(abstract, passage) is None
        html = create_highlighted_html(abstract, passage)
        assert "Cited Passage:" in html and "<span" not in html


def test_unrelated_passage_is_shown_separately() -> None:
    """A quote the abstract lacks is shown above it."""
    passage = "Aspirin reduced the risk of stroke in elderly women."
    assert find_passage_in_abstract(ABSTRACT, passage) is None
    html = create_highlighted_html(ABSTRACT, passage)
    assert "Cited Passage:" in html


def test_word_inside_a_word_is_not_exact() -> None:
    """A word found inside another word is never an exact match."""
    abstract = "The drug was ineffective."
    assert find_passage_in_abstract(abstract, "effective") is None
    assert "<span" not in create_highlighted_html(abstract, "effective")


def test_multiple_passages_note_only_when_one_is_near() -> None:
    """The note appears once any highlighted passage is near."""
    exact = ["Statins are widely used", "Mortality fell by 12%"]
    html = highlight_multiple_passages(ABSTRACT, exact)
    assert html.count("<span") == 2 and NOTE not in html
    near = exact + ["We enrolled 1200 with high cholesterol."]
    assert NOTE in highlight_multiple_passages(ABSTRACT, near)
