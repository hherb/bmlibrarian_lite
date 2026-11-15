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

import Foundation

/// Who this installation is in the shared paper library: each installation
/// writes only its own record (`records/medicalfactchecker-<id>.json`), so the
/// same app on two Macs sharing a synced folder never overwrites the other's.
///
/// The id is made once, at the app's first use of a library, and kept in the
/// app's settings; the label names the app and the machine for a person
/// reading the folder or the manual clear's list.
public enum LibraryInstallation {

    /// A fresh installation id: a random UUID in lower case. bmlib refuses
    /// upper case, which `UUID().uuidString` gives.
    public static func newID() -> String {
        UUID().uuidString.lowercased()
    }

    /// Whether `id` is an installation id bmlib accepts: 1–64 characters of
    /// `a-z`, `0-9` and `-`. The app makes a new id when its stored one is not.
    public static func isValidID(_ id: String) -> Bool {
        (1...BioMedLitConstants.libraryInstallationIDMaxChars).contains(id.utf8.count)
            && id.utf8.allSatisfy { b in
                (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                    || b == UInt8(ascii: "-")
            }
    }

    /// The installation's label: "MedicalFactChecker on <machine>".
    ///
    /// Control and bidirectional control characters are dropped (bmlib refuses
    /// them; a bidi mark could disguise the name). With no usable machine name,
    /// or one too long for bmlib's 200 characters (counted in Unicode
    /// scalars, as bmlib's `chars()`), the label is the app's name alone: a
    /// label is never cut.
    ///
    /// - Parameter machineName: The computer's name as the system gives it
    ///   (`Host.current().localizedName` on macOS), or nil.
    public static func label(machineName: String?) -> String {
        let app = BioMedLitConstants.libraryAppDisplayName
        let cleaned = String(String.UnicodeScalarView(
            (machineName ?? "").unicodeScalars.filter { !isRefused($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return app }
        let label = "\(app) on \(cleaned)"
        return label.unicodeScalars.count <= BioMedLitConstants.libraryLabelMaxChars ? label : app
    }

    /// True for the characters bmlib refuses in a label: controls, and the
    /// bidirectional controls of its `is_bidi_control`.
    static func isRefused(_ s: Unicode.Scalar) -> Bool {
        if s.properties.generalCategory == .control { return true }
        switch s.value {
        case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}
