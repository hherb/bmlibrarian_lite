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
  could not read, unless it says retracted: nothing warns more, so a
  retraction is stored whatever was down (#669).
- **A failure is not knowledge.** A stored verdict with a lookup unanswered
  is asked again on every check; a decided one is reused for
  `RETRACTION_CHECK_MAX_AGE_DAYS` (7), unless the record's label now says
  retracted.
- **The label survives everything.** A failed check (the checker could not be
  built, the database raised) still leaves out a paper its label retracts. A
  failed *Check again* stores nothing and the line says the run's record
  stands, but a cited paper its label now retracts is still warned of (#673,
  all three platforms; not on Android without bmlib's native library, which
  the label needs). A shown retraction keeps its own notice, and a shown
  concern stays.
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
  (`unchecked_causes`): the check failed, the copy, an unreadable notice,
  Crossref's failure, no DOI, no usable Crossref answer, no identifiers, or a
  cancel. A restored report gives the count only, as its snapshot does not
  record why; after *Check again* the saved-work line names the causes of
  the papers whose row stays unchecked (#660, all three platforms). A
  decided row kept over an unchecked answer is counted ("could not be
  checked again"), its own answers' causes after the count (#668). When an
  unchecked row was not reached (its document is gone), the unchecked count
  stands alone, as on a reopen, since the others' causes would claim it too.
- **A paper no screen saw is unchecked, never clear.** *Find More Evidence*
  on a run reviewed before retraction checking screens only the papers it
  finds, so the report written again counts every scored paper with no
  snapshot row as unchecked, its count alone (#657, all three platforms; the
  desktop's `write_report_again`). The stored snapshot does not gain them.
  *Check again* does check them (#684): the desktop writes a row for each of
  the run's scored papers with none (`rechecked_snapshot`'s `run_ids`,
  `run_status` None, as for a run that predates the check), and the apps'
  line reads a scored paper's stored check when the run has none
  (`RetractionSavedWork.recheckedChecks`'s `scored`). A paper only another
  run scored still gets no row.
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
  scoring. Each paper's latest check is a `RetractionCheckRecord`, keyed by
  `paperKey` as the desktop's `retraction_checks` row is, and kept when the
  sessions holding the paper are deleted (#651). Not unique, since CloudKit
  allows no unique constraint; readers merge duplicates (`standing`).
  `Document.retractionCheckJSON` is each session's copy: a screen or *Check
  again* brings it up to the record (`adopt`), decides, and writes it back
  (`share`). A stored check naming a status or
  lookup this build does not know is unreadable (`isReadable`), as the
  desktop's `_decode`. What the run used is
  `FactCheckSession.retractionSnapshotJSON`. They can differ: a stored clear
  stands in storage against an outage, but the run is shown unchecked. A
  check that throws still retracts by the record's own label
  (`PaperRetractionCheck.failed(for:at:)`, the desktop's `_label_check`, #656).
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
  run saw (the desktop's `run_status`); its line names why papers stay
  unchecked (`RetractionText.savedWorkLine(_:causes:)`, #660). A run row that is unchecked (a failed
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
`app/.../util/retraction/`, ports of BioMedLit's `Retraction/` files.
`PaperRetractionCheck` is the stored check Swift keeps in
`RetractionChecker.swift` and `Document`; `RetractionConstants` holds what
Swift's `BioMedLitConstants` does; `RetractionService` is Android's own (the
Hilt entry point). `RetractionSavedWork` is Swift's, less `latest`: with one
row per paper, that row is the paper's latest check.

- `RetractionCrossrefLookup` (bmlib's batches over OkHttp, paced and retried
  as `CrossRefService`), `RetractionIndexStore` (the export as bmlib's index
  file under `noBackupFilesDir`), `RetractionChecker`, `PaperRetractionCheck`
  (the stored form, reuse, `standsAgainst`, `take`) and `RetractionSnapshot`
  (read entry by entry), `RetractionNames` (exhaustive `when`s),
  `RetractionText`, `RetractionReportSection`, and `RetractionService`
  (`@Singleton`: the production check, one lookup per process and contact
  address, the stored rows). A stored row naming a status or lookup this
  build does not know is unreadable, as the desktop's `_decode`, so only a
  fully answered check, or a retraction, overwrites it.
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
  **A failing lookup** leaves unchecked every paper with no stored warning
  that stands; **a failure before it** (stored rows unreadable, or the native
  library missing in a debug build without a bmlib checkout) leaves every
  paper unchecked. Either way the record's own label still retracts
  (`PaperRetractionCheck.failedFor`, the desktop's `_label_check`). A Crossref
  batch that fails in any way costs that batch alone.
- The fact-check screen shows `retractionNotice`, badges each card by the
  run's snapshot (`RetractionBadge`) and lists the papers left out after the
  scored ones, each with `RetractionText.excludedLine`.
- The export downloads only on an unmetered network, at launch and in the
  background when a run finds no usable copy; one download at a time,
  streamed to disk, and a refused one is not downloaded again for a day,
  across launches (a `.refused` file beside the index). A run never waits
  for it, and a device that runs out of memory building it carries on
  without it.
- **Saved work.** `restoreForViewing` sets `retractionSavedWorkLine`
  (`savedWorkLine` over `RetractionSavedWork.recheckedChecks`: the run's
  snapshot, or a newer stored row) and `retractionSavedWorkWarning` for cited
  papers whose row now says retracted or concern where the run saw another
  status (or none), with no request. A restored session's cards are badged
  from the same stored rows (`retractionCurrentChecks`); with one row per
  paper, written through `take`, badge and warning agree. Rows that cannot be
  read leave the run's checks and say "later checks could not be read"; a
  restore that cannot read the session's documents at all says "Retraction
  status could not be read", never nothing. *Check again*
  (`checkRetractionsAgain`) stores each paper's answer through the run's
  `take` and never the snapshot. Its answers are laid over the stored rows,
  so they are shown even when storing them failed. It runs in its own job,
  which its own Cancel (`cancelCheckAgain`) stops without touching the
  session's step; a run or restore begun meanwhile cancels it, and it never
  writes their screen. A failure, or a cancel before its answers are in,
  stores nothing and says the run's record stands (a failure still warns by
  the label, and of what an answered check found when its rows could not be
  read, #673); once they are in, they
  are stored and shown whole. Its line names why papers stay unchecked, as
  the run's notice does (#654 item 1; all three platforms since #660). Of #654's other
  items, Android's Check again can be stopped (item 2), but item 3 (the
  not-saved note said on that view only) and item 4 (a failed check recomputes
  the warning from the stored rows and the label) apply to it too. The report screen's
  `DocumentDetailSheet` shows the same check's badge and status line for a
  retracted, concern or unchecked paper (nothing for a clear one), NOT
  CHECKED for one never checked, and "could not be read" when its check
  could not be read; nothing while it loads.

Tests: `FactCheckWorkflowRetractionTest` (one label test needs the host
library), `RetractionBadgeContentTest`, `Migration10To11Test`,
`PublicationTypesTest`, `ReportTextTest`, `RetractionSavedWorkTest` and
`ReportViewModelRetractionTest` (no native library), and the other
`util/retraction/Retraction*Test` suites, which need the host library
(`BMLIB_DIR`); the checker, lookup and index-store suites run over
MockWebServer. CI fails if they skip.

## Tests

`tests/test_retraction_*.py`, `tests/test_mcp_retraction.py`,
`tests/test_cli_retractions.py`. They use stub sessions, never the network.
