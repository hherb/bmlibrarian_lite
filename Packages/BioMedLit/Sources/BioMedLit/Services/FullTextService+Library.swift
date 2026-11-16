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

import CryptoKit
import Foundation

// MARK: - Shared paper library

extension FullTextService {
    /// The shared library's part in one fetch (bmlib's `_FromLibrary`): the
    /// paper it is told of, the PDFs the fetch kept there, and the library
    /// failures met. A library error ends the library's use for the rest of
    /// the call (bmlib's rule); a library PDF of another article is only
    /// reported, so the PDF the chain downloads instead is still kept. One per
    /// ``fetchFullText(pmcId:doi:pmid:primaryKind:title:)`` call, passed down
    /// the chain and never shared, so two fetches interleaving on the actor
    /// cannot see each other's failure.
    final class LibraryLookup {
        /// The library, or `nil` when none is set.
        private let library: (any FullTextLibrary)?
        /// The paper as the library is told of it.
        let paper: LibraryPaper
        /// The library failures in this call, in the order met.
        private var failures: [String] = []
        /// Whether a failure ended the library's use in this call.
        private var ended = false
        /// Whether the library could not be read or written in this call, so
        /// a source the chain fetched and could not keep waits for it (design
        /// §4.6). Not for a file of another paper, nor a use that could not be
        /// noted: neither leaves a source out of the library.
        private(set) var unreachable = false
        /// Whether a JATS was left waiting in the PDF cache.
        private var wroteWaitingJATS = false
        /// The PDFs this call kept in the library, by the path a result
        /// reads them from (the library's, or an earlier fetch's cache copy).
        private var kept: [String: LibraryFileReference] = [:]

        /// The part of one fetch for `paper` in `library`, `nil` for none.
        init(library: (any FullTextLibrary)?, paper: LibraryPaper) {
            self.library = library
            self.paper = paper
        }

        /// The library while this call may still use it: one is set and no
        /// failure has ended its use.
        var inUse: (any FullTextLibrary)? { ended ? nil : library }

        /// Record a library failure, already logged where it was worded.
        ///
        /// - Parameters:
        ///   - text: The failure, for the result's `libraryFailure`.
        ///   - ends: Whether the library is not used again in this call.
        ///   - unreachable: Whether the library could not be read or written.
        func fail(_ text: String, ends: Bool, unreachable: Bool) {
            failures.append(text)
            ended = ended || ends
            self.unreachable = self.unreachable || unreachable
        }

        /// Record a PDF kept in the library, so the result read from `path`
        /// names its file.
        func record(_ file: LibraryFileReference, at path: String) {
            kept[path] = file
        }

        /// Record that a JATS waits for the library in the PDF cache.
        func recordWaitingJATS() {
            wroteWaitingJATS = true
        }

        /// `result` with this call's library failures (one sentence each, in
        /// order), its library file (its own, else that of the PDF it reads,
        /// when this call kept it), and whether a source waits for the
        /// library: a JATS left in the cache, or the result's own PDF, read
        /// from the cache and not kept because the library could not be
        /// reached. Unchanged without a library.
        func finish(_ result: FullTextResult) -> FullTextResult {
            guard library != nil else { return result }
            let file = result.libraryFile ?? result.localPDFPath.flatMap { kept[$0] }
            let pdfWaits = unreachable && file == nil && result.localPDFPath != nil && result.source != .library
            return result.noting(
                libraryFile: file,
                libraryFailure: failures.isEmpty
                    ? nil : failures.joined(separator: BioMedLitConstants.libraryFailureSeparator),
                libraryWaiting: wroteWaitingJATS || pdfWaits
            )
        }
    }

    /// The paper as the library is told of it: the request's own identifiers,
    /// never ones a lookup resolved (as ``ArticleCacheKey`` is built, so the
    /// paper is filed the same way on every run), and its title.
    ///
    /// Read as bmlib's `library_request_ids` reads them, so both make the same
    /// lookup: the primary slot is the pmid only when it is ASCII digits and
    /// not all zeros; a PMC ID in it (`PMC` and digits) is the PMC ID when the
    /// request names none; anything else (a `PPR` accession included) is not
    /// passed. A slot whose kind says it is no PubMed ID (another Europe PMC
    /// source's accession, a preprint's, a PMC record's) is never the pmid,
    /// digits or not: the library would file the paper under another's PMID.
    ///
    /// - Parameters:
    ///   - pmcId: The request's PMC ID, passed as given (blank is none).
    ///   - doi: The request's DOI.
    ///   - pmid: The request's primary slot.
    ///   - primaryKind: What the slot holds, when stated.
    ///   - title: The article's title.
    /// - Returns: The paper.
    public static func libraryPaper(
        pmcId: String?, doi: String?, pmid: String, primaryKind: ArticleIdentifierKind?, title: String?
    ) -> LibraryPaper {
        let slot = pmid.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = ArticleIdentifierKind.resolved(declared: primaryKind, accession: slot)
        let mayBePubMed = kind == .pubmed || kind == .unknown
        let usablePMID = mayBePubMed && ArticleIdentifierKind.isAllASCIIDigits(slot) && slot.contains { $0 != "0" }
        let prefix = BioMedLitConstants.pmcAccessionPrefix
        let pmcShaped = slot.hasPrefix(prefix) && ArticleIdentifierKind.isAllASCIIDigits(String(slot.dropFirst(prefix.count)))
        let givenPMCID = pmcId.flatMap { $0.isEmpty ? nil : $0 }
        return LibraryPaper(
            pmid: usablePMID ? slot : nil,
            doi: trimmed(doi),
            pmcId: givenPMCID ?? (pmcShaped ? slot : nil),
            title: trimmed(title)
        )
    }

    /// The library's usable JATS, rendered as the lookup's result, its use
    /// noted in this installation's record.
    ///
    /// - Parameters:
    ///   - xml: The JATS, digest checked.
    ///   - file: The library's file of it.
    ///   - lookup: The fetch's part of the library.
    ///   - articleName: How the log names the article.
    /// - Returns: The result, or `nil` when it does not render here (warned
    ///   of, and the chain runs).
    func libraryJATSResult(
        _ xml: Data, file: LibraryFileReference, lookup: LibraryLookup, articleName: String
    ) -> FullTextResult? {
        let content: EuropePMCRendering
        do {
            content = try renderEuropePMCXML(xml, accession: lookup.paper.pmcId ?? "")
        } catch {
            BioMedLitLib.logger?.warning(
                "The library's JATS for \(articleName) could not be rendered (\(error)); looking further",
                category: .fullText
            )
            return nil
        }
        // A note that fails ends the library's use, but the JATS is still
        // served: its bytes passed the digest check (bmlib's rule). It is in
        // the library already; a source fetched past it (an abstract held
        // back) waits when the library could not be reached.
        if let failure = lookup.inUse?.noteUse(file, paper: lookup.paper) {
            lookup.fail(failure.description, ends: true, unreachable: failure.waits)
        }
        BioMedLitLib.logger?.info("Serving the library's JATS for \(articleName)", category: .fullText)
        return FullTextResult(
            content: .libraryJATS(html: content.html, markdown: content.markdown),
            warnings: content.warnings,
            contentKind: content.contentKind,
            libraryFile: file
        )
    }

    /// A JATS a chain tier served and rendered, kept in the library when it
    /// has a body (bmlib keeps no body-less one). While the library cannot be
    /// reached it waits in the PDF cache instead (``writeWaitingJATS(_:key:)``).
    ///
    /// - Parameters:
    ///   - xml: The JATS as served.
    ///   - content: Its rendering.
    ///   - origin: The tier that served it.
    ///   - key: Names the article in the PDF cache, or `nil` for none.
    ///   - lookup: The fetch's part of the library.
    /// - Returns: The library's file of it, or `nil` when it was not kept.
    func keptJATS(
        _ xml: Data, _ content: EuropePMCRendering, origin: FullTextSource, key: ArticleCacheKey?,
        lookup: LibraryLookup
    ) -> LibraryFileReference? {
        guard content.contentKind != .abstract else { return nil }
        if let library = lookup.inUse {
            switch library.keep(xml, kind: BioMedLitConstants.libraryKindJATS, paper: lookup.paper,
                                origin: origin.displayName) {
            case .success(let kept):
                if let kept {
                    BioMedLitLib.logger?.info(
                        "JATS from \(origin.displayName) kept in the library at \(kept.path)", category: .fullText
                    )
                }
                return kept?.file
            case .failure(let failure):
                lookup.fail(failure.description, ends: true, unreachable: failure.waits)
            }
        }
        if lookup.unreachable, let key, Self.writeWaitingJATS(xml, key: key) { lookup.recordWaitingJATS() }
        return nil
    }

    /// A JATS kept while the library cannot be reached, waiting in the PDF
    /// cache as `<cacheKey>-<sha12>.xml` (design §4.6; moving it in is step
    /// 3c's). A write that fails is logged: the article's text is still
    /// served, and the result's library failure already says the library was
    /// not reached.
    ///
    /// - Parameters:
    ///   - xml: The JATS as served.
    ///   - key: Names the article.
    /// - Returns: Whether it was written.
    @discardableResult
    static func writeWaitingJATS(_ xml: Data, key: ArticleCacheKey) -> Bool {
        let name = LibraryMove.appCopyName(key: key, sha256: LibraryMove.sha256(xml),
                                           kind: BioMedLitConstants.libraryKindJATS)
        let url = pdfCacheDirectory.appendingPathComponent(name)
        do {
            try writeAtomically(xml, to: url)
            BioMedLitLib.logger?.info(
                "JATS for \(key.logDescription) waits for the library at \(url.path)", category: .fullText
            )
            return true
        } catch {
            BioMedLitLib.logger?.error(
                "Could not keep the JATS for \(key.logDescription) waiting for the library at \(url.path): "
                    + error.localizedDescription,
                category: .fullText
            )
            return false
        }
    }

    /// The library's PDF of the paper as the lookup's result, read in place
    /// of a download (design §4.5), its use noted.
    ///
    /// Checked against the title first (§4.4: a record is a claim, not proof),
    /// once, on the library's path: a PDF the check refuses is not served, is
    /// reported as one of the call's library failures without ending the
    /// library's use (the PDF downloaded instead is kept), and is left where
    /// it is (a cached one would be set aside; the library's files are
    /// bmlib's).
    ///
    /// - Parameters:
    ///   - lookup: The fetch's part of the library.
    ///   - title: The article's title, or `nil` to check nothing.
    ///   - degradation: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:libraryFile:)``.
    ///   - holdingAbstract: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:libraryFile:)``.
    ///   - articleName: How the log names the article.
    /// - Returns: The result, or `nil` to go on down the chain.
    /// - Throws: `CancellationError`.
    func libraryPDFResult(
        lookup: LibraryLookup,
        title: String?,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String
    ) throws -> FullTextResult? {
        guard let library = lookup.inUse else { return nil }
        let held: LibraryHeldPDF
        switch library.pdf(for: lookup.paper) {
        case .success(let found?): held = found
        case .success(nil): return nil
        case .failure(let failure):
            lookup.fail(failure.description, ends: true, unreachable: failure.waits)
            return nil
        }
        if let title, try refusesAsAnotherArticle(held.path, title: title, inLibrary: true) {
            let url = URL(fileURLWithPath: held.path)
            let message = BioMedLitConstants.libraryPDFAnotherArticleFailure(
                file: "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
            )
            BioMedLitLib.logger?.warning(message, category: .fullText)
            // Reported, and the library stays in use: the PDF the chain
            // downloads instead is kept, and outranks this one as the newer
            lookup.fail(message, ends: false, unreachable: false)
            return nil
        }
        // Judged already: read without a second check. With extraction off
        // nothing is read, and the file is served as one without text.
        let outcome = extractPDFText
            ? try extractText(fromCachedPDF: held.path, title: nil)
            : .noText(localPath: held.path, coverage: nil)
        if case .vanished = outcome {
            BioMedLitLib.logger?.warning(
                BioMedLitConstants.libraryPDFGoneWarning(path: held.path), category: .fullText
            )
            return nil
        }
        // Served all the same: it is in the library already, and a source
        // fetched past it waits when the library could not be reached
        if let failure = library.noteUse(held.file, paper: lookup.paper) {
            lookup.fail(failure.description, ends: true, unreachable: failure.waits)
        }
        BioMedLitLib.logger?.info(
            "Using the library's PDF \(held.path) for \(articleName) in place of a download", category: .fullText
        )
        // A PDF in hand: no download failed, so no link
        var noLink: FullTextResult?
        return pdfTierResult(
            outcome: outcome,
            content: .libraryPDF(localPath: held.path),
            degradation: degradation,
            holdingAbstract: holdingAbstract,
            articleName: articleName,
            linkFallback: &noLink,
            libraryFile: held.file
        )
    }

    /// A PDF a tier read from the cache, kept in the library (design §4.5).
    /// One this call downloaded and admitted loses its cache copy once the
    /// library holds it (the save returned), and the outcome reads from the
    /// library's file. One an earlier fetch cached is kept too, but its cache
    /// copy stays and is still read from: an earlier session's document may
    /// point at it, and moving it in is §4.7's move, step 3c's. A PDF the
    /// save refuses stays in the cache, read from there, and the failure is
    /// the call's. Any other outcome, or no library in use, is returned as it
    /// is.
    ///
    /// - Parameters:
    ///   - read: What the tier's read came to, and whether this call admitted
    ///     its PDF to the cache.
    ///   - origin: The tier, whose display name the library records.
    ///   - lookup: The fetch's part of the library.
    /// - Returns: The outcome, its path the library's when this call's copy
    ///   was kept.
    func keptInLibrary(
        _ read: (outcome: PDFTierOutcome, admitted: Bool), origin: FullTextSource, lookup: LibraryLookup
    ) -> PDFTierOutcome {
        let outcome = read.outcome
        guard let library = lookup.inUse else { return outcome }
        let cachePath: String
        switch outcome {
        case .noText(let path, _), .extracted(let path, _, _): cachePath = path
        case .notAttempted, .downloadFailed, .notCached, .wrongArticle, .vanished: return outcome
        }
        let bytes: Data
        do {
            bytes = try Data(contentsOf: URL(fileURLWithPath: cachePath))
        } catch {
            // Another service fetching the paper kept it and removed this
            // copy meanwhile: read from the library's file, not a gone path
            if !FileManager.default.fileExists(atPath: cachePath),
               let held = heldInstead(of: cachePath, lookup: lookup) {
                return Self.outcome(outcome, readingFrom: held.path)
            }
            // Not the library's failure: the PDF is served from the cache
            BioMedLitLib.logger?.warning(
                "Could not read the cached PDF \(cachePath) to keep it in the library "
                    + "(\(error.localizedDescription)); serving it from the cache",
                category: .fullText
            )
            return outcome
        }
        let kept: LibraryKept
        switch library.keep(bytes, kind: BioMedLitConstants.libraryKindPDF, paper: lookup.paper,
                            origin: origin.displayName) {
        case .success(let file?): kept = file
        case .success(nil): return outcome
        case .failure(let failure):
            lookup.fail(failure.description, ends: true, unreachable: failure.waits)
            return outcome
        }
        BioMedLitLib.logger?.info(
            "PDF from \(origin.displayName) kept in the library at \(kept.path)", category: .fullText
        )
        guard read.admitted else {
            // An earlier fetch's copy: left, and still read from (Ruling L′)
            lookup.record(kept.file, at: cachePath)
            return outcome
        }
        lookup.record(kept.file, at: kept.path)
        do {
            try FileManager.default.removeItem(atPath: cachePath)
        } catch {
            // Only disk: the library's copy is the one read from now
            BioMedLitLib.logger?.warning(
                "Could not remove the cache copy \(cachePath) of a PDF the library holds: "
                    + error.localizedDescription,
                category: .fullText
            )
        }
        return Self.outcome(outcome, readingFrom: kept.path)
    }

    /// The library's PDF of the paper, read in place of a cache copy that
    /// went away before it could be kept (another fetch kept it and removed
    /// it), recorded as the call's. A library that cannot be read is the
    /// call's failure.
    ///
    /// - Parameters:
    ///   - cachePath: The cache copy that is gone, for the log.
    ///   - lookup: The fetch's part of the library.
    /// - Returns: The library's PDF, or `nil` when it holds none or cannot
    ///   be read.
    private func heldInstead(of cachePath: String, lookup: LibraryLookup) -> LibraryHeldPDF? {
        guard let library = lookup.inUse else { return nil }
        switch library.pdf(for: lookup.paper) {
        case .success(let held?):
            BioMedLitLib.logger?.info(
                "The cached PDF \(cachePath) went away before it was kept (another fetch kept it?); "
                    + "reading the library's \(held.path)",
                category: .fullText
            )
            lookup.record(held.file, at: held.path)
            return held
        case .success(nil):
            return nil
        case .failure(let failure):
            lookup.fail(failure.description, ends: true, unreachable: failure.waits)
            return nil
        }
    }

    /// `outcome`, read from `path`: a PDF's outcome moved to where it is read
    /// from now; any other outcome unchanged.
    private static func outcome(_ outcome: PDFTierOutcome, readingFrom path: String) -> PDFTierOutcome {
        switch outcome {
        case .noText(_, let coverage): return .noText(localPath: path, coverage: coverage)
        case .extracted(_, let text, let coverage):
            return .extracted(localPath: path, text: text, coverage: coverage)
        case .notAttempted, .downloadFailed, .notCached, .wrongArticle, .vanished: return outcome
        }
    }
}
