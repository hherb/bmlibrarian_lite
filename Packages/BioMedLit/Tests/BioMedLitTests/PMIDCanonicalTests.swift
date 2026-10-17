// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
@testable import BioMedLit

/// A PMID is canonical ASCII digits, or it is not sent (bmlib#470, bmlib#472, bmlib#478):
/// the shared rows of `doc/cross_platform/fulltext_parity/pmid_canonical.json`,
/// then where the reading is used.
final class PMIDCanonicalTests: XCTestCase {
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/fulltext_parity/pmid_canonical.json"
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return nil }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }()

    private func contract() throws -> [String: Any] {
        let file = try XCTUnwrap(Self.contractFile, "pmid_canonical.json not found")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
        return try XCTUnwrap(object as? [String: Any])
    }

    private func cases() throws -> [[String: Any]] {
        try XCTUnwrap(contract()["cases"] as? [[String: Any]])
    }

    func testEveryContractKeyIsReadHere() throws {
        XCTAssertEqual(
            Set(try contract().keys),
            ["schema_version", "description", "source", "stripped_whitespace", "cases"]
        )
    }

    func testEveryCaseHasEveryKey() throws {
        // "note" is prose for the contract's reader, read by no suite.
        let required: Set<String> = ["name", "input", "pmid", "pmc_id", "refused"]
        for row in try cases() {
            XCTAssertEqual(Set(row.keys).subtracting(["note"]), required, "\(row["name"] ?? "?")")
        }
    }

    func testTheStrippedWhitespaceIsTheContracts() throws {
        let listed = try XCTUnwrap(contract()["stripped_whitespace"] as? [Int])
        XCTAssertEqual(listed.count, Set(listed).count)
        XCTAssertEqual(Set(listed.map(UInt32.init)), BioMedLitConstants.pmidStrippedWhitespace)
    }

    func testEachCase() throws {
        let rows = try cases()
        XCTAssertGreaterThanOrEqual(rows.count, 11)
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String)
            let input = try XCTUnwrap(row["input"] as? String)
            let reading = PMID.canonical(input)
            XCTAssertEqual(reading.pmid, row["pmid"] as? String, name)
            XCTAssertEqual(reading.pmcId, row["pmc_id"] as? String, name)
            XCTAssertEqual(reading.refused, row["refused"] as? Bool, name)
        }
    }

    func testAZeroWidthSpaceAfterAPMIDIsNotQueriedOrLinked() {
        let raw = "33301246\u{200B}"
        XCTAssertEqual(
            FullTextService.identifierQueries(pmid: raw, pmcId: nil, doi: "10.1/x", primaryKind: .pubmed)
                .map(\.query),
            ["DOI:\"10.1/x\""]
        )
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: raw, declared: .pubmed))
    }

    func testAPaddedPMIDIsQueriedCanonical() {
        for kind: ArticleIdentifierKind? in [.pubmed, .unknown, nil] {
            let queries = FullTextService.identifierQueries(
                pmid: "0033301246", pmcId: nil, doi: nil, primaryKind: kind
            )
            XCTAssertEqual(queries.map(\.query), ["ext_id:33301246 src:med"], "\(String(describing: kind))")
        }
    }

    func testARefusedPMIDIsNotQueried() {
        for raw in ["1 OR 2", "33301246abc", "PMID:33301246", "١٢٣", "0000"] {
            for kind: ArticleIdentifierKind? in [.pubmed, .unknown] {
                let queries = FullTextService.identifierQueries(
                    pmid: raw, pmcId: nil, doi: "10.1/x", primaryKind: kind
                )
                XCTAssertEqual(queries.map(\.query), ["DOI:\"10.1/x\""], raw)
            }
        }
    }

    func testAPMCIDInThePMIDSlotIsAskedAsAPMCID() {
        for kind: ArticleIdentifierKind? in [.pubmed, .unknown] {
            let queries = FullTextService.identifierQueries(
                pmid: "PMC7745181", pmcId: nil, doi: nil, primaryKind: kind
            )
            XCTAssertEqual(queries.map(\.query), ["PMCID:PMC7745181"])
        }
    }

    func testThePubMedURLIdentifierIsCanonical() {
        XCTAssertEqual(
            ArticleIdentifierKind.pubmedID(in: " 0033301246 ", declared: .pubmed), "33301246"
        )
        XCTAssertNil(ArticleIdentifierKind.pubmedID(in: "0000", declared: .pubmed))
    }

    func testTheCanonicalCheck() {
        XCTAssertTrue(PMID.isCanonical("33301246"))
        XCTAssertFalse(PMID.isCanonical("0033301246"))
        XCTAssertFalse(PMID.isCanonical(""))
    }
}
