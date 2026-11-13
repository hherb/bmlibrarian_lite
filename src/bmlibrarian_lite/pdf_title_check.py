# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Whether a PDF is the article it was fetched for, judged by its title (#532).

A fetched PDF can be another article: a publisher's script redirects, a
reader downloads a supplement, a DOI resolves to the wrong file. Its text
would then feed the article's transparency rating. The check asks whether the
first page with text carries the title: the share of the title's adjacent
word pairs (each pair in the title's word order, found anywhere on the page)
that the page also has. Single words are not enough: an article on the same
subject shares most of them (see ``PDF_TITLE_MIN_PAIR_SHARE``). A title the
page carries whole, read with no word breaks on either side, is carried too:
a text layer can space a word apart or run words together on a title line
(see ``PDF_TITLE_MIN_JOINED_CHARACTERS``).

A check can also find nothing to judge by: a title with no words, a PDF with
no text at all (a scan), a title PubMed translated from the article's own
language, or a file that is no readable PDF. Those are outcomes of their
own, never a match or a mismatch; each caller decides what they mean.
"""

from __future__ import annotations

import logging
import re
import unicodedata
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from .constants import (
    PDF_TITLE_MIN_JOINED_CHARACTERS,
    PDF_TITLE_MIN_PAIR_SHARE,
    PDF_TITLE_PAGES_READ,
)

logger = logging.getLogger(__name__)

#: Markup a stored title may carry (``<i>E. coli</i>``, ``CO<sub>2</sub>``):
#: an element's tag, never a bare ``<`` or ``>`` (``IL-6 < 5 pg/mL``).
_TAG = re.compile(r"</?[A-Za-z][\w:-]*(?:\s[^<>]*)?/?>")
#: A word hyphenated over a line break, as a PDF's text layer gives it: an
#: ASCII hyphen, a Unicode hyphen (U+2010) or a soft hyphen (U+00AD).
_LINE_BREAK_HYPHEN = re.compile(r"(\w)[-\u2010\u00ad][ \t]*\r?\n\s*(\w)")
#: The soft hyphen: where a word may break, never a separator of words.
_SOFT_HYPHEN = "\u00ad"
#: A word: a run of letters and digits. Hyphens and punctuation separate words.
_WORD = re.compile(r"[^\W_]+")
#: A title PubMed translated into English, which it gives in square
#: brackets (``[Treatment of ...].``): one bracketed whole, which may hold
#: bracketed parts of its own (``[[18F]FDG PET in ...]``).
_TRANSLATED_TITLE = re.compile(r"\[(?:[^\[\]]|\[[^\[\]]*\])*\]\.?")


class TitleCheckOutcome(Enum):
    """What checking a PDF against a title found."""

    #: The pages read carry the title.
    MATCHES = "matches"
    #: The pages read have text, and too little of the title.
    MISMATCH = "mismatch"
    #: The title has no words: there is nothing to check against.
    NO_TITLE = "no_title"
    #: The PDF has no text on any page (a scan): nothing to check.
    NO_TEXT = "no_text"
    #: The title is PubMed's translation of one in another language (in
    #: square brackets), and the pages do not carry it: the PDF may well be
    #: in the article's own language, so its title cannot be judged.
    TRANSLATED_TITLE = "translated_title"
    #: The file could not be read as a PDF, or has no pages.
    UNREADABLE = "unreadable"


#: The outcomes that compared a title with text, and so carry a share.
_COMPARED = frozenset({TitleCheckOutcome.MATCHES, TitleCheckOutcome.MISMATCH})
#: The outcomes of a PDF that was read, whose title could not be judged.
UNJUDGED_OUTCOMES = frozenset(
    {TitleCheckOutcome.NO_TITLE, TitleCheckOutcome.NO_TEXT, TitleCheckOutcome.TRANSLATED_TITLE}
)


@dataclass(frozen=True)
class TitleCheck:
    """What checking a PDF against a title found.

    Attributes:
        outcome: What it found.
        share: The share of the title's word pairs the pages carry, from 0
            to 1, when text was compared (1 when only the whole title, word
            breaks ignored, matched); ``None`` otherwise.

    Raises:
        ValueError: On construction, for a share missing from a comparison,
            given for anything else, or outside 0 to 1.
    """

    outcome: TitleCheckOutcome
    share: float | None = None

    def __post_init__(self) -> None:
        """Hold a share exactly when text was compared."""
        compared = self.outcome in _COMPARED
        if compared != (self.share is not None):
            raise ValueError(
                f"A {self.outcome.value!r} check {'needs' if compared else 'takes no'} share"
            )
        if self.share is not None and not 0.0 <= self.share <= 1.0:
            raise ValueError(f"A share runs from 0 to 1, not {self.share!r}")

    @classmethod
    def compared(cls, share: float) -> TitleCheck:
        """The check of a title compared with text, judged by its share.

        Args:
            share: The share of the title's word pairs the pages carry.

        Returns:
            ``MATCHES`` when it reaches ``PDF_TITLE_MIN_PAIR_SHARE``,
            ``MISMATCH`` below it, with the share.
        """
        if share >= PDF_TITLE_MIN_PAIR_SHARE:
            return cls(TitleCheckOutcome.MATCHES, share)
        return cls(TitleCheckOutcome.MISMATCH, share)


def _words(text: str) -> list[str]:
    """Text as words, compared alike whatever the source's encoding.

    NFKC folds ligatures (``ﬀ`` to ``ff``) and compatibility forms, a soft
    hyphen inside a word is dropped, and the text is case-folded.

    Args:
        text: Any text.

    Returns:
        Its words, in order.
    """
    normalised = unicodedata.normalize("NFKC", text).replace(_SOFT_HYPHEN, "")
    return _WORD.findall(normalised.casefold())


def _title_readings(title: str) -> list[list[str]]:
    """A stored title's words, read with its markup as a word break and as none.

    A tag can sit between words (``<i>E. coli</i> isolates``) or inside one
    (``H<sub>2</sub>O<sub>2</sub>``), and nothing says which, so both
    readings are kept; they are one when no tag sits inside a word.

    Args:
        title: The title as stored.

    Returns:
        Each reading's words, in order; the first reads a tag as a break.
    """
    spaced = _words(_TAG.sub(" ", title))
    joined = _words(_TAG.sub("", title))
    return [spaced] if joined == spaced else [spaced, joined]


def _is_translated(title: str) -> bool:
    """Whether a stored title is PubMed's translation, wholly in square brackets.

    Args:
        title: The title as stored.

    Returns:
        Whether it is one bracketed whole, with at most a full stop after.
    """
    return _TRANSLATED_TITLE.fullmatch(_TAG.sub("", title).strip()) is not None


def _pairs(words: list[str]) -> set[tuple[str, str]]:
    """Each word with the one after it.

    Args:
        words: Words in order.

    Returns:
        The adjacent pairs.
    """
    return set(zip(words, words[1:], strict=False))


def _reading_share(title_words: list[str], joined: list[str], split: list[str]) -> float:
    """The share of one reading of a title that the page's words carry.

    Args:
        title_words: The reading's words, at least one.
        joined: The page's words, a word hyphenated at a line break joined.
        split: The page's words, such a word split.

    Returns:
        From 0 to 1; a one-word title counts that word.
    """
    if len(title_words) == 1:
        return 1.0 if title_words[0] in set(joined) | set(split) else 0.0
    wanted = [*zip(title_words, title_words[1:], strict=False)]
    have = _pairs(joined) | _pairs(split)
    return sum(1 for pair in wanted if pair in have) / len(wanted)


def carries_whole_title(page_text: str, title: str) -> bool:
    """Whether the page carries the whole title, word breaks ignored (#546).

    The title's words and the page's are each joined with nothing between
    them, so a word the text layer spaced apart (``res ponse``) or words it ran
    together (``ClinicalOutcome``) read alike. Only a title of at least
    ``PDF_TITLE_MIN_JOINED_CHARACTERS`` letters and numbers counts, so a short
    one cannot match inside a longer word.

    Args:
        page_text: The text of the pages read.
        title: The article's title, as stored; markup is not counted.

    Returns:
        Whether the joined title appears in the joined page.
    """
    joined_title = "".join(_words(_TAG.sub("", title)))
    if len(joined_title) < PDF_TITLE_MIN_JOINED_CHARACTERS:
        return False
    return joined_title in "".join(_words(page_text))


def title_pair_share(page_text: str, title: str) -> float | None:
    """The share of a title's adjacent word pairs that the page text also has.

    The page is read twice over: once with a word hyphenated at a line break
    joined (``hyper-``/``tension``), once with it split (``SARS-``/``CoV-2``),
    since the text layer cannot say which hyphen was the author's. A title
    with markup inside a word is read both ways too (``_title_readings``);
    the better reading counts. A one-word title counts that word.

    Args:
        page_text: The text of the pages read.
        title: The article's title, as stored; markup is not counted.

    Returns:
        From 0 to 1; ``None`` when the title has no words.
    """
    readings = [words for words in _title_readings(title) if words]
    if not readings:
        return None
    joined = _words(_LINE_BREAK_HYPHEN.sub(r"\1\2", page_text))
    split = _words(page_text)
    return max(_reading_share(words, joined, split) for words in readings)


def judge_title(page_text: str, title: str) -> TitleCheck:
    """Whether the text of a PDF's first pages carries an article's title.

    Args:
        page_text: The text of the pages read.
        title: The article's title.

    Returns:
        ``NO_TITLE`` when the title has no words, ``NO_TEXT`` when the pages
        have none; otherwise ``MATCHES`` when at least
        ``PDF_TITLE_MIN_PAIR_SHARE`` of the title's word pairs are there, and
        ``MISMATCH`` when fewer are, each with the share. A title the pages
        carry whole with word breaks ignored (:func:`carries_whole_title`)
        matches with a share of 1, all of it carried. A translated title (in
        square brackets) the pages do not carry is ``TRANSLATED_TITLE``, not a
        mismatch: the PDF may carry it in the article's own language.
    """
    share = title_pair_share(page_text, title)
    if share is None:
        return TitleCheck(TitleCheckOutcome.NO_TITLE)
    if not _words(page_text):
        return TitleCheck(TitleCheckOutcome.NO_TEXT)
    check = TitleCheck.compared(share)
    if check.outcome is not TitleCheckOutcome.MISMATCH:
        return check
    if carries_whole_title(page_text, title):
        return TitleCheck(TitleCheckOutcome.MATCHES, 1.0)
    if _is_translated(title):
        return TitleCheck(TitleCheckOutcome.TRANSLATED_TITLE)
    return check


def opening_text(pdf_path: Path, pages: int = PDF_TITLE_PAGES_READ) -> str | None:
    """The text of a PDF's first pages that carry any.

    A page with no text before them (an image-only cover, a full-page
    figure) is passed over: the title is looked for where the text starts,
    so a PDF whose text starts on a later page is still checked.

    Args:
        pdf_path: The PDF.
        pages: How many pages with text to read.

    Returns:
        Their text, joined; empty when no page has text (a scan); ``None``
        when the PDF has no pages.

    Raises:
        Exception: Whatever PyMuPDF raises for a file it cannot read: a
            ``RuntimeError`` for one that is no PDF or is empty or missing,
            a ``ValueError`` for one that needs a password, its own
            ``FzErrorBase`` (an ``Exception``) for damage. The set is not
            documented (``_unreadable_file_errors``).
    """
    import fitz  # type: ignore[import-untyped]  # PyMuPDF, imported where it is used

    with fitz.open(str(pdf_path)) as document:
        if document.page_count == 0:
            return None
        texts: list[str] = []
        for page in document:
            text = page.get_text()
            if _words(text):
                texts.append(text)
                if len(texts) == pages:
                    break
        return "".join(texts)


def _unreadable_file_errors() -> tuple[type[BaseException], ...]:
    """The errors PyMuPDF raises for a file it cannot read.

    Its own (``FileDataError`` and its kin are ``RuntimeError`` s), a
    ``ValueError`` for a password, an ``OSError``, and MuPDF's
    ``FzErrorBase`` where this PyMuPDF has it (1.24 on). Anything else (an
    ``AttributeError`` from a changed API, an ``ImportError``) is a fault of
    the code or the install, not a property of the file.

    Returns:
        The exception types.
    """
    errors: tuple[type[BaseException], ...] = (RuntimeError, ValueError, OSError)
    try:
        import fitz
    except ImportError:
        return errors
    base = getattr(getattr(fitz, "mupdf", None), "FzErrorBase", None)
    if isinstance(base, type) and issubclass(base, Exception):
        return (*errors, base)
    return errors


def check_pdf_title(pdf_path: Path, title: str) -> TitleCheck:
    """Whether a PDF's first page with text carries an article's title.

    A title with no words is not checked, so the file is not opened for it.

    Args:
        pdf_path: The PDF.
        title: The article's title.

    Returns:
        The check; ``UNREADABLE`` when the file cannot be read as a PDF or
        has no pages (logged).
    """
    if not any(_title_readings(title)):
        return TitleCheck(TitleCheckOutcome.NO_TITLE)
    try:
        text = opening_text(pdf_path)
    except Exception as e:  # noqa: BLE001
        # PyMuPDF wraps a C library and documents no closed set of errors,
        # and no caller (a Qt slot, a discovery) may be left without an
        # answer: an unexpected one is logged as the fault it is, and the
        # file is still only unread, never judged
        if isinstance(e, _unreadable_file_errors()):
            logger.warning("%s could not be read to check its title", pdf_path.name, exc_info=True)
        else:
            logger.exception("Reading %s to check its title failed in the code, not the file", pdf_path.name)
        return TitleCheck(TitleCheckOutcome.UNREADABLE)
    if text is None:
        logger.warning("%s has no pages, so its title could not be checked", pdf_path.name)
        return TitleCheck(TitleCheckOutcome.UNREADABLE)
    return judge_title(text, title)
