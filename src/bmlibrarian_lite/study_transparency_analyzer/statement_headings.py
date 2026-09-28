# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""The headings a transparency statement is known by, and the end matter's.

The analyser recognises a statement only by its heading. Once end matter was
recognised, a statement it did not find used to be charged as missing: -5 and
a risk indicator. But a heading it does not know may be exactly that
statement under a journal's own name -- Diabetologia's "Authors'
relationships and activities" was one such, charged although it listed
pharmaceutical ties (#426 review). Adding each name as it is found leaves
the next journal in the same hole.

So a missing statement is charged only when every heading in the article's
end matter is one this module knows: a statement, or a known neighbour of
one ("Publisher's note", "Abbreviations", ...). A heading it does not know
makes the result "not assessed" instead (#428). The list of neighbours
fails safe: a heading missing from it costs a charge, never makes one.

Knowing the end matter's headings needs to know where the end matter is.
The JATS converter marks its start (``END_MATTER_MARKER``). Text extracted
from a PDF carries no such mark and no marked headings at all, so its end
matter cannot be told from its body; :func:`end_matter_sections` then
answers ``None`` and nothing is charged.
"""

import re
from dataclasses import dataclass

from ..jats_markdown import END_MATTER_MARKER

#: A statement heading longer than this is taken for prose. Headings in
#: surveyed articles are far shorter; a PDF line this long is a sentence.
MAX_HEADING_LINE_CHARS = 120

#: A markdown heading line: one to six ``#`` then a space. Converted JATS
#: marks every heading this way; extracted PDF text marks none, and a line
#: of it that happens to open "# " only ends a section early.
_MARKDOWN_HEADING_RE = re.compile(r'(#{1,6})\s')

#: What may follow a statement's heading. "Conflict of Interest Statement"
#: and "Data Availability Statement" are the commonest spellings of both
#: sections, and a fully anchored match rejected every one of them (#359).
HEADING_QUALIFIER = r'(?:\s+(?:statements?|disclosures?|declarations?|section))?'

#: The headings each statement is recognised by, as regular expressions
#: matched against a whole lower-cased heading line, keyed by the section
#: the analyser files it under.
STATEMENT_HEADING_PATTERNS: dict[str, tuple[str, ...]] = {
    'coi': (
        # "Declaration of Competing Interest" is Elsevier's standard heading
        # and "Conflict of Interest Statement" the standard PMC/JATS one;
        # both missed the anchored match until the ``competing`` infix and
        # the trailing qualifier existed. A heading we fail to recognise used
        # to be recorded as the article declaring no conflicts (#359).
        'coi',
        'conflicts? of interests?',
        'conflict[-‐-―\\s]of[-‐-―\\s]interests?',
        'potential conflicts? of interests?',
        'declarations? of (?:competing |conflicting |conflicts? of )?interests?',
        '(?:potential )?competing (?:financial )?interests?',
        # One heading for two statements; the funding half is still found
        # by the funder lookups (#420).
        'conflicts? of interests? and sources? of funding',
        'author disclosures?',
        'disclosures?',
        # Diabetologia's heading for every competing interests statement,
        # and another journal's; missed, each read as an article that
        # declares nothing, industry ties and all (#426 review).
        "authors?['’]? relationships and activities",
        '(?:financial and non-?financial )?relationships? and activities',
        'duality of interests?',
        # The statement's heading in the languages surveyed articles print
        # it in untyped: French, Spanish, Portuguese, German.
        "conflits? d['’]int[ée]r[êe]ts?",
        'conflictos? de intereses?',
        'conflitos? de interesses?',
        'interessenkonflikte?',
    ),
    'data_sharing': (
        'data sharing',
        'data availability',
        'data access',
        'availability of data',
        # BMC's standard "Availability of data and materials", Cell's "Data
        # and code availability", and Wiley's "Data accessibility" (#426
        # review).
        'availability of (?:the )?data and (?:materials?|code)',
        'availability of materials? and data',
        'data and (?:code|materials?|software) availability',
        'data accessibility',
        '(?:research )?data transparency and availability',
    ),
    'funding': (
        'funding',
        'financial support(?: (?:&|and) sponsorship)?',
        'grant support',
        'sources? of (?:support|funding)',
        # Found by the #428 survey, which needs every end-matter heading
        # classified: missed, each made its article "not assessed".
        'funding (?:sources?|information)',
        'funding/support',
        'declarations? of sources? of funding',
    ),
    'funding_role': (
        'role of the funding source',
        'role of the funder',
        'role of the sponsor',
        'role of the funder/sponsor',
        'funder role',
    ),
    'acknowledgments': (
        # "Acknowledgements", the British spelling, heads a third of the
        # surveyed <ack> elements; ``acknowledgm?ents?`` matched only the
        # American one (#420).
        'acknowledge?ments?',
    ),
    'contributors': (
        'contributors?',
        'author contributions?',
        "authors['’] contributions?",
    ),
}

#: End-matter headings that are known not to hold a competing interests or
#: data availability statement: the neighbours statements sit among. Matched
#: like a statement heading, against the whole lower-cased heading. Built
#: from a survey of 1,292 real PMC articles (#428); a heading missing here
#: makes its article "not assessed" rather than charged, so the list fails
#: safe. Keep it to headings whose name says what they hold. "Appendix" and
#: "Declarations" are left out on purpose: either can hold a statement.
KNOWN_NON_STATEMENT_HEADING_PATTERNS: tuple[str, ...] = (
    # The reference list, the converter's own and the one BMJ puts among
    # its back matter.
    'references?', 'bibliography',
    # Frontiers and MDPI print one after every competing interests statement.
    "(?:disclaimer/)?publisher['’]?s note",
    # Ethics, consent and registration.
    'institutional review board statement',
    'informed consent(?: statement)?',
    'ethics(?: committee)? approval(?: and consent to participate)?',
    'ethics statement', 'ethical (?:approval|consideration|standards?)s?',
    'ethical publication statement',
    '(?:patient )?consent (?:to participate|for publication)',
    '(?:animal|human) subjects', 'patient consent(?: statement)?',
    '(?:clinical )?(?:trial )?registration;?',
    # Use of generative AI.
    '(?:generative )?ai statement',
    'declaration regarding the use of generative ai',
    'use of (?:generative )?(?:ai|artificial intelligence)(?: \\(ai\\))?'
    '(?:[- ]assisted technology)?(?: for manuscript preparation)?',
    # Abbreviations and keywords.
    '(?:list of )?(?:abbreviations|acronyms)', 'key ?words', 'glossary',
    # Correspondence, addresses and identifiers.
    '(?:address for |for )?correspondence(?: to)?', 'corresponding author',
    'author to whom correspondence should be addressed',
    'korrespondenzanschrift', 'present address(?:es)?',
    'institutional affiliations', 'orcid(?: ids?)?',
    # Editors and peer review.
    '(?:open )?peer[- ]review(?: information)?',
    '(?:handling|associated?|scientific|section) editor', 'edited by',
    'reviewed by',
    # Supplementary material and figure descriptions.
    'supplementary (?:materials?|data|information)',
    'supplemental (?:materials?|information)',
    'supporting information(?: available)?',
    '(?:the|this) pdf file includes', 'long descriptions?',
    # About the article and its authors.
    'how to cite', 'correction note', 'change history',
    'contributor information', 'citation diversity statement',
    'tweetable summary',
    # A statement of its own, but neither of the two this rule is about.
    'code availability',
)

#: Headings of a part of one statement, by the statement's key. Cureus heads
#: the three parts of the ICMJE disclosure form as siblings of its "Conflicts
#: of interest" run-in. Such a part is no place for the *other* statement,
#: but it is no known neighbour of its own statement either: under it may be
#: that statement, in a shape the extractor did not recognise.
STATEMENT_PART_HEADING_PATTERNS: dict[str, tuple[str, ...]] = {
    'coi': (
        'payment/services info', 'financial relationships',
        'other relationships',
    ),
}

#: The headings the JATS converter gives end matter that had none of its own
#: (``DEFAULT_HEADING_BY_OWNER``, ``DEFAULT_HEADING``,
#: ``AUTHOR_NOTES_HEADING``, and "Endnotes" as publishers print it). Their
#: name says nothing of what they hold, and a statement can sit under one:
#: "The author discloses no conflicts of research interest." as an author
#: note (PMC12805416). So such a section is known only by what it holds --
#: one whose text uses none of a statement's vocabulary
#: (:data:`COI_VOCABULARY_RE`, :data:`DATA_VOCABULARY_RE`) holds no statement.
CATCH_ALL_HEADING_PATTERNS: tuple[str, ...] = (
    "authors?['’]? notes?", '(?:foot|end)?notes?',
    # Named, but what they hold can be a disclosure: "The authors have no
    # financial relationships to disclose" as a disclaimer, advisory roles
    # in a biography (review of #428).
    '(?:author )?disclaimer', '(?:authors?[\'’]? )?biograph(?:y|ies)',
    'notes on contributors',
)

#: What end-matter text with no heading at all before it is filed under. It
#: is known only by what it holds, as a catch-all is.
UNHEADED = "text without a heading"

#: Words any competing interests statement is likely to use, in any of the
#: languages surveyed articles print one in. Broad: a word here in a
#: catch-all section costs a charge, never makes one. But in its disclosure
#: forms only -- "financial interests", not "financ"; "stock options", not
#: "stock" -- or every economics paper's footnotes on interest rates and
#: stock returns go unassessed (#428 held-out survey).
COI_VOCABULARY_RE = re.compile(
    r'disclos|conflict|conflit|competing|\bdeclar(?:e|es|ed|ing|ation)\b'
    r'|honorari|consult(?:ant|anc|ing)|speaker|advisory|royalt|patents?\b'
    r'|stock options?|shareholder|equity (?:interest|holder|stake)'
    r'|employee of|employed by|financial (?:interest|relationship|support|tie)'
    r'|relationships? (?:with|to) (?:industry|compan)|\bgrants?\b|funded|funding'
    r'|sponsor|\bnone\b|\bnil\b|nothing to|interessenkonflikt|利益',
    re.IGNORECASE,
)

#: Words any data availability statement is likely to use, likewise broad.
DATA_VOCABULARY_RE = re.compile(
    r'\bdata|dataset|datos|dados|daten|repositor|availab|disponib|request'
    r'|accession|osf\.io|github|zenodo|figshare|dryad|数据',
    re.IGNORECASE,
)

#: The statements a missing one can be charged for, and their vocabulary.
VOCABULARY_BY_STATEMENT: dict[str, "re.Pattern[str]"] = {
    'coi': COI_VOCABULARY_RE,
    'data_sharing': DATA_VOCABULARY_RE,
}


@dataclass(frozen=True)
class EndMatterSection:
    """A heading of the end matter and the text it holds of its own.

    Attributes:
        heading: The heading line, stripped, ``#`` marks and all.
        text: The lines under it before the next heading of any level,
            joined by newlines; never empty.
        ancestors: The headings of the end-matter sections it is a
            subsection of, outermost first.
    """

    heading: str
    text: str
    ancestors: tuple[str, ...] = ()

    @property
    def words(self) -> str:
        """The heading's words, without its ``#`` marks."""
        return self.heading.lstrip('#').strip()


def markdown_heading_level(line: str) -> int:
    """The level of a markdown heading line.

    Args:
        line: A stripped line of full text.

    Returns:
        The number of ``#`` marks opening it, or 0 when it is not a
        markdown heading -- a plain-text heading from a PDF, or prose.
    """
    match = _MARKDOWN_HEADING_RE.match(line)
    return len(match.group(1)) if match else 0


def _matches_heading(line: str, pattern: str, qualifier: str = '') -> bool:
    """Whether a heading line is, as a whole, one a pattern names.

    Args:
        line: The heading line, as the text holds it.
        pattern: A regular expression for the heading's words.
        qualifier: What may follow the words (:data:`HEADING_QUALIFIER`).

    Returns:
        True if the line, less its ``#`` marks and a trailing colon, matches.
    """
    lowered = line.strip().lower()
    return re.search(rf'^(?:#*\s*)?{pattern}{qualifier}\s*:?\s*$', lowered) is not None


def _matches_any(line: str, patterns: tuple[str, ...]) -> bool:
    """Whether a heading line is one any of some patterns names.

    Args:
        line: The heading line.
        patterns: Regular expressions for headings' words.

    Returns:
        True if one matches.
    """
    return any(_matches_heading(line, pattern) for pattern in patterns)


def statement_key_of_heading(line: str) -> str | None:
    """The statement a heading line names, if any.

    Args:
        line: A heading line, with or without its ``#`` marks.

    Returns:
        The key of :data:`STATEMENT_HEADING_PATTERNS` it matches first, or
        ``None`` when it names no statement or is longer than the extractor
        reads a heading, so that the two agree on what is a statement.
    """
    if len(line.strip()) > MAX_HEADING_LINE_CHARS:
        return None
    for key, patterns in STATEMENT_HEADING_PATTERNS.items():
        if any(_matches_heading(line, p, HEADING_QUALIFIER) for p in patterns):
            return key
    return None


def is_known_non_statement_heading(line: str) -> bool:
    """Whether a heading line names a known neighbour of the statements.

    Args:
        line: A heading line, with or without its ``#`` marks.

    Returns:
        True if it matches :data:`KNOWN_NON_STATEMENT_HEADING_PATTERNS`.
    """
    return _matches_any(line, KNOWN_NON_STATEMENT_HEADING_PATTERNS)


def is_catch_all_heading(line: str) -> bool:
    """Whether a heading line is one that says nothing of what it holds.

    Args:
        line: A heading line, with or without its ``#`` marks.

    Returns:
        True if it matches :data:`CATCH_ALL_HEADING_PATTERNS`.
    """
    return line == UNHEADED or _matches_any(line, CATCH_ALL_HEADING_PATTERNS)


def is_end_matter_marker(line: str) -> bool:
    """Whether a line is the one the JATS converter opens the end matter with.

    Args:
        line: A line of full text.

    Returns:
        True for :data:`~bmlibrarian_lite.jats_markdown.END_MATTER_MARKER`
        alone on its line.
    """
    return line.strip() == END_MATTER_MARKER


def end_matter_sections(fulltext: str) -> tuple[EndMatterSection, ...] | None:
    """The headed sections of a full text's end matter.

    The end matter opens at the first end-matter marker -- the converter
    marks end matter wherever it begins, and one journal keeps its
    footnotes, its competing interests statement among them, in the body --
    or at the first statement heading, when one comes before it: an article
    may print its statements as ordinary sections of its body and still have
    back matter the marker opens (review of #428). It runs to the end of the
    text.

    Text after the marker but before any heading is the continuation of the
    section the marker fell in: an untitled footnote group inside a titled
    body section. With no heading before it at all, it is filed under
    :data:`UNHEADED`.

    Args:
        fulltext: The article's full text.

    Returns:
        Every heading from the start of the end matter that holds text of its
        own before the next heading, in order -- empty when there is none. A
        heading holding none, such as a "Declarations" wrapper whose
        subsections follow at once, cannot hide a statement; its subsections
        are listed instead. ``None`` when the text carries no marker, so that
        its end matter cannot be told from its body: text extracted from a
        PDF, or converted before the marker existed.
    """
    lines = [line.strip() for line in fulltext.split('\n')]
    marker = next(
        (index for index, line in enumerate(lines) if is_end_matter_marker(line)),
        None,
    )
    if marker is None:
        return segment_unmarked_end_matter(fulltext)
    start = next(
        (
            index
            for index, line in enumerate(lines[:marker])
            if markdown_heading_level(line)
            and statement_key_of_heading(line) is not None
        ),
        marker,
    )
    headed: list[tuple[str, tuple[str, ...], list[str]]] = []
    enclosing: list[tuple[int, str]] = []
    open_text: list[str] | None = None
    for index, line in enumerate(lines):
        level = markdown_heading_level(line)
        if level:
            while enclosing and enclosing[-1][0] >= level:
                enclosing.pop()
            ancestors = tuple(heading for _, heading in enclosing)
            enclosing.append((level, line))
            open_text = None
            if index >= start:
                open_text = []
                headed.append((line, ancestors, open_text))
        elif index > start and line and not is_end_matter_marker(line):
            if open_text is None:
                # The marker fell inside a section: this is its text.
                open_text = []
                heading, ancestors = (
                    (enclosing[-1][1], tuple(h for _, h in enclosing[:-1]))
                    if enclosing
                    else (UNHEADED, ())
                )
                headed.append((heading, ancestors, open_text))
            open_text.append(line)
    return tuple(
        EndMatterSection(heading, '\n'.join(text), ancestors)
        for heading, ancestors, text in headed
        if text
    )


def segment_unmarked_end_matter(fulltext: str) -> tuple[EndMatterSection, ...] | None:
    """The end matter of a text no converter marked. Not yet possible.

    A PDF's extracted text marks neither its headings nor where its end
    matter begins, so nothing here can tell a statement's heading from a
    line of prose. This is where a segmentation of such text belongs --
    for example a model reading the PDF into sections as the JATS converter
    does -- once one exists. Until then every such text answers ``None``,
    and a statement not found in it is not assessed rather than charged
    (#430).

    Args:
        fulltext: A full text without the end-matter marker.

    Returns:
        ``None``: the end matter is unknown.
    """
    del fulltext  # Unused until a segmenter exists.
    return None


def unclassified_headings(
    sections: tuple[EndMatterSection, ...],
    sought: str,
) -> tuple[str, ...]:
    """The headings under which the statement sought could stand unrecognised.

    A heading is classified when it is a statement's, a known neighbour's,
    or a part of a statement other than the one sought.
    Two kinds are known only by what they hold, and are classified when
    their text uses none of the statement's vocabulary: a catch-all, and a
    subsection of a named section or a catch-all (Springer heads each
    author's biography with the author's name) -- Cureus heads each part of its
    competing interests statement ("Financial relationships") and each
    author's role, and what the extractor reads as part of a statement could
    as well hide another.

    Args:
        sections: The end matter, from :func:`end_matter_sections`.
        sought: The key of the statement sought, one of
            :data:`VOCABULARY_BY_STATEMENT`.

    Returns:
        Each unclassified heading's words, without ``#`` marks, in order.
    """
    return tuple(
        section.words
        for section in sections
        if not _is_classified(section, sought)
    )


def _is_named(heading: str) -> bool:
    """Whether a heading names a statement or a known neighbour of one.

    Args:
        heading: A heading line.

    Returns:
        True if it matches either list.
    """
    return (
        statement_key_of_heading(heading) is not None
        or is_known_non_statement_heading(heading)
    )


def _is_classified(section: EndMatterSection, sought: str) -> bool:
    """Whether a section of the end matter cannot hold the statement sought.

    Args:
        section: The section.
        sought: The key of the statement sought.

    Returns:
        True if its heading is named or a part of another statement, or if it
        is known only by what it holds and its text avoids the statement's
        vocabulary.
    """
    if _is_named(section.heading):
        return True
    if any(
        _matches_any(section.heading, patterns)
        for statement, patterns in STATEMENT_PART_HEADING_PATTERNS.items()
        if statement != sought
    ):
        return True
    vocabulary = VOCABULARY_BY_STATEMENT[sought]
    known_by_its_text = is_catch_all_heading(section.heading) or any(
        _is_named(ancestor) or is_catch_all_heading(ancestor)
        for ancestor in section.ancestors
    )
    return known_by_its_text and vocabulary.search(section.text) is None
