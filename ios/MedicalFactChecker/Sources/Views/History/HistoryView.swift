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
/// Tapping a session row restores the full session state in the Check tab,
/// including the claim text, scored documents, and report. Use the context menu
/// "View Report" option to view just the report as a popup.
struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    /// Callback when user wants to continue searching from an existing session.
    ///
    /// Called when the user taps the "Continue Search" button or context menu item.
    /// The parent view should restore the session's claim text and resume the workflow.
    var onContinueSession: ((FactCheckSession) -> Void)?

    @State private var selectedReport: EvidenceReport?
    @State private var sessionToDelete: FactCheckSession?
    @State private var searchText = ""

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
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    EmptyHistoryView()
                } else {
                    List {
                        ForEach(filteredSessions) { session in
                            SessionRow(
                                session: session,
                                onContinueSearch: onContinueSession != nil ? {
                                    onContinueSession?(session)
                                } : nil
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Restore full session state in Check tab
                                if onContinueSession != nil {
                                    onContinueSession?(session)
                                } else if let report = session.report {
                                    // Fallback: show report popup if no restore handler
                                    selectedReport = report
                                }
                            }
                            .contextMenu {
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
            .navigationTitle("History")
            .searchable(text: $searchText, prompt: "Search claims...")
            .toolbar {
                if !sessions.isEmpty {
                    EditButton()
                }
            }
            .sheet(item: $selectedReport) { report in
                ReportView(report: report)
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
    }

    // MARK: - Private Methods

    /// Deletes multiple sessions at the given offsets.
    ///
    /// Used by the swipe-to-delete gesture on the list.
    /// - Parameter offsets: The index set of sessions to delete.
    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }

    /// Deletes a single session from the database.
    ///
    /// Used by the context menu delete action.
    /// - Parameter session: The session to delete.
    private func deleteSession(_ session: FactCheckSession) {
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
