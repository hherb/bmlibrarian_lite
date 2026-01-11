//
//  MacConstants.swift
//  MedicalFactChecker
//
//  Constants for macOS UI layout, styling, and configuration.
//  Centralizes magic numbers to improve maintainability.
//

import SwiftUI

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

    /// Minimum heights.
    static let viewMinHeight: CGFloat = 500
    static let textEditorMinHeight: CGFloat = 120
    static let textEditorMaxHeight: CGFloat = 200

    /// Button widths.
    static let submitButtonMinWidth: CGFloat = 140
    static let sortPickerWidth: CGFloat = 140
    static let filterPickerWidth: CGFloat = 100
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
}

// MARK: - UserDefaults Keys

/// Keys for UserDefaults storage.
enum MacUserDefaultsKeys {
    static let hasAcceptedDisclaimer = "hasAcceptedDisclaimer"
}
