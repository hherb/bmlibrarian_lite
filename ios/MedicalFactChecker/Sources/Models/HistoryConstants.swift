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

// MARK: - History View Constants

/// Constants for the History view and related components.
///
/// Centralizes UI-related constants for the history list display,
/// including text truncation limits and empty state configuration.
enum HistoryConstants {

    // MARK: - Text Display

    /// Maximum number of characters to display for a claim in the delete confirmation dialog.
    ///
    /// Claims longer than this limit are truncated with an ellipsis.
    static let maxClaimPreviewLength = 50

    // MARK: - Empty State

    /// Font size for the empty state icon in the history view.
    static let emptyStateIconSize: CGFloat = 60
}
