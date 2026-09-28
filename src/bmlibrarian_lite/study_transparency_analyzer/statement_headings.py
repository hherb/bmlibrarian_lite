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

The analyser recognises a statement only by its heading, and a heading it
does not know may be exactly that statement under a journal's own name:
Diabetologia's "Authors' relationships and activities" lists pharmaceutical
ties. Adding each name as it is found leaves the next journal in the same
hole.

So a missing statement is charged (-5 and a risk indicator) only when every
heading in the article's end matter is one this module knows: a statement,
or a known neighbour of one ("Publisher's note", "Abbreviations", ...). A
heading it does not know makes the result "not assessed" instead (#428). The
list of neighbours fails safe: a heading missing from it can only stop a
charge, never cause one.

Knowing the end matter's headings needs to know where the end matter is.
The JATS converter marks its start (``END_MATTER_MARKER``). Text extracted
from a PDF carries no such mark and no marked headings at all, so its end
matter cannot be told from its body; there is no segmenter for such text
yet (:func:`segment_unmarked_end_matter`), so :func:`end_matter_sections`
answers ``None`` and nothing is charged.
"""

import re
from dataclasses import dataclass

from ..jats_markdown import END_MATTER_MARKER, SECTION_HEADING_LEVEL

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
#: the analyser files it under. Every pattern here and in the lists below is
#: spliced into one anchored expression (:func:`_matches_heading`), so any
#: alternation in one must sit inside a group.
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
        # JACC's heading for its funding and competing interests statements
        # together, listing industry ties (PMC11198077, held-out survey,
        # review of #428).
        '(?:funding|financial) support and author disclosures?',
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
        # Found by the #428 survey, as below.
        '(?:research )?data transparency and availability',
    ),
    'funding': (
        'funding',
        # "Financial support & sponsorship" and the rest below were found
        # by the #428 survey, which needs every end-matter heading
        # classified: missed, each made its article "not assessed".
        'financial support(?: (?:&|and) sponsorship)?',
        'grant support',
        'sources? of (?:support|funding)',
        'funding (?:sources?|information)',
        'funding/support',
        'declarations? of sources? of funding',
    ),
    'funding_role': (
        'role of the funding source',
        'role of the funder',
        'role of the sponsor',
        # JAMA's heading (#428 survey).
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
        # BMC's heading (#428 survey).
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
    # its back matter, and its names in the survey's other languages.
    'references?', 'bibliography', 'further reading', 'literature cited',
    'literatur', 'bibliograf[íi]a',
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
    # Figure descriptions. The supplements are listed apart
    # (:data:`SUPPLEMENT_HEADING_PATTERNS`).
    '(?:the|this) pdf file includes', 'long descriptions?',
    # About the article and its authors.
    'how to cite', 'correction note', 'change history',
    'contributor information', 'citation diversity statement',
    'tweetable summary',
)

#: Supplementary material's headings. No place for a competing interests
#: statement, but one may say where the raw data are deposited, so when the
#: data availability statement is sought a supplement is known only by what
#: it holds (:data:`SUPPLEMENT_WORDING_BY_STATEMENT`).
SUPPLEMENT_HEADING_PATTERNS: tuple[str, ...] = (
    'supplementary (?:materials?|data|information)',
    'supplemental (?:materials?|information)',
    'supporting information(?: available)?',
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
    # A statement of its own, and the data statement's neighbour: "All code
    # and the underlying datasets are deposited at Zenodo" is both (review
    # of #428).
    'data_sharing': ('code availability',),
}

#: Headings that say nothing reliable of what they hold, so a section under
#: one is judged by its text: one whose text uses none of a statement's
#: vocabulary (:data:`COI_VOCABULARY_RE`, :data:`DATA_VOCABULARY_RE`) holds
#: no statement. They are the converter's fallbacks for untitled end matter
#: ("Footnotes" from ``DEFAULT_HEADING_BY_OWNER``, ``DEFAULT_HEADING``,
#: ``AUTHOR_NOTES_HEADING``), "Endnotes" as publishers print it, and named
#: headings that can still hold a disclosure (below). A statement can sit
#: under any of them: "The author discloses no conflicts of research
#: interest." as an author note (PMC12805416). The converter's other
#: fallbacks, "Acknowledgments" and "Glossary", are classified by name.
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
#: languages surveyed articles print one in. Broad: a word here found in a
#: catch-all section can only stop a charge, never cause one. But in its
#: disclosure forms only -- "financial interests", not "financ"; "stock
#: options", not "stock" -- or every economics paper's footnotes on interest
#: rates and stock returns go unassessed (#428 held-out survey). The ICMJE
#: form's own phrases ("personal fees from ..., outside the submitted work")
#: are listed too (review of #428).
COI_VOCABULARY_RE = re.compile(
    r'disclos|conflict|conflit|competing|\bdeclar(?:e|es|ed|ing|ation)\b'
    r'|honorari|consult(?:ant|anc|ing)|speaker|advisory|royalt|patents?\b'
    r'|stock options?|shareholder|equity (?:interest|holder|stake)'
    r'|(?:holds?|holding|owns?|owned) (?:\w+ )?shares\b'
    r'|employee of|employed by|financial (?:interest|relationship|support|tie)'
    r'|relationships? (?:with|to) (?:industry|compan)|\bgrants?\b|funded|funding'
    r'|personal fees|lecture fees|\bfees? from|outside the submitted work'
    r'|travel (?:support|grants?|expenses|reimbursements?)|\bcois?\b'
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

#: What betrays a data availability statement in a supplement's text: where
#: the data are deposited, or who holds them. Narrower than
#: :data:`DATA_VOCABULARY_RE`, since every supplement speaks of its "data"
#: ("Supplementary data to this article can be found online").
DATA_DEPOSIT_RE = re.compile(
    r'repositor|deposit|accession|osf\.io|github|gitlab|zenodo|figshare|dryad'
    r'|(?:up)?on (?:reasonable )?request'
    r'|data(?:sets?)? (?:are|is|will be) (?:publicly |freely |openly )?'
    r'(?:available|accessible|shared)',
    re.IGNORECASE,
)

#: The statements a supplement can hold, and the wording that shows it does.
SUPPLEMENT_WORDING_BY_STATEMENT: dict[str, "re.Pattern[str]"] = {
    'data_sharing': DATA_DEPOSIT_RE,
}

#: Words in a heading that say one statement may be under it, by the
#: statement's key; matched against the heading's words anywhere, not as a
#: whole. Phrases, not stems: "disclosure quality", "board duality" and "an
#: armed conflict" head economics and politics sections. A section known
#: only by its heading (:attr:`EndMatterSection.known_by_its_heading`) is
#: asked about for the statements its heading names this way.
HEADING_WORDS_BY_STATEMENT: dict[str, "re.Pattern[str]"] = {
    'coi': re.compile(
        r"conflicts? of (?:\w+ )?interests?|competing (?:financial )?interests?"
        r"|(?:authors?['’]?|financial|industry|conflicts?)\b[\w’'/ -]{0,25}"
        r"disclosures?|^disclosures?\b|duality of interests?"
        r"|relationships? (?:and|with|to) (?:activities|industry)"
        r"|financial[\w’'/ -]{0,25}(?:interests?|relationships?|ties)"
        r"|interessenkonflikt|conflits? d|conflictos? de|conflitos? de|利益冲突",
        re.IGNORECASE,
    ),
    'data_sharing': re.compile(
        r"data (?:and \w+ )?(?:availability|sharing|accessibility|access|deposition)"
        r"|availability of (?:the )?(?:data|materials?)"
        r"|(?:materials?|code|software) availability|数据",
        re.IGNORECASE,
    ),
}


@dataclass(frozen=True)
class EndMatterSection:
    """A heading of the end matter and the text it holds of its own.

    Attributes:
        heading: The heading line, stripped, ``#`` marks and all; the
            heading of the section an end-matter marker fell in, for the
            text after it; or :data:`UNHEADED` for text before any heading.
        text: Its non-blank lines, stripped, up to the next heading of any
            level (for the section a marker fell in, only those after the
            marker), joined by newlines; may be empty.
        ancestors: The headings of the sections it is a subsection of,
            outermost first; never the article's title.
        known_by_its_heading: Whether it is asked about only for the
            statement its heading's words name
            (:data:`HEADING_WORDS_BY_STATEMENT`): a body section before the
            end matter opens, or a heading with no text. The converter
            emits a heading alone over content it could not render --
            mostly an appendix table, but an ICMJE form is one too.
    """

    heading: str
    text: str
    ancestors: tuple[str, ...] = ()
    known_by_its_heading: bool = False

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
        True if it is :data:`UNHEADED` or matches
        :data:`CATCH_ALL_HEADING_PATTERNS`.
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


def _opens_the_end_matter(line: str) -> bool:
    """Whether a body line is a statement printed as a top-level section.

    Such a section opens the end matter even before the marker. A statement
    heading nested deeper does not: Lancet's "Role of the funding source"
    closes its Methods, and Cell's "Data and code availability" sits in its
    STAR Methods, with Results and Discussion still to come (review of
    #428). The extractor reads such a statement wherever it stands.

    Args:
        line: A stripped line of full text.

    Returns:
        True for a top-level markdown heading that names a statement.
    """
    return (
        markdown_heading_level(line) == SECTION_HEADING_LEVEL
        and statement_key_of_heading(line) is not None
    )


def _names_a_statement(words: str) -> bool:
    """Whether a heading's words name either statement a charge is about.

    Args:
        words: A heading's words, without ``#`` marks.

    Returns:
        True if any of :data:`HEADING_WORDS_BY_STATEMENT` matches.
    """
    return any(pattern.search(words) for pattern in HEADING_WORDS_BY_STATEMENT.values())


def end_matter_sections(fulltext: str) -> tuple[EndMatterSection, ...] | None:
    """The headed sections of a full text's end matter.

    The end matter opens at the earlier of the first end-matter marker (the
    converter marks end matter in the body too) and the first top-level
    statement heading before it (:func:`_opens_the_end_matter`); it runs to
    the end of the text. Every later body section is then end matter and is
    classified like any other heading.

    A body heading before that whose words name a statement
    (:data:`HEADING_WORDS_BY_STATEMENT`) is listed too, known only by its
    heading: JACC prints "Financial support and author disclosures" among
    its closing body sections, and one under a name the lists do not know
    would otherwise never be looked at (review of #428).

    Text after the marker but before any heading continues the section the
    marker fell in: an untitled footnote group inside a titled body section.
    With no heading before it at all, it is filed under :data:`UNHEADED`.

    Args:
        fulltext: The article's full text.

    Returns:
        Every heading of the end matter, in order, with the text it holds of
        its own. Without a marker, whatever
        :func:`segment_unmarked_end_matter` makes of the text: today always
        ``None``, since the end matter of PDF text, or of a converted
        article with no end-matter element, cannot be told from its body.
    """
    lines = [line.strip() for line in fulltext.split('\n')]
    marker = next(
        (index for index, line in enumerate(lines) if is_end_matter_marker(line)),
        None,
    )
    if marker is None:
        return segment_unmarked_end_matter(fulltext)
    start = next(
        (index for index, line in enumerate(lines[:marker]) if _opens_the_end_matter(line)),
        marker,
    )
    headed: list[tuple[str, tuple[str, ...], list[str], bool]] = []
    enclosing: list[tuple[int, str]] = []
    open_text: list[str] | None = None
    for index, line in enumerate(lines):
        level = markdown_heading_level(line)
        if level:
            while enclosing and enclosing[-1][0] >= level:
                enclosing.pop()
            ancestors = tuple(heading for _, heading in enclosing)
            # The article's title encloses everything and names nothing.
            if level >= SECTION_HEADING_LEVEL:
                enclosing.append((level, line))
            open_text = None
            before = index < start
            if not before or _names_a_statement(line.lstrip('#').strip()):
                open_text = []
                headed.append((line, ancestors, open_text, before))
        elif index > start and line and not is_end_matter_marker(line):
            if open_text is None:
                # The marker fell inside a section: this is its text.
                open_text = []
                heading, ancestors = (
                    (enclosing[-1][1], tuple(h for _, h in enclosing[:-1]))
                    if enclosing
                    else (UNHEADED, ())
                )
                headed.append((heading, ancestors, open_text, False))
            open_text.append(line)
        elif open_text is not None and line and not is_end_matter_marker(line):
            open_text.append(line)
    return tuple(
        EndMatterSection(
            heading, '\n'.join(text), ancestors,
            known_by_its_heading=before or not text,
        )
        for heading, ancestors, text, before in headed
    )


def segment_unmarked_end_matter(fulltext: str) -> tuple[EndMatterSection, ...] | None:
    """Segment end matter the converter did not mark: a stub (#430).

    A PDF's extracted text marks neither its headings nor where its end
    matter begins, so nothing here can tell a statement's heading from a
    line of prose. This is where a segmentation of such text belongs --
    for example a model reading the PDF into sections as the JATS converter
    does -- once one exists. Until then every such text answers ``None``,
    and a statement not found in it is not assessed rather than charged.

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

    A section known only by its heading
    (:attr:`EndMatterSection.known_by_its_heading`) is unclassified when
    its heading is the sought statement's, or its words name that statement
    (:data:`HEADING_WORDS_BY_STATEMENT`). Any other is classified when it:

    - names a statement other than the one sought, or a known neighbour;
    - names a part of a statement other than the one sought (Cureus's ICMJE
      parts, when data availability is sought);
    - names a supplement, and its text does not say where data are
      deposited when data availability is sought; or
    - is known only by what it holds -- a catch-all, or a subsection of a
      named or catch-all section (Springer's per-author biographies,
      Cureus's per-author roles under "Author Contributions") -- and its
      text uses none of the sought statement's vocabulary.

    The sought statement's own heading is never classified: the extractor
    read nothing from it, or the analyser would not be asking.

    Args:
        sections: The end matter, from :func:`end_matter_sections`.
        sought: The key of the statement sought, one of
            :data:`VOCABULARY_BY_STATEMENT`.

    Returns:
        Each unclassified heading's words, without ``#`` marks, once each,
        in order.

    Raises:
        KeyError: When ``sought`` is no statement a missing one can be
            charged for, whatever the sections.
    """
    vocabulary = VOCABULARY_BY_STATEMENT[sought]
    return tuple(dict.fromkeys(
        section.words
        for section in sections
        if not _is_classified(section, sought, vocabulary)
    ))


def _is_named(heading: str) -> bool:
    """Whether a heading names a statement, a known neighbour or a supplement.

    Args:
        heading: A heading line.

    Returns:
        True if it matches any of those lists.
    """
    return (
        statement_key_of_heading(heading) is not None
        or is_known_non_statement_heading(heading)
        or _matches_any(heading, SUPPLEMENT_HEADING_PATTERNS)
    )


def _is_classified(
    section: EndMatterSection, sought: str, vocabulary: "re.Pattern[str]"
) -> bool:
    """Whether a section of the end matter cannot hold the statement sought.

    Args:
        section: The section.
        sought: The key of the statement sought.
        vocabulary: That statement's vocabulary.

    Returns:
        True if it is classified as :func:`unclassified_headings` describes.
    """
    heading, text = section.heading, section.text
    key = statement_key_of_heading(heading)
    if key is not None:
        return key != sought
    if section.known_by_its_heading:
        return HEADING_WORDS_BY_STATEMENT[sought].search(section.words) is None
    if is_known_non_statement_heading(heading):
        return True
    if any(
        _matches_any(heading, patterns)
        for statement, patterns in STATEMENT_PART_HEADING_PATTERNS.items()
        if statement != sought
    ):
        return True
    if _matches_any(heading, SUPPLEMENT_HEADING_PATTERNS):
        wording = SUPPLEMENT_WORDING_BY_STATEMENT.get(sought)
        return wording is None or wording.search(text) is None
    known_by_its_text = is_catch_all_heading(heading) or any(
        _is_named(ancestor) or is_catch_all_heading(ancestor)
        for ancestor in section.ancestors
    )
    return known_by_its_text and vocabulary.search(text) is None
