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
@testable import MedicalFactChecker
import BioMedLit

/// A secret store with no key, in place of the Keychain.
private final class NoSecrets: SecretStore {
    func load(key: String) throws -> String? { nil }
    func save(key: String, value: String) -> Bool { false }
    func delete(key: String) -> Bool { true }
}

/// The shared paper library's two settings persist across launches (a fresh
/// `AppSettings` on the same defaults reads them back).
final class LibrarySettingsTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "LibrarySettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func settings() -> AppSettings {
        AppSettings(secretStore: NoSecrets(), libraryDefaults: defaults)
    }

    func testBookmarkPersists() {
        let data = Data([7, 8, 9])
        settings().libraryBookmark = data
        XCTAssertEqual(settings().libraryBookmark, data)
        settings().libraryBookmark = nil
        XCTAssertNil(settings().libraryBookmark)
    }

    func testInstallationIDPersists() {
        let id = LibraryInstallation.newID()
        settings().libraryInstallationID = id
        XCTAssertEqual(settings().libraryInstallationID, id)
    }

    func testNothingSetReadsAsNoLibrary() {
        XCTAssertNil(settings().libraryBookmark)
        XCTAssertNil(settings().libraryInstallationID)
    }
}
