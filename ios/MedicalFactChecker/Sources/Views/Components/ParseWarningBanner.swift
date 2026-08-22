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

import SwiftUI
import BioMedLit

/// Layout and tint values for ``ParseWarningBanner``.
private enum ParseWarningBannerConstants {
    /// Vertical gap between the banner's own rows.
    static let spacing: CGFloat = 8

    /// Inset around the banner content, and its margin from the content below.
    static let padding: CGFloat = 12

    /// Corner radius of the banner's outline.
    static let cornerRadius: CGFloat = 8

    /// Vertical gap between individual diagnostic lines in the disclosure.
    static let detailSpacing: CGFloat = 4

    /// Tint strength of the warning fill, kept light enough to read over.
    static let backgroundOpacity: Double = 0.15
}

/// Tells the reader when what they are looking at is not the whole article, or
/// not the copy we would have preferred to give them.
///
/// Without this the app renders a gutted article exactly as it renders a
/// complete one, so a reader who cannot find the table they came for has no way
/// to know whether the publisher never deposited it or the parser dropped it
/// (#181). Those are opposite conclusions, and in a medical-literature tool the
/// wrong one is a reader deciding the evidence is absent.
///
/// Three states, one component, so the two facts cannot drift apart in wording
/// or styling:
///
/// - nothing lost and the best source used — renders nothing;
/// - the rendering is incomplete — a warning;
/// - a better source existed and could not be read — an informational note.
///
/// The last is deliberately *not* a warning. A fallback PDF is complete, and a
/// warning triangle over content that is fine is the false alarm that trains a
/// reader to dismiss the banner on the article where text really was discarded
/// (#183).
///
/// The sentences are composed here rather than in `BioMedLit` because they are
/// clinician-facing copy: the package emits typed losses and developer
/// diagnostics, and those are offered as expandable detail for a bug report
/// rather than shown by default.
/// What a ``ParseWarningBanner`` has to say about a retrieval, if anything.
///
/// A pure value rather than a computation inside the view, so the choice between
/// the three states — the part with actual logic in it — can be tested without
/// rendering anything.
enum ParseWarningMessage: Equatable {
    /// Parts of the rendering are missing.
    case incomplete

    /// The rendering carries no article text at all.
    ///
    /// Distinguished from ``incomplete`` because "some of this article" badly
    /// understates a document reduced to its own accession number. Telling the
    /// two apart is what typing the losses made possible (#184).
    case noContent

    /// A better source existed and could not be read (#183).
    case degraded

    /// What to tell the reader about a retrieval, or `nil` when there is nothing
    /// to say.
    ///
    /// Warnings win over a degradation on a result that somehow carries both: an
    /// incomplete rendering the reader is actually looking at outranks a note
    /// about the source it came from.
    ///
    /// - Parameters:
    ///   - warnings: What the parse of this content lost.
    ///   - degradation: Why this is not the best source that existed, if it is not.
    init?(warnings: JATSParseWarnings, degradation: FullTextDegradation?) {
        if !warnings.isClean {
            self = warnings.losses.contains(.noContent) ? .noContent : .incomplete
        } else if degradation != nil {
            self = .degraded
        } else {
            return nil
        }
    }

    /// Whether this is a problem with the text shown, or a note about its source.
    ///
    /// A degradation is deliberately not a warning: the fallback PDF is
    /// complete, and a warning over content that is fine is the false alarm that
    /// trains a reader to dismiss the banner on the article where text really was
    /// discarded.
    var isWarning: Bool { self != .degraded }

    /// The sentence the reader sees.
    var headline: LocalizedStringKey {
        switch self {
        case .incomplete:
            return "Some of this article could not be displayed. Parts of the text may be missing."
        case .noContent:
            return "None of this article's text could be displayed. Only its reference details are shown."
        case .degraded:
            return "This article's machine-readable copy could not be read, so a substitute is shown here."
        }
    }

    /// The SF Symbol beside the headline.
    var iconName: String {
        isWarning ? "exclamationmark.triangle.fill" : "info.circle.fill"
    }
}

struct ParseWarningBanner: View {
    /// What the parse lost. Renders nothing when it lost nothing.
    let warnings: JATSParseWarnings

    /// Why this is not the best source that existed, or `nil` when it is.
    ///
    /// Defaulted so the callers that render a parsed article need not name it,
    /// which is also what keeps the memberwise initialiser usable with either
    /// fact alone.
    var degradation: FullTextDegradation? = nil

    @State private var showingDetail = false

    var body: some View {
        if let message = ParseWarningMessage(warnings: warnings, degradation: degradation) {
            VStack(alignment: .leading, spacing: ParseWarningBannerConstants.spacing) {
                Label(message.headline, systemImage: message.iconName)
                    .font(.footnote)
                    .foregroundStyle(.primary)

                // The package's developer diagnostics, for a bug report. A
                // degradation has none — the parser's own error went to the log —
                // so the disclosure is omitted rather than padded.
                if !warnings.diagnostics.isEmpty {
                    DisclosureGroup("Technical details", isExpanded: $showingDetail) {
                        VStack(
                            alignment: .leading,
                            spacing: ParseWarningBannerConstants.detailSpacing
                        ) {
                            ForEach(warnings.diagnostics, id: \.self) { diagnostic in
                                Text(diagnostic)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.top, ParseWarningBannerConstants.detailSpacing)
                    }
                    .font(.caption)
                }
            }
            .padding(ParseWarningBannerConstants.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (message.isWarning ? Color.yellow : Color.accentColor)
                    .opacity(ParseWarningBannerConstants.backgroundOpacity)
            )
            .clipShape(
                RoundedRectangle(cornerRadius: ParseWarningBannerConstants.cornerRadius)
            )
            .padding(.horizontal, ParseWarningBannerConstants.padding)
            .padding(.top, ParseWarningBannerConstants.spacing)
            .accessibilityElement(children: .contain)
        }
    }
}

#Preview {
    VStack {
        ParseWarningBanner(warnings: JATSParseWarnings(losses: [.openTables(2)]))
        ParseWarningBanner(warnings: JATSParseWarnings(losses: [.noContent]))
        ParseWarningBanner(warnings: JATSParseWarnings(), degradation: .jatsParseFailed)
        ParseWarningBanner(warnings: JATSParseWarnings())
        Spacer()
    }
}
