#if os(macOS)
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

import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Window & Layout Constants

/// Constants for window sizing and layout dimensions.
enum MacLayout {
    /// Default main window size.
    static let defaultWindowWidth: CGFloat = 1200
    static let defaultWindowHeight: CGFloat = 800

    /// Sidebar dimensions.
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 280

    /// Split view column dimensions.
    static let leftColumnMinWidth: CGFloat = 400
    static let leftColumnIdealWidth: CGFloat = 500
    static let leftColumnMaxWidth: CGFloat = 600
    static let rightColumnMinWidth: CGFloat = 400
    static let detailColumnMinWidth: CGFloat = 300

    /// Content constraints.
    static let maxContentWidth: CGFloat = 900
    static let emptyStateMaxWidth: CGFloat = 300
    static let searchFieldWidth: CGFloat = 200
    static let budgetProgressWidth: CGFloat = 100
    static let percentageWidth: CGFloat = 40
    static let currencyFieldWidth: CGFloat = 100

    /// Settings window.
    static let settingsWindowWidth: CGFloat = 550
    static let settingsWindowHeight: CGFloat = 450

    /// Sheet dimensions.
    static let documentSheetMinWidth: CGFloat = 600
    static let documentSheetMinHeight: CGFloat = 500
    static let disclaimerMinWidth: CGFloat = 700
    static let disclaimerMinHeight: CGFloat = 600
    static let disclaimerMaxContentWidth: CGFloat = 600

    /// Onboarding dimensions.
    static let onboardingMinWidth: CGFloat = 650
    static let onboardingMinHeight: CGFloat = 550
    static let onboardingMaxContentWidth: CGFloat = 500

    /// Minimum heights.
    static let viewMinHeight: CGFloat = 500
    static let textEditorMinHeight: CGFloat = 120
    static let textEditorMaxHeight: CGFloat = 200
    static let scoredDocumentsMinHeight: CGFloat = 300

    /// Button widths.
    static let submitButtonMinWidth: CGFloat = 140
    static let sortPickerWidth: CGFloat = 140
    static let filterPickerWidth: CGFloat = 100
    static let filterPickerWideWidth: CGFloat = 140
}

// MARK: - Spacing Constants

/// Constants for padding and spacing.
enum MacSpacing {
    /// Standard padding values.
    static let xxSmall: CGFloat = 2
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let standard: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 20
    static let xxLarge: CGFloat = 24
    static let section: CGFloat = 32
    static let disclaimer: CGFloat = 40

    /// Card and content spacing.
    static let cardSpacing: CGFloat = 12
    static let sectionSpacing: CGFloat = 24
    static let listItemSpacing: CGFloat = 8
    static let statItemSpacing: CGFloat = 32
}

// MARK: - Corner Radius Constants

/// Constants for corner radii.
enum MacCornerRadius {
    static let small: CGFloat = 4
    static let medium: CGFloat = 6
    static let standard: CGFloat = 8
    static let large: CGFloat = 10
    static let xLarge: CGFloat = 12
    static let pill: CGFloat = 30
}

// MARK: - Icon & Badge Sizes

/// Constants for icon and badge sizing.
enum MacIconSize {
    /// Empty state icon sizes.
    static let emptyStateLarge: CGFloat = 72
    static let emptyStateMedium: CGFloat = 48
    static let disclaimerIcon: CGFloat = 80
    static let aboutIcon: CGFloat = 64
    static let onboardingIcon: CGFloat = 72

    /// Badge sizes.
    static let scoreBadgeSize: CGFloat = 36
    static let scoreBadgeSmall: CGFloat = 32
    static let stepIndicatorSize: CGFloat = 16
    static let stepIndicatorRingSize: CGFloat = 24
    static let iconFrame: CGFloat = 32
    static let disclaimerIconFrame: CGFloat = 30

    /// Step connector.
    static let stepConnectorHeight: CGFloat = 2
    static let stepConnectorMaxWidth: CGFloat = 40
    static let stepConnectorOffset: CGFloat = 20

    /// List number width.
    static let listNumberWidth: CGFloat = 24
}

// MARK: - Animation Constants

/// Constants for animations.
enum MacAnimation {
    static let expandDuration: Double = 0.2
}

// MARK: - Opacity Constants

/// Constants for opacity values.
enum MacOpacity {
    static let veryLight: Double = 0.05
    static let light: Double = 0.08
    static let subtle: Double = 0.1
    static let badgeBackground: Double = 0.15
    static let border: Double = 0.2
    static let muted: Double = 0.3
    static let faded: Double = 0.4
    static let half: Double = 0.5
}

// MARK: - Scale Constants

/// Constants for view scaling.
enum MacScale {
    static let progressViewSmall: CGFloat = 0.6
    static let progressViewMedium: CGFloat = 0.7
}

// MARK: - Color Helpers

/// Shared color utilities for verdict and score badges.
enum MacColors {
    /// Returns the color for a relevance score (1-5 scale).
    ///
    /// - Parameter score: The relevance score from 1 to 5.
    /// - Returns: A color representing the score level.
    static func scoreColor(for score: Int) -> Color {
        switch score {
        case 5: return .green
        case 4: return Color(red: 0.4, green: 0.7, blue: 0.3)
        case 3: return .orange
        case 2: return Color(red: 0.9, green: 0.5, blue: 0.2)
        default: return .red
        }
    }

    /// Returns the color for a verdict.
    ///
    /// - Parameter verdict: The verdict to get color for.
    /// - Returns: A color representing the verdict.
    static func verdictColor(for verdict: Verdict) -> Color {
        switch verdict {
        case .supported: return .green
        case .partiallySupported: return .orange
        case .notSupported: return .red
        case .insufficientEvidence: return .gray
        case .conflicting: return .purple
        }
    }

    // MARK: - LLM Reasoning Colors

    /// Background color for LLM reasoning/explanation blocks.
    static let reasoningBackground = Color(red: 0.98, green: 0.97, blue: 0.93)

    /// Border color for LLM reasoning blocks.
    static let reasoningBorder = Color(red: 0.85, green: 0.82, blue: 0.72)

    /// Text color for LLM reasoning content.
    static let reasoningText = Color(red: 0.35, green: 0.35, blue: 0.35)

    /// Accent color for LLM reasoning icon.
    static let reasoningAccent = Color(red: 0.6, green: 0.55, blue: 0.4)

    // MARK: - Batch Number Colors

    /// Returns the color for a batch number badge.
    ///
    /// Uses distinct colors for different batches to help users identify
    /// which documents came from which search iteration.
    ///
    /// - Parameter batchNumber: The batch number (1-indexed).
    /// - Returns: A color for the batch badge.
    static func batchColor(for batchNumber: Int) -> Color {
        let colors: [Color] = [.blue, .purple, .orange, .teal, .pink]
        let index = (batchNumber - 1) % colors.count
        return colors[index]
    }
}

// MARK: - PDF Export Constants

/// Constants for PDF generation.
enum MacPDFLayout {
    /// Page margin in points (72 points per inch).
    static let pageMargin: CGFloat = 50

    /// A4 page dimensions in points.
    static let a4Width: CGFloat = 595.28
    static let a4Height: CGFloat = 841.89

    /// US Letter page dimensions in points.
    static let letterWidth: CGFloat = 612
    static let letterHeight: CGFloat = 792
}

// MARK: - UserDefaults Keys

/// Keys for UserDefaults storage.
enum MacUserDefaultsKeys {
    static let hasAcceptedDisclaimer = "hasAcceptedDisclaimer"
    static let pdfPaperSize = "pdf_paper_size"
}

// MARK: - Full Text Layout Constants

/// Constants for full-text viewer layout.
enum MacFullTextLayout {
    /// Viewer window dimensions.
    static let viewerMinWidth: CGFloat = 500
    static let viewerIdealWidth: CGFloat = 700
    static let viewerMaxWidth: CGFloat = 900
    static let viewerMinHeight: CGFloat = 600

    /// Split view proportions.
    static let documentListProportion: CGFloat = 0.4
    static let fullTextProportion: CGFloat = 0.6

    /// PDF viewer constraints.
    static let pdfMinWidth: CGFloat = 400
    static let pdfMinHeight: CGFloat = 500

    /// Markdown viewer padding.
    static let markdownPadding: CGFloat = 20
    static let markdownLineSpacing: CGFloat = 4

    /// Loading indicator size.
    static let loadingIndicatorSize: CGFloat = 24
}

// MARK: - Search Provider Colors

/// Colors for search provider badges and UI elements.
///
/// Uses distinct blue shades to differentiate providers while reserving
/// green for other purposes (scores, success states, etc.):
/// - PubMed: Very pale blue (traditional, established database)
/// - Europe PMC: Darker blue (European alternative)
/// - Both: Cyan (merged/combined results)
enum MacProviderColors {
    /// Color for PubMed provider (very pale blue).
    static let pubmed = Color(red: 0.6, green: 0.75, blue: 0.9)

    /// Color for Europe PMC provider (darker blue).
    static let europePMC = Color(red: 0.2, green: 0.4, blue: 0.7)

    /// Color for merged/both providers (cyan).
    static let both = Color(red: 0.0, green: 0.7, blue: 0.8)

    /// Returns the appropriate color for a search provider.
    ///
    /// - Parameter provider: The search provider.
    /// - Returns: Color appropriate for the provider badge.
    static func color(for provider: SearchProvider) -> Color {
        switch provider {
        case .pubmed: return pubmed
        case .europePMC: return europePMC
        case .both: return both
        }
    }
}

// MARK: - Full Text Colors

/// Colors for full-text source badges and viewer.
enum MacFullTextColors {
    #if os(macOS)
    /// Background color for markdown viewer.
    static let markdownBackground = Color(NSColor.textBackgroundColor)
    #else
    /// Background color for markdown viewer (iOS fallback).
    static let markdownBackground = Color(.systemBackground)
    #endif

    /// Tint color for Europe PMC badge.
    static let europePMCTint = Color.blue

    /// Tint color for Unpaywall badge.
    static let unpaywallTint = Color.green

    /// Tint color for DOI/website badge.
    static let doiTint = Color.orange

    /// Tint color for cached content badge.
    static let cachedTint = Color.gray

    /// Returns the appropriate color for a full-text source.
    ///
    /// - Parameter source: The full-text source.
    /// - Returns: Color appropriate for the source badge.
    static func color(for source: AppFullTextSource) -> Color {
        switch source {
        case .europePMC: return europePMCTint
        case .unpaywall: return unpaywallTint
        case .doi: return doiTint
        case .cached: return cachedTint
        }
    }
}

#endif // os(macOS)
