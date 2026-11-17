// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import Foundation
import BioMedLit

/// What a document hands StudyAnalyzer, and why any source was passed over.
struct StudyAnalyzerHandoffChoice: Equatable {
    /// The hand-off to write.
    let handoff: StudyAnalyzerHandoff
    /// One sentence per source tried and passed over, in order (a read that
    /// failed, a file too large); empty when the first source tried was sent.
    let notes: [String]
}

extension Document {
    /// What to hand StudyAnalyzer (StudyAnalyzer's shared-library design §3),
    /// or `nil` when there is nothing to send.
    ///
    /// What StudyAnalyzer cannot fetch itself, first match winning: the
    /// library's JATS file; identifiers only for a paper whose text came from
    /// JATS while online (StudyAnalyzer fetches the JATS); the local PDF, else
    /// the library's PDF; the Markdown; the HTML; identifiers only. Offline,
    /// the identifiers-only step is skipped, so whatever the app has is sent.
    /// A read that fails, or a file over `handoffMaxFileBytes`, is passed over
    /// with a note.
    ///
    /// - Parameters:
    ///   - online: Whether the Mac was online at the click.
    ///   - readLibrary: Reads a file of the shared paper library.
    ///   - readFile: Reads a local file by path.
    /// - Returns: The hand-off and its notes, or `nil` when the document has
    ///   no identifier and no text.
    func studyAnalyzerHandoff(
        online: Bool,
        readLibrary: (LibraryFileReference) -> Result<Data, LibraryLookupFailure>,
        readFile: (String) throws -> Data
    ) -> StudyAnalyzerHandoffChoice? {
        var notes: [String] = []
        let source = fullTextSource.flatMap { AppFullTextSource(rawValue: $0) }
        let sourceName = source?.displayName

        func handoff(_ fullText: StudyAnalyzerHandoff.FullText?) -> StudyAnalyzerHandoffChoice? {
            let handoff = StudyAnalyzerHandoff(pmid: pmid, doi: usableDOI, pmcid: pmcId,
                                               title: title, fullText: fullText)
            return handoff.hasContent ? StudyAnalyzerHandoffChoice(handoff: handoff, notes: notes) : nil
        }

        /// `data` when it is not over the cap; else nil, noted as `what`.
        func capped(_ data: Data, _ what: String) -> Data? {
            guard data.count > BioMedLitConstants.handoffMaxFileBytes else { return data }
            notes.append(String(format: StudyAnalyzerText.tooLarge, what, BioMedLitConstants.handoffMaxFileBytes >> 20))
            return nil
        }

        /// The library's file of `kind`, read, or nil (noted) when it cannot be.
        func libraryFile(_ kind: String, _ what: String) -> Data? {
            guard fullTextLibraryKind == kind, let sha256 = fullTextLibrarySHA256 else { return nil }
            switch readLibrary(LibraryFileReference(sha256: sha256, kind: kind)) {
            case .success(let data): return capped(data, what)
            case .failure(let failure):
                notes.append(String(format: StudyAnalyzerText.unreadable, what, failure.description))
                return nil
            }
        }

        let hasLibraryJATS = fullTextLibraryKind == BioMedLitConstants.libraryKindJATS && fullTextLibrarySHA256 != nil
        if let jats = libraryFile(BioMedLitConstants.libraryKindJATS, StudyAnalyzerText.libraryJATS) {
            return handoff(.init(format: .jats, data: jats, source: sourceName))
        }

        let cameFromJATS = hasLibraryJATS || source == .europePMC || source == .pmcOpenData
        let ids = StudyAnalyzerHandoff(pmid: pmid, doi: usableDOI, pmcid: pmcId, title: nil, fullText: nil)
        if online, cameFromJATS, ids.hasContent {
            return handoff(nil)
        }

        if let path = localPDFFilePath {
            do {
                if let pdf = capped(try readFile(path), StudyAnalyzerText.pdf) {
                    let name = (path as NSString).lastPathComponent
                    return handoff(.init(format: .pdf, data: pdf, fileName: name, source: sourceName))
                }
            } catch {
                notes.append(String(format: StudyAnalyzerText.unreadable, StudyAnalyzerText.pdf,
                                    error.localizedDescription))
            }
        }
        if let pdf = libraryFile(BioMedLitConstants.libraryKindPDF, StudyAnalyzerText.libraryPDF) {
            return handoff(.init(format: .pdf, data: pdf, source: sourceName))
        }

        if let markdown = fullTextContent, !markdown.isEmpty,
           let data = capped(Data(markdown.utf8), StudyAnalyzerText.markdown) {
            return handoff(.init(format: .markdown, data: data, source: sourceName))
        }
        if let html = fullTextHTML, !html.isEmpty,
           let data = capped(Data(html.utf8), StudyAnalyzerText.html) {
            return handoff(.init(format: .html, data: data, source: sourceName))
        }
        return handoff(nil)
    }
}

/// The reader-facing sentences of a hand-off's notes.
enum StudyAnalyzerText {
    /// "<what> could not be read: <why>"
    static let unreadable = "%@ could not be read: %@"
    /// "<what> is larger than StudyAnalyzer accepts (<n> MiB)."
    static let tooLarge = "%@ is larger than StudyAnalyzer accepts (%d MiB)."
    static let libraryJATS = "The library's JATS file"
    static let libraryPDF = "The library's PDF"
    static let pdf = "The PDF"
    static let markdown = "The text"
    static let html = "The HTML"
}
