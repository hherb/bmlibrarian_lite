# Open in StudyAnalyzer (macOS full-text viewer) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Superseded in part by the review commits.** The code is the reference
> where this plan differs. The one cap became per-format caps
> (`handoffMaxPDFBytes`, `handoffMaxTextBytes`, `handoffMaxHTMLBytes`). The
> choice is now `StudyAnalyzerPaper.handoff(...)`, reached through
> `Document.studyAnalyzerPaper`. Its `handoff` is optional, so the notes
> survive when nothing is sent. Notes end with "… was sent instead.". The
> text sent is `analyzableFullText`: never an abstract-only record's text,
> and sent as `text` when it was extracted from a PDF. The PMID slot holds
> only a PubMed ID or a preprint accession. The test counts below are
> out of date.

**Goal:** An **Open in StudyAnalyzer** button in the macOS full-text viewer that hands the paper to StudyAnalyzer as a `.studyanalyzer` file.

**Architecture:** Three layers. BioMedLit's pure `StudyAnalyzerHandoff` writes the JSON. A `Document` extension in the app's shared sources picks what to send (testable under SwiftPM). A macOS-only `StudyAnalyzerSender` writes the temp file, opens it with StudyAnalyzer, cleans up, and backs the button.

**Tech Stack:** Swift, SwiftUI, SwiftData, Foundation `JSONEncoder`, Network (`NWPathMonitor`), AppKit (`NSWorkspace`), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-17-open-in-studyanalyzer-design.md`. The parent design is StudyAnalyzer's `docs/superpowers/specs/2026-11-13-shared-paper-library-design.md` §5.4, and the format is StudyAnalyzer's `docs/handoff-format.md`. Read the format doc before Task 1.

## Global Constraints

- Format `studyanalyzer-handoff`, `version` 1, `sender` `MedicalFactChecker`, extension `studyanalyzer`, bundle id `com.bmlibrarian.studyanalyzer`.
- `full_text.format` is one of `pdf`, `jats`, `html`, `markdown`, `text`. `full_text.data` is standard padded base64 with no line breaks.
- An optional field that is blank is omitted. Nothing is truncated.
- A file over 104,857,600 bytes (100 MiB) is not sent.
- No magic numbers or strings: every value above goes in `BioMedLitConstants` (`Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift`).
- Viewer only. There is no card button, no iOS code and no `studyanalyzer://` link.
- A failure is shown in the viewer, never dropped silently.
- Run the app tests with `swift test --package-path ios/MedicalFactChecker`; the macOS views are not compiled by it. Run the BioMedLit tests with `swift test --package-path Packages/BioMedLit`. Never run two Swift builds at once (they deadlock).
- New app files must be added to `MedicalFactChecker.xcodeproj` with the `xcodeproj` gem (1.27.0 is installed; see `ios/MedicalFactChecker/add_macos_sources.rb`). The project has no synchronized folders.
- Golden rules: Google-style doc comments on every type and function, and pure functions in focused files.

## Review Focus

1. **A second send before StudyAnalyzer has read the first.** The clean-up deletes earlier hand-off files, which could pull the first file away. Expected: the first paper still arrives. StudyAnalyzer copies a received file into its `handoffs` table at once. Task 3 keeps the file just written and deletes only files older than 60 seconds; the manual check sends twice quickly.
2. **StudyAnalyzer not running at the click.** Expected: it launches and shows the paper. This is covered by the manual check in Task 3 Step 6.
3. **A cached PDF that has gone from disk** (the cache was cleared, or the file moved into the library). Expected: the library's PDF or the Markdown is sent instead, with a note. Test in Task 2.
4. **A PDF over 100 MiB.** Expected: the next source is sent, with a note, rather than a file StudyAnalyzer would refuse. Tests in Tasks 1 and 2.
5. **A document with no identifier and no text** (an upload record that went wrong). Expected: the button says there is nothing to send instead of writing an empty file. Test in Task 2.

---

### Task 1: `StudyAnalyzerHandoff` in BioMedLit

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Utilities/StudyAnalyzerHandoff.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift` (a `// MARK: StudyAnalyzer hand-off` block beside the library kinds, near line 922)
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/Handoff/`, holding copies of StudyAnalyzer's `crates/studyanalyzer-core/tests/fixtures/handoff/{cases.json,ids_only.studyanalyzer,pdf.studyanalyzer,jats.studyanalyzer}` and `crates/studyanalyzer-core/tests/fixtures/{paper.pdf,article.xml}`, plus a `README.md` naming the source repo and commit (`git -C ~/src/studyanalyzer rev-parse HEAD`)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/StudyAnalyzerHandoffTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct StudyAnalyzerHandoff: Equatable, Sendable {
      public enum Format: String, Sendable { case pdf, jats, html, markdown, text }
      public struct FullText: Equatable, Sendable {
          public let format: Format; public let data: Data
          public let fileName: String?; public let source: String?
          public init(format: Format, data: Data, fileName: String? = nil, source: String? = nil)
      }
      public let pmid: String?, doi: String?, pmcid: String?, title: String?
      public let fullText: FullText?
      /// Blank or whitespace-only strings become nil (here and in FullText).
      public init(pmid: String?, doi: String?, pmcid: String?, title: String?, fullText: FullText?)
      /// True when any identifier or the full text is present.
      public var hasContent: Bool { get }
      public func encoded() throws -> Data
  }
  ```
- Constants: `BioMedLitConstants.studyAnalyzerBundleID = "com.bmlibrarian.studyanalyzer"`, `handoffFormat = "studyanalyzer-handoff"`, `handoffVersion = 1`, `handoffSender = "MedicalFactChecker"`, `handoffFileExtension = "studyanalyzer"`, `handoffMaxFileBytes = 104_857_600`.

- [ ] **Step 1: Copy the fixtures** listed above and write the README.
- [ ] **Step 2: Write the failing tests.** Locate the fixtures through `#filePath`, as `PDFTextExtractorTests` does (`Fixtures/Handoff/<name>`).
  - `testEachAcceptedFixtureIsWhatTheEncoderWrites`: for every case in `cases.json` with `"expect": "ok"`, build a `StudyAnalyzerHandoff` from the case's `pmid`, `doi`, `pmcid` and `title`, plus a `FullText(format: Format(rawValue: kind)!, data: <bytes of the file the case's "bytes" names>, fileName:, source:)` when `kind` is non-null. Then assert `NSDictionary(JSONSerialization(encoded())) == NSDictionary(JSONSerialization(<the .studyanalyzer file>))`.
  - `testBlankFieldsAreLeftOut`: a title of `"  "`, a doi of `""` and a pmid of `"1"` encode with no `title` key and an `identifiers` object of exactly `["pmid": "1"]`.
  - `testHasContent`: false for all-nil, true for a pmid alone, true for a full text alone.
  - `testTheDataIsOneUnbrokenBase64String`: 100 KB of bytes give a `data` string with no `\n` or `\r`, equal to `bytes.base64EncodedString()`.
- [ ] **Step 3: Run them.** `swift test --package-path Packages/BioMedLit --filter StudyAnalyzerHandoffTests`. Expected: FAIL to compile (`StudyAnalyzerHandoff` is not defined).
- [ ] **Step 4: Implement.** Use private `Encodable` structs with explicit `CodingKeys` (`full_text`, `file_name`) and synthesized `encodeIfPresent`, so nils are left out. Use `JSONEncoder` with its default `.base64` data strategy, which writes no line breaks.
- [ ] **Step 5: Run them.** Same command. Expected: PASS, and the whole BioMedLit suite stays green (`swift test --package-path Packages/BioMedLit`).
- [ ] **Step 6: Commit** with the message `feat(biomedlit): StudyAnalyzerHandoff writes the .studyanalyzer file, checked against StudyAnalyzer's fixtures`.

### Task 2: What a document sends

**Files:**
- Create: `ios/MedicalFactChecker/Sources/Models/Document+StudyAnalyzer.swift` (add it to the Xcode target `MedicalFactChecker` under the `Models` group with the `xcodeproj` gem)
- Test: `ios/MedicalFactChecker/Tests/DocumentStudyAnalyzerHandoffTests.swift`

**Interfaces:**
- Consumes: `StudyAnalyzerHandoff`, `BioMedLitConstants.handoffMaxFileBytes` (Task 1); `LibraryFileReference(sha256:kind:)`, `LibraryLookupFailure.description`, `BioMedLitConstants.libraryKindJATS` / `libraryKindPDF`; `Document.localPDFFilePath`, `usableDOI`, `pmcId`, `pmid`, `title`, `fullTextContent`, `fullTextHTML`, `fullTextSource`, `fullTextLibrarySHA256`, `fullTextLibraryKind`; `AppFullTextSource(rawValue:)?.displayName`.
- Produces:
  ```swift
  struct StudyAnalyzerHandoffChoice: Equatable {
      let handoff: StudyAnalyzerHandoff
      /// One sentence per source tried and passed over, in order (a read that failed, a file too large).
      let notes: [String]
  }
  extension Document {
      /// What to hand StudyAnalyzer, or nil when there is nothing to send.
      func studyAnalyzerHandoff(
          online: Bool,
          readLibrary: (LibraryFileReference) -> Result<Data, LibraryLookupFailure>,
          readFile: (String) throws -> Data
      ) -> StudyAnalyzerHandoffChoice?
  }
  ```

The choice follows the spec's "What it sends", in this order. The first match wins:

1. The library's JATS file (`fullTextLibraryKind == libraryKindJATS` and a digest) read through `readLibrary` → `.jats`.
2. `online` and the paper's text came from JATS (`fullTextSource` is `europepmc` or `pmc_open_data`, or step 1's file exists but its read failed) and it has an identifier → identifiers only.
3. `localPDFFilePath` read through `readFile`; if that fails, the library PDF (`fullTextLibraryKind == libraryKindPDF`) through `readLibrary` → `.pdf`, with `fileName` set to the path's last component when the file came from the path.
4. Non-empty `fullTextContent` as UTF-8 → `.markdown`.
5. Non-empty `fullTextHTML` as UTF-8 → `.html`.
6. Identifiers only.

A read over `handoffMaxFileBytes` counts as passed over. Each source passed over adds a note, worded for the reader, for example "The library's JATS file could not be read: <failure description>" or "The PDF is larger than StudyAnalyzer accepts (100 MiB)". `source` is `AppFullTextSource(rawValue: fullTextSource)?.displayName`. `pmid` is `pmid` when it is not blank (a `PPR` accession is kept); `doi` is `usableDOI`; `pmcid` is `pmcId`. If the result's `hasContent` is false, return nil.

- [ ] **Step 1: Write the failing tests.** Use `Document(pmid:title:abstract:)` as `DocumentLibraryFieldsTests` does, with closures that record their calls.
  - `testTheLibrarysJATSIsSentFirst`: kind jats with a digest, plus a local PDF. `readLibrary` returns `<article/>` bytes. Expect `.jats` with those bytes, no notes, and `readFile` not called.
  - `testOnlineAJATSPaperWithoutItsFileSendsIdentifiersOnly`: source `europepmc`, Markdown set, `online: true`. Expect `fullText == nil`, `pmid == "1"`.
  - `testOfflineAJATSPaperSendsItsMarkdown`: same, `online: false`. Expect `.markdown` with the Markdown's UTF-8.
  - `testAGoneLocalPDFFallsBackToTheLibrarysPDF`: `localPDFFilePath` set, `readFile` throws, kind pdf with a digest, `readLibrary` returns `%PDF-` bytes. Expect `.pdf` with those bytes and one note.
  - `testAnUnreadableLibraryJATSFallsBackWithANote`: kind jats, `readLibrary` returns `.failure(LibraryLookupFailure(description: "the folder is not reachable", waits: true))`, `online: false`, Markdown set. Expect `.markdown`, and `notes.first` contains "the folder is not reachable".
  - `testAPDFOverTheCapIsPassedOver`: `readFile` returns `handoffMaxFileBytes + 1` bytes, Markdown set. Expect `.markdown` and one note.
  - `testNothingToSendIsNil`: pmid `""`, no doi, no pmcid, no text. Expect nil.
  - `testAPreprintAccessionIsKept`: pmid `"PPR456"`. Expect `handoff.pmid == "PPR456"`.
- [ ] **Step 2: Run them.** `swift test --package-path ios/MedicalFactChecker --filter DocumentStudyAnalyzerHandoffTests`. Expected: FAIL to compile.
- [ ] **Step 3: Implement** `studyAnalyzerHandoff(online:readLibrary:readFile:)` in the new file. Add the file to the Xcode project, then confirm `grep -c "Document+StudyAnalyzer.swift" ios/MedicalFactChecker/MedicalFactChecker.xcodeproj/project.pbxproj` prints at least 2.
- [ ] **Step 4: Run them.** Same command, then the full `swift test --package-path ios/MedicalFactChecker`. Expected: PASS. The suite's test count goes up by exactly 8 from before Step 1.
- [ ] **Step 5: Commit** with the message `feat(app): choose what a document hands StudyAnalyzer (library JATS, ids, PDF, Markdown, HTML)`.

### Task 3: The sender and the viewer's button (macOS)

**Files:**
- Create: `ios/MedicalFactChecker/Sources/macOS/App/StudyAnalyzerSender.swift` (add it to the Xcode target under `Sources/macOS/App` with the `xcodeproj` gem)
- Modify: `ios/MedicalFactChecker/Sources/macOS/Views/FactCheck/MacFullTextViewer.swift` (the header's actions `HStack`, about lines 125–160, beside `shareMenu`; plus state and an alert)
- Modify: `ios/MedicalFactChecker/Sources/macOS/App/MedicalFactCheckerMacApp.swift` (at launch, next to `LibraryController.startAtLaunch`, line 35)
- Modify: `ios/MedicalFactChecker/Sources/macOS/MacConstants.swift` (the button's label `"Open in StudyAnalyzer"`, the SF Symbol `"arrow.up.forward.app"`, and the clean-up age of 60 seconds)
- Docs: `CLAUDE.md` (BioMedLit `Utilities/`: add StudyAnalyzerHandoff), `CHANGELOG.md` `[Unreleased]` → Added, `HANDOVER.md` (the library section: step 4's viewer half done, the card half left)

**Interfaces:**
- Consumes: `Document.studyAnalyzerHandoff(online:readLibrary:readFile:)` and `StudyAnalyzerHandoffChoice` (Task 2); `StudyAnalyzerHandoff.encoded()` and the constants (Task 1); `LibraryController.library()` (returns `(any FullTextLibrary)?`; its `read(_:)` backs `readLibrary`, and a nil library answers every read with `.failure` "No paper library is set").
- Produces:
  ```swift
  @MainActor enum StudyAnalyzerSender {
      /// StudyAnalyzer's app, or nil when Launch Services knows none.
      static func appURL() -> URL?
      /// Write and open the hand-off. Returns the sentences to show:
      /// empty on a clean send; the choice's notes after a send that passed sources over;
      /// one failure sentence when nothing was sent.
      static func send(_ document: Document) async -> [String]
      /// Delete hand-off files older than the clean-up age (at launch and before each send).
      static func removeOldHandoffs()
  }
  ```
- Behaviour: the files go in `FileManager.default.temporaryDirectory/StudyAnalyzerHandoff/<UUID>.studyanalyzer`. "Online" is one `NWPathMonitor` reading: start it on a private queue, take the first `path.status == .satisfied`, cancel, and treat a reading not had within 1 second as offline (a constant in `MacConstants`). Open with `NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())`. Failures each give one sentence: StudyAnalyzer not found, the choice nil ("This paper has nothing StudyAnalyzer can open."), the write failing, the open throwing.

- [ ] **Step 1: Implement `StudyAnalyzerSender`** as above. It has no unit test, because macOS views and app code are outside the SwiftPM target; Steps 4–6 check it.
- [ ] **Step 2: Wire the button.** In the viewer, compute `@State private var studyAnalyzerURL: URL?` in `.task` with `StudyAnalyzerSender.appURL()`. When it is non-nil, show a `Button` with the label and icon from `MacConstants`; it is disabled while a send runs, with `.help` and `.accessibilityLabel` set. Its action awaits `send(document)`. A non-empty result goes into `@State private var studyAnalyzerMessages: [String]`, shown in an `.alert` (title "Open in StudyAnalyzer", message the sentences joined by spaces, one OK button).
- [ ] **Step 3: Clean up at launch.** Call `StudyAnalyzerSender.removeOldHandoffs()` in `MedicalFactCheckerMacApp` beside `LibraryController.startAtLaunch`.
- [ ] **Step 4: Type-check the macOS build.** `xcodebuild build -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj -scheme MedicalFactChecker -destination 'generic/platform=macOS' -quiet`. Expected: exit 0 and no new warnings in the touched files. Then build iOS too (`-destination 'generic/platform=iOS'`); the new shared file must compile there.
- [ ] **Step 5: Run every suite once more** (BioMedLit, then the app, one at a time). Expected: PASS, with the counts from Tasks 1 and 2.
- [ ] **Step 6: Manual check (the maintainer's, sandboxed build).** With StudyAnalyzer quit, click the button on (a) a Europe PMC paper, (b) a paper with a cached PDF, and (c) the same paper twice within 10 seconds. Expected: StudyAnalyzer launches and offers each paper once, and (a) arrives by identifiers when online. Then confirm `ls $TMPDIR/StudyAnalyzerHandoff` holds at most the last minute's files.
- [ ] **Step 7: Docs.** Add the CLAUDE.md line, a CHANGELOG Added entry ("**Open in StudyAnalyzer** (macOS full-text viewer): hands the paper with its text to StudyAnalyzer; no lasting copy"), and the HANDOVER update. Reflow the paragraphs you edited.
- [ ] **Step 8: Commit** with the message `feat(mac): Open in StudyAnalyzer from the full-text viewer`, then open the PR and run `/finalcheck`. Write "Part of #788" with no closing keyword, because #788 stays open.
