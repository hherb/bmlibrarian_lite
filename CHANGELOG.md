# Changelog

All notable changes to BMLibrarian Lite are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions cover the Python desktop package published to PyPI. Changes to the
iOS/macOS and Android apps are noted where they ship in the same release; those
apps additionally carry their own store version tags (`swift_*`, `appstore_*`).

## [Unreleased]

### Fixed

- **Claude works again on a fresh install (#758).** Claude is sent no
  `temperature` or `top_p`. anthropic 1.x and 2.x (2.x is what a fresh
  `pip install` resolves) have no such parameters, so every Claude call
  failed before a request left. Claude Opus 4.7 and later refuse them on the
  API too. Claude now samples at the API's defaults, so a lower temperature
  set for a task no longer takes effect on Claude. Other providers still get
  it.
- **The default Claude models are ones that still answer (#759).** Every
  Claude ID the app shipped or offered (`claude-sonnet-4-20250514`,
  `claude-3-5-haiku-20241022`, `claude-opus-4-20250514`, and older) now
  answers 404. The defaults are `claude-sonnet-5-5` and `claude-haiku-5-5`.
  A saved setting that names a retired ID is sent to its successor in the
  same family, and the log says so.

## [0.6.0] - 2026-11-10

### Added

- **Retraction checking (#594, #597, #605).** Every paper a review finds is
  checked against a local copy of the Retraction Watch data and against
  Crossref, and by its own PubMed label. Retracted papers are left out of the
  review, counted, and named in the report; papers under an expression of
  concern stay in, and the report carries the concern. Badges read RETRACTED,
  CONCERN or NOT CHECKED, and the report says why any paper could not be
  checked. The Retraction Watch copy is downloaded into the data directory
  when a review finds it more than 35 days old (`bmll retractions-update`
  refreshes it at once). A reopened research
  question says when its papers were checked, warns of any cited paper retracted
  or flagged since, and offers *Check again*. A source that could not be reached
  never counts as "no retraction found", and a stored record this build cannot
  read is never written over (#725, #729, #732, #735, #736, #740).
- **Find More Evidence and repeated smart search (#628).** A reviewed research
  question can be searched again for more papers, which are scored into the
  same run before the report is written again. Each smart-search round asks the
  model for alternative queries and lists every query already run, so it does
  not repeat itself.
- **Citations from full text and Retry Full Text (#622).** Under *Settings →
  Full Text*, *Read citations from full text* (off by default) fetches the full
  text of every paper scored at least *Fetch Full Text From Score* (default 4)
  and extracts citations from it. *Research Questions → Retry Full Text* reads
  any full texts a reviewed run missed and writes its report again.
- **Upload Full Text (#626).** Right-click a paper on the Audit Trail's
  literature cards to give it your own PDF, HTML, Markdown or text file; Retry
  Full Text then reads it.
- **More full-text sources (#487, #491, #501, #507).** PMC's open-data bucket
  and every PDF OpenAlex names; with your own key (Settings), CORE's extracted
  text and Elsevier's article API (PDFs for `10.1016/` DOIs). The first copy
  served ends the search, and the report names every source that was tried.
- **A hidden built-in browser for bot-walled PDFs (#480; #521, #529, #536).** An
  open-access PDF whose host answers our downloads with a robot check is queued
  and fetched later by a hidden QtWebEngine page while the app is open; a
  rescued PDF is saved to the library and, when the article is in your library,
  its transparency is re-checked. *Tools → Walled PDFs…* (and the "Walled PDFs:
  N" status-bar count) lists the queue and shows a page so you can tick a
  robot check yourself. Switch the hidden browser off under Settings with "Try
  bot-walled PDFs in a hidden browser".
- **Another article's PDF is set aside, never read (#542, #548).** A PDF whose
  first page does not carry the article's title is renamed to `.mismatch` and
  not used for transparency, interrogation or MCP. If the check is wrong,
  `bmll keep-pdf <path>` restores it.
- **Transparency certainty and High explained (#419).** A rating made without
  the full text reads "Limited certainty because of lack of full text access"
  (its badge carries `· limited`), and a High rating names the rules that made
  it High. The wording matches the iOS/macOS and Android apps.

### Changed

- **Long texts are read whole (#622).** Citation extraction and the quality
  analyses read a paper's text in overlapping 16,000-character windows, without
  the reference list, instead of cutting it short. If one window fails, the
  paper fails; half a text is never reported as read.
- **The transparency analyser reads the article's end matter (#426, #431).**
  Funding, conflict-of-interest and data statements in a full text's front and
  back matter now reach the analysis. A missing statement is charged only when
  the end matter was recognised. The analyser version is now 2.7, so stored
  ratings are offered for re-analysis, and cached full texts are converted
  again.
- **Citation highlights use bmlib's passage matcher (#741).** A highlight is
  exact in the abstract as written. A near match is marked as one, and a quote
  that changes a number, a negation or a direction is not highlighted.
- Europe PMC's full-text XML is asked for only when its record says the article
  is open access (#452), and a preprint's steady HTTP 500 is asked once rather
  than retried (#455).
- BMLibrarian Lite now depends on bmlib, for the retraction rules and passage
  matching (#594). PySide6 is capped below 6.12, which crashes at
  exit (#515).
- A copy behind a robot check is no longer reported as paywalled, so no
  OpenAthens offer is made for it.

### Removed

- **The Playwright fallback (#483).** Removed with it: the public
  `close_browser_session` export; the `use_browser_fallback` and
  `browser_headless` parameters of `PDFDiscoverer`, `FulltextDiscoverer` and
  `StudyTransparencyAnalyzer`; and the transparency CLI's `--no-browser` flag.
  There is no compatibility shim.

### Fixed

- **A source that could not answer is not an absence.** A Europe PMC full-text
  fetch that failed (429, 5xx, timeout) was recorded as "no full text" (#433);
  an exhausted throttle at doi.org read as no PDF (#448); a lookup that
  answered "not served" read as one that could not be asked (#444); and a 5xx
  read as an answer (#449).
- **Unpaywall:** a repository landing page was saved as the PDF (#465), and an
  Unpaywall PDF that could not be downloaded read as "no open-access copy"
  (#482).
- **A model's cut-off or refused answer is never read as a whole one (#630,
  #632, #636, #638, #640).** An answer stopped at its token limit is reported as
  cut off instead of failing to parse and being paid for again; a refusal is
  not retried; a cut-off smart-search answer's complete queries are still run,
  and the reader is told.
- **Identifiers (#565, #566).** A padded or malformed PMID is normalised or not
  sent, rather than recorded as "not found"; the transparency analyser no longer
  takes a *cited* paper's PMC ID and DOI from PubMed's reference list.
- A `null` or non-numeric value in a model's quality answer no longer makes the
  study unclassified or crashes the assessment (#568).
- Europe PMC's own open-access PDFs are now used (#569); authors declared on the
  JATS author group are kept (#570); text around inline markup in PubMed titles
  and abstracts is kept (#397); a trial is recognised only by whole words in its
  title (#410).
- The settings dialog no longer aborts the app when closed while a model list
  is loading (#518).
- Ollama requests now honor the configured per-task `context_window` as
  `options.num_ctx` instead of silently ignoring it (#620). Invalid configured
  limits fail before the request; an unset limit preserves the server/model
  default. No prompt data is shortened or automatic context size inferred.
- `bmll -v validate` crashed after "Configuration is valid." (#589).
- A re-added document's chunks lost their search vectors; opening a store now
  removes the orphaned vectors earlier versions left behind (#592).

### Security

- **Credentials are kept out of error text (#330).** URL query strings and
  passwords, bearer and API-key headers (Elsevier's included) and `sk-` keys are
  redacted from every error a reader sees: the review, interrogation, quality
  filter, benchmarks, PDF and full-text discovery, and OpenAthens (#743). The
  full text stays in the log.
- Dependency updates for published advisories: fastembed 0.9.1 and pillow 13.0.0
  (#677), pyjwt, urllib3, fsspec, mcp, certifi and filelock.

### Apps

#### iOS / macOS 1.9.0

Since the App Store's 1.6 (1.7 and 1.8 did not reach the store; 1.8.0 shipped
as a macOS beta DMG).

- **Retraction checking (#650, #652).** As on the desktop: retracted papers
  left out, counted, badged and reported; concerns carried; saved sessions show
  when they were checked and offer *Check again*, which can be cancelled and
  runs in one window at a time (#707, #712).
- **Taking a fact check further (#611, #458).** *Find More Evidence* for the
  same claim, repeated smart search, *Fetch Full Text for Top Papers* (scored 4
  or 5), Retry Full Text, and uploading your own full text.
- **More full-text sources** (PMC's open-data bucket, every Unpaywall PDF,
  OpenAlex; CORE and Elsevier with your key), and another article's PDF is
  refused, also when it was already cached (#559, #562).
- **Cancel works** on every run and records no failure (#469).
- The Mac app is sandboxed, and the app carries a privacy manifest (#676,
  #679).
- Fixed: every second report crashed on iOS 18 / macOS 15 (#722); macOS
  *Get More Evidence* did nothing (#608); a transparency
  failure showed a successful run as failed (#460); studies added by
  *Get More Evidence* went unrated (#463); a Keychain key that could not be read
  was treated as no key (#678); PubMed titles lost the text around italics
  (#397); references lost their punctuation (#405); a source outage became a
  permanent transparency finding (#410); an unreadable relevance score is a
  parse failure, never a score (#567).
- Also fixed as on the desktop: an Unpaywall landing page saved as the PDF,
  and an Unpaywall PDF that could not be downloaded read as no open-access
  copy (#465, #482); a preprint's steady HTTP 500 is asked once (#455); a
  padded PMID is normalised (#565); Europe PMC's own open-access PDFs are used
  (#569); a trial is recognised only by whole words in its title (#410).

#### Android 1.9.0

Since 1.6.0.

- **Retraction checking (#655, #661),** as on the desktop and the Apple apps.
- **Taking a fact check further (#616):** *Find More Evidence*, repeated smart
  search, full text for top papers, Retry Full Text and uploads.
- **More full-text sources,** as on iOS/macOS, and another article's PDF is
  refused (#559, #562).
- **Cancel stops a running fact check,** at once, even mid-download (#664,
  #666).
- Fixed: an unreadable relevance score was read as 3, which made the paper
  relevant (#567); a link-only record offered *Get Full Text* (#479); a source
  outage became a permanent transparency finding (#410); references lost their
  punctuation (#405).
- Also fixed as on the desktop and the Apple apps: #465, #482, #455, #565,
  #569 and #410's whole-word trial test.
- The release build works again (R8, #555) and targets Android 16 (API 36), as
  Google Play requires; it ships as an AAB on Google Play.

## [0.5.0] - 2026-09-24

### Added

- **Polite request pacing.** A host-keyed, thread-safe rate limiter
  (`rate_limit.py`) mounted on each `requests.Session` (`polite_session.py`)
  now paces PubMed, Europe PMC and the PDF/full-text discovery clients,
  honours `Retry-After` in full and shares one retry budget. Loopback hosts
  are never paced.
- A re-runnable structural survey of real JATS articles, reporting the
  journal mix it was drawn from.
- **iOS/macOS/Android: transparency ratings explained.** Reports name every
  study rated high transparency risk and why: the rules that applied, the
  score's terms, other concerns and caveats. Android gains the full
  transparency analysis (funding, COI, trial registration, data
  availability), risk badges and report sections.
- **iOS/macOS/Android:** a downloaded PDF contributes its text to the
  analysis; an abstract-only deposit is not treated as an article.

### Changed

- The canonical funder classifier runs on the shared parity corpus; FDA, VA,
  AHRQ and PCORI funding is tiered as government, and NONPROFIT survives the
  trial-sponsor upgrade.
- **Apps:** a rating made without the full text is labelled "Limited
  certainty"; one resting only on unsearched text is shown as "Unassessed".
  A missing trial registration is reported only when ClinicalTrials.gov
  answered. The transparency analyzer version is now 6 (Python 2.1), so
  stored results are re-analysed.

### Fixed

- **Funders named by brand are industry.** "Pfizer" or "The Pfizer company"
  with no legal suffix was classified as not industry on every platform, so
  industry funding went undetected. A brand layer, shared through
  `sponsor_patterns.json`, recognises the curated known-funder companies by
  name, while their charitable foundations stay non-industry. The labelled
  funder corpus was re-audited (five commercial entities relabelled
  industry, five undecidable names made ambiguous); on it, precision rises
  from 0.909 to 0.958 and recall from 0.333 to 0.657.
- **iOS/macOS: conflict-of-interest and data statements missed.** The Swift
  JATS parser dropped the heading of an unsectioned `<ack>`/`<notes>`
  ("Competing interests", "Data availability"), so the heading-based
  extractors found nothing and studies were rated high risk for a missing
  COI statement they had. The Swift and Android extractors also captured the
  word "Statement" from "Data Availability Statement" headings as the
  statement itself. On 220 surveyed PMC articles, usable COI statements rose
  from 150 to 182 and usable data statements from 43 to 179.
- **iOS/macOS: funders never checked for PubMed results.** The Swift PubMed
  parser never read a record's DOI or PMC ID, so CrossRef was never asked
  for the funders of documents found through a PubMed search.

- **A failure is not an empty result.** Across search, scoring, quality and
  transparency analysis, benchmarks and the Research Questions tab, a source
  that could not be reached, a failed analysis, or an unparsed heading or COI
  statement is reported as such, never as a finding of absence.
- One undecodable stored transparency row no longer fails a whole batch
  read; it is shown as not assessed for that document alone.
- Cancelling a run, a worker or a benchmark ends it and says what was done.
- A failed model list is reported as an error, not shown as an empty or
  stale list.
- Security: the NCBI API key is sent to NCBI only, redirects are refused,
  credential files are written owner-only, and four CodeQL alerts are closed.
- **iOS/macOS/Android:** a failed literature source is reported, not shown
  as empty; Swift PubMed searches report every match and page on; current
  Claude model pricing; an unreadable stored analysis is named in reports.

## [0.4.1] - 2026-08-20

### Added

- `scripts/set_version.py` now updates the `**Current version:**` line in
  `CLAUDE.md` and promotes the `CHANGELOG.md` `[Unreleased]` section into a
  dated release section, rewriting the compare links. Pass `--skip-changelog`
  to bump versions without touching the changelog.
- Test coverage for `scripts/set_version.py` (`tests/test_set_version.py`).

### Fixed

- **iOS/macOS/Android: DeepSeek model list stopped syncing.** DeepSeek retired
  the `deepseek-chat` / `deepseek-reasoner` IDs in July 2026 in favour of
  `deepseek-v4-flash` / `deepseek-v4-pro`; all three apps whitelisted the old
  IDs exactly, so every model the API returned was filtered out and the picker
  silently fell back to two retired models. The filter now excludes non-chat
  families instead of whitelisting IDs, fallback models and pricing cover V4,
  and a successful fetch replaces a stored model the provider no longer offers
  (hand-typed names for Ollama and custom endpoints are left alone).
- **iOS/macOS/Android: DeepSeek V4 no longer reasons on every call.** V4 replaced
  the V3 chat/reasoner split with a `thinking` parameter that defaults to
  *enabled*, so scoring and citation calls spent output tokens on chain-of-thought
  and had their `temperature` silently ignored. All three apps now send
  `{"thinking": {"type": "disabled"}}` to DeepSeek, and the iOS/macOS connection
  test sends the same options as a real call.
- **iOS/macOS/Android: model fetch failures are no longer silent.**
  `ModelFetchService` propagates errors instead of substituting hardcoded models,
  so Settings shows the real reason (including the HTTP status) rather than a
  generic notice. macOS previously captured that reason and never displayed it,
  and Android swallowed the failure entirely and reported it as a successful
  fetch; both now surface it. A rejected API key (HTTP 401/403) says so instead of
  reading like a server error.
- **Android: a retired model is now actually replaced.** Nothing triggered a model
  fetch when the settings screen opened, so an existing install kept sending a
  model ID the provider had retired until the user happened to switch provider
  away and back.
- **Android: a valid model selection is no longer overwritten when offline.**
  Because a failed fetch returned the hardcoded catalogue, the selection-healing
  logic treated it as the provider's live line-up and could rewrite a model the
  user had deliberately chosen.
- **iOS/macOS: the model picker no longer shows a different model from the one
  being sent.** The picker resolved the selection for display without storing it,
  so after a failed fetch it could show a healthy model while a retired ID sat in
  settings. A stored model the provider no longer lists is now shown explicitly.
- **Cost estimates no longer depend on dictionary ordering.** `CostCalculator`
  matched model IDs by iterating an unordered dictionary, and several keys match
  the same ID, so the rate quoted for a model could vary between runs - threefold
  for Claude Opus 4.5, twelvefold for GPT-5.2 Pro. The most specific key now wins.
- **macOS: the Custom provider no longer shows two model-name fields.**

### Changed

- **CI runs the Swift and Android suites** (`swift-tests.yml`,
  `android-tests.yml`), completing #129. All three platforms of the
  cross-platform parity guard are now enforced on pull requests.

## [0.4.0] - 2026-07-19

### Added

- **MCP server** (`bmlibrarian-lite-mcp`) exposing BMLibrarian Lite as an expert
  medical fact-checker to any MCP client, with progress notifications during
  `fact_check_claim`.
- **Parallel scoring and citation extraction** against cloud APIs, on desktop,
  iOS/macOS, and Android.
- **Europe PMC PDF** added to the full-text discovery fallback chain on all
  platforms, ahead of the Unpaywall and DOI fallbacks.
- **Study transparency analysis** extended across platforms: multi-pass
  conflict-of-interest analysis, full-text support, and effective-refusal
  detection. iOS/macOS gained a transparency detail view, risk badge, and
  summary section; Android gained a byte-parity data-availability classifier
  (`DataAvailabilityAnalyzer`, `DataRepositoryPatterns`, `RegexHelper`).
- **Cross-platform transparency parity guard** pinning Python, Swift, and Kotlin
  to a shared contract, with drift diagnostics.
- **Android smart search** with alternative query generation.

### Changed

- The standalone macOS app is retired in favor of the multiplatform Xcode
  project; Xcode Cloud archiving is fixed and guarded by CI.
- Combined ("Both") search mode reports its total as an explicit lower bound
  rather than an exact count, and drops abstract-less articles.
- `RegexHelper` is Unicode-aware and caches compiled patterns.

### Fixed

- Scoring: a missing `"score"` key is treated as a parse failure instead of
  silently scoring 1.
- PDF: sniffed bytes are preserved, so downloaded PDFs are no longer corrupted.
- Quality: true median sample size for even-sized sets; study types matched by
  evidence priority rather than dict order.
- LLM: thinking tags stripped from reasoning-model output; the actual quality
  model is reported.
- Storage: helpful error when Python lacks SQLite extension support; new
  question-document links counted via `cursor.rowcount`.
- Errors: status-code-less `APIError` classified by message, not as a connection
  failure.
- Transparency open-data precision: negation scope bounded, `no` / `neither…nor`
  negated affirmations caught, short repository tokens word-anchored, and
  refusal signals now override a co-occurring repository mention.
- Android: `EuropePmcPdf` branch handled in view models; missing
  `UI_CARD_CORNER_RADIUS` constant restored; PubMed XML parsing made
  unit-testable.

### Security

- Dependency updates including cryptography 48.0.1, urllib3 2.7.0,
  python-multipart 0.0.31, starlette 1.3.1, pyjwt 2.13.0, idna 3.15,
  pillow 12.2.0, and mcp 1.28.1.

## [0.3.0] - 2026-02-10

Cross-platform expansion release. Full detail in
[RELEASE_NOTES_0.3.0.md](RELEASE_NOTES_0.3.0.md).

### Added

- **Native iOS and macOS apps** (SwiftUI, SwiftData, iCloud sync, NLEmbedding
  on-device scoring, parallel scoring with checkpointing) and a **native Android
  app** (Kotlin/Compose, Room, Hilt).
- **BioMedLit** shared Swift package: JATS parsing, Europe PMC/PubMed/full-text
  services, transparency analysis, and sync engine.
- **Study Transparency Analyzer**: funding, conflict-of-interest, data
  availability, and trial-compliance analyzers with CrossRef and
  ClinicalTrials.gov integration; risk badges on document cards.
- **Risk warnings in reports**, configurable per transparency dimension.
- **Europe PMC** as an alternative search provider, with cursor pagination and
  cross-provider deduplication (PMID/DOI/PMC/title).
- Full-text discovery and viewing: Europe PMC XML, Unpaywall PDFs, JATS →
  HTML/Markdown rendering, and manual upload for paywalled documents.
- Smart search mode using HyDE (Hypothetical Document Embeddings).

### Changed

- **License changed from GPL-3.0 to AGPL-3.0.**
- Searches go through a provider-agnostic `StructuredQuery` intermediate format.
- Reports gained clickable citations grouped by document, plus disclaimer and
  model-info footnotes.

### Fixed

- PubMed and JATS XML parsers no longer lose text around embedded formatting and
  inline elements.
- Year no longer rendered with a thousands separator (`2,022`).
- SwiftData enum persistence, resumed-session pagination cursors, and Europe PMC
  `hitCount` parsed as `Int`.

## [0.2.0] - 2025-12-23

Benchmarking and storage release. Full detail in
[RELEASE_NOTES_0.2.0.md](RELEASE_NOTES_0.2.0.md).

### Added

- **Multi-model benchmarking** for relevance scoring and quality assessment,
  with agreement matrices, score distributions, cost/latency tracking, and
  CSV/JSON export.
- **Research Questions tab**: manage past questions, re-run searches with
  incremental pagination, and re-classify/re-score/delete via context menu.
- `question_documents` pivot table for document-question tracking.
- Report versioning with a methodology metadata section.
- `scripts/set_version.py` for release version management.

### Changed

- **Replaced ChromaDB with sqlite-vec**, unifying metadata and embeddings in a
  single SQLite database.
- Benchmark results render in main-window tabs rather than modal dialogs.
- Scores are reused across benchmark runs of the same question.

### Removed

- ChromaDB dependency. Existing ChromaDB data is unused and can be deleted;
  documents are re-indexed on first launch.

## [0.1.1] - 2025-12-18

First published release.

### Added

- PyPI packaging with `bmll` / `bmlibrarian-lite` CLI entry points and a macOS
  DMG build.
- Audit Trail tab with collapsible document cards and LLM rationale display.
- Europe PMC full-text XML retrieval and caching.
- Task-based model configuration with a dynamic model selector and a provider
  base class for LLM backends.
- PDF discovery and download.

### Changed

- License set to GPL-3.0.

### Fixed

- `QThread` destroyed-while-running crash, resolved by deferring cleanup with
  `QTimer`.
- Ollama model listing using object attributes rather than dict access.

[Unreleased]: https://github.com/hherb/bmlibrarian_lite/compare/0.6.0...HEAD
[0.6.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.4.1...0.5.0
[0.4.1]: https://github.com/hherb/bmlibrarian_lite/compare/0.4.0...0.4.1
[0.4.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/hherb/bmlibrarian_lite/releases/tag/0.1.1
