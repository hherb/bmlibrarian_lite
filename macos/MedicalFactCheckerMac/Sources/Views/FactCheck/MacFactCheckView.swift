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

    /// Binding to the workflow (owned by parent to persist across tab switches).
    @Binding var workflow: FactCheckWorkflow?

    /// Callback when a report is generated (navigates to Report view).
    var onReportGenerated: ((EvidenceReport) -> Void)?

    @State private var claimText = ""
    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        HSplitView {
            // Left column: Input and controls
            leftColumn
                .frame(minWidth: MacLayout.leftColumnMinWidth, idealWidth: MacLayout.leftColumnIdealWidth, maxWidth: MacLayout.leftColumnMaxWidth)

            // Right column: Documents and results
            rightColumn
                .frame(minWidth: MacLayout.rightColumnMinWidth)
        }
        .frame(minHeight: MacLayout.viewMinHeight)
        .alert("Error", isPresented: $showingError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Left Column

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MacSpacing.xLarge) {
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

                Spacer(minLength: MacSpacing.xLarge)
            }
            .padding(MacSpacing.xxLarge)
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
            .padding(.horizontal, MacSpacing.xLarge)
            .padding(.vertical, MacSpacing.large)
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
        VStack(spacing: MacSpacing.large) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: MacIconSize.emptyStateMedium))
                .foregroundColor(.secondary.opacity(MacOpacity.half))

            Text("No Documents Yet")
                .font(.title3)
                .fontWeight(.medium)

            Text("Enter a medical claim and click \"Check Evidence\" to search PubMed")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: MacLayout.emptyStateMaxWidth)
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

/// Warning banner displayed when LLM is not configured.
struct MacConfigurationWarningView: View {
    var body: some View {
        HStack(spacing: MacSpacing.standard) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.orange)

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
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
        .padding(MacSpacing.large)
        .background(Color.orange.opacity(MacOpacity.subtle))
        .cornerRadius(MacCornerRadius.large)
    }
}

/// Text input section for entering medical claims.
///
/// Includes a multiline text editor with example hints and a submit button.
struct MacClaimInputSection: View {
    /// The claim text binding.
    @Binding var claimText: String
    /// Whether a fact-check is currently running.
    let isRunning: Bool
    /// Whether the submit button should be enabled.
    let canSubmit: Bool
    /// Callback when the user submits the claim.
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            Text("Enter a medical claim or question")
                .font(.headline)

            TextEditor(text: $claimText)
                .font(.body)
                .frame(minHeight: MacLayout.textEditorMinHeight, maxHeight: MacLayout.textEditorMaxHeight)
                .scrollContentBackground(.hidden)
                .padding(MacSpacing.standard)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: MacCornerRadius.standard)
                        .stroke(Color.secondary.opacity(MacOpacity.muted))
                )
                .disabled(isRunning)

            Text("Examples: \"Vitamin D reduces COVID-19 severity\" or \"Is aspirin effective for preventing heart attacks?\"")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Button(action: onSubmit) {
                    HStack(spacing: MacSpacing.medium) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(MacScale.progressViewMedium)
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(isRunning ? "Checking..." : "Check Evidence")
                    }
                    .frame(minWidth: MacLayout.submitButtonMinWidth)
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

/// Displays current budget usage and limits.
///
/// Shows monthly spending progress and per-run budget limits.
struct MacBudgetDisplayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var monthlyUsed: Double = 0

    var body: some View {
        HStack(spacing: MacSpacing.sectionSpacing) {
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Monthly Budget")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(CostCalculator.formatCost(monthlyUsed)) / \(CostCalculator.formatCost(settings.monthlyBudgetUSD))")
                    .font(.headline)
            }

            ProgressView(value: min(monthlyUsed / settings.monthlyBudgetUSD, 1.0))
                .frame(width: MacLayout.budgetProgressWidth)

            Spacer()

            VStack(alignment: .trailing, spacing: MacSpacing.xSmall) {
                Text("Per-run limit")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(settings.maxRunBudgetUSD))
                    .font(.headline)
            }
        }
        .padding(MacSpacing.large)
        .background(Color(NSColor.controlBackgroundColor).opacity(MacOpacity.half))
        .cornerRadius(MacCornerRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: MacCornerRadius.large)
                .stroke(Color.secondary.opacity(MacOpacity.border))
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

/// Progress display showing workflow steps and completion percentage.
///
/// Displays a horizontal step indicator, progress bar, and status message.
struct MacProgressSection: View {
    /// The workflow being monitored.
    let workflow: FactCheckWorkflow

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.large) {
            // Step indicators
            HStack(spacing: 0) {
                ForEach(Array(mainSteps.enumerated()), id: \.element) { index, step in
                    MacStepIndicator(
                        step: step,
                        currentStep: workflow.session?.currentStep ?? .idle
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
                    .frame(width: MacLayout.percentageWidth, alignment: .trailing)
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
                        .padding(.horizontal, MacSpacing.medium)
                        .padding(.vertical, MacSpacing.xSmall)
                        .background(Color.secondary.opacity(MacOpacity.subtle))
                        .cornerRadius(MacCornerRadius.small)
                }
            }

            // Generated PubMed query (show once generated)
            if let query = workflow.session?.pubmedQuery, !query.isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                    Text("PubMed Query:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(query)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(MacSpacing.medium)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(MacOpacity.subtle))
                        .cornerRadius(MacCornerRadius.small)
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color.accentColor.opacity(MacOpacity.veryLight))
        .cornerRadius(MacCornerRadius.large)
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

/// Individual step indicator in the progress display.
///
/// Shows a colored circle representing the step's status (pending, current, or completed).
struct MacStepIndicator: View {
    /// The workflow step this indicator represents.
    let step: WorkflowStep
    /// The current step in the workflow.
    let currentStep: WorkflowStep

    var body: some View {
        VStack(spacing: MacSpacing.small) {
            Circle()
                .fill(color)
                .frame(width: MacIconSize.stepIndicatorSize, height: MacIconSize.stepIndicatorSize)
                .overlay {
                    if step == currentStep {
                        Circle()
                            .stroke(color.opacity(MacOpacity.muted), lineWidth: 3)
                            .frame(width: MacIconSize.stepIndicatorRingSize, height: MacIconSize.stepIndicatorRingSize)
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
            return .gray.opacity(MacOpacity.muted)
        }

        if step == currentStep {
            return .accentColor
        } else if stepIndex < currentIndex {
            return .green
        } else {
            return .gray.opacity(MacOpacity.muted)
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

/// Horizontal connector line between step indicators.
struct MacStepConnector: View {
    /// Whether this connector represents a completed transition.
    let isPast: Bool

    var body: some View {
        Rectangle()
            .fill(isPast ? Color.green : Color.gray.opacity(MacOpacity.muted))
            .frame(height: MacIconSize.stepConnectorHeight)
            .frame(maxWidth: MacIconSize.stepConnectorMaxWidth)
            .padding(.bottom, MacIconSize.stepConnectorOffset) // Align with circles
    }
}

/// Prompt for user decision during workflow pause.
///
/// Displayed when the workflow needs user input to continue (e.g., fetch more documents).
struct MacUserDecisionSection: View {
    /// The prompt message to display.
    let prompt: String
    /// Callback when user chooses to continue fetching.
    let onContinue: () -> Void
    /// Callback when user chooses to proceed with current documents.
    let onProceed: () -> Void

    var body: some View {
        VStack(spacing: MacSpacing.large) {
            HStack(spacing: MacSpacing.standard) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                Text(prompt)
                    .font(.body)

                Spacer()
            }

            HStack(spacing: MacSpacing.standard) {
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
        .padding(MacSpacing.large)
        .background(Color.orange.opacity(MacOpacity.subtle))
        .cornerRadius(MacCornerRadius.large)
    }
}

#Preview {
    @Previewable @State var previewWorkflow: FactCheckWorkflow? = nil
    MacFactCheckView(workflow: $previewWorkflow, onReportGenerated: nil)
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
