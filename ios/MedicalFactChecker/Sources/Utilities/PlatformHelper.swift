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
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform utilities for common operations.
///
/// Provides a unified API for operations that differ between iOS and macOS.
enum PlatformHelper {
    /// Open a URL in the system's default browser.
    ///
    /// - Parameter url: The URL to open.
    static func openURL(_ url: URL) {
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Copy text to the system clipboard.
    ///
    /// - Parameter text: The text to copy.
    static func copyToClipboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    /// Build a DOI URL from a DOI string.
    ///
    /// - Parameter doi: The DOI string.
    /// - Returns: A URL pointing to the DOI resolver, or nil if invalid.
    static func doiURL(for doi: String) -> URL? {
        URL(string: "\(FullTextConstants.doiBaseURL)/\(doi)")
    }

    /// Build a PubMed URL from a PMID.
    ///
    /// - Parameter pmid: The PubMed ID.
    /// - Returns: A URL pointing to the PubMed page, or nil if invalid.
    static func pubmedURL(for pmid: String) -> URL? {
        URL(string: "\(FullTextConstants.pubmedBaseURL)/\(pmid)/")
    }
}

// MARK: - Bundle Extension

extension Bundle {
    /// The app's marketing version (CFBundleShortVersionString).
    var marketingVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// The app's build number (CFBundleVersion).
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// A formatted version string combining marketing version and build number.
    ///
    /// Format: "X.Y.Z (Build N)" e.g., "1.3.0 (Build 3)"
    var appVersionString: String {
        "\(marketingVersion) (Build \(buildNumber))"
    }
}
