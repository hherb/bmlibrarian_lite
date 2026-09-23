# Analysis Failure Reporting

A model that could not read a document is not a document with nothing to say.
This document is the cross-platform contract for telling the two apart, from
the failed LLM call to the words the reader sees. It is the companion of
[Search Failure Reporting](search_failure_reporting.md), which covers the
stage before: a source that failed is not a source with no evidence.

Python (`analysis_failures.py`, `audit_records.py`, `agents/`, and for the
source label `gui/document_interrogation_tab.py` with `gui/citation_loader.py`)
is the reference.

| Platform | Status |
|----------|--------|
| Python | Conforms (#261, #262, #263, #264, #302, #303, #304, #306, #307, #310, #314, #315, #316, #320, #324, #326, #327, #346, #347, #352, #353, #354, #355, #356), except two known gaps: the review's quality filter records a failed classification as an "unknown" design (#319), and its `WorkflowWorker` is not yet on the single-terminal-signal contract (#334) |
| Swift (BioMedLit + app) | **Unchecked.** `ParallelScoringService` and `ParallelCitationService` have the same shape; see #300 |
| Android | **Unchecked.** `domain/workflow/` has the same shape; see #300 |

## Why

Before #261–#263, every failure after the search left the pipeline the way a
document the model had judged irrelevant did — as something missing from the
result:

- a provider that could not be reached ended a review with "No documents
  scored 3 or higher. Try lowering the minimum score threshold.", and an MCP
  `fact_check_claim` with "Found 20 documents but none scored above the
  relevance threshold (3/5)." A calling agent reads that as the literature not
  supporting the claim (#262);
- a citation extraction that failed for every relevant document produced "No
  relevant evidence was found in the searched literature. This may indicate:
  1. The topic has limited published research", in the same result that
  reported `documents_relevant` above zero (#261);
- a report the model could not generate came back as the string `Error
  generating report: …`, which the GUI checkpointed as `step="complete"`,
  auto-saved to `~/bmlibrarian_reports/LITE` and listed under Load Report, and
  which MCP returned as a successful result (#263);
- a full text that was retrieved but could not be loaded for interrogation was
  reported as `{"success": true}`, and the caller's next `ask_document` call
  failed with nothing having said why (#264).

## What counts as a failed analysis

A stage failed for a document when the model call did not produce a usable
answer after its retries: a timeout, a refused or unreachable provider, a
rate limit, an answer that could not be parsed, or spent retries. Python
classifies each one into an `EvaluationErrorCode`, whose negative value a
`ScoredDocument` carries in place of a score.

A document that was never attempted did not fail, and is counted in neither
number. At **scoring** that means the documents the run was cancelled before
reaching; a document scored below the threshold *was* attempted and is counted
in `documents_attempted`. At **citation extraction** it also means the
documents below the threshold, which extraction never sees.

A document that failed was not scored and was not rejected. `documents_scored`
is `documents_accepted + documents_rejected`; counting the failures there
leaves the three numbers unreconcilable in the Methodology section.

**An answer with nothing in it is an answer** (#303). Citation extraction's
`{"passages": []}` is well-formed: the model read the text and found nothing
quotable for the question. Treating it as a parse failure spent the retries on
a verdict that was never going to change, cost four model calls per silent
document, and reported a run in which every abstract was read correctly as an
incomplete analysis. A port must tell *parsed, nothing found* from *could
not be read*, as Python's `readable_passages` does:

- An answer is readable when it parses — whole, after stripping a code fence,
  or as the first balanced `{…}` in surrounding prose — to a JSON object whose
  `passages` is an array. A missing or `null` `passages`, or any other shape,
  is a failure, and is retried.
- A passage is usable when it is an object whose `text` is a string holding
  more than whitespace. (`{"text": null}` would become a citation with no
  passage, which storage refuses — ending the whole review over one quote.)
- An empty array is the answer *nothing quotable*: not retried, not counted
  as failed.
- A non-empty array none of whose passages is usable is a failure. One with
  some usable passages keeps them and drops the rest, logging what it dropped.

The report built on no citations then tells three situations apart, because
they are different findings: the extraction **failed** (known only from a
recorded `citation_extraction` shortfall), the relevant documents **held
nothing quotable** (documents were accepted, and nothing was lost — the report
names how many were read, and says each was read successfully), or **no
document was relevant** (the "no relevant evidence" text). Inferring a failure
from the accepted count is the defect: extraction only runs once a document
was accepted, so it called every silent run a failed one.

### A source we could not reach is not a finding

The rule of #186/#187 one layer down, and the one #346 and #347 cost. A
source that **answered "nothing"** and a source we **could not reach** are
opposite answers, and only the first is a fact about the article. Where the
two arrive as the same value — an `Optional[str]` that is `None`, an empty
list of sources — every caller reads them as the first, and the reader is
shown a property of the study that nobody established.

This is not a logging problem. Logging the failure and still reporting the
absence leaves the reader with the fabricated finding (golden rule 8: handled,
logged **and reported**).

- **Make the ambiguity unrepresentable, not documented.** Python's
  `FullTextFetch` carries the XML *or* a `RequestFailure`, and refuses both
  at once; `SourceLookupFailure` names the service a discovery could not ask.
  A docstring saying "`None` is ambiguous here" did not stop a single caller.
- **"Not assessed" is a state of its own, and it costs the paper nothing.**
  An unreachable Europe PMC leaves `DataDisclosureLevel.UNKNOWN`, which scores
  neutral. `NOT_STATED` scores −5 and tells a clinician the study publishes no
  data availability statement — a number and a claim invented out of our own
  throttling. No risk-of-bias indicator may be raised from a source that was
  never read. The conflict of interest path keeps the same rule through
  `COIDisclosureLevel`: `NOT_STATED` costs five points and raises the
  missing-statement indicator, `NOT_ASSESSED` costs nothing and raises
  nothing (#352).
- **One status is genuinely about the article.** Europe PMC answers `404` for
  a PMC ID it holds no open-access full text for, and Unpaywall answers `404`
  for a DOI it has no record of. Those stay absences. Every other failure —
  429, 503, a timeout, a refused connection — is unreachable. Reporting a 404
  as unreachable would put a caveat on every closed-access paper and drown the
  honest majority.
- **The caveat names the service and the failure, never the provider's text.**
  It is built from `RequestFailure.describe()`, which keeps the kind and HTTP
  status only: a `requests` exception embeds the request URL, and the
  Unpaywall URL carries the user's email address, the NCBI one the API key
  (#196, #330). Python's `unreachable_source_caveat()` and
  `no_pdf_sources_message()` are pure, so the sentence is tested without the
  network.
- **Withhold the claim, do not merely deny it.** The discovery sentence used
  to read "The document may require institutional access." When a lookup
  failed, the replacement says a freely available copy may exist and that open
  access *was not established* — it does not repeat the paywall claim in order
  to negate it, because that phrase read in isolation is the harm.
- **Unreadable is not absent either.** A source that answers `2xx` with an
  empty body, or XML that does not parse, has told us nothing about the
  article — so that is "not assessed" too, not an absence. The same for a
  body whose shape we cannot read: `FullTextFetch` refuses a blank XML, and
  the id converter routes a `pmcid` it cannot read to a failure while a
  `pmcid` key that is simply *absent* stays the article's answer.
- **Every unsuccessful path says it in words.** Carrying the failures in a
  field is not reporting them: `DiscoveryResult.lookup_failures` reached no
  consumer in its first form, so the qualifier now goes into `error` on
  every unsuccessful return — the paywall, the failed download, and the
  "no sources" sentence alike. A field nobody reads reproduces the defect
  one layer up.
- **A source nobody read is the same defect as one we could not reach.**
  Only the article's own text can establish that a study declares no
  conflicts. A PubMed record without a `CoiStatement` has not said the
  article carries none: publishers deposit the field unevenly, for 36.5% of
  a 2018 sample and 79.7% of a 2024 one, so its silence is the publisher's
  and not the study's. `ConflictOfInterest` therefore has no default level
  and refuses a "disclosed" with no statement behind it, or a finding drawn
  from a statement that was never read (#352).
- **Unparsed is not absent either.** The rule keeps going down a layer. A
  full text we obtained but could not segment is not the article declaring
  nothing: `extract_fulltext_sections` anchored its heading match, so
  "Declaration of Competing Interest" (Elsevier's standard heading) and
  "Conflict of Interest Statement" (the standard PMC/JATS one) both missed,
  and the article was recorded as declaring no conflicts, charged five
  points and downgraded. Two things follow. Recognise the spellings real
  journals print, and require *positive evidence that the relevant part was
  parsed* before recording an absence — the COI path now records
  `NOT_ASSESSED` with a caveat when no end-matter section was recognised at
  all (#359). Watch especially for a fix that **activates previously dead
  code**: #352 made `missing_coi_triggers_downgrade` live for the first
  time, which turned a latent extractor miss into a forced high-risk badge.
- **Delete a lookup that reads nothing rather than reporting it honestly.**
  The COI path fetched a `resultType=core` Europe PMC record per document,
  named Europe PMC in `data_sources_used`, and read no part of the response
  — which carries no conflict of interest field at all. The fix was to
  remove the fetch and, with it, its ambiguous `Optional[Dict]` (#348,
  #351). A source is named as provenance only when it contributed.
- **A source nobody asked is not a source that answered "nothing".** The
  rule's other half, and the larger population by far. #346 and #347 taught
  the pipeline to tell a source that answered from one it could not reach;
  four paths were still reporting a source *never consulted* as the
  article's own answer. Data availability recorded `NOT_STATED` -- five
  points and "this study publishes no data availability statement" -- for
  every article outside PMC whose full text was not retrieved, which is most
  of them (#353). What follows from fixing it:
  - **A skip is a third state, not a failure.** `SourceLookupSkipped`
    carries `NOT_CONFIGURED` or `NO_IDENTIFIER` beside
    `SourceLookupFailure`, and `LookupRecord` carries both together so one
    value travels from PDF discovery through full-text discovery to the
    analyser. They are separate types because a failure may not recur while
    a skip recurs on every search until something changes, and only the
    second is the reader's to act on: an unconfigured Unpaywall earns a
    sentence of advice, a throttled one does not (#355). Advice the reader
    cannot act on reads as confidently as advice they can (#335).
  - **`NOT_FOUND` is a claim about the article, so only the end of the
    chain may reach it.** Every per-source "this one holds nothing" is
    `NOT_ASSESSED`, because the sources after it have not been asked yet. `FulltextDiscoverer` mapped every failure, every cancel and every
    skipped download to it, erasing #347's distinction one layer up (#354).
    Whether an absence was established is now derived --
    `FulltextResult.absence_established` is true only when the source type
    is `NOT_FOUND` *and* nothing went unasked -- because either condition
    alone lies.
  - **Only report a skip where it changes what can be claimed.** With no
    PMID the PMC path is not consulted, but Unpaywall is what establishes
    open access there: where it answered the claim stands, and where it did
    not, its own entry already withholds the claim. Recording both would
    caveat every DOI-only record twice, which is how an honest majority
    gets drowned -- the same danger as reporting a 404 as unreachable.
  - **A metadata record has the same three states as a full text.**
    `RecordFetch` (served / absent / unreachable) replaced the
    `Optional[Dict]` that PubMed's efetch and CrossRef's works endpoint
    both returned. An unreachable PubMed left `trial_ids` empty and printed
    "Trial Registration: None found"; an unreachable CrossRef left the study
    looking unfunded, with an honest tier and no caveat anywhere (#356). A
    CrossRef 404 is its own answer and stays an absence; an efetch carrying
    no `PubmedArticle` likewise, while XML that will not parse does not
    (#250).
  - **A failure classified is a failure that no longer ends the analysis.**
    `fetch_article` let its request exception out of `analyze()`, so one
    throttled record lost every other dimension of that study's
    transparency. Typing the return fixed the reporting and the blast
    radius together.
  - **The reader is told at every surface, including the agent's.** MCP's
    `get_document_fulltext` answered "Full text not available for this
    article." for every unsuccessful result -- the harm of #262, one tool
    over. It now makes that claim only when the absence was established,
    and carries `absence_established` so a calling agent can tell.
- **Keep a control test for the honest finding, and for the success path.**
  Returning "unknown" unconditionally passes every test that only checks the
  unreachable path. A reachable source that answers "no statement" must still
  report `NOT_STATED`; an article genuinely without an open-access PDF must
  still get today's wording; and a source that *serves* the full text must be
  shown to have it read, or the whole fix can silently become "nothing is
  ever fetched".

**Ports.** Python is canonical and has landed this for every path listed
here (see *Still outstanding* below for what it has not):
the Europe PMC full-text fetch behind data availability and the three
full-text discovery lookups (#346, #347), the conflict of interest
disclosure (#352, #348, #351), and the sources nobody asked -- data
availability outside PMC, full-text discovery's own failures, the skipped
lookups, and the metadata records behind trial registration and funding
(#353, #354, #355, #356, #250). Swift
(`Packages/BioMedLit/Sources/BioMedLit/Transparency/`) and Android still read
an unreachable source as an absence — tracked on #346. Swift does **not**
share the always-true `coi_disclosed` Python has just removed: `COIAnalysisResult.hasStatement`
is an honest two-state boolean. It has the other half of #352 instead — only
two states where three are needed. `TransparencyAnalysisService` takes a COI
statement from the full text alone, so every article whose full text it
never obtained is scored and badged as declaring no conflicts (#357).
Android
analyses no COI at all today (#116). No transparency *pattern* changes here,
so the parity fixtures are not involved; the COI **score** does move, for
studies nobody read.

**Still outstanding in Python**, so do not read the rule as fully enforced
before checking: the download paths still put the provider's own error text
in reader-facing fields (#350); and a DOI-only document never asks PubMed at
all, so its record is honestly reported as unread rather than being read
(#362).

### A correction only reaches the reader if something re-analyses

The rule's last mile, and the one that made every fix above conditional. A
stored assessment is an answer given under the analyser's *old* semantics.
Where nothing compares the two, every correction applies only to documents
analysed after it, and the reader cannot tell which they are looking at.

- **The version a result was produced under is compared, not just stored.**
  `TransparencyResult.analyzer_version` was written, read back and compared
  by nobody, and had been `"1.0"` since it was introduced. One constant --
  `TRANSPARENCY_ANALYZER_VERSION` -- says what this build would find today,
  and `is_current` is the predicate every reader asks (#360). **Bump it
  whenever the analyser's semantics change**: whenever the same inputs could
  produce a different score, risk level, indicator or caveat. Not for a
  refactor that cannot move a result, and not for a change in user settings
  -- thresholds are applied at analysis time and are not part of what the
  version identifies.
- **The comparison is an ordering, and only an *older* version is stale.**
  A result stamped with a version *newer* than this build's must be left
  alone. Treating it as stale re-analyses it and overwrites a better finding
  with a worse one -- across a synced store, or simply two builds over one
  data directory -- and it makes the caveat's own words false, since that
  caveat tells the reader an *earlier* analyser produced the row. Compare
  version components numerically, not as text: `"10.0"` sorts *before*
  `"2.0"` as a string. An absent or unreadable version sorts oldest, so an
  unknown provenance is re-analysed rather than trusted.
- **A version says who produced the row, never whether the analysis
  reached its sources.** A throttled source does not raise: the fetch
  returns "unreachable" and the analysis completes, with a caveat and a
  score that fell because nothing could be established. Stamped with the
  current version, such a row is current forever -- a transient outage
  becomes a permanent risk claim nothing revisits. A result must therefore
  record that a source was unreadable, and a row carrying that flag is a
  cache miss too (`is_final`). It is still *presented*, with its caveat: it
  is a weakened finding, not an absent one.
- **A stale row is a cache miss, not a cache hit.** Re-analysis happens on
  the path that already queues and paces that work (`analyze_document`),
  and `get_documents_pending_transparency` counts a superseded row as
  pending. There is no bulk invalidation on open: these are rate-limited
  network sources, and a user opening the application is not asking for
  every article they have ever searched to be fetched again.
- **But something the reader can reach must ask.** A cache miss is only
  re-analysed when a review asks for its document again, so every study the
  user does not happen to review again kept a withheld badge for good, and
  the pending query had no caller (#373). The remedy is an **explicit
  request, not a sweep**: the Research Questions tab's *Re-analyse
  Transparency* runs the pending documents of one question -- no row, a
  provisional row, or a superseded one -- through the same analysis body the
  review runs (`transparency/assessment.py`), paced by the same per-host
  limiter. "Pending" is the cache's own predicate (`is_final`), asked of the
  same rows, so the pass and the review cannot disagree about what is done.
  A re-analysis that could not read a source is counted as **provisional**,
  neither a success nor a failure: its result is stored and shown, and it
  stays pending.
- **A reloaded question shows what the store holds, and fetches nothing.**
  It used to show no badge at all, so a missing badge meant a fourth thing
  beside disabled, still running and failed. Every document now gets an
  outcome (`stored_transparency_outcomes`): a row this build stands behind,
  or a reason -- superseded, never stored, or no identifier to look one up
  by -- with advice to use the re-analysis only where it can help. A caveat
  may not claim work in progress that is not happening: "is being
  re-analysed" was true only inside a running review.
- **Until it is redone, no surface presents it as a finding.** Five read a
  stored row and made a claim from it: the badge, the report's citation
  warnings (`should_warn_for_citation`, which also gates the reference
  annotations and the prompt's risk context), the report's risk
  distribution, the quality tier downgrade, and the quality filter, which
  would exclude the study from the review altogether. Each asks
  `is_current`. (In the Python build the filter has no caller yet, so of
  the five it is the gate that guards the least today.)
- **Withheld, not dropped -- and that has to hold at every surface, not
  just the badge.** A withheld row is labelled, not omitted: the badge reads
  "Not assessed" and carries the reason on hover, and the reference list
  annotates the entry rather than printing it bare. Bare is not neutral --
  an unannotated reference reads as a study nothing was found against, which
  is the same claim the gate just retracted. An aggregate line elsewhere in
  the document does not discharge this: it is counted over a different
  population than the references, so the reader cannot map it onto any one
  study. The report also names how many rows are waiting, and how many
  studies came back with no finding at all, so no denominator shrinks in
  silence -- and **says what each count is a share of**: "12 of the 40
  studies reviewed; 3 of them are cited in this report" (#372). Both
  populations, not the cited set alone, because a withheld study that was
  not cited is still worth knowing about. A report made before the
  populations were recorded keeps its bare count rather than a guessed one.
- **"Applied" means asked, not answered.** A report whose transparency
  analysis was switched on says so even when every analysis failed. Saying
  "transparency analysis was not applied" over an analysis that ran against
  every study and failed on every one is a positive false statement, in the
  one artefact the reader keeps; a partial outage that merely shrinks the
  count is quieter and no better.
- **Stored scores and risk levels are still not recomputed in place**
  (#145). They are superseded, then replaced by a re-analysis; nothing
  edits an old row to look like a new one.

### A failed analysis is not a document without one

- **A signal nothing connects is not reporting.** `TransparencyManager`
  emitted `analysis_failed` and the application connected `analysis_complete`
  only, so a PubMed outage produced a review in which studies quietly had
  no assessment (#361, #249). A missing badge meant three things at once:
  transparency switched off, the analysis still running, and the analysis
  failed. A reporting path is asserted end to end: not only that the
  emitter fires, but that something connects it. Extracting the wiring so a
  test can reach it creates a second place for the same defect, so the test
  that the wiring *is reached* belongs beside the test of what it does.
- **The payload is a classified value, not a message.** What it emitted was
  `str(e)`, and a `requests` exception embeds the request URL -- the
  Unpaywall one carries the user's email address, the NCBI one the API key
  (#196, #330). `TransparencyAnalysisFailure` carries the document and an
  `EvaluationErrorCode`, or says no identifier was held to ask by;
  `transparency_failure_text` builds the sentence. The raw text stays in
  the log.
- **A request is classified by what the source answered, not by the type
  of the error object.** Classify on the HTTP status where there was a
  response; fall back to the transport failure only where there was none.
  (In Python every `requests` exception inherits from `OSError`, so a
  throttled PubMed, a refused NCBI key and an unplugged cable all read as
  `API_CONNECTION_ERROR`, and the reader was advised to check their
  internet connection for a rate limit they need only wait out.) Three
  corollaries the first pass missed: a status that means "the source
  refused your credentials" may only be read that way for a source this
  build actually sends credentials to -- every other source answers 400 for
  a request it could not parse; a 5xx is the source's own trouble, not the
  reader's network, so it must not be advised as one; and an answer we
  could not *read* is not a source we could not *reach*.
- **Our own defect is not the source's.** A shape error out of our parser
  -- a missing key, an attribute on nothing -- arrives at the same handler
  as a provider failure. Classified by message, it reached the reader as
  "the source's answer could not be read. Try again later": a permanent bug
  in this code reported as someone else's fault, with advice that will
  never work. Enumerate those by type before any message is inspected, and
  give them their own wording and no retry advice.
- **The advice is written for the source that failed.** These are
  literature APIs, not the model provider: "check that Ollama is running"
  for a throttled PubMed is advice the reader cannot act on, which reads as
  confidently as advice they can (#335). `source_failure_advice` is that
  set of sentences, beside `advice_for_causes` and never instead of it.

**Four feed sites found in review of the above.** The types were right and
the claim was still made, because a correct `absence_established` can only
be as honest as what it is fed:

- **Europe PMC holding no open-access copy is not the article saying
  nothing.** `FullTextFetch.absent()` sets neither `failure` nor `xml`, so
  it fell past the unreachable guard *and* the sections guard onto
  `analyze_data_availability(None)` -- `NOT_STATED`, five points, no
  warning. Every embargoed deposit and author manuscript in PMC but outside
  the OA subset. A three-state value needs three arms; two arms and a
  fall-through is how the third state becomes the default (#353).
- **A PDF we hold and cannot read is not an article without one.** An empty
  text extraction fell through to `NOT_FOUND` with a record saying every
  lookup answered -- which is true, and irrelevant: our extractor is what
  came up empty. *Unparsed is not absent*, one layer below #359 (#354).
- **An unreachable Europe PMC recorded nothing.** `get_article_info`
  answered "not in Europe PMC" and "we could not ask" with one `None`
  (#363, now fixed): `fetch_article_info` returns `ArticleInfoFetch`, and
  `get_article_info` keeps the `Optional` for callers that only want the
  record. Until then a throttled Europe PMC left an empty record, so the
  chain's `NOT_FOUND` was an *established* absence and MCP stated it.
- **A source that answered must never be described as unread.**
  `pubmed_record_read` / `crossref_record_read` are set only when a record
  is *served*, so a CrossRef 404 -- the absence the design works hard to
  preserve -- produced "CrossRef was not read". The inverse of the error the
  types exist to prevent, so the flags now carry `*_record_unreachable`
  beside them and the wording is chosen from the state (#356).
- **A withheld claim must stay withheld at every surface.** The risk
  indicator still read an empty `trial_registrations` as "unregistered"
  while the warnings said "not assessed"; `format_report_summary` still
  printed "Trial Registration: None found" and "Industry Funding: NO"; and
  the CSV still exported `0` and `False`. A caveat elsewhere in the document
  does not withhold a claim under KEY FINDINGS.
- `ClinicalTrialsClient.get_study` had the same `Optional[Dict]` shape two
  screens below `RecordFetch`, so a mistyped accession read as an outage.
  Now a `RecordFetch` too.

## What a stage records

`AnalysisShortfall` (`data_models.py`) is the unit:

| Field | Meaning |
|-------|---------|
| `stage` | `scoring` or `citation_extraction`, persisted by those names |
| `documents_failed` | At least one; a shortfall that lost nothing is refused on construction |
| `documents_attempted` | At least `documents_failed` |
| `causes` | Each distinct `EvaluationErrorCode`, in the order it first occurred |

Its clause is `"3 of 20 documents could not be scored (API request timed
out)"`, or `"… could not be read for citations (…)"`. Without a cause, the
count alone: **the reason degrades, the loss never does.**

Twenty documents that timed out are one cause, not twenty — the constructor
reduces repeats, so no reader has to. `SUCCESS` is dropped: it is not a
reason a document was lost.

Rules a port must match exactly, because they are what the reader sees:

- clauses from several stages join with `"; "`;
- both counts carry thousands separators (`"1,200 of 3,000 documents …"`);
- the noun is singular only when **`documents_attempted == 1`** — the sentence
  is "1 of 1 document", never "1 of 20 document". This differs from the search
  contract, where the singular follows the count of what is missing;
- causes are joined with `", "` inside one pair of parentheses.

The constructor refuses what cannot be true: a zero or negative count, a count
that is not a whole number (`true` is not a count), more losses than attempts,
and more distinct causes than documents lost. `from_dict` refuses the same and
additionally drops cause codes this build does not know — **the reason
degrades, the loss never does.**

### Persisted form

`to_dict` writes `stage` as its raw string and `causes` as the
`EvaluationErrorCode` **integer** values, so a port must share those numbers
to read a record written elsewhere.

## What each stage does

- **Scoring** (`LiteScoringAgent.score_documents`) answers with a
  `ScoringOutcome`: the documents that met the threshold, the documents that
  failed, and how many were attempted. When **every** attempted document
  failed, it raises `AnalysisFailedError` instead: there is nothing to proceed
  on, and a threshold message would be read as the literature's answer.
- **Citation extraction** (`LiteCitationAgent.extract_all_citations`) answers
  with a `CitationOutcome` and never raises: losing every document is
  reportable, because the documents are known to be relevant. A report built
  on no citations then says the extraction failed rather than that the
  literature is silent. The outcome **names each document it could not read**,
  with its cause (#310); the failed count and the causes are read from that
  list, so they cannot disagree with it. It refuses a document that failed
  twice, or that failed and was also cited.
- **Report generation** (`LiteReportingAgent.generate_report`,
  `generate_brief_summary`) **raises**. An error message returned as the
  report is a report as far as every caller is concerned.

## What the reader sees

- **A report, or a message standing in for one**, opens with
  `> **Incomplete analysis:** <clauses>. Everything below rests only on the
  documents that were analysed.` The search notice (#247) goes in front of it,
  so a review that lost both reads the search first.
  A check that decides *what a text is* — the Report tab's auto-save — reads
  the body behind **both** notices, never in front of them.
- **The Methodology section** gains `- **Analysis Completeness:** Incomplete:
  <clauses>`. Documents that failed are **not** counted as rejected: recording
  them as rejected is what made a failure read as the literature's answer.
- **The GUI** shows a standing "Incomplete analysis: …" warning under
  Progress, accumulating one clause per stage — a second notice that replaced
  the first would hide what the first said. **Scoring** losing everything ends
  the review with an error naming what failed and what to do next, never a
  threshold message; extraction losing everything does not, per *What each
  stage does* above. Cancellation is not failure: a run the user stopped
  reports as cancelled even when every document it got through had failed.
- **MCP** carries `analysis_shortfalls` beside `retrieval_shortfalls` in every
  `fact_check_claim` result, each entry with a sentence-ready `description`,
  and each source carries `citation_extraction_error`: `null`, or why its
  citations could not be extracted (#310).
  A failed analysis is an error result carrying the same list plus `advice`.
  `get_document_fulltext` reports `interrogation_available`, and
  `interrogation_error` when it is false: the text was retrieved, but
  `ask_document` cannot answer about it.
- **The audit trail** — the durable record, which outlives the session —
  sorts documents by the score they actually received, never by their absence
  from the accepted list (#302). Four outcomes, together holding each found
  document exactly once: **accepted**, **rejected** (carrying the model's own
  explanation, never a sentence the code made up), **failed** (carrying the
  error code, its description, and the raw code as its score), and **not
  scored** (the quality filter's removals and whatever a stopped run never
  reached — no reason is recorded, because none was given). A document the
  found list lacks but a score names, as a restored session can hold, is
  still counted, so the four can then sum to more than were searched. The
  record states the threshold its accepted / rejected split was made with, in
  the file and on screen, since a reader cannot check "below threshold"
  without knowing which. A failure section is drawn only when something
  failed; the summary keeps its zero, because the four counts only reconcile
  against the documents found if all four are shown.
  - **A restored report** is split at the threshold its checkpoint recorded
    (`min_score_threshold` in the checkpoint's metadata, written as the run
    starts), from the scores of that checkpoint's run only — never every run
    of the question merged — and is not saved again: the run saved its own
    record when it ran, and a rebuild from the database is a poorer one. A
    checkpoint older than the key states its threshold as *not recorded*,
    never as the default the split then falls back to.
  - **A record an older build wrote** (no `failed_documents` key) listed
    failures and filtered documents as rejected, each with the reason "Score
    below minimum threshold". It is shown with a note saying so, and without
    that one stock reason; any other reason is the model's and stays. A score
    that is an error code is shown as the failure it names, never as "−4/5".
  - **Silent or unread** (#310). An accepted document with no citation either
    held nothing quotable or could not be read, and only the record can say
    which: it lists the second under `citation_extraction_failed` (id, title,
    error code name, description) and counts them in its summary as
    `documents_citation_extraction_failed`. The dialog says, per relevant
    document, how many citations it gave, "none quotable", or that it could
    not be extracted and why. The checkpoint keeps the list
    (`{"document_id", "error_code"}` with the code's integer value) beside its
    threshold, so a restore can say it too. **Not recorded is not "none
    failed"**: a checkpoint or record older than the list states the count as
    not recorded, omits the list, and says an uncited relevant document may
    have been either. **The list is recorded only once extraction has run to
    the end**: a cancelled run's unreached documents were never read, and
    recorded as complete they read as "none quotable". A list — in a
    checkpoint or an audit file — that cannot be read whole, or that names a
    document twice, reads as not recorded rather than shorter or longer; the
    rest of the record is still shown. An unknown cause code — or one that
    names no failure, such as success — degrades to `UNKNOWN_ERROR`. A failed write of the checkpoint's list does not end the
    review; its restore then says "not recorded". **A restore reads its own
    run's citations**, as it reads its own scores: counted against every
    run's, a document this run found silent reads as cited.
  - **A stored failure has two forms.** Every build since #306 stores a
    failure as its negative code; older ones stored it as a **1** with the
    explanation `"Scoring failed: …"` or `"Could not parse response"` (Python's
    benchmark runner until #306, its review scorer until 2025-12-23). A reader
    that restores, reuses or aggregates stored scores recognises both, by
    score and explanation together — a model that answers 1 gives its own
    reasons — and never shows the older form's text, which is raw provider
    output. Python: `is_scoring_failure()`, its SQL form
    `scoring_failure_sql()` (an exact, case-sensitive prefix match), and
    `as_recorded_failure()`, which the audit's classification applies itself
    — no load path has to remember to — so the older form is audited as a
    failure whose cause cannot be named (#315). **One older form cannot be
    recognised**: the benchmark runner before #306 also stored a JSON answer
    with no `score` in it as a 1 with the model's own explanation. Nothing
    tells those from real 1s, so a result stored before #306 says its 1s may
    include failures, and nothing more can be claimed for it.
  - **An answer holding no score on the scale is a failure, not a score.**
    A `score` that is missing, null, not a whole number, or off the 1–5
    scale, and an answer stated in prose whose number is on another scale
    ("10/10") or is a range ("1-5"), are unreadable: retried, then recorded
    as `JSON_PARSE_ERROR`. Clamped, "0" and "-3" read as a confident "not
    relevant". Once an answer is a JSON object, only that object is read —
    a digit in its explanation is not a score. Python:
    `parse_score_response()`, shared by the review and the benchmark.
- **The live Audit Trail view** follows the record (#307): a document that
  could not be scored is drawn as a failure with its reason (Python: a grey
  "Scoring failed" badge, the description as tooltip), never as its code on
  the score scale, and a listing orders judged documents by score, then the
  failures, then the never scored. The running count of documents scored
  excludes the failures, which are counted beside it.
- **A model benchmark** counts a failure apart from its scores (#306): not in
  the mean, the distribution, the per-document spread, or the agreement
  between models, which is computed over the documents both models judged —
  and is *no figure*, never 100% or 0%, when they judged none in common. A
  model that judged nothing has no mean, no latency and no agreement with
  itself; a document fewer than two models judged has no spread; and the
  disagreement rates are over the documents at least two models judged. What
  a failed call cost still counts. A stored failure is scored again by the
  next benchmark of the question, never replayed as that model's answer —
  and reuse is of the same question only: a relevance score answers one
  question. A cost estimate counts the documents a model has judged, not that
  it ran before. A result stored before failures were counted says its 1s
  may include them, and reads its older-form entries as failures. The run's
  completion message says how many scorings failed. A model that judged
  nothing has no cost per judgement either — ranked at $0.00, the model whose
  every billed call failed was the cheapest — and no score distribution. A
  stored result that cannot be read back says so where the results would be,
  never "no results": that invited paying for the benchmark again. Offline
  comparisons across questions (Python: `scripts/concordance_analysis.py`)
  follow the same rules — failures counted per model and left out, a pair
  with too few documents in common shown as "n/a", never 0%. **A quality
  benchmark** (study design classification or detailed assessment) follows
  them too (#314): a failed call, or an answer naming no recognised design,
  is a failure — never the "unknown" design, which is an answer — counted
  apart from the design and tier distributions and the agreement between
  models; one malformed answer fails its document, not the run. A review's
  assessment stands in for a model's answer only when it records that model
  as its maker, is for the same task, names a design and was not downgraded
  afterwards; a design read from publication-type metadata answers for no
  model. A reused assessment is not counted in cost or speed per
  assessment.
- **Cancelling a benchmark stops it** (#324), relevance and quality alike.
  The runner is asked before each evaluation and stops at the first yes, so a
  cancel stops the run *before* it pays for one more — a flag only the caller
  could see let the run go on calling every model for every document, and
  then threw the result away. What ran before the cancel is real and is kept:
  the run is stored as **cancelled** rather than complete, and its partial
  result is shown rather than dropped. A cancelled run's result carries how
  many evaluations were made of how many planned — a pair that refuses
  impossible counts rather than repairing them — so the message names what
  was evaluated and what was *not started*, and the results view says every
  figure is over that part of the run only. Because that count includes
  evaluations a run replayed from earlier ones, the message says what was not
  started, never what was paid for. The note travels with the data, not only
  the window: an exported cancelled result carries it too. The UI stays busy
  until the run has actually ended: re-enabling the action at once let a
  second run start on top of a live one. A cancelled run is not the
  question's latest benchmark, and a cancel that stopped the run before its
  first evaluation publishes no result at all, rather than replacing a whole
  comparison with an empty one. Cancelling is not failing, but a failure
  mid-cancel is still named — and a run that was cancelled *and* then failed
  is still stored as cancelled, so what it bought stays reusable.

  **Reuse is relevance-only.** The relevance benchmark stores a per-document
  score, so a cancelled run's scores are reused by a later benchmark of the
  question, which would otherwise buy again what the user has paid for. The
  quality benchmark stores no per-document evaluation, so it has nothing from
  an earlier run — cancelled or complete — to reuse; for it, only the
  cancelled status and the partial result are kept.
- **A background run ends, whatever happens to it** (#320, #326). Every
  worker that does analysis in the background ends a run with exactly one
  terminal signal — finished, failed, or cancelled — and the screen that
  started it returns to ready only when one arrives. This is enforced by the
  mechanism the workers emit through, not stated in a comment: a worker that
  fell silent once cancelled (`if not cancelled: finished.emit(...)`, or a
  bare return) left its screen waiting for a signal that never came, stuck
  mid-cancel with its actions disabled until it was rebuilt. The enforcement
  must also cover what the body does not anticipate — a failed import, or a
  failure no `except Exception` catches — because those ended the thread in
  the same silence. A worker that can be cancelled says when it was; a
  worker that cannot be cancelled has nothing to say and no such signal. A
  cancel the runner cannot see is not a cancel: it mutes the progress
  reporting while the run goes on paying for every remaining document.
  *Reference-platform scope:* Python enforces this through `SingleOutcome`
  for every worker in `gui/workers.py` and the two benchmark workers. The
  systematic review's own `WorkflowWorker` is **not** on it yet — it reports
  a cancel as `finished`, and a `BaseException` still leaves it silent — so
  a port that mirrors that worker mirrors a known gap, not the contract
  (#334).
- **A failed pass says what failed and why, not only how many** (#327). A
  re-classification or re-scoring reports one entry per document it could not
  finish, each naming the document and a **classified** cause; from those the
  user is told the cause most of them shared, its share of the total, one
  example document, and what to do about every cause among them. "17
  documents failed" is the same sentence for an unreachable provider, a
  refused key and seventeen unprocessable abstracts — one is a one-line fix
  and another is an afternoon in the log. **The provider's own words are not
  shown**: they can print the request, credentials and all, and stay in the
  log. Spent retries are classified by the failure they were spent on, never
  by the wrapper. A failure the analysis stage *returns* rather than raises
  is classified from the record it stored, not guessed. **A model that
  answers without naming a study design has not failed** — nothing broke, and
  counting it as a failure reported a clean pass as a broken one; it is
  counted apart and the user is told its stored design is unchanged.
- **A rerun retries a failure** (#316). Deduplicating a search for more
  documents against those already scored, a document whose every scoring
  failed is not scored: it is scored again, and the user is told how many are
  retried. A document judged in any run stays judged.
- **A degraded source is named where the source is named** (#304). Falling
  back from full text to the abstract — discovery failing, content arriving
  empty, the load raising, PDF extraction yielding nothing, a paywall the user
  skipped, an article with no identifier to search by — says so wherever the
  source is stated, not only in the log. "The abstract says nothing about X"
  and "the full text says nothing about X" are different claims, and every
  later answer is drawn from whichever was loaded. The reason is a fixed
  phrase per cause, because **the provider's error text never reaches the
  screen**: error text prints the request URL, and on this path that URL
  carries the user's email address (the Unpaywall query). Python states it as
  `Abstract (<phrase>)` in the document header and in the chat's `Source:`
  line; a port may word the phrases in its own idiom, but keeps one per cause:

  | Cause | Python's phrase |
  |-------|-----------------|
  | Discovery failed | the full text could not be retrieved |
  | Content arrived empty | the full text retrieved was empty |
  | Loading the full text raised | the full text was retrieved but could not be read |
  | Paywall, and the user skipped it | the full text is behind a paywall |
  | The user cancelled retrieval | retrieving the full text was cancelled |
  | No DOI, PMID or PMC ID to search by | the article has no DOI, PMID or PMC ID to find a full text by |
  | The PDF yielded no text | no text could be extracted from the PDF |
  | Loading the PDF raised | the PDF was retrieved but could not be read |

  A cancellation is not a failure. Nor is closing a progress indicator
  because the work finished: Qt's `QProgressDialog.close()` emits
  `canceled`, which is how every successful load came to announce first that
  the full text "could not be retrieved".

## Advice

`analysis_failure_advice` says what the user can do, each sentence at most
once, in this order:

| Cause | Sentence |
|-------|----------|
| `API_AUTH_ERROR` | The provider refused the credentials: check the API key in Settings. |
| `API_RATE_LIMIT` | The provider is limiting how often it can be called: wait a minute. |
| `API_TIMEOUT`, `API_CONNECTION_ERROR`, `API_SERVER_ERROR` | Check that the provider is reachable — Ollama running, or the connection. |
| `JSON_PARSE_ERROR`, `INVALID_RESPONSE_FORMAT`, `EMPTY_RESPONSE`, `RESPONSE_TOO_LARGE` | The answers could not be read: another model may do better. |
| anything else | Try again later. |

**Spent retries are not a cause.** Every provider failure is retried, so each
one reaches the agent wrapped in a `RetryExhaustedError`. Recording that
wrapper puts every outage in the last row, which is the one thing the user
cannot act on: a port must classify the failure the retries were *spent on*
(`last_error`), not the wrapper. `RETRY_EXHAUSTED` is recorded only when the
wrapper carries nothing to classify.

## Ports

Nothing here has been checked against Swift or Android (#300).

On the analyser version (#360) the ledger is not symmetric. **Swift already
carries it**, and carries it better: `TransparencyConstants.analyzerVersion`
(an `Int`, with a per-version changelog in its doc comment),
`TransparencyResult.isStale` comparing *strictly older* — with the reason
written down, since a CloudKit-synced `Document` can arrive from a device on
a newer build — and consumers in `Document`, `TransparencyDetailView` and
`MacTransparencyDetailView`, under `TransparencyStalenessTests`. Python
followed it here, to an ordering over dotted components. **Android has
nothing**, and carries #360 in full.

Note the two version spaces are not comparable: Swift counts `Int` (at 3),
Python counts a dotted string (at `"2.0"`). Each platform's constant orders
only against itself; a stored row never crosses between them. Swift's
`TransparencyAnalysisService` additionally reads COI from the full text
alone (#357). Both run the
same pipeline with the same shape — a parallel scoring service that drops
what it could not score, and a report built from whatever citations arrived —
so the same defects are likely present. A port conforms when a review whose
model is unreachable ends in an error naming the stage, the counts and the
cause, with the matching advice from the table above; when no report can
be built from an empty citation list without saying why it is empty; when a
document the model read and found nothing quotable in is not retried, not
counted as failed, and not reported as a failed extraction; when the audit
record sorts every found document into accepted, rejected, failed or not
scored by the score it received, and states the threshold it split at; when
the record names each relevant document whose citations could not be
extracted, and says "not recorded" where it cannot; when a failure is never
drawn or counted as a score, live or in a benchmark; and when a fall back from
full text to the abstract names its cause wherever the source is named. Note
that no platform names the *provider* in that error today; it is a gap to
close in all three, not a conformance criterion.
