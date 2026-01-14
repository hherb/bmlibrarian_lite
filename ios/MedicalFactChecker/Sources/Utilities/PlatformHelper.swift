//
//  PlatformHelper.swift
//  MedicalFactChecker
//
//  Cross-platform utilities for iOS and macOS.
//

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
