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

/// Evidence verdict for fact-check reports.
///
/// Represents the outcome of comparing a claim against scientific evidence.
public enum Verdict: String, Codable, Sendable, Equatable {
    /// The claim is fully supported by the evidence.
    case supported = "Supported"

    /// The claim is partially supported - some aspects are correct.
    case partiallySupported = "Partially Supported"

    /// The claim is not supported or contradicted by the evidence.
    case notSupported = "Not Supported"

    /// There is insufficient evidence to make a determination.
    case insufficientEvidence = "Insufficient Evidence"

    /// The evidence is conflicting - some supports, some contradicts.
    case conflicting = "Conflicting Evidence"

    /// A suggested color for displaying this verdict.
    ///
    /// Returns a color name suitable for use in UI styling.
    public var colorName: String {
        switch self {
        case .supported:
            return "green"
        case .partiallySupported:
            return "orange"
        case .notSupported:
            return "red"
        case .insufficientEvidence:
            return "gray"
        case .conflicting:
            return "purple"
        }
    }
}
