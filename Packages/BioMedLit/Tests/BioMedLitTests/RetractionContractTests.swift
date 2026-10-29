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

import BmlibCore
import XCTest
@testable import BioMedLit

/// bmlib's retraction-status contract (bmlib#504) through bmlib's Rust over
/// UniFFI: `doc/cross_platform/retraction_parity/retraction_status.json`.
///
/// The fixture is copied verbatim from bmlib and never edited here; these
/// runners mirror the desktop's `tests/test_retraction_contract.py`. Results
/// are compared as the fixture's own JSON shape, so an expected field the
/// mapping lacks, or a value that differs, fails here rather than passing
/// unseen. `android-tests.yml` checks the copy is bmlib's file at the FFI pin.
final class RetractionContractTests: XCTestCase {

    private enum ContractError: Error {
        case notFound(origin: String)
        case unknownName(String)
    }

    /// The contract, found by walking up from this file; the walk stops at the
    /// checkout root, as `AnsweredLookupVerbContractTests.contractFile` does.
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/retraction_parity/retraction_status.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
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
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        let rows = try XCTUnwrap(loadContract()[key] as? [[String: Any]], key)
        XCTAssertFalse(rows.isEmpty, key)
        return rows
    }

    // MARK: - Fixture to FFI

    private static let sources = RetractionNames.sources
    private static let kinds = RetractionNames.kinds
    private static let statuses = RetractionNames.statuses
    private static let lookups = RetractionNames.lookups

    private func value<T>(_ name: String?, in table: [(String, T)]) throws -> T {
        guard let match = table.first(where: { $0.0 == name }) else {
            throw ContractError.unknownName(name ?? "nil")
        }
        return match.1
    }

    private func name<T: Equatable>(_ value: T, in table: [(String, T)]) -> String {
        table.first { $0.1 == value }?.0 ?? "unmapped \(value)"
    }

    private func evidence(_ row: [String: Any]) throws -> RetractionEvidence {
        RetractionEvidence(
            source: try value(row["source"] as? String, in: Self.sources),
            kind: try value(row["kind"] as? String, in: Self.kinds),
            date: row["date"] as? String,
            noticeDoi: row["notice_doi"] as? String,
            recordId: row["record_id"] as? String,
            rawKind: row["raw_kind"] as? String
        )
    }

    /// `body_text` verbatim, or `body` serialised as JSON.
    private func body(_ row: [String: Any]) throws -> Data {
        if let text = row["body_text"] as? String {
            return Data(text.utf8)
        }
        return try JSONSerialization.data(withJSONObject: try XCTUnwrap(row["body"]))
    }

    private func status(_ row: [String: Any]) throws -> UInt16 {
        UInt16(try XCTUnwrap(row["status"] as? Int))
    }

    // MARK: - FFI to the fixture's JSON

    private func json(_ text: String?) -> Any { text ?? NSNull() }

    private func json(_ evidence: RetractionEvidence) -> [String: Any] {
        [
            "source": name(evidence.source, in: Self.sources),
            "kind": name(evidence.kind, in: Self.kinds),
            "date": json(evidence.date),
            "notice_doi": json(evidence.noticeDoi),
            "record_id": json(evidence.recordId),
            "raw_kind": json(evidence.rawKind),
        ]
    }

    /// An unreachable result's reason is not part of the contract, but it must name why.
    private func json(_ result: CrossrefResult) -> [String: Any] {
        switch result {
        case let .served(doi, evidence, retractionTargets):
            return [
                "outcome": "served",
                "doi": doi,
                "evidence": evidence.map(json),
                "retraction_targets": retractionTargets,
            ]
        case .notKnown:
            return ["outcome": "not_known"]
        case let .unreachable(reason):
            XCTAssertFalse(reason.isEmpty, "an unreachable result names why")
            return ["outcome": "unreachable"]
        }
    }

    private func json(_ verdict: RetractionVerdict) -> [String: Any] {
        [
            "status": name(verdict.status, in: Self.statuses),
            "deciding": verdict.deciding.map(json) ?? NSNull(),
            "unanswered": verdict.unanswered.map { name($0, in: Self.lookups) },
        ]
    }

    private func assertMatches(_ got: [String: Any], _ expected: Any?, _ caseName: String) {
        XCTAssertTrue(
            NSDictionary(dictionary: got).isEqual(expected),
            "\(caseName): got \(got), expected \(String(describing: expected))"
        )
    }

    // MARK: - The three case families

    /// Each rule case's verdict equals the expected one.
    func testRuleCases() throws {
        for row in try cases("rule_cases") {
            let caseName = try XCTUnwrap(row["name"] as? String)
            let doi = row["doi"] as? String
            var crossref: CrossrefResult?
            if let answer = row["crossref"] as? [String: Any] {
                let requested = (answer["for"] as? String) ?? doi
                let results = parseCrossrefRetractionResponse(
                    status: try status(answer),
                    body: try body(answer),
                    requestedDois: [try XCTUnwrap(requested, caseName)]
                )
                XCTAssertEqual(results.count, 1, caseName)
                crossref = results.values.first
            }
            let export = try (row["export"] as? [[String: Any]])?.map(evidence)
            let verdict = retractionStatus(
                doi: doi,
                export: export,
                crossref: crossref,
                publicationTypes: try XCTUnwrap(row["publication_types"] as? [String], caseName)
            )
            assertMatches(json(verdict), row["expected"], caseName)
        }
    }

    /// Each Crossref answer parses to the expected results, keyed by normalised DOI.
    func testParseCases() throws {
        for row in try cases("parse_cases") {
            let caseName = try XCTUnwrap(row["name"] as? String)
            let results = parseCrossrefRetractionResponse(
                status: try status(row),
                body: try body(row),
                requestedDois: try XCTUnwrap(row["requested"] as? [String], caseName)
            )
            assertMatches(results.mapValues(json), row["expected"], caseName)
        }
    }

    /// The Crossref requests built equal the expected ones exactly.
    func testRequestCases() throws {
        for row in try cases("request_cases") {
            let caseName = try XCTUnwrap(row["name"] as? String)
            let requests = crossrefRetractionRequests(
                dois: try XCTUnwrap(row["dois"] as? [String], caseName),
                mailto: row["mailto"] as? String
            )
            let got: [String: Any] = [
                "batches": requests.batches.map { ["url": $0.url, "dois": $0.dois] },
                "unsendable": requests.unsendable,
            ]
            assertMatches(got, row["expected"], caseName)
        }
    }

    /// An older fixture predates `crossref.for` (bmlib#508); fail loudly.
    func testTheCopyIsThePinnedBmlibs() throws {
        let readme = try XCTUnwrap(loadContract()["_readme"] as? String)
        XCTAssertTrue(readme.contains("crossref.for"))
    }
}
