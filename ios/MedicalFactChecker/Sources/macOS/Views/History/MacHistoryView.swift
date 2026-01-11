//
//  MacHistoryView.swift
//  MedicalFactChecker
//
//  macOS-optimized view for browsing past fact-check sessions.
//  Features a table-based layout with search and filtering.
//

import SwiftUI
import SwiftData

/// macOS history view with table layout and filtering.
///
/// Features:
/// - Searchable session list
/// - Sortable columns
/// - Quick actions (delete, export)
/// - Session detail on selection
struct MacHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    let onReportSelected: ((EvidenceReport) -> Void)?

    @State private var searchText = ""
    @State private var selectedSession: FactCheckSession?
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
                .frame(minWidth: 400, idealWidth: 500)

            // Right: Session detail
            sessionDetail
                .frame(minWidth: 300)
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
                        .frame(width: 200)
                }
                .padding(6)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(6)

                // Delete button
                if selectedSession != nil {
                    Button(action: deleteSelectedSession) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Delete selected session")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if filteredSessions.isEmpty {
                emptyState
            } else {
                List(selection: $selectedSession) {
                    ForEach(filteredSessions) { session in
                        MacSessionRow(session: session)
                            .tag(session)
                            .contextMenu {
                                if session.report != nil {
                                    Button("View Report") {
                                        if let report = session.report {
                                            onReportSelected?(report)
                                        }
                                    }
                                }

                                Divider()

                                Button("Delete", role: .destructive) {
                                    deleteSession(session)
                                }
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.4))

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
            MacSessionDetailView(session: session, onViewReport: {
                if let report = session.report {
                    onReportSelected?(report)
                }
            })
        } else {
            VStack(spacing: 16) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.4))

                Text("Select a Session")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Choose a fact-check session from the list to view details")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 200)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private func deleteSelectedSession() {
        guard let session = selectedSession else { return }
        deleteSession(session)
    }

    private func deleteSession(_ session: FactCheckSession) {
        if selectedSession == session {
            selectedSession = nil
        }
        modelContext.delete(session)
        try? modelContext.save()
    }
}

// MARK: - Session Row

struct MacSessionRow: View {
    let session: FactCheckSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Claim
            Text(session.claim)
                .font(.body)
                .lineLimit(2)

            // Status and metadata
            HStack(spacing: 12) {
                // Verdict or status badge
                if let report = session.report {
                    MacSmallVerdictBadge(verdict: report.verdict)
                } else {
                    MacStatusBadge(step: session.currentStep)
                }

                Spacer()

                // Stats
                if let report = session.report {
                    HStack(spacing: 8) {
                        Label("\(report.documentsReviewed)", systemImage: "doc.text")
                        Label("\(report.citationCount)", systemImage: "quote.bubble")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Date
                Text(session.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
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
            } else if !step.isTerminal {
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

struct MacSessionDetailView: View {
    let session: FactCheckSession
    let onViewReport: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Details")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("Created \(session.createdAt.formatted(date: .long, time: .shortened))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Claim
                VStack(alignment: .leading, spacing: 6) {
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
                    VStack(alignment: .leading, spacing: 6) {
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
                VStack(alignment: .leading, spacing: 8) {
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
                if session.documents.count > 0 {
                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Statistics")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        HStack(spacing: 24) {
                            MacDetailStatItem(
                                value: "\(session.documents.count)",
                                label: "Documents"
                            )
                            MacDetailStatItem(
                                value: "\(session.documents.filter { $0.isScored }.count)",
                                label: "Scored"
                            )
                            MacDetailStatItem(
                                value: "\(session.relevantDocuments.count)",
                                label: "Relevant"
                            )
                        }

                        HStack(spacing: 24) {
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

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct MacDetailStatItem: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
    MacHistoryView(onReportSelected: nil)
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
        .frame(width: 900, height: 600)
}
