# Retraction checking: a retracted paper never counts as evidence

Phase 7 of `doc/plans/2026-10-17-port-bmlib-advances.md` (approved
2026-10-17), ledger row `bmlib:0.7.0-retraction-watch`. All three platforms,
desktop first. **The rule and the source parsing come from bmlib**
([bmlib#504](https://github.com/hherb/bmlib/issues/504)). This repo starts
building after bmlib#504 has landed.

## Why

No platform here can tell a retracted paper from a sound one. A systematic
review, a fact-check or a report can therefore rest on a retracted paper and
say nothing about it. Wakefield 1998 and the 2020 Surgisphere papers are
ordinary search hits today. The only trace of the problem in the code is
iOS's PubMed query, which drops `"Retracted Publication"[pt]` without saying
so, and a desktop map that reads that label as the study design "other".
Nothing reads the label at run time.

## Decisions (maintainer, 2026-10-18)

1. **A retracted paper is never used.** When the app works on its own (the
   systematic review, the fact-check, the MCP tools, the report), it leaves
   the paper out and says that it did. When a person is looking at a paper,
   the app tells them it is retracted.
2. **An expression of concern is a warning only.** The paper stays in, with
   the warning shown wherever the paper is shown, the report included.
3. **Saved work gets a warning with an offer to check again.** Reopening a
   saved session or report shows when its papers were last checked and
   offers to check them now. A paper retracted since then is named in a
   warning.
4. **Both Retraction Watch and Crossref are checked**, plus the PubMed
   label. Neither source contains the other (measured, see *Sources*), and
   the maintainer wants no gap and no drift.
5. **The rule lives in bmlib, and the apps consume it through bmlib's Rust
   (UniFFI).** One rule and one contract fixture for Python, Rust and all
   three platforms. Asked for in bmlib#504.
6. **An MCP tool asked for one paper by ID** (`get_document_fulltext`,
   `ask_document`) returns it, with the retraction stated at the top (date,
   notice), as the interrogation tab does for a person.
7. Accepted as proposed (the maintainer agreed to all of these):
   - A paper the app could not check is shown as "retraction status not
     checked". It is never treated as clear.
   - An excluded paper stays in the audit trail with its reason, the date of
     the retraction and the notice's DOI.
   - A reinstatement undoes a retraction. Only the newest retraction or
     reinstatement decides (bmlib's `is_retracted` rule).
   - A correction or erratum shows nothing.

## Goals

- Every document that enters a workflow on any platform gets one of four
  statuses: **retracted**, **concern**, **clear** or **unchecked**. The
  status is computed by one pure function and pinned by one shared contract.
- No retracted document is scored, cited or reported by an unattended
  workflow. Each one leaves a visible trace: in the run's summary, the audit
  trail and the report.
- A person who opens a retracted paper (the interrogation tab, a document
  card, the report) sees that it is retracted, when, and the notice's DOI.
- Saved sessions and reports show when their papers were last checked, and
  can be checked again on request.

## Non-goals

- **No automatic re-check of saved work in the background.** Checking again
  is offered, never done unasked.
- **No automatic rewrite of a finished report.** A paper retracted after the
  report was written is named in a warning; re-running the work is the
  person's choice.
- No warnings for corrections or errata.
- No embedded-browser or full-text work. The check reads metadata only.

## Anti-goals (a failure even if it works)

- **"Couldn't check" read as "not retracted".** An unreachable Crossref, a
  malformed answer, a Retraction Watch export that was not consulted, or a
  paper with no DOI and no PMID is **unchecked**, never **clear**.
  This is the repo's most repeated defect family
  (`unreachable-is-not-absent`); every such branch keeps a control test.
- **A paper that disappears without a trace.** Every exclusion is counted
  and named. iOS's silent query filter is the counter-example (see
  *Platform notes*).
- **A run that stops because the check failed.** An unchecked paper goes on
  through the workflow, marked unchecked. Its count appears in the run's
  summary, as a shortfall would.
- **A notice that flags itself.** A retraction *notice* is never marked
  retracted on the strength of the relation to the paper it retracts. The
  guard is part of the status rule (see *Known data quirks*).

## Sources (measured 2026-10-18)

| Source | Reached by | Has what the others lack |
|---|---|---|
| Retraction Watch export (Crossref-distributed CSV, 67.6 MB, 73,283 rows, monthly) | DOI **and** PMID, from a local copy | 5,886 of 67,845 retractions (8.7%) have no DOI (714 have a PMID). Of 300 sampled retractions with a DOI, 6 DOIs are unknown to Crossref and 10 more lack that RW record in Crossref's `updated-by`. |
| Crossref works API, `updated-by` / `update-to` (`source`: `retraction-watch` or `publisher`) | DOI, live, batched (`filter=doi:a,doi:b,…`) | 77 of 197 sampled publisher-deposited retractions are not in the export. |
| PubMed `<PublicationType>` / Europe PMC `pubTypeList.pubType`, `Retracted Publication` (D016441) | the search record itself | Free, already fetched. Verified on PMID 9500320 and 32356626. |

## The status rule (bmlib's, one contract)

bmlib#504 specifies it in full. The rule takes source-neutral evidence from
all three sources and returns `retracted`, `concern`, `clear` or
`unchecked`, plus the deciding notice and the sources that did not answer.
In short:

- Newest first among retraction, withdrawal, removal and reinstatement, the
  first decides; corrections and errata are evidence of nothing. On equal
  dates the reinstatement wins; undated entries are oldest.
- The `Retracted Publication` label settles retraction alone, unless a later
  reinstatement is named.
- `concern`: an expression of concern or a partial retraction, not undone.
- **`clear` needs every source answered.** Anything less is `unchecked`,
  naming what did not answer. (How a DOI Crossref does not know is read is
  settled in bmlib#504.)
- A notice never flags itself, and Elsevier's self-referencing retraction
  stays a retraction (see *Known data quirks*).
- An unknown type is logged once at WARNING and decides nothing.

The fixture bmlib#504 adds is copied to
`doc/cross_platform/retraction_parity/retraction_status.json`, following the
`_readme` conventions of `request_failure_parity/answered_lookup_verb.json`.
All three suites assert against it.

## The lookups

- **Crossref**: bmlib builds the batched request URLs and parses the answers
  (`select=DOI,update-to,updated-by`). Each platform sends them over its own
  transport and pacing: on the desktop, `mount_politely` and
  `POLITE_RATE_CEILINGS["api.crossref.org"]`; on the apps, their existing
  Crossref pacing, with the same mailto User-Agent. **A failed batch leaves
  every DOI in it unanswered**, typed with a `RequestFailure` (or the
  platform's equivalent). No status is ever inferred from it.
- **Retraction Watch export**: a local copy, refreshed monthly (*my call:*
  `RETRACTION_WATCH_MAX_AGE_DAYS` = 35; the export is monthly). Downloaded
  over Wi-Fi only on the apps. Its form (a SQLite index built from the CSV
  by bmlib's Rust parser, or a compact index bmlib publishes) is settled in
  bmlib#504. A missing, stale or unreadable copy means "export not
  consulted": the paper is `unchecked`, and the run's summary says why. Each
  verdict can say "Retraction Watch data as of <date>".
- **The label**: the search parsers keep publication types (see *Storage*).
- **Freshness.** A stored verdict older than `RETRACTION_CHECK_MAX_AGE_DAYS`
  is checked again before a new run uses it. *My call:* 7 days, a constant.
  A retraction can land any day, and a check costs about one request per 50
  papers.
- **The desktop** uses bmlib's Python API, or mirrors it against the shared
  fixture. Lite does not depend on bmlib yet (Phase 8). The plan decides
  which, once bmlib#504 has landed.

## Where the check runs

The status is decided **after the search and before anything is scored**,
at one choke point per workflow. Every path that brings documents in passes
through it: a search, preloaded documents, a restore that resumes work.

**Desktop**
- Systematic review: `gui/systematic_review_tab.py` `WorkflowWorker.run`,
  after documents are gathered and before the quality filter. Retracted
  documents leave the list there.
- MCP `get_document_fulltext` and `ask_document` (one paper the caller
  named): the paper is returned, with its status stated at the top of the
  answer (retracted or concern, the date and the notice; unchecked says so).
- MCP `fact_check_claim` and `search_literature`: the same exclusion. The
  tool's answer lists what was left out and why. The cleanest single hook
  may be inside `LiteSearchAgent.search` (shared by the GUI and MCP). That
  is the builder's call, as long as each workflow excludes exactly once and
  the GUI's audit trail sees the exclusion.
- Interrogation tab: a person chose this paper, so it loads. A prominent
  banner names the retraction (date, notice DOI). Expression of concern
  gets a warning banner. Unchecked shows nothing loud, only a line under
  the title. Use the existing banner/badge patterns, not inline
  stylesheets.
- Document cards: a retracted or concern badge, following the existing
  `transparency_badge` / `quality_badge` pattern.
- Audit trail: a new outcome category, **excluded: retracted**, alongside
  accepted/rejected/failed/not scored in `audit_records.py`. Each entry
  carries the date and the notice's DOI. Today `not_scored` takes anything
  never scored without a reason, and a retraction must not hide in it.
- Report: a short "Left out as retracted" section names each excluded paper
  and its notice. A cited paper under an expression of concern carries a
  caveat at its reference. Reports with no exclusions and no concerns gain
  nothing but the checked-on line (below).
- Run summary and shortfalls: "N retracted papers left out; M papers'
  retraction status could not be checked". The second clause follows the
  existing shortfall notice conventions (`search_failures.py` /
  `analysis_failures.py`): it names the cause class and never carries
  provider text.

**iOS/macOS and Android** do the same at their own choke points:
`FactCheckWorkflow` after search and before `scoreDocuments`. Each shows a
retracted/concern badge on the document views (iOS `ParseWarningBanner`
pattern; Android `DocumentCard`'s warning row). The report gets the same
section and caveat. A restored session gets the same last-checked line and
*Check again*.

## Saved work: "last checked" and "Check again"

- **Each run keeps a snapshot** of the status it used for every document it
  held (cited, scored, excluded, unchecked), with that status's `checked_at`.
  It is stored with the run (the desktop's checkpoint metadata, as
  extraction failures are kept; each app's session). The shared per-paper
  row (see *Storage*) is the latest knowledge. The snapshot is what the run
  saw. A reopened run's audit trail shows the snapshot, so a paper reinstated
  later still reads "excluded: retracted" in the run that left it out.
- **Excluded documents stay linked to their run** so that reopening and
  *Check again* can find them. Today the desktop's `add_question_documents`
  links only scored documents.
- On reopening, a session or report shows the oldest snapshot `checked_at`:
  "Retraction status checked 2026-10-18", followed by "; 2 papers could not be
  checked" when some were not, in the report's methods line too (#631). A
  session older than this feature says "Retraction status never checked".
- **"Used" means cited in the run's report** (the fact-check verdict's
  citations on the apps). Only a used paper's change warrants a warning. A
  scored but uncited paper changed nothing the reader sees.
- **Reopening warns at once from what is already known.** When the shared
  row is newer than the snapshot and now says `retracted` or `concern` for a
  used paper (another run checked it meanwhile), the warning shows straight
  away, without a request. *My call:* the knowledge is already on the
  device. *Check again* is still offered.
- *Check again* checks every document of the run, updates the shared rows
  and the run's snapshot, and warns about each used paper now `retracted` or
  `concern`. The report is not rewritten (non-goal). *My call:* the warning
  suggests re-running the question, and runs nothing.
- Desktop: reopening a question (`gui/app.py` `_on_question_selected`) and a
  saved report file (`report_tab._load_report`). A saved report file holds
  no store row, so its snapshot goes in its `*_audit.json`. *My call:* the
  audit JSON is already the report's companion record.

## Storage

- Desktop: a new `retraction_checks` table keyed by lower-cased DOI, plus a
  PMID key for papers with no DOI. It holds the status, deciding notice
  (type, date, DOI, source), the unanswered sources, the export's data-as-of
  date, `checked_at`, and for an unanswered Crossref the `RequestFailure`
  kind. The local Retraction Watch copy is stored separately, in the form
  bmlib#504 settles. It is added by the existing idempotent
  `_init_sqlite` migration pattern. Keyed by paper rather than by document
  row, so one check serves every session that holds the paper.
- **The search parsers must keep publication types.** Today no platform
  stores them: the desktop's `ArticleMetadata` and Europe PMC mapping drop
  them; Android parses `publicationTypes` then discards it. The label rule
  needs them at check time. PubMed `<PublicationType>` and Europe PMC
  `pubTypeList.pubType` both carry `Retracted Publication` (verified
  2026-10-18 on PMID 9500320 and 32356626). Whether they are persisted or
  only carried to the choke point is the builder's call. A restored session
  without them is still checked against Crossref and the export.
- iOS: SwiftData additions must be lightweight-migratable (new optional
  properties or a new model). **#289 blocks anything else.** Follow the
  *Touching a SwiftData model* rule in HANDOVER's Verify section.
- Android: Room migration 9 → 10, registered in `AppDatabase.ALL_MIGRATIONS`,
  with a migration test.

## Platform notes

- **iOS's PubMed query already excludes `"Retracted Publication"[pt]`**
  (`StructuredQuery.swift` `defaultExcludeTypes`), and nothing records it.
  *My call:* remove that exclusion so iOS behaves like the others. The paper
  then arrives, is caught at the choke point and is counted and named. A
  query filter cannot say what it dropped, and Europe PMC results bypass it
  anyway.
- The desktop's `quality/metadata_filter.py` maps `Retracted Publication` to
  `StudyDesign.OTHER`. Once publication types are carried, that map would
  start firing. The retraction check runs first, so a retracted paper never
  reaches it. Leave the map alone.
- Ledger row `bmlib:0.7.0-retraction-watch`: each platform becomes
  `ported` when its slice lands; the row's note names bmlib#504.

## Known data quirks

- **An inverted publisher relation.** Crossref lists the Surgisphere Lancet
  *notice* (`10.1016/s0140-6736(20)31324-6`) as `updated-by` a `retraction`
  (source `publisher`) pointing at the retracted paper `…31180-6`. The
  notice's own `update-to` names `…31180-6`. The guard: a retraction-family
  `updated-by` entry is ignored when its DOI is a target of the record's own
  retraction-family `update-to` **and that target is not the record's own
  DOI**.
- **Elsevier's self-reference is a real retraction.**
  `10.1016/j.nbd.2014.05.024` and `10.1016/j.jviromet.2009.04.018` are each
  `updated-by` a `retraction` whose DOI is their own, with an `update-to`
  pointing at themselves. These are the retracted papers ("RETRACTED: …").
  A guard without the self-reference exemption would read them as clear.
- Both shapes are bmlib#504 contract cases. A new shape found later becomes
  a new contract case, never a silent patch.
- Retraction Watch and the publisher can both report the same retraction
  under different notice DOIs (the Surgisphere Lancet paper has two). The
  status is unaffected. The *deciding notice* shown is the newest one, and
  on a tie the `retraction-watch` one. *My call:* its record is curated.

## Testing

- The contract suite on all three platforms.
- Lite's side of the lookups (transport, pacing, storage) against canned
  Crossref answers (MockWebServer on Android, a
  stubbed session/URLProtocol elsewhere): served, partial batch (a DOI
  missing), 429 then success, 5xx exhausted, malformed JSON, network error.
  Each failure must produce `unchecked`, with a control test that the served
  path produces `clear`/`retracted`. Likewise a missing, stale and
  unreadable export copy, each against a control.
- A workflow test per platform: a retracted document never reaches scoring,
  appears in the audit trail and the report section, and is counted in the
  summary. An unchecked document is scored and counted.
- No test talks to the live Crossref or downloads the export (see the
  dead-proxy memory).

## Left to the builder

- The exact single hook on the desktop (the review worker and MCP each
  hooking, or `LiteSearchAgent`), subject to "exclude once, audit sees it".
- Whether publication types are persisted or only carried to the choke
  point.
- Wording of banners, badges and the report section, within the repo's
  reader-facing rules (no provider text, golden rule 13).
- Order of the PRs, after bmlib#504 has landed and lite's bmlib pin is
  current (#583). Suggested: (1) the contract fixture and the parsers
  keeping publication types, on all three; (2) desktop lookups, storage,
  choke point, audit, report and UI; (3) desktop saved work; (4) iOS/macOS;
  (5) Android. One branch per PR, never stacked.
