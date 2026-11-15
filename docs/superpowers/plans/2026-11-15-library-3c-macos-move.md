# Shared paper library 3c (macOS): the move and the switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** MedicalFactChecker (macOS) moves the PDFs and waiting JATS its
documents use into the shared paper library, settles waiting sources by
itself once the library is reached, and carries its files across a switch of
folder (or back into the app for *no library*).

**Architecture:** A pure engine in BioMedLit (`LibraryMove`) copies a file
into a library, reads it back digest checked through bmlib, and only then
drops the app's copy. The app side (`LibraryMover`, macOS) turns SwiftData
`Document`s into the engine's items and writes the outcomes back on the main
actor. `LibrarySession` gains two hooks: one run while both the old and new
access are held (the switch), one run each time a library is held (the
waiting settle).

**Tech Stack:** Swift 6, SwiftUI, SwiftData, BmlibFFI (bmlib-ffi at
`747e7a80`, unchanged), XCTest.

**Spec:** StudyAnalyzer's
`docs/superpowers/specs/2026-11-13-shared-paper-library-design.md` §4.6, §4.7,
§5.3. Decided with the maintainer on 2026-11-15:
1. The move covers the cached PDFs and waiting JATS that a `Document` uses
   (its identifiers name the paper). Cache entries no document uses stay
   cache, and *Clear Cache* still removes them.
2. Sources waiting for the library (`fullTextLibraryWaiting`) move in by
   themselves whenever the library is held (launch, re-check, choice), as
   StudyAnalyzer's settle does. The rest of the cache moves only by the
   user's choice.
3. *No library* with *copy back*: PDFs and JATS both go back into the PDF
   cache (a JATS as `<cacheKey>-<sha12>.xml`, as 3b's waiting files).
4. One PR.

## Global Constraints

- Every copy is checked before the app's copy goes: saved, read back through
  bmlib (`PaperLibrary.read`, which checks the digest), then removed. A
  failure leaves the app's copy and names the paper (§4.7).
- The old folder is never changed by a switch (§4.7). Nothing is deleted from
  any library.
- Offers are unticked checkboxes, as StudyAnalyzer's (`bring = false`).
- A document whose file was not carried across a switch says so (§4.7
  "reads as unavailable, naming it"), through its stored
  `fullTextLibraryNote`.
- Every library and disk call runs off the main actor; `Document`s change
  only on it.
- Every FFI call keeps a catch-all `catch`; `LibraryError`'s text is bmlib's.
- Copy, file suffixes and counts live in `BioMedLitConstants`; no magic
  strings.
- `#if os(macOS)` for anything touching `LibraryAccess`; iOS unchanged.
- Tests never write the real PDF cache: the engine takes its directory.
- Every outward function documented and tested (CLAUDE.md).

## Review Focus

1. **One cached PDF used by several documents** (the same paper in two fact
   checks): moved once, every document repointed, the cache copy removed
   once. Test: `testSharedCacheFileMovesOnceForEveryDocument` (Task 3).
2. **The library goes away mid-move** (drive unplugged): every item after the
   failure fails with bmlib's reason, every app copy stays, and the failed
   documents are left waiting, not lost. Test:
   `testUnreachableLibraryLeavesEveryAppCopy` (Task 1).
3. **A document's cache path that no longer exists** (cache cleared by hand):
   not offered, not counted, no failure. Test:
   `testMissingCacheFileIsNotAnItem` (Task 3).
4. **A switch while a fetch writes**: the old access stays held until the
   carry ends. Test: `testCarryRunsWhileBothAccessesHeld` (Task 2).
5. **Stop using with copy back while the library is unreachable**: the offer
   is not shown (as StudyAnalyzer: `unreachable === null`), documents get the
   *no longer used* note. Test: `testStopUsingNotesUncopiedDocuments`
   (Task 3).

---

### Task 1: The engine, `LibraryMove` (BioMedLit)

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Library/LibraryMove.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Library/FullTextLibrary.swift`
  (protocol gains `read`), `LibrarySource.swift`, `UnreachableLibrary.swift`,
  `Utilities/Constants.swift`
- Modify: `Tests/BioMedLitTests/FullTextServiceLibraryTests.swift`
  (`FakeLibrary.read`)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/LibraryMoveTests.swift`

**Interfaces:**
- Produces:
  - `FullTextLibrary.read(_ file: LibraryFileReference) -> Result<Data, LibraryLookupFailure>`:
    `findDigest` then `PaperLibrary.read` (digest checked). Not held is a
    failure with `libraryDigestNotHeldReason`, `waits: false`.
  - `public struct LibraryMoveItem: Sendable { paper: LibraryPaper; path: String; kind: String; origin: String }`
  - `public enum LibraryMoveOutcome: Sendable, Equatable { case moved(LibraryKept); case failed(String) }`
  - `public enum LibraryMove`:
    - `static func moveIn(_ items: [LibraryMoveItem], into library: any FullTextLibrary) -> [LibraryMoveOutcome]`
      (same order as `items`): read the file, `keep`, `read` back and compare
      bytes, then remove `path` (a failed remove is logged, still `.moved`).
      `keep` answering nil fails with `libraryMoveNoIdentifierReason`.
    - `static func copy(_ files: [(file: LibraryFileReference, paper: LibraryPaper)], from old: any FullTextLibrary, to new: any FullTextLibrary) -> [LibraryMoveOutcome]`:
      read from `old`, `keep` in `new`, read back. Nothing removed.
    - `static func copyBack(_ files: [(file: LibraryFileReference, key: ArticleCacheKey)], from library: any FullTextLibrary, into directory: URL) -> [Result<String, LibraryLookupFailure>]`:
      read, write atomically as `<key.filenameComponent>-<sha12>.pdf` or
      `.xml` by kind; returns the path.
  - `FullTextService.writeWaitingJATS` builds its name with the same helper,
    `static func appCopyName(key: ArticleCacheKey, sha256: String, kind: String) -> String`
    (in `LibraryMove`), so the two names never drift.
  - Constants: `libraryMoveNoIdentifierReason`, `libraryMoveReadBackMismatchReason`,
    `libraryAppCopyPDFSuffix` (`.pdf`).

- [ ] **Step 1: Write the failing tests** in `LibraryMoveTests` on a real
  library (`LibrarySetup.choose` in a temp folder, as `LibrarySourceTests`)
  and `FakeLibrary` for faults:
  - `testMovedFileIsInTheLibraryAndTheAppCopyIsGone`: outcome `.moved`,
    `kept.path` exists with the same bytes, `item.path` gone.
  - `testRefusedSaveLeavesTheAppCopy`: `keepAnswer = .failure(…)`, outcome
    `.failed(description)`, file still there.
  - `testReadBackMismatchLeavesTheAppCopy`: a fake whose `read` returns other
    bytes → `.failed` containing `libraryMoveReadBackMismatchReason`.
  - `testUnreadableSourceFails`: a path that does not exist → `.failed`.
  - `testNoIdentifierFails`: `LibraryPaper(pmid: nil, doi: nil, pmcId: nil)`
    → `.failed(libraryMoveNoIdentifierReason)`, file kept.
  - `testUnreachableLibraryLeavesEveryAppCopy`: `UnreachableLibrary` with
    three items → three `.failed`, three files kept.
  - `testCopyLeavesTheOldLibraryUnchanged`: two real libraries; the file is
    in both after, the old scan unchanged.
  - `testCopyBackWritesTheAppName`: PDF → `<key>-<first 12 hex>.pdf` in the
    given directory, JATS → `.xml`, bytes equal.
- [ ] **Step 2:** `swift test --package-path Packages/BioMedLit --filter LibraryMoveTests`: FAIL (no `LibraryMove`).
- [ ] **Step 3:** Implement as the Interfaces block says; `LibrarySource.read`
  via `access.library.scan().findDigest` and `access.library.read`;
  `UnreachableLibrary.read` fails with its reason, `waits: true`.
- [ ] **Step 4:** The filter, then the full `swift test --package-path Packages/BioMedLit`: PASS.
- [ ] **Step 5:** Commit `feat(library): move and copy files into the library, checked (3c)`.

### Task 2: `LibrarySession`'s hooks (BioMedLit)

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Library/LibrarySession.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/LibrarySessionTests.swift`

**Interfaces:**
- Produces:
  - `public var onHeld: (@MainActor (LibraryAccess) async -> Void)?`: run
    after every `hold` (launch resume, re-check resume, choice), counted in
    `running` so the buttons wait for it.
  - `public func choose(_ url: URL, carry: (@MainActor (_ old: LibraryAccess?, _ new: LibraryAccess) async -> Void)? = nil) async`:
    `carry` runs after the choice succeeded and before the old access stops.
  - `public func stopUsing(carry: (@MainActor (LibraryAccess) async -> Void)? = nil) async`:
    `carry` runs with the held access (nil carry, or none held: as today),
    then access stops and the bookmark goes. Now `async`; the Settings tab's
    call site awaits it.

- [ ] **Step 1: Failing tests**:
  - `testCarryRunsWhileBothAccessesHeld`: in `carry`, `old` and `new` are
    both non-nil and `old`'s folder still readable; after `choose` returns,
    `session.access === new`.
  - `testOnHeldRunsOnResumeAndChoice`: counts 1 after `resumeAtLaunch`
    (held), 2 after `choose`; 0 for a `.lost` resume.
  - `testStopUsingCarryRunsBeforeAccessStops`: `carry` sees the access;
    after, `state == .notChosen`, bookmark nil.
- [ ] **Step 2:** `swift test --package-path Packages/BioMedLit --filter LibrarySessionTests`: FAIL.
- [ ] **Step 3:** Implement; keep the generation rule (a resume outcome out
  of date drops, and `onHeld` is not run for it).
- [ ] **Step 4:** Full BioMedLit `swift test`: PASS.
- [ ] **Step 5:** Commit `feat(library): session hooks for the move and the switch (3c)`.

### Task 3: `LibraryMover`, documents to items and back (app, macOS)

**Files:**
- Create: `ios/MedicalFactChecker/Sources/macOS/App/LibraryMover.swift`
  (add to the macOS target with `add_macos_sources.rb`, as 3a's files)
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift` (one writer
  for a moved file, `storeMovedLibraryFile`), `LibraryController.swift`
- Test: `ios/MedicalFactChecker/Tests/LibraryMoverTests.swift`

**Interfaces:**
- Consumes: Task 1's `LibraryMove`, Task 2's hooks.
- Produces (`@MainActor enum LibraryMover`):
  - `static func moveItems(_ documents: [Document], cacheDirectory: URL, onlyWaiting: Bool) -> [(item: LibraryMoveItem, documents: [Document])]`:
    a document's local PDF inside `cacheDirectory` that exists (kind PDF,
    origin its `fullTextSource` display name), and its waiting JATS
    (`<cacheKey>-*.xml` there; kind JATS). Grouped by path, so one file is
    one item. `onlyWaiting` takes only documents with
    `fullTextLibraryWaiting != nil`. The paper is
    `FullTextService.libraryPaper(pmcId:doi:pmid:primaryKind:title:)` from the
    document's fields, as the fetch builds it.
  - `static func apply(_ outcomes: [LibraryMoveOutcome], to documents: [[Document]]) -> LibraryMoveSummary`
    (`documents[i]` are the documents of outcome `i`; the move and the
    switch's copy both use it): `.moved` → each document
    `storeMovedLibraryFile(kept)` (a PDF also repoints `fullTextPDFPath`;
    waiting and note cleared); `.failed` → "‹title›: ‹reason›" in `failed`.
  - `Document.storeAppCopy(at path: String, kind: String)`: after *copy
    back*: a PDF's path is the cache copy; the library fields are cleared.
  - `public struct LibraryMoveSummary: Equatable { moved: Int; failed: [String] }`
    (failed: "‹title›: ‹reason›").
  - `static func notCarried(_ documents: [Document], note: String)`: stores
    `note` in `fullTextLibraryNote` for documents with a library file left
    behind.
  - `LibraryController`: `pendingCount(in: ModelContext) async -> Int`,
    `usedCount(in:) -> Int`, `moveIn(context:onlyWaiting:) async -> LibraryMoveSummary`,
    and sets `session.onHeld` to the waiting settle at launch; the switch's
    carries for Task 4. `source(for: LibraryAccess) -> LibrarySource?`
    factored out of `library()`.
  - Constants: `libraryNotCarriedNote(folderName:)` ("Its file was left in
    the paper library “‹old›”; choose that folder again to read it."),
    `libraryNoLongerUsedNote` ("Its file is in a paper library this app no
    longer uses; choose that folder again to read it.").

- [ ] **Step 1: Failing tests** (in-memory `ModelContainer`, a temp cache
  directory, a real library):
  - `testSharedCacheFileMovesOnceForEveryDocument`: two documents, one path →
    one item; after `apply`, both point at `kept.path` with the digest set.
  - `testMissingCacheFileIsNotAnItem`.
  - `testPathOutsideTheCacheIsNotAnItem` (a library path already).
  - `testWaitingJATSIsAnItem`: `<key>-abc123def456.xml` present → a JATS item.
  - `testOnlyWaitingSkipsPlainCache`.
  - `testFailedMoveNamesThePaper`: summary `failed == ["‹title›: ‹reason›"]`,
    the document unchanged.
  - `testStopUsingNotesUncopiedDocuments`: `notCarried` sets the note;
    `libraryNotices(.notChosen)` shows it with the failure prefix.
- [ ] **Step 2:** `swift test --package-path ios/MedicalFactChecker --filter LibraryMoverTests`: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Both `swift test` suites and the macOS `xcodebuild … build`: PASS / `BUILD SUCCEEDED`.
- [ ] **Step 5:** Commit `feat(mac): move documents' files into the library (3c)`.

### Task 4: The Settings tab: offers, *Move into library*, the switch

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/macOS/Views/Settings/MacLibrarySettingsTab.swift`,
  `LibraryController.swift`

**Interfaces:**
- Consumes: Task 3's `LibraryController` calls and Task 2's carries.
- Behaviour (copy in `BioMedLitConstants` where shared, else the view):
  - No library set, `pendingCount > 0`: an unticked toggle *Move the N paper
    files kept in this app into it*; ticked, `choose(url, carry:)` runs
    `moveIn(onlyWaiting: false)` on the new access.
  - A library reachable: *Choose Another…* with the unticked toggle *Copy the
    N files this app uses into the new folder*: the carry copies with
    `LibraryMove.copy(old → new)` and repoints moved documents; documents not
    copied (unticked, or failed) get `libraryNotCarriedNote(old name)`.
  - *Stop Using…*'s confirmation gains the unticked *Copy the N files this
    app uses back into this app* (only while reachable): the carry runs
    `copyBack` into `FullTextService.pdfCacheDirectory`, repoints PDFs to the
    cache and clears the library fields; documents not copied get
    `libraryNoLongerUsedNote`.
  - While reachable with `pendingCount > 0`: *Move N Files Into the Library*.
  - The last change's outcome under the buttons: "N files moved into the
    paper library." / "Nothing was copied or moved." plus one line per
    failure; it goes on the next change.
  - Counts are re-read in `.task` on appear and after each change.

- [ ] **Step 1:** Implement; `xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj -scheme MedicalFactChecker -destination 'platform=macOS' build`: `BUILD SUCCEEDED`; both `swift test` suites PASS.
- [ ] **Step 2:** Commit `feat(mac): the Library setting's move and switch (3c)`.
- [ ] **Step 3: The click-through is the maintainer's** (owed, in HANDOVER):
  a sandboxed build; a few fetched papers with no library; *Choose…* with the
  move ticked (the PDFs leave `PDFCache`, appear in `papers/…`, the viewer
  still opens them); unplug the drive, fetch one (it waits), plug it back,
  switch to the app (it moves in by itself); *Choose Another…* unticked (the
  note names the old folder) and ticked (both folders hold the files);
  *Stop Using* with copy back (the PDFs are in `PDFCache` again).

### Task 5: Docs

- [ ] Lite's `HANDOVER.md` (3c landed, click-through owed, next 3d),
  `CLAUDE.md`'s `Library/` line if a type is added there, this plan's
  *As built*; commit `docs(handover): library 3c`.

## Out of scope

- 3d, the manual clear.
- HANDOVER's *Stop using*/*Choose…* mid-fetch race (a fetch's source waits
  under a wrong reason): the carry holds the old access through the copy,
  but a fetch's own `LibrarySource` still sees it stop afterwards. Lodged as
  an issue if not fixed in passing.
- Cache entries no document uses (decision 1).
