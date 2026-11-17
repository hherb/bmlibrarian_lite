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

/// Layout values for ``SearchQueriesView``.
enum SearchQueriesViewConstants {
    /// Space between the header and the queries, and between queries.
    static let sectionSpacing: CGFloat = 8
    /// Space between a query's lines.
    static let rowSpacing: CGFloat = 2
    /// Padding inside a query's box.
    static let rowPadding: CGFloat = 8
    /// Corner radius of a query's box.
    static let rowCornerRadius: CGFloat = 6
    /// Opacity of a query's box.
    static let rowBackgroundOpacity: Double = 0.08
}

/// Every query a session ran, folded to the first until the reader asks for all.
///
/// Folded, it shows the initial query and its counts; when the session ran
/// more than one query (smart search's alternatives, or the initial query
/// asked of another provider), tapping the query or the button beside the
/// header unfolds the list, each query with how many documents it found and
/// how many of those were relevant.
struct SearchQueriesView: View {
    /// The session whose queries are shown.
    let session: FactCheckSession

    /// The lowest score that counts as relevant.
    var minScore: Int = AppSettings.shared.minScoreThreshold

    /// Whether every query is shown without folding (a printed report).
    var alwaysExpanded = false

    /// Whether the header is drawn; off where a surrounding fold names the queries.
    var showsHeader = true

    /// The header's text case (macOS headers are upper case).
    var headerTextCase: Text.Case?

    @State private var isExpanded = false

    var body: some View {
        let rows = session.searchQueryStatistics(minScore: minScore)
        if !rows.isEmpty {
            let showsAll = alwaysExpanded || isExpanded || rows.count == 1
            VStack(alignment: .leading, spacing: SearchQueriesViewConstants.sectionSpacing) {
                if showsHeader {
                    header(rows)
                }
                if showsAll {
                    ForEach(rows.indices, id: \.self) { index in
                        SearchQueryRowView(
                            label: rows.count > 1
                                ? SearchQueryLog.label(at: index, in: rows.map { $0.record })
                                : nil,
                            record: rows[index].record,
                            statistics: rows[index].statistics,
                            selectable: true
                        )
                    }
                } else {
                    Button {
                        withAnimation { isExpanded = true }
                    } label: {
                        VStack(alignment: .leading, spacing: SearchQueriesViewConstants.rowSpacing) {
                            SearchQueryRowView(
                                label: nil,
                                record: rows[0].record,
                                statistics: rows[0].statistics,
                                selectable: false
                            )
                            Text(moreQueriesText(rows.count - 1))
                                .font(.caption2)
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Shows every search query and what each found")
                }
            }
        }
    }

    /// The header: what is listed, and the fold button when there is more than one query.
    @ViewBuilder
    private func header(_ rows: [(record: SearchQueryRecord, statistics: SearchQueryStatistics?)]) -> some View {
        HStack {
            Text(headerTitle(rows))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .textCase(headerTextCase)
            Spacer()
            if rows.count > 1 && !alwaysExpanded {
                Button {
                    withAnimation { isExpanded.toggle() }
                } label: {
                    Label(
                        isExpanded ? "Show first only" : "Show all \(rows.count)",
                        systemImage: isExpanded ? "chevron.up" : "chevron.down"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// The header's text: the provider's query, or all the queries run.
    private func headerTitle(_ rows: [(record: SearchQueryRecord, statistics: SearchQueryStatistics?)]) -> String {
        if rows.count > 1 {
            return "Search Queries (\(rows.count))"
        }
        switch rows[0].record.searchProvider {
        case .pubmed?, nil: return "PubMed Query"
        case .europePMC?: return "Europe PMC Query"
        case .both?: return "Search Query"
        }
    }

    /// The folded list's hint that more queries are listed.
    private func moreQueriesText(_ count: Int) -> String {
        count == 1 ? "+ 1 more query — tap to show" : "+ \(count) more queries — tap to show all"
    }
}

/// One query: its name, its text (and Europe PMC's form), and its counts.
struct SearchQueryRowView: View {
    /// The query's name in the list, or `nil` when it is the only one.
    let label: String?

    /// The query.
    let record: SearchQueryRecord

    /// What it found, or `nil` when that was not recorded.
    let statistics: SearchQueryStatistics?

    /// Whether the query's text can be selected (not while it is a fold button).
    let selectable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SearchQueriesViewConstants.rowSpacing) {
            if let label {
                Text(labelText(label))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            queryText(record.query)
            if let europePMC = record.europePMCQuery {
                Text("As Europe PMC was asked it:")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                queryText(europePMC)
            }
            if let statistics {
                Text(SearchQueryLog.statisticsLine(statistics, totalHits: record.totalHits))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(SearchQueriesViewConstants.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(SearchQueriesViewConstants.rowBackgroundOpacity))
        .cornerRadius(SearchQueriesViewConstants.rowCornerRadius)
    }

    /// The name with the provider the query was asked of.
    private func labelText(_ label: String) -> String {
        switch record.searchProvider {
        case nil: return label
        case .both?: return "\(label) — PubMed + Europe PMC"
        case let provider?: return "\(label) — \(provider.displayName)"
        }
    }

    /// A query's text, selectable where it is not a button.
    @ViewBuilder
    private func queryText(_ text: String) -> some View {
        let styled = Text(text)
            .font(.system(.caption, design: .monospaced))
            .foregroundColor(.accentColor)
            .multilineTextAlignment(.leading)
        if selectable {
            styled.textSelection(.enabled)
        } else {
            styled
        }
    }
}
