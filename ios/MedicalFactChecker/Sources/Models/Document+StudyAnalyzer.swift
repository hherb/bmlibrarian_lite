// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import Foundation
import BioMedLit

/// What a document hands StudyAnalyzer, and why any source was passed over.
struct StudyAnalyzerHandoffChoice: Equatable, Sendable {
    /// The hand-off to write.
    let handoff: StudyAnalyzerHandoff
    /// One sentence per source tried and passed over, in order (a read that
    /// failed, a file too large), then one saying what was sent instead;
    /// empty when the first source tried was sent.
    let notes: [String]
}

/// What a document holds that a hand-off to StudyAnalyzer is chosen from,
/// copied off the `Document` on the main actor so the choice, its reads and
/// the encoding can run elsewhere.
struct StudyAnalyzerPaper: Equatable, Sendable {
    let pmid: String
    let doi: String?
    let pmcid: String?
    let title: String
    let source: AppFullTextSource?
    let libraryKind: String?
    let librarySHA256: String?
    let localPDFPath: String?
    let markdown: String?
    let html: String?

    /// What to hand StudyAnalyzer (StudyAnalyzer's shared-library design §3),
    /// or `nil` when there is nothing to send.
    ///
    /// What StudyAnalyzer cannot fetch itself, first match winning: the
    /// library's JATS file; identifiers only for a paper whose text came from
    /// JATS while online (StudyAnalyzer fetches the JATS); the local PDF, else
    /// the library's PDF; the Markdown; the HTML; identifiers only. Offline,
    /// the identifiers-only step is skipped, so whatever the app has is sent.
    /// A read that fails, or a file over its format's cap, is passed over
    /// with a note.
    ///
    /// - Parameters:
    ///   - online: Whether the Mac was online at the click.
    ///   - readLibrary: Reads a file of the shared paper library.
    ///   - readFile: Reads a local file by path.
    /// - Returns: The hand-off and its notes, or `nil` when the paper has no
    ///   identifier and no text.
    func handoff(
        online: Bool,
        readLibrary: (LibraryFileReference) -> Result<Data, LibraryLookupFailure>,
        readFile: (String) throws -> Data
    ) -> StudyAnalyzerHandoffChoice? {
        var notes: [String] = []
        let sourceName = source?.displayName

        /// The choice of `fullText` (nil: identifiers only), named `sent` in
        /// the closing note when a source was passed over before it.
        func handoff(_ fullText: StudyAnalyzerHandoff.FullText?, sent: String) -> StudyAnalyzerHandoffChoice? {
            let handoff = StudyAnalyzerHandoff(pmid: pmid, doi: doi, pmcid: pmcid,
                                               title: title, fullText: fullText)
            guard handoff.hasContent else { return nil }
            if !notes.isEmpty { notes.append(sent) }
            return StudyAnalyzerHandoffChoice(handoff: handoff, notes: notes)
        }

        /// `data` when it is not over `cap` bytes; else nil, noted as `what`.
        func capped(_ data: Data, _ what: String, _ cap: Int) -> Data? {
            guard data.count > cap else { return data }
            notes.append(String(format: StudyAnalyzerText.tooLarge, what, cap >> 20))
            return nil
        }

        /// The library's file of `kind`, read, or nil (noted) when it cannot be.
        func libraryFile(_ kind: String, _ what: String, _ cap: Int) -> Data? {
            guard libraryKind == kind, let librarySHA256 else { return nil }
            switch readLibrary(LibraryFileReference(sha256: librarySHA256, kind: kind)) {
            case .success(let data): return capped(data, what, cap)
            case .failure(let failure):
                notes.append(String(format: StudyAnalyzerText.unreadable, what, failure.description))
                return nil
            }
        }

        let hasLibraryJATS = libraryKind == BioMedLitConstants.libraryKindJATS && librarySHA256 != nil
        if let jats = libraryFile(BioMedLitConstants.libraryKindJATS, StudyAnalyzerText.libraryJATS,
                                  BioMedLitConstants.handoffMaxTextBytes) {
            return handoff(.init(format: .jats, data: jats, source: sourceName),
                           sent: String(format: StudyAnalyzerText.sentInstead, StudyAnalyzerText.libraryJATS))
        }

        let cameFromJATS = hasLibraryJATS || source == .europePMC || source == .pmcOpenData
        let ids = StudyAnalyzerHandoff(pmid: pmid, doi: doi, pmcid: pmcid, title: nil, fullText: nil)
        if online, cameFromJATS, ids.hasContent {
            return handoff(nil, sent: StudyAnalyzerText.identifiersSent)
        }

        if let path = localPDFPath {
            do {
                if let pdf = capped(try readFile(path), StudyAnalyzerText.pdf, BioMedLitConstants.handoffMaxPDFBytes) {
                    let name = (path as NSString).lastPathComponent
                    return handoff(.init(format: .pdf, data: pdf, fileName: name, source: sourceName),
                                   sent: String(format: StudyAnalyzerText.sentInstead, StudyAnalyzerText.pdf))
                }
            } catch {
                notes.append(String(format: StudyAnalyzerText.unreadable, StudyAnalyzerText.pdf,
                                    error.localizedDescription))
            }
        }
        if let pdf = libraryFile(BioMedLitConstants.libraryKindPDF, StudyAnalyzerText.libraryPDF,
                                 BioMedLitConstants.handoffMaxPDFBytes) {
            return handoff(.init(format: .pdf, data: pdf, source: sourceName),
                           sent: String(format: StudyAnalyzerText.sentInstead, StudyAnalyzerText.libraryPDF))
        }

        if let markdown, !markdown.isEmpty,
           let data = capped(Data(markdown.utf8), StudyAnalyzerText.markdown, BioMedLitConstants.handoffMaxTextBytes) {
            return handoff(.init(format: .markdown, data: data, source: sourceName),
                           sent: String(format: StudyAnalyzerText.sentInstead, StudyAnalyzerText.markdown))
        }
        if let html, !html.isEmpty,
           let data = capped(Data(html.utf8), StudyAnalyzerText.html, BioMedLitConstants.handoffMaxHTMLBytes) {
            return handoff(.init(format: .html, data: data, source: sourceName),
                           sent: String(format: StudyAnalyzerText.sentInstead, StudyAnalyzerText.html))
        }
        return handoff(nil, sent: StudyAnalyzerText.identifiersSent)
    }
}

extension Document {
    /// This document's fields a hand-off to StudyAnalyzer is chosen from.
    /// A body-less (abstract-only) record holds no article text, so neither
    /// its Markdown nor its HTML is offered (``analyzableFullText``'s rule).
    var studyAnalyzerPaper: StudyAnalyzerPaper {
        let abstractOnly = storedContentKind == .abstract
        return StudyAnalyzerPaper(
            pmid: pmid, doi: usableDOI, pmcid: pmcId, title: title,
            source: fullTextSource.flatMap { AppFullTextSource(rawValue: $0) },
            libraryKind: fullTextLibraryKind, librarySHA256: fullTextLibrarySHA256,
            localPDFPath: localPDFFilePath, markdown: analyzableFullText,
            html: abstractOnly ? nil : fullTextHTML
        )
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
    /// "<what> was sent instead."
    static let sentInstead = "%@ was sent instead."
    static let identifiersSent = "Only the paper's identifiers were sent."
}
