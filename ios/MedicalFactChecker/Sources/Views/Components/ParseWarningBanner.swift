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

private enum ParseWarningBannerConstants {
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12
    static let cornerRadius: CGFloat = 8
    static let detailSpacing: CGFloat = 4
}

/// Tells the reader that what they are looking at is not the whole article.
///
/// Without this the app renders a gutted article exactly as it renders a
/// complete one, so a reader who cannot find the table they came for has no way
/// to know whether the publisher never deposited it or the parser dropped it
/// (#181). Those are opposite conclusions, and in a medical-literature tool the
/// wrong one is a reader deciding the evidence is absent.
///
/// The sentence is composed here rather than in `BioMedLit` because it is
/// clinician-facing copy: the package emits developer diagnostics, and those are
/// offered as expandable detail for a bug report rather than shown by default.
struct ParseWarningBanner: View {
    /// What the parse lost. Renders nothing when it lost nothing.
    let warnings: JATSParseWarnings

    @State private var showingDetail = false

    var body: some View {
        if !warnings.isClean {
            VStack(alignment: .leading, spacing: ParseWarningBannerConstants.spacing) {
                Label(
                    "Some of this article could not be displayed. Parts of the text may be missing.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.primary)

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
            .padding(ParseWarningBannerConstants.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.yellow.opacity(0.15))
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
        ParseWarningBanner(warnings: JATSParseWarnings(diagnostics: [
            "JATS parse ended with 2 open <table-wrap> — those tables and their content were discarded"
        ]))
        ParseWarningBanner(warnings: JATSParseWarnings())
        Spacer()
    }
}
