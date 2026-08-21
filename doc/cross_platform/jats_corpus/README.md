# Real PMC JATS corpus

Seven open-access articles from Europe PMC, committed **verbatim**, with a stored
structural digest of what the parser makes of each. Read by
`Packages/BioMedLit/Tests/BioMedLitTests/JATSRealCorpusTests.swift`, offline, on
every pull request.

## Why this exists

Every other JATS fixture in this repository is hand-written, and hand-written XML
encodes only the shapes its author already knew about. The consequences are
measured, not hypothetical:

- The caption-host defect fixed in the #142 review affected **86 of 386 real
  articles (22.3%)** while the entire hand-written JATS suite passed throughout.
- Two of the six defects fixed in #142 were found by surveying live PMC, not by
  the suite.
- The network-gated `JATSXMLParserIntegrationTests` do see real documents, but
  they run nightly and never on a pull request, so they cannot block a merge.

The corpus paid for itself before it landed: hand-checking the digests against
their source XML found five defects, all confirmed against a 225-article survey —
see **Known defects** below.

## What is here

| File | Purpose |
|---|---|
| `corpus.json` | Provenance: source, licence, SHA-256 and why each article was kept |
| `PMC*.xml` | The article, exactly as Europe PMC served it |
| `PMC*.digest.json` | Structural summary of the parsed article |

### The articles

| PMC ID | Publisher | Size | Licence | Kept for |
|---|---|---|---|---|
| `PMC12759138` | SAGE | 146 KB | **CC-BY-NC-4.0** | `publisher-id` is a DOI wearing an underscore (`10.1177_20552076251406653`), plus `pmcid-ver`; eight table captions, the heaviest in the corpus |
| `PMC12785261` | MDPI | 115 KB | CC-BY-4.0 | A `publisher-id` that is a bare journal slug, `healthcare-14-00097`; the deepest numbered section hierarchy |
| `PMC12661592` | JMIR | 29 KB | CC-BY-4.0 | The degenerate end: one table, no figures, no supplements, and a `<body>` with no `<sec>` at all. Its table carries the labelled footnote behind #157 |
| `PMC8754430` | eLife | 179 KB | CC-BY-4.0 | Peer-review sub-articles, and figure supplements nested inside their parent `<fig>` — the shape behind #156. Twelve figure captions |
| `PMC12755737` | PLOS ONE | 157 KB | CC-BY-4.0 | No `publisher-id` element at all; twelve supplementary-material captions; all 72 references are `<mixed-citation>` (#155) |
| `PMC13294358` | Nature (Sci Rep) | 63 KB | CC-BY-4.0 | The only `<media>` captions in the corpus, six of them |
| `PMC13295835` | BMJ | 71 KB | CC-BY-4.0 | The only `<boxed-text>` caption — BMJ Open's *Strengths and limitations of this study* block. Also a `<media>` nested inside a `<fig>` |

Caption hosts across the corpus: `fig` 25, `table-wrap` 16,
`supplementary-material` 14, `media` 6, `boxed-text` 1 — all five hosts that
occur in the wild. Four `publisher-id` shapes are represented, including its
complete absence, along with both citation markup styles and both ends of the
size range.

> The `<media>` and `<boxed-text>` articles were added during review of the PR
> that created this corpus. The first five were chosen by counting `<media>` and
> `<boxed-text>` *elements* rather than captions **on** them, so the corpus
> claimed a coverage it did not have. Count the caption's parent, not the element.

### Licensing

These are **third-party works, not part of this project's AGPL-3.0 source.** Each
is redistributed unmodified under its own Creative Commons licence, recorded per
article in `corpus.json`.

`PMC12759138` is **CC-BY-NC-4.0**, the only non-CC-BY article here. It is kept
deliberately: it is the only article carrying the DOI-shaped `publisher-id`,
which is the shape that provoked the empty-typed-`article-id` and
pattern-recovery defects, and it carries the corpus's heaviest table load. The
constraint is that the NC term restricts commercial use of *that article's text*.
It does not reach this repository's code, and fixtures ship in no app binary. If
that trade stops being acceptable, replacing it means finding a CC-BY article
with the same shapes — `testTheCorpusHasNotShrunk` exists so that it cannot
simply be deleted.

## The digest is a characterisation, not a specification

A stored digest records **what the parser does today**, which includes behaviour
known to be wrong. A digest change is a prompt to read the diff. It is not by
itself proof of a regression, and it is not by itself proof of a fix.

Because a characterisation can only ever report "this changed", the comparison
sits on top of a **specification floor** —
`testEveryArticleClearsTheSpecificationFloor` — asserting what must hold for any
real article whatever the digest says: a title, authors, an abstract, body
sections, references, and a recovered PMC ID. Without it, a collapse to zero
could be regenerated into the expectations and would read as correct forever.
`testTheManifestAgreesWithTheParsedArticle` does the same job for identifiers,
checking the parse against values transcribed by hand into `corpus.json` rather
than against the digest, so it survives a blind regeneration.

**Verified by hand against the source XML** when each article was committed:
title, DOI, PMC ID, PMID, journal, volume, author names, section titles and
nesting, figure and table labels, caption text, graphic URLs, reference counts.

**Characterised as-is, known to be wrong** — each has an issue, and fixing it is
*expected* to change these files:

| Issue | Shows up in the digests as |
|---|---|
| #154 | `"affiliationCount": 0` on every author of every article — affiliations are never captured |
| #155 | `PMC12755737`: 72 references and `PMC13294358`: 23, with `withAuthors`/`withDOI`/`withPMID`/`withYear` all 0 |
| #156 | `PMC8754430`: 9 figures where the XML has 12; `Figure 2.`, `Figure 4.`, `Figure 5.` are absent |
| #157 | `PMC12661592`: the single table's label is `"a"`, from its footnote, not `"Table 1."` |
| #161 | `PMC12755737` and `PMC13294358`: `graphicURL` ends `.gif` — the thumbnail, not the full image |

**Characterised and believed correct, but worth knowing:**

- `PMC12661592` has two untitled body sections. The article genuinely has no
  `<sec>` in its `<body>`; the second is its back matter — an acknowledgements
  paragraph, the funding, data-availability and conflicts statements the
  transparency analysis reads, and a stray one-line `<notes>` paragraph, five in
  all.
- An abstract's digest title comes from `<abstract><title>` when the article
  supplies one and is empty otherwise, so both spellings appear here: `"Abstract"`
  for JMIR and PLOS, `""` for MDPI and eLife. Structured abstracts list their own
  section headings.
- `pages` is empty for five of seven, which use `elocation-id` rather than
  `fpage`/`lpage`.

## Regenerating a digest

```bash
cd Packages/BioMedLit
UPDATE_JATS_DIGESTS=1 swift test --filter JATSRealCorpusTests
```

**Regenerating without reading the resulting diff is the failure mode this whole
corpus exists to prevent.** It converts any regression into a committed
expectation, silently, and the next reader has no way to tell. Read every changed
line and be able to say which fix or which defect produced it.

A regeneration run therefore **always fails**, naming the digests it rewrote. It
cannot be mistaken for a verification, and `UPDATE_JATS_DIGESTS` set in CI fails
the run outright. Re-run without the variable to actually verify.

## Adding an article

1. Fetch it verbatim: `curl -sS "https://www.ebi.ac.uk/europepmc/webservices/rest/PMCxxxxxxx/fullTextXML" -o PMCxxxxxxx.xml`
2. Check the licence in its `<license>` element and record it in `corpus.json`,
   along with the SHA-256 and a real reason under `inCorpusBecause`. An article
   nobody can justify is one nobody will know how to replace.
3. Raise `expectedArticleCount` in `JATSRealCorpusTests`.
4. Generate the digest, then **hand-check it against the XML** before committing.
   That step is where all five defects above came from; skipping it reduces the
   corpus to a change detector.

Never edit the XML. Trimming an article to save space counts as editing, and
turns a real fixture into a synthetic one wearing a real article's name.
`testCorpusBytesAreUnmodified` enforces this against the recorded SHA-256, and
`.gitattributes` keeps the files out of git's line-ending translation so a
checkout on another platform cannot rewrite them.

## What this corpus cannot do

Nested `<sub-article>` **did not occur in any of the 225 articles surveyed**,
while 69 (30.7%) carried sub-articles at depth 1. eLife's decision-letter and
reply are siblings, not parent and child, in both its older and current shapes.

So the mutation that motivated part of #146 — reducing `subArticleDepth` from a
counter to a 0/1 flag — passes this corpus as readily as it passed the
hand-written suite. Real articles cannot cover a shape real articles do not
contain. That line is held instead by
`JATSNestingTests.testNestedSubArticleTailIsStillExcluded`, which is synthetic
*because* the shape is absent from the wild. That test previously claimed the
guard without providing it: its outer tail held only loose `<p>`, which is
dropped for an unrelated reason, so it passed under the mutation. It now carries
a `<sec>` in the tail and is the single test that fails when the counter becomes
a flag.

Other blind spots worth knowing, all deliberate:

- Body prose is stored as paragraph and scalar **counts**, not text, so
  same-length filler substituted for real prose would pass. Storing the prose
  would make this a golden snapshot nobody reviews and everybody regenerates.
  Abstracts and captions *are* stored in full, being short.
- `markdownRowCount` counts lines in the rendered table, so a column swap or a
  header/body inversion that preserves the line count would pass.
- Table cell text is not stored at all, only the rendered row count, so a
  change confined to cell contents would pass. `PMC13294358` and `PMC13295835`
  do carry real `colspan`/`rowspan`, so the table-padding branch at least sees
  real input rather than only hand-written fixtures.

## Survey data behind the numbers

The prevalence figures quoted here and in #154–#157 and #161 come from 225
open-access articles pulled from Europe PMC across eLife, PLOS One, PLOS Biology,
BMJ Open, Scientific Reports, Nature Communications, Frontiers in Immunology,
JMIR, Trials and BMC Medicine (2 726 captions, 14 056 references, 1 118 figures,
470 tables). The 86-of-386 caption-host figure quoted at the top of this file is
from the separate, earlier survey conducted during the #142 review.

| Measurement | Result |
|---|---|
| `<caption>` hosts | `fig` 1061, `supplementary-material` 856, `table-wrap` 445, `media` 337, `boxed-text` 27 |
| max `<sub-article>` nesting depth | 1 (no article nested) |
| articles with nested `<fig>` | 44 (19.6%) |
| articles using `<mixed-citation>` | 182 (80.9%) |
| articles linking affiliations by `<xref ref-type="aff">` | 222 (98.7%) |
| articles with `<aff>` inline in `<contrib>` | 10 (4.4%) |
| articles with a labelled `<table-wrap-foot><fn>` | 27 (12.0%) |
| figures whose last `<graphic>` is a thumbnail | 507 of 959 (52.9%) |
