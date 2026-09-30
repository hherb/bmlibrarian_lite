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

/// The verb a failed lookup earns, read from the contract all three platforms
/// share (#447): `doc/cross_platform/request_failure_parity/answered_lookup_verb.json`.
///
/// Each platform used to pin its own table, so a change on one passed that
/// platform's tests and left the three disagreeing about what the reader is told.
final class AnsweredLookupVerbContractTests: XCTestCase {

    /// The contract file, decoded.
    private struct Contract: Decodable {
        let unansweredStatuses: UnansweredStatuses
        let predicate: [PredicateRow]
        let absenceNotEstablished: [SentenceRow]

        enum CodingKeys: String, CodingKey {
            case unansweredStatuses = "unanswered_statuses"
            case predicate
            case absenceNotEstablished = "absence_not_established"
        }
    }

    /// The statuses that are not an answer: each one listed, and a range.
    private struct UnansweredStatuses: Decodable {
        let listed: [Int]
        let from: Int
        let through: Int

        var all: Set<Int> { Set(listed).union(from...through) }
    }

    /// One (kind, status) and whether it is an answer.
    private struct PredicateRow: Decodable {
        let kind: RequestFailureKind
        let statusCode: Int?
        let isAnswer: Bool

        enum CodingKeys: String, CodingKey {
            case kind
            case statusCode = "status_code"
            case isAnswer = "is_answer"
        }
    }

    /// One failure and the whole sentence the reader is shown for it.
    private struct SentenceRow: Decodable {
        let kind: RequestFailureKind
        let statusCode: Int?
        let sentence: String

        enum CodingKeys: String, CodingKey {
            case kind
            case statusCode = "status_code"
            case sentence
        }
    }

    private enum ContractError: Error {
        case notFound(origin: String)
    }

    /// Where the contract lives, found by walking up from this source file.
    ///
    /// Read from the repository, never copied into test resources: every
    /// platform must read the same bytes. The walk stops at the checkout root,
    /// as `TransparencyParityTests.fixtureDirectory` does, so a worktree under
    /// the main checkout never reads the main checkout's contract.
    private static let contractFile: URL? = {
        let relative = "doc/cross_platform/request_failure_parity/answered_lookup_verb.json"
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

    private func loadContract() throws -> Contract {
        guard let file = Self.contractFile else {
            throw ContractError.notFound(origin: #filePath)
        }
        return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: file))
    }

    /// The failure a row names, through the same path a stored one takes.
    private func failure(_ kind: RequestFailureKind, _ statusCode: Int?) -> RequestFailure {
        RequestFailure.restored(kind: kind, statusCode: statusCode)
    }

    /// Each (kind, status) is an answer exactly when the contract says.
    func testEachPredicateRow() throws {
        let contract = try loadContract()
        XCTAssertFalse(contract.predicate.isEmpty)
        for row in contract.predicate {
            let failure = failure(row.kind, row.statusCode)
            XCTAssertEqual(failure.statusCode, row.statusCode, "\(row)")
            XCTAssertEqual(failure.isAnswer, row.isAnswer, "\(row)")
        }
    }

    /// Python and Android name the same statuses.
    func testTheUnansweredStatusesAreTheContracts() throws {
        let contract = try loadContract()
        XCTAssertEqual(BioMedLitConstants.unansweredStatusCodes, contract.unansweredStatuses.all)
    }

    /// A kind added later cannot inherit a verb nobody chose for it.
    func testEveryKindHasARow() throws {
        let contract = try loadContract()
        XCTAssertEqual(Set(contract.predicate.map(\.kind)), Set(RequestFailureKind.allCases))
    }

    /// The reader's sentence, asserted whole, so the tail cannot drift from
    /// Android's.
    func testEachSentenceRow() throws {
        let contract = try loadContract()
        XCTAssertFalse(contract.absenceNotEstablished.isEmpty)
        for row in contract.absenceNotEstablished {
            let error = FullTextError.absenceNotEstablished(failure(row.kind, row.statusCode))
            XCTAssertEqual(error.errorDescription, row.sentence, "\(row)")
        }
    }
}
