# Retraction Checking

Developer notes for the desktop's retraction checking. Design and decisions:
`docs/superpowers/specs/2026-10-18-retraction-checking-design.md`. The rule
that turns evidence into a verdict is bmlib's (`bmlib.publications.retraction_status`,
bmlib#504); lite's copy of its contract fixture is
`doc/cross_platform/retraction_parity/` (run by `tests/test_retraction_contract.py`).

## What It Does

Every paper a systematic review, an MCP tool, the interrogation tab or a
Research Questions pass (re-score, re-classify, transparency, benchmark)
holds is checked against three sources, and a saved run's papers again on
*Check again*:

- **Retraction Watch's export**, a local SQLite copy in the data directory
  (`retraction_watch.db`), rebuilt whole on every refresh.
- **Crossref**, asked in batches of up to 50 DOIs over the polite session.
- **The record's PubMed label** ("Retracted Publication"), which needs
  neither network nor database.

bmlib decides a verdict: **retracted**, **concern** (an expression of
concern or a partial retraction), **clear**, or **unchecked**. Clear needs
the export consulted *and* Crossref to have served the DOI; anything less is
unchecked, never clear.

The review leaves retracted papers out before anything is filtered or scored
(the one choke point in `WorkflowWorker.run`); the report names them in a
"Left out as retracted" section and puts a caveat under a cited concern
paper's reference. The MCP tools leave them out too and mark every other
paper with its `retraction_status`.

## Modules

- `retraction_export.py`: the local copy. `export_copy` reports its state
  (`ExportState`: current, stale, missing, unreadable); `export_evidence`
  looks one paper up (`None` when not consulted); `refresh_export` downloads
  and swaps in a new copy, keeping the old one on any failure or cancel.
- `retraction_crossref.py`: `crossref_session` and `lookup_crossref`. A DOI
  that was not asked has no entry; one whose batch failed has a
  `RequestFailure`. Not asked is not unreachable.
- `retraction_store.py`: the `retraction_checks` table (one row per paper,
  keyed `doi:` + Crossref key, else `pmid:` + PMID) and `PaperCheck`.
- `retraction_checks.py`: `RetractionChecker.check`, the rules for reusing
  and replacing stored verdicts; `build_retraction_checker`.
- `retraction_screen.py`: pure. `RetractionScreen` splits documents into kept
  and excluded; `screen_with_fallback` never lets a failed check stop the
  caller; `RetractionSnapshot` rebuilds what a stored report needs. For saved
  work: `stored_checks` (in `retraction_checks.py`) reads the shared rows,
  `latest_checks` and `changed_since_snapshot` decide what a reopen warns of,
  and `rechecked_snapshot` writes *Check again*'s answers into the run's
  snapshot (a checkpoint's metadata, or a report file's `*_audit.json`,
  replaced whole through a temp file in the same directory).
- `retraction_text.py`: the shared reader-facing sentences.
- `gui/retraction_badge.py`: the RETRACTED / CONCERN / NOT CHECKED badge.

## Rules

- **An outage never erases a verdict.** A fresh verdict that leaves
  unanswered a lookup the stored one had answered never replaces it; a
  stored retraction or concern is still returned. A verdict resting on a
  failure only fills a missing row, so it cannot overwrite a row this build
  could not read.
- **A failure is not knowledge.** A stored verdict with a lookup unanswered
  is asked again on every check; a decided one is reused for
  `RETRACTION_CHECK_MAX_AGE_DAYS` (7), unless the record's label now says
  retracted.
- **The label survives everything.** A failed check (the checker could not be
  built, the database raised) still leaves out a paper its label retracts.
- **A failed store is not a failed check.** The verdicts are returned even
  when they could not be stored.
- **A failed check is failed document by document.** `RetractionScreen.failed_ids`
  holds the papers whose checks are a failed check's stand-ins: no check time,
  and "the check failed" as the cause of each kept, unchecked one (a paper
  its label retracts is still left out). When the review screens smart
  search's documents after the search's (`merged_screen`), a batch that was
  checked keeps its times and causes. `failed` means every paper held failed
  (an empty screen never has); *Check again* writes no failed paper's row.
- **Only the review-like workflows download the export.** A copy older than
  `RETRACTION_WATCH_MAX_AGE_DAYS` (35) is not consulted; the review's checker,
  *Check again* and MCP's `fact_check_claim` download a new one (about 68 MB)
  once per run. Cancel or quit stops the review's and *Check again*'s
  download; MCP's runs to the end. MCP's single-paper tools, the
  interrogation tab and the Research Questions passes use the copy there is.
  `bmll retractions-update` refreshes it by hand.
- **A shrunken export is refused.** A new copy holding fewer than
  `RETRACTION_WATCH_MIN_KEEP_RATIO` (95%) of the old copy's notices is a
  partial download; the old copy is kept.
- **Every unchecked paper has a named cause** in the run's summary
  (`_unchecked_causes`): the check failed, the copy, an unreadable notice,
  Crossref's failure, no DOI, no usable Crossref answer, no identifiers, or a
  cancel. A restored report gives the count only, as its snapshot does not
  record why.
- **`excluded` is a fact of the run.** Snapshot rows record whether the run
  left a paper out; a later re-check (*Check again*) may change `status`,
  never that. *Check again* keeps the run's own status and notice as
  `run_status` and `run_deciding`, set once, which the audit counts and the
  "left out" lines read; a `run_status` of `None` means the run's check was
  not recorded. A report file's papers carry the PubMed label their snapshot
  rows were decided by, so a re-check on another machine does not clear a
  paper only its label retracts.

## iOS/macOS

The apps share bmlib's rule, Crossref parsing and export index through
BioMedLit; the app never imports `BmlibCore`.

- `Packages/BioMedLit/Sources/BioMedLit/Retraction/`: `RetractionCrossrefLookup`
  (Crossref over a URLSession), `RetractionIndexStore` (the export as bmlib's
  index file in Application Support, excluded from backup), `RetractionChecker`,
  `RetractionText` (the desktop's sentences), `RetractionNames` and
  `RetractionReportSection` (the report's notice, methods line and "Left out
  as retracted"), `RetractionSavedWork` (a restored session's line and
  warning).
- The screen is the app's `FactCheckWorkflow.screenForRetraction`, before
  scoring. Each document's latest check is `Document.retractionCheckJSON`:
  per document, so per session, not per paper as the desktop's
  `retraction_checks` row is (#651). What the run used is
  `FactCheckSession.retractionSnapshotJSON`. They can differ: a stored clear
  stands in storage against an outage, but the run is shown unchecked.
- Views list and count from the run's snapshot first, then the stored check
  (`FactCheckSession.shownRetractionChecks`, `Document.shownRetractionCheck`).
  The badge and banner (`RetractionBadge`, `RetractionBanner`) show the
  stored check where *Check again* has replaced the run's
  (`Document.badgedRetractionCheck`), as the desktop's card badges the latest;
  another session's newer check for the same paper is not badged (#653).
- A restored session (`FactCheckWorkflow.restoreForViewing`) shows
  `retractionSavedWorkLine` and, for cited papers whose latest stored check
  (this session's, or another document's with the same `RetractionPaper.paperKey`)
  is now retracted or concern where the run's was not,
  `retractionSavedWorkWarning`; no request is made. **Check again**
  (`checkRetractionsAgain`) stores each answer by
  `Document.takeRetractionCheck`, which keeps a decided check over an outage,
  and never rewrites the snapshot or the report: the snapshot stays what the
  run saw (the desktop's `run_status`). A run row that is unchecked (a failed
  check carries its attempt's time) is no check time, so any later warning is
  news. The rules are BioMedLit's `RetractionSavedWork`. A left-out row says
  `RetractionText.excludedLine`; the report opens with
  `RetractionReportSection.notice`. The line and warning show above the
  report too (`RetractionSavedWorkSection`, only for the workflow's own
  session), never in its export.
- The export downloads over Wi-Fi only (no cellular, no Low Data Mode). It is
  refreshed at launch and, in the background, by a run that finds no usable
  copy; a run never waits for it. `RetractionIndexStore.refreshIfStale` is
  single-flight: calls meanwhile share one download.

Tests: `RetractionScreenWorkflowTests`, `RetractionSavedWorkTests` and `RetractionBadgeTests` (app);
`Retraction*Tests`, `ReportFormatterRetractionTests` and
`PublicationTypeParsingTests` (BioMedLit). They run over URLProtocol stubs and
injected checks, never the network.

## Android

The app calls bmlib's rule, Crossref parsing and export index through the
UniFFI bindings (`org.bmlib.ffi`); everything else is in
`app/.../util/retraction/`, each file a port of the BioMedLit file of the
same name.

- `RetractionCrossrefLookup` (bmlib's batches over OkHttp, paced and retried
  as `CrossRefService`), `RetractionIndexStore` (the export as bmlib's index
  file under `noBackupFilesDir`), `RetractionChecker`, `PaperRetractionCheck`
  (the stored form, reuse, `standsAgainst`, `take`) and `RetractionSnapshot`
  (read entry by entry), `RetractionNames` (exhaustive `when`s),
  `RetractionText`, `RetractionReportSection`, and `RetractionService`
  (`@Singleton`: the production check, one lookup per process, the stored rows).
- **Checks are stored per paper**, as the desktop's: Room table
  `retraction_checks` (`paper_key`, `check_json`), so what one session learnt
  serves the next and survives a deleted session. A paper with neither DOI
  nor PMID has no key and no row. What a run used is
  `sessions.retraction_snapshot_json`, by document id, never rewritten by a
  later check. Publication types are `documents.publication_types_json`
  (Room 11); a Europe PMC duplicate's types merge into PubMed's copy.
- The screen is `FactCheckWorkflow.screenForRetraction`, at the top of
  `scoreDocuments`, which every scoring path calls. A run starts in
  `runHandlingFailures`, `fetchMoreEvidence` and `retryFailedDocuments`.
  **The native library may be missing** (a debug build without a bmlib
  checkout): its `UnsatisfiedLinkError` is caught there, and every paper is
  unchecked for the run.
- The fact-check screen shows `retractionNotice`, badges each card by the
  run's snapshot (`RetractionBadge`) and lists the papers left out after the
  scored ones, each with `RetractionText.excludedLine`.
- The export downloads only on an unmetered network, at launch and in the
  background when a run finds no usable copy; one download at a time, and a
  refused one is not downloaded again for a day. A run never waits for it.
- Saved work (a restored session's line and warning, *Check again*) is PR 5b.

Tests: `FactCheckWorkflowRetractionTest`, `RetractionBadgeContentTest`,
`Migration10To11Test`, `PublicationTypesTest` (no native library), and
`util/retraction/Retraction*Test` over MockWebServer, which need the host
library (`BMLIB_DIR`); CI fails if they skip.

## Tests

`tests/test_retraction_*.py`, `tests/test_mcp_retraction.py`,
`tests/test_cli_retractions.py`. They use stub sessions, never the network.
