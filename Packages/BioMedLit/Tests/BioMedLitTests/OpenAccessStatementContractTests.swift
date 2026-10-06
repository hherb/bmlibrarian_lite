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

/// What the reader is told once open-access PDFs were tried (#480), the caching
/// note, and the stored list, read from the contract all three platforms share:
/// `doc/cross_platform/fulltext_parity/open_access_statement.json`.
final class OpenAccessStatementContractTests: XCTestCase {

    private enum ContractError: Error {
        case notFound(origin: String)
        case malformed(String)
    }

    /// The contract file, read from the repository; the walk stops at the
    /// checkout root, as `OpenAccessShortfallContractTests.contractFile` does.
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/fulltext_parity/open_access_statement.json"
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

    private func table(_ name: String) throws -> [[String: Any]] {
        guard let rows = try loadContract()[name] as? [[String: Any]] else {
            throw ContractError.malformed(name)
        }
        return rows
    }

    private func persistedTable(_ name: String) throws -> [[String: Any]] {
        guard let persisted = try loadContract()["persisted"] as? [String: Any],
              let rows = persisted[name] as? [[String: Any]] else {
            throw ContractError.malformed("persisted.\(name)")
        }
        return rows
    }

    /// The shortfall a row's entries describe, in the order given.
    private func shortfall(_ row: [String: Any]) throws -> OpenAccessShortfall {
        let rows = try XCTUnwrap(row["entries"] as? [[String: Any]], "\(row)")
        let parts: [OpenAccessShortfall] = try rows.map { entry in
            let source = try XCTUnwrap(
                (entry["source"] as? String).flatMap(OpenAccessSource.init(rawValue:)), "\(entry)"
            )
            if entry["skipped"] as? String == "not_configured" { return .unpaywallNotConfigured }
            if entry["skipped"] as? String == "key_refused" {
                XCTAssertEqual(source, .core, "\(entry)")
                return .coreKeyRefused
            }
            let kind = try XCTUnwrap(
                (entry["kind"] as? String).flatMap(RequestFailureKind.init(rawValue:)), "\(entry)"
            )
            return OpenAccessShortfall(
                source: source,
                failure: RequestFailure.restored(kind: kind, statusCode: entry["status_code"] as? Int),
                address: entry["address"] as? String
            )
        }
        return parts.dropFirst().reduce(parts[0]) { $0.appending($1) }
    }

    /// A table added to the contract and asserted nowhere would pin nothing.
    func testEveryContractTableIsReadHere() throws {
        XCTAssertEqual(
            Set(try loadContract().keys),
            ["schema_version", "description", "lead", "hosts", "statements", "not_saved_note", "persisted"]
        )
        let persisted = try XCTUnwrap(loadContract()["persisted"] as? [String: Any])
        XCTAssertEqual(Set(persisted.keys), ["written", "read"])
    }

    func testEachHostRow() throws {
        let rows = try table("hosts")
        XCTAssertGreaterThanOrEqual(rows.count, 5, "an empty table would pass vacuously")
        for row in rows {
            XCTAssertEqual(
                OpenAccessShortfall.host(of: try XCTUnwrap(row["address"] as? String)),
                row["host"] as? String, "\(row)"
            )
        }
    }

    func testEachStatementRow() throws {
        let rows = try table("statements")
        XCTAssertGreaterThanOrEqual(rows.count, 8, "an empty table would pass vacuously")
        for row in rows {
            XCTAssertEqual(try shortfall(row).notice, row["statement"] as? String, "\(row)")
        }
    }

    func testEachNotSavedNoteRow() throws {
        let rows = try table("not_saved_note")
        XCTAssertGreaterThanOrEqual(rows.count, 2, "an empty table would pass vacuously")
        for row in rows {
            XCTAssertEqual(
                OpenAccessShortfall.notSavedNote(
                    address: try XCTUnwrap(row["address"] as? String),
                    linkKept: try XCTUnwrap(row["link_kept"] as? Bool)
                ),
                row["note"] as? String, "\(row)"
            )
        }
    }

    func testEachWrittenRow() throws {
        let rows = try persistedTable("written")
        XCTAssertGreaterThanOrEqual(rows.count, 4, "an empty table would pass vacuously")
        for row in rows {
            let written = try shortfall(row).persisted()
            let parsed = try JSONSerialization.jsonObject(with: Data(written.utf8)) as? NSDictionary
            XCTAssertEqual(parsed, try XCTUnwrap(row["stored"] as? NSDictionary, "\(row)"), "\(row)")
        }
    }

    func testEachReadRow() throws {
        let rows = try persistedTable("read")
        XCTAssertGreaterThanOrEqual(rows.count, 8, "an empty table would pass vacuously")
        for row in rows {
            XCTAssertEqual(
                OpenAccessShortfall.restored(fromPersisted: try XCTUnwrap(row["stored"] as? String)),
                try shortfall(row), row["name"] as? String ?? "?"
            )
        }
    }

    func testEveryShortfallRoundTrips() throws {
        for row in try table("statements") {
            let built = try shortfall(row)
            XCTAssertEqual(OpenAccessShortfall.restored(fromPersisted: built.persisted()), built, "\(row)")
        }
    }
}
