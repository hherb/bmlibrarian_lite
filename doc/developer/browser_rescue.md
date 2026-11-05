# Browser Rescue

Developer notes for the desktop's browser rescue (#480, stages 2 and 3). Design and
decisions: `docs/superpowers/specs/2026-10-12-browser-rescue-design.md`. What
the embedded browser passes and what it does not:
`doc/developer/unpaywall_pdf_survey/spikes/README.md`.

Decision labels come from two documents. **Spec D*n*** is the design spec's
(stage 2). A bare **D*n***, here and in code comments, is the stage 3 plan's
(`docs/superpowers/plans/2026-10-15-browser-rescue-stage-3.md`).

## What It Does

An open-access PDF (Unpaywall's or OpenAlex's) whose host answered our client
with a bot wall's challenge page is **queued** instead of given up. Later, the
GUI **visits** its address in a hidden QtWebEngine page, **saves** the PDF
where discovery's cached-PDF tier finds it (`rescue_pdf_path`, in the PDF
library), and **re-analyses** the document so its transparency badge reflects
the full text. What the hidden page cannot pass waits for the reader in the
**review queue window**, whose embedded view shows the page so a person can
tick the robot check (stage 3).

## Modules

- `browser_rescue.py`: the rules, with no Qt and no database access (it imports `sqlite3` only to
  catch its errors). States, outcomes,
  verdicts (`page_verdict`, `download_verdict`, and `title_checked_verdict`
  for a PDF that arrived), `next_state`, which failures are queued
  (`rescue_requests`, `queue_challenged_copies`: a `CHALLENGED` failure of a
  `RESCUABLE_SERVICES` copy, Unpaywall's or OpenAlex's, for a document with a
  DOI), where a rescued PDF goes (`rescue_pdf_path`), the pacing delay
  (`rescue_delay_ms`), `penalise_host_for_answer` and `reanalyse_rescued`.
  Stage 3 adds `dismissed_state` and `dismiss_entry` (a `DismissResult`:
  dismissed, not open, or failed), `awaiting_reader_states`, the reader's
  wait (`wait_watch`, and `wait_outcome`, whose `WaitResult` carries the entry
  that decided it), `WalkEnd`, `HeldPdfKeep`, `fetchable_host`, and `stamp`
  (the stored time format, aware moments only).
- `bot_walls.py`: `challenge_markers`, the defences an answer names (the
  `WALL_MARKERS` needles in its first `CHALLENGE_BODY_PREFIX_BYTES`, a
  defence's own headers, and Cloudflare's own 403 or 503, `Server:
  cloudflare`). Shared with the HTTP client, whose `challenge_failure`
  records a `CHALLENGED` failure; the contract is `doc/cross_platform/fulltext_parity/challenge_detection.json`.
- `rescue_queue_store.py`: the queue's table, `browser_rescue_queue`, one row
  per document and address. SQL only; `LiteStorage` opens the connection.
  `enqueue` is idempotent: an existing entry is left as it is, open or
  settled, except that a higher priority raises an open one's.
  `record_verdict` and `dismiss` each run their own transaction, because the MCP server writes the same table from another process. They
  return a `RecordedVerdict`: the entry as it now stands and whether this
  change was applied, so a rescue another process recorded first is not
  announced twice.
- `gui/rescue_attempt.py`: `RescueAttempt`, one visit of one address, ending in
  exactly one verdict; and `rescue_profile`.
- `gui/browser_rescue_service.py`: `BrowserRescueService`: the hidden pass, the
  window's shown visits and the walk. One visit at a time, driven by signals
  and timers; nothing waits on it.
- `browser_rescue_text.py`: what the reader reads about the queue (state,
  service and verdict labels; the window's and the interrogation tab's
  sentences). Pure text, no Qt.
- `gui/review_queue_dialog.py`: `ReviewQueueDialog`, the review queue window.
  It never imports QtWebEngine: its view comes from `make_view`.
- `gui/rescue_view.py`: `make_rescue_view()`, the only runtime
  QtWebEngineWidgets import (others are for type checking only). `gui/app.py`
  imports it lazily, and only with a service; if it cannot load, the window
  opens without a view, as without QtWebEngine.
- `gui/rescue_queue_indicator.py`: `RescueQueueIndicator`, "Walled PDFs: N" in
  the status bar, hidden at 0.
- `gui/web_engine.py`: `prepare_web_engine()`, QtWebEngine's start-up
  requirement. `gui/app.py` imports the service lazily (`start_browser_rescue`)
  and guards the preparation (`prepare_browser_rescue`), so an app whose
  QtWebEngine cannot load starts without the hidden pass, with a warning in the
  log, a status-bar message (while the setting is on) and the setting shown
  disabled in Settings (`LiteMainWindow.browser_rescue_unavailable`).

## States

```
                  +--> rescued      (PDF arrived and was saved)
                  +--> no_pdf       (page loaded, unchallenged, no PDF)
pending --visit-->+--> gone         (404 or 410)
   ^              +--> too_large    (PDF over MAX_PDF_SIZE)
   |              +--> needs_person (still a challenge, wrong_pdf, unreadable_pdf)
   +--transport---+
   |
   +--transport, attempts >= cap--> needs_person
needs_person --visit, any outcome--> its answer's state
needs_person --transport--> needs_person
```

`dismissed` (the reader set it aside, `dismissed_state`, open entries only; the
last verdict is kept) and `superseded` (another address of the same document
was rescued) are reached outside a visit. `pending` and
`needs_person` are the *open* states; the others are settled and never change.

A **transport** outcome learnt nothing about the article, so the entry stays
`pending` (unreachable is not absent). Transport covers: a network error, a
renderer crash, a stalled download (nothing received for
`RESCUE_DOWNLOAD_STALL_MS`, 20 s) or an interrupted one, an empty download,
a PDF that arrived and could not be kept or read (a `%PDF` body PyMuPDF cannot
open), a visit that could not start (no profile
or PDF folder), a visit with no main-frame answer before
`RESCUE_HIDDEN_TIMEOUT_MS` (`page_verdict` with no status), a page read while a
navigation it started is still open (the page in view is the one being left;
a challenge it shows still counts), and a load failure in Chromium's internal
error domain other than ERR_ABORTED (-3, which a script-driven navigation
produces). A browser status that is no HTTP status counts as none.

A page that answered with a status that says "not now" and shows no challenge
marker (408, 425, 429, any 5xx) is transport too: a temporary server error must
not settle an entry. A 401 or 403 with no marker is a `challenge` with no
markers and waits for a person, since the HTTP client was already walled at that
address. Markers win over the status; 404 and 410 stay `gone`; any other
answered page with no marker and no PDF is `no_pdf`. A download that is not a
PDF goes through the same marker rules: a wall served as a download is a
`challenge`, an empty one is transport, and only the rest is `no_pdf`. A main-frame 429 or 503 also penalises
the host's shared limiter (`limiter_for(host).penalise(retry_after)`, with the
answer's `Retry-After`), except on loopback, so the rescue and the HTTP client
back off together. The hidden page is muted.

- **Spec D2.** `too_large` is its own state: the PDF is real, the application
  just does not download that much.
- **A PDF must carry the article's title (#532).** Before a PDF is renamed
  into place, `pdf_title_check.check_pdf_title` reads its first page with
  text (pages with none before it, an image-only cover, are passed over) and
  asks for at least `PDF_TITLE_MIN_PAIR_SHARE` (0.5) of the title's adjacent
  word pairs (single words are not enough: an article on the same subject
  shares them; the survey is in the constant's comment). A title of at least
  `PDF_TITLE_MIN_JOINED_CHARACTERS` (20) letters and numbers that the page
  carries whole, word breaks ignored on both sides, matches too: a text layer
  can space a word apart or run words together (#546). Markup inside a word
  (`H<sub>2</sub>O<sub>2</sub>`) is read both as a break and as none.
  `title_checked_verdict` maps the check:
  - a mismatch is `wrong_pdf`, which waits for a person (the right PDF may
    still be on the page, so it is never an absence);
  - a title with no words, a PDF with no text on any page (a scan), or a
    title PubMed translated (wholly in square brackets) that the page does
    not carry keeps the PDF, and the verdict says so (`title_unchecked`, shown
    as "its title could not be checked");
  - a file PyMuPDF cannot open, or one with no pages, is `unreadable_pdf`,
    which waits for a person: retrying would fetch the same file. Any error
    PyMuPDF raises is caught; one that is no file error (`ImportError`, an
    `AttributeError` from a changed API) is logged at ERROR as a code fault.

  Each check is logged with its outcome and share. Each visit is checked
  against its entry's `request.title`. The HTTP download paths share the same
  check (#541): a whole download is checked before it replaces the cached
  file, and one that lacks the title is set aside as `<pdf>.mismatch`
  (`pdf_library_check.set_aside`) unless a keep marker names its bytes; the
  cached-PDF tier sets aside a library PDF the same way
  (`check_cached_pdf`), and `bmll keep-pdf` keeps either.
  `verification_warning` warns of a mismatch, no text and an unreadable file,
  and the progress status says `unchecked`, never `mismatch`, for what could
  not be judged.
- **Spec D3.** A transport failure is retried no sooner than
  `RESCUE_RETRY_DELAY_SECONDS` (15 minutes) later. After `MAX_RESCUE_ATTEMPTS`
  (3) the entry becomes `needs_person` and waits for the review queue window.

Three rules inside a visit: a visit accepts only a download its own page
started (the profile is shared, and a page an earlier visit let go of may still
start one: another article's PDF); once a download is accepted, later page
answers are ignored; and a visit that ends mid-download cancels the download
and discards the partial file. If the verdict cannot be written to storage, the service keeps
it and tries the write again, never the visit: the entry is still pending, and
visiting it again would ask the publisher twice. The retry waits
`RESCUE_VERDICT_SAVE_RETRY_SECONDS` (30 s), doubling with each further failure
up to `RESCUE_RETRY_DELAY_SECONDS`, and a successful write resets the wait.
While a verdict is unsaved no new entry is taken, since the next write would
most likely fail too. At quit an unsaved verdict gets one last try, and a
rescue it records is not announced: re-analysing would start an analysis while
the app quits, and the next session's analysis finds the PDF. Any error
writing a verdict holds it like a database lock does; any other unexpected
error in the pass's slots is logged and never leaves the pass busy (#525).

## Shown Visits and the Walk (stage 3)

- **One visit at a time, hidden or shown (D1).** `BrowserRescueService` runs
  the window's visits too: it owns the profile and hands each download to the
  one attempt under way. A shown visit asked for while a hidden one runs
  starts when that one ends. While a shown visit is asked for or under way,
  or a walk runs, the hidden pass takes no entry. Shown visits take their
  host's pacing slot like hidden ones; a slot that cannot be claimed fails
  the visit rather than opening it unpaced.
- **Every visit reads its entry again when it starts.** A shown visit may
  have waited behind a hidden visit, an unsaved verdict or its pacing slot;
  a hidden one, for its slot. One settled meanwhile (rescued, dismissed,
  superseded) is not visited: a shown one ends with `shown_visit_ended(entry
  as it now stands, None)`, and a hidden one is skipped, so it cannot replace
  a PDF already rescued. A shown entry that cannot be read is shown as last
  read.
- **A person's visit is judged only by its download (D2).** `RescueAttempt(...,
  view=, judge_pages=False)`: no timeout, no page verdict. A 404 or a network
  error is shown, not settled, and the host is still penalised for 429/503.
  It ends on a finished download or a renderer crash. A finished download
  that is neither a PDF nor a wall (a citation export, a supplement), which
  would be `no_pdf`, is discarded instead: `download_ignored` is emitted, the
  page stays open, and the next download is taken. A PDF that cannot be
  opened (one that needs a password, damage) is discarded the same way, with
  `download_unreadable`. A PDF that does not carry the title is held (moved
  to `held_download_path`, `<pdf>.held`, out of the way of the partial file,
  which discovery also writes), `download_mismatched` is emitted, and the
  window shows *Keep this PDF*: `BrowserRescueService.keep_shown_pdf` →
  `RescueAttempt.keep_held_pdf` writes its keep marker (`<pdf>.kept`, the
  held file's SHA-256; `pdf_library_check.mark_kept`), renames it into place
  and ends the visit as a rescue, since the check misreads scans with
  garbled text and preprints retitled between versions. Without the marker
  the cached-PDF tier would set it aside as another article's (#541). It
  returns `HeldPdfKeep`: `KEPT`, `NOTHING_HELD`, or `NOT_SAVED` when the
  marker or the rename fails, in which case the file stays held and the
  visit goes on; the window says each. The next
  download (`download_started`, which hides the button), leaving, or the
  visit's end discards it.
  Leaving the visit (another entry, *Dismiss*, closing the window, quit) is
  `abort()`: no verdict, no attempt counted.
- **New windows open in the same page (D3).** `_ShownPage.createWindow`
  returns the page, so a `target=_blank` "Download PDF" link arrives as this
  visit's download. `JavascriptCanOpenWindows` stays off.
- A page deleted while a view shows it leaves the view on a page of its own,
  in the default profile (probed on 6.10.1), so a visit can let its page go
  mid-display.
- **Walk the queue** (`walk(entry_ids, view)`) judges each page as the hidden
  pass does, with `RESCUE_VISIBLE_TIMEOUT_MS` (60 s). It re-reads each entry
  before its visit and skips one no longer open; a queue it cannot read stops
  it (unreadable is not settled). A page that cannot open is counted and
  passed. It ends when the list is done, on `stop_walk()`, when the reader
  chooses an entry, or on `end_shown_visit()` (dismissing the walk's entry,
  selecting a settled one, closing the window). When it ends, the hidden pass
  looks again at once. It may end before `walk()` returns, so the window
  says it is walking before it asks.
- Signals: `entry_changed(entry)` after every applied verdict, hidden or
  shown. `shown_visit_started(entry)`. `shown_visit_ended(entry, verdict |
  None)`, where `None` means left without a verdict; the window reads
  `holds_unsaved_verdict` to tell a saved verdict from one waiting to be.
  `shown_visit_failed(entry)` when the page could not open (`ended(entry,
  None)` comes first). `shown_download_ignored(entry)`. `walk_ended(WalkEnd)`:
  finished, stopped or unreadable, with how many pages could not open.
- **What waits for the reader (D4):** `needs_person`, plus `pending` while no
  hidden pass will visit (`awaiting_reader_states`). The indicator counts
  these, and the window's default filter lists them.
- **Without QtWebEngine (D12)** the window still opens: the list, *Dismiss*
  and *Open in system browser*, with a note in place of the view.

## Who Queues

`assess_document` (`transparency/assessment.py`, the body both analysis paths
share) and the MCP server queue the challenged copies a discovery left. A
queue that cannot be written is logged, never raised: the analysis must not
fail for it.

**The interrogation tab** (stage 3, citation path only, D7) queues what its
full-text discovery left at `RESCUE_PRIORITY_WAITING`.
`FulltextDiscoveryWorker.lookups` carries the record out (D10). Only the
current discovery's signals count: opening another citation stops the running
one and lets go of it, so its late failure starts no wait over the article
now open. The tab waits while one of the entries this load queued is
pending, due now and unvisited since the wait began (`wait_watch`,
`wait_outcome`). The wait ends on any of these:
- a rescue: the PDF is loaded, labelled "fetched in the built-in browser";
- an entry still open, which includes a transport verdict: the abstract,
  "behind a robot check", and an offer to open the review queue on that
  entry;
- everything settled without a PDF: today's fallback;
- *Cancel*: "cancelled", and the entry stays queued;
- `RESCUE_READER_WAIT_LIMIT_MS` (90 s), decided on what is known
  (`wait_outcome(..., final=True)`): a watched entry rescued by another
  process, whose verdict never reached this tab, still loads its PDF.

A queue that cannot be written or read falls back naming the robot check,
never "could not be retrieved"; a verdict whose re-read fails is decided by
the entry it carries. With the hidden pass off or unavailable, or while the
review queue window holds the browser (a visit or a walk), the tab does not
wait (D8). It falls back through `load_from_citation`'s own `fall_back(reason)`,
so a stale cached full text is still preferred to the abstract.

**Spec D1.** A challenged copy is not a paywall. Before stage 2, a challenged 401,
403 or `text/html` 200 at a paywall-looking address took the paywall branch, so
the reader was told a source refused access. It now is a challenged copy and is
queued.

**Spec D7.** The service wakes on the systematic review and Research Questions tabs'
analysis outcomes (an analysis is where walled PDFs are queued); a 60 s poll
(`RESCUE_POLL_INTERVAL_MS`) catches entries other processes wrote. The hidden
pass runs only while `discovery.browser_rescue_hidden` is on (the default).
It is read when an entry is taken and again when its visit starts, after the host's pacing slot,
which a throttling host can push minutes away.

A rescue re-analyses its document when storage holds it
(`reanalyse_rescued`). If that document's analysis is already pending, it may
have passed the cached-PDF tier before the PDF arrived, so the manager analyses
it once more when that one ends (`analyze_document(..., again_if_pending=True)`);
never after `stop()`.

Pacing: the browser does not go through `requests`, so each visit claims its
host's slot with `limiter_for(host).claim()` without sleeping and is scheduled
for then (`rescue_delay_ms`).

## QtWebEngine Facts the Code Depends On

- `prepare_web_engine()` must run **before any `QApplication`** exists: it sets
  `AA_ShareOpenGLContexts` and imports `QtWebEngineCore`. Otherwise the first
  page fails and Qt only warns. The application, `tests/conftest.py`, the
  harness and CI's preflight all call it; it raises if a `QApplication` exists.
- The profile is persistent and owner-only (cookies are the reader's
  clearances), with its PDF viewer **off**, so a PDF arrives through
  `downloadRequested` instead of rendering.
- QtWebEngine's own User-Agent and no automation protocol: what passed the walls
  in the spikes. Nothing is impersonated.
- A load failure's domain says whether the network failed; ERR_ABORTED (-3) is
  not a failure.
- The page is judged by its serialised DOM, after a short grace
  (`RESCUE_PAGE_READ_GRACE_MS`).
- **Page before profile at quit**: pages are deleted first, then the profile.
  `shutdown()` ends a visit with no verdict, so its entry stays as it was.

## Testing

Everything that pumps QtWebEngine runs in `tests/browser_rescue_harness.py`, in
a **subprocess**, against a loopback publisher. Pumping the suite's shared
`QApplication` inherits earlier tests' dangling timers (#516, #517).
`tests/test_browser_rescue_engine.py` runs the harness once and asserts on its
JSON. Stage 3 adds `shown_scenarios`, a shown case in `service_scenarios`, and
`shown_quit_scenario`:
- a hidden visit served another article's PDF (`wrong_pdf`) or one that
  cannot be opened (`unreadable_pdf`): nothing is left in the folder. The
  harness serves real PDFs, checked against `ARTICLE_TITLE`;
- a person's visit in a `QWebEngineView`: the PDF is saved, and a gone page or
  an abstract stays unjudged until it is left;
- a person's visit served another article's PDF: held as `article.pdf.held`,
  then kept with *Keep this PDF*, and the visit ends as a rescue;
- `createWindow`;
- a walk's judged visit;
- a person's visit through the real service (`service_scenarios`);
- quit during a shown visit (`shown_quit_scenario`), after which the entry is
  unchanged and no profile-release warning appears.

Run the harness alone:

```bash
QT_QPA_PLATFORM=offscreen python tests/browser_rescue_harness.py
```

`scripts/browser_rescue_acceptance.py` is the live acceptance run: it queues
the spike's walled addresses in a throwaway data directory, with a fresh
profile, and runs the real `BrowserRescueService` with production timeouts
and pacing until nothing is due, writing one row per address (PDFs go to a
temporary folder, never the reader's library).

The window, the indicator and the tab are tested in the suite with a fake
service, calling slots directly and never pumping. The window's fake service
is coupled as the real one is (choosing an entry or ending the visit stops a
walk; a walk can end inside `walk()`).

A QtWebEngine that cannot start **fails** these tests; it never skips them, as
a skip would leave CI green with the feature untested. CI sets
`QTWEBENGINE_DISABLE_SANDBOX` (its runner cannot sandbox Chromium) and runs
`.github/scripts/qt_preflight.py` first.

## Accepted Limits

- A `no_pdf` or `gone` verdict does not rewrite the stored sentence the reader
  saw ("could not be asked"). Lodged as #524.
- Only one visit runs at a time, so a host whose pacing slot is minutes away
  holds up every other host's entries meanwhile (#531).
- The title check cannot tell an article from its own supplement, or from a
  whole issue, when either carries the title on its first page. A same-subject
  title passes up to 2% of the time (3, 10 and 9 of 500 in the survey; COVID-19
  reviews sharing boilerplate), and a reader's *Keep this PDF* is believed.
  Errata, generic titles, stopword-heavy titles and stamped scans are #543.
- A PDF with a translated title (PubMed's square brackets) that does not
  print the English title is kept unchecked: the PDF is in the article's own
  language, and nothing in the title can be judged against it.
- A `.held` file left by a crash, the title check on the GUI thread, and a
  disk error on arrival said as `transport` are #544.
- An entry is unique by document ID and address, and the MCP server queues
  under its own IDs, so one address can be queued twice (#533).
- A rescue that lands after the interrogation tab's wait ended is not loaded
  into the tab. Opening the citation again finds it, and the offer says so.
- The *Fetch PDF* button's path is not queued (Deferred: #534).
