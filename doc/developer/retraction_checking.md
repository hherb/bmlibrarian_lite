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
  built, or raised) still leaves out a paper its label retracts. A
  failed or stopped *Check again* stores nothing with the run and the line
  says the run's record stands (a stop says it was stopped,
  `CHECK_AGAIN_STOPPED`, #663; on the desktop, the shared `retraction_checks`
  table still keeps what the lookups answered before the stop), but a cited paper its label now retracts is still warned of (#673,
  #675, all three platforms; not on Android without bmlib's native library,
  which the label needs). A shown retraction keeps its own notice, and a shown
  concern stays.
- ***Check again* runs once per session at a time** (Apple, #711: each
  window has its own workflow). A second window's tap is refused, asks
  nothing, and its line ends `RetractionText.checkAgainElsewhere`; a stopped
  check (its Cancel, a workflow swap, a closed window) frees the session at
  once, since it stores nothing.
- **A failed store is not a failed check.** The verdicts are returned even
  when they could not be stored.
- **Neither is a failed stored read** (#720, all three platforms, the run
  and *Check again* alike). Every paper is then asked afresh, as if it had
  no row, so a retraction found earlier is still found and left out;
  nothing is stored, since a row not read may hold a retraction a fresh
  verdict must not overwrite (the desktop's `check`, Android's
  `readStoredChecks`). Apple's shared records are the ones not read
  (`adoptSharedRetractionChecks` returning false): a session's own fresh
  check is still reused, and nothing is shared. Android's *Check again*,
  whose answers live only in the shared rows, then says the new status
  could not be saved.
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
- **A run's record that cannot be read is unread, never "never checked"**
  (#600, #662, all three platforms). Over a record this build cannot read,
  the saved-work line shows the run's papers' stored checks (#727 desktop,
  #733 apps: its scored and cited papers, on the desktop a loaded file's own,
  those with none counted as could not be checked; an answered *Check again*'s
  answers join them, the record still unread; the apps' `unreadRunChecks`, while
  their badges keep every document's check; a failed *Check again*'s label
  stand-ins only warn), and says "Retraction
  status could not be read" (`STATUS_UNREAD` / `RetractionText.statusUnread`)
  while none of them has one. A failed or stopped *Check again* over it
  never says "so this is still the run's record", which could not be read
  (`over_unread_record` / `overUnreadRecord`, #733); on the desktop
  "later checks could not be read" stays after it until a *Check again* answers. Such a record is:
  on the desktop the checkpoint's `retraction_snapshot`, or a loaded file's
  audit JSON `retraction` entry, that is not a list or is a list none of
  whose rows it reads (`stored_snapshot_unreadable`); on the apps the
  snapshot JSON, whole or one entry. A report written again says so as its
  methods line (`RetractionReportSection.unread` / `UNREAD`, no notice): on
  the desktop that line follows `ReportMetadata.retraction_screen`, read by
  the same rule and kept as found (`retraction_screen_unread`) so a later
  save does not erase it. The apps' detail view says it for a paper whose
  own entry or copy cannot be read. Nothing writes over such a record
  (#726, all three platforms): the desktop's *Check again* says the new
  status could not be saved; Find More Evidence and the apps' screen still
  screen, leave out the retracted and store each paper's check in the shared
  rows, but keep the snapshot as found and add `SCREEN_NOT_SAVED` /
  `RetractionText.screenNotSaved` to what they report (the desktop's
  `MoreEvidence.screen_unsaved`, the apps' `RetractionRun.unsaved`); on the
  desktop the worker is told at once (`on_screen_unsaved`), so a run that
  fails or is cancelled after the screen still says it (#731). The
  desktop keeps the ids it left out under `retracted_left_out_unsaved`, so a
  later Find More Evidence does not find them again as new. The desktop's
  report written again over an unreadable checkpoint record says unread, even
  over a readable copy in the report metadata, but that copy stays stored as
  it was, never erased (#730: the report is written from a copy of the
  metadata carrying `retraction_screen_unread`).
- **One unreadable entry in a readable record is its own count** (#600,
  #727 item 2, all three platforms). A desktop snapshot row it cannot read
  (`unread_snapshot_rows`; `RetractionSnapshot.unread_rows`) or an app's
  snapshot entry that does not decode (`retractionSnapshotUnreadIDs` /
  `RetractionSnapshot.unreadIds`) is a paper whose run record is unknown:
  the notice says "N papers' retraction records could not be read" and the
  methods and saved-work lines "; N papers' records could not be read"
  (`not_read_clause` / `notReadClause`), after the rest. N counts papers,
  one per id, as the apps do (`unread_paper_count`): two unreadable desktop
  rows for one paper are one, one beside a readable row for its paper is
  none, and a row naming no id is one. A desktop row is unreadable without
  `document_id` or `status`, or with a status that is not a string (the
  apps cannot decode one either); an unknown status string reads as
  unchecked on every platform (Deferred: #737). It is never counted
  "could not be checked" (no unchecked stand-in, in the line or in a report
  written again), and never listed as left out: whether the run left it out
  is unknown. Nothing writes over it (`keeping_unread_rows`: Check again,
  Find More Evidence's merge, the audit JSON saved again; a report's
  metadata stores `RetractionSnapshot.unread_rows` after its rows; the apps'
  snapshot merge), unless the record also reads a row for that paper, so a *Check again* answer for that paper
  stays in the shared rows only and the line still counts it unread. On the
  desktop its paper counts as seen for Find More Evidence, its audit entry
  (unscored) carries `retraction_record_unread` and the Audit Trail dialog
  lists it under "Retraction Record Could Not Be Read", never "Not Scored",
  and its audit trail card badges NOT CHECKED, "could not be read" (as does
  a row whose deciding evidence this build cannot parse). Android's list badges keep its
  row (the line alone drops it).
- **A paper the run saw unchecked warns of any retraction or concern**, of
  whatever time (#662, all three platforms: the desktop's
  `changed_since_snapshot`, the apps' `RetractionSavedWork.changedSinceRun`).
  An unchecked check's time is no check time, so a retraction stored before
  it (one a failed stored read hid from the run, #720) is still news. The
  latest check a reopen reads never puts an unchecked check over a decided
  one, whatever their times, either way round (#728: the desktop's
  `latest_checks`, the apps' `RetractionSavedWork.rechecked`), so an
  unchecked run row or *Check again* answer never hides an older stored
  retraction; between two decided or two unchecked checks the newer wins.
- **A paper no screen saw is unchecked, never clear.** *Find More Evidence*
  on a run reviewed before retraction checking screens only the papers it
  finds, so the report written again counts every scored paper with no
  snapshot row as unchecked, its count alone (#657, all three platforms; the
  desktop's `write_report_again`). Writing the report again does not add
  them to the stored snapshot; *Check again* does check them (#684). The
  desktop writes a row for each of the run's scored papers with none
  (`rechecked_snapshot`'s `run_ids`, `run_status` None, as for a run that
  predates the check), even when saving it fails; a paper only another run
  scored still gets no row. The apps' line reads such a paper's stored check
  when the run has no check of it (`RetractionSavedWork.recheckedChecks`'s
  `scored`; an unscored document stays out). That holds on every reopen, not
  only after *Check again*: Apple's stored check is this session's own, set
  by its *Check again*, while Android's is the paper's one row, which any
  session may have written, as its line already reads for the run's own
  papers. A reopen with no stored check still leaves the paper out (#685).
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
  allows no unique constraint; readers merge duplicates (`standing`): by
  `checkedAt`, a copy this build cannot read included, which replaces any
  but a retraction and is replaced by a readable check only when every
  lookup answered it or it is a retraction (#694); a copy that does not
  decode has no time and beats all but a readable retraction the merge keeps.
  `Document.retractionCheckJSON` is each session's copy: a screen or *Check
  again* brings it up to the record (`adopt`), decides, and writes it back
  (`share`). A stored check naming a status or
  lookup this build does not know is unreadable (`isReadable`), as the
  desktop's `_decode`. What the run used is
  `FactCheckSession.retractionSnapshotJSON`. They can differ: a stored clear
  stands in storage against an outage, but the run is shown unchecked. A
  check that throws still retracts by the record's own label
  (`PaperRetractionCheck.failed(for:at:)`, the desktop's `_label_check`, #656).
- **A paper is decided once**, as the desktop's `check` (#688): the documents
  of one `paperKey` are given one copy (`RetractionCheckRecord.unify`, in
  `adoptSharedRetractionChecks`) and one paper (`RetractionPaper.merged`: the
  first document's DOI, the first canonical PMID, every publication type),
  asked about once; a paper's label counts as recorded when any of its
  documents recorded it (`Document.takeRetractionChecks`).
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
  `Document.takeRetractionChecks`, which keeps a decided check over an outage,
  and never rewrites the snapshot or the report: the snapshot stays what the
  run saw (the desktop's `run_status`); its line names why papers stay
  unchecked (`RetractionText.savedWorkLine(_:causes:)`, #660). Its own
  Cancel and background expiry stop it (`cancelCheckAgain`, #654), never a
  run it waits behind, and record no stop on the session. A run row that is unchecked (a failed
  check carries its attempt's time) has no check time, so any warning is
  news, whatever its time (#662). The rules are BioMedLit's `RetractionSavedWork`. A left-out row says
  `RetractionText.excludedLine`; the report opens with
  `RetractionReportSection.notice`. The line and warning show above the
  report too (`RetractionSavedWorkSection`, only for the workflow's own
  session), never in its export.
- The export downloads over Wi-Fi only (no cellular, no Low Data Mode). It is
  refreshed at launch and, in the background, by a run that finds no usable
  copy; a run never waits for it. `RetractionIndexStore.refreshIfStale` is
  single-flight: calls meanwhile share one download. A refused export
  (unbuildable, or shrunk) is not downloaded again for a day, across
  launches (a `.refused` file beside the index); an index that cannot be
  written here (`.notStored`) records no wait (#700). A full disk would
  then fetch it every run, so too little free space
  (`retractionWatchMinFreeBytes`), or a folder that cannot be made, skips
  the download as `.notStored` (#702); an unknown free space does not.

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
  Each screen call decides a paper once (#671): `RetractionPaper.merged`
  gives its documents one paper, as the desktop's `check` and Apple's.
- The screen is `FactCheckWorkflow.screenForRetraction`, at the top of
  `scoreDocuments`, which every scoring path calls. A run starts in
  `runHandlingFailures`, `fetchMoreEvidence` and `retryFailedDocuments`.
  **A failing lookup** leaves unchecked every paper with no stored warning
  that stands; **a failure before it** (the native library missing in a
  debug build without a bmlib checkout) leaves every paper unchecked. Stored
  rows that cannot be read are no such failure: every paper is asked afresh
  and nothing is stored (#720). Either way the record's own label still retracts
  (`PaperRetractionCheck.failedFor`, the desktop's `_label_check`). A Crossref
  batch that fails in any way costs that batch alone.
- The fact-check screen shows `retractionNotice`, badges each card by the
  run's snapshot (`RetractionBadge`) and lists the papers left out after the
  scored ones, each with `RetractionText.excludedLine`.
- The export downloads only on an unmetered network, at launch and in the
  background when a run finds no usable copy; one download at a time,
  streamed to disk, and a refused one (unbuildable, or shrunk) is not
  downloaded again for a day, across launches (a `.refused` file beside the
  index); an index that cannot be written (`NotStored`) or a missing native
  library (`NoNativeLibrary`) records no wait (#700); too little free space
  (`RETRACTION_WATCH_MIN_FREE_BYTES`), or a folder that cannot be made,
  skips the download as `NotStored` (#702). A run never waits
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
  stores nothing and says the run's record stands, still warning by the
  label (#673, #675; a failure also of what an answered check found when its
  rows could not be read); once they are in, they
  are stored and shown whole. Its line names why papers stay unchecked, as
  the run's notice does (#654 item 1; all three platforms since #660). Of #654's other
  items, both apps' Check again can be stopped (item 2), but item 3 (the
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
