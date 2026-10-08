// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// Loads the shared Elsevier contract (#480, stage C2).
enum ElsevierContract {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/elsevier_article.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            // `.git` is a directory in a normal checkout and a file in a worktree.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return nil }
            directory = parent
        }
    }()

    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(contractFile, "elsevier_article.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// Elsevier's pure rules and session state, read from the contract all three
/// platforms share: `doc/cross_platform/fulltext_parity/elsevier_article.json`.
final class ElsevierContractTests: XCTestCase {
    private var contract: [String: Any] = [:]

    override func setUpWithError() throws {
        contract = try ElsevierContract.load()
    }

    private func table(_ name: String, minimum: Int) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(contract[name] as? [[String: Any]], name)
        XCTAssertGreaterThanOrEqual(rows.count, minimum, "\(name) lost rows")
        return rows
    }

    // MARK: - The tables and the names

    /// A table added to the contract and asserted nowhere would pin nothing.
    func testEveryContractTableIsReadHere() {
        XCTAssertEqual(Set(contract.keys), [
            "schema_version", "description", "service_name", "source", "source_label",
            "desktop_source_type", "base_url", "doi_prefix", "pause_after_consecutive_429",
            "key_refused_status", "key_refused_reason", "network_refused_status",
            "network_refused_token", "network_refused_reason", "first_page_header",
            "first_page_prefix", "error_body_max_bytes", "follows_redirects", "requests_per_second",
            "eligible", "article_url", "sendable", "answers", "session",
        ])
    }

    func testTheNamesAreTheContracts() {
        XCTAssertEqual(contract["service_name"] as? String, BioMedLitConstants.elsevierServiceName)
        XCTAssertEqual(BioMedLitConstants.elsevierServiceName, "Elsevier's API")
        XCTAssertEqual(contract["source"] as? String, OpenAccessSource.elsevier.rawValue)
        XCTAssertEqual(OpenAccessSource.elsevier.rawValue, "elsevier")
        XCTAssertEqual(OpenAccessSource.elsevier.serviceName, BioMedLitConstants.elsevierServiceName)
        XCTAssertEqual(contract["source_label"] as? String, BioMedLitConstants.elsevierSourceLabel)
        XCTAssertEqual(BioMedLitConstants.elsevierSourceLabel, "Elsevier's API (PDF)")
        // The desktop's own type; the apps have no counterpart, so it is pinned as read
        XCTAssertEqual(contract["desktop_source_type"] as? String, "elsevier_api")
    }

    func testTheConstantsAreTheContracts() throws {
        XCTAssertEqual(contract["base_url"] as? String, BioMedLitConstants.elsevierBaseURL)
        XCTAssertEqual(contract["doi_prefix"] as? String, BioMedLitConstants.elsevierDOIPrefix)
        XCTAssertEqual(
            contract["pause_after_consecutive_429"] as? Int,
            BioMedLitConstants.elsevierPauseAfterConsecutive429
        )
        XCTAssertEqual(contract["key_refused_status"] as? Int, BioMedLitConstants.elsevierKeyRefusedStatus)
        // The words are shared with CORE's refused key, so the reason reads one way
        XCTAssertEqual(contract["key_refused_reason"] as? String, BioMedLitConstants.coreKeyRefusedReason)
        XCTAssertEqual(OpenAccessUnsettledReason.keyRefused.described, contract["key_refused_reason"] as? String)
        XCTAssertEqual(
            contract["network_refused_status"] as? Int, BioMedLitConstants.elsevierNetworkRefusedStatus
        )
        XCTAssertEqual(
            contract["network_refused_token"] as? String, BioMedLitConstants.elsevierNetworkRefusedToken
        )
        XCTAssertEqual(
            contract["network_refused_reason"] as? String, BioMedLitConstants.elsevierNetworkRefusedReason
        )
        XCTAssertEqual(
            OpenAccessUnsettledReason.networkRefused.described, contract["network_refused_reason"] as? String
        )
        XCTAssertEqual(contract["first_page_header"] as? String, BioMedLitConstants.elsevierStatusHeader)
        XCTAssertEqual(contract["first_page_prefix"] as? String, BioMedLitConstants.elsevierWarningPrefix)
        XCTAssertEqual(contract["error_body_max_bytes"] as? Int, BioMedLitConstants.elsevierErrorBodyMaxBytes)
        // Never followed: a redirect would carry the key wherever it points
        XCTAssertEqual(contract["follows_redirects"] as? Bool, false)
        let perSecond = try XCTUnwrap(contract["requests_per_second"] as? Int)
        XCTAssertEqual(Double(perSecond), 1 / BioMedLitConstants.elsevierMinimumInterval)
        XCTAssertEqual(BioMedLitConstants.elsevierMinimumInterval, 0.5)
    }

    func testTheRetriesAreCOREs() {
        XCTAssertEqual(RetryConfiguration.elsevier.maxAttempts, 4)
        XCTAssertEqual(RetryConfiguration.elsevier.maxAttempts, RetryConfiguration.core.maxAttempts)
    }

    /// Elsevier is asked after Europe PMC's render and before any Unpaywall
    /// lookup, so it is told first among the tried sources.
    func testElsevierIsFirstInChainOrder() {
        XCTAssertEqual(OpenAccessShortfall.chainOrder.first, .elsevier)
        XCTAssertEqual(OpenAccessShortfall.chainOrder.last, .core)
        XCTAssertEqual(Set(OpenAccessShortfall.chainOrder), Set(OpenAccessSource.allCases))
    }

    // MARK: - Eligibility and the request

    func testEachEligibleRow() throws {
        for row in try table("eligible", minimum: 10) {
            let doi = try XCTUnwrap(row["doi"] as? String)
            XCTAssertEqual(Elsevier.isEligible(doi: doi), row["eligible"] as? Bool, "\(doi.debugDescription)")
        }
    }

    func testEachArticleURL() throws {
        for row in try table("article_url", minimum: 12) {
            let name = row["name"] as? String ?? "?"
            let doi = try XCTUnwrap(row["doi"] as? String, name)
            let base = row["base_url"] as? String ?? BioMedLitConstants.elsevierBaseURL
            XCTAssertEqual(
                Elsevier.articleURL(doi: doi, baseURL: base)?.absoluteString, row["url"] as? String, name
            )
        }
    }

    func testTheArticleURLDefaultsToElseviersBase() throws {
        let url = try XCTUnwrap(Elsevier.articleURL(doi: "10.1016/j.x.1"))
        XCTAssertEqual(url.absoluteString, "https://api.elsevier.com/content/article/doi/10.1016/j.x.1")
    }

    /// Only printable ASCII is ever sent as the key or the token.
    func testEachSendableRow() throws {
        for row in try table("sendable", minimum: 11) {
            let name = row["name"] as? String ?? "?"
            let key = try XCTUnwrap(row["key"] as? String, name)
            let token = row["token"] as? String
            XCTAssertEqual(Elsevier.isSendable(key: key, token: token), row["sendable"] as? Bool, name)
        }
    }

    // MARK: - Classifying one answer

    /// A body that starts `%PDF-1.7` and a newline, then some bytes, as the contract says.
    private static let pdfBody = Data("%PDF-1.7\n".utf8) + Data([0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A, 0x31])

    /// The body a row describes.
    private func body(_ row: [String: Any]) -> Data {
        if row["body_pdf"] as? Bool == true { return Self.pdfBody }
        let padding = row["body_padding_bytes"] as? Int ?? 0
        return Data(repeating: UInt8(ascii: " "), count: padding) + Data((row["body_text"] as? String ?? "").utf8)
    }

    /// The contract's outcome name for an answer, and its failure when unreachable.
    private func outcome(_ answer: ElsevierAnswer) -> (String, RequestFailure?) {
        switch answer {
        case .served: return ("served", nil)
        case .absent, .firstPageOnly: return ("absent", nil)
        case .unreachable(let failure): return ("unreachable", failure)
        case .keyRefused: return ("key_refused", nil)
        case .networkRefused: return ("network_refused", nil)
        }
    }

    /// Assert an answer is the outcome a row expects, its failure's kind and status included.
    private func assertOutcome(
        _ answer: ElsevierAnswer, _ row: [String: Any], status: Int?, _ name: String
    ) {
        let (got, failure) = outcome(answer)
        XCTAssertEqual(got, row["outcome"] as? String, name)
        XCTAssertEqual(failure?.kind.rawValue, row["failure_kind"] as? String, name)
        if failure?.kind == .httpStatus {
            XCTAssertEqual(failure?.statusCode, status, name)
        } else if let failure {
            XCTAssertNil(failure.statusCode, name)
        }
    }

    func testEachAnswer() throws {
        for row in try table("answers", minimum: 24) {
            let name = row["name"] as? String ?? "?"
            let status = try XCTUnwrap(row["status"] as? Int, name)
            let headers = try XCTUnwrap(row["headers"] as? [String: String], name)
            let answer = Elsevier.classify(status: status, headers: headers, body: body(row))
            assertOutcome(answer, row, status: status, name)
        }
    }

    /// The first page is told apart from a 404, so it can be logged as such;
    /// both are absences.
    func testTheFirstPageIsToldApartFromNoArticle() {
        let warning = [BioMedLitConstants.elsevierStatusHeader: "WARNING - first page"]
        XCTAssertEqual(Elsevier.classify(status: 200, headers: warning, body: Self.pdfBody), .firstPageOnly)
        XCTAssertEqual(Elsevier.classify(status: 404, headers: [:], body: Data()), .absent)
        // The control: the warning reads only on a 200
        XCTAssertEqual(
            Elsevier.classify(status: 404, headers: warning, body: Data()), .absent
        )
    }

    // MARK: - What one fetch leaves for the next

    /// One fetch of the contract's session table: the checks that make no
    /// request, then the answer classified and its ending recorded.
    ///
    /// - Returns: Whether a request was made, and the answer.
    private func fetch(
        _ session: KeyedServiceSession, _ step: [String: Any], _ name: String
    ) throws -> (asked: Bool, answer: ElsevierAnswer) {
        let credentials = try XCTUnwrap(step["credentials"] as? [String: Any], name)
        let key = try XCTUnwrap(credentials["key"] as? String, name)
        let token = credentials["token"] as? String
        let keyDigest = KeyDigest.key(key)
        let credentialsDigest = KeyDigest.credentials(key: key, token: token)
        if let unasked = Elsevier.answerWithoutAsking(
            session: session, keyDigest: keyDigest, credentialsDigest: credentialsDigest,
            sendable: Elsevier.isSendable(key: key, token: token)
        ) {
            return (false, unasked)
        }
        let status = try XCTUnwrap(step["status"] as? Int, name)
        let answer = Elsevier.classify(
            status: status, headers: [:], body: Data((step["body_text"] as? String ?? "").utf8)
        )
        Elsevier.record(
            answer, endedOn: status, in: session, keyDigest: keyDigest, credentialsDigest: credentialsDigest
        )
        return (true, answer)
    }

    func testEachSessionRow() throws {
        for row in try table("session", minimum: 11) {
            let name = row["name"] as? String ?? "?"
            let session = ElsevierSession()
            for step in try XCTUnwrap(row["fetches"] as? [[String: Any]], name) {
                _ = try fetch(session, step, name)
            }
            let checks = try XCTUnwrap(row["then"] as? [[String: Any]], name)
            XCTAssertFalse(checks.isEmpty, name)
            for (index, check) in checks.enumerated() {
                let label = "\(name), check \(index)"
                let (asked, answer) = try fetch(session, check, label)
                XCTAssertEqual(asked, check["asked"] as? Bool, label)
                assertOutcome(answer, check, status: check["status_code"] as? Int, label)
            }
        }
    }

    /// The session is Elsevier's own: a CORE 429 never pauses Elsevier, nor
    /// the reverse, and each keeps its own refused key.
    func testTheSessionSharesNothingWithCOREs() {
        let core = CoreThrottle(pauseAfter: 2)
        let elsevier = ElsevierSession(pauseAfter: 2)
        let digest = KeyDigest.key("shared-key")
        core.record(endedOn: 429, keyDigest: digest)
        core.record(endedOn: 429, keyDigest: digest)
        core.record(endedOn: 401, keyDigest: digest)
        XCTAssertTrue(core.isPaused)
        XCTAssertFalse(elsevier.isPaused)
        XCTAssertFalse(elsevier.refuses(keyDigest: digest))
    }

    /// A refusal from this network is an ending: it resets the 429 count and
    /// refuses no key.
    func testANetworkRefusalResetsThe429Count() {
        let session = ElsevierSession(pauseAfter: 2)
        let key = KeyDigest.key("key-A")
        let credentials = KeyDigest.credentials(key: "key-A", token: nil)
        session.record(endedOn: 429, keyDigest: key)
        session.recordNetworkRefused(credentialsDigest: credentials)
        session.record(endedOn: 429, keyDigest: key)
        XCTAssertFalse(session.isPaused)
        XCTAssertTrue(session.refusesNetwork(credentialsDigest: credentials))
        XCTAssertFalse(session.refuses(keyDigest: key), "a network refusal is no refused key")
    }

    // MARK: - The fingerprints

    func testTheCredentialsAreHeldAsADigestOfKeyNewlineToken() {
        // Python's credentials_digest of the same credentials, so the platforms agree
        XCTAssertEqual(
            KeyDigest.credentials(key: "key-A", token: nil),
            "50b21231d19454abde7269149737076b5236197952c14f0028ab4d0a057c2fee"
        )
        XCTAssertEqual(
            KeyDigest.credentials(key: " key-A\n", token: " token-T "),
            "aaf6f589b9c34c106a1fd1f05d29ab067708fe5f7704217d4c663c747ac55048"
        )
        // A blank token is no token
        XCTAssertEqual(
            KeyDigest.credentials(key: "key-A", token: "  "),
            KeyDigest.credentials(key: "key-A", token: nil)
        )
        let digest = KeyDigest.credentials(key: "key-A", token: "token-T")
        XCTAssertFalse(digest.contains("key-A") || digest.contains("token-T"))
    }

    func testTheKeyDigestIsCOREs() {
        XCTAssertEqual(KeyDigest.key("  test-core-key\n"), CORE.keyDigest("test-core-key"))
        XCTAssertEqual(
            CORE.keyDigest("test-core-key"),
            "648a20094c7319271078b3f552cac0ce0f0f84c812ee4be3b825f6a3e489be68"
        )
    }
}
