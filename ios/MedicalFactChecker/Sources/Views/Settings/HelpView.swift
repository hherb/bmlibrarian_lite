//
//  HelpView.swift
//  MedicalFactChecker
//
//  Displays in-app help documentation with native markdown rendering.
//

import SwiftUI

/// View that displays the help documentation with native markdown rendering.
///
/// Loads and renders the HELP.md file bundled with the app, providing
/// users with comprehensive guidance on using the app.
struct HelpView: View {
    @State private var helpContent: AttributedString = AttributedString("Loading...")
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load help content")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                Text(helpContent)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle("Help")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            await loadHelpContent()
        }
    }

    // MARK: - Content Loading

    /// Loads the HELP.md content from the app bundle.
    private func loadHelpContent() async {
        // Try to load from bundle
        if let url = Bundle.main.url(forResource: "HELP", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            do {
                helpContent = try AttributedString(markdown: content, options: markdownOptions)
            } catch {
                loadError = "Failed to parse markdown: \(error.localizedDescription)"
            }
        } else {
            // Fallback: use embedded content
            helpContent = fallbackHelpContent
        }
    }

    /// Markdown parsing options for proper rendering.
    private var markdownOptions: AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return options
    }

    /// Fallback help content if the bundle file is not available.
    private var fallbackHelpContent: AttributedString {
        let text = """
        # Medical Fact Checker Help

        Welcome to Medical Fact Checker, an AI-powered tool for evaluating medical claims using peer-reviewed scientific literature.

        ## Quick Start

        1. Enter a medical claim or question
        2. Tap "Check Evidence"
        3. Review the evidence report

        ## Important Notes

        - This app analyzes publication abstracts, not full-text articles
        - The default fetches 20 documents per search - you can fetch more for thorough research
        - Results depend on the AI model used - Claude models are recommended

        ## Need More Help?

        Visit our GitHub repository for detailed documentation:
        github.com/hherb/bmlibrarian_lite

        ---

        This app is a research tool, not a substitute for professional medical advice.
        """

        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

// MARK: - Privacy View

/// View that displays the privacy policy with native markdown rendering.
struct PrivacyView: View {
    @State private var privacyContent: AttributedString = AttributedString("Loading...")
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            if let error = loadError {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text("Could not load privacy policy")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                Text(privacyContent)
                    .textSelection(.enabled)
                    .padding()
            }
        }
        .navigationTitle("Privacy Policy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            await loadPrivacyContent()
        }
    }

    // MARK: - Content Loading

    /// Loads the PRIVACY.md content from the app bundle.
    private func loadPrivacyContent() async {
        if let url = Bundle.main.url(forResource: "PRIVACY", withExtension: "md"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            do {
                privacyContent = try AttributedString(markdown: content, options: markdownOptions)
            } catch {
                loadError = "Failed to parse markdown: \(error.localizedDescription)"
            }
        } else {
            privacyContent = fallbackPrivacyContent
        }
    }

    /// Markdown parsing options for proper rendering.
    private var markdownOptions: AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return options
    }

    /// Fallback privacy content if the bundle file is not available.
    private var fallbackPrivacyContent: AttributedString {
        let text = """
        # Privacy Policy

        Medical Fact Checker is designed with privacy in mind.

        ## What We Do NOT Collect

        - We do not collect personal information
        - We do not collect usage analytics
        - We do not track your location
        - We do not use advertising trackers

        ## What Stays On Your Device

        - Medical claims and queries
        - Fact-check history
        - App settings
        - API keys (stored in iOS Keychain)

        ## Third-Party Services

        When you run a fact-check, data is sent to:
        - PubMed (NCBI) for literature searches
        - Your chosen LLM provider for AI analysis

        Use Ollama for completely local processing with no external API calls.

        ---

        For the complete privacy policy, visit:
        github.com/hherb/bmlibrarian_lite
        """

        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

#Preview("Help") {
    NavigationStack {
        HelpView()
    }
}

#Preview("Privacy") {
    NavigationStack {
        PrivacyView()
    }
}
