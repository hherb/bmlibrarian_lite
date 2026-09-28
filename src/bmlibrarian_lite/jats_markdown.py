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

"""JATS XML to markdown, for the reader and for the transparency analyser.

The markdown is what the document view shows, what interrogation embeds and
what the transparency analyser segments. The analyser recognises a statement
only by its heading (``extract_fulltext_sections``), so a statement this
module drops, or emits without a heading, is one the analyser never sees --
and an article in which it recognises nothing is rated as though its full
text had not been read (#386).

Until #420 only the front matter's title, authors and abstract, the body and
the reference list reached the markdown. Everything else was dropped:

- every ``<back>`` element but ``<ref-list>`` -- the ``<sec>``, ``<notes>``,
  ``<ack>`` and ``<fn-group>`` where most journals put their competing
  interests, data availability, funding and contribution statements;
- the statements PLOS journals put in the *front* matter: the competing
  interests footnote in ``<author-notes>``, a titled ``<notes>`` holding the
  data availability statement, and ``<funding-statement>``.

A 2026-09-27 survey of 150 PLOS ONE research articles found the competing
interests statement recognised in none of them; of 299 recent research
articles across journals, 146 had no statement recognised at all.

Statements are emitted after the body and before the references, each under
its own heading. A heading also ends the section before it in the analyser,
so a Publisher's note that follows a competing interests statement is not
read as part of it. For the same reason nothing in the end matter is emitted
without a heading once a sibling has had one: an untitled abbreviation list
or disclaimer printed after a competing interests statement would otherwise
be read as part of it, and a vaccine maker it names as an industry tie
(#426 review).

The end matter opens with :data:`END_MATTER_MARKER`, wherever it first
appears. The analyser charges a missing statement only when it knows every
heading after the marker (#428), so a heading this module emits there is
one ``study_transparency_analyzer.statement_headings`` must classify.
"""

import copy
import logging
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from html import unescape

logger = logging.getLogger(__name__)

#: Identifies the markdown this module produces. Cached markdown carries it
#: (``pdf_utils.save_fulltext_markdown``), and a file stamped with any other
#: version is converted again rather than read. **Bump it whenever the same
#: XML would convert to different markdown**, or a fix here reaches only
#: articles nobody has opened yet.
#:
#: 1: every file cached before the stamp existed (implicitly; they carry none).
#: 2: #420 -- back matter, front-matter statements, body paragraphs before the
#: first section, and nested sections emitted once instead of twice.
#: 3: the review of PR #426 -- end-matter pieces headed, repeated statement
#: headings merged, body run-ins kept inline, sub-articles ignored. Bumped
#: before release, so no file a pre-review build of the branch cached is
#: trusted.
#: 4: #428 -- :data:`END_MATTER_MARKER` opens the end matter.
JATS_MARKDOWN_CONVERTER_VERSION = 4

#: The line that opens the end matter: the back matter and the front-matter
#: statements, after the body. Everything after it is end matter. It tells
#: the transparency analyser which headings are the article's statements and
#: their neighbours, so that a missing statement is charged only when every
#: one of them is a heading it knows (#428). An HTML comment, so that no
#: markdown view shows it.
END_MATTER_MARKER = "<!-- bmlibrarian-lite end-matter -->"

#: The heading a statement gets from its type when the article gives it no
#: heading of its own. Read from ``fn-type``, ``notes-type`` and ``sec-type``:
#: PLOS types its competing interests footnote, ACS its untitled ``<notes>``.
#: Keys are case-folded, because deposits vary the case of ``COI-statement``.
#: Only statement types are listed. An element of any other type without a
#: heading gets a neutral one in the end matter (:data:`DEFAULT_HEADING_BY_OWNER`);
#: in the front matter an author-notes footnote is kept under "Author Notes",
#: and an untitled ``<notes>`` contributes only its titled sections.
STATEMENT_HEADING_BY_TYPE: dict[str, str] = {
    "coi-statement": "Competing Interests",
    "conflict": "Competing Interests",
    "conflict-of-interest": "Competing Interests",
    "financial-disclosure": "Funding",
    "supported-by": "Funding",
    "funding": "Funding",
    "funding-statement": "Funding",
    "data-availability": "Data Availability",
    "con": "Author Contributions",
    "author-contributions": "Author Contributions",
    "abbr": "Abbreviations",
}

#: The attributes a JATS element states its type in.
_TYPE_ATTRIBUTES = ("fn-type", "notes-type", "sec-type")

#: The heading an end-matter piece without one is emitted under, by the tag
#: of the element that holds it. Given only where the piece would otherwise
#: run on into a heading that is not its own: at the top of the end matter,
#: or after a sibling that had a heading. An ``<ack>`` some publishers wrap
#: their declarations in gets none, since each of its sections has its own.
DEFAULT_HEADING_BY_OWNER: dict[str, str] = {
    "ack": "Acknowledgments",
    "glossary": "Glossary",
    "fn": "Footnotes",
    "fn-group": "Footnotes",
}

#: The heading for an end-matter piece whose holder is not in
#: :data:`DEFAULT_HEADING_BY_OWNER`. No statement heading the analyser
#: recognises: a piece nobody headed is not a statement we know.
DEFAULT_HEADING = "Notes"

#: The heading a competing interests statement is emitted under when only
#: its wording says what it is.
COI_HEADING = "Competing Interests"

#: Wording that marks a footnote as a competing interests statement when it
#: carries no heading or type ("The authors declared no potential conflicts
#: of interest ..."). Shared with the analyser, which will not charge a
#: missing statement against a text that uses it (#420 review). Diabetologia
#: words its statement "no relationships or activities that might bias ...
#: their work", and some journals "no duality of interest" (#426 review).
COI_WORDING_PATTERN = (
    r"conflicts? of interests?|competing (?:financial )?interests?"
    r"|duality of interests?|relationships? (?:or|and) activities"
)
_COI_WORDING_RE = re.compile(COI_WORDING_PATTERN, re.IGNORECASE)

#: What makes a footnote that uses that wording a declaration rather than a
#: sentence about conflicts of interest: it declares, or it denies. A
#: meta-research footnote ("trials were coded as having conflicts of
#: interest when ...") is neither, and heading it "Competing Interests"
#: would put it before the article's real statement (#426 review).
_DECLARATION_RE = re.compile(
    r"\b(?:declared?s?|disclosed?s?|none|no|nothing|not)\b", re.IGNORECASE
)

#: The heading author-notes footnotes without one of their own are kept under.
AUTHOR_NOTES_HEADING = "Author Notes"

#: The heading ``<funding-statement>`` is emitted under.
FUNDING_STATEMENT_HEADING = "Funding"

#: The level of a top-level section heading (``##``); the title is ``#``.
SECTION_HEADING_LEVEL = 2

#: Markdown has six heading levels.
MAX_HEADING_LEVEL = 6

#: The longest bold run that is read as a heading. A footnote whose whole
#: first sentence is bold is emphasis, not a heading, and the analyser
#: ignores heading lines longer than 120 characters anyway.
MAX_RUN_IN_HEADING_CHARS = 80

#: A label names its element only when it holds a word. Markers -- ``*``,
#: ``†``, ``1``, ``a`` -- do not, and are dropped as they always were.
_WORD_RE = re.compile(r"[^\W\d_]{3,}")

#: Containers rendered as sections of their own wherever they appear.
#: ``<statement>`` among them: one journal wraps its competing interests
#: text in it inside the titled section, and an unknown tag renders to
#: nothing, so the disclosure was lost (#426 review).
_BLOCK_TAGS = frozenset({
    "sec", "notes", "ack", "app", "app-group", "boxed-text", "fn-group",
    "fn", "glossary", "bio", "statement",
})

#: Containers that are end matter wherever they appear. Europe PMC serves
#: some articles with no ``<back>`` at all, their footnotes, funding and
#: competing interests statements in a ``<sec>`` of the body; read as body,
#: a bare "The authors declared no potential conflicts of interest" footnote
#: after a funding one was read as part of the funding statement.
_END_MATTER_TAGS = frozenset({"fn-group", "fn", "notes", "ack", "glossary"})

#: Lists whose own ``<title>`` heads them. JMIR prints its abbreviations as
#: an untitled ``<notes>`` holding ``<def-list><title>Abbreviations</title>``
#: straight after the competing interests footnote; with the title dropped,
#: the list was read as part of the statement (#426 review).
_TITLED_LIST_TAGS = frozenset({"list", "def-list"})

#: Front-matter containers that can hold statements, besides the
#: ``<author-notes>``, ``<notes>`` and ``<funding-statement>`` read by name.
#: JATS allows each as a direct child of ``<front>``.
_FRONT_STATEMENT_CONTAINERS = frozenset({"fn-group", "ack", "glossary"})

#: Elements that are known to carry no prose, so dropping them in the end
#: matter is not worth a log line.
_SILENT_TAGS = frozenset({
    "ref-list", "title", "label", "disp-formula", "inline-formula",
    "alternatives", "graphic", "media", "table", "object-id",
})

_XLINK_HREF = "{http://www.w3.org/1999/xlink}href"


def jats_to_markdown(xml_content: str) -> str:
    """Convert a JATS article to markdown.

    Args:
        xml_content: The article's JATS XML, as Europe PMC serves it.

    Returns:
        The markdown: title, authors, journal line and abstract; the body;
        :data:`END_MATTER_MARKER`, then the back matter and the front-matter
        statements, each under its own heading; then the references. The
        marker is left out when there is no end matter. An empty string when
        the XML does not parse.
    """
    try:
        root = ET.fromstring(xml_content)
    except ET.ParseError as e:
        logger.error("Failed to parse JATS XML: %s", e)
        return ""

    parts: list[str] = []
    article = _article_element(root)

    # The article's own parts, not the first found anywhere: a decision
    # letter or author reply is a <sub-article> with its own <back>, and
    # in an article without one, "Competing interests: Reviewer has none"
    # was read as the study's statement (#426 review).
    front = article.find("front")
    if front is not None:
        parts.append(_front_matter(front))

    body = article.find("body")
    if body is not None:
        parts.append(_body(body))

    end_matter: list[str] = []
    back = article.find("back")
    if back is not None:
        end_matter.append(_back_matter(back))

    if front is not None:
        already = "\n\n".join(parts + end_matter)
        end_matter.extend(_front_statements(front, already))

    end_matter = [part for part in end_matter if part]
    if end_matter:
        parts.append(END_MATTER_MARKER)
        parts.extend(end_matter)

    if back is not None:
        parts.append(_references(back))

    return "\n\n".join(part for part in parts if part)


def _article_element(root: ET.Element) -> ET.Element:
    """The ``<article>`` whose parts are converted.

    Args:
        root: The parsed document's root: the article itself as Europe PMC
            serves it, or a wrapper such as ``<pmc-articleset>``.

    Returns:
        The root when it is the article, else the first ``<article>`` in it,
        else the root, so a fragment without one still converts.
    """
    if root.tag == "article":
        return root
    article = root.find(".//article")
    return article if article is not None else root


def _front_matter(front: ET.Element) -> str:
    """Render the title, authors, journal line and abstract.

    Args:
        front: The article's ``<front>``.

    Returns:
        The rendered lines, or an empty string when none are present.
    """
    parts = []

    title_group = front.find(".//title-group")
    if title_group is not None:
        article_title = title_group.find("article-title")
        if article_title is not None:
            parts.append(f"# {text_of(article_title)}")

    contrib_group = front.find(".//contrib-group")
    if contrib_group is not None:
        authors = []
        for contrib in contrib_group.findall("contrib[@contrib-type='author']"):
            name = contrib.find("name")
            if name is not None:
                given = name.findtext("given-names", "")
                surname = name.findtext("surname", "")
                if surname:
                    authors.append(f"{given} {surname}".strip())
        if authors:
            parts.append(f"**Authors:** {', '.join(authors)}")

    journal_meta = front.find(".//journal-meta")
    article_meta = front.find(".//article-meta")

    meta_parts = []
    if journal_meta is not None:
        journal_title = journal_meta.findtext(".//journal-title", "")
        if journal_title:
            meta_parts.append(f"*{journal_title}*")

    if article_meta is not None:
        pub_date = article_meta.find(".//pub-date")
        if pub_date is not None:
            year = pub_date.findtext("year", "")
            if year:
                meta_parts.append(f"({year})")

        for article_id in article_meta.findall("article-id"):
            if article_id.get("pub-id-type") == "doi":
                doi = article_id.text
                if doi:
                    meta_parts.append(f"DOI: {doi}")
                    break

    if meta_parts:
        parts.append(" | ".join(meta_parts))

    abstract = front.find(".//abstract")
    if abstract is not None:
        abstract_text = text_of(abstract)
        if abstract_text:
            parts.append(f"## Abstract\n\n{abstract_text}")

    return "\n\n".join(parts)


def _body(body: ET.Element) -> str:
    """Render the body in document order.

    Walking ``body.findall(".//sec")`` emitted every nested section twice
    (once inside its parent, once on its own) and dropped the paragraphs
    before the first section, which 66 of 700 surveyed articles have.

    Args:
        body: The article's ``<body>``.

    Returns:
        The body's markdown. When the walk renders nothing, every ``<p>`` in
        the body, so a body wrapped in an element this module does not know
        is not lost.
    """
    rendered = _render_children(body, SECTION_HEADING_LEVEL)
    if rendered:
        return rendered
    paragraphs = [text_of(p) for p in body.iter("p")]
    return "\n\n".join(p for p in paragraphs if p)


def _back_matter(back: ET.Element) -> str:
    """Render everything in ``<back>`` but the reference list.

    Args:
        back: The article's ``<back>``.

    Returns:
        Each back-matter element under its heading, in document order.
    """
    return _render_children(back, SECTION_HEADING_LEVEL, end_matter=True)


def _front_statements(front: ET.Element, already: str) -> list[str]:
    """Render the statements an article keeps in its front matter.

    An author-notes footnote with a heading is a statement under it; those
    without one -- "these authors contributed equally", and BMJ's bare
    "None declared." -- are kept together under "Author Notes", as are the
    paragraphs JATS allows directly in ``<author-notes>``. A ``<fn-group>``,
    ``<ack>`` or ``<glossary>`` placed directly in ``<front>`` is rendered as
    back matter is. The ``custom-meta`` data availability PLOS deposits is
    left out: it repeats the titled ``<notes>`` in every surveyed article
    that has one.

    Args:
        front: The article's ``<front>``.
        already: The markdown rendered so far. A statement it already holds,
            under the same heading, is not repeated.

    Returns:
        The rendered statements, in document order.
    """
    candidates: list[str] = []

    for notes in front.iter("author-notes"):
        unheaded: list[str] = []
        # A paragraph inside a footnote is the footnote's; only one standing
        # directly in <author-notes> is read on its own.
        direct_paragraphs = {id(child) for child in notes if child.tag == "p"}
        for note in notes.iter():
            if note.tag == "fn" and _heading_of(note) is not None:
                candidates.append(
                    _render_element(note, SECTION_HEADING_LEVEL, end_matter=True)
                )
            elif note.tag == "fn" or id(note) in direct_paragraphs:
                text = text_of(note)
                if not text:
                    continue
                if _is_coi_declaration(text):
                    candidates.append(
                        f"{_heading_line(COI_HEADING, SECTION_HEADING_LEVEL)}\n\n{text}"
                    )
                else:
                    unheaded.append(text)
        if unheaded:
            # Kept, not dropped: BMJ deposits its competing interests
            # statement as a bare "None declared." footnote here, and a
            # statement the analyser never sees reads as one never made.
            candidates.append(
                _heading_line(AUTHOR_NOTES_HEADING, SECTION_HEADING_LEVEL)
                + "\n\n"
                + "\n\n".join(unheaded)
            )

    for notes in front.iter("notes"):
        if _heading_of(notes) is not None:
            candidates.append(
                _render_element(notes, SECTION_HEADING_LEVEL, end_matter=True)
            )
            continue
        # An untitled front <notes> is PLOS's article-history wrapper; only
        # the titled sections inside it are statements.
        for sec in notes.findall("sec"):
            if _heading_of(sec) is not None:
                candidates.append(
                    _render_element(sec, SECTION_HEADING_LEVEL, end_matter=True)
                )

    containers = [child for child in front if child.tag in _FRONT_STATEMENT_CONTAINERS]
    if containers:
        holder = ET.Element("front-statements")
        holder.extend(containers)
        candidates.append(
            _render_children(holder, SECTION_HEADING_LEVEL, end_matter=True)
        )

    for statement in front.iter("funding-statement"):
        text = text_of(statement)
        if text:
            candidates.append(
                f"{_heading_line(FUNDING_STATEMENT_HEADING, SECTION_HEADING_LEVEL)}"
                f"\n\n{text}"
            )

    # Compared heading and statement together: a statement's words alone
    # can be a single "None", which any article contains, and dropping it as
    # a duplicate charged the study for a missing statement (#420 review).
    # Whole words only, for the same reason: "## Funding None" is not
    # repeated by a body that says "cofunding none of ..." (#426 review).
    seen = f" {_comparable(already)} "
    kept = []
    for candidate in candidates:
        if not candidate:
            continue
        comparable = _comparable(candidate)
        if f" {comparable} " in seen:
            continue
        kept.append(candidate)
        seen += f"{comparable} "
    return kept


def _references(back: ET.Element) -> str:
    """Render the reference list.

    Args:
        back: The article's ``<back>``.

    Returns:
        A ``## References`` list, or an empty string when there is none.
    """
    ref_list = back.find(".//ref-list")
    if ref_list is None:
        return ""

    parts = ["## References"]

    for ref in ref_list.findall("ref"):
        citation = ref.find(".//mixed-citation")
        if citation is None:
            citation = ref.find(".//element-citation")

        if citation is not None:
            ref_text = text_of(citation)
            if ref_text:
                parts.append(f"- {' '.join(ref_text.split())}")

    if len(parts) == 1:
        return ""

    return "\n".join(parts)


def _render_element(
    element: ET.Element,
    level: int,
    end_matter: bool = False,
    in_force: str | None = None,
) -> str:
    """Render one element of a body or back-matter walk.

    Args:
        element: The element.
        level: The heading level a section here would take.
        end_matter: Whether the element is back matter or a front-matter
            statement, where every piece gets a heading. An element in
            :data:`_END_MATTER_TAGS` is end matter wherever it stands.
        in_force: The heading the element falls under. A section headed the
            same is not headed again: eLife prints one footnote per author
            group under a titled "Competing interests" group, and with each
            footnote headed anew the analyser read only the first (#426
            review).

    Returns:
        Its markdown, or an empty string for an element that renders to
        nothing. An element this module does not know renders to nothing,
        which keeps display formulas and other machine markup out of the
        prose (#399).
    """
    tag = element.tag
    end_matter = end_matter or tag in _END_MATTER_TAGS
    if tag in _BLOCK_TAGS:
        return _render_block(element, level, end_matter, in_force)
    if tag == "p":
        return text_of(element)
    if tag in _TITLED_LIST_TAGS:
        items = _render_list(element) if tag == "list" else _render_def_list(element)
        title = text_of(element.find("title"))
        if not title or _same_heading(title, in_force):
            return items
        heading_line = _heading_line(title, level)
        return f"{heading_line}\n\n{items}" if items else heading_line
    if tag == "disp-quote":
        return text_of(element)
    if tag == "table-wrap":
        caption = text_of(element.find(".//caption/p"))
        return f"*Table: {caption}*" if caption else ""
    if tag == "fig":
        caption = text_of(element.find(".//caption/p"))
        return f"*Figure: {caption}*" if caption else ""
    if end_matter and tag not in _SILENT_TAGS and text_of(element):
        logger.debug("Dropped a <%s> holding text from the end matter", tag)
    return ""


def _render_block(
    block: ET.Element,
    level: int,
    end_matter: bool = False,
    in_force: str | None = None,
) -> str:
    """Render a section-like element under its heading.

    Args:
        block: A ``<sec>``, ``<notes>``, ``<fn>`` or other container.
        level: Its heading level.
        end_matter: Whether it is back matter or a front-matter statement.
        in_force: The heading it falls under; a block headed the same is not
            headed again (see :func:`_render_element`).

    Returns:
        The heading, when it has one, followed by its content. The content
        of a block without a heading is rendered at the block's own level.
        When a stated type supplied the heading and the article printed a
        different one, the article's opens the content in bold, so the
        reader still sees it.
    """
    found = _heading_of(block)
    if found is None:
        return _render_children(block, level, end_matter, in_force)

    if found.from_run_in:
        block = _without_run_in(block)
    # A block headed by its first paragraph's run-in holds statements side by
    # side, so a later run-in heads a sibling, not a subsection: nested one
    # level down, a "Publisher's note" run-in did not end the competing
    # interests statement it followed (#426 review).
    content = _render_children(
        block,
        level + 1,
        end_matter,
        in_force=found.heading,
        run_in_level=level if found.from_run_in else None,
    )
    if found.printed is not None:
        content = f"**{found.printed}**\n\n{content}" if content else f"**{found.printed}**"
    if _same_heading(found.heading, in_force):
        return content
    heading_line = _heading_line(found.heading, level)
    return f"{heading_line}\n\n{content}" if content else heading_line


def _render_children(
    parent: ET.Element,
    level: int,
    end_matter: bool = False,
    in_force: str | None = None,
    run_in_level: int | None = None,
) -> str:
    """Render an element's children in document order.

    A child block without a heading contributes its own children in its
    place (see :func:`_pieces`).

    A paragraph opening with a bold run-in ending in a colon becomes a
    heading of its own: several statements often share one container
    ("**Source of support:** Nil" then "**Conflict of interest:** None"),
    and only the first used to be headed, so the second was read as part of
    the first (#420 review). In the body only a run-in no plain paragraph
    follows does: a heading cannot be closed in markdown, so "**Data
    availability:** On request." in the middle of the methods made the rest
    of the methods its statement (#426 review).

    In the end matter a piece without a heading of its own gets one when it
    would otherwise fall under a heading that is not its own -- at the top,
    or after a sibling that had one (:data:`DEFAULT_HEADING_BY_OWNER`). A
    piece after a run-in in the same holder is taken as the run-in's own
    continuation.

    Args:
        parent: The element whose children are rendered.
        level: The heading level a section among them would take.
        end_matter: Whether they are back matter or a front-matter statement.
        in_force: The parent's heading, which they fall under until one of
            them has a heading; ``None`` when the parent has none.
        run_in_level: The level a run-in heading here takes; ``level`` when
            not given.

    Returns:
        Their markdown, joined by blank lines.
    """
    pieces = _pieces(parent, end_matter)
    sibling_level = run_in_level or level
    parts = []
    # End matter inside the body -- a journal that keeps its footnotes, and
    # the competing interests statement among them, in a <sec> of the body
    # -- is marked where it begins, as the back matter is (#428).
    marked = end_matter
    current = in_force
    heading_holder: ET.Element | None = None
    headed_here = False
    for index, piece in enumerate(pieces):
        child, holder = piece.element, piece.holder
        if child.tag == "p":
            run_in = _paragraph_run_in(child, colon_only=True)
            if run_in is not None and (
                piece.end_matter or _only_run_ins_follow(pieces[index + 1:])
            ):
                rest = text_of(_paragraph_without_run_in(child))
                heading_line = _heading_line(run_in, sibling_level)
                if piece.end_matter and not marked:
                    parts.append(END_MATTER_MARKER)
                    marked = True
                parts.append(f"{heading_line}\n\n{rest}" if rest else heading_line)
                current, heading_holder, headed_here = run_in, holder, True
                continue

        found = _piece_heading(child)
        rendered = _render_element(child, level, piece.end_matter, current)
        if not rendered:
            continue
        if found is not None:
            if not _same_heading(found.heading, current):
                current, heading_holder, headed_here = found.heading, child, True
        elif piece.end_matter and (
            current is None or (headed_here and heading_holder is not holder)
        ):
            default = DEFAULT_HEADING_BY_OWNER.get(holder.tag, DEFAULT_HEADING)
            if not _same_heading(default, current):
                rendered = f"{_heading_line(default, sibling_level)}\n\n{rendered}"
            current, heading_holder, headed_here = default, holder, True
        if piece.end_matter and not marked:
            parts.append(END_MATTER_MARKER)
            marked = True
        parts.append(rendered)
    return "\n\n".join(parts)


@dataclass(frozen=True)
class _Piece:
    """One piece of a walk: a child, or the child of a block without a heading.

    Attributes:
        element: The piece.
        holder: The element it is a direct child of.
        end_matter: Whether it is end matter (see :data:`_END_MATTER_TAGS`).
    """

    element: ET.Element
    holder: ET.Element
    end_matter: bool


def _pieces(parent: ET.Element, end_matter: bool) -> list[_Piece]:
    """An element's children, each paired with the element that holds it.

    A child block without a heading is replaced by its own pieces: it opens
    no section, so what it holds stands beside its siblings. Its title and
    label are skipped, as the parent's are.

    Args:
        parent: The element.
        end_matter: Whether it is back matter or a front-matter statement.

    Returns:
        The pieces in document order.
    """
    pieces: list[_Piece] = []
    for child in parent:
        if child.tag in ("title", "label"):
            continue
        child_end_matter = end_matter or child.tag in _END_MATTER_TAGS
        if child.tag in _BLOCK_TAGS and _heading_of(child) is None:
            pieces.extend(_pieces(child, child_end_matter))
        else:
            pieces.append(_Piece(child, parent, child_end_matter))
    return pieces


def _only_run_ins_follow(pieces: list[_Piece]) -> bool:
    """Whether every paragraph among some pieces opens with a run-in.

    Args:
        pieces: The pieces after a run-in paragraph.

    Returns:
        True if no plain paragraph is among them.
    """
    return all(
        _paragraph_run_in(piece.element, colon_only=True) is not None
        for piece in pieces
        if piece.element.tag == "p"
    )


def _piece_heading(piece: ET.Element) -> "_Heading | None":
    """The heading a piece of a walk opens, if any.

    Args:
        piece: A child from :func:`_pieces`.

    Returns:
        The block's heading, or a list's own title, or ``None``.
    """
    if piece.tag in _BLOCK_TAGS:
        return _heading_of(piece)
    if piece.tag in _TITLED_LIST_TAGS:
        title = text_of(piece.find("title"))
        return _Heading(title) if title else None
    return None


def _same_heading(heading: str, other: str | None) -> bool:
    """Whether two headings are the same, ignoring case and spacing.

    Args:
        heading: A heading.
        other: Another, or ``None``.

    Returns:
        True if ``other`` is given and reads the same.
    """
    return other is not None and _normalised(heading) == _normalised(other)


@dataclass(frozen=True)
class _Heading:
    """The heading an element is rendered under.

    Attributes:
        heading: The heading line's text.
        from_run_in: Whether the article's own heading was a run-in, which
            is then taken out of the paragraph it opened.
        printed: The article's own heading when a stated type replaced it,
            else ``None``.
    """

    heading: str
    from_run_in: bool = False
    printed: str | None = None


def _heading_of(element: ET.Element) -> _Heading | None:
    """Find the heading an element is rendered under.

    The article's own heading is a ``<title>``, else a ``<label>`` that holds
    a word, else a run-in opening its first paragraph ("**Competing
    Interests:** The authors ..."). A *stated* statement type -- ``fn-type``,
    ``notes-type`` or ``sec-type`` -- outranks it on an element that holds
    no sections of its own: the analyser recognises English headings only,
    and "Conflicts of interest/Competing interests", "INTERESSENKONFLIKT"
    or "Disclosure and potential conflicts of interest" under a
    ``COI-statement`` type are all one statement it would otherwise miss.
    Then a footnote -- end matter wherever it stands -- that declares its
    conflicts of interest (:func:`_is_coi_declaration`). A footnote inside
    a body paragraph is not a block, and is read as the paragraph's text.

    Args:
        element: The element.

    Returns:
        The heading, or ``None`` when the element carries none.
    """
    own: str | None = None
    from_run_in = False
    title = text_of(element.find("title"))
    label = text_of(element.find("label"))
    if title:
        own = title
    elif label and _WORD_RE.search(label):
        own = label
    else:
        run_in = _run_in_heading(element)
        if run_in is not None:
            own, from_run_in = run_in, True

    stated = _stated_statement_heading(element)
    if stated is not None and not _holds_sections(element):
        printed = own if own is not None and _normalised(own) != _normalised(stated) else None
        return _Heading(stated, from_run_in, printed)
    if own is not None:
        return _Heading(own, from_run_in)
    if element.tag == "fn" and _is_coi_declaration(text_of(element)):
        return _Heading(COI_HEADING)
    return None


def _is_coi_declaration(text: str) -> bool:
    """Whether a text without a heading declares competing interests.

    Args:
        text: A footnote's or paragraph's text.

    Returns:
        True if it uses the wording of a competing interests statement and
        declares or denies something (:data:`_DECLARATION_RE`).
    """
    return (
        _COI_WORDING_RE.search(text) is not None
        and _DECLARATION_RE.search(text) is not None
    )


def _stated_statement_heading(element: ET.Element) -> str | None:
    """The heading an element's stated statement type maps to.

    Args:
        element: The element.

    Returns:
        The canonical heading, or ``None`` when no statement type is stated.
    """
    for attribute in _TYPE_ATTRIBUTES:
        stated_type = (element.get(attribute) or "").casefold()
        if stated_type in STATEMENT_HEADING_BY_TYPE:
            return STATEMENT_HEADING_BY_TYPE[stated_type]
    return None


def _holds_sections(element: ET.Element) -> bool:
    """Whether an element wraps statements of its own.

    A ``sec-type="COI-statement"`` around a whole "Declarations" block must
    not head its funding subsection "Competing Interests".

    Args:
        element: The element.

    Returns:
        True if any child is itself a section-like container.
    """
    return any(child.tag in _BLOCK_TAGS for child in element)


def _run_in_heading(element: ET.Element) -> str | None:
    """Read a run-in heading from an element's first paragraph.

    Args:
        element: A section-like element.

    Returns:
        The heading text, without its colon, or ``None`` when the first
        paragraph opens otherwise (see :func:`_paragraph_run_in`).
    """
    first = _first_content_child(element)
    if first is None or first.tag != "p":
        return None
    return _paragraph_run_in(first, colon_only=False, in_footnote=element.tag == "fn")


def _paragraph_run_in(
    paragraph: ET.Element, colon_only: bool, in_footnote: bool = False
) -> str | None:
    """Read a run-in heading from a paragraph.

    A run-in is a ``<bold>`` or ``<italic>`` that opens the paragraph and
    ends in a colon ("**Funding:** ...", "*Funding*: ..."). Unless
    ``colon_only``, a bold opening is also one when it is the whole
    paragraph, or when the paragraph opens a footnote ("**Conflict of
    Interest** None declared."), where a leading bold phrase is always a
    heading. An italic opening without a colon never is: in the surveyed
    footnotes those are the titles of cited works.

    Args:
        paragraph: A ``<p>``.
        colon_only: Accept only a bold opening ending in a colon -- the rule
            for a paragraph that is not its element's first.
        in_footnote: Whether the paragraph opens a footnote.

    Returns:
        The heading text, without its colon, or ``None``.
    """
    if len(paragraph) == 0 or (paragraph.text or "").strip():
        return None
    opening = paragraph[0]
    if opening.tag not in ("bold", "italic"):
        return None
    if colon_only and opening.tag != "bold":
        return None

    heading = text_of(opening)
    tail = (opening.tail or "").strip()
    ends_in_colon = heading.endswith(":") or tail.startswith(":")
    is_whole_paragraph = not tail and len(paragraph) == 1
    is_footnote_lead = in_footnote and opening.tag == "bold"
    if colon_only:
        qualifies = ends_in_colon
    else:
        qualifies = ends_in_colon or (
            opening.tag == "bold" and (is_whole_paragraph or is_footnote_lead)
        )
    if not heading or not qualifies:
        return None
    heading = heading.rstrip(":").strip()
    if len(heading) > MAX_RUN_IN_HEADING_CHARS:
        return None
    # A marker is no heading: "<bold>*</bold> Deceased." was headed "*",
    # which the label rule has always refused (#426 review).
    if not _WORD_RE.search(heading):
        return None
    return heading


def _paragraph_without_run_in(paragraph: ET.Element) -> ET.Element:
    """A copy of a paragraph with its opening run-in taken out.

    Args:
        paragraph: A ``<p>`` that opens with a run-in heading.

    Returns:
        The copy, starting with the text after the heading, its colon
        removed. ``paragraph`` is left unchanged.
    """
    copied = copy.deepcopy(paragraph)
    if len(copied) == 0:
        return copied
    opening = copied[0]
    tail = (opening.tail or "").lstrip()
    if tail.startswith(":"):
        tail = tail[1:]
    copied.text = (copied.text or "") + tail
    copied.remove(opening)
    return copied


def _without_run_in(block: ET.Element) -> ET.Element:
    """A copy of ``block`` with its run-in heading taken out of the text.

    Args:
        block: An element whose first paragraph opens with a run-in heading
            (see :func:`_run_in_heading`).

    Returns:
        A copy in which that paragraph starts with the text after the
        heading. ``block`` is left unchanged.
    """
    copied = copy.deepcopy(block)
    paragraph = _first_content_child(copied)
    if paragraph is None or paragraph.tag != "p":
        # Not reachable from _render_block, which calls this only after
        # _run_in_heading found the paragraph.
        return copied
    index = list(copied).index(paragraph)
    copied.remove(paragraph)
    copied.insert(index, _paragraph_without_run_in(paragraph))
    return copied


def _first_content_child(element: ET.Element) -> ET.Element | None:
    """The first child that is not the element's title or label.

    Args:
        element: A section-like element.

    Returns:
        That child, or ``None`` when there is none.
    """
    return next(
        (child for child in element if child.tag not in ("title", "label")),
        None,
    )


def _render_list(list_elem: ET.Element) -> str:
    """Render a ``<list>`` as markdown list items.

    Args:
        list_elem: The list.

    Returns:
        One item per line, numbered for an ordered list.
    """
    items = []
    ordered = list_elem.get("list-type", "bullet") == "order"

    for i, item in enumerate(list_elem.findall("list-item"), 1):
        text = text_of(item)
        if text:
            items.append(f"{i}. {text}" if ordered else f"- {text}")

    return "\n".join(items)


def _render_def_list(def_list: ET.Element) -> str:
    """Render a ``<def-list>`` -- a glossary of abbreviations, usually.

    Args:
        def_list: The definition list.

    Returns:
        One ``term: definition`` item per line.
    """
    items = []
    for item in def_list.findall("def-item"):
        term = text_of(item.find("term"))
        definition = text_of(item.find("def"))
        if term and definition:
            items.append(f"- {term}: {definition}")
        elif term or definition:
            items.append(f"- {term or definition}")
    return "\n".join(items)


def _heading_line(heading: str, level: int) -> str:
    """A markdown heading line.

    Args:
        heading: Its text.
        level: Its level; deeper than markdown's six is rendered at six.

    Returns:
        The line.
    """
    return f"{'#' * min(level, MAX_HEADING_LEVEL)} {heading}"


def _normalised(text: str) -> str:
    """Text with its whitespace collapsed and its case folded, for comparing."""
    return " ".join(text.split()).casefold()


def _comparable(markdown: str) -> str:
    """Markdown reduced to its words, so a heading's level does not matter.

    Args:
        markdown: Rendered markdown.

    Returns:
        The text without heading and emphasis marks, whitespace collapsed
        and case folded.
    """
    return _normalised(markdown.replace("#", " ").replace("*", " "))


def text_of(element: ET.Element | None) -> str:
    """Extract an element's text, keeping inline formatting as markdown.

    Titles and labels inside it are skipped: they are rendered as headings
    by the caller, or are markers.

    Args:
        element: The element, or ``None``.

    Returns:
        Its text with whitespace collapsed and HTML entities unescaped; an
        empty string for ``None``.
    """
    if element is None:
        return ""

    parts = []

    if element.text:
        parts.append(element.text)

    for child in element:
        child_text = _inline_text(child)
        if child_text:
            parts.append(child_text)
        if child.tail:
            parts.append(child.tail)

    text = "".join(parts)
    text = re.sub(r"\s+", " ", text).strip()
    return unescape(text)


def _inline_text(child: ET.Element) -> str:
    """Render one inline child of a text element.

    Args:
        child: The child element.

    Returns:
        Its text, marked up as markdown where it is formatting, a
        cross-reference or a link; empty for a title or label.
    """
    tag = child.tag
    if tag in ("title", "label"):
        return ""
    text = text_of(child)
    if not text:
        return ""
    if tag == "italic":
        return f"*{text}*"
    if tag == "bold":
        return f"**{text}**"
    if tag == "sup":
        return f"^{text}^"
    if tag == "sub":
        return f"_{text}_"
    if tag == "xref":
        return f"[{text}]"
    if tag == "ext-link":
        href = child.get(_XLINK_HREF, "")
        return f"[{text}]({href})" if href else text
    return text
