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

/// Tests for library logging configuration.
///
/// The library's diagnostics are optional-chained through `BioMedLitLib.logger`,
/// so a configuration that supplies no logger discards every message silently.
/// Both apps did exactly that — `logger: nil`, commented "use default console
/// logger in debug", when there is no default — which left the rejected-PDF and
/// truncated-parse warnings unreachable in every build. These tests pin the two
/// halves of that: a configured logger is actually reachable, and the absence of
/// one is a real absence rather than a fallback.
final class BioMedLitLoggerTests: XCTestCase {

    /// Records what it was asked to log, so the wiring can be asserted on.
    private final class SpyLogger: BioMedLitLogger, @unchecked Sendable {
        private let lock = NSLock()
        private var _messages: [(level: String, message: String)] = []

        var messages: [(level: String, message: String)] {
            lock.lock()
            defer { lock.unlock() }
            return _messages
        }

        private func record(_ level: String, _ message: String) {
            lock.lock()
            defer { lock.unlock() }
            _messages.append((level, message))
        }

        func debug(_ message: String, category: BioMedLitLogCategory) { record("debug", message) }
        func info(_ message: String, category: BioMedLitLogCategory) { record("info", message) }
        func warning(_ message: String, category: BioMedLitLogCategory) { record("warning", message) }
        func error(_ message: String, category: BioMedLitLogCategory) { record("error", message) }
    }

    override func tearDown() {
        BioMedLitLib.configure(with: BioMedLitConfiguration(ncbiEmail: "test@example.com"))
        super.tearDown()
    }

    func testAConfiguredLoggerReceivesMessages() {
        let spy = SpyLogger()
        BioMedLitLib.configure(
            with: BioMedLitConfiguration(ncbiEmail: "test@example.com", logger: spy)
        )

        BioMedLitLib.logger?.warning("a warning", category: .fullText)

        XCTAssertEqual(spy.messages.count, 1)
        XCTAssertEqual(spy.messages.first?.level, "warning")
        XCTAssertEqual(spy.messages.first?.message, "a warning")
    }

    /// There is no implicit fallback: passing `nil` means nothing is logged, on
    /// any build. This is the behaviour the apps' comment misdescribed.
    func testNoLoggerMeansNoLoggerRatherThanADefault() {
        BioMedLitLib.configure(
            with: BioMedLitConfiguration(ncbiEmail: "test@example.com", logger: nil)
        )

        XCTAssertNil(BioMedLitLib.logger)
    }

    /// The os.log adapter the apps now install must accept every level without
    /// trapping on the string interpolation.
    func testOSLogLoggerAcceptsEveryLevel() {
        let logger = BioMedLitOSLogLogger(subsystem: "com.bmlibrarian.tests")

        logger.debug("debug", category: .parsing)
        logger.info("info", category: .network)
        logger.warning("warning", category: .fullText)
        logger.error("error", category: .transparency)
    }
}
