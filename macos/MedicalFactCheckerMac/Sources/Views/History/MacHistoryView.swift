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
import SwiftData

/// macOS history view with table layout and filtering.
///
/// Features:
/// - Searchable session list
/// - Sortable columns
/// - Quick actions (delete, export, continue search)
/// - Session detail on selection
/// - Tap row to restore session in Fact Check tab
///
/// Sessions with more available evidence display a "Continue Search" button.
/// Tapping a session row restores the full session state in the Check tab,
/// including the claim text, scored documents, and report.
struct MacHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    /// Callback when the user wants to view a report.
    let onReportSelected: ((EvidenceReport) -> Void)?

    /// Callback when user wants to continue searching from an existing session.
    ///
    /// Called when the user taps a session row, clicks the "Continue Search" button,
    /// or uses the context menu item. The parent view should restore the session's
    /// claim text and resume the workflow.
    let onContinueSession: ((FactCheckSession) -> Void)?

    @State private var searchText = ""
    @State private var selectedSession: FactCheckSession?
    @State private var sessionToDelete: FactCheckSession?
    @State private var sortOrder: [KeyPathComparator<FactCheckSession>] = [
        .init(\.createdAt, order: .reverse)
    ]

    private var filteredSessions: [FactCheckSession] {
        if searchText.isEmpty {
            return sessions
        }
        return sessions.filter { session in
            session.claim.localizedCaseInsensitiveContains(searchText) ||
            (session.pubmedQuery?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        HSplitView {
            // Left: Session list
            sessionList
                .frame(minWidth: MacLayout.leftColumnMinWidth, idealWidth: MacLayout.leftColumnIdealWidth)

            // Right: Session detail
            sessionDetail
                .frame(minWidth: MacLayout.detailColumnMinWidth)
        }
        .alert(
            "Delete Session?",
            isPresented: Binding(
                get: { sessionToDelete != nil },
                set: { if !$0 { sessionToDelete = nil } }
            ),
            presenting: sessionToDelete
        ) { session in
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
            Button("Delete", role: .destructive) {
                deleteSession(session)
                sessionToDelete = nil
            }
        } message: { session in
            Text("This will permanently delete the fact-check for \"\(session.claim.prefix(50))\(session.claim.count > 50 ? "..." : "")\" and all associated data.")
        }
    }

    // MARK: - Session List

    private var sessionList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("History")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                // Search field
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search claims...", text: $searchText)
                        .textFieldStyle(.plain)
                        .frame(width: MacLayout.searchFieldWidth)
                }
                .padding(MacSpacing.small)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(MacCornerRadius.medium)

                // Delete button
                if let session = selectedSession {
                    Button(action: { sessionToDelete = session }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Delete selected session")
                }
            }
            .padding(.horizontal, MacSpacing.xLarge)
            .padding(.vertical, MacSpacing.standard)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if filteredSessions.isEmpty {
                emptyState
            } else {
                List(selection: $selectedSession) {
                    ForEach(filteredSessions) { session in
                        MacSessionRow(
                            session: session,
                            onContinueSearch: onContinueSession != nil ? {
                                onContinueSession?(session)
                            } : nil
                        )
                        .tag(session)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Restore full session state in Check tab
                            if onContinueSession != nil {
                                onContinueSession?(session)
                            } else if let report = session.report {
                                // Fallback: show report popup if no restore handler
                                onReportSelected?(report)
                            }
                        }
                        .contextMenu {
                            if session.report != nil {
                                Button("View Report") {
                                    if let report = session.report {
                                        onReportSelected?(report)
                                    }
                                }
                            }

                            if session.canGetMoreEvidence {
                                Button("Continue Search") {
                                    onContinueSession?(session)
                                }
                            }

                            Divider()

                            Button("Delete", role: .destructive) {
                                sessionToDelete = session
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "clock")
                .font(.system(size: MacIconSize.emptyStateMedium))
                .foregroundColor(.secondary.opacity(MacOpacity.faded))

            Text(searchText.isEmpty ? "No Fact Checks Yet" : "No Results Found")
                .font(.title3)
                .fontWeight(.medium)

            Text(searchText.isEmpty
                 ? "Your completed fact-checks will appear here"
                 : "Try a different search term")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Session Detail

    @ViewBuilder
    private var sessionDetail: some View {
        if let session = selectedSession {
            MacSessionDetailView(
                session: session,
                onViewReport: {
                    if let report = session.report {
                        onReportSelected?(report)
                    }
                },
                onShowFullText: { document in
                    NotificationCenter.default.post(
                        name: .showDocumentFullText,
                        object: nil,
                        userInfo: ["document": document]
                    )
                },
                onContinueSession: {
                    onContinueSession?(session)
                }
            )
        } else {
            VStack(spacing: MacSpacing.large) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: MacIconSize.emptyStateMedium))
                    .foregroundColor(.secondary.opacity(MacOpacity.faded))

                Text("Select a Session")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Choose a fact-check session from the list to view details")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: MacLayout.searchFieldWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    /// Deletes a session from the database.
    ///
    /// Clears the selection if the deleted session was selected, then removes
    /// the session from the model context and saves.
    ///
    /// - Parameter session: The session to delete.
    private func deleteSession(_ session: FactCheckSession) {
        if selectedSession == session {
            selectedSession = nil
        }
        modelContext.delete(session)
        try? modelContext.save()
    }
}

// MARK: - Session Row

/// A single row displaying a fact-check session in the history list.
///
/// Shows the claim text, verdict or status badge, document statistics, timestamp,
/// and optionally a "Continue Search" button when more results are available.
struct MacSessionRow: View {
    /// The session to display.
    let session: FactCheckSession

    /// Optional callback when the user taps the "Continue Search" button.
    ///
    /// If nil, the button is not shown even when more evidence is available.
    var onContinueSearch: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            // Claim
            Text(session.claim)
                .font(.body)
                .lineLimit(2)

            // Status and metadata
            HStack(spacing: MacSpacing.standard) {
                // Verdict or status badge
                if let report = session.report {
                    MacSmallVerdictBadge(verdict: report.verdict)
                } else {
                    MacStatusBadge(step: session.currentStep)
                }

                Spacer()

                // Stats
                if let report = session.report {
                    HStack(spacing: MacSpacing.medium) {
                        Label("\(report.documentsReviewed)", systemImage: "doc.text")
                        Label("\(report.citationCount)", systemImage: "quote.bubble")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Date - use relative for active sessions, fixed for completed
                if session.currentStep.isProcessing {
                    Text(session.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(session.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // More results indicator and continue button
            if session.canGetMoreEvidence {
                HStack {
                    // Visual indicator
                    HStack(spacing: MacSpacing.xSmall) {
                        Image(systemName: "plus.magnifyingglass")
                        Text("More results available")
                    }
                    .font(.caption2)
                    .foregroundColor(.accentColor)

                    Spacer()

                    // Continue search button (if callback provided)
                    if let onContinueSearch {
                        Button {
                            onContinueSearch()
                        } label: {
                            Text("Continue Search")
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, MacSpacing.medium)
    }
}

/// Compact verdict badge for list rows.
struct MacSmallVerdictBadge: View {
    /// The verdict to display.
    let verdict: Verdict

    var body: some View {
        let color = MacColors.verdictColor(for: verdict)
        Text(verdict.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, MacSpacing.medium)
            .padding(.vertical, MacSpacing.xSmall)
            .background(color.opacity(MacOpacity.badgeBackground))
            .foregroundColor(color)
            .cornerRadius(MacCornerRadius.medium)
    }
}

/// Badge displaying workflow step status.
struct MacStatusBadge: View {
    /// The workflow step to display.
    let step: WorkflowStep

    var body: some View {
        HStack(spacing: MacSpacing.xSmall) {
            if step == .failed || step == .budgetExceeded {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            } else if step.isPaused {
                Image(systemName: step == .awaitingUserDecision ? "pause.circle" : "circle")
                    .foregroundColor(.secondary)
            } else if step.isProcessing {
                ProgressView()
                    .scaleEffect(MacScale.progressViewSmall)
            }

            Text(step.displayName)
                .font(.caption)
                .foregroundColor(step.isTerminal && step != .completed ? .red : .secondary)
        }
        .padding(.horizontal, MacSpacing.medium)
        .padding(.vertical, MacSpacing.xSmall)
        .background(Color.secondary.opacity(MacOpacity.subtle))
        .cornerRadius(MacCornerRadius.medium)
    }
}

// MARK: - Session Detail View

/// Detail view showing comprehensive information about a fact-check session.
///
/// Displays the session's claim, PubMed query, status, statistics, scored documents,
/// and provides buttons to view the report and continue searching.
struct MacSessionDetailView: View {
    @Environment(AppSettings.self) private var settings

    /// The session to display.
    let session: FactCheckSession
    /// Callback when the user wants to view the report.
    let onViewReport: () -> Void
    /// Callback when the user wants to view full text for a document.
    var onShowFullText: ((Document) -> Void)?
    /// Callback when the user wants to continue searching from this session.
    var onContinueSession: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSpacing.xLarge) {
                // Header
                VStack(alignment: .leading, spacing: MacSpacing.medium) {
                    Text("Session Details")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Created \(session.createdAt.formatted(date: .long, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Claim
                VStack(alignment: .leading, spacing: MacSpacing.small) {
                    Text("Claim")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    Text(session.claim)
                        .font(.body)
                        .textSelection(.enabled)
                }

                // Query
                if let query = session.pubmedQuery {
                    VStack(alignment: .leading, spacing: MacSpacing.small) {
                        Text("PubMed Query")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Text(query)
                            .font(.body)
                            .fontDesign(.monospaced)
                            .foregroundColor(.accentColor)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                // Status
                VStack(alignment: .leading, spacing: MacSpacing.medium) {
                    Text("Status")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)

                    if let report = session.report {
                        MacVerdictBadge(verdict: report.verdict)
                    } else {
                        MacStatusBadge(step: session.currentStep)
                    }
                }

                // Statistics
                if (session.documents ?? []).count > 0 {
                    Divider()

                    VStack(alignment: .leading, spacing: MacSpacing.standard) {
                        Text("Statistics")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: MacSpacing.sectionSpacing) {
                            MacDetailStatItem(
                                value: "\((session.documents ?? []).count)",
                                label: "Documents"
                            )
                            MacDetailStatItem(
                                value: "\((session.documents ?? []).filter { $0.isScored }.count)",
                                label: "Scored"
                            )
                            MacDetailStatItem(
                                value: "\(session.relevantDocuments.count)",
                                label: "Relevant"
                            )
                        }

                        HStack(spacing: MacSpacing.sectionSpacing) {
                            MacDetailStatItem(
                                value: CostCalculator.formatCost(session.estimatedCostUSD),
                                label: "Cost"
                            )
                            MacDetailStatItem(
                                value: "\(session.totalInputTokens + session.totalOutputTokens)",
                                label: "Tokens"
                            )
                        }
                    }
                }

                Divider()

                // Actions
                VStack(spacing: MacSpacing.standard) {
                    if session.report != nil {
                        Button(action: onViewReport) {
                            HStack {
                                Image(systemName: "doc.text")
                                Text("View Report")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    // Continue Search button
                    if session.canGetMoreEvidence {
                        Button(action: { onContinueSession?() }) {
                            HStack {
                                Image(systemName: "magnifyingglass.circle")
                                Text("Continue Search")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                // Scored Documents
                if (session.documents ?? []).contains(where: { $0.isScored }) {
                    Divider()

                    VStack(alignment: .leading, spacing: MacSpacing.standard) {
                        Text("Scored Documents")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        MacScoredDocumentsView(
                            session: session,
                            showEmbeddingScores: settings.embeddingScoringEnabled,
                            onShowFullText: onShowFullText
                        )
                        .frame(minHeight: MacLayout.scoredDocumentsMinHeight)
                    }
                }

                Spacer(minLength: MacSpacing.xLarge)
            }
            .padding(MacSpacing.xLarge)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

/// Displays a single statistic value with a label.
///
/// Used in the session detail view to show document counts, cost, and tokens.
struct MacDetailStatItem: View {
    /// The statistic value to display.
    let value: String
    /// The label describing the statistic.
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    MacHistoryView(
        onReportSelected: nil,
        onContinueSession: { session in
            print("Continue session: \(session.claim)")
        }
    )
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
    .frame(width: 900, height: 600)
}
