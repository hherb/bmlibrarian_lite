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

struct FactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings
    @FocusState private var isTextEditorFocused: Bool

    /// Callback when a report is generated (navigates to Report tab).
    var onReportGenerated: ((EvidenceReport) -> Void)?

    /// Bindings to preserve state across tab switches (passed from parent).
    @Binding var claimText: String
    @Binding var workflow: FactCheckWorkflow?

    /// Search options for the current fact-check.
    @State private var searchOptions = AppSettings.shared.buildSearchOptions()

    @State private var showingError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Configuration warning
                    if !settings.isLLMConfigured {
                        ConfigurationWarningView()
                    }

                    // Input Section
                    ClaimInputSection(
                        claimText: $claimText,
                        isRunning: workflow?.isRunning ?? false,
                        canSubmit: canSubmit,
                        isTextEditorFocused: $isTextEditorFocused,
                        onSubmit: {
                            isTextEditorFocused = false
                            startFactCheck()
                        }
                    )

                    // Search Options
                    SearchOptionsView(
                        options: $searchOptions,
                        isDisabled: workflow?.isRunning ?? false
                    )

                    // Budget Display
                    BudgetDisplayView()

                    // Progress Section
                    if let workflow = workflow {
                        if workflow.isRunning {
                            ProgressSection(workflow: workflow)
                        }

                        if workflow.awaitingUserDecision {
                            UserDecisionSection(
                                prompt: workflow.userDecisionPrompt,
                                showSmartSearchOption: workflow.awaitingSmartSearchDecision,
                                onContinue: { Task { await workflow.continueWithMoreDocuments() } },
                                onSmartSearch: { Task { await workflow.continueWithSmartSearch() } },
                                onProceed: { Task { await workflow.proceedWithCurrentDocuments() } }
                            )
                        }

                        // Scored Documents Section
                        if let session = workflow.session,
                           !(session.documents ?? []).filter({ $0.isScored }).isEmpty {
                            ScoredDocumentsView(
                                session: session,
                                showEmbeddingScores: settings.embeddingScoringEnabled
                            )
                        }
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .onTapGesture {
                isTextEditorFocused = false
            }
            .navigationTitle("Medical Fact Check")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isTextEditorFocused = false
                    }
                }
            }
            .alert("Error", isPresented: $showingError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var canSubmit: Bool {
        let trimmed = claimText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && settings.isLLMConfigured && !(workflow?.isRunning ?? false)
    }

    // MARK: - Actions

    private func startFactCheck() {
        let newWorkflow = FactCheckWorkflow(modelContext: modelContext, settings: settings)

        // Set up callbacks
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
            await newWorkflow.startFactCheck(claim: claimText, searchOptions: searchOptions)
        }
    }
}

// MARK: - Subviews

struct ConfigurationWarningView: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text("Configure your LLM API in Settings to start fact-checking")
                .font(.subheadline)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
}

struct ClaimInputSection: View {
    @Binding var claimText: String
    let isRunning: Bool
    let canSubmit: Bool
    var isTextEditorFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter a medical claim or question")
                .font(.headline)

            TextEditor(text: $claimText)
                .frame(minHeight: 120)
                .padding(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3))
                )
                .focused(isTextEditorFocused)
                .disabled(isRunning)

            Text("Examples: \"Vitamin D reduces COVID-19 severity\" or \"Is aspirin effective for preventing heart attacks?\"")
                .font(.caption)
                .foregroundColor(.secondary)

            Button(action: onSubmit) {
                HStack {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(isRunning ? "Checking..." : "Check Evidence")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canSubmit ? Color.accentColor : Color.gray)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(!canSubmit)
        }
    }
}

struct BudgetDisplayView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var monthlyUsed: Double = 0

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Budget")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(CostCalculator.formatCost(monthlyUsed)) / \(CostCalculator.formatCost(settings.monthlyBudgetUSD)) monthly")
                    .font(.subheadline)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("Per run limit")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(CostCalculator.formatCost(settings.maxRunBudgetUSD))
                    .font(.subheadline)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
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

struct ProgressSection: View {
    let workflow: FactCheckWorkflow

    var body: some View {
        VStack(spacing: 16) {
            // Step indicators
            HStack(spacing: 8) {
                ForEach(mainSteps, id: \.self) { step in
                    StepIndicator(
                        step: step,
                        currentStep: workflow.session?.currentStep ?? .idle
                    )
                }
            }

            // Progress bar
            ProgressView(value: workflow.session?.progressPercent ?? 0, total: 100)
                .progressViewStyle(LinearProgressViewStyle())

            // Status message
            Text(workflow.progressMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Generated PubMed query (show once generated)
            if let query = workflow.session?.pubmedQuery, !query.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PubMed Query:")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    Text(query)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                }
            }

            // Cost so far (only show if non-zero)
            if let session = workflow.session, session.estimatedCostUSD > 0 {
                Text("Cost so far: \(CostCalculator.formatCost(session.estimatedCostUSD))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }

    private var mainSteps: [WorkflowStep] {
        [.convertingQuery, .searchingPubMed, .scoringDocuments, .extractingCitations, .generatingReport]
    }
}

struct StepIndicator: View {
    let step: WorkflowStep
    let currentStep: WorkflowStep

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Text(shortName)
                .font(.system(size: 8))
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

/// View displayed when user input is needed during workflow.
///
/// Shows appropriate action buttons based on workflow state:
/// - Smart Search option when initial search found few relevant results
/// - Fetch More option when more documents are available from current query
/// - Proceed option to continue with current results
struct UserDecisionSection: View {
    /// Message explaining the current situation to the user.
    let prompt: String

    /// Whether to show "Try Smart Search" as the primary action.
    ///
    /// When true, shows smart search button. When false, shows "Fetch More Documents".
    let showSmartSearchOption: Bool

    /// Called when user wants to fetch more documents from current query.
    let onContinue: () -> Void

    /// Called when user wants to try smart search with alternative queries.
    let onSmartSearch: (() -> Void)?

    /// Called when user wants to proceed with current results.
    let onProceed: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.orange)
                Text(prompt)
                    .font(.subheadline)
            }

            HStack(spacing: 12) {
                // Primary action: Smart Search or Fetch More
                if showSmartSearchOption {
                    Button {
                        onSmartSearch?()
                    } label: {
                        Label("Try Smart Search", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Try Smart Search")
                    .accessibilityHint("Generates alternative search queries to find more relevant documents")
                } else {
                    Button {
                        onContinue()
                    } label: {
                        Label("Fetch More Documents", systemImage: "arrow.down.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Fetch More Documents")
                    .accessibilityHint("Retrieves additional documents from the current search")
                }

                // Secondary action: Proceed with current
                Button {
                    onProceed()
                } label: {
                    Text("Proceed with Current")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Proceed with Current Results")
                .accessibilityHint("Continues to generate report with currently available documents")
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(10)
    }
}

#Preview {
    @Previewable @State var claimText = ""
    @Previewable @State var workflow: FactCheckWorkflow? = nil

    FactCheckView(
        onReportGenerated: nil,
        claimText: $claimText,
        workflow: $workflow
    )
    .modelContainer(for: [
        FactCheckSession.self,
        Document.self,
        Citation.self,
        EvidenceReport.self,
        UsageRecord.self,
    ], inMemory: true)
    .environment(AppSettings.shared)
}
