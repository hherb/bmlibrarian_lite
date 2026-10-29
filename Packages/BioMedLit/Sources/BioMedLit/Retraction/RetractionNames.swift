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

/// bmlib's retraction enums by the names
/// `doc/cross_platform/retraction_parity/retraction_status.json` gives them,
/// the form a check is stored in. `RetractionContractTests` runs the
/// contract's cases through these tables, and checks each table against its
/// own literal names, every case once.
enum RetractionNames {
    static let sources: [(String, RetractionSource)] = [
        ("retraction_watch_export", .retractionWatchExport),
        ("crossref_retraction_watch", .crossrefRetractionWatch),
        ("crossref_publisher", .crossrefPublisher),
        ("pubmed_label", .pubmedLabel),
    ]

    static let kinds: [(String, RetractionKind)] = [
        ("retraction", .retraction), ("withdrawal", .withdrawal), ("removal", .removal),
        ("partial_retraction", .partialRetraction), ("expression_of_concern", .expressionOfConcern),
        ("correction", .correction), ("erratum", .erratum), ("corrigendum", .corrigendum),
        ("addendum", .addendum), ("clarification", .clarification), ("new_version", .newVersion),
        ("new_edition", .newEdition), ("reinstatement", .reinstatement), ("other", .other),
    ]

    static let statuses: [(String, RetractionStatus)] = [
        ("retracted", .retracted), ("concern", .concern), ("clear", .clear), ("unchecked", .unchecked),
    ]

    static let lookups: [(String, RetractionLookup)] = [
        ("retraction_watch_export", .retractionWatchExport), ("crossref", .crossref),
    ]

    /// `value`'s contract name; `testNameTablesAreTheContractNames` keeps every
    /// case in its table, so the fallback (never a contract name, so never
    /// read back as one) is unreachable.
    static func name<T: Equatable>(_ value: T, in table: [(String, T)]) -> String {
        table.first { $0.1 == value }?.0 ?? "unmapped \(value)"
    }

    /// The case `name` names, or `nil` for a name the table lacks.
    static func value<T>(_ name: String, in table: [(String, T)]) -> T? {
        table.first { $0.0 == name }?.1
    }
}
