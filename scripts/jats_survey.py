#!/usr/bin/env python3
r"""Structural survey of real JATS articles, derived straight from the XML.

Every prevalence figure quoted in `doc/cross_platform/jats_corpus/README.md` and
in the JATS issues came from a survey that existed only as prose: no article
list, no counting script, so no maintainer could re-derive a number or check
whether a replacement article covered the same ground (#164).

This script is that counting script. It reads the XML with `ElementTree` and
**never** goes through `JATSXMLParser`, which is the point: a survey that asked
the parser what a document contains would agree with the parser's bugs. Several
of the defects behind #156, #157, #161, #167 and #169 were found precisely
because a hand-derived count disagreed with what the parser reported.

Usage:
    # The seven committed articles. Offline, deterministic, no network.
    python scripts/jats_survey.py

    # One measurement, for a decision that turns on it.
    python scripts/jats_survey.py --measure grouped-citations

    # A wider sample. Writes the article list so the run can be repeated.
    #
    # PUB_TYPE is load-bearing: the newest open-access deposits are dominated by
    # conference abstracts, and Europe PMC serves a fullTextXML document for
    # those too. HAS_FT:Y does NOT exclude them — a 400-article sample drawn
    # without PUB_TYPE came back 390 abstracts and reported "no nested figures
    # in 400 articles". Every run prints its sample composition for this reason.
    python scripts/jats_survey.py --limit 300 --cache tmp/jats-survey \\
        --fetch-query 'SRC:PMC AND OPEN_ACCESS:Y AND HAS_FT:Y AND PUB_TYPE:"research-article"'
    python scripts/jats_survey.py --corpus tmp/jats-survey --full-text-only

    # Re-fetch exactly the articles a previous run used.
    python scripts/jats_survey.py --fetch-ids tmp/jats-survey/manifest.json \\
        --cache tmp/jats-survey2

    # Machine-readable, for diffing two samples.
    python scripts/jats_survey.py --json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import time
import xml.etree.ElementTree as ET
from collections import Counter
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

# Europe PMC serves the full text of an open-access article at this path.
_FULLTEXT_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/{pmc_id}/fullTextXML"
_SEARCH_URL = "https://www.ebi.ac.uk/europepmc/webservices/rest/search"

# Europe PMC asks for courtesy rather than enforcing a rate; three requests a
# second is well inside what the service tolerates for a few hundred articles.
_REQUEST_DELAY_SECONDS = 0.34
_REQUEST_TIMEOUT_SECONDS = 30
_SEARCH_PAGE_SIZE = 100

# The two elements a <ref> may wrap around one bibliographic entry.
_CITATION_TAGS = ("element-citation", "mixed-citation")

# A grouped citation numbers its members "(a)", "(b)", "(c)", and subdivides them
# as "(b1)", "(b2)" — 3 of 543 labels in a 147-article RSC sample take the
# suffixed form, always in sequence beside plain letters. A <label> on a citation
# that does NOT look like either is the counterexample to the #177 drop: it would
# be a real reference number, and dropping it would lose data.
#
# The digit suffix is deliberately part of the *accepted* shape. Without it the
# detector reported those 3 as counterexamples, which is a false alarm on the one
# question this script exists to answer honestly — and a detector that cries wolf
# is one nobody reads.
_SUB_MARKER = re.compile(r"^\(\s*[a-z]\d*\s*\)$", re.IGNORECASE)

# Two publisher conventions mark a thumbnail; neither is the file extension.
# Kept in step with `graphicSuitability` in JATSXMLParser.swift.
_THUMBNAIL_MARKERS = ("thumb",)
_ARCHIVAL_MIME_SUBTYPES = frozenset({"tiff", "tif", "eps", "postscript"})


@dataclass
class Article:
    """One parsed JATS article, with a child->parent index.

    `ElementTree` gives no parent pointers, and almost every question this
    survey asks is "what does this element hang off?" — so the index is built
    once per article rather than re-walked per measurement.

    Attributes:
        pmc_id: The article's PMC identifier, or the file stem if it has none.
        path: Where the XML was read from.
        root: The parsed `<article>` element.
        parents: Maps each element to its parent. The root is absent.
    """

    pmc_id: str
    path: Path
    root: ET.Element
    parents: dict[ET.Element, ET.Element] = field(repr=False, default_factory=dict)

    @classmethod
    def load(cls, path: Path) -> Article:
        """Parse one article file.

        Args:
            path: An article's XML file.

        Returns:
            The parsed article, with its parent index built.

        Raises:
            ET.ParseError: If the file is not well-formed XML.
        """
        root = ET.parse(path).getroot()
        parents = {child: parent for parent in root.iter() for child in parent}
        pmc_id = _read_pmc_id(root) or path.stem
        return cls(pmc_id=pmc_id, path=path, root=root, parents=parents)

    @property
    def article_type(self) -> str:
        """The `article-type` attribute, e.g. `research-article`, `abstract`."""
        return self.root.get("article-type", "")

    @property
    def journal(self) -> str:
        """The journal title, or `""` if the article names none."""
        title = self.root.find(".//journal-title")
        return (title.text or "").strip() if title is not None and title.text else ""

    @property
    def has_full_text(self) -> bool:
        """Whether the article carries a `<body>` with any prose in it.

        Europe PMC serves a `fullTextXML` document for records that have no
        full text — a conference abstract deposit is front matter and nothing
        else. Measuring structure across those reports zeroes that look like
        findings: a sample of 400 newest-first open-access deposits was 390
        abstracts, and reported "no nested figures in 400 articles".
        """
        body = self.root.find("body")
        return body is not None and any(True for _ in body.iter("p"))

    def parent_tag(self, element: ET.Element) -> str:
        """The tag of an element's parent, or `""` at the root."""
        parent = self.parents.get(element)
        return parent.tag if parent is not None else ""

    def ancestors(self, element: ET.Element) -> Iterator[ET.Element]:
        """Walk from an element's parent up to the root, nearest first."""
        current = self.parents.get(element)
        while current is not None:
            yield current
            current = self.parents.get(current)

    def has_ancestor(self, element: ET.Element, *tags: str) -> bool:
        """Whether any ancestor of `element` has one of `tags`."""
        return any(ancestor.tag in tags for ancestor in self.ancestors(element))


def _text_of(element: ET.Element) -> str:
    """All text inside an element, inline markup flattened.

    `<label>(<italic>a</italic>)</label>` occurs, and `element.text` would read
    it as `"("` — which would then fail the sub-marker test and be reported as a
    counterexample that is not one. A measurement whose job is to falsify a
    decision must not manufacture its own counterexamples.

    Args:
        element: Any element.

    Returns:
        Its concatenated text, stripped.
    """
    return "".join(element.itertext()).strip()


def _read_pmc_id(root: ET.Element) -> str:
    """The article's PMC id from `<article-id pub-id-type="pmc">`, if present."""
    for article_id in root.iter("article-id"):
        if article_id.get("pub-id-type") == "pmc":
            text = (article_id.text or "").strip()
            return text if text.startswith("PMC") else f"PMC{text}"
    return ""


@dataclass
class Measurement:
    """One survey result, rendered as a headline plus a breakdown.

    Attributes:
        name: Stable slug, usable with `--measure`.
        title: Human-readable heading.
        headline: The single sentence a reader should take away, or `""`.
        rows: Label/value pairs forming the breakdown table.
        notes: Lines printed under the table — caveats, counterexamples.
        data: The same result as plain JSON-serialisable values.
    """

    name: str
    title: str
    headline: str = ""
    rows: Sequence[tuple[str, object]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    data: dict[str, object] = field(default_factory=dict)


def _plural(count: int, noun: str) -> str:
    """Render "1 host" / "5 hosts" with the plural the number calls for."""
    return f"{count} {noun}{'' if count == 1 else 's'}"


def _counter_rows(counts: Counter[str]) -> list[tuple[str, object]]:
    """Counter entries as rows, most frequent first."""
    return [(f"`<{tag}>`" if tag else "(no parent)", n) for tag, n in counts.most_common()]


def measure_label_parents(articles: Sequence[Article]) -> Measurement:
    """Which elements carry a `<label>`.

    The measurement behind the routing rule in #157/#169: `<label>` means a
    figure number, a table number, a footnote marker, an affiliation
    superscript, an equation number, a supplement title or a citation
    sub-marker depending only on its parent, so the parent is the only thing
    that can route it.
    """
    counts: Counter[str] = Counter()
    modelled = {"fig", "table-wrap", "fn", "ref"}
    unmodelled_inside_exhibit = 0
    for article in articles:
        for label in article.root.iter("label"):
            parent = article.parent_tag(label)
            counts[parent] += 1
            if parent not in modelled and article.has_ancestor(label, "fig", "table-wrap"):
                unmodelled_inside_exhibit += 1

    total = sum(counts.values())
    unmodelled = total - sum(counts[tag] for tag in modelled)
    return Measurement(
        name="label-parents",
        title="`<label>` parents",
        headline=(
            f"{total} labels on {_plural(len(counts), 'distinct parent')}; "
            f"{unmodelled} on hosts the parser does not model."
        ),
        rows=_counter_rows(counts),
        notes=[
            f"Unmodelled labels sitting *inside* a `<fig>`/`<table-wrap>`: "
            f"**{unmodelled_inside_exhibit}**. These are the ones that would be "
            f"adopted by the enclosing exhibit if routing asked the ambient "
            f"flags instead of the parent (#169).",
        ],
        data={
            "byParent": dict(counts),
            "total": total,
            "unmodelled": unmodelled,
            "unmodelledInsideExhibit": unmodelled_inside_exhibit,
        },
    )


def measure_grouped_citations(articles: Sequence[Article]) -> Measurement:
    """Labels on a citation inside a `<ref>` — the evidence behind #177.

    A `<ref>` may wrap several `<element-citation>`/`<mixed-citation>`, each
    numbered `(a)`, `(b)`, `(c)`. Routing `<label>` by its parent drops those,
    where the old ambient `inRef` test wrote the last one into the field
    holding the reference *number*.

    The decision rests on every such label being a sub-marker rather than a
    reference number. `nonSubMarkerExamples` is the falsifier: if a wider
    sample turns any up, the drop is losing real data and #177 becomes urgent.
    """
    single_refs = single_labels = multi_refs = multi_labels = 0
    with_own_label = 0
    marker_texts: Counter[str] = Counter()
    non_sub_markers: list[dict[str, str]] = []
    parents: Counter[str] = Counter()

    for article in articles:
        for ref in article.root.iter("ref"):
            citations = [child for child in ref if child.tag in _CITATION_TAGS]
            # Selected by the label's own parent, which is exactly what the Swift
            # routing switches on — not by "somewhere inside a citation", which
            # would also sweep up a <label> nested deeper in the citation's parts.
            nested = [
                (label, article.parent_tag(label))
                for label in ref.iter("label")
                if article.parent_tag(label) in _CITATION_TAGS
            ]
            if not nested:
                continue
            if any(child.tag == "label" for child in ref):
                with_own_label += 1
            if len(citations) == 1:
                single_refs += 1
                single_labels += len(nested)
            else:
                multi_refs += 1
                multi_labels += len(nested)
            for label, parent_tag in nested:
                parents[parent_tag] += 1
                text = _text_of(label)
                marker_texts[text] += 1
                if not _SUB_MARKER.match(text):
                    non_sub_markers.append(
                        {
                            "pmcId": article.pmc_id,
                            "ref": ref.get("id", ""),
                            "label": text,
                            "citations": str(len(citations)),
                        }
                    )

    total = single_labels + multi_labels
    if not total:
        verdict = (
            "**This sample contains none, so it says nothing either way.** The "
            "shape is rare — 3 of 161 articles in the survey behind #177 — so a "
            "small corpus reporting zero is expected, not reassurance."
        )
    elif non_sub_markers:
        verdict = (
            f"**{len(non_sub_markers)} counterexamples** — see below. The #177 "
            f"drop is losing real reference numbers in this sample."
        )
    else:
        verdict = (
            "No counterexamples: every label is a parenthesised letter, "
            "optionally digit-suffixed, so dropping them loses no reference "
            "number."
        )
    return Measurement(
        name="grouped-citations",
        title="Labels on a citation inside a `<ref>` (#177)",
        headline=f"{total} such labels in {single_refs + multi_refs} refs. {verdict}",
        rows=[
            ("refs with one citation child", single_refs),
            ("labels in those refs", single_labels),
            ("refs with several citation children", multi_refs),
            ("labels in those refs", multi_labels),
            ("refs that also carry a direct `<label>`", with_own_label),
        ]
        + _counter_rows(parents),
        notes=_grouped_citation_notes(
            non_sub_markers, total, with_own_label, single_refs + multi_refs
        ),
        data={
            "singleCitationRefs": single_refs,
            "singleCitationLabels": single_labels,
            "multiCitationRefs": multi_refs,
            "multiCitationLabels": multi_labels,
            "refsWithOwnLabel": with_own_label,
            "labelParents": dict(parents),
            "markerTexts": dict(marker_texts.most_common()),
            "nonSubMarkerExamples": non_sub_markers,
        },
    )


def _grouped_citation_notes(
    counterexamples: Sequence[dict[str, str]],
    total: int,
    with_own_label: int,
    affected_refs: int,
) -> list[str]:
    """Explain a grouped-citation result, including the empty case.

    Args:
        counterexamples: Labels that do not look like a sub-marker.
        total: How many citation-level labels were found at all.
        with_own_label: Affected refs that also carry a direct `<label>`.
        affected_refs: How many refs carried a citation-level label.

    Returns:
        Lines to print under the breakdown table.
    """
    if not total:
        return [
            "Re-run against a wider sample before treating this as evidence:",
            "",
            "```",
            "python scripts/jats_survey.py --fetch-query 'SRC:PMC AND OPEN_ACCESS:Y' \\",
            "    --limit 300 --cache tmp/jats-survey",
            "python scripts/jats_survey.py --corpus tmp/jats-survey \\",
            "    --measure grouped-citations",
            "```",
        ]
    if counterexamples:
        return [
            "Counterexamples — a label here is probably a real reference number, "
            "not a sub-marker, so #177 should capture rather than drop it:",
        ] + [
            f"  - `{example['pmcId']}` ref `{example['ref']}` "
            f"({example['citations']} citations): `{example['label']}`"
            for example in counterexamples[:20]
        ]
    return [
        f"A first-wins rule would never fire: {with_own_label} of {affected_refs} "
        "affected refs carry a direct `<label>` of their own.",
    ]


def measure_caption_hosts(articles: Sequence[Article]) -> Measurement:
    """Which elements carry a `<caption>` — the #142 measurement."""
    counts: Counter[str] = Counter()
    for article in articles:
        for caption in article.root.iter("caption"):
            counts[article.parent_tag(caption)] += 1
    return Measurement(
        name="caption-hosts",
        title="`<caption>` hosts",
        headline=(
            f"{sum(counts.values())} captions on "
            f"{_plural(len(counts), 'distinct host')}."
        ),
        rows=_counter_rows(counts),
        data={"byHost": dict(counts), "total": sum(counts.values())},
    )


def measure_nested_exhibits(articles: Sequence[Article]) -> Measurement:
    """Exhibits inside exhibits — the shapes behind #156 and #169.

    `<fig>` inside `<fig>` is eLife's figure-supplement convention and common.
    A `<table-wrap>` inside a `<fig>` is the #169 shape, and a `<table-wrap>`
    inside a `<table-wrap>` is #173; both are rare enough that a small corpus
    will report zero, which is exactly why they need synthetic fixtures.
    """
    shapes = {
        "fig in fig": ("fig", "fig"),
        "table-wrap in fig": ("table-wrap", "fig"),
        "fig in table-wrap": ("fig", "table-wrap"),
        "table-wrap in table-wrap": ("table-wrap", "table-wrap"),
    }
    occurrences: Counter[str] = Counter()
    article_counts: Counter[str] = Counter()
    for article in articles:
        seen: set[str] = set()
        for name, (inner, outer) in shapes.items():
            for element in article.root.iter(inner):
                if article.has_ancestor(element, outer):
                    occurrences[name] += 1
                    seen.add(name)
        for name in seen:
            article_counts[name] += 1

    return Measurement(
        name="nested-exhibits",
        title="Exhibits nested inside exhibits (#156, #169, #173)",
        headline=(
            f"{sum(occurrences.values())} nested exhibits across "
            f"{len(articles)} articles."
        ),
        rows=[
            (name, _occurrences_phrase(occurrences[name], article_counts[name]))
            for name in shapes
        ],
        notes=[
            "A zero here is a finding, not an absence of one: it means the "
            "shape needs a hand-written fixture, because no digest will ever "
            "catch a regression in it.",
        ],
        data={
            "occurrences": dict(occurrences),
            "articles": dict(article_counts),
            "articlesSurveyed": len(articles),
        },
    )


def _occurrences_phrase(occurrences: int, articles: int) -> str:
    """Render "N in M articles" with the plural the numbers call for."""
    return f"{occurrences} in {articles} article{'' if articles == 1 else 's'}"


def measure_table_graphics(articles: Sequence[Article]) -> Measurement:
    """`<graphic>` owners — the routing behind #161, #169 and #172.

    A `<graphic>` under `<table-wrap>` is a table deposited as an image (#172).
    `<alternatives>` is transparent for ownership; everything else owns the
    image it holds.
    """
    owners: Counter[str] = Counter()
    tables_with_graphic = 0
    for article in articles:
        for graphic in article.root.iter("graphic"):
            owner = ""
            for ancestor in article.ancestors(graphic):
                if ancestor.tag != "alternatives":
                    owner = ancestor.tag
                    break
            owners[owner] += 1
        for table_wrap in article.root.iter("table-wrap"):
            if any(True for _ in table_wrap.iter("graphic")):
                tables_with_graphic += 1

    return Measurement(
        name="graphic-owners",
        title="`<graphic>` owners, skipping `<alternatives>` (#172)",
        headline=(
            f"{sum(owners.values())} deposits; "
            f"{tables_with_graphic} `<table-wrap>` carry an image (#172)."
        ),
        rows=_counter_rows(owners),
        data={"byOwner": dict(owners), "tableWrapsWithGraphic": tables_with_graphic},
    )


def measure_thumbnail_deposits(articles: Sequence[Article]) -> Measurement:
    """Whether a figure's *last* `<graphic>` is a thumbnail — the #161 measure.

    Position cannot settle which deposit is the image: a thumbnail is deposited
    last by PLOS and Springer, while an `<alternatives>` archival master is
    deposited first.
    """
    figures_with_graphic = 0
    last_is_thumbnail = 0
    first_is_archival = 0
    for article in articles:
        for figure in article.root.iter("fig"):
            deposits = list(figure.iter("graphic"))
            if not deposits:
                continue
            figures_with_graphic += 1
            if _is_thumbnail(deposits[-1]):
                last_is_thumbnail += 1
            if _is_archival(deposits[0]):
                first_is_archival += 1

    share = (
        f"{last_is_thumbnail / figures_with_graphic:.1%}" if figures_with_graphic else "n/a"
    )
    return Measurement(
        name="thumbnail-deposits",
        title="Figures whose last `<graphic>` is a thumbnail (#161)",
        headline=f"{last_is_thumbnail} of {figures_with_graphic} figures ({share}).",
        rows=[
            ("figures carrying a `<graphic>`", figures_with_graphic),
            ("last deposit is a thumbnail", last_is_thumbnail),
            ("first deposit is an archival master", first_is_archival),
        ],
        data={
            "figuresWithGraphic": figures_with_graphic,
            "lastIsThumbnail": last_is_thumbnail,
            "firstIsArchival": first_is_archival,
        },
    )


def _is_thumbnail(graphic: ET.Element) -> bool:
    """Whether a `<graphic>` is marked as a thumbnail by either convention."""
    for attribute in ("content-type", "specific-use"):
        value = (graphic.get(attribute) or "").lower()
        if any(marker in value for marker in _THUMBNAIL_MARKERS):
            return True
    return False


def _is_archival(graphic: ET.Element) -> bool:
    """Whether a `<graphic>` names an archival master rather than a web image."""
    return (graphic.get("mime-subtype") or "").lower() in _ARCHIVAL_MIME_SUBTYPES


def measure_labelled_table_foot_fn(articles: Sequence[Article]) -> Measurement:
    """Articles carrying a labelled `<table-wrap-foot><fn>` — the #157 measure."""
    hits = 0
    total_fns = 0
    for article in articles:
        found = False
        for foot in article.root.iter("table-wrap-foot"):
            for fn in foot.iter("fn"):
                if any(child.tag == "label" for child in fn):
                    total_fns += 1
                    found = True
        if found:
            hits += 1
    share = f"{hits / len(articles):.1%}" if articles else "n/a"
    return Measurement(
        name="labelled-table-foot-fn",
        title="Articles with a labelled `<table-wrap-foot><fn>` (#157)",
        headline=f"{hits} of {len(articles)} articles ({share}); {total_fns} footnotes.",
        rows=[("articles", hits), ("labelled footnotes", total_fns)],
        data={"articles": hits, "labelledFootnotes": total_fns},
    )


def measure_title_parents(articles: Sequence[Article]) -> Measurement:
    """Which elements carry a `<title>` — the measurement behind #167."""
    counts: Counter[str] = Counter()
    inside_sec = 0
    for article in articles:
        for title in article.root.iter("title"):
            parent = article.parent_tag(title)
            counts[parent] += 1
            if parent not in ("sec", "caption") and article.has_ancestor(title, "sec"):
                inside_sec += 1
    return Measurement(
        name="title-parents",
        title="`<title>` parents (#167)",
        headline=(
            f"{sum(counts.values())} titles on "
            f"{_plural(len(counts), 'distinct parent')}."
        ),
        rows=_counter_rows(counts),
        notes=[
            f"Non-`<sec>`, non-`<caption>` titles sitting *inside* a `<sec>`: "
            f"**{inside_sec}**. Each one renamed its enclosing section before "
            f"#167.",
        ],
        data={"byParent": dict(counts), "insideSection": inside_sec},
    )


def measure_sub_article_depth(articles: Sequence[Article]) -> Measurement:
    """Maximum `<sub-article>` nesting — the shape `subArticleDepth` counts."""
    max_depth = 0
    with_sub_article = 0
    for article in articles:
        depths = [
            1 + sum(1 for a in article.ancestors(sub) if a.tag == "sub-article")
            for sub in article.root.iter("sub-article")
        ]
        if depths:
            with_sub_article += 1
            max_depth = max(max_depth, max(depths))
    return Measurement(
        name="sub-article-depth",
        title="`<sub-article>` nesting depth",
        headline=f"Maximum depth {max_depth}; {with_sub_article} articles carry one.",
        rows=[("articles with a `<sub-article>`", with_sub_article), ("max depth", max_depth)],
        data={"maxDepth": max_depth, "articlesWithSubArticle": with_sub_article},
    )


def measure_citation_style(articles: Sequence[Article]) -> Measurement:
    """`<mixed-citation>` versus `<element-citation>` — the #155 measure."""
    counts: Counter[str] = Counter()
    article_counts: Counter[str] = Counter()
    for article in articles:
        seen: set[str] = set()
        for tag in _CITATION_TAGS:
            found = list(article.root.iter(tag))
            if found:
                counts[tag] += len(found)
                seen.add(tag)
        for tag in seen:
            article_counts[tag] += 1
    total = sum(counts.values())
    mixed_share = f"{counts['mixed-citation'] / total:.1%}" if total else "n/a"
    return Measurement(
        name="citation-style",
        title="Citation markup style (#155)",
        headline=(
            f"{counts['mixed-citation']} of {total} citations are "
            f"`<mixed-citation>` ({mixed_share})."
        ),
        rows=[
            (f"`<{tag}>` elements", counts[tag]) for tag in _CITATION_TAGS
        ]
        + [(f"articles using `<{tag}>`", article_counts[tag]) for tag in _CITATION_TAGS],
        data={"elements": dict(counts), "articles": dict(article_counts)},
    )


def measure_affiliation_linking(articles: Sequence[Article]) -> Measurement:
    """How affiliations attach to authors — the #154 measure."""
    by_xref = 0
    inline = 0
    for article in articles:
        if any(
            xref.get("ref-type") == "aff" for xref in article.root.iter("xref")
        ):
            by_xref += 1
        if any(
            article.has_ancestor(aff, "contrib") for aff in article.root.iter("aff")
        ):
            inline += 1
    n = len(articles)
    return Measurement(
        name="affiliation-linking",
        title="How affiliations reach their author (#154)",
        headline=(
            f"{by_xref} of {n} articles link by `<xref ref-type=\"aff\">`; "
            f"{inline} inline an `<aff>` inside `<contrib>`."
        ),
        rows=[
            ("linked by `<xref ref-type=\"aff\">`", by_xref),
            ("inline `<aff>` in `<contrib>`", inline),
        ],
        data={"byXref": by_xref, "inline": inline, "articles": n},
    )


# Slug -> measurement, in the order a full run prints them. The slug is what
# `--measure` accepts and what keys the JSON output, so it is spelled here once
# rather than recovered by calling each function to read its result.
MEASUREMENTS: dict[str, Callable[[Sequence[Article]], Measurement]] = {
    "label-parents": measure_label_parents,
    "title-parents": measure_title_parents,
    "grouped-citations": measure_grouped_citations,
    "caption-hosts": measure_caption_hosts,
    "nested-exhibits": measure_nested_exhibits,
    "graphic-owners": measure_table_graphics,
    "thumbnail-deposits": measure_thumbnail_deposits,
    "labelled-table-foot-fn": measure_labelled_table_foot_fn,
    "citation-style": measure_citation_style,
    "affiliation-linking": measure_affiliation_linking,
    "sub-article-depth": measure_sub_article_depth,
}


def load_articles(corpus: Path) -> tuple[list[Article], list[str]]:
    """Parse every `*.xml` under a directory.

    Args:
        corpus: Directory holding article XML.

    Returns:
        The parsed articles, and one message per file that could not be parsed.
        A malformed article is reported and skipped rather than aborting the
        run: a survey of 200 fetched articles should not be lost to one of them.
    """
    articles: list[Article] = []
    problems: list[str] = []
    for path in sorted(corpus.glob("*.xml")):
        try:
            articles.append(Article.load(path))
        except ET.ParseError as error:
            problems.append(f"{path.name}: {error}")
    return articles, problems


def fetch(pmc_ids: Sequence[str], cache: Path) -> Path:
    """Download articles into a cache directory and record what was fetched.

    The manifest is the half of #164 that the prose survey lacked: without the
    article list, a number cannot be re-derived or compared against a later
    sample.

    Args:
        pmc_ids: Europe PMC identifiers, with or without the `PMC` prefix.
        cache: Directory to write `PMC*.xml` and `manifest.json` into.

    Returns:
        The path to the written manifest.

    Raises:
        SystemExit: If `requests` is not installed.
    """
    try:
        import requests
    except ImportError as error:  # pragma: no cover - depends on the environment
        raise SystemExit(
            "fetching needs `requests`: pip install -e '.[dev]' or pip install requests"
        ) from error

    cache.mkdir(parents=True, exist_ok=True)
    records: list[dict[str, str]] = []
    for index, raw_id in enumerate(pmc_ids):
        pmc_id = raw_id if raw_id.upper().startswith("PMC") else f"PMC{raw_id}"
        target = cache / f"{pmc_id}.xml"
        if target.exists():
            body = target.read_bytes()
        else:
            if index:
                time.sleep(_REQUEST_DELAY_SECONDS)
            response = requests.get(
                _FULLTEXT_URL.format(pmc_id=pmc_id), timeout=_REQUEST_TIMEOUT_SECONDS
            )
            if response.status_code != 200 or not response.content.lstrip().startswith(b"<"):
                print(f"  skipped {pmc_id}: HTTP {response.status_code}", file=sys.stderr)
                continue
            body = response.content
            target.write_bytes(body)
        records.append(
            {
                "pmcId": pmc_id,
                "file": target.name,
                "sha256": hashlib.sha256(body).hexdigest(),
            }
        )
        print(f"  {len(records):4d}/{len(pmc_ids)}  {pmc_id}", file=sys.stderr)

    manifest = cache / "manifest.json"
    manifest.write_text(
        json.dumps(
            {
                "retrieved": date.today().isoformat(),
                "sourceEndpoint": _FULLTEXT_URL,
                "articles": records,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return manifest


def search(query: str, limit: int) -> list[str]:
    """Find open-access PMC ids matching a Europe PMC query.

    Args:
        query: A Europe PMC search expression.
        limit: How many identifiers to return at most.

    Returns:
        PMC identifiers, in the order the service returned them.

    Raises:
        SystemExit: If `requests` is not installed.
    """
    try:
        import requests
    except ImportError as error:  # pragma: no cover - depends on the environment
        raise SystemExit(
            "searching needs `requests`: pip install requests"
        ) from error

    found: list[str] = []
    cursor = "*"
    while len(found) < limit:
        response = requests.get(
            _SEARCH_URL,
            params={
                "query": query,
                "format": "json",
                "pageSize": min(_SEARCH_PAGE_SIZE, limit - len(found)),
                "cursorMark": cursor,
            },
            timeout=_REQUEST_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        payload = response.json()
        results = payload.get("resultList", {}).get("result", [])
        if not results:
            break
        for result in results:
            pmc_id = result.get("pmcid")
            if pmc_id:
                found.append(pmc_id)
        next_cursor = payload.get("nextCursorMark")
        if not next_cursor or next_cursor == cursor:
            break
        cursor = next_cursor
        time.sleep(_REQUEST_DELAY_SECONDS)
    return found[:limit]


@dataclass(frozen=True)
class SampleComposition:
    """What a sample actually contains, as opposed to what was asked for.

    Several of the figures this script reports are properties of a publisher
    rather than of JATS — nested `<fig>` is eLife's figure-supplement
    convention, grouped citations are an RSC chemistry one — so a number is
    only readable against the mix that produced it. A 300-article sample of
    MDPI and Cureus reports nested figures at 0.3% where the curated
    10-journal survey behind the corpus README reports 19.6%. Neither is wrong.

    Attributes:
        articles: How many articles were surveyed.
        with_full_text: How many carry a `<body>` with prose in it.
        by_article_type: Counts keyed by the `article-type` attribute.
        by_journal: Counts keyed by journal title, most frequent first.
    """

    articles: int
    with_full_text: int
    by_article_type: dict[str, int]
    by_journal: dict[str, int]

    @property
    def full_text_share(self) -> float:
        """The fraction of the sample that can answer a structural question."""
        return self.with_full_text / self.articles if self.articles else 0.0

    def as_json(self) -> dict[str, object]:
        """The same values under the JSON output's key style."""
        return {
            "articles": self.articles,
            "withFullText": self.with_full_text,
            "fullTextShare": self.full_text_share,
            "byArticleType": self.by_article_type,
            "byJournal": self.by_journal,
        }


def describe_sample(articles: Sequence[Article]) -> SampleComposition:
    """Summarise what the sample actually contains.

    Every structural measurement is meaningless on a record with no `<body>`,
    and a sample of those reports zeroes that read like findings. So the
    composition is computed on every run rather than being a measurement a
    caller can forget to ask for.

    Args:
        articles: The parsed sample.

    Returns:
        Its composition.
    """
    return SampleComposition(
        articles=len(articles),
        with_full_text=sum(1 for a in articles if a.has_full_text),
        by_article_type=dict(
            Counter(a.article_type or "(unset)" for a in articles).most_common()
        ),
        by_journal=dict(Counter(a.journal or "(unnamed)" for a in articles).most_common()),
    )


# Enough journals to see the shape of the mix without burying the report.
_JOURNALS_SHOWN = 8

# Below this share of full-text articles, the structural counts describe the
# sample's front matter rather than JATS, and the run says so.
_FULL_TEXT_WARNING_THRESHOLD = 0.5


def render_markdown(
    measurements: Sequence[Measurement], articles: Sequence[Article], problems: Sequence[str]
) -> str:
    """Format survey results as markdown."""
    sample = describe_sample(articles)
    share = sample.full_text_share
    lines = [
        "# JATS structural survey",
        "",
        f"{len(articles)} articles, read straight from the XML — "
        "not through `JATSXMLParser`.",
        "",
        f"**Sample composition:** {sample.with_full_text} of {len(articles)} "
        f"carry a `<body>` with prose ({share:.1%}). By `article-type`: "
        + ", ".join(f"`{t}` {n}" for t, n in sample.by_article_type.items())
        + ".",
        "",
        f"**Journals:** {len(sample.by_journal)} — "
        + ", ".join(
            f"{name} ({n})" for name, n in list(sample.by_journal.items())[:_JOURNALS_SHOWN]
        )
        + (
            f", and {len(sample.by_journal) - _JOURNALS_SHOWN} more"
            if len(sample.by_journal) > _JOURNALS_SHOWN
            else ""
        )
        + ". Several figures below are publisher conventions rather than JATS "
        "properties, so read them against this mix.",
        "",
    ]
    if share < _FULL_TEXT_WARNING_THRESHOLD:
        lines += [
            f"> **These counts describe front matter, not JATS structure.** Only "
            f"{share:.1%} of this sample has a body. Europe PMC serves a "
            f"`fullTextXML` document for abstract-only deposits too, and the "
            f"newest open-access records are dominated by conference abstracts, "
            f"so a naive query returns them by the hundred. Re-run with "
            f"`--full-text-only`, or narrow the query.",
            "",
        ]
    if problems:
        lines += ["**Unparseable files:**", ""] + [f"- {p}" for p in problems] + [""]
    for measurement in measurements:
        lines += [f"## {measurement.title}", ""]
        if measurement.headline:
            lines += [measurement.headline, ""]
        if measurement.rows:
            lines += ["| Measurement | Result |", "|---|---|"]
            lines += [f"| {label} | {value} |" for label, value in measurement.rows]
            lines += [""]
        if measurement.notes:
            lines += list(measurement.notes) + [""]
    return "\n".join(lines)


def main(argv: Sequence[str] | None = None) -> int:
    """Run the survey.

    Args:
        argv: Command-line arguments, defaulting to `sys.argv[1:]`.

    Returns:
        `0` on success, `1` if the corpus held no parseable article.
    """
    default_corpus = Path(__file__).resolve().parent.parent / "doc/cross_platform/jats_corpus"
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--corpus", type=Path, default=default_corpus, help="directory of article XML"
    )
    parser.add_argument(
        "--measure",
        action="append",
        metavar="NAME",
        help="run only this measurement; repeatable. Use --list to see the names",
    )
    parser.add_argument("--list", action="store_true", help="list measurement names and exit")
    parser.add_argument(
        "--full-text-only",
        action="store_true",
        help="drop articles with no <body> prose before measuring",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of markdown")
    parser.add_argument(
        "--fetch-query", metavar="QUERY", help="Europe PMC query naming articles to fetch"
    )
    parser.add_argument(
        "--fetch-ids",
        type=Path,
        metavar="FILE",
        help="fetch the ids in this file: a manifest.json, or one id per line",
    )
    parser.add_argument(
        "--limit", type=int, default=200, help="maximum articles to fetch (default 200)"
    )
    parser.add_argument(
        "--cache", type=Path, help="where fetched articles are written; then surveyed"
    )
    args = parser.parse_args(argv)

    if args.list:
        for slug in MEASUREMENTS:
            print(slug)
        return 0

    corpus = args.corpus
    if args.fetch_query or args.fetch_ids:
        if not args.cache:
            parser.error("--fetch-query/--fetch-ids need --cache to say where to write")
        if args.fetch_ids:
            text = args.fetch_ids.read_text(encoding="utf-8")
            if args.fetch_ids.suffix == ".json":
                ids = [a["pmcId"] for a in json.loads(text).get("articles", [])]
            else:
                ids = [line.strip() for line in text.splitlines() if line.strip()]
        else:
            print(f"searching Europe PMC for {args.limit} articles...", file=sys.stderr)
            ids = search(args.fetch_query, args.limit)
        print(f"fetching {len(ids)} articles into {args.cache}...", file=sys.stderr)
        manifest = fetch(ids, args.cache)
        print(f"wrote {manifest}", file=sys.stderr)
        corpus = args.cache

    articles, problems = load_articles(corpus)
    if not articles:
        print(f"no parseable article XML under {corpus}", file=sys.stderr)
        return 1
    if args.full_text_only:
        kept = [a for a in articles if a.has_full_text]
        print(
            f"keeping {len(kept)} of {len(articles)} articles that carry body prose",
            file=sys.stderr,
        )
        articles = kept
        if not articles:
            print("no article in the sample has a <body> with prose", file=sys.stderr)
            return 1

    if args.measure:
        unknown = [name for name in args.measure if name not in MEASUREMENTS]
        if unknown:
            parser.error(
                f"unknown measurement(s): {', '.join(unknown)}. "
                f"Known: {', '.join(MEASUREMENTS)}"
            )
        selected = [MEASUREMENTS[name] for name in args.measure]
    else:
        selected = list(MEASUREMENTS.values())

    results = [measure(articles) for measure in selected]
    if args.json:
        print(
            json.dumps(
                {
                    "articlesSurveyed": len(articles),
                    "sample": describe_sample(articles).as_json(),
                    "articles": [a.pmc_id for a in articles],
                    "unparseable": list(problems),
                    "measurements": {r.name: r.data for r in results},
                },
                indent=2,
            )
        )
    else:
        print(render_markdown(results, articles, problems))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
