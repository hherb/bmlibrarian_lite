#if os(iOS)
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
import SwiftData

/// A view displaying the history of fact-check sessions.
///
/// Shows a list of past fact-checks with their verdicts, statistics, and options
/// to view reports, continue searching, or delete sessions. Sessions with more
/// available evidence display a "Continue Search" button.
///
/// On iPad, displays a split-view with session details on the right.
/// Tapping a session row restores the full session state in the Check tab,
/// including the claim text, scored documents, and report. Use the context menu
/// "View Report" option to view just the report as a popup.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    /// Callback when user wants to continue searching from an existing session.
    ///
    /// Called when the user taps the "Continue Search" button or context menu item.
    /// The parent view should restore the session's claim text and resume the workflow.
    var onContinueSession: ((FactCheckSession) -> Void)?

    @State private var selectedReport: EvidenceReport?
    @State private var sessionToDelete: FactCheckSession?
    @State private var searchText = ""
    @State private var selectedSession: FactCheckSession?
    @State private var showingDetailSheet = false

    /// Sessions filtered by search text.
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
        NavigationSplitView {
            sessionListView
                .navigationTitle("History")
        } detail: {
            sessionDetailView
        }
        .searchable(text: $searchText, prompt: "Search claims...")
        .sheet(item: $selectedReport) { report in
            ReportView(report: report)
        }
        .sheet(isPresented: $showingDetailSheet) {
            if let session = selectedSession {
                NavigationStack {
                    SessionDetailView(
                        session: session,
                        onViewReport: { selectedReport = session.report },
                        onContinueSession: {
                            showingDetailSheet = false
                            onContinueSession?(session)
                        }
                    )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                showingDetailSheet = false
                            }
                        }
                    }
                }
            }
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
            Text("This will permanently delete the fact-check for \"\(session.claim.prefix(HistoryConstants.maxClaimPreviewLength))\(session.claim.count > HistoryConstants.maxClaimPreviewLength ? "..." : "")\" and all associated data.")
        }
    }

    // MARK: - Session List View

    private var sessionListView: some View {
        Group {
            if sessions.isEmpty {
                EmptyHistoryView()
            } else {
                List(selection: $selectedSession) {
                    ForEach(filteredSessions) { session in
                        SessionRow(
                            session: session,
                            isSelected: selectedSession?.id == session.id,
                            onContinueSearch: onContinueSession != nil ? {
                                onContinueSession?(session)
                            } : nil
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            handleSessionTap(session)
                        }
                        .tag(session)
                        .contextMenu {
                            Button {
                                selectedSession = session
                                if horizontalSizeClass == .compact {
                                    showingDetailSheet = true
                                }
                            } label: {
                                Label("View Details", systemImage: "info.circle")
                            }

                            if session.report != nil {
                                Button {
                                    selectedReport = session.report
                                } label: {
                                    Label("View Report", systemImage: "doc.text")
                                }
                            }

                            if session.canGetMoreEvidence {
                                Button {
                                    onContinueSession?(session)
                                } label: {
                                    Label("Continue Search", systemImage: "magnifyingglass.circle")
                                }
                            }

                            Divider()

                            Button(role: .destructive) {
                                sessionToDelete = session
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete(perform: deleteSessions)
                }
                .listStyle(.insetGrouped)
            }
        }
        .toolbar {
            if !sessions.isEmpty {
                EditButton()
            }
        }
    }

    // MARK: - Session Detail View (Split View)

    @ViewBuilder
    private var sessionDetailView: some View {
        if let session = selectedSession {
            SessionDetailView(
                session: session,
                onViewReport: { selectedReport = session.report },
                onContinueSession: { onContinueSession?(session) }
            )
        } else {
            emptyDetailView
        }
    }

    private var emptyDetailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "sidebar.left")
                .font(.system(size: HistoryConstants.emptyStateIconSize))
                .foregroundColor(.secondary.opacity(0.5))

            Text("Select a Session")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Choose a session from the list to view its details.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: - Actions

    /// Handle tap on a session row.
    private func handleSessionTap(_ session: FactCheckSession) {
        selectedSession = session
        if horizontalSizeClass == .compact {
            // On iPhone, show detail sheet
            showingDetailSheet = true
        }
    }

    // MARK: - Private Methods

    /// Deletes sessions at the given offsets within `filteredSessions`.
    ///
    /// Used by the swipe-to-delete gesture on the list.
    /// - Parameter offsets: Index set within `filteredSessions`.
    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let sessionToRemove = filteredSessions[index]
            if selectedSession?.id == sessionToRemove.id {
                selectedSession = nil
            }
            modelContext.delete(sessionToRemove)
        }
        try? modelContext.save()
    }

    /// Deletes a single session from the database.
    ///
    /// Used by the context menu delete action.
    /// - Parameter session: The session to delete.
    private func deleteSession(_ session: FactCheckSession) {
        if selectedSession?.id == session.id {
            selectedSession = nil
        }
        modelContext.delete(session)
        try? modelContext.save()
    }
}

// MARK: - Subviews

/// Empty state view shown when there are no fact-check sessions in history.
///
/// Displays a clock icon and helpful text to indicate the history is empty.
struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: HistoryConstants.emptyStateIconSize))
                .foregroundColor(.secondary)
            Text("No Fact Checks Yet")
                .font(.headline)
            Text("Your completed fact-checks will appear here")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

/// A row displaying a single fact-check session in the history list.
///
/// Shows the claim text, verdict badge, date, and statistics.
/// Optionally displays a "Continue Search" button when more results are available.
struct SessionRow: View {
    /// The fact-check session to display.
    let session: FactCheckSession

    /// Whether this row is selected (for split-view highlighting).
    var isSelected: Bool = false

    /// Optional callback when the user taps the "Continue Search" button.
    ///
    /// If nil, the button is not shown even when more evidence is available.
    var onContinueSearch: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Claim text
            Text(session.claim)
                .font(.body)
                .lineLimit(2)

            // Status and date
            HStack {
                // Verdict badge (if completed)
                if let report = session.report {
                    SmallVerdictBadge(verdict: report.verdict)
                } else {
                    StatusBadge(step: session.currentStep)
                }

                Spacer()

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

            // Stats (if completed)
            if let report = session.report {
                HStack(spacing: 16) {
                    Label("\(report.documentsReviewed)", systemImage: "doc.text")
                    Label("\(report.citationCount)", systemImage: "quote.bubble")
                    Label(CostCalculator.formatCost(session.estimatedCostUSD), systemImage: "dollarsign.circle")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // More results indicator and continue button
            if session.canGetMoreEvidence {
                HStack {
                    // Visual indicator
                    HStack(spacing: 4) {
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
        .padding(.vertical, 4)
    }
}

/// A compact badge displaying a fact-check verdict.
///
/// Shows the verdict text with a color-coded background indicating
/// the level of evidence support (green for supported, red for not supported, etc.).
struct SmallVerdictBadge: View {
    /// The verdict to display.
    let verdict: Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundColor.opacity(0.2))
            .foregroundColor(backgroundColor)
            .cornerRadius(6)
    }

    private var backgroundColor: Color {
        switch verdict {
        case .supported: return .green
        case .partiallySupported: return .orange
        case .notSupported: return .red
        case .insufficientEvidence: return .gray
        case .conflicting: return .purple
        }
    }
}

/// A badge displaying the current workflow step status.
///
/// Shows an icon and text indicating the session's progress state,
/// such as processing, paused, failed, or completed.
struct StatusBadge: View {
    /// The workflow step to display.
    let step: WorkflowStep

    var body: some View {
        HStack(spacing: 4) {
            if step == .failed || step == .budgetExceeded {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
            } else if step.isPaused {
                Image(systemName: step == .awaitingUserDecision ? "pause.circle" : "circle")
                    .foregroundColor(.secondary)
            } else if step.isProcessing {
                ProgressView()
                    .scaleEffect(0.6)
            }

            Text(step.displayName)
                .font(.caption)
                .foregroundColor(step.isTerminal && step != .completed ? .red : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Session Detail View

/// Detailed view displaying comprehensive session statistics.
///
/// Shows:
/// - Claim text and PubMed query
/// - Verdict badge (if completed)
/// - Statistics (documents, scored, relevant, cost, tokens)
/// - Action buttons (View Report, Continue Search)
struct SessionDetailView: View {
    /// The session to display.
    let session: FactCheckSession

    /// Called when user taps View Report.
    var onViewReport: (() -> Void)?

    /// Called when user taps Continue Session.
    var onContinueSession: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                headerSection

                Divider()

                // Session Info
                sessionInfoSection

                Divider()

                // Statistics
                statisticsSection

                Divider()

                // Actions
                actionsSection
            }
            .padding()
        }
        .navigationTitle("Session Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Date
            Text(session.createdAt, format: .dateTime.month(.wide).day().year().hour().minute())
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Verdict or Status
            if let report = session.report {
                SmallVerdictBadge(verdict: report.verdict)
            } else {
                StatusBadge(step: session.currentStep)
            }
        }
    }

    // MARK: - Session Info Section

    private var sessionInfoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Claim
            VStack(alignment: .leading, spacing: 4) {
                Text("Claim")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(session.claim)
                    .font(.body)
                    .textSelection(.enabled)
            }

            // PubMed Query
            if let query = session.pubmedQuery, !query.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search Query")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)

                    Text(query)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Statistics Section

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Statistics")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            // First row: Documents, Scored, Relevant
            HStack(spacing: 20) {
                StatItem(
                    value: "\((session.documents ?? []).count)",
                    label: "Documents",
                    icon: "doc.text"
                )

                StatItem(
                    value: "\((session.documents ?? []).filter { $0.isScored }.count)",
                    label: "Scored",
                    icon: "checkmark.circle"
                )

                StatItem(
                    value: "\(session.relevantDocuments.count)",
                    label: "Relevant",
                    icon: "star"
                )
            }

            // Second row: Cost, Tokens, Duration
            HStack(spacing: 20) {
                StatItem(
                    value: CostCalculator.formatCost(session.estimatedCostUSD),
                    label: "Cost",
                    icon: "dollarsign.circle"
                )

                StatItem(
                    value: formatTokens(session.totalInputTokens + session.totalOutputTokens),
                    label: "Tokens",
                    icon: "number"
                )

                if let report = session.report {
                    StatItem(
                        value: "\(report.citationCount)",
                        label: "Citations",
                        icon: "quote.bubble"
                    )
                }
            }
        }
    }

    /// Format token count for display.
    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    // MARK: - Actions Section

    private var actionsSection: some View {
        VStack(spacing: 12) {
            // View Report button
            if session.report != nil {
                Button(action: { onViewReport?() }) {
                    Label("View Report", systemImage: "doc.text")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }

            // Continue Search button
            if session.canGetMoreEvidence {
                Button(action: { onContinueSession?() }) {
                    Label("Continue Search", systemImage: "magnifyingglass.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

/// A single statistic item with icon, value, and label.
struct StatItem: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)

            Text(value)
                .font(.headline)
                .fontWeight(.semibold)

            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    HistoryView(onContinueSession: { session in
        print("Continue session: \(session.claim)")
    })
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
}

#endif // os(iOS)
