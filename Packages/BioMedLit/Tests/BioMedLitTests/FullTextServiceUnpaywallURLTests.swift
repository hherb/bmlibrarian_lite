// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// A transport that answers everything alike and remembers what it was asked.
///
/// ``StubURLProtocol`` serves bodies but discards the request, and the request
/// is the whole subject here: what matters is the URL the email ends up in, not
/// what Unpaywall says back.
final class RecordingURLProtocol: URLProtocol {
    /// Every URL requested through this protocol, in order.
    nonisolated(unsafe) static var requested: [URL] = []

    static func reset() { requested = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requested.append(url) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The Unpaywall request carries the user's email, and how it is spelled into
/// the URL is both a correctness question and the reason CodeQL flags the call
/// (`swift/cleartext-transmission`).
final class FullTextServiceUnpaywallURLTests: XCTestCase {
    override func setUp() {
        super.setUp()
        RecordingURLProtocol.reset()
    }

    override func tearDown() {
        RecordingURLProtocol.reset()
        super.tearDown()
    }

    private func service(email: String) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: email,
            session: session,
            europePMCService: EuropePMCService(session: session)
        )
    }

    /// The URL the email is sent in, for a plain address.
    private func unpaywallRequest(email: String) async -> URL? {
        _ = try? await service(email: email)
            .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")
        return RecordingURLProtocol.requested.first { $0.host == "api.unpaywall.org" }
    }

    func testTheRequestIsHTTPS() async throws {
        let requested = await unpaywallRequest(email: "researcher@example.org")
        let url = try XCTUnwrap(requested)

        XCTAssertEqual(url.scheme, "https")
    }

    func testTheEmailArrivesAsTheEmailQueryItem() async throws {
        let requested = await unpaywallRequest(email: "researcher@example.org")
        let url = try XCTUnwrap(requested)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(
            components.queryItems?.first { $0.name == "email" }?.value,
            "researcher@example.org"
        )
    }

    /// Every character `queryValueAllowed` exists to escape, and what goes wrong
    /// if it does not.
    ///
    /// `+` is the one URLComponents will not save you from: `URLQueryItem`
    /// leaves it alone and raw in a query it decodes to a space, so Unpaywall is
    /// told the caller is `name tag@example.org` -- someone else. `&` and `=`
    /// are worse: they let the value split itself into query items nobody asked
    /// for. The rest are here so the set cannot quietly shrink.
    func testDelimitersInTheAddressAreEscapedAndSurviveTheRoundTrip() async throws {
        let addresses = [
            "name+tag@example.org",
            "a&b=c@example.org",
            "x#y@example.org",
            "100%pure@example.org",
            "a b@example.org",
            "wär@exämple.org",
        ]

        for address in addresses {
            RecordingURLProtocol.reset()
            let requested = await unpaywallRequest(email: address)
            let url = try XCTUnwrap(requested, "no request for \(address)")
            let rawQuery = try XCTUnwrap(url.query(percentEncoded: true))
            // Drop the "email=" separator so only the value is inspected.
            let rawValue = rawQuery.dropFirst("email=".count)

            // On the wire: nothing that could be read as a delimiter or a space.
            for delimiter in ["+", "&", "=", "#", " "] {
                XCTAssertFalse(
                    rawValue.contains(delimiter),
                    "\(delimiter) left bare for \(address): \(rawQuery)"
                )
            }

            // And after decoding: exactly the address that was configured.
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(
                components.queryItems?.first { $0.name == "email" }?.value,
                address,
                "round trip changed the address"
            )
        }
    }

    /// An unset address must be named as such, not left to Unpaywall.
    ///
    /// Unpaywall answers 422 for a missing email, which the caller renders as
    /// "no full text available" -- an outage dressed up as an absent PDF.
    func testAnEmptyAddressIsRejectedBeforeTheRequest() async {
        _ = try? await service(email: "   ")
            .fetchFullText(pmcId: nil, doi: "10.1234/example", pmid: "1")

        XCTAssertNil(
            RecordingURLProtocol.requested.first { $0.host == "api.unpaywall.org" },
            "an empty address must not reach Unpaywall"
        )
    }

    /// The DOI still reaches the path it belongs in, unmangled by the move to
    /// URLComponents.
    func testTheDOIStaysInThePath() async throws {
        let requested = await unpaywallRequest(email: "researcher@example.org")
        let url = try XCTUnwrap(requested)

        XCTAssertEqual(url.path, "/v2/10.1234/example")
    }
}
