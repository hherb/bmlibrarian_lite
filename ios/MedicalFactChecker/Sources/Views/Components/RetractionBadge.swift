// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import BioMedLit

// MARK: - Constants

/// Layout constants for the retraction badge and banner.
private enum RetractionBadgeConstants {
    static let labelFontSize: CGFloat = 9
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 3
    static let cornerRadius: CGFloat = 4
    static let backgroundOpacity: CGFloat = 0.12
    static let bannerSpacing: CGFloat = 8
    static let bannerPadding: CGFloat = 10
}

/// A paper's retraction status as a badge: RETRACTED, CONCERN or NOT CHECKED.
///
/// Follows the desktop's `retraction_badge`: clear shows nothing, and the
/// tooltip is the paper's status line. The app's own rule (the desktop always
/// has a check): a paper never checked shows NOT CHECKED only in the detail
/// view, so a list of unchecked papers stays quiet.
struct RetractionBadge: View {
    /// What the badge says; separate from the view so it can be tested.
    struct Content: Equatable {
        /// The badge's text.
        let text: String
        /// The status line shown as tooltip and read aloud.
        let tooltip: String
        /// Whether the badge is drawn in the error colour (retracted).
        let isRetracted: Bool
        /// Whether the badge is drawn in the warning colour (concern).
        let isConcern: Bool

        /// The content for a check, or `nil` when no badge is shown.
        ///
        /// - Parameters:
        ///   - check: The paper's check; `nil` when it was never checked.
        ///   - inDetail: Whether this is the detail view (viewer), where a
        ///     never-checked paper is called NOT CHECKED.
        init?(check: PaperRetractionCheck?, inDetail: Bool = false) {
            guard let check else {
                guard inDetail else { return nil }
                self.init(text: "NOT CHECKED", tooltip: RetractionText.checkedOnLine(nil),
                          isRetracted: false, isConcern: false)
                return
            }
            let text: String
            if check.isRetracted {
                text = "RETRACTED"
            } else if check.isConcern {
                text = "CONCERN"
            } else if check.isUnchecked {
                text = "NOT CHECKED"
            } else {
                return nil
            }
            self.init(text: text, tooltip: RetractionText.paperStatusLine(check),
                      isRetracted: check.isRetracted, isConcern: check.isConcern)
        }

        private init(text: String, tooltip: String, isRetracted: Bool, isConcern: Bool) {
            self.text = text
            self.tooltip = tooltip
            self.isRetracted = isRetracted
            self.isConcern = isConcern
        }

        /// The badge's colour: red retracted, orange concern, grey unchecked.
        var color: Color { isRetracted ? .red : (isConcern ? .orange : .gray) }
    }

    let content: Content

    /// Builds the badge, or `nil` when the check shows none.
    init?(check: PaperRetractionCheck?, inDetail: Bool = false) {
        guard let content = Content(check: check, inDetail: inDetail) else { return nil }
        self.content = content
    }

    var body: some View {
        Text(content.text)
            .font(.system(size: RetractionBadgeConstants.labelFontSize, weight: .bold))
            .foregroundColor(content.color)
            .padding(.horizontal, RetractionBadgeConstants.horizontalPadding)
            .padding(.vertical, RetractionBadgeConstants.verticalPadding)
            .background(content.color.opacity(RetractionBadgeConstants.backgroundOpacity))
            .cornerRadius(RetractionBadgeConstants.cornerRadius)
            .help(content.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(content.text). \(content.tooltip)")
    }
}

/// The banner above a full-text viewer: the badge and the status line.
/// Nothing for a clear paper.
struct RetractionBanner: View {
    let check: PaperRetractionCheck?

    var body: some View {
        if let badge = RetractionBadge(check: check, inDetail: true) {
            HStack(spacing: RetractionBadgeConstants.bannerSpacing) {
                badge
                Text(badge.content.tooltip)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(RetractionBadgeConstants.bannerPadding)
            .background(badge.content.color.opacity(RetractionBadgeConstants.backgroundOpacity))
        }
    }
}

/// A restored session's retraction line with *Check again*, and the warning
/// when a paper its report cites is now retracted or under concern (the
/// desktop's report-tab line, button and warning).
struct RetractionSavedWorkSection: View {
    /// ``FactCheckWorkflow/retractionSavedWorkLine``.
    let line: String
    /// ``FactCheckWorkflow/retractionSavedWorkWarning``.
    let warning: String?
    /// Whether *Check again* is running.
    let isChecking: Bool
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RetractionBadgeConstants.bannerSpacing) {
            HStack(spacing: RetractionBadgeConstants.bannerSpacing) {
                Text(line)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(RetractionText.checkAgainLabel, action: onCheckAgain)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isChecking)
            }
            if let warning {
                Text(warning)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(RetractionBadgeConstants.bannerPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(RetractionBadgeConstants.backgroundOpacity))
            }
        }
    }
}
