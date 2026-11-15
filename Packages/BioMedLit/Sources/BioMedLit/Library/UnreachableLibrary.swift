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

import Foundation

/// The library a fetch goes through while the one set cannot be reached
/// (design §4.6): every call fails with why, so the fetch keeps its source
/// where it is and marks it waiting for the library, as for a library that
/// fails mid-fetch. A paper with no identifier the library accepts is not
/// touched, as the library's own rule.
public struct UnreachableLibrary: FullTextLibrary {
    /// Why the library cannot be reached, for the user.
    public let reason: String

    /// A library that cannot be reached, for `reason`.
    public init(reason: String) {
        self.reason = reason
    }

    public func jats(for paper: LibraryPaper) -> LibraryJATSLookup {
        failure(for: paper).map { .failed($0) } ?? .none
    }

    public func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure> {
        failure(for: paper).map { .failure($0) } ?? .success(nil)
    }

    public func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String)
        -> Result<LibraryKept?, LibraryLookupFailure> {
        failure(for: paper).map { .failure($0) } ?? .success(nil)
    }

    public func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure? {
        failure(for: paper)
    }

    public func path(of file: LibraryFileReference) -> String? {
        BioMedLitLib.logger?.warning(
            BioMedLitConstants.libraryFileFailure(kind: file.kind, sha256: file.sha256, reason: reason),
            category: .library)
        return nil
    }

    public func read(_ file: LibraryFileReference) -> Result<Data, LibraryLookupFailure> {
        let failure = LibraryLookupFailure(
            description: BioMedLitConstants.libraryFileFailure(kind: file.kind, sha256: file.sha256, reason: reason),
            waits: true)
        BioMedLitLib.logger?.warning(failure.description, category: .library)
        return .failure(failure)
    }

    /// The failure for `paper`, logged at warning, or nil for a paper with no
    /// identifier the library accepts (read as the library reads them). It
    /// always waits: the library may come back.
    private func failure(for paper: LibraryPaper) -> LibraryLookupFailure? {
        guard let ids = paper.libraryRequestIDs else { return nil }
        let failure = LibraryLookupFailure(
            description: BioMedLitConstants.libraryFailure(ids: LibraryPaper.describe(ids), file: nil, reason: reason),
            waits: true)
        BioMedLitLib.logger?.warning(failure.description, category: .library)
        return failure
    }
}
