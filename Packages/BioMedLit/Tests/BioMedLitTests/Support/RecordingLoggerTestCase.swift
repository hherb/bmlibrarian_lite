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

import Foundation
import XCTest
@testable import BioMedLit

/// Records the library's diagnostics so a test can assert on them.
///
/// Each line is stored as `"LEVEL: message"`, so a test can filter by level or
/// search every line at once.
///
/// **Every level is recorded, including `debug`.** Ignoring the quiet levels is
/// a defect in its own right, and it was live: `debug` is where the JATS parser
/// announces a discarded caption, and the real corpus dropped captions on every
/// run with nothing to hear it.
///
/// `@unchecked Sendable` with a lock because `BioMedLitLogger` requires
/// `Sendable` and this is mutable; the lock is what makes that claim true. An
/// actor cannot satisfy the protocol's synchronous requirements, and
/// `Synchronization.Mutex` needs a newer deployment target than this package's.
final class RecordingLogger: BioMedLitLogger, @unchecked Sendable {
    /// Guards ``messages``; the whole basis of the `@unchecked Sendable` claim.
    private let lock = NSLock()

    /// Everything logged since the last ``reset()``, each line prefixed by level.
    private var messages: [String] = []

    /// Append one message under its level.
    ///
    /// - Parameters:
    ///   - level: Level name, used as the line's prefix.
    ///   - message: The logged text.
    private func record(_ level: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        messages.append("\(level): \(message)")
    }

    /// Record a debug message.
    func debug(_ message: String, category: BioMedLitLogCategory) {
        record("DEBUG", message)
    }

    /// Record an informational message.
    func info(_ message: String, category: BioMedLitLogCategory) {
        record("INFO", message)
    }

    /// Record a warning.
    func warning(_ message: String, category: BioMedLitLogCategory) {
        record("WARNING", message)
    }

    /// Record an error.
    func error(_ message: String, category: BioMedLitLogCategory) {
        record("ERROR", message)
    }

    /// Everything logged at any level since the last ``reset()``.
    var recorded: [String] {
        lock.lock(); defer { lock.unlock() }
        return messages
    }

    /// Only the lines logged at error level.
    var errors: [String] {
        recorded.filter { $0.hasPrefix("ERROR: ") }
    }

    /// Only the levels that report a problem: warnings and errors.
    var problems: [String] {
        recorded.filter { $0.hasPrefix("WARNING: ") || $0.hasPrefix("ERROR: ") }
    }

    /// Forget everything recorded so far.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        messages.removeAll()
    }
}

/// A test case that hears everything the library logs while each test runs.
///
/// The library holds its logger in process-global configuration, so installing
/// one is process-wide. **One test at a time per process is load-bearing**
/// (#239). XCTest runs one test method at a time, and `swift test --parallel`
/// and Xcode's parallel testing both spread tests across separate processes, so
/// none of those overlap. What would overlap is a Swift Testing `@Test`, which
/// runs concurrently inside the process by default, or work a test leaves
/// running after it ends. Either would install or log over these tests' logger,
/// and a logger assertion would pass or fail by scheduling.
///
/// The logger is installed around the whole test, in `invokeTest()`, not in
/// `setUp()`: a subclass that overrides `setUp()` and forgets `super` still has
/// it, where otherwise `logger.recorded == []` would pass having heard nothing.
/// The configuration is reset after every test, so a subclass must not install
/// a logger of its own in a class-level `setUp()`; each test replaces it.
class RecordingLoggerTestCase: XCTestCase {
    /// The logger installed for the duration of each test.
    let logger = RecordingLogger()

    /// Run one test, its `setUp()` and `tearDown()` included, with the recording
    /// logger installed and emptied.
    ///
    /// Afterwards the library is put back to what the rest of the package's tests
    /// have always run with: configured, but no logger. It cannot be un-configured.
    override func invokeTest() {
        logger.reset()
        BioMedLitLib.configure(with: BioMedLitConfiguration(
            ncbiEmail: "tests@example.com", logger: logger
        ))
        defer {
            BioMedLitLib.configure(with: BioMedLitConfiguration(
                ncbiEmail: "tests@example.com", logger: nil
            ))
        }
        super.invokeTest()
    }
}
