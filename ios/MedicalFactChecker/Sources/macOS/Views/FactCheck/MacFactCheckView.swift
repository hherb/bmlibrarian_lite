//
//  MacFactCheckView.swift
//  MedicalFactChecker
//
//  macOS-optimized view for entering claims and running fact-checks.
//  Uses a two-column layout with input on the left and results on the right.
//

import SwiftUI
import SwiftData

/// macOS fact-check view with two-column layout.
///
/// Left column: Claim input, controls, and progress.
/// Right column: Scored documents and results.
struct MacFactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    /// Callback when a report is generated (navigates to Report view).
    var onReportGenerated: ((EvidenceReport) -> Void)?

    @State private var claimText = ""
    @State private var workflow: FactCheckWorkflow?
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        HSplitView {
            // Left column: Input and controls
            leftColumn
                .frame(minWidth: 400, idealWidth: 500, maxWidth: 600)

            // Right column: Documents and results
            rightColumn
                .frame(minWidth: 400)
        }
        .frame(minHeight: 500)
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                Text("Medical Fact Check")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                // Configuration warning
                if !settings.isLLMConfigured {
                    MacConfigurationWarningView()
                }

                // Claim input
                MacClaimInputSection(
                    claimText: $claimText,
                    isRunning: workflow?.isRunning ?? false,
                    canSubmit: canSubmit,
                    onSubmit: startFactCheck
                )

                // Budget display
                MacBudgetDisplayView()

                // Progress section
                if let workflow = workflow, workflow.isRunning {
                    MacProgressSection(workflow: workflow)
                }

                // User decision section
                if let workflow = workflow, workflow.awaitingUserDecision {
                    MacUserDecisionSection(
                        prompt: workflow.userDecisionPrompt,
                        onContinue: { Task { await workflow.continueWithMoreDocuments() } },
                        onProceed: { Task { await workflow.proceedWithCurrentDocuments() } }
                    )
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Right Column

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Documents")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                if let session = workflow?.session {
                    let scored = session.documents.filter { $0.isScored }.count
                    let total = session.documents.count
                    Text("\(scored) of \(total) scored")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Documents list
            if let session = workflow?.session,
               !session.documents.filter({ $0.isScored }).isEmpty {
                MacScoredDocumentsView(
                    session: session,
                    showEmbeddingScores: settings.embeddingScoringEnabled
                )
            } else {
                emptyDocumentsState
            }
        }
    }

    private var emptyDocumentsState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Documents Yet")
                .font(.title3)
                .fontWeight(.medium)

            Text("Enter a medical claim and click \"Check Evidence\" to search PubMed")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Computed Properties

    private var canSubmit: Bool {
        let trimmed = claimText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && settings.isLLMConfigured && !(workflow?.isRunning ?? false)
    }

    // MARK: - Actions

    private func startFactCheck() {
        let newWorkflow = FactCheckWorkflow(modelContext: modelContext, settings: settings)

        newWorkflow.onComplete = { report in
            onReportGenerated?(report)
        }

        newWorkflow.onError = { error in
            errorMessage = error.localizedDescription
            showingError = true
        }

        newWorkflow.onBudgetExceeded = { message in
            errorMessage = message
            showingError = true
        }

        self.workflow = newWorkflow

        Task {
            await newWorkflow.startFactCheck(claim: claimText)
        }
    }
}

// MARK: - Subviews

struct MacConfigurationWarningView: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("LLM Not Configured")
                    .font(.headline)
                Text("Open Settings to configure your LLM API before fact-checking.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Open Settings") {
                #if os(macOS)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                #endif
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
}

struct MacClaimInputSection: View {
    @Binding var claimText: String
    let isRunning: Bool
    let canSubmit: Bool
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter a medical claim or question")
                .font(.headline)

            TextEditor(text: $claimText)
                .font(.body)
                .frame(minHeight: 120, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .disabled(isRunning)

            Text("Examples: \"Vitamin D reduces COVID-19 severity\" or \"Is aspirin effective for preventing heart attacks?\"")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(action: onSubmit) {
                    HStack(spacing: 8) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.7)
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(isRunning ? "Checking..." : "Check Evidence")
                    }
                    .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                if isRunning {
                    Button("Cancel") {
                        // TODO: Implement cancellation
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
    }
}

struct MacBudgetDisplayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var monthlyUsed: Double = 0

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Monthly Budget")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(CostCalculator.formatCost(monthlyUsed)) / \(CostCalculator.formatCost(settings.monthlyBudgetUSD))")
                    .font(.headline)
            }

            ProgressView(value: min(monthlyUsed / settings.monthlyBudgetUSD, 1.0))
                .frame(width: 100)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Per-run limit")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(settings.maxRunBudgetUSD))
                    .font(.headline)
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.2))
        )
        .onAppear(perform: loadMonthlyUsage)
    }

    private func loadMonthlyUsage() {
        let monthKey = UsageRecord.currentMonthKey
        let descriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate { $0.monthKey == monthKey }
        )

        if let records = try? modelContext.fetch(descriptor) {
            monthlyUsed = records.reduce(0) { $0 + $1.costUSD }
        }
    }
}

struct MacProgressSection: View {
    let workflow: FactCheckWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Step indicators
            HStack(spacing: 0) {
                ForEach(Array(mainSteps.enumerated()), id: \.element) { index, step in
                    MacStepIndicator(
                        step: step,
                        currentStep: workflow.session?.currentStep ?? .idle,
                        isFirst: index == 0,
                        isLast: index == mainSteps.count - 1
                    )

                    if index < mainSteps.count - 1 {
                        MacStepConnector(
                            isPast: stepIsPast(step, current: workflow.session?.currentStep ?? .idle)
                        )
                    }
                }
            }

            // Progress bar with percentage
            HStack {
                ProgressView(value: workflow.session?.progressPercent ?? 0, total: 100)
                    .progressViewStyle(LinearProgressViewStyle())

                Text("\(Int(workflow.session?.progressPercent ?? 0))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            // Status message
            HStack {
                Text(workflow.progressMessage)
                    .font(.body)
                    .foregroundColor(.secondary)

                Spacer()

                if let session = workflow.session, session.estimatedCostUSD > 0 {
                    Text("Cost: \(CostCalculator.formatCost(session.estimatedCostUSD))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                }
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.05))
        .cornerRadius(10)
    }

    private var mainSteps: [WorkflowStep] {
        [.convertingQuery, .searchingPubMed, .scoringDocuments, .extractingCitations, .generatingReport]
    }

    private func stepIsPast(_ step: WorkflowStep, current: WorkflowStep) -> Bool {
        let stepOrder = WorkflowStep.allCases
        guard let currentIndex = stepOrder.firstIndex(of: current),
              let stepIndex = stepOrder.firstIndex(of: step) else {
            return false
        }
        return stepIndex < currentIndex
    }
}

struct MacStepIndicator: View {
    let step: WorkflowStep
    let currentStep: WorkflowStep
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 16, height: 16)
                .overlay {
                    if step == currentStep {
                        Circle()
                            .stroke(color.opacity(0.3), lineWidth: 3)
                            .frame(width: 24, height: 24)
                    }
                }

            Text(shortName)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var color: Color {
        let stepOrder = WorkflowStep.allCases
        guard let currentIndex = stepOrder.firstIndex(of: currentStep),
              let stepIndex = stepOrder.firstIndex(of: step) else {
            return .gray.opacity(0.3)
        }

        if step == currentStep {
            return .accentColor
        } else if stepIndex < currentIndex {
            return .green
        } else {
            return .gray.opacity(0.3)
        }
    }

    private var shortName: String {
        switch step {
        case .convertingQuery: return "Query"
        case .searchingPubMed: return "Search"
        case .scoringDocuments: return "Score"
        case .extractingCitations: return "Cite"
        case .generatingReport: return "Report"
        default: return ""
        }
    }
}

struct MacStepConnector: View {
    let isPast: Bool

    var body: some View {
        Rectangle()
            .fill(isPast ? Color.green : Color.gray.opacity(0.3))
            .frame(height: 2)
            .frame(maxWidth: 40)
            .padding(.bottom, 20) // Align with circles
    }
}

struct MacUserDecisionSection: View {
    let prompt: String
    let onContinue: () -> Void
    let onProceed: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                Text(prompt)
                    .font(.body)

                Spacer()
            }

            HStack(spacing: 12) {
                Button("Fetch More Documents") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent)

                Button("Continue with Current") {
                    onProceed()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
}

#Preview {
    MacFactCheckView(onReportGenerated: nil)
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
        .environment(AppSettings.shared)
        .frame(width: 1000, height: 700)
}
