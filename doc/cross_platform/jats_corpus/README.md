# Real PMC JATS corpus

Five open-access articles from Europe PMC, committed **verbatim**, with a stored
structural digest of what the parser makes of each. Read by
`Packages/BioMedLit/Tests/BioMedLitTests/JATSRealCorpusTests.swift`, offline, on
every pull request.

## Why this exists

Every other JATS fixture in this repository is hand-written, and hand-written XML
encodes only the shapes its author already knew about. The consequences are
measured, not hypothetical:

- The caption-host defect fixed in the #142 review affected **86 of 386 real
  articles (22.3%)** while all 59 committed JATS tests passed throughout.
- Two of the six defects fixed in #142 were found by surveying live PMC, not by
  the suite.
- The network-gated `JATSXMLParserIntegrationTests` do see real documents, but
  they run nightly and never on a pull request, so they cannot block a merge.

The corpus paid for itself before it landed: hand-checking the five digests
against their source XML found four defects, all confirmed against a 225-article
survey — see **Known defects** below.

## What is here

| File | Purpose |
|---|---|
| `corpus.json` | Provenance: source, licence, SHA-256 and why each article was kept |
| `PMC*.xml` | The article, exactly as Europe PMC served it |
| `PMC*.digest.json` | Structural summary of the parsed article |

### The articles

| PMC ID | Publisher | Size | Licence | Kept for |
|---|---|---|---|---|
| `PMC12759138` | SAGE | 150 KB | **CC-BY-NC-4.0** | `publisher-id` is a DOI wearing an underscore (`10.1177_20552076251406653`), plus `pmcid-ver`; 2 supplementary-material and 2 media captions, 8 tables, 3 figures |
| `PMC12785261` | MDPI | 118 KB | CC-BY-4.0 | A third `publisher-id` shape, the journal slug `healthcare-14-00097` |
| `PMC12661592` | JMIR | 30 KB | CC-BY-4.0 | The degenerate end: one table, no figures, no supplements, no sub-articles |
| `PMC8754430` | eLife | 184 KB | CC-BY-4.0 | Peer-review sub-articles, nested figure supplements, and the only `<boxed-text>` caption in the corpus |
| `PMC12755737` | PLOS ONE | 161 KB | CC-BY-4.0 | No `publisher-id` element at all; 12 supplementary-material captions; all-`<mixed-citation>` references |

Between them they cover all five `<caption>` hosts that occur in the wild, three
`publisher-id` spellings plus its absence, both citation markup styles, and both
ends of the size range.

### Licensing

These are **third-party works, not part of this project's AGPL-3.0 source.** Each
is redistributed unmodified under its own Creative Commons licence, recorded per
article in `corpus.json`.

`PMC12759138` is **CC-BY-NC-4.0**. It is kept deliberately — it is the only
article carrying the DOI-shaped `publisher-id` together with supplementary
material and media-in-figure — but note the constraint: the NC term restricts
commercial use of *that article's text*. It does not reach this repository's
code, and test fixtures ship in no app binary. If that trade ever stops being
acceptable, replacing it means finding a CC-BY article with the same shapes, not
just deleting it.

## The digest is a characterisation, not a specification

A stored digest records **what the parser does today**, which includes behaviour
known to be wrong. A digest change is a prompt to read the diff. It is not by
itself proof of a regression, and it is not by itself proof of a fix.

**Verified by hand against the source XML** when the corpus was committed:
article title, DOI, PMC ID, PMID, journal, volume, author names, section titles
and nesting, figure and table labels, caption text, reference counts.

**Characterised as-is, known to be wrong** — each has an issue, and fixing it is
*expected* to change these files:

| Issue | Shows up in the digests as |
|---|---|
| #154 | `"affiliationCount": 0` on all 17 authors — affiliations are never captured |
| #155 | `PMC12755737`: 72 references, `withAuthors`/`withDOI`/`withPMID`/`withYear` all 0 |
| #156 | `PMC8754430`: 9 figures where the XML has 12; `Figure 2.`, `Figure 4.`, `Figure 5.` are absent |
| #157 | `PMC12661592`: the single table's label is `"a"`, from its footnote, not `"Table 1."` |

**Characterised and believed correct, but worth knowing:**

- `PMC12661592` has two untitled body sections. The article genuinely has no
  `<sec>` in its `<body>`; the second is its back matter (funding, data
  availability, conflicts), which the transparency analysis reads.
- Unstructured abstracts appear as a single section with an empty title.
- `pages` is empty for four of five articles, which use `elocation-id` rather
  than `fpage`/`lpage`.

## Regenerating a digest

```bash
cd Packages/BioMedLit
UPDATE_JATS_DIGESTS=1 swift test --filter JATSRealCorpusTests
```

**Regenerating without reading the resulting diff is the failure mode this whole
corpus exists to prevent.** It converts any regression into a committed
expectation, silently, and the next reader has no way to tell. Read every changed
line and be able to say which fix or which defect produced it.

`testEveryArticleHasAStoredDigest` fails during a regeneration run, because the
digests are written by a test that sorts after it. That is expected on a
regeneration pass and only on one.

## Adding an article

1. Fetch it verbatim: `curl -sS "https://www.ebi.ac.uk/europepmc/webservices/rest/PMCxxxxxxx/fullTextXML" -o PMCxxxxxxx.xml`
2. Check the licence in its `<license>` element and record it in `corpus.json`,
   along with the SHA-256 and a real reason under `inCorpusBecause`. An article
   nobody can justify is one nobody will know how to replace.
3. Generate the digest, then **hand-check it against the XML** before committing.
   That step is where all four defects above came from; skipping it reduces the
   corpus to a change detector.

Never edit the XML. Trimming an article to save space counts as editing, and
turns a real fixture into a synthetic one wearing a real article's name.
`testCorpusBytesAreUnmodified` enforces this against the recorded SHA-256.

## What this corpus cannot do

Nested `<sub-article>` **does not occur in the Europe PMC feed**: 0 of 225
articles surveyed, while 69 (30.7%) carry sub-articles at depth 1. eLife's
decision-letter and reply are siblings, not parent and child.

So the mutation that motivated part of #146 — reducing `subArticleDepth` from a
counter to a 0/1 flag — passes this corpus as well as it passed the 91 synthetic
JATS tests. Real articles cannot cover a shape real articles do not contain. That
line is held instead by
`JATSSubArticleTests.testASectionAfterANestedSubArticleClosesStaysOutOfTheBody`,
which is synthetic *because* the shape is absent from the wild, and which fails
under exactly that mutation.

Real fixtures and synthetic fixtures answer different questions. This corpus
replaces neither the synthetic suite nor the nightly integration run.

## Survey data behind the numbers

The prevalence figures quoted here and in #154–#157 come from 225 open-access
articles pulled from Europe PMC across eLife, PLOS One, PLOS Biology, BMJ Open,
Scientific Reports, Nature Communications, Frontiers in Immunology, JMIR, Trials
and BMC Medicine (2 726 captions, 14 056 references, 1 118 figures, 470 tables).

| Measurement | Result |
|---|---|
| `<caption>` hosts | `fig` 1061, `supplementary-material` 856, `table-wrap` 445, `media` 337, `boxed-text` 27 |
| max `<sub-article>` nesting depth | 1 (0 articles nest) |
| articles with nested `<fig>` | 44 (19.6%) |
| articles using `<mixed-citation>` | 182 (80.9%) |
| articles linking affiliations by `<xref ref-type="aff">` | 222 (98.7%) |
| articles with `<aff>` inline in `<contrib>` | 10 (4.4%) |
| articles with a labelled `<table-wrap-foot><fn>` | 27 (12.0%) |
