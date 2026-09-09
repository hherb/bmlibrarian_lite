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
@testable import MedicalFactChecker

/// Answers one canned response, so the remote branch has offline coverage.
private final class StubPDFURLProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.response
        let http = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The iOS PDF viewer was an HTTP downloader with no file branch, and this
/// branch changed `fullTextPDFPath` from a remote URL string to a local
/// filesystem path. A `file://` URL through `URLSession` answers with a plain
/// `NSURLResponse`, so the `HTTPURLResponse` cast failed and every PDF-sourced
/// article reopened from the cache showed "bad server response" over an "Open
/// in Browser" link pointing at a `file:///` path.
final class PDFContentLoaderTests: XCTestCase {
    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25])

    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFContentLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        StubPDFURLProtocol.response = (200, Data())
        try super.tearDownWithError()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubPDFURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func writeFixture(named name: String, bytes: Data) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: - The regression

    /// The defect itself: a cached PDF is a file on disk, and reading it must
    /// not go through `URLSession`'s HTTP response cast.
    func testACachedFilePathIsReadFromDisk() async throws {
        let url = try writeFixture(named: "cached.pdf", bytes: Self.pdfBytes)

        let data = try await PDFContentLoader.loadData(from: url, session: makeSession())

        XCTAssertEqual(data, Self.pdfBytes)
    }

    /// The exact shape `Document.cachedFullTextResult` hands the viewer for a
    /// PDF-sourced article: a URL built with `URL(fileURLWithPath:)`.
    func testAFileURLBuiltFromAStoredPathLoads() async throws {
        let path = try writeFixture(named: "reopened.pdf", bytes: Self.pdfBytes).path

        let data = try await PDFContentLoader.loadData(
            from: URL(fileURLWithPath: path), session: makeSession()
        )

        XCTAssertEqual(data, Self.pdfBytes)
    }

    /// A missing cached file is not a server problem, and must not be reported
    /// as one — the reader's next move is to re-fetch, not to retry a host.
    func testAMissingCachedFileSaysSoRatherThanBlamingTheServer() async {
        let url = scratch.appendingPathComponent("absent.pdf")

        do {
            _ = try await PDFContentLoader.loadData(from: url, session: makeSession())
            XCTFail("a missing file should not load")
        } catch let error as PDFContentLoader.LoadError {
            XCTAssertEqual(error, .fileMissing)
        } catch {
            XCTFail("expected a LoadError, got \(error)")
        }
    }

    /// Validation applies to a cached entry too: an entry corrupted outside
    /// this app must not render as an article.
    func testACachedFileThatIsNotAPDFIsRejected() async throws {
        let url = try writeFixture(named: "notapdf.pdf", bytes: Data("<html>404</html>".utf8))

        do {
            _ = try await PDFContentLoader.loadData(from: url, session: makeSession())
            XCTFail("a non-PDF should not load")
        } catch let error as PDFContentLoader.LoadError {
            XCTAssertEqual(error, .notAPDF)
        } catch {
            XCTFail("expected a LoadError, got \(error)")
        }
    }

    // MARK: - The remote path still works

    /// The negative control: a live result whose tier returned a link without
    /// downloading it — what the extraction flag being off looks like — still
    /// fetches over HTTP.
    func testARemoteURLStillLoadsOverHTTP() async throws {
        StubPDFURLProtocol.response = (200, Self.pdfBytes)

        let data = try await PDFContentLoader.loadData(
            from: URL(string: "https://example.org/a.pdf")!, session: makeSession()
        )

        XCTAssertEqual(data, Self.pdfBytes)
    }

    func testARemoteErrorStatusIsAServerProblem() async {
        StubPDFURLProtocol.response = (404, Data())

        do {
            _ = try await PDFContentLoader.loadData(
                from: URL(string: "https://example.org/a.pdf")!, session: makeSession()
            )
            XCTFail("a 404 should not load")
        } catch let error as PDFContentLoader.LoadError {
            XCTAssertEqual(error, .badServerResponse)
        } catch {
            XCTFail("expected a LoadError, got \(error)")
        }
    }
}
