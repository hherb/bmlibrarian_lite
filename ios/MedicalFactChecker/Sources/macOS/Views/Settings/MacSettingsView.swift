#if os(macOS)
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
import CloudKit

/// macOS Settings view with tabbed interface.
///
/// Follows macOS Human Interface Guidelines:
/// - Tab-based organization for different setting categories
/// - Standard macOS controls (toggles, pickers, text fields)
/// - Appropriate spacing and sizing
struct MacSettingsView: View {
    var body: some View {
        TabView {
            LLMSettingsTab()
                .tabItem {
                    Label("LLM", systemImage: "brain")
                }

            SearchSettingsTab()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            BudgetSettingsTab()
                .tabItem {
                    Label("Budget", systemImage: "dollarsign.circle")
                }

            PubMedSettingsTab()
                .tabItem {
                    Label("PubMed", systemImage: "books.vertical")
                }

            SyncSettingsTab()
                .tabItem {
                    Label("Sync", systemImage: "icloud")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: MacLayout.settingsWindowWidth, height: MacLayout.settingsWindowHeight)
    }
}

// MARK: - LLM Settings Tab

struct LLMSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.openURL) private var openURL

    @State private var apiKey = ""
    @State private var showingAPIKey = false
    @State private var availableModels: [LLMModel] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?
    @State private var showingSaveConfirmation = false
    @State private var isTestingAPI = false
    @State private var apiTestResult: APITestResult?

    /// Result of an API connection test.
    private enum APITestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            // Provider selection
            Section {
                Picker("Provider", selection: $settings.selectedProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                Text(settings.selectedProvider.providerDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Model selection
            Section {
                if isLoadingModels {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Loading models...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    let modelBinding = Binding<String>(
                        get: {
                            if displayModels.contains(where: { $0.id == settings.llmModel }) {
                                return settings.llmModel
                            }
                            return displayModels.first { $0.isRecommended }?.id
                                ?? displayModels.first?.id
                                ?? settings.llmModel
                        },
                        set: { settings.llmModel = $0 }
                    )

                    Picker("Model", selection: modelBinding) {
                        ForEach(displayModels) { model in
                            HStack {
                                Text(model.displayName)
                                if model.isRecommended {
                                    Text("Recommended")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, MacSpacing.small)
                                        .padding(.vertical, MacSpacing.xxSmall)
                                        .background(Color.blue)
                                        .cornerRadius(MacCornerRadius.small)
                                }
                            }
                            .tag(model.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if let selectedModel = displayModels.first(where: { $0.id == settings.llmModel }) {
                        Text(selectedModel.priceDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if settings.selectedProvider.supportsDynamicModelFetching && !apiKey.isEmpty {
                        Button("Refresh Models") {
                            Task { await loadModels() }
                        }
                    }
                }

                if settings.selectedProvider == .ollama {
                    TextField("Custom model name", text: $settings.llmModel)
                }
            }

            // API Key
            Section {
                if settings.selectedProvider.requiresAPIKey {
                    HStack {
                        if showingAPIKey {
                            TextField("API Key", text: $apiKey)
                        } else {
                            SecureField("API Key", text: $apiKey)
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

                        Button {
                            Task { await testAPIConnection() }
                        } label: {
                            if isTestingAPI {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(apiKey.isEmpty || isTestingAPI)

                        if let url = settings.selectedProvider.apiKeyURL {
                            Button("Get API Key") {
                                openURL(url)
                            }
                        }

                        // Help button for API key documentation
                        Button {
                            if let helpURL = URL(string: "https://bmlibrarian.org/user-manual/api-keys/") {
                                openURL(helpURL)
                            }
                        } label: {
                            Image(systemName: "questionmark.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Learn more about API keys")
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
                                Text("Error: \(error)")
                                    .foregroundColor(.red)
                                    .lineLimit(2)
                            }
                        }
                        .font(.caption)
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("No API key required for \(settings.selectedProvider.displayName)")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Advanced settings
            Section("Advanced") {
                TextField("Base URL", text: $settings.llmBaseURL)
                    .textFieldStyle(.roundedBorder)

                if settings.selectedProvider == .custom {
                    TextField("Model Name", text: $settings.llmModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Embedding scoring
            Section("Scoring") {
                Toggle("Enable Embedding Scoring", isOn: $settings.embeddingScoringEnabled)

                if settings.embeddingScoringEnabled {
                    HStack {
                        Image(systemName: EmbeddingService.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(EmbeddingService.isAvailable ? .green : .red)
                        Text(EmbeddingService.isAvailable ? "Apple NLEmbedding available" : "Embeddings unavailable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKey = settings.llmAPIKey
            Task { await loadModels() }
        }
        .onChange(of: settings.selectedProvider) { _, newProvider in
            // Load API key for the new provider
            apiKey = settings.apiKey(for: newProvider)
            // Clear test result when provider changes
            apiTestResult = nil
            // Clear models and reload
            availableModels = []
            modelLoadError = nil
            Task { await loadModels() }
        }
        .alert("Saved", isPresented: $showingSaveConfirmation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("API key saved securely to Keychain")
        }
    }

    private var displayModels: [LLMModel] {
        availableModels.isEmpty ? settings.selectedProvider.fallbackModels : availableModels
    }

    private func loadModels() async {
        guard settings.selectedProvider.supportsDynamicModelFetching else {
            availableModels = []
            return
        }

        isLoadingModels = true
        modelLoadError = nil

        let models = await ModelFetchService.shared.fetchModels(
            for: settings.selectedProvider,
            apiKey: apiKey.isEmpty ? nil : apiKey,
            baseURL: settings.llmBaseURL
        )

        await MainActor.run {
            if models.isEmpty {
                availableModels = settings.selectedProvider.fallbackModels
                modelLoadError = "Using fallback models"
            } else {
                availableModels = models
            }
            isLoadingModels = false
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
                model: settings.llmModel
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
}

// MARK: - Search Settings Tab

struct SearchSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            // Search Provider Section
            Section("Default Search Provider") {
                Picker("Provider", selection: $settings.selectedSearchProvider) {
                    ForEach(SearchProvider.allCases) { provider in
                        HStack {
                            Image(systemName: provider.iconName)
                                .foregroundColor(MacProviderColors.color(for: provider))
                                .frame(width: MacIconSize.iconFrame)
                            VStack(alignment: .leading) {
                                Text(provider.displayName)
                                Text(provider.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                Toggle("Include Preprints by Default", isOn: $settings.includePreprints)
                    .disabled(!settings.selectedSearchProvider.supportsPreprints)

                if !settings.selectedSearchProvider.supportsPreprints {
                    Text("Preprints are only available when using Europe PMC or Both providers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Provider Information Section
            Section("Provider Information") {
                providerInfoView
            }

            Section("Document Retrieval") {
                Stepper(value: $settings.batchSize, in: 5...50, step: 5) {
                    HStack {
                        Text("Batch Size")
                        Spacer()
                        Text("\(settings.batchSize)")
                            .foregroundColor(.secondary)
                    }
                }

                Stepper(value: $settings.minRelevantDocuments, in: 1...20) {
                    HStack {
                        Text("Min Relevant Documents")
                        Spacer()
                        Text("\(settings.minRelevantDocuments)")
                            .foregroundColor(.secondary)
                    }
                }

                Text("The app will prompt you to fetch more documents if fewer than this number are found to be relevant.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Relevance Threshold") {
                Picker("Minimum Score", selection: $settings.minScoreThreshold) {
                    ForEach(1...5, id: \.self) { score in
                        Text("\(score) - \(scoreLabel(score))").tag(score)
                    }
                }
                .pickerStyle(.menu)

                Text("Documents below this score are considered not relevant for citation extraction.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// View displaying information about each search provider.
    private var providerInfoView: some View {
        VStack(alignment: .leading, spacing: MacSpacing.medium) {
            providerInfoRow(
                icon: SearchProvider.pubmed.iconName,
                color: MacProviderColors.pubmed,
                name: "PubMed",
                description: "NCBI's primary biomedical literature database. Uses MeSH indexing and provides the most reliable PMID identifiers."
            )

            Divider()

            providerInfoRow(
                icon: SearchProvider.europePMC.iconName,
                color: MacProviderColors.europePMC,
                name: "Europe PMC",
                description: "European mirror with access to preprints from 34 servers including bioRxiv and medRxiv. Also provides full-text XML for many articles."
            )

            Divider()

            providerInfoRow(
                icon: SearchProvider.both.iconName,
                color: MacProviderColors.both,
                name: "Both (Merged)",
                description: "Search both providers simultaneously. Results are merged with duplicates removed based on PMID, DOI, and title similarity."
            )
        }
        .padding(.vertical, MacSpacing.small)
    }

    /// Row displaying information about a single provider.
    ///
    /// - Parameters:
    ///   - icon: SF Symbol name for the provider.
    ///   - color: Color for the icon.
    ///   - name: Provider display name.
    ///   - description: Provider description.
    /// - Returns: A view displaying the provider information.
    private func providerInfoRow(
        icon: String,
        color: Color,
        name: String,
        description: String
    ) -> some View {
        HStack(alignment: .top, spacing: MacSpacing.medium) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: MacIconSize.listNumberWidth)
            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                Text(name)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
}

// MARK: - Budget Settings Tab

struct BudgetSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext

    @State private var monthlyUsage: Double = 0

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Spending Limits") {
                HStack {
                    Text("Per-Run Limit")
                    Spacer()
                    TextField("USD", value: $settings.maxRunBudgetUSD, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: MacLayout.currencyFieldWidth)
                }

                HStack {
                    Text("Monthly Limit")
                    Spacer()
                    TextField("USD", value: $settings.monthlyBudgetUSD, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: MacLayout.currencyFieldWidth)
                }

                Text("The app will stop when these limits are reached.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Current Usage") {
                HStack {
                    Text("Monthly Usage")
                    Spacer()
                    Text(CostCalculator.formatCost(monthlyUsage))
                        .foregroundColor(.secondary)
                }

                ProgressView(value: min(monthlyUsage / settings.monthlyBudgetUSD, 1.0))
                    .progressViewStyle(.linear)

                if monthlyUsage > 0 {
                    Button("Reset Monthly Usage", role: .destructive) {
                        resetMonthlyUsage()
                    }
                }
            }

            Section("Model Pricing") {
                VStack(alignment: .leading, spacing: MacSpacing.medium) {
                    Text("Prices are per 1 million tokens.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("A typical fact-check uses 5,000-20,000 tokens, costing approximately $0.01-$0.05 with Claude Sonnet.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: loadMonthlyUsage)
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
}

// MARK: - PubMed Settings Tab

struct PubMedSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var ncbiAPIKey = ""
    @State private var showingSaveConfirmation = false

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("NCBI Identification") {
                TextField("Email Address", text: $settings.ncbiEmail)
                    .textFieldStyle(.roundedBorder)

                Text("NCBI recommends providing an email for API usage. This helps them contact you if there are issues.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("API Key (Optional)") {
                SecureField("NCBI API Key", text: $ncbiAPIKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save API Key") {
                        settings.ncbiAPIKey = ncbiAPIKey
                        showingSaveConfirmation = true
                    }
                    .disabled(ncbiAPIKey.isEmpty)

                    Button("Get API Key") {
                        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/account/settings/") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Text("An API key increases rate limits from 3 to 10 requests per second.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            ncbiAPIKey = settings.ncbiAPIKey
        }
        .alert("Saved", isPresented: $showingSaveConfirmation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("NCBI API key saved securely to Keychain")
        }
    }
}

// MARK: - Sync Settings Tab

struct SyncSettingsTab: View {
    @State private var isSyncEnabled = CloudKitConfiguration.isSyncEnabled
    @State private var cloudStatus: CKAccountStatus = .couldNotDetermine
    @State private var showingRestartAlert = false

    var body: some View {
        Form {
            Section("iCloud Sync") {
                Toggle("Enable iCloud Sync", isOn: $isSyncEnabled)
                    .onChange(of: isSyncEnabled) { _, newValue in
                        CloudKitConfiguration.requestSyncChange(enabled: newValue)
                        showingRestartAlert = true
                    }

                Text("Sync your fact-check sessions, documents, and reports across all your devices signed into the same iCloud account.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if CloudKitConfiguration.pendingConfigChange {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Restart required to apply changes")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Section("iCloud Status") {
                HStack {
                    Image(systemName: cloudStatusIcon)
                        .foregroundColor(cloudStatusColor)
                    Text(cloudStatusText)
                        .foregroundColor(.secondary)
                }

                if !CloudKitConfiguration.isCloudAvailable {
                    Text("Sign in to iCloud in System Settings to enable sync.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Privacy") {
                VStack(alignment: .leading, spacing: MacSpacing.small) {
                    Label("Data stays local by default", systemImage: "lock.shield")
                    Label("Only syncs when you enable it", systemImage: "hand.raised")
                    Label("Your API keys are never synced", systemImage: "key")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
            return "iCloud is temporarily unavailable"
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

// MARK: - About Tab

struct AboutTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @State private var showingDeleteAllConfirmation = false

    var body: some View {
        VStack(spacing: MacSpacing.sectionSpacing) {
            // App icon and name
            VStack(spacing: MacSpacing.medium) {
                Image(systemName: "cross.case.circle.fill")
                    .font(.system(size: MacIconSize.aboutIcon))
                    .foregroundColor(.accentColor)

                Text("Medical Fact Checker")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(Bundle.main.appVersionString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(width: MacLayout.searchFieldWidth)

            // Description
            Text("AI-powered medical claim verification using PubMed literature and large language models.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            // Links and onboarding
            VStack(spacing: MacSpacing.medium) {
                Button {
                    NotificationCenter.default.post(name: .showMacOnboarding, object: nil)
                } label: {
                    HStack {
                        Image(systemName: "hands.sparkles")
                        Text("View Onboarding Guide")
                    }
                }

                Link(destination: URL(string: "https://github.com/hherb/bmlibrarian_lite")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("GitHub Repository")
                    }
                }

                Link(destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/")!) {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text("PubMed")
                    }
                }
            }

            Spacer()

            // Reset and delete buttons
            VStack(spacing: MacSpacing.medium) {
                Button("Reset All Settings", role: .destructive) {
                    settings.resetToDefaults()
                }

                Button("Clear All Report Data", role: .destructive) {
                    showingDeleteAllConfirmation = true
                }
            }
            .padding(.bottom)
        }
        .padding(MacSpacing.section)
        .alert("Delete All Reports?", isPresented: $showingDeleteAllConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete All", role: .destructive) {
                deleteAllReportData()
            }
        } message: {
            Text("This will permanently delete all fact-check sessions, documents, and reports. This action cannot be undone.")
        }
    }

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
}

#Preview {
    MacSettingsView()
        .environment(AppSettings.shared)
        .modelContainer(for: [UsageRecord.self, FactCheckSession.self], inMemory: true)
}

#endif // os(macOS)
