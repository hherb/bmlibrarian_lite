//
//  SettingsView.swift
//  MedicalFactChecker
//
//  View for configuring app settings including API keys and budgets.
//

import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @State private var apiKey = ""
    @State private var ncbiAPIKey = ""
    @State private var showingSaveConfirmation = false
    @State private var monthlyUsage: Double = 0
    @State private var showingCustomConfig = false

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
                        if settings.selectedProvider.models.isEmpty {
                            Text("Enter model name manually below")
                                .foregroundColor(.secondary)
                        } else {
                            // Use a computed binding that ensures the selection is always valid
                            let modelBinding = Binding<String>(
                                get: {
                                    // If current model is valid for this provider, use it
                                    if settings.selectedProvider.models.contains(where: { $0.id == settings.llmModel }) {
                                        return settings.llmModel
                                    }
                                    // Otherwise return the default model for this provider
                                    return settings.selectedProvider.defaultModel?.id ?? settings.llmModel
                                },
                                set: { newValue in
                                    settings.llmModel = newValue
                                }
                            )

                            Picker("Model", selection: modelBinding) {
                                ForEach(settings.selectedProvider.models) { model in
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

                            if let selectedModel = settings.selectedProvider.models.first(where: { $0.id == settings.llmModel }) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(selectedModel.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(selectedModel.priceDescription)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        // For Ollama, allow custom model names
                        if settings.selectedProvider == .ollama {
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
                        SecureField("API Key", text: $apiKey)
                            .textContentType(.password)

                        Button("Save API Key") {
                            settings.llmAPIKey = apiKey
                            showingSaveConfirmation = true
                        }
                        .disabled(apiKey.isEmpty)

                        if let apiKeyURL = settings.selectedProvider.apiKeyURL {
                            Button {
                                openURL(apiKeyURL)
                            } label: {
                                HStack {
                                    Text("Get API Key")
                                    Spacer()
                                    Image(systemName: "arrow.up.right.square")
                                }
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
                    Text("Search Settings")
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

                // About
                Section {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Button("Reset All Settings", role: .destructive) {
                        settings.resetToDefaults()
                        apiKey = ""
                        ncbiAPIKey = ""
                        showingCustomConfig = false
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
            .onAppear {
                loadCurrentValues()
            }
        }
    }

    // MARK: - Helpers

    private func loadCurrentValues() {
        apiKey = settings.llmAPIKey
        ncbiAPIKey = settings.ncbiAPIKey
        loadMonthlyUsage()
        // Auto-expand custom config for custom provider
        showingCustomConfig = settings.selectedProvider == .custom
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
}

// MARK: - Model Pricing View

struct ModelPricingView: View {
    private let models: [(name: String, input: Double, output: Double)] = [
        ("gpt-4o-mini", 0.15, 0.60),
        ("gpt-4o", 2.50, 10.00),
        ("gpt-3.5-turbo", 0.50, 1.50),
        ("claude-3-haiku", 0.25, 1.25),
        ("claude-3-sonnet", 3.00, 15.00),
        ("deepseek-chat", 0.14, 0.28),
        ("mistral-small", 1.00, 3.00),
        ("llama-3.1-8b", 0.05, 0.08),
    ]

    var body: some View {
        List {
            Section {
                Text("Prices are per 1 million tokens. A typical fact-check uses 5,000-20,000 tokens.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Common Models") {
                ForEach(models, id: \.name) { model in
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

            Section {
                Text("Estimated cost per fact-check:")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 8) {
                    CostEstimateRow(model: "gpt-4o-mini", cost: "$0.001 - $0.003")
                    CostEstimateRow(model: "gpt-4o", cost: "$0.02 - $0.05")
                    CostEstimateRow(model: "claude-3-haiku", cost: "$0.002 - $0.005")
                }
            } header: {
                Text("Cost Estimates")
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
