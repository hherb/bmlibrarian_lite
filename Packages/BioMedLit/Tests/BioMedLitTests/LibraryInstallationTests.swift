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
import BmlibCore
@testable import BioMedLit

/// The installation's id and label for the shared paper library: both must be
/// what bmlib's `installationNew` accepts.
final class LibraryInstallationTests: XCTestCase {

    func testNewIDIsLowerCaseUUID() {
        let id = LibraryInstallation.newID()
        XCTAssertEqual(id.count, 36)
        XCTAssertEqual(id, id.lowercased())
        XCTAssertTrue(LibraryInstallation.isValidID(id))
    }

    func testIsValidIDRefusesUpperCaseAndEmpty() {
        XCTAssertFalse(LibraryInstallation.isValidID("ABC-DEF"))
        XCTAssertFalse(LibraryInstallation.isValidID(""))
        XCTAssertFalse(LibraryInstallation.isValidID(String(repeating: "a", count: 65)))
        XCTAssertTrue(LibraryInstallation.isValidID(String(repeating: "a", count: 64)))
    }

    func testLabelNamesAppAndMachine() {
        XCTAssertEqual(
            LibraryInstallation.label(machineName: "Horst's MacBook"),
            "MedicalFactChecker on Horst's MacBook")
    }

    func testLabelWithoutMachineIsAppName() {
        for name in [nil, "", "  \n"] as [String?] {
            XCTAssertEqual(LibraryInstallation.label(machineName: name), "MedicalFactChecker")
        }
    }

    func testLabelDropsControlAndBidiCharacters() {
        XCTAssertEqual(
            LibraryInstallation.label(machineName: "Mac\u{202E}Book\u{0007}"),
            "MedicalFactChecker on MacBook")
    }

    func testOverlongMachineNameGivesAppName() {
        let name = String(repeating: "x", count: 300)
        XCTAssertEqual(LibraryInstallation.label(machineName: name), "MedicalFactChecker")
    }

    func testLabelIsAcceptedByBmlib() throws {
        let names: [String?] = [
            "Horst's MacBook", nil, "", "Mac\u{202E}Book\u{0007}",
            String(repeating: "x", count: 300), String(repeating: "y", count: 180),
        ]
        for name in names {
            let label = LibraryInstallation.label(machineName: name)
            XCTAssertNoThrow(
                try installationNew(
                    app: BioMedLitConstants.libraryAppName,
                    id: LibraryInstallation.newID(),
                    label: label),
                label)
        }
    }
}
