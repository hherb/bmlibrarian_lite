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

/// What the reader is told about an open-access copy that went unassessed, and
/// how a document stores it, read from the contract all three platforms share
/// (#466): `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`.
final class OpenAccessShortfallContractTests: XCTestCase {

    private enum ContractError: Error {
        case notFound(origin: String)
        case malformed(String)
    }

    /// The contract file, read from the repository. The walk stops at the
    /// checkout root, as `UnpaywallLandingPageContractTests.contractFile` does.
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            // `.git` is a directory in a normal checkout and a file in a worktree.
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private func loadContract() throws -> [String: Any] {
        guard let file = Self.contractFile else {
            throw ContractError.notFound(origin: #filePath)
        }
        guard let contract = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            as? [String: Any] else {
            throw ContractError.malformed("the contract")
        }
        return contract
    }

    private func persistedTable(_ name: String) throws -> [[String: Any]] {
        guard let persisted = try loadContract()["persisted"] as? [String: Any],
              let rows = persisted[name] as? [[String: Any]] else {
            throw ContractError.malformed("persisted.\(name)")
        }
        return rows
    }

    /// The shortfall a row names by its `source`, `kind` and `status_code`, or
    /// by `skipped` for a lookup that was never made.
    private func shortfall(_ row: [String: Any]) throws -> OpenAccessShortfall {
        let source = try XCTUnwrap(
            (row["source"] as? String).flatMap(OpenAccessSource.init(rawValue:)), "\(row)"
        )
        if let skipped = row["skipped"] as? String {
            switch skipped {
            case "not_configured":
                XCTAssertEqual(source, .unpaywall, "\(row)")
                return .unpaywallNotConfigured
            case "key_refused":
                // CORE's or Elsevier's, as the row names it (#480, stage C2)
                switch source {
                case .core: return .coreKeyRefused
                case .elsevier: return .elsevierKeyRefused
                default: throw ContractError.malformed("a key_refused skip of \(source) in \(row)")
                }
            case "network_refused":
                XCTAssertEqual(source, .elsevier, "\(row)")
                return .elsevierNetworkRefused
            default:
                throw ContractError.malformed("an unknown skip in \(row)")
            }
        }
        let kind = try XCTUnwrap(
            (row["kind"] as? String).flatMap(RequestFailureKind.init(rawValue:)), "\(row)"
        )
        return OpenAccessShortfall(
            source: source,
            failure: RequestFailure.restored(kind: kind, statusCode: row["status_code"] as? Int)
        )
    }

    func testEachSourceIsNamedAsPythonNamesIt() throws {
        let sources = try XCTUnwrap(loadContract()["sources"] as? [String: String])

        XCTAssertEqual(Set(sources.keys), Set(OpenAccessSource.allCases.map(\.rawValue)))
        for source in OpenAccessSource.allCases {
            XCTAssertEqual(source.serviceName, sources[source.rawValue], source.rawValue)
        }
    }

    func testEachNoticeRow() throws {
        let rows = try XCTUnwrap(loadContract()["notices"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(rows.count, 10, "an empty table would pass vacuously")
        for row in rows {
            XCTAssertEqual(try shortfall(row).notice, row["notice"] as? String, "\(row)")
        }
        XCTAssertTrue(
            rows.contains { $0["skipped"] as? String == "not_configured" },
            "a skip row pins the not-configured sentence"
        )
        XCTAssertTrue(
            rows.contains { $0["skipped"] as? String == "key_refused" },
            "a skip row pins CORE's refused key (#498)"
        )
        XCTAssertTrue(
            rows.contains { $0["skipped"] as? String == "key_refused" && $0["source"] as? String == "elsevier" },
            "a skip row pins Elsevier's refused key"
        )
        XCTAssertTrue(
            rows.contains { $0["skipped"] as? String == "network_refused" },
            "a skip row pins Elsevier's off-network refusal"
        )
    }

    func testEachWrittenRow() throws {
        let rows = try persistedTable("written")
        XCTAssertGreaterThanOrEqual(rows.count, 3, "an empty table would pass vacuously")
        for row in rows {
            let written = try shortfall(row).persisted()
            let parsed = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? NSDictionary
            let expected = try XCTUnwrap(row["stored"] as? NSDictionary, "\(row)")

            XCTAssertEqual(parsed, expected, "\(row)")
        }
    }

    func testEachReadRow() throws {
        let rows = try persistedTable("read")
        XCTAssertGreaterThanOrEqual(rows.count, 10, "an empty table would pass vacuously")
        for row in rows {
            let stored = try XCTUnwrap(row["stored"] as? String, "\(row)")

            XCTAssertEqual(
                OpenAccessShortfall.restored(fromPersisted: stored), try shortfall(row),
                row["name"] as? String ?? "?"
            )
        }
    }

    /// Every shortfall reads back as itself.
    func testEveryShortfallRoundTrips() {
        let failures: [RequestFailure] = [
            .timeout, .connection, .serviceError, .malformedResponse, .incompleteResponse,
            .requestFailed, .httpStatus(429), .httpStatus(408), .redirectRefused(statusCode: 307),
            .redirectRefused(statusCode: nil),
        ]
        for source in OpenAccessSource.allCases {
            for failure in failures {
                let shortfall = OpenAccessShortfall(source: source, failure: failure)

                XCTAssertEqual(
                    OpenAccessShortfall.restored(fromPersisted: shortfall.persisted()), shortfall
                )
            }
        }
        for skipped in [
            OpenAccessShortfall.unpaywallNotConfigured, .coreKeyRefused, .elsevierKeyRefused, .elsevierNetworkRefused,
        ] {
            XCTAssertEqual(OpenAccessShortfall.restored(fromPersisted: skipped.persisted()), skipped)
        }
    }

    /// A refused key is CORE's, configured, and unasked: no nudge (#498).
    func testARefusedKeyEarnsNoConfigurationNudge() {
        let refused = OpenAccessShortfall.coreKeyRefused
        XCTAssertEqual(refused.source, .core)
        XCTAssertEqual(refused.reason, .keyRefused)
        XCTAssertNil(refused.failure)
        XCTAssertFalse(refused.notice.contains("Configuring"))
        // The control: alongside an unconfigured Unpaywall, only Unpaywall is nudged
        let both = OpenAccessShortfall.unpaywallNotConfigured.appending(refused)
        XCTAssertEqual(
            both.notice,
            "Unpaywall (not configured) and CORE (the key in the settings was refused) could not be "
                + "asked, so a freely available copy may exist. Whether this document is open access "
                + "was not established. Configuring Unpaywall would add an open-access route this "
                + "search did not have."
        )
    }

    /// Elsevier's refusals are a configured keyed channel's, unasked: no
    /// nudge, and each reads as Elsevier's (#480, stage C2).
    func testElseviersRefusalsEarnNoConfigurationNudge() {
        for refused in [OpenAccessShortfall.elsevierKeyRefused, .elsevierNetworkRefused] {
            XCTAssertEqual(refused.source, .elsevier)
            XCTAssertNil(refused.failure)
            XCTAssertFalse(refused.notice.contains("Configuring"), refused.notice)
        }
        XCTAssertEqual(OpenAccessShortfall.elsevierKeyRefused.reason, .keyRefused)
        XCTAssertEqual(OpenAccessShortfall.elsevierNetworkRefused.reason, .networkRefused)
        // The control: alongside an unconfigured Unpaywall, only Unpaywall is nudged
        let both = OpenAccessShortfall.elsevierNetworkRefused.appending(.unpaywallNotConfigured)
        XCTAssertEqual(
            both.notice,
            "Elsevier's API (not available from this network) and Unpaywall (not configured) could not "
                + "be asked, so a freely available copy may exist. Whether this document is open access "
                + "was not established. Configuring Unpaywall would add an open-access route this "
                + "search did not have."
        )
    }

    /// A refused key and an off-network refusal are told apart, and a CORE
    /// refusal stays CORE's beside Elsevier's.
    func testCOREsAndElseviersRefusalsAreToldApart() {
        XCTAssertNotEqual(OpenAccessShortfall.coreKeyRefused, .elsevierKeyRefused)
        XCTAssertNotEqual(OpenAccessShortfall.elsevierKeyRefused, .elsevierNetworkRefused)
        let both = OpenAccessShortfall.elsevierKeyRefused.appending(.coreKeyRefused)
        XCTAssertEqual(OpenAccessShortfall.restored(fromPersisted: both.persisted()), both)
        XCTAssertEqual(both.entries.map(\.source), [.elsevier, .core])
    }

    /// A table added to the contract and asserted nowhere would pin nothing.
    func testEveryContractTableIsReadHere() throws {
        let contract = try loadContract()
        XCTAssertEqual(
            Set(contract.keys),
            ["schema_version", "description", "sources", "notices", "persisted"]
        )
        let persisted = try XCTUnwrap(contract["persisted"] as? [String: Any])
        XCTAssertEqual(Set(persisted.keys), ["written", "read"])
    }
}
