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

import Foundation

extension FullTextService {
    // MARK: - PDF Caching

    /// Return this article's cached PDF, downloading it first if there is none.
    ///
    /// The cache check is step one, as `doc/cross_platform/fulltext_retrieval.md`
    /// specifies for every platform. Without it this method re-downloaded on
    /// every call — a second fetch of bytes already on disk — and
    /// ``cachedPDFPath(for:)``'s validation and quarantine had no production
    /// caller at all, so a corrupt entry was never moved aside by anything but a
    /// test. A cached entry that fails validation is quarantined there and reads
    /// as a miss, which is exactly what makes the download below the repair.
    ///
    /// The article is named by an ``ArticleCacheKey`` rather than by a PMID,
    /// because a PMID is not the only identifier an article has and was not
    /// always present. An empty PMID used to be refused outright — correctly,
    /// since every such article would otherwise share one entry — but that cost
    /// those articles their extraction entirely (#202). The key falls back to
    /// the PMC ID and then the DOI, and only an article carrying none of the
    /// three has no name to file bytes under. No *key* can be constructed for
    /// such an article — the article itself certainly exists — so this method,
    /// which takes a key, has no refusal left to make.
    ///
    /// The download is ``obtainPDF(from:for:)``'s, which tells a bot wall's
    /// challenge page from a PDF (#480).
    ///
    /// No title is checked here: the download replaces its cache name, in one
    /// rename, once it has arrived whole. ``fetchFullText(pmcId:doi:pmid:primaryKind:title:)``
    /// does not come this way; it checks each download before it is cached
    /// (#560). Internal, not public, so that no caller outside this module
    /// caches a PDF its check never saw; the tests reach the cache through it.
    ///
    /// - Parameters:
    ///   - url: URL to download the PDF from, on a cache miss.
    ///   - key: Names the article the bytes belong to.
    /// - Returns: Local file path to the cached PDF.
    /// - Throws: `FullTextError` on failure.
    func downloadAndCachePDF(from url: URL, for key: ArticleCacheKey) async throws -> String {
        switch try await obtainPDF(from: url, for: key) {
        case .cached(let path):
            return path
        case .staged(let staged, let cachePath):
            defer { Self.discardStaged(staged) }
            guard Self.promote(staged: staged, to: cachePath) else {
                throw FullTextError.cachingFailed("the downloaded PDF could not be moved into the cache")
            }
            BioMedLitLib.logger?.info("Cached PDF at: \(cachePath)", category: .fullText)
            return cachePath
        }
    }

    /// A PDF a tier is about to read (#560): one cached earlier, which is
    /// checked against the title when it is read, or one just downloaded,
    /// waiting beside its cache name until its check lets it in.
    enum ObtainedPDF {
        /// The cache already held it, under the name it is read from.
        case cached(path: String)

        /// Downloaded and written beside its cache name; nothing reads it but
        /// its title check (``admit(staged:cachePath:title:)``).
        case staged(path: String, cachePath: String)
    }

    /// This article's cached PDF from `url`, or, on a miss, the download
    /// written beside its cache name: the half of
    /// ``downloadAndCachePDF(from:for:)`` before anything is cached.
    ///
    /// A download is never written to its cache name before its title check
    /// (#560), as Python stages one at `unchecked_download_path`: written
    /// there first, another service fetching the same article at the same
    /// time could take it from the cache while this one sets it aside, and
    /// count another article's PDF as a copy served. Each download waits under
    /// a name of its own (a UUID before ``BioMedLitConstants/pdfUncheckedSuffix``),
    /// since the app builds a service per call and two may download one PDF.
    ///
    /// An answer that is not a PDF and that ``BotWalls`` recognises as a bot
    /// wall's challenge page throws `.pdfDownloadFailed(.challenged(...))`
    /// (#480). Every caller shares the check; Europe PMC's render tier records
    /// no shortfall from it, so only Unpaywall's and OpenAlex's copies are
    /// told as challenged, as Python checks those copies alone. The body is
    /// read whole, so a page that breaks off is the transport's failure here,
    /// where Python and Android judge what arrived of it.
    ///
    /// - Parameters:
    ///   - url: URL to download the PDF from, on a cache miss.
    ///   - key: Names the article the bytes belong to.
    /// - Returns: Where the PDF is, and whether it still waits for its check.
    /// - Throws: `FullTextError.pdfDownloadFailed` when the source did not
    ///   serve a PDF, `FullTextError.cachingFailed` when it could not be
    ///   written, `CancellationError` when cancelled.
    func obtainPDF(from url: URL, for key: ArticleCacheKey) async throws -> ObtainedPDF {
        if let cached = Self.cachedPDFPath(for: key, from: url) {
            BioMedLitLib.logger?.info(
                "Serving the cached PDF for \(key.logDescription) from \(cached)",
                category: .fullText
            )
            return .cached(path: cached)
        }

        BioMedLitLib.logger?.info(
            "Downloading PDF for \(key.logDescription) from \(url.absoluteString)",
            category: .fullText
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await RetryHelper.retry(
                config: .pdfDownload,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                try await self.session.data(from: url)
            }
        } catch where error.isCancellation {
            throw CancellationError()
        } catch {
            throw FullTextError.pdfDownloadFailed(SearchTransport.failure(for: error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.pdfDownloadFailed(.malformedResponse)
        }
        let headers = Dictionary(
            httpResponse.allHeaderFields.compactMap { key, value in
                (key as? String).map { ($0, "\(value)") }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let pdfMagic = Data(BioMedLitConstants.pdfMagicBytes)
        let isPDF = data.count > pdfMagic.count && data.prefix(pdfMagic.count) == pdfMagic
        // A bot wall's challenge page in place of the PDF is no answer about
        // the article (#480), whatever status it came with but a gone 404 or 410.
        if !isPDF, let challenge = BotWalls.challengeFailure(
            status: httpResponse.statusCode, headers: headers, body: data
        ) {
            let defences = BotWalls.challengeMarkers(status: httpResponse.statusCode, headers: headers, body: data)
            BioMedLitLib.logger?.warning(
                "A bot wall's challenge answered \(url.absoluteString) (HTTP \(httpResponse.statusCode)): "
                    + defences.joined(separator: ", "),
                category: .fullText
            )
            throw FullTextError.pdfDownloadFailed(challenge)
        }
        guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed(.httpStatus(httpResponse.statusCode))
        }
        // A login page served with a 200 stops here (#478).
        guard isPDF else {
            throw FullTextError.pdfDownloadFailed(.malformedResponse)
        }

        let cachePath = Self.cachePath(for: key, from: url)
        return .staged(path: try stagePDF(data: data, beside: cachePath), cachePath: cachePath)
    }

    /// What became of a download once its title was checked (#560).
    enum Admission {
        /// Moved into its cache name, to be read from there.
        case admitted(path: String)

        /// Another article's PDF, set aside beside the cache name unread.
        case refused

        /// It could not be moved into its cache name, after a check that did
        /// not refuse it: a fault of ours.
        case notCached

        /// It was gone before its check (a clearing of the cache removed it):
        /// never judged, so never let in, linked or counted as a copy served.
        case gone
    }

    /// Check a download waiting beside its cache name against the article's
    /// title, then let it in or set it aside (#560).
    ///
    /// Only a mismatch refuses it: the file goes to the cache name's
    /// ``BioMedLitConstants/pdfMismatchSuffix`` name, never to the cache name,
    /// so neither this fetch nor any other reads it; the PDF already cached
    /// under the cache name is left alone, and an earlier set-aside is
    /// replaced. A check that judged nothing lets it in, as
    /// ``extractText(fromCachedPDF:title:)`` keeps a cached one. A waiting file
    /// already gone is `.gone`, not checked: a check of no file judges
    /// nothing, and would let a PDF never read be linked. The waiting file is
    /// gone on every outcome.
    ///
    /// - Parameters:
    ///   - staged: The download, where it waits.
    ///   - cachePath: The cache name it is to take.
    ///   - title: The article's title, or `nil` to check nothing.
    /// - Returns: Where it now is, or that it was refused, could not be moved
    ///   or was gone.
    /// - Throws: `CancellationError` if the caller cancelled during the check.
    func admit(staged: String, cachePath: String, title: String?) throws -> Admission {
        defer { Self.discardStaged(staged) }
        guard FileManager.default.fileExists(atPath: staged) else {
            BioMedLitLib.logger?.warning(
                "The download waiting at \(staged) was gone before its check; not read",
                category: .fullText
            )
            return .gone
        }
        if let title, try refusesAsAnotherArticle(staged, title: title) {
            Self.setAsideWrongArticle(at: staged, besideCacheName: cachePath)
            return .refused
        }
        guard Self.promote(staged: staged, to: cachePath) else { return .notCached }
        BioMedLitLib.logger?.info("Cached PDF at: \(cachePath)", category: .fullText)
        return .admitted(path: cachePath)
    }

    /// Whether a PDF's first page with text fails to carry the article's title
    /// (#546), logged either way it is not a plain match.
    ///
    /// - Parameters:
    ///   - path: The PDF, cached, waiting for its check, or the library's.
    ///   - title: The article's title.
    ///   - inLibrary: Whether `path` is the library's file, which a mismatch
    ///     leaves where it is (the caller sets a cached one aside).
    /// - Returns: `true` for a mismatch, the one outcome that refuses a PDF.
    /// - Throws: `CancellationError` if the caller cancelled during the check.
    func refusesAsAnotherArticle(_ path: String, title: String, inLibrary: Bool = false) throws -> Bool {
        let check = titleChecker(URL(fileURLWithPath: path), title)
        try Task.checkCancellation()
        if case .mismatch(let share) = check {
            BioMedLitLib.logger?.warning(
                "PDF \(path) is another article's: its first page with text carries "
                    + "\(Int((share * 100).rounded()))% of the title's word pairs; "
                    + (inLibrary ? "not read, and left in the library" : "set aside unread"),
                category: .fullText
            )
            return true
        }
        // Told apart from a match in the log: a PDF kept unjudged was never checked
        if check.share == nil {
            BioMedLitLib.logger?.info(
                "PDF \(path) kept unjudged by the title check: \(check.outcomeName)",
                category: .fullText
            )
        }
        return false
    }

    /// What a PDF tier's download-and-extract attempt produced.
    ///
    /// Five outcomes rather than a `(path?, text?)` pair, because two of them
    /// used to share `(nil, nil)` and the tier could not tell them apart. It
    /// therefore keyed its decision to try the next tier on whether an abstract
    /// happened to be in hand, so a Europe PMC render URL that 404s ended the
    /// chain and an open-access Unpaywall copy of the same paper was never
    /// fetched. "We chose not to look" and "we looked and the source is dead"
    /// call for opposite moves.
    enum PDFTierOutcome {
        /// Extraction is switched off, so nothing was downloaded.
        case notAttempted

        /// The source did not serve the PDF, and why (#478): the status, the
        /// transport failure, `challenged` (with its status) for a bot wall's
        /// challenge page (#480), or `malformedResponse` for any other body
        /// that is not a PDF.
        case downloadFailed(RequestFailure)

        /// The source served the PDF, and it could not be cached. A fault of
        /// ours, which says nothing about the copy, so its link is kept even
        /// for a PDF Unpaywall named (#478).
        case notCached

        /// The file is on disk and holds no recoverable prose — a scan, or a
        /// document PDFKit declined to open.
        ///
        /// Carries coverage whenever a page count is known, so the reader can
        /// be told that nothing was recovered. That covers a scan and a
        /// password-protected file alike — PDFKit reports a page count for a
        /// locked document even though it hands back no text. `nil` only when
        /// the file could not be opened at all, where there is nothing to
        /// count and the reason went to the log.
        case noText(localPath: String, coverage: PDFExtractionCoverage?)

        /// Prose was recovered, and this much of the document yielded it.
        case extracted(localPath: String, text: String, coverage: PDFExtractionCoverage)

        /// The file's first page with text does not carry the article's
        /// title: another article's PDF, set aside unread (#546). Neither its
        /// text nor its link is offered; the caller records it and tries the
        /// next source.
        case wrongArticle

        /// The cached file was gone when it was to be read (#560): most often
        /// another fetch of the same article set it aside, refusing it, so it
        /// is no copy served and its link is never kept. A download gone before
        /// its check is the same. ``downloadAndExtract(from:key:title:)``, and
        /// the Elsevier tier for its PDF, ask the source again, once; gone
        /// again, it is returned, and the caller records the source's PDF as
        /// unsettled (`request_failed` with its address; Elsevier's with none,
        /// as its PDF served and not saved is).
        case vanished
    }

    /// Download a PDF tier's file, cache it, and recover its text.
    ///
    /// An ordinary failure — a 404, a server error, a file PDFKit cannot open —
    /// is reported as an outcome rather than thrown. Throwing on those would
    /// turn a tier that merely came up empty into a hard failure of the whole
    /// chain.
    ///
    /// Cancellation is the one thing this does not swallow: it propagates as
    /// `CancellationError`, matching every other guard in this file. A cancelled
    /// download is not a dead source, and letting it fall through here would
    /// return a normal, non-throwing result for a fetch the caller walked away
    /// from — caching a bare link as this article's full text, the outcome
    /// `fetchFullText`'s own doc comment promises cannot happen. The check after
    /// extraction is what makes the extractor's own early exit safe: it stops
    /// mid-document on cancellation, and the partial value it returns is
    /// discarded here rather than reported as a real extraction.
    ///
    /// Every empty outcome is logged at warning level, as bmlib does, because a
    /// scan that yields nothing is invisible otherwise and a partial extraction
    /// must not be mistaken for a whole article.
    ///
    /// - Parameters:
    ///   - url: The remote PDF.
    ///   - key: Names the article, and so the cached file. Non-optional: a
    ///     document carrying no identifier at all reaches no PDF tier in the
    ///     first place, so there is no refusal for this method to make. See
    ///     ``fetchFullText(pmcId:doi:pmid:primaryKind:title:)``.
    ///   - title: The article's title the PDF is checked against (#546), or
    ///     `nil` to check nothing.
    /// - Returns: What the attempt produced (see ``PDFTierOutcome``), and
    ///   whether its PDF was downloaded and admitted to the cache by this
    ///   call rather than cached earlier.
    /// - Throws: `CancellationError` if the caller cancelled.
    func downloadAndExtract(
        from url: URL,
        key: ArticleCacheKey,
        title: String?
    ) async throws -> (outcome: PDFTierOutcome, admitted: Bool) {
        guard extractPDFText else { return (.notAttempted, false) }

        let read = try await obtainAndRead(from: url, key: key, title: title)
        guard case .vanished = read.outcome else { return read }
        // Asked again, once: the cache name is empty now, so this downloads,
        // and the download is judged on its own
        BioMedLitLib.logger?.info(
            "The cached PDF for \(key.logDescription) from \(url.absoluteString) went away before it "
                + "was read (another fetch set it aside?); downloading it again",
            category: .fullText
        )
        let again = try await obtainAndRead(from: url, key: key, title: title)
        guard case .vanished = again.outcome else { return again }
        // Gone a second time: the retry may itself have been a cache hit that
        // another fetch refused, so it is no copy served and keeps no link
        BioMedLitLib.logger?.error(
            "The PDF for \(key.logDescription) from \(url.absoluteString) went away from the cache "
                + "before it was read, twice; that copy is not assessed",
            category: .fullText
        )
        return (.vanished, false)
    }

    /// One attempt of ``downloadAndExtract(from:key:title:)``: the cached PDF
    /// read through its title check, or a download admitted by its check and
    /// then read.
    ///
    /// - Parameters:
    ///   - url: The remote PDF.
    ///   - key: Names the article, and so the cached file.
    ///   - title: The article's title, or `nil` to check nothing.
    /// - Returns: What the attempt produced (`.vanished` when the cached file
    ///   was gone before it was read), and whether its PDF was admitted to the
    ///   cache by this attempt rather than cached earlier.
    /// - Throws: `CancellationError` if the caller cancelled.
    private func obtainAndRead(
        from url: URL,
        key: ArticleCacheKey,
        title: String?
    ) async throws -> (outcome: PDFTierOutcome, admitted: Bool) {
        let obtained: ObtainedPDF
        do {
            obtained = try await obtainPDF(from: url, for: key)
        } catch where error.isCancellation {
            // As above: a cancelled download must not be read as an absent PDF.
            throw CancellationError()
        } catch {
            BioMedLitLib.logger?.warning(
                "Could not download the PDF for \(key.logDescription) from "
                    + "\(url.absoluteString): \(error.localizedDescription); "
                    + "trying the next source",
                category: .fullText
            )
            if case FullTextError.pdfDownloadFailed(let failure) = error {
                return (.downloadFailed(failure), false)
            }
            // The only other failure the download throws is the cache write's
            return (.notCached, false)
        }

        switch obtained {
        case .cached(let path):
            return (try extractText(fromCachedPDF: path, title: title), false)
        case .staged(let staged, let cachePath):
            switch try admit(staged: staged, cachePath: cachePath, title: title) {
            // Judged already: read without a second check
            case .admitted(let path): return (try extractText(fromCachedPDF: path, title: nil), true)
            case .refused: return (.wrongArticle, false)
            case .notCached: return (.notCached, false)
            case .gone: return (.vanished, false)
            }
        }
    }

    /// Recover a cached PDF's text: the half of ``downloadAndExtract(from:key:title:)``
    /// after the download, shared with Elsevier's PDF, which arrives by its own
    /// request (#480, stage C2).
    ///
    /// The one place every PDF passes before its text is used, a copy cached
    /// by an earlier run included, so it is where the title is checked
    /// (#546): only a mismatch refuses the PDF, which is set aside
    /// (``setAsideWrongArticle(at:)``) and never read; a check that judged
    /// nothing (no title, no text, a translated title, a file PDFKit cannot
    /// read) leaves it to the extraction. A download reaches here only once
    /// ``admit(staged:cachePath:title:)`` has judged it, and comes with no
    /// title.
    ///
    /// A file that is gone when it is to be read, or gone once its read failed,
    /// is `.vanished` (#560), never a copy without text: another fetch of the
    /// same article may have set it aside, and the caller asks again.
    ///
    /// - Parameters:
    ///   - path: The cached file.
    ///   - title: The article's title, or `nil` to check nothing.
    /// - Returns: `.noText` or `.extracted`, with the path, `.wrongArticle`,
    ///   or `.vanished`.
    /// - Throws: `CancellationError` if the caller cancelled.
    func extractText(fromCachedPDF path: String, title: String?) throws -> PDFTierOutcome {
        guard FileManager.default.fileExists(atPath: path) else { return .vanished }
        if let title, try refusesAsAnotherArticle(path, title: title) {
            Self.setAsideWrongArticle(at: path)
            return .wrongArticle
        }
        let extraction = extractor.extract(from: URL(fileURLWithPath: path))
        // Before anything is read off `extraction`: the extractor stops early
        // when cancelled, so a cancelled read looks exactly like a short
        // document unless the cancellation is asked about first.
        try Task.checkCancellation()

        // Set aside between the check and the read, by a fetch whose check
        // refused it (#560): no copy of this article
        if !extraction.success, !FileManager.default.fileExists(atPath: path) { return .vanished }
        guard extraction.success else {
            BioMedLitLib.logger?.warning(
                "PDF text extraction failed for \(path): "
                    + "\(extraction.errorMessage ?? "no reason reported")",
                category: .fullText
            )
            // The page count survives a failed read when PDFKit could open the
            // document enough to count pages — a locked file, typically. Passed
            // on so the reader learns that no text reached any analysis, rather
            // than being shown a document that looks entirely ordinary.
            return .noText(
                localPath: path,
                coverage: extraction.pageCount > 0 ? extraction.coverage : nil
            )
        }
        guard extraction.charCount > 0 else {
            BioMedLitLib.logger?.warning(
                "PDF \(path) yielded no extractable text over \(extraction.pageCount) page(s) — "
                    + "likely a scan; "
                    + "\(extraction.warnings.prefix(BioMedLitConstants.loggedPageWarningLimit))",
                category: .fullText
            )
            return .noText(localPath: path, coverage: extraction.coverage)
        }
        if !extraction.isComplete {
            BioMedLitLib.logger?.warning(
                "PDF \(path) extracted only \(extraction.convertedPages) of "
                    + "\(extraction.pageCount) pages — the attached text is incomplete",
                category: .fullText
            )
        }
        BioMedLitLib.logger?.info(
            "Extracted \(extraction.charCount) chars of text from PDF \(path)",
            category: .fullText
        )
        return .extracted(localPath: path, text: extraction.text, coverage: extraction.coverage)
    }

    /// Turn a PDF tier's outcome into the result to return, or `nil` to let the
    /// chain try the next tier.
    ///
    /// Shared by the Europe PMC PDF tier and, through ``tryOpenAccessPDFs``,
    /// every open-access PDF Unpaywall or OpenAlex names, so they cannot decide
    /// this differently — the render and Unpaywall tiers once had one copy of
    /// the rule each, and only one of them was ever updated.
    ///
    /// - Parameters:
    ///   - outcome: What the download and extraction produced.
    ///   - content: The content value to attach to a returned result.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    ///   - holdingAbstract: Whether a body-less rendering is being kept in
    ///     reserve. A tier that recovered nothing must not displace it.
    ///   - articleName: How to name this article in the log line.
    ///   - linkFallback: Set to a link-only result when a download failed, so
    ///     the chain can still offer the URL if no later tier does better.
    ///     First writer wins: the earliest tier is the best-quality source.
    ///   - libraryFile: The library's file of the PDF, for the library's own
    ///     PDF; `nil` — the default — for a tier's.
    /// - Returns: The result to return, or `nil` to continue the chain.
    func pdfTierResult(
        outcome: PDFTierOutcome,
        content: FullTextContent,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        linkFallback: inout FullTextResult?,
        libraryFile: LibraryFileReference? = nil
    ) -> FullTextResult? {
        switch outcome {
        case .downloadFailed, .notCached:
            // Try the next tier, but keep the URL. Returning it here — which is
            // what this did, because a failed download was indistinguishable
            // from "extraction is switched off" — ended the chain on a link we
            // had just proved we could not fetch, so an open-access Unpaywall
            // copy of the same paper was never tried. Held in reserve instead:
            // a link we could not download is still better than a publisher
            // page, and still worse than a copy a later tier actually retrieves.
            // Only the render tier arrives here with either: a PDF an
            // open-access source named is handled by `tryOpenAccessPDFs`,
            // which refuses one not served (#478) and keeps one not cached
            // with its caching note (#480).
            if linkFallback == nil {
                linkFallback = FullTextResult(content: content, degradation: degradation)
            }
            return nil

        case .wrongArticle:
            // Another article's (#546): its link would name that article, so
            // none is kept; the caller records it and the chain goes on
            return nil

        case .vanished:
            // Gone twice (#560), most likely refused by another fetch: no copy
            // was read, and its link, which may name another article, is not
            // kept. The caller records the shortfall
            return nil

        case .notAttempted:
            // Nothing was downloaded because nothing was meant to be. The URL
            // is still worth handing over, unless an abstract is in reserve —
            // a bare link does not beat a rendering of the article's abstract.
            if holdingAbstract { return nil }
            return FullTextResult(content: content, degradation: degradation)

        case .noText(let localPath, let coverage):
            if holdingAbstract {
                BioMedLitLib.logger?.info(
                    "The \(content.source.displayName) PDF yielded no text for \(articleName); "
                        + "keeping the abstract",
                    category: .fullText
                )
                return nil
            }
            // The file is real even though its prose is not, so the path goes
            // with it: a scan is still worth showing the reader. The coverage
            // goes too, so the reader is told that nothing was recovered —
            // otherwise a scan displays as an ordinary article while every
            // analysis of it silently ran on no text at all.
            return FullTextResult(
                content: content,
                degradation: degradation,
                contentKind: .none,
                localPDFPath: localPath,
                extractionCoverage: coverage,
                libraryFile: libraryFile
            )

        case .extracted(let localPath, let text, let coverage):
            return FullTextResult(
                content: content,
                degradation: degradation,
                contentKind: .extracted,
                extractedText: text,
                localPDFPath: localPath,
                extractionCoverage: coverage,
                libraryFile: libraryFile
            )
        }
    }

    /// Try each PDF a source named, in order, until one is served (#480).
    ///
    /// An address already tried is skipped. An address the chain cannot
    /// fetch, a download the source refused, or a PDF of another article
    /// (#546), is added to the shortfall
    /// under `source`, with its address: the reader is told every copy that
    /// went unassessed. **The first copy served ends the walk:** extracted, it
    /// is the result; served but not cached, its link becomes the link
    /// fallback (it beats any held), its address is the caching note, and no
    /// further candidate is asked, saving being our problem, not the source's.
    /// A copy cached without text while an abstract is held settles the
    /// question too, but the walk goes on for a copy with text.
    ///
    /// The caching note's address is the URL the link is kept under
    /// (`absoluteString`), so the app can tell whether the link it stored is
    /// that copy's.
    ///
    /// - Parameters:
    ///   - addresses: The PDF addresses, as the source gave them.
    ///   - source: Whose PDF a failure is recorded against (`.pdf`, `.openAlexPDF`).
    ///   - content: The result content for an address.
    ///   - cacheKey: Names the article, and so the cached file.
    ///   - title: The article's title each PDF is checked against (#546), or `nil`.
    ///   - degradation: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:libraryFile:)``.
    ///   - holdingAbstract: As ``pdfTierResult(outcome:content:degradation:holdingAbstract:articleName:linkFallback:libraryFile:)``.
    ///   - articleName: How to name this article in the log.
    ///   - linkFallback: The chain's link fallback.
    ///   - shortfall: What went unsettled so far; added to.
    ///   - notSavedFrom: Set to the address of a copy served but not cached.
    ///   - copyServed: Set when a copy is served, whether not cached or
    ///     cached without text: either settles the open-access question.
    ///   - tried: Addresses already asked, across sources; updated.
    ///   - lookup: The fetch's part of the library, which each PDF read is
    ///     kept in.
    /// - Returns: The result to return, or `nil` to go on down the chain.
    /// - Throws: `CancellationError`.
    func tryOpenAccessPDFs(
        _ addresses: [String],
        refusedAs source: OpenAccessSource,
        content: (URL) -> FullTextContent,
        cacheKey: ArticleCacheKey,
        title: String?,
        degradation: FullTextDegradation?,
        holdingAbstract: Bool,
        articleName: String,
        linkFallback: inout FullTextResult?,
        shortfall: inout OpenAccessShortfall?,
        notSavedFrom: inout String?,
        copyServed: inout Bool,
        tried: inout Set<String>,
        lookup: LibraryLookup
    ) async throws -> FullTextResult? {
        for address in addresses where tried.insert(address).inserted {
            // An address we cannot fetch leaves that copy unassessed, not
            // absent (#474): refused, recorded against the PDF, not the source
            // that answered (#478). Python's `requests` refuses the same.
            guard let pdfURL = UnpaywallLandingPage.fetchableURL(address) else {
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: .requestFailed, address: address),
                    to: shortfall
                )
                BioMedLitLib.logger?.warning(
                    "\(source.serviceName) for \(articleName) is at an address that cannot be "
                        + "fetched ('\(address)'), so that copy is not assessed",
                    category: .fullText
                )
                continue
            }
            let outcome = keptInLibrary(
                try await downloadAndExtract(from: pdfURL, key: cacheKey, title: title),
                origin: content(pdfURL).source,
                lookup: lookup
            )
            switch outcome {
            case .wrongArticle:
                // Served, and another article's (#546): it settles nothing
                // about this one, so the walk goes on, as for a copy refused
                shortfall = .adding(.wrongArticle(source: source, address: address), to: shortfall)
                continue
            case .downloadFailed(let failure):
                // Refused, not offered (#478): not held as a link fallback,
                // and the reader is told of it on whatever the chain returns
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: failure, address: address),
                    to: shortfall
                )
                BioMedLitLib.logger?.warning(
                    "\(source.serviceName) at \(OpenAccessShortfall.host(of: address)) could not be "
                        + "obtained for \(articleName) (\(failure.describe()))",
                    category: .fullText
                )
                continue
            case .notCached:
                linkFallback = FullTextResult(content: content(pdfURL), degradation: degradation)
                notSavedFrom = pdfURL.absoluteString
                copyServed = true
                return nil
            case .noText:
                // Obtained, so the question is settled; with an abstract held
                // the walk goes on for a copy with text
                copyServed = true
                if let result = pdfTierResult(
                    outcome: outcome,
                    content: content(pdfURL),
                    degradation: degradation,
                    holdingAbstract: holdingAbstract,
                    articleName: articleName,
                    linkFallback: &linkFallback
                ) {
                    return result
                }
            case .vanished:
                // Gone twice before it was read (#560): not obtained, so the
                // question stays open, and no link to it is kept
                shortfall = .adding(
                    OpenAccessShortfall(source: source, failure: .requestFailed, address: address),
                    to: shortfall
                )
                continue
            case .notAttempted, .extracted:
                if let result = pdfTierResult(
                    outcome: outcome,
                    content: content(pdfURL),
                    degradation: degradation,
                    holdingAbstract: holdingAbstract,
                    articleName: articleName,
                    linkFallback: &linkFallback
                ) {
                    return result
                }
            }
        }
        return nil
    }

    /// The shortfall the fallbacks carry (#480): a copy served, whether not
    /// cached or cached without text, settles the open-access question, so
    /// nothing that went unsettled is told then, but CORE's entry. A copy
    /// without text is no full text obtained, so a CORE left unasked or
    /// unreachable after it keeps the absence open (#499), as Python's does.
    /// `FullTextResult.init` asserts the same of the link itself.
    ///
    /// - Parameters:
    ///   - shortfall: What went unsettled in the open-access tiers.
    ///   - copyServed: Whether an open-access copy was served: not cached, or
    ///     cached without text while an abstract is held.
    /// - Returns: The shortfall to carry, or `nil` when the question is settled.
    static func settledOpenAccessShortfall(
        _ shortfall: OpenAccessShortfall?, copyServed: Bool
    ) -> OpenAccessShortfall? {
        copyServed ? shortfall?.keeping(only: .core) : shortfall
    }

    /// Ask CORE for this article's text (#480, stage C) and record what it
    /// left unsettled: the chain's CORE step, shared by the textless copy's.
    ///
    /// - Parameters:
    ///   - doi: The DOI, as ``CORE/bareDOI(_:)`` cleans it; blank asks nothing.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    ///   - shortfall: What went unsettled so far; CORE's failure, or its
    ///     refused key (#498), is added.
    /// - Returns: CORE's text as the result, or `nil` when it served none or
    ///   was not asked (no key, or no DOI).
    /// - Throws: `CancellationError`.
    func coreTextResult(
        doi: String, degradation: FullTextDegradation?, shortfall: inout OpenAccessShortfall?
    ) async throws -> FullTextResult? {
        guard !doi.isEmpty else { return nil }
        guard !coreKeyUnreadable else {
            shortfall = .adding(OpenAccessShortfall(source: .core, failure: .requestFailed), to: shortfall)
            BioMedLitLib.logger?.warning(
                "CORE's key could not be read, so CORE was not asked about DOI \(doi) and any text "
                    + "it holds is not assessed",
                category: .fullText
            )
            return nil
        }
        guard let coreAPIKey else {
            BioMedLitLib.logger?.debug(
                "No CORE API key configured; CORE not asked about DOI \(doi)", category: .fullText
            )
            return nil
        }
        switch try await fetchCoreText(doi: doi, apiKey: coreAPIKey) {
        case .served(let text):
            BioMedLitLib.logger?.info(
                "Retrieved CORE's extracted text for DOI \(doi)", category: .fullText
            )
            // Text in hand: it beats a held abstract, a link and a copy
            // without text, and settles the open-access question.
            return FullTextResult(
                content: .core(text: text),
                degradation: degradation,
                contentKind: .extracted,
                extractedText: text
            )
        case .absent:
            BioMedLitLib.logger?.info("CORE holds no text for DOI \(doi)", category: .fullText)
        case .unreachable(let failure):
            shortfall = .adding(OpenAccessShortfall(source: .core, failure: failure), to: shortfall)
            BioMedLitLib.logger?.warning(
                "CORE could not be asked about DOI \(doi) (\(failure.describe())), so any "
                    + "text it holds is not assessed",
                category: .fullText
            )
        case .keyRefused:
            // A skip, not a failure: told as the key, and it keeps the absence
            // unsettled (#498). Logged once, by the throttle, when new.
            shortfall = .adding(.coreKeyRefused, to: shortfall)
            BioMedLitLib.logger?.debug(
                "CORE's key is refused; not asked about DOI \(doi)", category: .fullText
            )
        }
        return nil
    }

    /// A tier's result, unless it is a copy that yielded no text and CORE has
    /// the text (#499): a scan is no full text obtained, so CORE is asked
    /// before it is returned, as Python asks after any PDF that yields none.
    ///
    /// Reached only where the walk returns a tier's result, before the chain's
    /// own CORE step, so CORE is asked at most once per fetch. A copy returned
    /// with an abstract held never arrives here: the walk goes on to that step.
    ///
    /// - Parameters:
    ///   - result: The tier's result; anything but a textless copy (a cached
    ///     file, no text) is returned as it is.
    ///   - doi: The DOI CORE is asked by; blank asks nothing.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    /// - Returns: CORE's text when served; otherwise the copy, carrying CORE's
    ///   unsettled entry (unreachable, or its refused key) so the absence stays
    ///   open. An absent CORE, or none asked, adds nothing.
    /// - Throws: `CancellationError`.
    func textlessCopyOrCORE(
        _ result: FullTextResult, doi: String, degradation: FullTextDegradation?
    ) async throws -> FullTextResult {
        guard result.contentKind == .none, result.localPDFPath != nil else { return result }
        var coreShortfall: OpenAccessShortfall?
        if let core = try await coreTextResult(doi: doi, degradation: degradation, shortfall: &coreShortfall) {
            return core
        }
        guard let coreShortfall else { return result }
        return result.noting(openAccessShortfall: coreShortfall, pdfNotSavedFrom: result.pdfNotSavedFrom)
    }

    /// Write a download beside its cache name, where it waits for its title
    /// check (#560).
    ///
    /// - Parameters:
    ///   - data: The verified PDF bytes.
    ///   - cachePath: The cache name it is to take, from ``cachePath(for:from:)``:
    ///     keyed on the source URL as well as the article, so a second source
    ///     for the same article gets its own entry (``cacheFilename(key:url:)``).
    /// - Returns: Where the bytes wait.
    /// - Throws: `FullTextError.cachingFailed` on a failed write.
    private func stagePDF(data: Data, beside cachePath: String) throws -> String {
        let staged = Self.stagedPath(beside: cachePath)
        do {
            try writeCachedPDF(data, URL(fileURLWithPath: staged))
            return staged
        } catch {
            Self.discardStaged(staged)
            BioMedLitLib.logger?.error("Failed to cache PDF: \(error.localizedDescription)", category: .fullText)
            throw FullTextError.cachingFailed(error.localizedDescription)
        }
    }
}
