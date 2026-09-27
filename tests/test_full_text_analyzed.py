"""A rating is made from the full text only when the analyser read some of it (#386).

``full_text_analyzed`` decides whether every surface says the rating's
certainty is limited. It used to mean "some text arrived": whitespace, and a
full text the extractor could not segment at all, both counted, so a rating
resting on metadata alone was shown as if the article had been read. These
tests drive the real ``analyze()``, with only the network steps stubbed:
the defect lived between the analyser and the result, where a hand-built
report never goes.
"""

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
)
from bmlibrarian_lite.transparency import get_default_settings
from bmlibrarian_lite.transparency.assessment import build_transparency_result
from bmlibrarian_lite.transparency.risk_explanation import certainty_note
from bmlibrarian_lite.transparency_terms import LIMITED_CERTAINTY_NOTE

#: A full text whose end matter the extractor recognises.
READABLE = "## Methods\nWe did X.\n\n## Funding\nNIH grant R01.\n"

#: Prose in which the extractor recognises no section at all -- the shape a
#: PLOS ONE article takes once its front-matter statements are dropped.
UNSEGMENTED = "We did a thing. It was good.\n\nMore prose, and no headings.\n"


def _analyzer(discovered: str | None = None) -> StudyTransparencyAnalyzer:
    """An analyser whose network steps do nothing.

    Args:
        discovered: What full-text discovery returns; ``None`` leaves
            discovery off.

    Returns:
        The analyser.
    """
    analyzer = StudyTransparencyAnalyzer(
        email="test@example.com",
        use_browser_fallback=False,
        auto_discover_fulltext=discovered is not None,
    )
    analyzer._fetch_basic_metadata = lambda report: None
    analyzer._fetch_funder_info = lambda report: None
    analyzer._fetch_trial_info = lambda report: None
    analyzer._discover_fulltext = lambda report: discovered
    return analyzer


def _analysed(analyzer: StudyTransparencyAnalyzer, fulltext: str | None = None):
    """Analyse one study and build the result that is stored and shown.

    Args:
        analyzer: The analyser to run.
        fulltext: The full text handed to it, if any.

    Returns:
        The analyser's report and the built result.
    """
    report = analyzer.analyze(doi="10.1/x", fulltext=fulltext)
    return report, build_transparency_result("d", report, get_default_settings())


class TestSuppliedText:
    """Text the caller hands the analyser."""

    @pytest.mark.parametrize("blank", ["", "   \n", "\n\n\t\n"])
    def test_whitespace_is_no_text(self, blank) -> None:
        """Not read, not a source, and the rating says so."""
        report, result = _analysed(_analyzer(), blank)
        assert result.full_text_analyzed is False
        assert "Full-text" not in report.data_sources_used
        assert certainty_note(result) == LIMITED_CERTAINTY_NOTE

    def test_text_nothing_could_be_recognised_in_is_not_analysed(self) -> None:
        """It arrived, and established nothing: the rating rests on metadata."""
        _, result = _analysed(_analyzer(), UNSEGMENTED)
        assert result.full_text_analyzed is False
        assert certainty_note(result) == LIMITED_CERTAINTY_NOTE

    def test_readable_text_is_analysed(self) -> None:
        """The control: without it, never setting the flag passes the rest."""
        _, result = _analysed(_analyzer(), READABLE)
        assert result.full_text_analyzed is True
        assert certainty_note(result) is None


class TestDiscoveredText:
    """Text the analyser finds for itself -- every desktop analysis's path."""

    def test_readable_discovered_text_is_analysed(self) -> None:
        """The production path: nothing is supplied, discovery finds it."""
        _, result = _analysed(_analyzer(discovered=READABLE))
        assert result.full_text_analyzed is True
        assert certainty_note(result) is None

    @pytest.mark.parametrize("blank", ["\n\n\n", "   "])
    def test_blank_discovered_text_is_not(self, blank) -> None:
        """An image-only PDF extracts to blank lines: no text, and no source."""
        report, result = _analysed(_analyzer(discovered=blank))
        assert result.full_text_analyzed is False
        assert "Full-text" not in report.data_sources_used

    def test_unsegmented_discovered_text_is_not(self) -> None:
        """Discovered or supplied, text nothing was recognised in is the same."""
        _, result = _analysed(_analyzer(discovered=UNSEGMENTED))
        assert result.full_text_analyzed is False

    def test_nothing_discovered_is_not(self) -> None:
        """Discovery on, and it found nothing."""
        analyzer = _analyzer(discovered="")
        analyzer._discover_fulltext = lambda report: None
        _, result = _analysed(analyzer)
        assert result.full_text_analyzed is False
