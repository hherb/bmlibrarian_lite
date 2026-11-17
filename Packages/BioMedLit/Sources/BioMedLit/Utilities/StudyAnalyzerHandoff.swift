// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import Foundation

/// A paper handed to StudyAnalyzer: the `.studyanalyzer` file
/// (StudyAnalyzer's `docs/handoff-format.md`, version 1).
///
/// Pure: it holds plain fields and writes the file's JSON. Which text to
/// send is the caller's choice. Identifiers are sent as given; StudyAnalyzer
/// checks each one and tells the reader of any it drops.
public struct StudyAnalyzerHandoff: Equatable, Sendable {
    /// The kind of the full text carried (`full_text.format`).
    public enum Format: String, Sendable {
        case pdf, jats, html, markdown, text
    }

    /// The full text carried in the file: the file's own bytes.
    public struct FullText: Equatable, Sendable {
        /// Its kind.
        public let format: Format
        /// The file's bytes, written as base64.
        public let data: Data
        /// A name only (never a path), or `nil`.
        public let fileName: String?
        /// Where the text came from, for display (e.g. "Europe PMC"), or `nil`.
        public let source: String?

        /// A full text of `format`; a blank `fileName` or `source` is left out.
        ///
        /// - Parameters:
        ///   - format: Its kind.
        ///   - data: The file's bytes.
        ///   - fileName: A name only, or `nil`.
        ///   - source: Where it came from, or `nil`.
        public init(format: Format, data: Data, fileName: String? = nil, source: String? = nil) {
            self.format = format
            self.data = data
            self.fileName = nonBlank(fileName)
            self.source = nonBlank(source)
        }
    }

    /// A PubMed ID or preprint accession (`PPR…`), or `nil`.
    public let pmid: String?
    /// A DOI, or `nil`.
    public let doi: String?
    /// A PMC ID, or `nil`.
    public let pmcid: String?
    /// The paper's title, or `nil`.
    public let title: String?
    /// The full text carried, or `nil` for identifiers only.
    public let fullText: FullText?

    /// A hand-off of these fields; blank or whitespace-only strings are left out.
    ///
    /// - Parameters:
    ///   - pmid: A PubMed ID or preprint accession.
    ///   - doi: A DOI.
    ///   - pmcid: A PMC ID.
    ///   - title: The paper's title.
    ///   - fullText: The full text to carry, or `nil`.
    public init(pmid: String?, doi: String?, pmcid: String?, title: String?, fullText: FullText?) {
        self.pmid = nonBlank(pmid)
        self.doi = nonBlank(doi)
        self.pmcid = nonBlank(pmcid)
        self.title = nonBlank(title)
        self.fullText = fullText
    }

    /// Whether StudyAnalyzer could open it: it has an identifier or a full text.
    public var hasContent: Bool {
        pmid != nil || doi != nil || pmcid != nil || fullText != nil
    }

    /// The file's JSON (UTF-8). Absent fields are left out.
    ///
    /// - Returns: The bytes to write to a `.studyanalyzer` file.
    /// - Throws: An `EncodingError`, which plain strings and data never cause.
    public func encoded() throws -> Data {
        let file = File(
            format: BioMedLitConstants.handoffFormat,
            version: BioMedLitConstants.handoffVersion,
            sender: BioMedLitConstants.handoffSender,
            title: title,
            identifiers: Identifiers(pmid: pmid, doi: doi, pmcid: pmcid),
            fullText: fullText.map {
                Text(format: $0.format.rawValue, data: $0.data, fileName: $0.fileName, source: $0.source)
            }
        )
        // The default `.base64` data strategy writes one unbroken, padded string.
        return try JSONEncoder().encode(file)
    }

    // The file's shape; synthesized `encodeIfPresent` leaves out each nil.
    private struct File: Encodable {
        let format: String
        let version: Int
        let sender: String
        let title: String?
        let identifiers: Identifiers
        let fullText: Text?

        enum CodingKeys: String, CodingKey {
            case format, version, sender, title, identifiers
            case fullText = "full_text"
        }
    }

    private struct Identifiers: Encodable {
        let pmid: String?
        let doi: String?
        let pmcid: String?
    }

    private struct Text: Encodable {
        let format: String
        let data: Data
        let fileName: String?
        let source: String?

        enum CodingKeys: String, CodingKey {
            case format, data, source
            case fileName = "file_name"
        }
    }
}

/// `value` unchanged, or `nil` when it is empty or only whitespace.
private func nonBlank(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}
