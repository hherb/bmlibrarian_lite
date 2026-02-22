#if os(macOS)
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

/// macOS fact-check view with two-column layout.
///
/// Left column: Claim input, controls, and progress.
/// Right column: Scored documents and results.
struct MacFactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSettings.self) private var settings

    /// Binding to the workflow (owned by parent to persist across tab switches).
    @Binding var workflow: FactCheckWorkflow?

    /// Binding to the claim text (owned by parent to persist across tab switches).
    @Binding var claimText: String

    /// When true, triggers `fetchMoreEvidence()` on the current workflow (set by Report view).
    @Binding var shouldFetchMoreEvidence: Bool

    /// Callback when a report is generated (navigates to Report view).
    var onReportGenerated: ((EvidenceReport) -> Void)?

    /// Callback when user wants to view full text (navigates to Full Text tab).
    var onShowFullText: ((Document) -> Void)?

    @State private var showingError = false
    @State private var errorMessage = ""

    // Search options state (initialized from settings)
    @State private var selectedSearchProvider: SearchProvider = .pubmed
    @State private var includePreprints: Bool = false

    // MARK: - Computed Properties

    /// The text to display on the submit button based on workflow state.
    private var buttonText: String {
        if workflow?.isRunning ?? false {
            return "Checking..."
        } else {
            return "Check Evidence"
        }
    }

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
        .onAppear {
            // Initialize search options from settings
            selectedSearchProvider = settings.selectedSearchProvider
            includePreprints = settings.includePreprints
        }
        .onChange(of: selectedSearchProvider) { _, newValue in
            // Reset preprints if provider doesn't support it
            if !newValue.supportsPreprints {
                includePreprints = false
            }
        }
        .onChange(of: workflow?.session?.searchProvider) { _, newProvider in
            // Sync search options from restored session
            if let providerRaw = newProvider,
               let provider = SearchProvider(rawValue: providerRaw),
               let session = workflow?.session {
                selectedSearchProvider = provider
                includePreprints = session.includePreprints
            }
        }
        .onChange(of: shouldFetchMoreEvidence) { _, newValue in
            guard newValue, let workflow = workflow else { return }
            shouldFetchMoreEvidence = false
            Task {
                await workflow.fetchMoreEvidence(searchOptions: buildSearchOptions())
            }
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

                // Claim input with search options
                MacClaimInputSection(
                    claimText: $claimText,
                    isRunning: workflow?.isRunning ?? false,
                    canSubmit: canSubmit,
                    buttonText: buttonText,
                    selectedSearchProvider: $selectedSearchProvider,
                    includePreprints: $includePreprints,
                    onSubmit: handleSubmit
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
                        showSmartSearchOption: workflow.awaitingSmartSearchDecision,
                        onContinue: { Task { await workflow.continueWithMoreDocuments() } },
                        onSmartSearch: { Task { await workflow.continueWithSmartSearch() } },
                        onProceed: { Task { await workflow.proceedWithCurrentDocuments() } }
                    )
                }

                // Retry Report Generation Section (shown when report generation fails)
                if let workflow = workflow, workflow.canRetryReportGeneration {
                    MacRetryReportSection(
                        errorMessage: workflow.session?.errorMessage,
                        isRetrying: workflow.isRunning,
                        onRetry: {
                            Task {
                                await workflow.retryReportGeneration()
                            }
                        }
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
                    let docs = session.documents ?? []
                    let scored = docs.filter { $0.isScored }.count
                    let total = docs.count
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
               !(session.documents ?? []).filter({ $0.isScored }).isEmpty {
                MacScoredDocumentsView(
                    session: session,
                    showEmbeddingScores: settings.embeddingScoringEnabled,
                    onShowFullText: onShowFullText
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

    /// Handles the submit button action — always starts a new fact-check.
    private func handleSubmit() {
        startFactCheck()
    }

    /// Builds search options from the current UI state.
    ///
    /// - Returns: A SearchOptions instance with the current provider and preprint settings.
    private func buildSearchOptions() -> SearchOptions {
        SearchOptions(
            provider: selectedSearchProvider,
            includePreprints: includePreprints,
            maxResults: settings.batchSize,
            offset: 0
        )
    }

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
            await newWorkflow.startFactCheck(claim: claimText, searchOptions: buildSearchOptions())
        }
    }
}

// MARK: - Subviews

/// Warning banner displayed when LLM is not configured.
///
/// The entire banner is tappable and opens the Settings window.
/// A chevron indicator shows the banner is interactive.
struct MacConfigurationWarningView: View {
    var body: some View {
        SettingsLink {
            HStack(spacing: MacSpacing.standard) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)

                VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                    Text("LLM Not Configured")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Click to configure your LLM API before fact-checking.")
                        .font(.body)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .padding(MacSpacing.large)
            .background(Color.orange.opacity(MacOpacity.subtle))
            .cornerRadius(MacCornerRadius.large)
        }
        .buttonStyle(.plain)
    }
}

/// Text input section for entering medical claims.
///
/// Includes a multiline text editor with example hints, search provider options,
/// and a submit button. The button text is configurable to support both new
/// fact-checks ("Check Evidence") and resumed sessions ("Add More Results").
struct MacClaimInputSection: View {
    /// The claim text binding.
    @Binding var claimText: String
    /// Whether a fact-check is currently running.
    let isRunning: Bool
    /// Whether the submit button should be enabled.
    let canSubmit: Bool
    /// The text to display on the submit button.
    ///
    /// Allows the parent view to customize the button text based on context
    /// (e.g., "Check Evidence" for new searches, "Add More Results" for resumed sessions).
    let buttonText: String
    /// The selected search provider binding.
    @Binding var selectedSearchProvider: SearchProvider
    /// Whether to include preprints binding.
    @Binding var includePreprints: Bool
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

            // Search options and submit button row
            HStack(spacing: MacSpacing.large) {
                // Search options
                MacSearchOptionsInline(
                    selectedProvider: $selectedSearchProvider,
                    includePreprints: $includePreprints
                )
                .disabled(isRunning)

                Spacer()

                // Submit and cancel buttons
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
                            Text(buttonText)
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
                        .textSelection(.enabled)
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
    /// Whether to show smart search option instead of fetch more.
    let showSmartSearchOption: Bool
    /// Callback when user chooses to continue fetching.
    let onContinue: () -> Void
    /// Callback when user chooses to try smart search.
    let onSmartSearch: (() -> Void)?
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
                if showSmartSearchOption {
                    Button("Try Smart Search") {
                        onSmartSearch?()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Fetch More Documents") {
                        onContinue()
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Proceed with Current") {
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

// MARK: - Retry Report Section

/// Section displayed when report generation fails and can be retried.
///
/// Shows the error message and provides a button to retry report generation.
/// The retry will skip all earlier workflow steps and directly attempt to
/// regenerate the report using existing scored documents and citations.
struct MacRetryReportSection: View {
    /// The error message from the failed report generation.
    let errorMessage: String?

    /// Whether report generation is currently being retried.
    let isRetrying: Bool

    /// Called when user clicks the retry button.
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: MacSpacing.large) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.red)

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Report Generation Failed")
                    .font(.headline)
                if let error = errorMessage {
                    Text(error)
                        .font(.body)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: onRetry) {
                HStack(spacing: MacSpacing.medium) {
                    if isRetrying {
                        ProgressView()
                            .scaleEffect(MacScale.progressViewMedium)
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? "Retrying..." : "Retry Report")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isRetrying)
        }
        .padding(MacSpacing.large)
        .background(Color.red.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
    }
}

// MARK: - Resumed Session Banner

/// Banner displayed when continuing a search from history.
///
/// Shows information about the resumed session including:
/// - Document count and scored count
/// - Indicator if more evidence is available
/// - "New Question" button to start fresh
///
/// Styled with a light blue background to distinguish from other UI elements.
struct MacResumedSessionBanner: View {
    /// The session being resumed.
    let session: FactCheckSession

    /// Called when user wants to start a new question instead.
    var onNewQuestion: (() -> Void)?

    var body: some View {
        HStack(spacing: MacSpacing.standard) {
            Image(systemName: "arrow.uturn.forward.circle.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text("Continuing previous search")
                    .font(.headline)

                let docCount = session.documents?.count ?? 0
                let scoredCount = session.documents?.filter { $0.isScored }.count ?? 0
                Text("\(docCount) documents found, \(scoredCount) scored")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // New Question button
            if let onNewQuestion {
                Button(action: onNewQuestion) {
                    Text("New Question")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            if session.canGetMoreEvidence {
                HStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "plus.circle")
                        .foregroundColor(.green)
                    Text("More available")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color.blue.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
    }
}

// MARK: - Get More Evidence Section

/// Section shown when more evidence can be fetched for a completed session.
///
/// Displays:
/// - "More Evidence Available" heading
/// - Estimated remaining results count
/// - Button to fetch more evidence
///
/// This section is shown for completed sessions that were NOT resumed from history.
/// For resumed sessions, the main "Add More Results" button handles fetching.
struct MacGetMoreEvidenceSection: View {
    /// The session to fetch more evidence for.
    let session: FactCheckSession

    /// Whether evidence is currently being fetched.
    let isFetching: Bool

    /// Called when user wants to fetch more evidence.
    let onFetchMore: () -> Void

    /// Description of what evidence sources are available.
    private var availableSourcesText: String {
        if session.canFetchMoreDocuments {
            let remaining = session.remainingPubMedResults
            if !session.smartSearchEnabled {
                return "\(remaining) more results available, plus smart search"
            } else {
                return "\(remaining) more results available"
            }
        } else if !session.smartSearchEnabled {
            return "Smart search available (alternative queries)"
        } else {
            return "All sources exhausted"
        }
    }

    var body: some View {
        HStack(spacing: MacSpacing.large) {
            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                HStack(spacing: MacSpacing.medium) {
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundColor(.accentColor)
                    Text("Need More Evidence?")
                        .font(.headline)
                }

                Text(availableSourcesText)
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: onFetchMore) {
                HStack(spacing: MacSpacing.medium) {
                    if isFetching {
                        ProgressView()
                            .scaleEffect(MacScale.progressViewMedium)
                            .progressViewStyle(CircularProgressViewStyle())
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(isFetching ? "Fetching..." : "Get More Evidence")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isFetching)
        }
        .padding(MacSpacing.large)
        .background(Color.green.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
    }
}

#Preview {
    @Previewable @State var previewWorkflow: FactCheckWorkflow? = nil
    @Previewable @State var previewClaimText: String = ""

    MacFactCheckView(
        workflow: $previewWorkflow,
        claimText: $previewClaimText,
        onReportGenerated: nil,
        onShowFullText: nil
    )
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

#endif // os(macOS)
