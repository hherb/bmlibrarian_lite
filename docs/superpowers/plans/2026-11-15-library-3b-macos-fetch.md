# Shared paper library, step 3b: MedicalFactChecker's fetch through the library (macOS) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With a library set (step 3a), the macOS app's full-text fetch looks
in the library first by identifier, and saves what it downloads there: PDFs,
and from now on the JATS XML it converts. `Document` records each library
file by digest and kind. A source fetched while the library cannot be reached
stays in the PDF cache, marked *waiting for the library*, and the full-text
view says so. Without a library, nothing changes.

**Architecture:** BioMedLit's `FullTextService` (shared by iOS and macOS)
gains an optional `library: (any FullTextLibrary)?`, nil by default. The
protocol is cross-platform; its one implementation, `LibrarySource`
(`Library/`, macOS only), wraps 3a's `LibraryAccess` and this installation.
It reads the library **by bmlib's rules through bmlib-ffi** (bmlib #784, PR
#785): `libraryIds`, `LibraryScan.newestSource`, `PaperLibrary.read`,
`parseJats` + `paperIdsContradiction`, `listsUse` + `recordUse`, `save`. No
selection rule is re-implemented in Swift (design §6, approach B rejected).

**Spec:** StudyAnalyzer's
`docs/superpowers/specs/2026-11-13-shared-paper-library-design.md`: §4.3
(save, `find_digest` first), §4.4 (reading; a library file goes through the
app's intake checks; refer by digest and kind), §4.5 (which library file ends
a lookup), §4.6 (unreachable), §5.3, §8 step 3. bmlib's
`docs/manual/library.md` and `docs/DECISIONS.md` (*FullTextService on a
library*) are the reference behaviour.

## Global Constraints

- **Without a library, behaviour is unchanged.** Every existing
  `FullTextService` test passes untouched; `library` defaults to nil.
- **§4.5, as bmlib's service does it** (MedicalFactChecker's chain has no PDF
  beside JATS, so only these apply):
  1. The library's JATS for the paper, when usable, ends the lookup: no
     request is made. *Usable* = it reads (digest checked), parses, has a body,
     and its own identifiers (`parseJats` → `libraryIds`) do not contradict
     the request's (`paperIdsContradiction`). A contradiction is a
     `libraryFailure` and that lookup keeps nothing in the library (bmlib's
     *as built* for 1b); unparseable or body-less is a warning and the chain
     runs.
  2. Otherwise the chain's JATS tiers run; a JATS served and rendered is
     saved (`kind: .jats`, origin the tier's display name).
  3. Before the first PDF tier, the library's PDF (if any) is used in place
     of a download, after the PDF title check (§4.4: a record is a claim, not
     proof). A PDF the check refuses is not served and is reported.
  4. A PDF the chain admits into the cache is saved; once the library holds
     it (the save returned), the cache copy is removed and the result's
     `localPDFPath` is the library file. The cache copy is never removed
     before that.
- **An unreachable or read-only library never stops a lookup** (bmlib's
  rule): log at warning, set `libraryFailure` on the result, keep the source
  where it is today (the PDF cache), and serve it.
- **A library JATS that cannot be served because its bytes fail the digest**
  is reported (`libraryFailure` names the file), never passed over for an
  older one (bmlib's `newest_source` rule).
- **The JATS kept while the library cannot be reached** waits as a file in
  the PDF cache directory, `<cacheKey>-<sha12>.xml` (MedicalFactChecker keeps
  no JATS today; §4.6 says a source waits in its PDF cache). Moving waiting
  files in when the folder returns is step 3c's (it is §4.7's move); 3b only
  marks them.
- **Refer by digest and kind, never by path** (§4.4). `Document` stores the
  digest and kind; a stored library path is only a hint, re-resolved through
  `findDigest` when the file is opened and the hint is gone.
- Every `PaperLibrary` / `LibraryScan` call does disk I/O on the calling
  thread: `FullTextService` is an actor off the main thread; app call sites
  stay off the main actor.
- Every FFI call keeps a catch-all `catch` (a Rust panic is a plain `Error`).
  `LibraryError`'s text is bmlib's.
- No magic strings: origins, file suffixes and notes in `BioMedLitConstants`.
- `#if os(macOS)` for everything touching `LibraryAccess`; iOS keeps
  `library: nil`.

## Out of scope

- **3c:** moving waiting sources and the PDF cache in (§4.7), the switch.
- **3d:** the manual clear.
- Resolving another device's digest when its library lacks the file is just
  "not in the library": the fetch runs as today.

## Review Focus

1. **A library JATS of another paper** (another app saved a wrong JATS): not
   served, `libraryFailure` names both values, the chain runs, nothing is
   kept in the library for that lookup. Test: `testForeignLibraryJATSIsNotServed`.
2. **A tampered library file**: `libraryFailure` contains "digest", the
   chain runs. Test: `testTamperedLibraryJATSIsReported`.
3. **A library PDF of another article**: the title check refuses it, the
   chain downloads. Test: `testLibraryPDFFailingTitleCheckIsNotServed`.
4. **The library unplugged between launch and fetch**: the PDF stays in the
   cache, `libraryFailure` set, `Document.fullTextLibraryWaiting` set, the
   view says so. Test: `testUnreachableLibraryKeepsTheCacheCopy`.
5. **The cache copy is removed only after the save returned.** Test:
   `testSavedPDFLeavesNoCacheCopy` and its failing-save twin.

---

### Task 1: Re-pin BmlibFFI past bmlib #785; ledger rows

As 3a's Task 1 (same files, same workflow and checks), to bmlib #785's merge
commit (until it merges, its head, re-pinned to the merge before this PR
leaves draft). Ledger: rows `bmlib#784` and `bmlib#780` (#781), `swift`
`owed` → `done` for the library rows this step adopts, `python`/`android`
unchanged. Gates as 3a's Step 6. Commit:
`build(ffi): re-pin BmlibFFI past bmlib #785 (#784)`.

### Task 2: `FullTextLibrary` and `LibrarySource` (BioMedLit)

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/FullTextLibrary.swift`
  (protocol and value types; cross-platform)
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/LibrarySource.swift`
  (`#if os(macOS)`)
- Modify: `Utilities/Constants.swift` (origins, `.xml` waiting suffix)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/LibrarySourceTests.swift`
  (`#if os(macOS)`; temp libraries via `LibrarySetup.choose`)

**Interfaces:**
- `public struct LibraryFileReference: Sendable, Equatable, Codable { sha256: String; kind: String }`
  (`kind` is bmlib's name: `pdf`, `jats`, …).
- `public struct LibraryPaper: Sendable { pmid, doi, pmcId, title, year, firstAuthor }`
  (plain fields; mapped to `PaperInfo` inside).
- `public enum LibraryJATSLookup: Sendable { case none; case usable(Data, LibraryFileReference); case unusable(note: String); case wrongPaper(String); case failed(String) }`
- `public struct LibraryHeldPDF: Sendable { path: String; file: LibraryFileReference }`
- `public protocol FullTextLibrary: Sendable`:
  - `func jats(for paper: LibraryPaper) -> LibraryJATSLookup` (one scan)
  - `func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure>`
    (read, digest checked; path is `root/papers/<folder>/<name>`)
  - `func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String) -> Result<(LibraryFileReference, path: String), LibraryLookupFailure>`
  - `func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure?`
    (`listsUse` first; `recordUse` only when not listed)
  - `func path(of file: LibraryFileReference) -> String?` (`findDigest`)
- `public struct LibraryLookupFailure: Error, Sendable, CustomStringConvertible`
  worded as bmlib's `failure`: "library, paper pmid=… doi=…[ file F/N]: <bmlib's text>".
- `public final class LibrarySource: FullTextLibrary` (macOS): `init(access: LibraryAccess, installation: Installation)`.
  Request ids go through `libraryIds`; with none left, every call is
  `.none` / `nil` and touches nothing (bmlib's "identifier-only request skips
  the library").

- [ ] **Step 1: failing tests**: `testJATSKeptThenFoundIsUsable`,
  `testForeignLibraryJATSIsWrongPaper` (save a JATS for PMID 1 under another
  installation by hand-planting, request PMID 2 sharing a DOI),
  `testTamperedLibraryJATSIsFailedNamingDigest`,
  `testBodylessJATSIsUnusable`, `testNoIdentifiersTouchesNothing`,
  `testNoteUseWritesOnce` (record bytes unchanged on the second call),
  `testKeepSameBytesTwiceGivesOneFile`, `testPathByDigest`,
  `testRemovedRootIsFailure`.
- [ ] **Step 2:** `swift test --filter LibrarySourceTests`: FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** PASS, then full BioMedLit `swift test`. Commit
  `feat(library): the fetch's library source, by bmlib's rules`.

### Task 3: `FullTextService` reads and saves through the library

**Files:**
- Modify: `Services/FullTextService.swift`, `Models/FullTextModels.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceLibraryTests.swift`
  (`StubURLProtocol` as `FullTextServiceExtractionTests`; a fake
  `FullTextLibrary` for the decision tests, a real `LibrarySource` on macOS
  for two end-to-end ones)

**Interfaces:**
- `init(…, library: (any FullTextLibrary)? = nil)` (last parameter).
- `FullTextSource.library = "library"` ("Paper library");
  `FullTextContent.libraryJATS(html:markdown:)` and
  `.libraryPDF(localPath:)`; `FullTextResult` gains
  `libraryFile: LibraryFileReference?` (the file the text came from or was
  saved to) and `libraryFailure: String?`; its `init` invariants extended
  (a library content case has a `libraryFile`).

Flow (Global Constraints' §4.5 list):
- After `cacheKey` (before identifier resolution): `library.jats(for:)`.
  `.usable` → `renderEuropePMCXML` → note use → return `.libraryJATS` (an
  abstract-only one is held back like Europe PMC's, not returned).
  `.wrongPaper` → `libraryFailure`, and no `keep` for the rest of the call.
  `.failed` → `libraryFailure`, library off for the call. `.unusable` → warn.
- Tier 1 / 1a `.served(xml)` rendered → `keep(xml.data, kind: "jats", …)`.
  Failure → `libraryFailure`, and the bytes are written to the cache's
  waiting `.xml` name.
- Before Tier 2: `library.pdf(for:)` → title check (`refusesAsAnotherArticle`
  on the library path) → `extractText(fromCachedPDF:)` → `.libraryPDF`, note
  use. Refused → `libraryFailure` ("the library's PDF F/N is another
  article's"), chain runs.
- `admit` → `.admitted(path)`: read the file, `keep(…, kind: "pdf", origin:
  tier display name)`; success → delete the cache file, `localPDFPath` = the
  library path, `libraryFile` set; failure → keep the cache file,
  `libraryFailure`.

- [ ] **Step 1: failing tests** (Review Focus 1–5, plus
  `testLibraryJATSEndsTheLookupWithNoRequest` (`StubURLProtocol.requestedURLs`
  empty), `testServedJATSIsKept`, `testLibraryPDFReplacesTheDownload`,
  `testNoLibraryIsUnchanged`).
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS, full suite.
  Commit `feat(fulltext): look in the library first and keep what is fetched (design §4.5)`.

### Task 4: The app: `Document`, the adapter, the service's library

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift`: optional
  `fullTextLibrarySHA256: String?`, `fullTextLibraryKind: String?`,
  `fullTextLibraryWaiting: String?` (why, or nil). Optional, so no schema
  version (as `retractionCheckJSON`); written only by `applyFullTextResult`,
  cleared with the rest in `clearFullTextCache` / `markFullTextUnavailable`.
- Modify: `Models/FullTextSource.swift` (`AppFullTextSource.library`),
  `Utilities/BioMedLitAdapters.swift` (map the new cases and fields; `create`
  takes `library: (any FullTextLibrary)?`), each call site (the six in the
  map) passes `LibraryController.library()` on macOS, nil on iOS.
- Modify: `macOS/App/LibraryController.swift`: `static func library() -> (any FullTextLibrary)?`
  (a `LibrarySource` over the held access and this installation, or nil).
- `localPDFFilePath`: a stored library path that no longer exists is
  re-resolved through `path(of:)` when a digest is stored (macOS).
- Test: `Tests/StoreMigrationTests.swift` (nil for an earlier build's
  document), `Tests/DocumentLibraryFieldsTests.swift` (apply/clear).

- [ ] Steps: failing tests → implement → both `swift test` suites and the
  macOS `xcodebuild` → commit `feat(mac): fetch through the paper library`.

### Task 5: The waiting note and the unreachable banner (§4.6)

- The macOS full-text view shows, while `fullTextLibraryWaiting` is set:
  "Kept in this app until the paper library can be reached: <why>." and,
  when the library is unreachable and a library file is needed but gone:
  "The paper library cannot be reached: <reason>."
- `LibrarySession` re-checks on `NSApplication.didBecomeActiveNotification`
  (§4.6), guarded against a concurrent choose (#792 item 4).
- Commit `feat(mac): say when a source waits for the library`.

### Task 6: #792, 3a's review minors

Items 1–7 of hherb/bmlibrarian_lite#792, each with its test where it has
behaviour (1: bookmark before the marker; 2: a stale bookmark not renewed is
a note shown on the setting; 3: "Reaching the library…"; 4: the guard (Task
5); 5: `unicodeScalars.count`, machine name off the main thread; 6: the
resume-into-Trash test; 7: doc comments). Commit
`fix(library): 3a's review minors (#792)`.

### Task 7: Docs, hand-over, PR

- `CLAUDE.md` (Library/: FullTextLibrary, LibrarySource), `HELP.md`,
  `PRIVACY.md` (JATS now kept in the library), `HANDOVER.md` (under 500
  lines), the ledger.
- Every gate; PR against lite's main, "merge #787 first", `Part of #788`,
  `Closes #792`.
- StudyAnalyzer's HANDOVER and ROADMAP: 3b's PR.
