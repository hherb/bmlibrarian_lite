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

import BmlibCore
import Foundation

/// A file in the shared paper library, referred to by digest and kind, never by
/// path (design §4.4): a path is only a hint, found again with
/// ``FullTextLibrary/path(of:)``.
public struct LibraryFileReference: Sendable, Equatable, Codable {
    /// The file's full SHA-256, 64 lower-case hex digits.
    public let sha256: String
    /// What the file is, by bmlib's name: `BioMedLitConstants.libraryKindPDF`,
    /// `libraryKindJATS`, `libraryKindHTML`, `libraryKindMarkdown` or
    /// `libraryKindText`.
    public let kind: String

    /// A reference to the file with `sha256` stored as `kind`.
    public init(sha256: String, kind: String) {
        self.sha256 = sha256
        self.kind = kind
    }
}

/// What the library is told of a paper: its identifiers, as the lookup has
/// them (made canonical inside, each on its own; a value the library refuses is
/// left out), and, when known, the title, year and first author, which name
/// the paper's folder.
public struct LibraryPaper: Sendable {
    /// The PubMed ID, or nil.
    public let pmid: String?
    /// The DOI, or nil.
    public let doi: String?
    /// The PubMed Central ID, or nil.
    public let pmcId: String?
    /// The title, or nil.
    public let title: String?
    /// The publication year, or nil.
    public let year: Int?
    /// The first author's name, or nil.
    public let firstAuthor: String?

    /// A paper with these identifiers and details; any may be nil.
    public init(pmid: String?, doi: String?, pmcId: String?,
                title: String? = nil, year: Int? = nil, firstAuthor: String? = nil) {
        self.pmid = pmid
        self.doi = doi
        self.pmcId = pmcId
        self.title = title
        self.year = year
        self.firstAuthor = firstAuthor
    }
}

/// What the library holds as the paper's JATS (design §4.5, bmlib's
/// `usable_library_jats`).
public enum LibraryJATSLookup: Sendable {
    /// No JATS may be served for the paper, or the paper has no identifier the
    /// library accepts (the library is then not touched).
    case none
    /// The JATS's bytes (digest checked) may be served: they parse, have a
    /// body, and the article's own identifiers do not contradict the paper's.
    case usable(Data, LibraryFileReference)
    /// The JATS does not parse or has no body: `note` says which and names the
    /// file. Warn and run the chain.
    case unusable(note: String)
    /// The JATS's own identifiers name another paper: the message names the
    /// file and both values. It is the lookup's library failure, and nothing is
    /// kept in the library for the rest of that lookup.
    case wrongPaper(String)
    /// The library could not be read (unreachable, or a file failing its
    /// digest): bmlib's text, the paper and the file named, and whether a
    /// source the lookup then fetches waits for the library. It is the
    /// lookup's library failure, and the rest of the lookup uses no library.
    case failed(LibraryLookupFailure)
}

/// The library's PDF for a paper, read and digest checked.
public struct LibraryHeldPDF: Sendable, Equatable {
    /// Where the file is: `<root>/papers/<folder>/<name>`.
    public let path: String
    /// The file, by digest and kind.
    public let file: LibraryFileReference

    /// The PDF at `path`, which is `file`.
    public init(path: String, file: LibraryFileReference) {
        self.path = path
        self.file = file
    }
}

/// A file saved in the library (or found there already, for the same bytes).
public struct LibraryKept: Sendable, Equatable {
    /// The file, by digest and kind.
    public let file: LibraryFileReference
    /// Where the file is: `<root>/papers/<folder>/<name>`.
    public let path: String

    /// `file`, kept at `path`.
    public init(file: LibraryFileReference, path: String) {
        self.file = file
        self.path = path
    }
}

/// Why a library call failed, worded as bmlib's service words it:
/// "library, paper pmid=1 doi=10.1/a[ file F/N]: <bmlib's text>".
public struct LibraryLookupFailure: Error, Sendable, CustomStringConvertible {
    /// The whole sentence, fit for a log and for the result's library failure.
    public let description: String
    /// Whether a source the fetch could not keep because of this failure
    /// waits for the library (design §4.6): true when the library could not
    /// be reached, read or written (it may come back); false when it was
    /// reached and refused (a file failing its digest, another paper's JATS,
    /// a name clash, an identifier it refuses).
    public let waits: Bool

    /// A failure worded `description`, whose source waits when `waits`.
    public init(description: String, waits: Bool) {
        self.description = description
        self.waits = waits
    }
}

/// The shared paper library as the full-text fetch uses it: read by bmlib's
/// rules, saved into, and every use noted. Every call does disk I/O on the
/// calling thread, so call it off the main thread.
///
/// A paper with no identifier the library accepts skips the library: every
/// call then answers "nothing" (`.none`, nil) and touches nothing.
public protocol FullTextLibrary: Sendable {
    /// The paper's JATS, read from one scan of the library.
    func jats(for paper: LibraryPaper) -> LibraryJATSLookup

    /// The paper's PDF, read and digest checked; nil when the library holds
    /// none for it.
    func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure>

    /// Save `bytes`, a source of `kind` (bmlib's name) for `paper`, found by
    /// `origin` (the tier's display name). Bytes already in the library are
    /// not written again. nil when the paper has no identifier the library
    /// accepts (nothing saved, no failure).
    func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String)
        -> Result<LibraryKept?, LibraryLookupFailure>

    /// Note in this installation's record that it uses `file` for `paper`,
    /// unless the record already lists it (then nothing is written). nil when
    /// done or not needed.
    func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure?

    /// Where `file` is in the library now, or nil when the library does not
    /// hold it (or cannot be read: logged).
    func path(of file: LibraryFileReference) -> String?

    /// `file`'s bytes, found by digest and read digest checked (bmlib's
    /// `read`): how a move checks a copy before the app's goes (design §4.7).
    /// A file the library does not hold is a failure that does not wait.
    func read(_ file: LibraryFileReference) -> Result<Data, LibraryLookupFailure>
}

// MARK: The library's reading of a paper's ids, shared by every library

extension LibraryPaper {
    /// The paper's ids as the library reads them (bmlib's `libraryIds`), each
    /// refused one warned of; nil when none is left, so the library is
    /// skipped.
    var libraryRequestIDs: PaperIds? {
        let made = libraryIds(pmid: pmid, doi: doi, pmcid: pmcId)
        for field in made.dropped {
            BioMedLitLib.logger?.warning(
                BioMedLitConstants.libraryDroppedIdentifierWarning(field: field), category: .library)
        }
        let ids = made.ids
        return ids.pmid == nil && ids.doi == nil && ids.pmcid == nil ? nil : ids
    }

    /// bmlib's `describe_ids`: "pmid=1 doi=10.1/a pmcid=PMC1", the ones
    /// present.
    static func describe(_ ids: PaperIds) -> String {
        let parts = [("pmid", ids.pmid), ("doi", ids.doi), ("pmcid", ids.pmcid)]
            .compactMap { name, value in value.map { "\(name)=\($0)" } }
        return parts.isEmpty ? BioMedLitConstants.libraryNoIdentifiers : parts.joined(separator: " ")
    }
}
