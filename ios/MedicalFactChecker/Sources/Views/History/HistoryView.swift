//
//  HistoryView.swift
//  MedicalFactChecker
//
//  View for browsing past fact-check sessions.
//

import SwiftUI
import SwiftData

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FactCheckSession.createdAt, order: .reverse) private var sessions: [FactCheckSession]

    @State private var selectedReport: EvidenceReport?

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    EmptyHistoryView()
                } else {
                    List {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let report = session.report {
                                        selectedReport = report
                                    }
                                }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("History")
            .toolbar {
                if !sessions.isEmpty {
                    EditButton()
                }
            }
            .sheet(item: $selectedReport) { report in
                ReportView(report: report)
            }
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sessions[index])
        }
        try? modelContext.save()
    }
}

// MARK: - Subviews

struct EmptyHistoryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "clock")
                .font(.system(size: 60))
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

struct SessionRow: View {
    let session: FactCheckSession

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

                // Date
                Text(session.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
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
        }
        .padding(.vertical, 4)
    }
}

struct SmallVerdictBadge: View {
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

struct StatusBadge: View {
    let step: WorkflowStep

    var body: some View {
        HStack(spacing: 4) {
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

#Preview {
    HistoryView()
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
}
