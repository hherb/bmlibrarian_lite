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

#if os(macOS)
import BioMedLit
import Foundation

/// One file of this app's to move into the library, with the documents that
/// use it.
struct LibraryMoveGroup {
    /// The file, as BioMedLit's move takes it.
    let item: LibraryMoveItem
    /// Every document reading it.
    var documents: [Document]
}

/// One library file this app's documents use, for a switch's copy or the
/// copy back.
struct LibraryFileGroup {
    /// The file, by digest and kind.
    let file: LibraryFileReference
    /// The paper, as the library is told of it (the first document's).
    let paper: LibraryPaper
    /// Names the article in the PDF cache, or nil when its documents carry
    /// no identifier.
    let key: ArticleCacheKey?
    /// Every document using it.
    var documents: [Document]
}

/// What a move or a copy came to, for the Library setting.
struct LibraryMoveSummary: Equatable {
    /// How many files the library holds now that it did not, or this app
    /// holds again.
    var moved: Int
    /// One line per file not moved: "‹title›: ‹why›".
    var failed: [String]

    /// What it did, for the setting: "N files ‹done›." (or that nothing
    /// was), then a line per file not moved.
    ///
    /// - Parameter done: What was done, as `BioMedLitConstants.libraryMovedInDone`.
    func lines(done: String) -> [String] {
        let head = moved == 0 && failed.isEmpty
            ? BioMedLitConstants.libraryNothingMovedText
            : "\(moved == 1 ? "1 file" : "\(moved) files") \(done)."
        return [head] + failed.map { BioMedLitConstants.libraryNotMovedPrefix + $0 }
    }
}

/// The documents' side of the move and the switch (design §4.7): which files
/// the move takes, and what each outcome writes back. Pure: the PDF cache is
/// a folder URL and the names in it, listed by the caller off the main actor.
@MainActor
enum LibraryMover {

    /// The cached PDFs and waiting JATS that `documents` use, one group per
    /// file (decided 2026-11-15: cache entries no document uses stay cache).
    ///
    /// - Parameters:
    ///   - documents: The documents to look through.
    ///   - cacheDirectory: The PDF cache.
    ///   - cacheNames: The names of the files in it now; a document's file
    ///     not among them is not offered.
    ///   - onlyWaiting: Take only the files a document waiting for the
    ///     library reads (the settle), each still with every document reading
    ///     it, so none is left on a removed path; otherwise every file (the
    ///     user's move).
    static func moveItems(_ documents: [Document], cacheDirectory: URL, cacheNames: Set<String>,
                          onlyWaiting: Bool) -> [LibraryMoveGroup] {
        var groups: [LibraryMoveGroup] = []
        var index: [String: Int] = [:]
        func add(_ name: String, kind: String, for document: Document) {
            let path = cacheDirectory.appendingPathComponent(name).path
            if let at = index[path] {
                groups[at].documents.append(document)
                return
            }
            index[path] = groups.count
            groups.append(LibraryMoveGroup(
                item: LibraryMoveItem(paper: paper(of: document), path: path, kind: kind, origin: origin(of: document)),
                documents: [document]))
        }
        let cachePath = cacheDirectory.standardizedFileURL.path
        for document in documents {
            if let local = document.localPDFFilePath {
                let url = URL(fileURLWithPath: local)
                if url.deletingLastPathComponent().standardizedFileURL.path == cachePath,
                   cacheNames.contains(url.lastPathComponent) {
                    add(url.lastPathComponent, kind: BioMedLitConstants.libraryKindPDF, for: document)
                }
            }
            if let key = cacheKey(of: document) {
                for name in cacheNames.sorted() where isWaitingJATS(name, of: key) {
                    add(name, kind: BioMedLitConstants.libraryKindJATS, for: document)
                }
            }
        }
        guard onlyWaiting else { return groups }
        return groups.filter { $0.documents.contains { $0.fullTextLibraryWaiting != nil } }
    }

    /// The library files `documents` use, one group per file.
    static func libraryFiles(_ documents: [Document]) -> [LibraryFileGroup] {
        var groups: [LibraryFileGroup] = []
        var index: [String: Int] = [:]
        for document in documents {
            guard let sha256 = document.fullTextLibrarySHA256, let kind = document.fullTextLibraryKind else { continue }
            let id = kind + ":" + sha256
            if let at = index[id] {
                groups[at].documents.append(document)
                continue
            }
            index[id] = groups.count
            groups.append(LibraryFileGroup(
                file: LibraryFileReference(sha256: sha256, kind: kind), paper: paper(of: document),
                key: cacheKey(of: document), documents: [document]))
        }
        return groups
    }

    /// Write `outcomes[i]` to the documents `documents[i]`: a moved file is
    /// stored as the documents' library file; a failed one is named by its
    /// paper's title, and its documents get `notCarriedNote` when given (a
    /// switch's copy). A document with a file that did not move keeps
    /// waiting, whatever else of it moved.
    static func apply(_ outcomes: [LibraryMoveOutcome], to documents: [[Document]],
                      notCarriedNote: String? = nil) -> LibraryMoveSummary {
        var summary = LibraryMoveSummary(moved: 0, failed: [])
        let waitingBefore = documents.joined().map { ($0, $0.fullTextLibraryWaiting) }
        var stillWaiting: Set<ObjectIdentifier> = []
        defer {
            for (document, why) in waitingBefore where stillWaiting.contains(ObjectIdentifier(document)) {
                if let why { document.keepLibraryWaiting(why) }
            }
        }
        for (outcome, group) in zip(outcomes, documents) {
            switch outcome {
            case let .moved(kept):
                summary.moved += 1
                for document in group { document.storeMovedLibraryFile(kept) }
            case let .failed(reason):
                summary.failed.append("\(group.first?.title ?? ""): \(reason)")
                stillWaiting.formUnion(group.map(ObjectIdentifier.init))
                if let notCarriedNote { notCarried(group, note: notCarriedNote) }
            }
        }
        return summary
    }

    /// Note on each of `documents` with a library file that it cannot be read
    /// after a switch, and why.
    static func notCarried(_ documents: [Document], note: String) {
        for document in documents where document.fullTextLibrarySHA256 != nil {
            document.noteLibraryFileLeft(note)
        }
    }

    /// Whether `name` is `key`'s waiting JATS, exactly `<key>-<sha12>.xml`
    /// (``LibraryMove/appCopyName(key:sha256:kind:)``): a prefix alone would
    /// also take the file of a key that extends this one (`doi_10.1_a-b`).
    static func isWaitingJATS(_ name: String, of key: ArticleCacheKey) -> Bool {
        let prefix = key.filenameComponent + "-"
        let suffix = BioMedLitConstants.libraryWaitingJATSSuffix
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let digest = name.dropFirst(prefix.count).dropLast(suffix.count)
        return digest.count == BioMedLitConstants.libraryWaitingDigestHexChars
            && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The paper as the fetch tells the library of it.
    private static func paper(of document: Document) -> LibraryPaper {
        FullTextService.libraryPaper(pmcId: document.pmcId, doi: document.doi, pmid: document.pmid,
                                     primaryKind: document.resolvedIdentifierKind, title: document.title)
    }

    /// The document's name in the PDF cache, as the fetch builds it.
    private static func cacheKey(of document: Document) -> ArticleCacheKey? {
        ArticleCacheKey(pmid: document.pmid, pmcId: document.pmcId, doi: document.doi,
                        primaryKind: document.resolvedIdentifierKind)
    }

    /// Who found the document's text, as the library records it.
    private static func origin(of document: Document) -> String {
        document.fullTextSource.flatMap(AppFullTextSource.init(rawValue:))?.displayName
            ?? BioMedLitConstants.libraryAppName
    }
}
#endif
