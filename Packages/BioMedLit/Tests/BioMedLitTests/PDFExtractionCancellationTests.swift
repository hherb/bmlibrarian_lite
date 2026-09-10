// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import XCTest
@testable import BioMedLit

/// Cancels the enclosing task from inside the extractor, then returns a partial
/// result — the shape `PDFKitTextExtractor` produces when its page loop breaks
/// early.
private struct CancellingExtractor: PDFTextExtracting {
    let onExtract: @Sendable () -> Void
    let result: PDFExtractionResult

    func extract(from fileURL: URL) -> PDFExtractionResult {
        onExtract()
        return result
    }
}

/// A cancelled read is not a short document.
///
/// The extractor stops mid-document when its task is cancelled, so without a
/// cancellation check on the way out, the partial value it returns is
/// indistinguishable from a genuine partial extraction — and would be cached and
/// shown as this article's text, with a coverage figure describing how far the
/// reader got before walking away.
final class PDFExtractionCancellationTests: XCTestCase {
    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])
    private static let pmid = "cancel-test-99401"

    /// The name this article's cached PDFs are filed under.
    private static let cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
        super.tearDown()
    }

    /// Cancellation arriving during *extraction* — after the bytes have landed,
    /// so no transport error can carry it — must still reach the caller as
    /// `CancellationError` rather than as a result.
    func testCancellationDuringExtractionPropagatesRatherThanReturningPartialText() async throws {
        StubURLProtocol.routes = [
            "unpaywall": (
                200,
                Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/a.pdf"}}"#.utf8)
            ),
            "a.pdf": (200, Self.pdfBytes),
        ]

        // Set once the task exists, so the extractor can cancel the very task it
        // is running inside.
        let box = TaskBox()
        let extractor = CancellingExtractor(
            onExtract: { box.cancel() },
            result: PDFExtractionResult(
                text: "half an article", success: true, pageCount: 20, convertedPages: 4,
                warnings: []
            )
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor
        )

        let task = Task {
            try await service.fetchFullText(pmcId: "PMC1", doi: "10.1/x", pmid: Self.pmid)
        }
        box.store(task)

        do {
            _ = try await task.value
            XCTFail("a cancelled extraction must not return a result")
        } catch is CancellationError {
            // The outcome under test.
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}

/// Holds the task under test so the extractor can cancel it from inside.
///
/// A class rather than a captured `var` because the extractor's closure is
/// `@Sendable` and runs while the task is still being awaited.
private final class TaskBox: @unchecked Sendable {
    private var task: Task<FullTextResult, Error>?
    private var cancelRequested = false
    private let lock = NSLock()

    /// Cancels immediately if the request arrived first.
    ///
    /// In practice the task suspends on the network before the extractor runs,
    /// so `store` always wins — but a test that depends on which of two threads
    /// gets there first is a test that fails on someone else's machine.
    func store(_ task: Task<FullTextResult, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelRequested { task.cancel() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelRequested = true
        task?.cancel()
    }
}
