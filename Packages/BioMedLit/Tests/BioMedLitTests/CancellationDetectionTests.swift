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

/// Cancellation arrives in two shapes, and code that falls back on failure has
/// to recognise both.
///
/// Tested here rather than only through `FullTextService` because a
/// `URLProtocol` stub cannot deliver a `CancellationError` unchanged — the
/// session converts it — so the transport-level test can only cover the
/// `URLError` half. This covers the half it cannot reach.
final class CancellationDetectionTests: XCTestCase {

    /// The shape `Task.sleep` raises, which is how the retry backoff cancels.
    func testACancellationErrorIsCancellation() {
        XCTAssertTrue(CancellationError().isCancellation)
    }

    /// The shape a cancelled `URLSession` request raises, which is how almost
    /// every real cancellation arrives: a request spends nearly all its life
    /// awaiting the transport rather than sleeping between retries.
    func testACancelledURLErrorIsCancellation() {
        XCTAssertTrue(URLError(.cancelled).isCancellation)
    }

    /// The negative control. Without it the predicate could answer `true` to
    /// everything and every assertion above would still pass — and a chain that
    /// treated a timeout as a cancellation would refuse to fall back at all,
    /// turning a recoverable failure into no full text.
    func testOrdinaryFailuresAreNotCancellation() {
        let notCancellations: [Error] = [
            URLError(.timedOut),
            URLError(.notConnectedToInternet),
            URLError(.badServerResponse),
            FullTextError.noFullTextAvailable,
        ]
        for error in notCancellations {
            XCTAssertFalse(error.isCancellation, "\(error) was read as a cancellation")
        }
    }
}
