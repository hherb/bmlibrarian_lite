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

extension FullTextService {
    // MARK: - PDF cache

    /// The path one article's copy of one PDF is cached under.
    ///
    /// - Parameters:
    ///   - key: Names the article.
    ///   - url: The remote PDF; part of the filename.
    /// - Returns: The cache path, in ``pdfCacheDirectory``.
    static func cachePath(for key: ArticleCacheKey, from url: URL) -> String {
        pdfCacheDirectory.appendingPathComponent(cacheFilename(key: key, url: url)).path
    }

    /// A name for a download to wait under beside its cache name (#560): its
    /// own UUID before ``BioMedLitConstants/pdfUncheckedSuffix``, so two
    /// downloads of one PDF never write the same file, and no lookup reads it.
    ///
    /// - Parameter cachePath: The cache name the download is to take.
    /// - Returns: The waiting name, in the same directory.
    static func stagedPath(beside cachePath: String) -> String {
        cachePath + "." + UUID().uuidString + BioMedLitConstants.pdfUncheckedSuffix
    }

    /// Move a download that passed its title check into its cache name,
    /// replacing whatever the name held, in one step (`rename(2)`), so a
    /// reader of the name sees the old file or the new one and never a part.
    ///
    /// - Parameters:
    ///   - staged: Where the download waits.
    ///   - cachePath: Its cache name.
    /// - Returns: Whether it was moved; a failure is logged.
    static func promote(staged: String, to cachePath: String) -> Bool {
        guard rename(staged, cachePath) == 0 else {
            let reason = String(cString: strerror(errno))
            BioMedLitLib.logger?.error(
                "Could not move the downloaded PDF into the cache at \(cachePath): \(reason)",
                category: .fullText
            )
            return false
        }
        return true
    }

    /// Remove a download's waiting file, if it is still there: it is never
    /// read but by its title check, so a leftover is only disk.
    ///
    /// - Parameter staged: The waiting file; may already be gone.
    static func discardStaged(_ staged: String) {
        guard FileManager.default.fileExists(atPath: staged) else { return }
        do {
            try FileManager.default.removeItem(atPath: staged)
        } catch {
            BioMedLitLib.logger?.warning(
                "Could not remove the unchecked download \(staged): \(error.localizedDescription)",
                category: .fullText
            )
        }
    }

    /// Get the cache directory for PDF files.
    public static var pdfCacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = appSupport
            .appendingPathComponent(BioMedLitConstants.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.pdfCacheFolderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to create PDF cache directory: \(error.localizedDescription)",
                category: .fullText
            )
        }

        return cacheDir
    }

    /// The cached PDF for a document, or `nil` when there is none usable.
    ///
    /// Validated rather than merely existence-checked. `obtainPDF`
    /// verifies the magic bytes on the way in; this did not check them on the
    /// way out, so a caller would have been handed the path to an entry
    /// corrupted by anything outside this service — an interrupted restore, a
    /// sync eviction, a file written by an older build — and would have kept
    /// treating it as the article's full text indefinitely, since nothing
    /// downstream re-validates a path it already has.
    ///
    /// A failing entry is renamed rather than deleted, so it can be inspected,
    /// and the method answers `nil` so the next fetch re-downloads. Those two
    /// facts are the whole justification: the entry stops being served as this
    /// article's text, and its bytes stay available to whoever investigates.
    ///
    /// Note bmlib's issue #71 argues something stronger for the Python path —
    /// that a bad entry left in place *hides* a freshly cached copy behind it —
    /// and that reasoning does not transfer here. It is a property of bmlib's
    /// two-tier cache, which consults an HTML entry before the PDF one. This
    /// cache holds a single entry per article and source URL, and a re-download
    /// overwrites it atomically, so there is nothing for a corrupt entry to
    /// hide.
    ///
    /// Best-effort: a rename that itself fails is logged and the read still
    /// answers `nil`, because turning a recoverable miss into a thrown error
    /// helps nobody.
    ///
    /// Every article is named by an ``ArticleCacheKey``, which cannot be built
    /// without at least one identifier, so there is no shared `<cache>/.pdf`
    /// entry for this method to mistake for any particular article's (#202).
    ///
    /// - Parameters:
    ///   - key: Names the article to check for.
    ///   - url: The remote PDF the caller wants. Part of the key — see
    ///     ``cacheFilename(key:url:)``.
    /// - Returns: The cached file's path, or `nil` if there is none or the
    ///   entry was unusable.
    public static func cachedPDFPath(for key: ArticleCacheKey, from url: URL) -> String? {
        let fileURL = pdfCacheDirectory
            .appendingPathComponent(cacheFilename(key: key, url: url))
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let magic = Data(BioMedLitConstants.pdfMagicBytes)
        let handle = try? FileHandle(forReadingFrom: fileURL)
        defer { try? handle?.close() }
        let head = (try? handle?.read(upToCount: magic.count)) ?? nil

        if let head, head == magic { return fileURL.path }

        BioMedLitLib.logger?.warning(
            "Cached PDF for \(key.logDescription) is not a PDF; quarantining it so the next "
                + "fetch re-downloads instead of serving it forever",
            category: .fullText
        )
        let aside = fileURL.appendingPathExtension(BioMedLitConstants.quarantinedPDFExtension)
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: fileURL, to: aside)
        } catch {
            BioMedLitLib.logger?.error(
                "Could not quarantine the corrupt cached PDF for \(key.logDescription): "
                    + "\(error.localizedDescription)",
                category: .fullText
            )
        }
        return nil
    }

    /// Set a cached PDF of another article aside, so the cache never serves
    /// it again (#546).
    ///
    /// Renamed beside itself with ``BioMedLitConstants/pdfMismatchSuffix``,
    /// which no lookup reads, rather than deleted: the check can be wrong (a
    /// preprint retitled between versions), as Python's `pdf_library_check`
    /// keeps its set-aside PDFs. One copy per cached name is kept, the latest:
    /// a name is one article's copy from one address, so a later refusal of
    /// it holds the same file or a newer one, and the apps have no keep to
    /// restore one by.
    ///
    /// Best-effort, as ``cachedPDFPath(for:from:)``'s quarantine is: a rename
    /// that fails is logged, and the PDF is still not read, since every read
    /// passes the same check.
    ///
    /// - Parameter path: The cached PDF.
    /// - Returns: Where it was set aside, or `nil` when it could not be moved.
    @discardableResult
    static func setAsideWrongArticle(at path: String) -> String? {
        setAsideWrongArticle(at: path, besideCacheName: path)
    }

    /// Set a PDF of another article aside under its cache name's set-aside
    /// name: ``setAsideWrongArticle(at:)`` for a file that is not at that
    /// name, a download waiting for its check (#560).
    ///
    /// A cached file already gone was set aside by another fetch of the same
    /// article whose check refused it too; a waiting one, whose name no other
    /// fetch knows, by a clearing of the cache. Nothing is left to do, and
    /// nothing is read.
    ///
    /// - Parameters:
    ///   - path: The PDF, cached or waiting.
    ///   - cachePath: The cache name its set-aside name follows.
    /// - Returns: Where it was set aside, or `nil` when it was not moved.
    @discardableResult
    static func setAsideWrongArticle(at path: String, besideCacheName cachePath: String) -> String? {
        let source = URL(fileURLWithPath: path)
        let aside = URL(fileURLWithPath: cachePath + BioMedLitConstants.pdfMismatchSuffix)
        guard FileManager.default.fileExists(atPath: path) else {
            BioMedLitLib.logger?.info(
                "The PDF of another article at \(path) is already gone "
                    + (path == cachePath ? "(another fetch set it aside)" : "(the cache was cleared)"),
                category: .fullText
            )
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: aside.path) {
                try FileManager.default.removeItem(at: aside)
            }
            try FileManager.default.moveItem(at: source, to: aside)
            return aside.path
        } catch {
            BioMedLitLib.logger?.error(
                "Could not set aside the PDF of another article at \(path): \(error.localizedDescription); "
                    + "it is still not read",
                category: .fullText
            )
            return nil
        }
    }

    /// The filename one article's copy of one PDF is cached under.
    ///
    /// Keyed on the source URL as well as the article, because an article can
    /// be offered more than one PDF — Europe PMC's render URL and Unpaywall's
    /// open-access copy are different files of the same paper. Keyed on the
    /// PMID alone, the first tier to download won the entry and every later
    /// tier was served *its* bytes: the chain then returned that file as the
    /// Unpaywall result, recorded `fullTextSource = "unpaywall"` over a Europe
    /// PMC download, and never fetched the copy that might have extracted
    /// cleanly.
    ///
    /// The article half comes from ``ArticleCacheKey``, which sanitises or
    /// digests the identifier it holds — identifiers reach us from search
    /// results, and `appendingPathComponent` on a value holding `/` or `..`
    /// would place the file outside the cache directory.
    ///
    /// Entries written before the URL became part of the key, or before the key
    /// named the *kind* of identifier it holds (#202), simply never match: they
    /// are re-downloaded once, and the old entries are then orphaned rather than
    /// replaced. ``deleteCachedPDF(for:)`` matches on the tagged prefix, so it
    /// cannot find them either, and only ``clearPDFCache()`` reclaims them. That
    /// is still the cheap direction to be wrong in — a stale entry costs one
    /// download and some disk, while serving the wrong article's bytes costs the
    /// reader a wrong answer.
    ///
    /// `Hasher` is deliberately not used for the fingerprint: Swift seeds it
    /// per process, so a filename built from it would change on every launch
    /// and every entry would miss forever.
    ///
    /// Internal rather than private so a test can name the file it is about to
    /// plant without duplicating the key derivation — a duplicate that would
    /// keep passing if the real one changed.
    ///
    /// - Parameters:
    ///   - key: Names the article this entry belongs to.
    ///   - url: The remote PDF this entry holds.
    /// - Returns: The filename, including extension.
    static func cacheFilename(key: ArticleCacheKey, url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let fingerprint = digest
            .prefix(BioMedLitConstants.cacheKeyFingerprintBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(key.filenameComponent)-\(fingerprint).\(BioMedLitConstants.pdfExtension)"
    }

    /// Delete every cached PDF for a document.
    ///
    /// Plural because one article can hold an entry per source URL — see
    /// ``cacheFilename(key:url:)``. Quarantined entries go too: they belong to
    /// the same article and are of no use once it is being discarded. A JATS
    /// waiting there for the library (``writeWaitingJATS(_:key:)``) is no
    /// cached PDF and stays: a source is never deleted by a cache clear.
    ///
    /// - Parameter key: Names the article whose PDFs are to be deleted.
    public static func deleteCachedPDF(for key: ArticleCacheKey) {
        let articleName = key.filenameComponent
        let cacheDir = pdfCacheDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in contents
        where (fileURL.lastPathComponent.hasPrefix("\(articleName)-")
            || fileURL.lastPathComponent.hasPrefix("\(articleName)."))
            && !fileURL.lastPathComponent.hasSuffix(BioMedLitConstants.libraryWaitingJATSSuffix) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Whether "clear cache" should remove this file.
    ///
    /// A separate predicate so it can be tested without calling
    /// ``clearPDFCache()``, which empties the *real* user cache directory — a
    /// test that called it would delete the PDFs of whoever ran the suite.
    ///
    /// - Parameter fileURL: A file found in the cache directory.
    /// - Returns: `true` for a cached PDF, a quarantined one, one set aside
    ///   as another article's (#546), or a download left waiting for its
    ///   title check (#560).
    static func isClearableCacheEntry(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        let pdfName = "." + BioMedLitConstants.pdfExtension
        return fileURL.pathExtension == BioMedLitConstants.pdfExtension
            || fileURL.pathExtension == BioMedLitConstants.quarantinedPDFExtension
            || name.hasSuffix(pdfName + BioMedLitConstants.pdfMismatchSuffix)
            || (name.hasSuffix(BioMedLitConstants.pdfUncheckedSuffix) && name.contains(pdfName + "."))
    }

    /// Clear all cached PDFs.
    ///
    /// Quarantined entries are removed too. Filtering on the `pdf` extension
    /// alone left every `.corrupt` file behind, so the bytes a quarantine set
    /// aside for inspection accumulated in a directory the user had explicitly
    /// asked to empty, and "clear cache" did not clear the cache.
    public static func clearPDFCache() {
        let cacheDir = pdfCacheDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents where Self.isClearableCacheEntry(fileURL) {
                try FileManager.default.removeItem(at: fileURL)
            }
            BioMedLitLib.logger?.info("Cleared PDF cache", category: .fullText)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to clear PDF cache: \(error.localizedDescription)",
                category: .fullText
            )
        }
    }
}
