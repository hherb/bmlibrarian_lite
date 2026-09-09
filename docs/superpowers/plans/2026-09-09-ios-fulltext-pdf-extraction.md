# iOS/macOS full-text PDF extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A PDF that full-text retrieval downloads contributes its text to transparency analysis and report generation, and a retrieval says what kind of content it produced.

**Architecture:** `FullTextResult` gains three fields beside `content` rather than new associated values on the content enum, following the argument that type already makes for `warnings` and `degradation`. A `PDFTextExtracting` protocol with a PDFKit backend mirrors bmlib's `PDFConverter` abstract base. Download and extraction move inside `FullTextService.fetchFullText` so all four app fetch surfaces get them at once.

**Tech Stack:** Swift 6.3, SwiftPM package `Packages/BioMedLit` (iOS 17 / macOS 14), XCTest, PDFKit and CoreText as system frameworks, SwiftData in the app.

**Spec:** `docs/superpowers/specs/2026-09-09-ios-fulltext-pdf-extraction-design.md`

## Global Constraints

- **Branch:** `feat/ios-fulltext-pdf-extraction`, already created, spec already committed on it.
- **Raw values are literals.** Every persisted enum raw value is written explicitly and pinned in tests against a string literal in both directions. Never round-trip through `init(rawValue:)` to assert a raw value: that agrees with a rename and pins nothing.
- **`FullTextContentKind` raw values are bmlib's, verbatim:** `"fulltext"`, `"abstract"`, `"extracted"`, `"none"`.
- **Reproduce before fixing.** Every regression test asserts the broken behaviour first, then the fix.
- **No new package dependencies.** PDFKit and CoreText are system frameworks; `Package.swift` gains nothing.
- **Fixtures are located by walking up from `#filePath`,** not by SwiftPM resources, matching `JATSRealCorpusTests.corpusDirectory`.
- **No new app source file, so no Xcode target change.** Every new file this plan creates lives in the SwiftPM package, which needs no `project.pbxproj` edit; the app-side tasks modify existing files only. The spec's file list names `project.pbxproj` and is wrong about that. If you find yourself adding a file under `ios/MedicalFactChecker/Sources/`, it must be added to the target or it silently does not build, which is the failure commit `85f37d6` had to fix for `Logger.swift`. Note `project.pbxproj` and `Info.plist` already carry unrelated uncommitted edits; leave them out of every commit in this plan.
- **Licence header.** Every new Swift file starts with the 15-line AGPL header used by every existing file in the package. Copy it verbatim from `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`.
- **Docstrings.** Public declarations carry doc comments saying why, not what, matching the surrounding files.
- **Package test command:** `swift test --package-path Packages/BioMedLit`.

---

### Task 1: `FullTextContentKind` and the three result fields

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextContentKindTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `public enum FullTextContentKind: String, Sendable, Codable, CaseIterable { case fulltext, abstract, extracted, none }`
  - `FullTextResult.contentKind: FullTextContentKind`
  - `FullTextResult.extractedText: String?`
  - `FullTextResult.localPDFPath: String?`
  - `FullTextResult.init(content:warnings:degradation:contentKind:extractedText:localPDFPath:)`, every new parameter defaulted so existing call sites compile unchanged.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/FullTextContentKindTests.swift` with the licence header, then:

```swift
import XCTest
@testable import BioMedLit

/// The kind is a *persisted* contract shared with bmlib, whose `ContentKind`
/// uses these exact four strings. Pinned against literals in both directions
/// for the reason `FullTextDegradation`'s raw values are: a compiler-derived
/// case name is a detail a rename changes silently, and a test that
/// round-trips through `init(rawValue:)` agrees with the rename.
final class FullTextContentKindTests: XCTestCase {
    func testTheRawValuesArePinned() {
        XCTAssertEqual(FullTextContentKind.fulltext.rawValue, "fulltext")
        XCTAssertEqual(FullTextContentKind.abstract.rawValue, "abstract")
        XCTAssertEqual(FullTextContentKind.extracted.rawValue, "extracted")
        XCTAssertEqual(FullTextContentKind.none.rawValue, "none")
    }

    func testTheRawValuesDecode() {
        XCTAssertEqual(FullTextContentKind(rawValue: "fulltext"), .fulltext)
        XCTAssertEqual(FullTextContentKind(rawValue: "abstract"), .abstract)
        XCTAssertEqual(FullTextContentKind(rawValue: "extracted"), .extracted)
        XCTAssertEqual(FullTextContentKind(rawValue: "none"), .none)
    }

    /// A member added later must be given a raw value deliberately, not
    /// inherited from its case name.
    func testTheMemberSetIsPinned() {
        XCTAssertEqual(FullTextContentKind.allCases.count, 4)
    }

    /// The default keeps every existing producer compiling and honest: a
    /// result built without saying what it holds claims nothing.
    func testAResultDefaultsToNoKindAndNoExtraction() {
        let result = FullTextResult(content: .doi(webURL: URL(string: "https://doi.org/10.1/x")!))
        XCTAssertEqual(result.contentKind, .none)
        XCTAssertNil(result.extractedText)
        XCTAssertNil(result.localPDFPath)
    }

    /// Europe PMC content carrying a body is the ordinary success, and the one
    /// case where a kind and a parse coexist.
    func testEuropePMCContentCanCarryTheFulltextKind() {
        let result = FullTextResult(
            content: .europePMC(html: "<p>body</p>", markdown: "body"),
            contentKind: .fulltext
        )
        XCTAssertEqual(result.contentKind, .fulltext)
    }

    /// The three facts a PDF tier produces travel together.
    func testAPDFResultCarriesItsTextAndItsPath() {
        let result = FullTextResult(
            content: .unpaywall(pdfURL: URL(string: "https://example.org/a.pdf")!),
            contentKind: .extracted,
            extractedText: "recovered prose",
            localPDFPath: "/tmp/a.pdf"
        )
        XCTAssertEqual(result.extractedText, "recovered prose")
        XCTAssertEqual(result.localPDFPath, "/tmp/a.pdf")
        XCTAssertEqual(result.pdfURL?.absoluteString, "https://example.org/a.pdf")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextContentKindTests`
Expected: compile failure, `cannot find 'FullTextContentKind' in scope`.

- [ ] **Step 3: Add the enum**

In `FullTextModels.swift`, directly after the `FullTextDegradation` enum:

```swift
/// What a retrieval's text actually is.
///
/// A retrieval can hand back an article body, the abstract of a body-less
/// deposit, prose recovered from a PDF, or no text at all, and until this
/// existed all four looked alike to a caller: `html` was either set or it was
/// not. So an abstract-only Europe PMC deposit was cached, displayed and handed
/// to the transparency analyzer as though it were an article.
///
/// Callers that must not analyse an abstract as if it were an article branch on
/// this rather than on the text being non-nil.
///
/// The four raw values are bmlib's `ContentKind` verbatim, so a stored value
/// means the same thing on both sides. They are explicit literals because they
/// are a *persisted* contract — the rule ``FullTextDegradation`` records.
public enum FullTextContentKind: String, Sendable, Codable, CaseIterable {
    /// A JATS document that had a `<body>`.
    case fulltext = "fulltext"

    /// A body-less JATS rendering. There is no article text in it, and it is
    /// returned only when nothing better was found.
    case abstract = "abstract"

    /// Text recovered from a PDF. Prose only: no figures, tables or layout, and
    /// possibly not every page, which is why the PDF itself stays worth
    /// offering alongside it.
    case extracted = "extracted"

    /// There is no text, only a link.
    case none = "none"
}
```

- [ ] **Step 4: Add the three fields**

In `FullTextResult`, after the `degradation` property:

```swift
    /// What ``extractedText`` or ``content``'s text actually is.
    ///
    /// See ``FullTextContentKind``. Defaults to ``FullTextContentKind/none``,
    /// which is what a link-only result holds.
    public let contentKind: FullTextContentKind

    /// Prose recovered from a PDF, or `nil` when none was.
    ///
    /// Separate from ``content`` because it is not what the source handed over:
    /// the source handed over a PDF, and this is what we got out of it. Kept
    /// beside the PDF's own URL and path rather than replacing them, because
    /// extraction recovers the prose and loses the figures, tables and layout.
    public let extractedText: String?

    /// Where the downloaded PDF now is on disk, or `nil` when none was cached.
    ///
    /// Distinct from ``pdfURL``, which is where it came from. Both are worth
    /// having: the remote URL is what a re-download would use, and this is what
    /// a viewer opens.
    public let localPDFPath: String?
```

Replace the initializer signature and add the four asserts. The existing three asserts stay exactly as they are, and these follow them:

```swift
    public init(
        content: FullTextContent,
        warnings: JATSParseWarnings = JATSParseWarnings(),
        degradation: FullTextDegradation? = nil,
        contentKind: FullTextContentKind = .none,
        extractedText: String? = nil,
        localPDFPath: String? = nil
    ) {
```

and, after the existing `assert(degradation != .unspecified, ...)`:

```swift
        // The kind and the text are one fact stored twice. A caller that
        // branches on `.extracted` and finds no text, or holds text under any
        // other kind, has two answers to one question and no rule for which
        // wins.
        assert(
            (extractedText != nil) == (contentKind == .extracted),
            "extractedText and .extracted must agree; got \(String(describing: extractedText?.count)) chars under \(contentKind)"
        )
        // `.fulltext` and `.abstract` name what a *parse* found, and Europe PMC
        // XML is the only thing this service parses.
        assert(
            (contentKind != .fulltext && contentKind != .abstract) || content.source == .europePMC,
            "\(contentKind) claims a parse, but \(content.source) involves none"
        )
        // And the converse: a parsed source's text is its own. Extracted text
        // on it would mean two texts with no rule for which the analyzer reads.
        assert(
            extractedText == nil || content.source != .europePMC,
            "extracted text on \(content.source), which is parsed rather than extracted"
        )
        // A path on a publisher link hands the viewer a file that is not there.
        assert(
            localPDFPath == nil || content.pdfURL != nil,
            "localPDFPath on \(content.source), which carries no PDF"
        )
        self.content = content
        self.warnings = warnings
        self.degradation = degradation
        self.contentKind = contentKind
        self.extractedText = extractedText
        self.localPDFPath = localPDFPath
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextContentKindTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the whole package suite**

Run: `swift test --package-path Packages/BioMedLit`
Expected: PASS. Every existing `FullTextResult(...)` call site compiles because all three new parameters are defaulted.

- [ ] **Step 7: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextContentKindTests.swift
git commit -m "feat(fulltext): say what a retrieval's text actually is

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: The PDF text extractor

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Services/PDFTextExtractor.swift`
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/PDFTextExtractorTests.swift`
- Create: `Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/PDF/` and four `.pdf` files
- Create: `Packages/BioMedLit/Scripts/make_pdf_fixtures.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `public struct PDFExtractionResult: Sendable, Equatable` with `text: String`, `success: Bool`, `pageCount: Int`, `convertedPages: Int`, `charCount: Int`, `warnings: [String]`, `isComplete: Bool`, `completionRatio: Double`, `errorMessage: String?`
  - `public protocol PDFTextExtracting: Sendable { func extract(from fileURL: URL) -> PDFExtractionResult }`
  - `public struct PDFKitTextExtractor: PDFTextExtracting` with `public init()`

- [ ] **Step 1: Write the fixture generator**

Create `Packages/BioMedLit/Scripts/make_pdf_fixtures.swift`. It is run by hand, not by the suite, so the fixtures stay reviewable and reproducible rather than being opaque committed binaries of unknown origin.

```swift
#!/usr/bin/env swift
// Regenerates the PDF fixtures in Tests/BioMedLitTests/Fixtures/PDF.
//
// Run from the package root:  swift Scripts/make_pdf_fixtures.swift
//
// CoreGraphics and CoreText only, so this needs no dependency and no Xcode
// project. Text is drawn with CoreText rather than as an image, because the
// whole point of three of these four files is that PDFKit can get the text
// back out.
import CoreGraphics
import CoreText
import Foundation

let pageSize = CGRect(x: 0, y: 0, width: 612, height: 792)

/// Draw one line of text near the top of the current page.
func draw(_ text: String, in context: CGContext, y: CGFloat = 700) {
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(
        string: text,
        attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: 72, y: y)
    CTLineDraw(line, context)
}

/// Write a PDF whose pages are produced by `body`.
func makePDF(named name: String, auxiliaryInfo: CFDictionary? = nil, body: (CGContext) -> Void) {
    let url = URL(fileURLWithPath: "Tests/BioMedLitTests/Fixtures/PDF/\(name)")
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    guard let consumer = CGDataConsumer(url: url as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: nil, auxiliaryInfo) else {
        fatalError("could not create a PDF context for \(name)")
    }
    body(context)
    context.closePDF()
    print("wrote \(url.path)")
}

// 1. An ordinary one-page article. The text is what the extractor must recover.
makePDF(named: "ordinary.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("Randomised trial of an intervention.", in: context, y: 700)
    draw("Methods: we enrolled 120 patients.", in: context, y: 670)
    context.endPage()
}

// 2. Two pages where the second carries no text at all: the shape of a partial
//    extraction, which must not read as a whole article.
makePDF(named: "mixed.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("Page one carries prose.", in: context, y: 700)
    context.endPage()
    context.beginPage(mediaBox: &box)
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 72, y: 400, width: 200, height: 200))
    context.endPage()
}

// 3. No text anywhere: a scan, which yields nothing and must say so.
makePDF(named: "imageonly.pdf") { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fill(CGRect(x: 72, y: 400, width: 300, height: 300))
    context.endPage()
}

// 4. Password-protected. bmlib is explicit that this is a *failed* result and
//    not an empty successful one, so that a locked file is never logged as a
//    scan.
let encryption: CFDictionary = [
    kCGPDFContextUserPassword as String: "secret",
    kCGPDFContextOwnerPassword as String: "owner",
] as CFDictionary
makePDF(named: "encrypted.pdf", auxiliaryInfo: encryption) { context in
    var box = pageSize
    context.beginPage(mediaBox: &box)
    draw("You should not be able to read this.", in: context, y: 700)
    context.endPage()
}
```

- [ ] **Step 2: Generate the fixtures and confirm they are what they claim**

```bash
cd Packages/BioMedLit && swift Scripts/make_pdf_fixtures.swift && cd -
ls -l Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/PDF/
```

Expected: four files, each a few kilobytes. Confirm the encrypted one really is:

```bash
head -c 2000 Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/PDF/encrypted.pdf | strings | grep -i encrypt
```

Expected: a line mentioning `/Encrypt`. If it is absent, the auxiliary dictionary was ignored and the fixture is worthless; stop and fix the generator rather than writing tests against it.

- [ ] **Step 3: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/PDFTextExtractorTests.swift` with the licence header, then:

```swift
import XCTest
@testable import BioMedLit

/// The extractor is what makes a downloaded PDF contribute anything at all, and
/// every way it can come up empty has to be distinguishable: a scan that yields
/// nothing, a file that needs a password, and a partial extraction are three
/// different things to tell an operator.
final class PDFTextExtractorTests: XCTestCase {
    /// Fixtures sit beside this file, so no walk is needed. Located from
    /// `#filePath` rather than bundled as SwiftPM resources, matching
    /// `JATSRealCorpusTests` — and here it also keeps the generator script's
    /// output path and the test's input path the same string.
    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/PDF/\(name)")
    }

    private let extractor = PDFKitTextExtractor()

    func testAnOrdinaryPDFYieldsItsProse() {
        let result = extractor.extract(from: Self.fixture("ordinary.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.text.contains("Randomised trial"))
        XCTAssertTrue(result.text.contains("120 patients"))
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.convertedPages, 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.charCount, result.text.count)
    }

    /// The point of the whole result type: a page that gave nothing is counted,
    /// so a caller can tell half an article from a whole one.
    func testAPageWithNoTextIsCountedAsUnconverted() {
        let result = extractor.extract(from: Self.fixture("mixed.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.convertedPages, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.completionRatio, 0.5, accuracy: 0.001)
        XCTAssertTrue(
            result.warnings.contains(where: { $0.contains("2") }),
            "the warning should name the page that gave nothing, got \(result.warnings)"
        )
    }

    /// A scan. Successful — nothing went wrong — but with no text, which is a
    /// state the caller must not mistake for prose.
    func testAnImageOnlyPDFSucceedsWithNoText() {
        let result = extractor.extract(from: Self.fixture("imageonly.pdf"))
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.charCount, 0)
        XCTAssertEqual(result.convertedPages, 0)
        XCTAssertFalse(result.isComplete)
    }

    /// bmlib is explicit that a password is a failure rather than an empty
    /// success, so that a locked file is never reported as a scan.
    func testAnEncryptedPDFIsAFailureNotAnEmptySuccess() {
        let result = extractor.extract(from: Self.fixture("encrypted.pdf"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.charCount, 0)
        XCTAssertNotNil(result.errorMessage)
    }

    func testAMissingFileIsAFailure() {
        let result = extractor.extract(from: Self.fixture("does-not-exist.pdf"))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.pageCount, 0)
        XCTAssertNotNil(result.errorMessage)
    }

    /// `isComplete` is derived, and every clause of it matters: an empty
    /// successful extraction is not complete.
    func testCompletenessRequiresSuccessEveryPageAndSomeText() {
        let empty = PDFExtractionResult(
            text: "", success: true, pageCount: 0, convertedPages: 0, warnings: []
        )
        XCTAssertFalse(empty.isComplete)
        XCTAssertEqual(empty.completionRatio, 0)
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter PDFTextExtractorTests`
Expected: compile failure, `cannot find 'PDFKitTextExtractor' in scope`.

- [ ] **Step 5: Write the extractor**

Create `Packages/BioMedLit/Sources/BioMedLit/Services/PDFTextExtractor.swift` with the licence header, then:

```swift
import Foundation
import PDFKit

/// What extracting a PDF's text produced, and how much of the document it
/// covered.
///
/// Mirrors bmlib's `ConversionResult`, including the distinction its comments
/// insist on: a file that could not be opened is a *failure*, while a scan that
/// opened fine and holds no text is a *success with no text*. Collapsing the two
/// tells an operator to go looking for OCR when the real problem is a password.
public struct PDFExtractionResult: Sendable, Equatable {
    /// The recovered prose, empty when there was none.
    public let text: String

    /// Whether the document could be opened and read at all.
    public let success: Bool

    /// Pages the document holds, `0` when it could not be opened.
    public let pageCount: Int

    /// Pages that yielded any text.
    public let convertedPages: Int

    /// Human-readable notes about pages that gave nothing, one per page.
    public let warnings: [String]

    /// Why the document could not be read, or `nil` when it could.
    public let errorMessage: String?

    /// Characters recovered.
    public var charCount: Int { text.count }

    /// Whether every page of a readable document yielded text.
    ///
    /// All three clauses are load-bearing. A failed read is not complete; a
    /// document with an unconverted page is not complete; and an empty
    /// successful extraction — a scan — is not complete either, or a scanned
    /// article would report as a whole one.
    public var isComplete: Bool {
        success && pageCount == convertedPages && charCount > 0
    }

    /// The share of pages that yielded text, `0` for a document with no pages.
    public var completionRatio: Double {
        guard pageCount > 0 else { return 0 }
        return Double(convertedPages) / Double(pageCount)
    }

    /// Create a result.
    ///
    /// - Parameters:
    ///   - text: The recovered prose.
    ///   - success: Whether the document could be read.
    ///   - pageCount: Pages the document holds.
    ///   - convertedPages: Pages that yielded text.
    ///   - warnings: One note per page that gave nothing.
    ///   - errorMessage: Why the read failed, `nil` when it did not.
    public init(
        text: String,
        success: Bool,
        pageCount: Int,
        convertedPages: Int,
        warnings: [String],
        errorMessage: String? = nil
    ) {
        self.text = text
        self.success = success
        self.pageCount = pageCount
        self.convertedPages = convertedPages
        self.warnings = warnings
        self.errorMessage = errorMessage
    }
}

/// Recovers text from a PDF on disk.
///
/// A protocol with one production implementation, mirroring bmlib's
/// `PDFConverter` abstract base and its `PyMuPDFConverter`. The seam is what
/// lets ``FullTextService``'s PDF tiers be tested without a real PDF, which is
/// the same reason its `URLSession` and `EuropePMCService` are injectable.
public protocol PDFTextExtracting: Sendable {
    /// Extract text from the PDF at `fileURL`.
    ///
    /// Never throws: an unreadable file is a result that says so, because the
    /// caller's next move is the same either way and a thrown error at that
    /// point discards the page counts an operator needs.
    ///
    /// - Parameter fileURL: A file URL for the PDF to read.
    /// - Returns: What was recovered and how much of the document it covered.
    func extract(from fileURL: URL) -> PDFExtractionResult
}

/// The production extractor, backed by PDFKit.
///
/// `PDFPage.string` is the native equivalent of what bmlib does with PyMuPDF.
public struct PDFKitTextExtractor: PDFTextExtracting {
    /// Create an extractor.
    public init() {}

    public func extract(from fileURL: URL) -> PDFExtractionResult {
        guard let document = PDFDocument(url: fileURL) else {
            return PDFExtractionResult(
                text: "", success: false, pageCount: 0, convertedPages: 0, warnings: [],
                errorMessage: "the file could not be opened as a PDF"
            )
        }

        // Checked before reading rather than inferred from empty output. A
        // locked document hands back nil for every page, which is
        // indistinguishable from a scan unless the lock is asked about first.
        if document.isLocked || document.isEncrypted {
            return PDFExtractionResult(
                text: "", success: false, pageCount: document.pageCount,
                convertedPages: 0, warnings: [],
                errorMessage: "the PDF is password-protected"
            )
        }

        var pages: [String] = []
        var warnings: [String] = []
        var convertedPages = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                warnings.append("page \(index + 1) could not be read")
                continue
            }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.isEmpty {
                warnings.append("page \(index + 1) yielded no text")
                continue
            }
            pages.append(pageText)
            convertedPages += 1
        }

        return PDFExtractionResult(
            text: pages.joined(separator: "\n\n"),
            success: true,
            pageCount: document.pageCount,
            convertedPages: convertedPages,
            warnings: warnings
        )
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter PDFTextExtractorTests`
Expected: PASS, 6 tests.

If `testAnEncryptedPDFIsAFailureNotAnEmptySuccess` fails because `PDFDocument(url:)` returned nil for the encrypted fixture, that is still a failure result with a `nil`-open message rather than a password message. Loosen the assertion to `XCTAssertFalse(result.success)` plus `XCTAssertNotNil(result.errorMessage)` and leave a comment saying PDFKit refuses the file before the lock check is reached. Do not weaken the `success` assertion.

- [ ] **Step 7: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/PDFTextExtractor.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/PDFTextExtractorTests.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/Fixtures/PDF \
        Packages/BioMedLit/Scripts/make_pdf_fixtures.swift
git commit -m "feat(fulltext): recover a PDF's text, and say how much of it

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The parser says whether it produced a body

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/JATS/JATSXMLParser.swift:731`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/JATSProducedBodyTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `JATSXMLParser.producedBody: Bool`, a public computed property, valid after any of `parseToHTML()`, `parseToMarkdown()` or `parseToArticle()` has run.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/JATSProducedBodyTests.swift` with the licence header, then:

```swift
import XCTest
@testable import BioMedLit

/// A body-less deposit parses *successfully* — `parseToHTML` throws
/// `.noContent` only when the whole rendering is empty, and an abstract is not
/// empty. So Europe PMC's abstract-only records were returned, cached and
/// analysed as article bodies, and nothing in the parse said otherwise.
final class JATSProducedBodyTests: XCTestCase {
    private func xml(_ body: String) -> Data {
        Data("""
        <article xmlns:xlink="http://www.w3.org/1999/xlink">
          <front><article-meta>
            <title-group><article-title>A title</article-title></title-group>
            <abstract><p>Background and findings.</p></abstract>
          </article-meta></front>
          \(body)
        </article>
        """.utf8)
    }

    func testAnArticleWithABodyReportsOne() throws {
        let parser = JATSXMLParser(data: xml("<body><sec><title>Methods</title><p>We enrolled 120 patients.</p></sec></body>"))
        _ = try parser.parseToHTML()
        XCTAssertTrue(parser.producedBody)
    }

    /// The case that matters: it parses, it renders, and it is not an article.
    func testABodylessDepositReportsNoBody() throws {
        let parser = JATSXMLParser(data: xml(""))
        let html = try parser.parseToHTML()
        XCTAssertFalse(html.isEmpty, "the abstract still renders; that is the trap")
        XCTAssertFalse(parser.producedBody)
    }

    /// A `<body>` element holding only loose prose still counts. Anything less
    /// would undo the implicit-section fix (#1.3 in the alignment doc), which
    /// exists precisely because `<sec>` is optional.
    func testLooseProseInABodyCountsAsABody() throws {
        let parser = JATSXMLParser(data: xml("<body><p>Loose prose with no section.</p></body>"))
        _ = try parser.parseToHTML()
        XCTAssertTrue(parser.producedBody)
    }

    /// An empty `<body>` element is not a body. The tag being present says
    /// nothing about there being prose in it.
    func testAnEmptyBodyElementIsNotABody() throws {
        let parser = JATSXMLParser(data: xml("<body></body>"))
        _ = try parser.parseToHTML()
        XCTAssertFalse(parser.producedBody)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter JATSProducedBodyTests`
Expected: compile failure, `value of type 'JATSXMLParser' has no member 'producedBody'`.

- [ ] **Step 3: Add the property**

In `JATSXMLParser.swift`, immediately before the existing `private var producedContent` at line 731:

```swift
    /// Whether the parse found any article body.
    ///
    /// Read after parsing, the way ``parseWarnings`` is, so neither
    /// ``parseToHTML()`` nor ``parseToMarkdown()`` changes signature for it.
    ///
    /// This is not the same question as ``producedContent``, and the difference
    /// is the whole point: a body-less deposit has a title and an abstract, so
    /// it *produced content*, rendered successfully, and was returned as an
    /// article. Europe PMC serves those for records deposited abstract-only, and
    /// until this existed nothing downstream could tell one from a real article.
    ///
    /// Keyed on `bodySections` rather than on having seen a `<body>` element,
    /// because an empty `<body>` is not a body, and because loose prose with no
    /// `<sec>` is one — which is what the implicit-section handling exists for.
    public var producedBody: Bool {
        !bodySections.isEmpty
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter JATSProducedBodyTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Run the whole package suite**

Run: `swift test --package-path Packages/BioMedLit`
Expected: PASS. The real-corpus digests are unaffected; nothing about rendering changed.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/JATS/JATSXMLParser.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/JATSProducedBodyTests.swift
git commit -m "feat(jats): distinguish a body-less deposit from an article

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The tier chain holds back an abstract

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift:125-265` and `286-360`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceAbstractHoldbackTests.swift` (create)

**Interfaces:**
- Consumes: `FullTextContentKind` and the `FullTextResult` fields from Task 1; `JATSXMLParser.producedBody` from Task 3.
- Produces:
  - `FullTextService.fetchEuropePMCXML(pmcId:)` now returns `(html: String, markdown: String, warnings: JATSParseWarnings, contentKind: FullTextContentKind)`.
  - `fetchFullText` returns `.europePMC` content carrying `contentKind: .fulltext` or `.abstract`.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceAbstractHoldbackTests.swift` with the licence header. `StubURLProtocol` already exists in `FullTextServiceParseWarningsTests.swift` in the same target; reuse it rather than writing a second stub.

```swift
import XCTest
@testable import BioMedLit

/// An abstract-only Europe PMC deposit used to win the chain outright: it
/// parses, it renders, and nothing said it was not an article. It was then
/// cached and handed to the transparency analyzer as an article body.
final class FullTextServiceAbstractHoldbackTests: XCTestCase {
    private static let withBody = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background.</p></abstract>
    </article-meta></front>
    <body><sec><title>Methods</title><p>We enrolled 120 patients.</p></sec></body>
    </article>
    """.utf8)

    private static let bodyless = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

    private func makeService() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(email: "test@example.org", session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.stubbed = (200, Data())
    }

    func testAnArticleWithABodyIsReportedAsFulltext() async throws {
        StubURLProtocol.stubbed = (200, Self.withBody)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .fulltext)
    }

    /// The abstract is still returned when nothing better exists — the reader
    /// gets what there is — but it is labelled, which is what stops it being
    /// analysed as an article.
    func testABodylessDepositIsReturnedAsAnAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        let result = try await makeService().fetchFullText(pmcId: "PMC1", doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertNotNil(result.markdown)
    }

    /// And it is held back rather than returned on the spot: an Unpaywall PDF
    /// is a better answer than an abstract, and used to be unreachable because
    /// the abstract returned first.
    func testAPDFBeatsAHeldAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        StubURLProtocol.stubbedByURLFragment = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8))
        ]
        defer { StubURLProtocol.stubbedByURLFragment = [:] }
        let result = try await makeService()
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: "1")
        XCTAssertEqual(result.source, .unpaywall)
    }
}
```

- [ ] **Step 2: Check the stub's fragment hook exists, and add it if not**

`StubURLProtocol` in `FullTextServiceParseWarningsTests.swift` documents a per-URL-fragment map. Confirm its exact property name:

```bash
grep -n "stubbedByURLFragment\|Bodies served only to requests" \
  Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift
```

If the property has a different name, use that name in the test above instead. If no such property exists, add one to `StubURLProtocol`:

```swift
    /// Bodies served only to requests whose URL contains the key, so one test
    /// can give the XML tier and the Unpaywall tier different answers.
    nonisolated(unsafe) static var stubbedByURLFragment: [String: (status: Int, body: Data)] = [:]
```

and, at the top of its `startLoading`, prefer a fragment match over `stubbed`.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextServiceAbstractHoldbackTests`
Expected: `testAnArticleWithABodyIsReportedAsFulltext` fails with `.none` instead of `.fulltext`, and `testAPDFBeatsAHeldAbstract` fails with `.europePMC` instead of `.unpaywall`. That second failure is the defect reproduced.

- [ ] **Step 4: Return the kind from the XML fetch**

In `fetchEuropePMCXML`, change the return type to include the kind and build it from the HTML parser, which is already the authoritative instance for warnings:

```swift
    func fetchEuropePMCXML(
        pmcId: String
    ) async throws -> (
        html: String, markdown: String, warnings: JATSParseWarnings, contentKind: FullTextContentKind
    ) {
```

and in the `do` block, replace the existing `return (html: html, markdown: markdown, warnings: parser.parseWarnings)` with:

```swift
            // Read from the HTML parser for the same reason its warnings are:
            // that is the rendering the reader is shown. Both parsers read the
            // same bytes, so this is about which instance is authoritative, not
            // about which answer is right.
            return (
                html: html,
                markdown: markdown,
                warnings: parser.parseWarnings,
                contentKind: parser.producedBody ? .fulltext : .abstract
            )
```

Change `fetchEuropePMCWithRetry`'s return type to match, leaving its body as it is.

- [ ] **Step 5: Hold the abstract back**

In `fetchFullText`, replace the Europe PMC success branch. Where it currently returns immediately:

```swift
                let content = try await fetchEuropePMCWithRetry(pmcId: pmcId)
                BioMedLitLib.logger?.info(
                    "Successfully retrieved Europe PMC full text for \(pmcId)",
                    category: .fullText
                )
                let parsed = FullTextResult(
                    content: .europePMC(html: content.html, markdown: content.markdown),
                    warnings: content.warnings,
                    contentKind: content.contentKind
                )
                // A body-less deposit is not an article. Returning it here — as
                // this did — made it beat every remaining tier, so an
                // open-access PDF of the same paper was unreachable, and the
                // abstract was cached and scored as an article body. Held back
                // instead, and returned at the end only if nothing better
                // arrives, mirroring bmlib's `_with_abstract_fallback`.
                if content.contentKind == .abstract {
                    BioMedLitLib.logger?.info(
                        "Europe PMC served an abstract-only deposit for \(pmcId); "
                            + "holding it back in case a PDF tier does better",
                        category: .fullText
                    )
                    abstractOnly = parsed
                } else {
                    return parsed
                }
```

Declare the holdback local beside the existing `var degradation: FullTextDegradation?` at the top of the method:

```swift
        // A body-less Europe PMC rendering, kept aside until every better tier
        // has had its turn. `nil` when none was seen.
        var abstractOnly: FullTextResult?
```

Then, at each of the three link-only exits, prefer the held abstract. Immediately before the DOI fallback's `return`, and before the PubMed fallback's `return`, and before the final `throw`:

```swift
        // The reader gets the abstract rather than a bare link. No web URL is
        // attached to it: `Document.fullTextLinkDestination` already resolves
        // the DOI page or the PubMed record for every document, and a second
        // copy here would give the views two sources for one link.
        if let abstractOnly {
            BioMedLitLib.logger?.info(
                "No tier beat the abstract-only rendering for PMID \(pmid); returning it",
                category: .fullText
            )
            return abstractOnly
        }
```

Place that block once, immediately after the Unpaywall branch and before the DOI fallback, so all three exits are covered by one check rather than three copies. Accumulating this per branch is what the handover's #186 note warns against.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextServiceAbstractHoldbackTests`
Expected: PASS, 3 tests.

- [ ] **Step 7: Run the whole package suite**

Run: `swift test --package-path Packages/BioMedLit`
Expected: PASS. `FullTextServiceParseWarningsTests` calls `fetchEuropePMCXML` directly and destructures its tuple; if it binds by position it now needs the fourth element. Fix by naming the fields it uses rather than by adding a positional `_`.

- [ ] **Step 8: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceAbstractHoldbackTests.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceParseWarningsTests.swift
git commit -m "fix(fulltext): an abstract-only deposit is not an article

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: The PDF tiers download and extract

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift:80-105` and the two PDF tier branches
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceExtractionTests.swift` (create)

**Interfaces:**
- Consumes: `PDFTextExtracting`, `PDFKitTextExtractor`, `PDFExtractionResult` from Task 2; the result fields from Task 1; the holdback local from Task 4.
- Produces: `FullTextService.init(email:session:europePMCService:extractor:extractPDFText:)`, with `extractor: PDFTextExtracting = PDFKitTextExtractor()` and `extractPDFText: Bool = true` both defaulted so existing call sites compile.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceExtractionTests.swift` with the licence header, then:

```swift
import XCTest
@testable import BioMedLit

/// Serves a fixed extraction result, so the tier logic can be tested without a
/// real PDF and without PDFKit's behaviour being part of the subject.
private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// A PDF used to reach the reader and stop there: `applyFullTextResult` set
/// `fullTextContent = nil` for it, so transparency analysis and report
/// generation saw nothing at all for a PDF-sourced article.
final class FullTextServiceExtractionTests: XCTestCase {
    private static let bodyless = Data("""
    <article><front><article-meta>
      <title-group><article-title>A trial</article-title></title-group>
      <abstract><p>Background and findings only.</p></abstract>
    </article-meta></front></article>
    """.utf8)

    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])

    private func makeService(
        extractor: PDFTextExtracting,
        extractPDFText: Bool = true
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(
            email: "test@example.org",
            session: URLSession(configuration: config),
            extractor: extractor,
            extractPDFText: extractPDFText
        )
    }

    private func stubUnpaywallAndPDF() {
        StubURLProtocol.stubbed = (404, Data())
        StubURLProtocol.stubbedByURLFragment = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)),
            "a.pdf": (200, Self.pdfBytes),
        ]
    }

    override func tearDown() {
        StubURLProtocol.stubbedByURLFragment = [:]
        super.tearDown()
    }

    func testAnUnpaywallPDFContributesItsText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "Recovered prose.")
        XCTAssertNotNil(result.localPDFPath, "the PDF is cached, and the viewer opens the file")
    }

    /// A scan. The link is still worth having, and claiming extracted text for
    /// it would be a lie the analyzer would act on.
    func testAPDFThatYieldsNothingContributesNoText() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: true, pageCount: 3, convertedPages: 0, warnings: ["page 1 yielded no text"]
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .none)
        XCTAssertNil(result.extractedText)
    }

    /// And when an abstract was held back, it is better than nothing — bmlib's
    /// rule that a PDF tier succeeds as soon as it has a URL, so a download that
    /// gave no text must not discard an abstract already in hand.
    func testAPDFThatYieldsNothingFallsBackToTheHeldAbstract() async throws {
        StubURLProtocol.stubbed = (200, Self.bodyless)
        StubURLProtocol.stubbedByURLFragment = [
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)),
            "a.pdf": (200, Self.pdfBytes),
        ]
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "", success: false, pageCount: 0, convertedPages: 0, warnings: [],
            errorMessage: "the PDF is password-protected"
        ))
        let result = try await makeService(extractor: extractor)
            .fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.contentKind, .abstract)
        XCTAssertNotNil(result.markdown)
    }

    /// The flag turns the download off entirely, mirroring bmlib's
    /// `convert_pdfs`. The link still comes back.
    func testTheFlagOffReturnsTheLinkAlone() async throws {
        stubUnpaywallAndPDF()
        let extractor = StubExtractor(result: PDFExtractionResult(
            text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
        let result = try await makeService(extractor: extractor, extractPDFText: false)
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: "1")

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.contentKind, .none)
        XCTAssertNil(result.extractedText)
        XCTAssertNil(result.localPDFPath)
        XCTAssertNotNil(result.pdfURL, "the reader can still open it")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextServiceExtractionTests`
Expected: compile failure on the `extractor:` argument label.

- [ ] **Step 3: Add the two stored properties and initializer parameters**

In `FullTextService`, beside `private let europePMCService: EuropePMCService`:

```swift
    /// Recovers text from a downloaded PDF.
    ///
    /// Injectable for the same reason `session` and `europePMCService` are:
    /// without the seam the PDF tiers can only be tested against a real file,
    /// and PDFKit's own behaviour becomes part of every tier test's subject.
    private let extractor: PDFTextExtracting

    /// Whether to download a PDF tier's file and recover its text.
    ///
    /// Mirrors bmlib's `convert_pdfs`. On, a PDF tier downloads, caches and
    /// extracts, so the article's prose reaches transparency analysis and report
    /// generation. Off, the tier returns the URL alone and nothing is
    /// downloaded, which is the behaviour every caller had before this existed.
    ///
    /// The PDF's URL is reported either way, because extracted text recovers the
    /// prose and loses the figures, tables and layout.
    private let extractPDFText: Bool
```

Extend the initializer, keeping every existing parameter and its documentation:

```swift
    public init(
        email: String,
        session: URLSession = FullTextService.makeSession(),
        europePMCService: EuropePMCService = EuropePMCService(),
        extractor: PDFTextExtracting = PDFKitTextExtractor(),
        extractPDFText: Bool = true
    ) {
        self.email = email
        self.europePMCService = europePMCService
        self.session = session
        self.extractor = extractor
        self.extractPDFText = extractPDFText
    }
```

- [ ] **Step 4: Add the download-and-extract helper**

Add to `FullTextService`, next to `downloadAndCachePDF`:

```swift
    /// Download a PDF tier's file, cache it, and recover its text.
    ///
    /// Best-effort throughout, and deliberately non-throwing: every failure here
    /// still leaves the reader the URL, which is exactly what this tier returned
    /// before extraction existed. Throwing would turn a tier that succeeded into
    /// a fall-through to the publisher link.
    ///
    /// Every empty outcome is logged at warning level, as bmlib does, because a
    /// scan that yields nothing is invisible otherwise and a partial extraction
    /// must not be mistaken for a whole article.
    ///
    /// - Parameters:
    ///   - url: The remote PDF.
    ///   - pmid: PubMed ID, used to name the cached file.
    /// - Returns: The cached path and the recovered text. Both `nil` when the
    ///   flag is off; the text alone `nil` when nothing was recovered.
    private func downloadAndExtract(
        from url: URL,
        pmid: String
    ) async -> (localPath: String?, text: String?) {
        guard extractPDFText else { return (nil, nil) }

        let path: String
        do {
            path = try await downloadAndCachePDF(from: url, for: pmid)
        } catch where error.isCancellation {
            return (nil, nil)
        } catch {
            BioMedLitLib.logger?.warning(
                "Could not download the PDF for PMID \(pmid) from \(url.absoluteString): "
                    + "\(error.localizedDescription); returning the link alone",
                category: .fullText
            )
            return (nil, nil)
        }

        let extraction = extractor.extract(from: URL(fileURLWithPath: path))
        guard extraction.success else {
            BioMedLitLib.logger?.warning(
                "PDF text extraction failed for \(path): "
                    + "\(extraction.errorMessage ?? "no reason reported")",
                category: .fullText
            )
            return (path, nil)
        }
        guard extraction.charCount > 0 else {
            BioMedLitLib.logger?.warning(
                "PDF \(path) yielded no extractable text over \(extraction.pageCount) page(s) — "
                    + "likely a scan; \(extraction.warnings.prefix(3))",
                category: .fullText
            )
            return (path, nil)
        }
        if !extraction.isComplete {
            BioMedLitLib.logger?.warning(
                "PDF \(path) extracted only \(extraction.convertedPages) of "
                    + "\(extraction.pageCount) pages — the attached text is incomplete",
                category: .fullText
            )
        }
        BioMedLitLib.logger?.info(
            "Extracted \(extraction.charCount) chars of text from PDF \(path)",
            category: .fullText
        )
        return (path, extraction.text)
    }
```

- [ ] **Step 5: Use it in both PDF tiers**

Replace the Europe PMC PDF branch's `return`:

```swift
        if let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            let (localPath, text) = await downloadAndExtract(from: pdfURL, pmid: pmid)
            return FullTextResult(
                content: .europePMCPDF(pdfURL: pdfURL),
                degradation: degradation,
                contentKind: text == nil ? .none : .extracted,
                extractedText: text,
                localPDFPath: localPath
            )
        }
```

and the Unpaywall branch's:

```swift
                let (localPath, text) = await downloadAndExtract(from: pdfURL, pmid: pmid)
                return FullTextResult(
                    content: .unpaywall(pdfURL: pdfURL),
                    degradation: degradation,
                    contentKind: text == nil ? .none : .extracted,
                    extractedText: text,
                    localPDFPath: localPath
                )
```

- [ ] **Step 6: Prefer the held abstract when a PDF gave no text**

The holdback check added in Task 4 sits after the Unpaywall branch, which both PDF tiers now return past. So each PDF tier falls through when it produced no text and an abstract is in hand. Replace the Europe PMC PDF branch written in Step 5 with:

```swift
        if let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            let (localPath, text) = await downloadAndExtract(from: pdfURL, pmid: pmid)
            // A PDF tier counts as a success as soon as it has a URL, so a
            // download or extraction that gave nothing would otherwise discard
            // an abstract already in hand and leave the reader a bare link.
            // bmlib's `_with_abstract_fallback` makes the same call.
            if text == nil, abstractOnly != nil {
                BioMedLitLib.logger?.info(
                    "The Europe PMC PDF yielded no text for PMID \(pmid); keeping the abstract",
                    category: .fullText
                )
            } else {
                return FullTextResult(
                    content: .europePMCPDF(pdfURL: pdfURL),
                    degradation: degradation,
                    contentKind: text == nil ? .none : .extracted,
                    extractedText: text,
                    localPDFPath: localPath
                )
            }
        }
```

and the Unpaywall branch's success path with:

```swift
                let (localPath, text) = await downloadAndExtract(from: pdfURL, pmid: pmid)
                if text == nil, abstractOnly != nil {
                    BioMedLitLib.logger?.info(
                        "The Unpaywall PDF yielded no text for PMID \(pmid); keeping the abstract",
                        category: .fullText
                    )
                } else {
                    return FullTextResult(
                        content: .unpaywall(pdfURL: pdfURL),
                        degradation: degradation,
                        contentKind: text == nil ? .none : .extracted,
                        extractedText: text,
                        localPDFPath: localPath
                    )
                }
```

Note the Unpaywall version sits inside the existing `do` block, so its indentation is one level deeper. Step 5's two `return` blocks are superseded by these; do not leave both.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextServiceExtractionTests`
Expected: PASS, 4 tests.

- [ ] **Step 8: Run the whole package suite**

Run: `swift test --package-path Packages/BioMedLit`
Expected: PASS. Existing tier tests construct `FullTextService` without an extractor, so they now download through the stub session; if any of them stubs a 200 for every URL and so starts caching a fake PDF, pass `extractPDFText: false` in that test's service rather than changing the default.

- [ ] **Step 9: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextServiceExtractionTests.swift
git commit -m "feat(fulltext): a downloaded PDF contributes its text

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Cached PDF reads are validated

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift`, `cachedPDFPath(for:)`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextCacheQuarantineTests.swift` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `FullTextService.cachedPDFPath(for:)` keeps its signature, `static func cachedPDFPath(for pmid: String) -> String?`, and gains validation and quarantine.

- [ ] **Step 1: Write the failing tests**

Create `Packages/BioMedLit/Tests/BioMedLitTests/FullTextCacheQuarantineTests.swift` with the licence header, then:

```swift
import XCTest
@testable import BioMedLit

/// `cachedPDFPath` asked only whether a file existed. A zero-length or corrupt
/// entry was therefore served as this article's full text forever, and — worse —
/// stood in front of any fresh download, so the article re-fetched on every run
/// and never got better. bmlib's issue #71 is the same finding.
final class FullTextCacheQuarantineTests: XCTestCase {
    private let pmid = "quarantine-test-99999"

    private var cachedFile: URL {
        FullTextService.pdfCacheDirectory
            .appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
    }

    private var quarantinedFile: URL {
        cachedFile.appendingPathExtension("corrupt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cachedFile)
        try? FileManager.default.removeItem(at: quarantinedFile)
        super.tearDown()
    }

    func testAValidPDFIsReturnedUntouched() throws {
        try Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]).write(to: cachedFile)
        XCTAssertEqual(FullTextService.cachedPDFPath(for: pmid), cachedFile.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    func testAnEmptyEntryIsQuarantinedAndReadsAsAbsent() throws {
        try Data().write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: cachedFile.path),
            "it must not stand in front of the next download"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: quarantinedFile.path),
            "moved aside rather than deleted, so an operator can look at it"
        )
    }

    func testAnEntryThatIsNotAPDFIsQuarantined() throws {
        try Data("<html>404 not found</html>".utf8).write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    func testAnAbsentEntryIsSimplyAbsent() {
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinedFile.path))
    }

    /// A second corrupt entry replaces the first rather than failing the read:
    /// `replaceItemAt` overwrites, and a quarantine that threw would turn a
    /// recoverable miss into an error.
    func testASecondQuarantineOverwritesTheFirst() throws {
        try Data("first".utf8).write(to: quarantinedFile)
        try Data("second".utf8).write(to: cachedFile)
        XCTAssertNil(FullTextService.cachedPDFPath(for: pmid))
        XCTAssertEqual(try Data(contentsOf: quarantinedFile), Data("second".utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextCacheQuarantineTests`
Expected: `testAnEmptyEntryIsQuarantinedAndReadsAsAbsent` and `testAnEntryThatIsNotAPDFIsQuarantined` fail, because the path is returned for both. That is the defect reproduced.

- [ ] **Step 3: Validate and quarantine**

Replace `cachedPDFPath(for:)`:

```swift
    /// The cached PDF for a document, or `nil` when there is none usable.
    ///
    /// Validated rather than merely existence-checked. `downloadAndCachePDF`
    /// verifies the magic bytes on the way in and this did not check them on the
    /// way out, so an entry corrupted by anything outside this service — an
    /// interrupted restore, a sync eviction, a file written by an older build —
    /// was served as the article's full text forever.
    ///
    /// A failing entry is renamed rather than deleted, so it can be inspected,
    /// and the method answers `nil` so the next fetch re-downloads. Leaving it in
    /// place is the worse failure: it hides a freshly cached PDF behind it and
    /// the article re-downloads on every run for good. bmlib's issue #71 reaches
    /// the same conclusion.
    ///
    /// Best-effort: a rename that itself fails is logged and the read still
    /// answers `nil`, because turning a recoverable miss into a thrown error
    /// helps nobody.
    ///
    /// - Parameter pmid: PubMed ID to check.
    /// - Returns: The cached file's path, or `nil` if there is none or it was
    ///   unusable.
    public static func cachedPDFPath(for pmid: String) -> String? {
        let fileURL = pdfCacheDirectory
            .appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let magic = Data(BioMedLitConstants.pdfMagicBytes)
        let handle = try? FileHandle(forReadingFrom: fileURL)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: magic.count)) ?? nil

        if let head, head == magic { return fileURL.path }

        BioMedLitLib.logger?.warning(
            "Cached PDF for PMID \(pmid) is not a PDF; quarantining it so the next "
                + "fetch re-downloads instead of serving it forever",
            category: .fullText
        )
        let aside = fileURL.appendingPathExtension("corrupt")
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            BioMedLitLib.logger?.error(
                "Could not quarantine the corrupt cached PDF for PMID \(pmid): "
                    + "\(error.localizedDescription)",
                category: .fullText
            )
        }
        return nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path Packages/BioMedLit --filter FullTextCacheQuarantineTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Run the whole package suite**

Run: `swift test --package-path Packages/BioMedLit`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift \
        Packages/BioMedLit/Tests/BioMedLitTests/FullTextCacheQuarantineTests.swift
git commit -m "fix(fulltext): a corrupt cache entry stops standing in for the article

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: The app's result type carries the three facts

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift:150-210`
- Modify: `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift`

**Interfaces:**
- Consumes: `FullTextContentKind` from Task 1.
- Produces:
  - `AppFullTextResult.contentKind: FullTextContentKind`, `.extractedText: String?`, `.localPDFPath: String?`
  - `AppFullTextResult.init(content:source:warnings:degradation:contentKind:extractedText:localPDFPath:)`, new parameters defaulted.
  - `BioMedLitAdapters.toAppFullTextResult` carries all three through.

- [ ] **Step 1: Find the adapter's current shape**

```bash
grep -n -A30 "func toAppFullTextResult" \
  ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift
```

Read it before editing: it maps `FullTextContent` cases to `AppFullTextContentType` cases, and the three new fields pass straight through beside that mapping.

- [ ] **Step 2: Add the three fields to `AppFullTextResult`**

After the `degradation` property:

```swift
    /// What this result's text actually is.
    ///
    /// `nil`-free because a result always holds one of the four kinds, but note
    /// this type carries no asserts about it, for the reason `degradation`
    /// documents: it is built from persisted values as well as live ones, and a
    /// record written by a newer build must decode rather than crash a debug
    /// build.
    let contentKind: FullTextContentKind

    /// Prose recovered from a PDF, or `nil` when none was.
    ///
    /// This is what transparency analysis and report generation read for a
    /// PDF-sourced article. `content` stays the PDF, because extraction recovers
    /// the prose and loses the figures, tables and layout.
    let extractedText: String?

    /// Where the downloaded PDF now is on disk, or `nil` when none was cached.
    let localPDFPath: String?
```

and extend the initializer, keeping its existing documentation and adding:

```swift
        contentKind: FullTextContentKind = .none,
        extractedText: String? = nil,
        localPDFPath: String? = nil
```

with the three matching assignments.

- [ ] **Step 3: Carry them through the adapter**

In `toAppFullTextResult`, pass the three fields from the `BioMedLit.FullTextResult` into the `AppFullTextResult` initializer:

```swift
            contentKind: result.contentKind,
            extractedText: result.extractedText,
            localPDFPath: result.localPDFPath
```

- [ ] **Step 4: Build the app**

Run:

```bash
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' build 2>&1 | tail -20
```

Expected: `BUILD SUCCEEDED`. If the scheme name differs, list them with `xcodebuild -list -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj` and use the app scheme.

- [ ] **Step 5: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Models/FullTextSource.swift \
        ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift
git commit -m "feat(fulltext): carry the content kind and extracted text into the app

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: The document stores it, and the reader still gets the PDF

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift:177`, `:498-533`, `:576-594`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift:47`
- Test: `ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift`

**Interfaces:**
- Consumes: `AppFullTextResult`'s three fields from Task 7.
- Produces:
  - `Document.fullTextContentKindRaw: String?`
  - `Document.storedContentKind: FullTextContentKind?`, private
  - `TransparencyConstants.analyzerVersion == 3`

- [ ] **Step 1: Write the failing tests**

Append to `ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift`:

```swift
    // MARK: - Extracted PDF text

    /// The whole point of the slice: a PDF-sourced article now has text for the
    /// transparency analyzer, which used to receive `nil`.
    func testAnExtractedResultStoresItsTextAndItsLocalPath() {
        let document = makeDocument()
        document.applyFullTextResult(AppFullTextResult(
            content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
            source: .unpaywall,
            contentKind: .extracted,
            extractedText: "Recovered prose.",
            localPDFPath: "/tmp/a.pdf"
        ))
        XCTAssertEqual(document.fullTextContent, "Recovered prose.")
        XCTAssertEqual(
            document.fullTextPDFPath, "/tmp/a.pdf",
            "the cached file, not the remote URL the field used to be given"
        )
        XCTAssertEqual(document.fullTextContentKindRaw, "extracted")
    }

    /// Extraction serves analysis; display still prefers the document.
    /// `cachedFullTextResult` tests `fullTextContent` before `fullTextPDFPath`,
    /// so without a kind-first branch every PDF-sourced article would reopen as
    /// prose and lose its figures, tables and layout.
    func testAnExtractedRecordReopensAsThePDFAndNotAsText() {
        let document = makeDocument()
        document.applyFullTextResult(AppFullTextResult(
            content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
            source: .unpaywall,
            contentKind: .extracted,
            extractedText: "Recovered prose.",
            localPDFPath: "/tmp/a.pdf"
        ))
        let rebuilt = document.cachedFullTextResult
        XCTAssertNotNil(rebuilt?.content.pdfURL, "the viewer must get the PDF back")
        XCTAssertEqual(rebuilt?.content.pdfURL?.path, "/tmp/a.pdf")
        XCTAssertEqual(
            rebuilt?.extractedText, "Recovered prose.",
            "and the analyzer must still reach the text"
        )
    }

    /// A record written before this field existed keeps today's behaviour:
    /// `nil` means "nothing known", not "no text".
    func testALegacyRecordKeepsFieldPopulationOrder() {
        let document = makeDocument()
        document.fullTextContent = "markdown from an older build"
        document.fullTextSource = "europepmc"
        document.fullTextFetchedAt = Date()
        XCTAssertNil(document.fullTextContentKindRaw)
        XCTAssertEqual(document.cachedFullTextResult?.content.markdownContent, "markdown from an older build")
    }

    /// A parsed article is unaffected, and its kind is recorded.
    func testAParsedArticleStoresTheFulltextKind() {
        let document = makeDocument()
        document.applyFullTextResult(AppFullTextResult(
            content: .html(content: "<p>body</p>", markdown: "body"),
            source: .europePMC,
            contentKind: .fulltext
        ))
        XCTAssertEqual(document.fullTextContentKindRaw, "fulltext")
        XCTAssertNil(document.fullTextPDFPath)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:

```bash
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' \
  -only-testing:MedicalFactCheckerTests/FullTextParseWarningsTests test 2>&1 | tail -30
```

Expected: compile failure, `Document` has no member `fullTextContentKindRaw`.

- [ ] **Step 3: Add the stored field and its reader**

In `Document.swift`, beside `fullTextDegradedReasonRaw`:

```swift
    /// What the stored full text actually is, as a ``FullTextContentKind`` raw
    /// value.
    ///
    /// `nil` means "written before this field existed", which is not the same as
    /// ``FullTextContentKind/none``: such a record's text may be an article
    /// body, an abstract-only deposit, or nothing, and there is no way to tell
    /// after the fact. Those records keep the old field-population behaviour and
    /// are rewritten on the next fetch. A required field would instead strand
    /// every one of them behind a decode failure that reads as "never fetched" —
    /// the reasoning `fullTextDegradedReasonRaw` was added with.
    var fullTextContentKindRaw: String?
```

and beside `storedDegradation`:

```swift
    /// The persisted content kind, or `nil` for a record that predates it.
    ///
    /// An unrecognised value — a record written by a newer build — reads as
    /// `nil` rather than as a guess, so it falls back to field-population order
    /// instead of claiming a kind this build does not understand.
    private var storedContentKind: FullTextContentKind? {
        guard let raw = fullTextContentKindRaw else { return nil }
        if let known = FullTextContentKind(rawValue: raw) { return known }
        documentLog.error(
            """
            Unrecognised full-text content kind \(raw, privacy: .public) stored for PMID \
            \(self.pmid, privacy: .public); falling back to field-population order.
            """
        )
        return nil
    }
```

- [ ] **Step 4: Store it, and store the local path**

In `applyFullTextResult`, after the `fullTextDegradedReasonRaw` assignment:

```swift
        fullTextContentKindRaw = result.contentKind.rawValue
```

and replace the `.pdfURL` case:

```swift
        case .pdfURL(let url):
            // The cached file when there is one, so the viewer opens a real
            // path. Before extraction existed this held the *remote URL*, which
            // read as "retrieved" and was handed to `URL(string:)` by every
            // consumer that thought it had a file. The remote URL falls back
            // only when nothing was downloaded, which is what the extraction
            // flag being off looks like.
            fullTextPDFPath = result.localPDFPath ?? url.absoluteString
            // Prose recovered from the PDF, which is what transparency analysis
            // and report generation read. `nil` for a scan or a failed
            // extraction, exactly as before.
            fullTextContent = result.extractedText
            fullTextHTML = nil
```

Add `fullTextContentKindRaw = nil` to both `markFullTextUnavailable()` and `clearFullTextCache()`, beside the other cleared fields.

- [ ] **Step 5: Branch reconstruction on the kind**

Replace the content selection in `cachedFullTextResult`:

```swift
        let content: AppFullTextContentType
        if storedContentKind == .extracted, let path = fullTextPDFPath {
            // Display prefers the document. Extraction serves *analysis*: the
            // recovered prose has no figures, tables or layout, so reopening a
            // PDF-sourced article as text loses the reason the PDF was kept.
            // Note this branch has to come first — the text is also populated,
            // and the field-population order below would take it.
            content = .pdfURL(URL(fileURLWithPath: path))
        } else if let html = fullTextHTML {
            content = .html(content: html, markdown: fullTextContent ?? "")
        } else if let markdown = fullTextContent {
            content = .markdown(markdown)
        } else if let path = fullTextPDFPath, let url = URL(string: path) {
            content = .pdfURL(url)
        } else {
            return nil
        }
        return AppFullTextResult(
            content: content,
            source: source,
            warnings: storedParseWarnings,
            degradation: storedDegradation,
            contentKind: storedContentKind ?? .none,
            extractedText: storedContentKind == .extracted ? fullTextContent : nil,
            localPDFPath: storedContentKind == .extracted ? fullTextPDFPath : nil
        )
```

The last `else if` keeps `URL(string:)` deliberately: it is the legacy branch, and a legacy record's stored value is a remote URL string.

- [ ] **Step 6: Bump the analyzer version**

In `TransparencyConstants.swift`, change `analyzerVersion` from `2` to `3` and extend its documentation:

```swift
    /// - Version 3 (2026-09-09): a downloaded PDF now contributes its extracted
    ///   text, where the analyzer previously received `nil` for every
    ///   PDF-sourced article; and an abstract-only Europe PMC deposit is no
    ///   longer handed over as an article body. Both change which evidence
    ///   reaches the scorer, in opposite directions.
    public static let analyzerVersion = 3
```

- [ ] **Step 7: Run the tests to verify they pass**

Run:

```bash
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' \
  -only-testing:MedicalFactCheckerTests/FullTextParseWarningsTests test 2>&1 | tail -30
```

Expected: all tests pass, including the four new ones.

- [ ] **Step 8: Run the app's whole suite and the package's**

```bash
swift test --package-path Packages/BioMedLit
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: both pass. `AnalyzerVersionTests` compares against `TransparencyConstants.analyzerVersion` rather than a literal, so the bump needs no test change. If it fails, the failure is real and not a pinned constant.

- [ ] **Step 9: Commit**

```bash
git add ios/MedicalFactChecker/Sources/Models/Document.swift \
        ios/MedicalFactChecker/Tests/FullTextParseWarningsTests.swift \
        Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift
git commit -m "feat(fulltext): store the extracted text, and keep showing the PDF

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: The docs say what changed

**Files:**
- Modify: `doc/cross_platform/ios_bmlib_alignment.md`, §3 and §7
- Modify: `doc/cross_platform/fulltext_retrieval.md`
- Modify: `HANDOVER.md`

**Interfaces:**
- Consumes: everything above.
- Produces: no code.

- [ ] **Step 1: Correct and update the alignment doc**

In §3's table, mark as done: "PDF → text extraction", "Body-less JATS detection / `content_kind`", "Corrupt-entry quarantine". Leave the NCBI efetch tier, the second PMC-id resolver, PDF section segmentation and exhaustion reporting marked as gaps; they are the next slice.

Add a short subsection recording the two corrections, in the voice the rest of the file uses:

- The "Cache writes are not atomic" paragraph is wrong. `cachePDF` has always called `data.write(to:options: .atomic)`, so bmlib's issue #70 failure — a disk filling mid-write and leaving a truncated file served as complete — is not reachable through it. The real defect was on the read side, which validated nothing, and that is what was fixed.
- The claim that the missing PDF text costs "scoring, citation extraction and transparency analysis" is wrong about the first two. Neither `ParallelScoringService` nor `ParallelCitationService` reads `fullTextContent`; the cost lands on transparency analysis and report generation.

Record the deliberate deviation, beside the existing `plc` note:

- bmlib writes cache entries through a temp file with `fsync` before `os.replace`. Swift's `.atomic` gives temp-and-rename without the sync, so the residual exposure loses the file rather than truncating it, and the new read validation catches that. Hand-rolling an `fsync` write to reach the same safe outcome is not worth diverging from a platform primitive.

In §7, strike item 4 and note that items 5 onward are unchanged.

- [ ] **Step 2: Update the retrieval contract**

In `doc/cross_platform/fulltext_retrieval.md`, document the four content kinds with their raw values, the abstract holdback rule and why it exists, and the cache read validation with its quarantine suffix. This file is the cross-platform contract, so write it as rules Android will also have to satisfy, not as a description of the Swift code.

- [ ] **Step 3: Add a handover section**

Add an "In flight" or "Recently landed" section to `HANDOVER.md` recording the rules that still bind:

- **Extraction serves analysis; display prefers the document.** `cachedFullTextResult` must branch on the stored kind before field population, or every PDF-sourced article reopens as prose and loses its figures and layout.
- **An abstract-only deposit is held back, not returned.** Returning it on the spot made it beat every remaining tier.
- **A PDF tier succeeds as soon as it has a URL,** so a download or extraction that gave nothing must not discard an abstract already in hand.
- **`nil` content kind means "predates the field",** not `none`.

Then prune the file back under 500 lines, as its own header instructs.

- [ ] **Step 4: Verify the whole suite once more**

```bash
swift test --package-path Packages/BioMedLit
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' test 2>&1 | tail -20
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add doc/cross_platform/ios_bmlib_alignment.md \
        doc/cross_platform/fulltext_retrieval.md HANDOVER.md
git commit -m "docs(fulltext): record the extraction slice, and correct two claims

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Verification

After Task 9, the whole slice is verified by:

```bash
swift test --package-path Packages/BioMedLit
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker -destination 'platform=macOS' test
```

Both must pass before the branch is offered for review. Claim nothing about the
network-gated `JATSXMLParserIntegrationTests` unless they were actually run.
