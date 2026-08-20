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
import CloudKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var apiKey = ""
    @State private var showingAPIKey = false
    @State private var ncbiAPIKey = ""
    @State private var showingSaveConfirmation = false
    @State private var monthlyUsage: Double = 0
    @State private var showingCustomConfig = false

    // Dynamic model loading state
    @State private var availableModels: [LLMModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    // API testing state
    @State private var isTestingAPI = false
    @State private var apiTestResult: APITestResult?

    // iCloud sync state
    @State private var isSyncEnabled = CloudKitConfiguration.isSyncEnabled
    @State private var cloudStatus: CKAccountStatus = .couldNotDetermine
    @State private var showingRestartAlert = false

    // Data deletion state
    @State private var showingDeleteAllConfirmation = false

    /// Result of an API connection test.
    private enum APITestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                // LLM Provider Selection
                Section {
                    Picker("Provider", selection: $settings.selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }

                    Text(settings.selectedProvider.providerDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("LLM Provider")
                } footer: {
                    if settings.selectedProvider == .anthropic {
                        Text("Recommended: Tested and works well with this app.")
                    }
                }

                // Model Selection (for non-custom providers)
                if settings.selectedProvider != .custom {
                    Section {
                        if isLoadingModels {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading models...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else if displayModels.isEmpty {
                            Text("Enter model name manually below")
                                .foregroundColor(.secondary)
                        } else {
                            // Bind to the stored value directly. Resolving here would show
                            // a model the app is not going to send; `pickerModels` lists
                            // the stored ID instead so the two cannot disagree.
                            let modelBinding = Binding<String>(
                                get: { settings.llmModel },
                                set: { newValue in
                                    settings.llmModel = newValue
                                }
                            )

                            Picker("Model", selection: modelBinding) {
                                ForEach(pickerModels) { model in
                                    VStack(alignment: .leading) {
                                        HStack {
                                            Text(model.displayName)
                                            if model.isRecommended {
                                                Text("Recommended")
                                                    .font(.caption2)
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.blue)
                                                    .cornerRadius(4)
                                            }
                                        }
                                    }
                                    .tag(model.id)
                                }
                            }

                            if let selectedModel = pickerModels.first(where: { $0.id == settings.llmModel }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selectedModel.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(selectedModel.priceDescription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Show error if dynamic fetch failed
                            if let error = modelLoadError {
                                HStack {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                    Text("Showing the built-in model list: \(error)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            // Refresh button
                            if settings.selectedProvider.supportsDynamicModelFetching && !apiKey.isEmpty {
                                Button {
                                    Task { await loadModels() }
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Refresh Models")
                                    }
                                    .font(.caption)
                                }
                            }
                        }

                        // Let the user name a model the provider does not list
                        if settings.selectedProvider.allowsManualModelEntry {
                            TextField("Or enter model name", text: $settings.llmModel)
                                .autocapitalization(.none)
                        }
                    } header: {
                        Text("Model")
                    }
                }

                // API Key Section
                Section {
                    if settings.selectedProvider.requiresAPIKey {
                        HStack {
                            if showingAPIKey {
                                TextField("API Key", text: $apiKey)
                                    .textContentType(.password)
                            } else {
                                SecureField("API Key", text: $apiKey)
                                    .textContentType(.password)
                            }

                            Button(action: { showingAPIKey.toggle() }) {
                                Image(systemName: showingAPIKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                        }

                        HStack {
                            Button("Save API Key") {
                                settings.llmAPIKey = apiKey
                                showingSaveConfirmation = true
                            }
                            .disabled(apiKey.isEmpty)

                            Spacer()

                            Button {
                                Task { await testAPIConnection() }
                            } label: {
                                if isTestingAPI {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Text("Test")
                                }
                            }
                            .disabled(apiKey.isEmpty || isTestingAPI)
                        }

                        // Show test result
                        if let result = apiTestResult {
                            HStack {
                                switch result {
                                case .success(let message):
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Success: \(message)")
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                case .failure(let error):
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                    Text(error)
                                        .foregroundColor(.red)
                                        .lineLimit(2)
                                }
                            }
                            .font(.caption)
                        }

                        if let apiKeyURL = settings.selectedProvider.apiKeyURL {
                            HStack {
                                Button {
                                    openURL(apiKeyURL)
                                } label: {
                                    HStack {
                                        Text("Get API Key")
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                    }
                                }

                                Button {
                                    if let helpURL = URL(string: "https://bmlibrarian.org/user-manual/api-keys/") {
                                        openURL(helpURL)
                                    }
                                } label: {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Learn more about API keys")
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("No API key required")
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    if settings.selectedProvider == .ollama {
                        Text("Make sure Ollama is running on your Mac at the configured URL.")
                    }
                }

                // Custom/Advanced Configuration
                Section {
                    DisclosureGroup("Advanced Configuration", isExpanded: $showingCustomConfig) {
                        TextField("Base URL", text: $settings.llmBaseURL)
                            .textContentType(.URL)
                            .autocapitalization(.none)
                            .keyboardType(.URL)

                        if settings.selectedProvider == .custom {
                            TextField("Model Name", text: $settings.llmModel)
                                .autocapitalization(.none)
                        }
                    }
                } footer: {
                    if settings.selectedProvider != .custom {
                        Text("Only modify if you need a custom endpoint.")
                    }
                }

                // Search Provider Settings
                Section {
                    Picker("Default Provider", selection: $settings.selectedSearchProvider) {
                        ForEach(SearchProvider.allCases) { provider in
                            HStack {
                                Image(systemName: provider.iconName)
                                Text(provider.displayName)
                            }
                            .tag(provider)
                        }
                    }

                    Text(settings.selectedSearchProvider.description)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Include Preprints", isOn: $settings.includePreprints)

                    if settings.includePreprints {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Preprints are not peer-reviewed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Literature Search")
                } footer: {
                    Text("Choose which database(s) to search. Europe PMC includes additional European sources and preprints.")
                }

                // Search Settings
                Section {
                    Stepper(
                        "Batch Size: \(settings.batchSize)",
                        value: $settings.batchSize,
                        in: 5...50,
                        step: 5
                    )

                    Stepper(
                        "Min Relevant Docs: \(settings.minRelevantDocuments)",
                        value: $settings.minRelevantDocuments,
                        in: 1...20
                    )

                    Picker("Min Score Threshold", selection: $settings.minScoreThreshold) {
                        ForEach(1...5, id: \.self) { score in
                            Text("\(score) - \(scoreLabel(score))").tag(score)
                        }
                    }
                } header: {
                    Text("Search Parameters")
                } footer: {
                    Text("Control how many documents to fetch per batch and the minimum relevance threshold.")
                }

                // Scoring Settings
                Section {
                    Toggle("Enable Embedding Scoring", isOn: $settings.embeddingScoringEnabled)

                    if settings.embeddingScoringEnabled {
                        HStack {
                            Image(systemName: EmbeddingService.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(EmbeddingService.isAvailable ? .green : .red)
                            Text(EmbeddingService.isAvailable ? "Embeddings available" : "Embeddings unavailable")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Scoring Methods")
                } footer: {
                    Text("When enabled, documents are scored using both LLM and on-device semantic similarity. This allows comparing the two methods without API cost for embedding scores.")
                }

                // Budget Settings
                Section {
                    HStack {
                        Text("Per-Run Limit")
                        Spacer()
                        TextField("USD", value: $settings.maxRunBudgetUSD, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Monthly Limit")
                        Spacer()
                        TextField("USD", value: $settings.monthlyBudgetUSD, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }

                    HStack {
                        Text("Monthly Usage")
                        Spacer()
                        Text(CostCalculator.formatCost(monthlyUsage))
                            .foregroundColor(.secondary)
                    }

                    if monthlyUsage > 0 {
                        Button("Reset Monthly Usage", role: .destructive) {
                            resetMonthlyUsage()
                        }
                    }
                } header: {
                    Text("Budget Limits")
                } footer: {
                    Text("Set spending limits to avoid unexpected costs. The app will stop when limits are reached.")
                }

                // PubMed Configuration (Optional)
                Section {
                    TextField("Email (recommended)", text: $settings.ncbiEmail)
                        .textContentType(.emailAddress)
                        .autocapitalization(.none)
                        .keyboardType(.emailAddress)

                    SecureField("API Key (optional)", text: $ncbiAPIKey)
                        .textContentType(.password)

                    if !ncbiAPIKey.isEmpty {
                        Button("Save NCBI API Key") {
                            settings.ncbiAPIKey = ncbiAPIKey
                            showingSaveConfirmation = true
                        }
                    }
                } header: {
                    Text("PubMed API (Optional)")
                } footer: {
                    Text("Providing an email helps NCBI contact you if there are issues. An API key increases rate limits.")
                }

                // Model Pricing Info
                Section {
                    NavigationLink("View Model Pricing") {
                        ModelPricingView()
                    }
                } header: {
                    Text("Cost Information")
                }

                // Help & Documentation
                Section {
                    Button {
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    } label: {
                        Label("View Onboarding Guide", systemImage: "hands.sparkles")
                    }

                    NavigationLink {
                        HelpView()
                    } label: {
                        Label("Help & Documentation", systemImage: "questionmark.circle")
                    }

                    NavigationLink {
                        PrivacyView()
                    } label: {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                } header: {
                    Text("Information")
                }

                // iCloud Sync
                Section {
                    iCloudSyncSection
                } header: {
                    Text("iCloud Sync")
                } footer: {
                    Text("Sync your fact-check sessions across all your devices signed into the same iCloud account.")
                }

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.appVersionString)
                            .foregroundColor(.secondary)
                    }

                    Button("Reset All Settings", role: .destructive) {
                        settings.resetToDefaults()
                        apiKey = ""
                        ncbiAPIKey = ""
                        showingCustomConfig = false
                    }

                    Button("Clear All Report Data", role: .destructive) {
                        showingDeleteAllConfirmation = true
                    }
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .alert("Saved", isPresented: $showingSaveConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("API key saved securely to Keychain")
            }
            .alert("Delete All Reports?", isPresented: $showingDeleteAllConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete All", role: .destructive) {
                    deleteAllReportData()
                }
            } message: {
                Text("This will permanently delete all fact-check sessions, documents, and reports. This action cannot be undone.")
            }
            .onAppear {
                loadCurrentValues()
            }
            .onChange(of: settings.selectedProvider) { _, newProvider in
                // Load API key for the new provider
                apiKey = settings.apiKey(for: newProvider)
                // Clear test result when provider changes
                apiTestResult = nil
                // Clear cached models and reload
                availableModels = []
                modelLoadError = nil
                Task { await loadModels() }
            }
        }
    }

    // MARK: - Computed Properties

    /// Models to display in the picker.
    ///
    /// Returns dynamically fetched models if available, otherwise falls back to provider defaults.
    private var displayModels: [LLMModel] {
        availableModels.isEmpty ? settings.selectedProvider.fallbackModels : availableModels
    }

    /// Models offered in the picker, including the stored selection when it is missing.
    ///
    /// Healing only runs after a successful fetch, so a stored ID can outlive the list
    /// being shown - after a failed fetch, or before an API key is entered. Listing it
    /// keeps the picker showing the model the app will actually send.
    private var pickerModels: [LLMModel] {
        guard !settings.llmModel.isEmpty,
              !displayModels.contains(where: { $0.id == settings.llmModel })
        else { return displayModels }

        let stored = LLMModel.notListed(
            id: settings.llmModel,
            provider: settings.selectedProvider
        )
        return [stored] + displayModels
    }

    // MARK: - Helpers

    /// Delete all fact-check sessions and their associated data.
    ///
    /// This removes all FactCheckSession objects from SwiftData,
    /// which cascades to delete all Documents, Citations, and EvidenceReports.
    private func deleteAllReportData() {
        let descriptor = FetchDescriptor<FactCheckSession>()
        if let sessions = try? modelContext.fetch(descriptor) {
            for session in sessions {
                modelContext.delete(session)
            }
            try? modelContext.save()
        }
    }

    private func loadCurrentValues() {
        apiKey = settings.llmAPIKey
        ncbiAPIKey = settings.ncbiAPIKey
        loadMonthlyUsage()
        // Auto-expand custom config for custom provider
        showingCustomConfig = settings.selectedProvider == .custom
        // Load models for current provider
        Task { await loadModels() }
    }

    /// Load available models for the current provider.
    private func loadModels() async {
        let provider = settings.selectedProvider
        guard provider.supportsDynamicModelFetching else {
            availableModels = []
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        do {
            let models = try await ModelFetchService.shared.fetchModels(
                for: provider,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                baseURL: settings.llmBaseURL
            )

            await MainActor.run {
                if models.isEmpty {
                    availableModels = provider.fallbackModels
                    modelLoadError = "Provider returned no usable models"
                } else {
                    availableModels = models
                    modelLoadError = nil
                    // A hosted provider's live list is authoritative: drop a stored
                    // model it no longer offers, so the app stops sending a dead ID.
                    if !provider.allowsManualModelEntry {
                        settings.llmModel = LLMModel.resolveSelection(
                            current: settings.llmModel,
                            available: models
                        )
                    }
                }
                isLoadingModels = false
            }
        } catch {
            await MainActor.run {
                availableModels = provider.fallbackModels
                modelLoadError = error.localizedDescription
                isLoadingModels = false
            }
        }
    }

    /// Test the API connection with the current settings.
    private func testAPIConnection() async {
        guard let url = URL(string: settings.llmBaseURL) else {
            await MainActor.run {
                apiTestResult = .failure("Invalid base URL")
            }
            return
        }

        await MainActor.run {
            isTestingAPI = true
            apiTestResult = nil
        }

        do {
            let response = try await LLMService.testConnection(
                baseURL: url,
                apiKey: apiKey,
                model: settings.llmModel,
                provider: settings.selectedProvider
            )
            await MainActor.run {
                isTestingAPI = false
                apiTestResult = .success(response.prefix(50).trimmingCharacters(in: .whitespacesAndNewlines))
                // Save the API key on successful test
                settings.llmAPIKey = apiKey
            }
            // Clear cache and refresh models on success
            await ModelFetchService.shared.clearCache(for: settings.selectedProvider)
            await loadModels()
        } catch {
            await MainActor.run {
                isTestingAPI = false
                apiTestResult = .failure(error.localizedDescription)
            }
        }
    }

    private func loadMonthlyUsage() {
        let monthKey = UsageRecord.currentMonthKey
        let descriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate { $0.monthKey == monthKey }
        )

        if let records = try? modelContext.fetch(descriptor) {
            monthlyUsage = records.reduce(0) { $0 + $1.costUSD }
        }
    }

    private func resetMonthlyUsage() {
        let monthKey = UsageRecord.currentMonthKey
        let descriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate { $0.monthKey == monthKey }
        )

        if let records = try? modelContext.fetch(descriptor) {
            for record in records {
                modelContext.delete(record)
            }
            try? modelContext.save()
            monthlyUsage = 0
        }
    }

    private func scoreLabel(_ score: Int) -> String {
        switch score {
        case 1: return "Any"
        case 2: return "Low"
        case 3: return "Moderate"
        case 4: return "High"
        case 5: return "Very High"
        default: return ""
        }
    }

    // MARK: - iCloud Sync Section

    private var iCloudSyncSection: some View {
        Group {
            Toggle("Enable iCloud Sync", isOn: $isSyncEnabled)
                .onChange(of: isSyncEnabled) { _, newValue in
                    CloudKitConfiguration.requestSyncChange(enabled: newValue)
                    showingRestartAlert = true
                }

            HStack {
                Image(systemName: cloudStatusIcon)
                    .foregroundColor(cloudStatusColor)
                Text(cloudStatusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if CloudKitConfiguration.pendingConfigChange {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Restart app to apply changes")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Data stays local by default", systemImage: "lock.shield")
                Label("API keys are never synced", systemImage: "key")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
        }
        .onAppear {
            isSyncEnabled = CloudKitConfiguration.isSyncEnabled
            Task { await checkCloudStatus() }
        }
        .alert("Restart Required", isPresented: $showingRestartAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please restart the app to apply the sync setting change.")
        }
    }

    private var cloudStatusIcon: String {
        switch cloudStatus {
        case .available:
            return "checkmark.icloud.fill"
        case .noAccount:
            return "xmark.icloud"
        case .restricted:
            return "lock.icloud"
        case .temporarilyUnavailable:
            return "exclamationmark.icloud"
        case .couldNotDetermine:
            return "questionmark.circle"
        @unknown default:
            return "questionmark.circle"
        }
    }

    private var cloudStatusColor: Color {
        switch cloudStatus {
        case .available:
            return .green
        case .noAccount, .restricted:
            return .red
        case .temporarilyUnavailable:
            return .orange
        case .couldNotDetermine:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var cloudStatusText: String {
        switch cloudStatus {
        case .available:
            return "iCloud is available"
        case .noAccount:
            return "Not signed in to iCloud"
        case .restricted:
            return "iCloud access is restricted"
        case .temporarilyUnavailable:
            return "iCloud temporarily unavailable"
        case .couldNotDetermine:
            return "Checking iCloud status..."
        @unknown default:
            return "Unknown iCloud status"
        }
    }

    private func checkCloudStatus() async {
        let status = await CloudKitConfiguration.checkAccountStatus()
        await MainActor.run {
            cloudStatus = status
        }
    }
}

// MARK: - Model Pricing View

struct ModelPricingView: View {
    /// Model pricing shown to the user, per 1M tokens.
///
/// Rows are dated individually rather than as a table: a single "last updated"
/// stamp goes stale the moment one provider changes its rates, which is how this
/// screen came to advertise January 2026 alongside August 2026 DeepSeek prices.
    private let modelGroups: [(provider: String, models: [(name: String, input: Double, output: Double)])] = [
        ("Anthropic (Claude)", [
            ("Claude Sonnet 4.5", 3.00, 15.00),
            ("Claude Haiku 4.5", 1.00, 5.00),
            ("Claude Opus 4.5", 5.00, 25.00),
        ]),
        ("OpenAI", [
            ("GPT-5.2", 2.00, 8.00),
            ("o4-mini", 1.10, 4.40),
            ("GPT-4o Mini", 0.15, 0.60),
        ]),
        ("DeepSeek", [
            ("DeepSeek V4 Flash", 0.44, 1.32),
            ("DeepSeek V4 Pro", 1.32, 3.96),
        ]),
        ("Groq", [
            ("Llama 4 Maverick", 0.50, 0.77),
            ("Llama 4 Scout", 0.11, 0.34),
            ("Llama 3.1 8B", 0.05, 0.08),
        ]),
        ("Mistral", [
            ("Mistral Large 3", 0.50, 1.50),
            ("Mistral Small", 0.10, 0.30),
        ]),
    ]

    var body: some View {
        List {
            Section {
                Text("Prices are per 1 million tokens. A typical fact-check uses 5,000-20,000 tokens.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(modelGroups, id: \.provider) { group in
                Section(group.provider) {
                    ForEach(group.models, id: \.name) { model in
                        HStack {
                            Text(model.name)
                                .font(.body)
                            Spacer()
                            VStack(alignment: .trailing) {
                                Text("$\(model.input, specifier: "%.2f") in")
                                    .font(.caption)
                                Text("$\(model.output, specifier: "%.2f") out")
                                    .font(.caption)
                            }
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("Estimated cost per fact-check:")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 8) {
                    CostEstimateRow(model: "Claude Sonnet 4.5", cost: "$0.01 - $0.03")
                    CostEstimateRow(model: "GPT-4o Mini", cost: "$0.001 - $0.003")
                    CostEstimateRow(model: "DeepSeek V4 Flash", cost: "$0.003 - $0.012")
                    CostEstimateRow(model: "Llama 4 Scout (Groq)", cost: "$0.001 - $0.003")
                }
            } header: {
                Text("Cost Estimates")
            } footer: {
                Text("Indicative rates per 1M tokens; DeepSeek is quoted at peak-hour, cache-miss rates. Providers change pricing without notice - check their websites before relying on these figures.")
                    .font(.caption2)
            }
        }
        .navigationTitle("Model Pricing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CostEstimateRow: View {
    let model: String
    let cost: String

    var body: some View {
        HStack {
            Text(model)
                .font(.caption)
            Spacer()
            Text(cost)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsView()
        .modelContainer(for: [UsageRecord.self], inMemory: true)
        .environment(AppSettings.shared)
}

#endif // os(iOS)
