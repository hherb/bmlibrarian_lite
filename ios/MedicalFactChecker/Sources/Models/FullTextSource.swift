//
//  FullTextSource.swift
//  MedicalFactChecker
//
//  Represents the source of retrieved full text.
//

import Foundation

/// Source from which full text was retrieved.
enum FullTextSource: String, Codable, Sendable {
    case europePMC = "europepmc"
    case unpaywall = "unpaywall"
    case doi = "doi"
    case cached = "cached"

    /// Human-readable display name.
    var displayName: String {
        switch self {
        case .europePMC: return "Europe PMC"
        case .unpaywall: return "Unpaywall"
        case .doi: return "Publisher"
        case .cached: return "Cached"
        }
    }

    /// Icon name for the source.
    var iconName: String {
        switch self {
        case .europePMC: return "building.columns"
        case .unpaywall: return "lock.open"
        case .doi: return "link"
        case .cached: return "arrow.down.circle"
        }
    }
}

/// Result of a full-text retrieval attempt.
struct FullTextResult: Sendable {
    /// The content type retrieved.
    enum ContentType: Sendable {
        case markdown(String)    // Europe PMC XML converted to markdown
        case pdfURL(URL)         // URL to downloadable PDF
        case webURL(URL)         // Fallback URL to open in browser
    }

    let content: ContentType
    let source: FullTextSource

    /// Whether this result can be displayed in-app.
    var canDisplayInApp: Bool {
        switch content {
        case .markdown, .pdfURL:
            return true
        case .webURL:
            return false
        }
    }

    /// Get the markdown content if available.
    var markdownContent: String? {
        if case .markdown(let text) = content {
            return text
        }
        return nil
    }

    /// Get the PDF URL if available.
    var pdfURL: URL? {
        if case .pdfURL(let url) = content {
            return url
        }
        return nil
    }

    /// Get the web URL if this is a fallback result.
    var webURL: URL? {
        if case .webURL(let url) = content {
            return url
        }
        return nil
    }
}
