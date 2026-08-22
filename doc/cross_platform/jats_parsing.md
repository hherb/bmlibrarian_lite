# JATS XML Parsing

This document describes the cross-platform algorithm for parsing JATS (Journal Article Tag Suite) XML into structured data, Markdown, and HTML.

## Overview

JATS is the standard XML format used by Europe PMC and PubMed Central for full-text articles. The parser needs to handle:

- Article metadata (title, authors, journal, identifiers)
- Structured abstracts with labeled sections
- Body sections with nested subsections
- Figures with captions and graphic URLs
- Tables with complex structures (colspan, nested lists)
- References with structured citation data

## JATS Document Structure

```xml
<article>
  <front>
    <journal-meta>...</journal-meta>
    <article-meta>
      <article-id pub-id-type="pmcid">4255432</article-id>
      <article-id pub-id-type="pmid">25427578</article-id>
      <article-id pub-id-type="doi">10.1186/s13023-014-0170-0</article-id>
      <title-group><article-title>...</article-title></title-group>
      <contrib-group>
        <contrib contrib-type="author">
          <name>
            <surname>Smith</surname>
            <given-names>John</given-names>
          </name>
        </contrib>
      </contrib-group>
      <abstract>...</abstract>
    </article-meta>
  </front>
  <body>
    <sec><title>Introduction</title><p>...</p></sec>
    <sec><title>Methods</title><p>...</p></sec>
  </body>
  <back>
    <ref-list>
      <ref id="CR1">...</ref>
    </ref-list>
  </back>
</article>
```

## Parsing Strategy

Use a SAX-style (streaming) parser rather than DOM for memory efficiency with large documents.

### Parser State Machine

```pseudocode
class JATSParser:
    # Document structure state
    in_front: bool = false
    in_article_meta: bool = false
    in_body: bool = false
    in_back: bool = false

    # Section state
    section_stack: list[SectionBuilder] = []

    # Abstract state
    in_abstract: bool = false
    current_abstract_title: string = ""
    current_abstract_text: list[string] = []

    # Figure/Table state
    # A <fig> may contain another <fig> (eLife wraps every figure supplement
    # this way, in 19.6% of surveyed articles), so the figure side is a stack,
    # not a slot, and `in_figure` is derived from it rather than stored. A
    # stored flag is cleared by the inner </fig> while the parent is still
    # open, which discards the parent and reads the rest of its content as
    # article prose (#156).
    figure_slots: list[Figure | null] = []   # one per <fig>, in *open* order
    figure_stack: list[FigureFrame] = []     # innermost last
    in_figure: bool = (figure_stack is not empty)
    in_table_wrap: bool = false
    current_table: TableBuilder | null

    # How deep the parser is inside a <fn> or <table-wrap-foot> belonging to
    # an exhibit. Compared against the depth each exhibit opened at, never
    # against zero — see "Label routing" below.
    footnote_depth: int = 0

class FigureFrame:
    slot: int                  # index into figure_slots, reserved at <fig>
    builder: FigureBuilder
    footnote_depth_at_open: int

    # Reference state
    in_ref_list: bool = false
    in_ref: bool = false
    in_ref_citation: bool = false
    in_person_group: bool = false
    current_reference: ReferenceBuilder | null

    # Author state
    in_contrib: bool = false
    current_author: AuthorBuilder | null

    # Text accumulation
    text_stack: list[string] = [""]
    element_stack: list[string] = []
```

### Text Accumulation Strategy

JATS has many inline elements (bold, italic, xref) that need text accumulation:

```pseudocode
# Elements that accumulate text content
const TEXT_ACCUMULATING_ELEMENTS = {
    "p", "title", "article-title", "abstract", "sec",
    "surname", "given-names", "journal-title", "volume", "issue",
    "fpage", "lpage", "year", "article-id", "label",
    "mixed-citation", "element-citation", "caption",
    "bold", "b", "italic", "i", "sub", "sup", "monospace", "code",
    "xref", "ext-link", "uri", "email", "named-content",
    "list-item", "source", "article-title", "person-group", "pub-id"
}

function on_start_element(name: string, attrs: dict):
    element_stack.push(name)

    if name in TEXT_ACCUMULATING_ELEMENTS:
        text_stack.push("")  # New buffer for this element

    # Handle element-specific state changes
    match name:
        case "front": in_front = true
        case "body": in_body = true
        case "abstract": in_abstract = true
        # ... etc

function on_characters(text: string):
    # Append to current buffer
    if text_stack:
        text_stack[-1] += text

function on_end_element(name: string):
    element_text = ""
    if name in TEXT_ACCUMULATING_ELEMENTS:
        element_text = text_stack.pop()
        # Inline elements merge with parent
        if is_inline_element(name) and text_stack:
            text_stack[-1] += element_text

    element_stack.pop()

    # Handle element-specific processing
    process_end_element(name, element_text.strip())
```

## Article ID Extraction

**Critical:** Use the `pub-id-type` attribute to classify article IDs:

```pseudocode
function handle_article_id(text: string, id_type: string | null):
    if id_type:
        match id_type.lower():
            case "doi": article.doi = text
            case "pmc", "pmcid": article.pmc_id = normalize_pmc_id(text)
            case "pmid", "pubmed": article.pmid = text
            case _: classify_by_pattern(text)
    else:
        classify_by_pattern(text)

function classify_by_pattern(text: string):
    if text.startswith("10."):
        article.doi = text
    elif text.startswith("PMC"):
        article.pmc_id = text
    elif text.is_numeric() and len(text) >= 7:
        article.pmid = text

function normalize_pmc_id(id: string) -> string:
    if id.startswith("PMC"):
        return id
    return "PMC" + id
```

## Abstract Parsing

Europe PMC returns structured abstracts with sections:

```xml
<abstract>
  <title>Background</title>
  <p>Background text...</p>
  <title>Methods</title>
  <p>Methods text...</p>
  <title>Results</title>
  <p>Results text...</p>
</abstract>
```

Or HTML-formatted in search results:

```html
<h4>Background</h4><p>Background text...</p>
<h4>Methods</h4><p>Methods text...</p>
```

### Parsing Algorithm

```pseudocode
class AbstractSection:
    title: string
    content: string

function parse_abstract_xml():
    sections = []
    current_title = ""
    current_paragraphs = []

    on_end_element("title"):
        if in_abstract:
            # Save previous section
            if current_paragraphs:
                sections.append(AbstractSection(
                    title=current_title,
                    content=" ".join(current_paragraphs)
                ))
            current_title = element_text
            current_paragraphs = []

    on_end_element("p"):
        if in_abstract:
            current_paragraphs.append(normalize_whitespace(element_text))

    on_end_element("abstract"):
        # Save final section
        if current_paragraphs:
            sections.append(AbstractSection(
                title=current_title,
                content=" ".join(current_paragraphs)
            ))
        article.abstract_sections = sections
```

### Cleaning HTML Abstracts

```pseudocode
function clean_abstract_html(html: string) -> string:
    result = html

    # Convert <h4>Section</h4> to **Section:**
    result = regex_replace(result, r'<h4>([^<]+)</h4>', '\n\n**$1:** ')

    # Convert paragraph tags
    result = result.replace("<p>", "\n\n")
    result = result.replace("</p>", "")

    # Remove remaining HTML tags
    result = regex_replace(result, r'<[^>]+>', '')

    return result.strip()
```

## Figure Handling

### XML Structure

```xml
<fig id="Fig1">
  <label>Figure 1</label>
  <caption><p>Caption text with <italic>formatting</italic>...</p></caption>
  <graphic xlink:href="13023_2014_170_Fig1_HTML" id="MO1"/>
</fig>
```

### Figure URL Construction

**Critical lesson:** The `xlink:href` contains the filename WITHOUT extension. NCBI URLs return 403; use Europe PMC URLs.

```pseudocode
const FIGURE_EXTENSIONS = [".jpg", ".gif", ".png"]

function build_figure_url(href: string, pmc_id: string) -> string:
    # Already a full URL
    if href.startswith("http://") or href.startswith("https://"):
        return href

    # Check if already has extension
    has_extension = any(href.lower().endswith(ext) for ext in FIGURE_EXTENSIONS)

    # Build Europe PMC URL (NOT NCBI - returns 403)
    normalized_pmc = normalize_pmc_id(pmc_id)
    base_url = f"https://europepmc.org/articles/{normalized_pmc}/bin/{href}"

    if not has_extension:
        # Default to .jpg, viewer should try alternatives
        return base_url + ".jpg"

    return base_url
```

### FigureBuilder

```pseudocode
class FigureBuilder:
    id: string = ""
    label: string = ""
    caption: string = ""
    graphic_href: string | null = null
    graphic_rank: GraphicSuitability | null = null
    footnotes: list[string] = []
    pending_footnote_label: string = ""

    # A figure commonly deposits the same image more than once, and only one
    # href fits in the model. Accept a deposit only when it is *strictly*
    # better, so the first wins among equals (#161).
    function offer_graphic(href, rank):
        if href is empty: return
        if graphic_rank is null or rank > graphic_rank:
            graphic_href = href
            graphic_rank = rank

    function append_footnote(text):
        footnotes.append(join_marker(pending_footnote_label, text))
        pending_footnote_label = ""

    function build() -> Figure:
        return Figure(
            id=id,
            label=label or f"Figure {index + 1}",
            caption=caption,
            graphic_url=graphic_href,
            footnotes=footnotes
        )
```

### Choosing among several `<graphic>`

Of the 959 survey figures carrying a `<graphic>` at all, 507 (52.9%) end on a
thumbnail, so "keep the last one" resolves the majority of figures to a
thumbnail. "Keep the first" is no better on its own: the two multi-graphic
conventions disagree about order.

```pseudocode
enum GraphicSuitability:   # worst to best
    ARCHIVAL  = 0   # mime-subtype tiff/tif/eps/postscript — will not render
    THUMBNAIL = 1   # content-type~"thumb" or specific-use~"thumb"
    FULL      = 2   # everything else

function graphic_suitability(attributes) -> GraphicSuitability:
    # Substring, lowercased: neither attribute is case-controlled, and both
    # are open-valued in JATS, so a third spelling is possible.
    if "thumb" in lower(attributes["content-type"] or "")
       or "thumb" in lower(attributes["specific-use"] or ""):
        return THUMBNAIL
    if lower(attributes["mime-subtype"] or "") in {tiff, tif, eps, postscript}:
        return ARCHIVAL
    return FULL
```

A thumbnail is deposited **last** (PLOS, Springer); an `<alternatives>`
archival master is deposited **first**. Ranking settles both without caring
which end it is. Never infer a thumbnail from the file extension: every corpus
thumbnail is a `.gif`, but a `.gif` elsewhere may be the only image a figure
has.

### Label routing

A `<fn>` carries its own marker — "a", "b", "*" — as a `<label>`, so routing
every `<label>` on the ambient "am I in a figure/table?" flags wrote that
marker over the exhibit's own number (#157). 27 of 225 surveyed articles
(12.0%) carry a labelled `<table-wrap-foot><fn>`.

```pseudocode
on </label>:
    # NOT `footnote_depth > 0`: JATS lets a <fig> or <table-wrap> open *inside*
    # a footnote, and testing against zero eats that exhibit's own label.
    exhibit_depth = figure_stack.last.footnote_depth_at_open if in_figure
                    else table_footnote_depth_at_open if in_table_wrap
                    else 0
    if footnote_depth > exhibit_depth:
        current_exhibit.pending_footnote_label = text   # held, not dropped
    else if in_figure:    current_figure.label = text
    else if in_table_wrap: current_table.label = text
    else if in_ref:        current_reference.label = text
```

Hold the marker rather than dropping it: `<sup>` is an inline element flattened
into the surrounding cell, so the rendered table body still reads `12.3a` and
the footnote has to say which one it is. Emit it as `"a — text"`.

An empty label is not inert — renderers substitute `f"Figure {index + 1}"`, so
a swallowed label becomes an invented figure number rather than a blank.

## Table Handling

JATS tables can have several structural variations that need special handling.

### Standard Structure

```xml
<table-wrap id="Tab1">
  <label>Table 1</label>
  <caption><p>Table caption</p></caption>
  <table>
    <thead>
      <tr><th>Column 1</th><th>Column 2</th></tr>
    </thead>
    <tbody>
      <tr><td>Data 1</td><td>Data 2</td></tr>
    </tbody>
  </table>
</table-wrap>
```

### Edge Cases

1. **`<td>` inside `<thead>`** - Some documents use `<td>` instead of `<th>` in headers
2. **Colspan attributes** - Merged cells need empty placeholders
3. **Nested lists in cells** - Lists inside table cells need proper formatting
4. **Tables without `<thead>`** - First row with `<th>` cells should be detected as header

### TableBuilder Implementation

```pseudocode
class TableBuilder:
    header_rows: list[list[string]] = []
    body_rows: list[list[string]] = []
    current_row: list[string] = []
    current_cell_text: string = ""

    # State tracking
    in_header: bool = false
    in_body: bool = false
    in_row: bool = false
    in_cell: bool = false

    # Edge case handling
    current_row_has_header_cells: bool = false
    current_colspan: int = 1

    # Nested list support
    in_list: bool = false
    list_is_ordered: bool = false
    list_item_number: int = 0
    pending_list_item: bool = false

    function start_header():
        in_header = true
        in_body = false

    function end_header():
        in_header = false

    function start_body():
        in_body = true
        in_header = false

    function start_row():
        in_row = true
        current_row = []
        current_row_has_header_cells = false

    function end_row():
        if in_row and current_row:
            # Determine if this is a header row
            is_header_row = in_header or
                           (current_row_has_header_cells and
                            not in_body and
                            not header_rows)

            if is_header_row:
                header_rows.append(current_row)
            else:
                body_rows.append(current_row)

        in_row = false
        current_row = []
        current_row_has_header_cells = false

    function start_cell(is_th: bool, colspan: int = 1):
        in_cell = true
        current_cell_text = ""
        current_colspan = max(1, colspan)
        in_list = false
        list_item_number = 0
        pending_list_item = false

        # Mark as header row if <th> or inside <thead>
        if is_th or in_header:
            current_row_has_header_cells = true

    function end_cell():
        if in_cell:
            # Normalize and escape
            normalized = normalize_whitespace(current_cell_text)
            normalized = normalized.replace("|", "\\|")  # Escape pipes for markdown
            current_row.append(normalized)

            # Add empty cells for colspan > 1
            for _ in range(1, current_colspan):
                current_row.append("")

        in_cell = false
        current_cell_text = ""
        current_colspan = 1
        reset_list_state()

    function start_list(ordered: bool):
        if in_cell:
            in_list = true
            list_is_ordered = ordered
            list_item_number = 0

    function start_list_item():
        if in_cell and in_list:
            list_item_number += 1
            pending_list_item = true

    function append_cell_text(text: string):
        if not in_cell:
            return

        normalized = text.replace("\n", " ").replace("\r", " ")

        # Add list marker when hitting content after list-item start
        if pending_list_item and normalized.strip():
            if current_cell_text.strip():
                current_cell_text += "; "  # Separator between items

            if list_is_ordered:
                current_cell_text += f"{list_item_number}. "
            else:
                current_cell_text += "• "

            pending_list_item = false

        current_cell_text += normalized
```

### Markdown Table Generation

```pseudocode
function table_to_markdown(table: Table) -> string:
    lines = []

    # Determine column count
    all_rows = table.header_rows + table.body_rows
    if not all_rows:
        return ""
    max_cols = max(len(row) for row in all_rows)

    # Header rows
    for row in table.header_rows:
        padded = pad_row(row, max_cols)
        lines.append("| " + " | ".join(padded) + " |")

    # Separator (required for markdown tables)
    if table.header_rows:
        lines.append("| " + " | ".join(["---"] * max_cols) + " |")
    elif table.body_rows:
        # No header - add empty header and separator
        lines.append("| " + " | ".join([""] * max_cols) + " |")
        lines.append("| " + " | ".join(["---"] * max_cols) + " |")

    # Body rows
    for row in table.body_rows:
        padded = pad_row(row, max_cols)
        lines.append("| " + " | ".join(padded) + " |")

    return "\n".join(lines)

function pad_row(row: list[string], target_cols: int) -> list[string]:
    if len(row) >= target_cols:
        return row[:target_cols]
    return row + [""] * (target_cols - len(row))
```

### HTML Table Generation (Preferred)

For complex tables, HTML is more capable:

```pseudocode
function table_to_html(table: Table) -> string:
    html = ["<table>"]

    if table.header_rows:
        html.append("  <thead>")
        for row in table.header_rows:
            html.append("    <tr>")
            for cell in row:
                html.append(f"      <th>{escape_html(cell)}</th>")
            html.append("    </tr>")
        html.append("  </thead>")

    if table.body_rows:
        html.append("  <tbody>")
        for row in table.body_rows:
            html.append("    <tr>")
            for cell in row:
                html.append(f"      <td>{escape_html(cell)}</td>")
            html.append("    </tr>")
        html.append("  </tbody>")

    html.append("</table>")
    return "\n".join(html)
```

## Reference Parsing

### XML Structure

```xml
<ref id="CR1">
  <label>1</label>
  <element-citation publication-type="journal">
    <person-group person-group-type="author">
      <name>
        <surname>Smith</surname>
        <given-names>John</given-names>
      </name>
      <name>
        <surname>Doe</surname>
        <given-names>Jane</given-names>
      </name>
    </person-group>
    <article-title>Article title</article-title>
    <source>Journal Name</source>
    <year>2023</year>
    <volume>45</volume>
    <issue>3</issue>
    <fpage>123</fpage>
    <lpage>145</lpage>
    <pub-id pub-id-type="doi">10.1234/example</pub-id>
  </element-citation>
</ref>
```

### ReferenceBuilder

```pseudocode
class ReferenceBuilder:
    id: string = ""
    label: string = ""
    authors: list[string] = []
    article_title: string = ""
    source: string = ""  # Journal name
    year: string = ""
    volume: string = ""
    issue: string = ""
    first_page: string = ""
    last_page: string = ""
    doi: string = ""
    pmid: string = ""
    citation: string = ""  # Raw citation text

    # Author accumulation
    current_surname: string = ""
    current_given_names: string = ""

    function finish_current_author():
        if current_surname:
            name = current_given_names + " " + current_surname
                   if current_given_names
                   else current_surname
            authors.append(name.strip())
            current_surname = ""
            current_given_names = ""

    function build() -> Reference:
        return Reference(
            id=id,
            label=label,
            authors=authors,
            article_title=article_title,
            source=source,
            year=year,
            volume=volume,
            issue=issue,
            first_page=first_page,
            last_page=last_page,
            doi=doi,
            pmid=pmid,
            citation=citation,
            formatted_citation=format_citation()
        )

    function format_citation() -> string:
        parts = []

        # Authors (et al. for >3)
        if authors:
            if len(authors) <= 3:
                parts.append(", ".join(authors))
            else:
                parts.append(f"{authors[0]}, {authors[1]}, et al.")

        # Title
        if article_title:
            parts.append(article_title)

        # Journal (italicized in markdown)
        if source:
            parts.append(f"*{source}*")

        # Year
        if year:
            parts.append(f"({year})")

        # Volume/issue/pages
        volume_info = volume
        if issue:
            volume_info += f"({issue})"
        if first_page:
            volume_info += f":{first_page}"
            if last_page:
                volume_info += f"-{last_page}"
        if volume_info:
            parts.append(volume_info)

        # DOI
        if doi:
            parts.append(f"doi:{doi}")

        return ". ".join(parts)
```

**Important:** Call `finish_current_author()` when closing each `</name>` element, not at `</person-group>`.

## Cross-Reference Handling

Convert `<xref>` elements to anchor links:

```pseudocode
function handle_xref(text: string, ref_type: string, rid: string) -> string:
    match ref_type:
        case "fig", "figure":
            link_text = text or "Figure"
            return f"[{link_text}](#{rid})"

        case "table", "table-wrap":
            link_text = text or "Table"
            return f"[{link_text}](#{rid})"

        case "bibr":  # Bibliography reference
            return f"[{text}]"  # Just keep the reference number

        case _:
            return text  # Other types, just use text
```

## Inline Formatting

Handle inline formatting elements:

```pseudocode
const INLINE_ELEMENTS = {
    "bold", "b", "italic", "i", "sub", "sup",
    "monospace", "code", "xref", "ext-link"
}

function is_inline_element(name: string) -> bool:
    return name in INLINE_ELEMENTS

# When processing inline elements, just accumulate text
# The formatting is preserved in the text accumulation
# For markdown output, you may want to add markers:

function format_inline_markdown(tag: string, text: string) -> string:
    match tag:
        case "bold", "b": return f"**{text}**"
        case "italic", "i": return f"*{text}*"
        case "sub": return f"~{text}~"
        case "sup": return f"^{text}^"
        case "monospace", "code": return f"`{text}`"
        case _: return text
```

## Output Formats

The parser should support multiple output formats:

### Structured Data

```pseudocode
class JATSArticle:
    title: string
    authors: list[AuthorInfo]
    journal: string
    volume: string
    issue: string
    pages: string
    year: string
    doi: string
    pmc_id: string
    pmid: string
    abstract_sections: list[AbstractSection]
    body_sections: list[BodySection]
    figures: list[Figure]
    tables: list[Table]
    references: list[Reference]
```

### Markdown

```pseudocode
function build_markdown(article: JATSArticle) -> string:
    lines = []

    # Title
    if article.title:
        lines.append(f"# {article.title}")
        lines.append("")

    # Authors
    if article.authors:
        author_str = format_authors(article.authors)
        lines.append(f"**Authors:** {author_str}")
        lines.append("")

    # Journal info
    journal_info = format_journal_info(article)
    if journal_info:
        lines.append(journal_info)
        lines.append("")

    # Identifiers
    ids = format_identifiers(article)
    if ids:
        lines.append(ids)
        lines.append("")

    # Abstract
    if article.abstract_sections:
        lines.append("## Abstract")
        lines.append("")
        for section in article.abstract_sections:
            if section.title:
                lines.append(f"**{section.title}:** {section.content}")
            else:
                lines.append(section.content)
            lines.append("")

    # Body sections
    for section in article.body_sections:
        lines.extend(format_body_section(section, level=2))

    # Figures
    if article.figures:
        lines.append("## Figures")
        lines.append("")
        for i, fig in enumerate(article.figures):
            fig_num = fig.label or f"Figure {i + 1}"
            anchor_id = fig.id or f"fig{i + 1}"
            lines.append(f"<!-- anchor:{anchor_id} -->")
            lines.append("")
            lines.append(f"### {fig_num}")
            lines.append("")
            if fig.graphic_url:
                url = build_figure_url(fig.graphic_url, article.pmc_id)
                lines.append(f"![Figure]({url})")
                lines.append("")
            if fig.caption:
                lines.append(fig.caption)
                lines.append("")

    # Tables
    if article.tables:
        lines.append("## Tables")
        lines.append("")
        for i, table in enumerate(article.tables):
            table_num = table.label or f"Table {i + 1}"
            anchor_id = table.id or f"table{i + 1}"
            lines.append(f"<!-- anchor:{anchor_id} -->")
            lines.append("")
            lines.append(f"### {table_num}")
            if table.caption:
                lines.append("")
                lines.append(table.caption)
            lines.append("")
            lines.append(table_to_markdown(table))
            lines.append("")

    # References
    if article.references:
        lines.append("## References")
        lines.append("")
        for i, ref in enumerate(article.references):
            ref_num = ref.label or str(i + 1)
            lines.append(f"{ref_num}. {ref.formatted_citation}")
        lines.append("")

    return "\n".join(lines)
```

### HTML

HTML output is similar but uses HTML tags instead of Markdown syntax. HTML is preferred for:
- Complex tables with colspan/rowspan
- Clickable links to figures and references
- Better rendering of nested structures

## Configuration Constants

```pseudocode
const MAX_HEADING_LEVEL = 6
const MAX_AUTHORS_BEFORE_ET_AL = 3
const MIN_PMID_LENGTH = 7

const EUROPEPMC_FIGURE_BASE_URL = "https://europepmc.org/articles"
# NOT: https://www.ncbi.nlm.nih.gov/pmc/articles (returns 403)
```

## Common Pitfalls

1. **Article ID classification** - Always use `pub-id-type` attribute; don't rely solely on pattern matching
2. **Figure URLs** - Use europepmc.org, not ncbi.nlm.nih.gov
3. **Figure extensions** - XML doesn't include extensions; default to .jpg
4. **Table headers** - Check both `<th>` presence AND `<thead>` context
5. **Colspan handling** - Add empty cells to maintain column alignment
6. **Nested lists in cells** - Format with separators ("; ") to keep content readable
7. **Author completion** - Call `finish_current_author()` on `</name>`, not `</person-group>`
8. **Whitespace normalization** - Collapse multiple spaces/newlines in paragraph text
