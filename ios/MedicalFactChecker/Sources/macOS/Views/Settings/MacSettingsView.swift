//
//  MacSettingsView.swift
//  MedicalFactChecker
//
//  macOS Settings window with tabbed interface following Apple HIG.
//

import SwiftUI
import SwiftData

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

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 550, height: 450)
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
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue)
                                        .cornerRadius(4)
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

                        if let url = settings.selectedProvider.apiKeyURL {
                            Button("Get API Key") {
                                openURL(url)
                            }
                        }
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
        .onChange(of: settings.selectedProvider) { _, _ in
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
}

// MARK: - Search Settings Tab

struct SearchSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
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
                        .frame(width: 100)
                }

                HStack {
                    Text("Monthly Limit")
                    Spacer()
                    TextField("USD", value: $settings.monthlyBudgetUSD, format: .currency(code: "USD"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
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
                VStack(alignment: .leading, spacing: 8) {
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

// MARK: - About Tab

struct AboutTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(spacing: 24) {
            // App icon and name
            VStack(spacing: 8) {
                Image(systemName: "cross.case.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.accentColor)

                Text("Medical Fact Checker")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version 1.0.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()
                .frame(width: 200)

            // Description
            Text("AI-powered medical claim verification using PubMed literature and large language models.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)

            // Links
            VStack(spacing: 8) {
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

            // Reset button
            Button("Reset All Settings", role: .destructive) {
                settings.resetToDefaults()
            }
            .padding(.bottom)
        }
        .padding(32)
    }
}

#Preview {
    MacSettingsView()
        .environment(AppSettings.shared)
        .modelContainer(for: [UsageRecord.self], inMemory: true)
}
