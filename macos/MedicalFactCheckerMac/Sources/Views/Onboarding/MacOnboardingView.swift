//
//  MacOnboardingView.swift
//  MedicalFactChecker
//
//  macOS onboarding view with navigation buttons and page indicator.
//

import SwiftUI

/// A single onboarding page with icon, title, and description.
struct MacOnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let iconColors: [Color]
    let title: String
    let description: String
}

/// macOS onboarding view shown on first launch.
///
/// Walks users through the key features and workflow of the app.
struct MacOnboardingView: View {
    /// Callback when user completes onboarding.
    let onComplete: () -> Void

    /// Current page index.
    @State private var currentPage = 0

    /// Onboarding pages content.
    private let pages: [MacOnboardingPage] = [
        MacOnboardingPage(
            icon: "checkmark.shield.fill",
            iconColors: [.blue, .cyan],
            title: "Welcome to Medical Fact Checker",
            description: "Evaluate medical claims using peer-reviewed scientific literature from PubMed and AI-powered analysis."
        ),
        MacOnboardingPage(
            icon: "text.badge.checkmark",
            iconColors: [.green, .mint],
            title: "Enter a Medical Claim",
            description: "Type any health-related claim or question. For example: \"Vitamin D supplementation reduces respiratory infections\" or \"Does omega-3 help with depression?\""
        ),
        MacOnboardingPage(
            icon: "magnifyingglass.circle.fill",
            iconColors: [.orange, .yellow],
            title: "AI Searches PubMed",
            description: "Your claim is converted into an optimized search query. The app retrieves relevant research abstracts from over 36 million biomedical citations."
        ),
        MacOnboardingPage(
            icon: "chart.bar.doc.horizontal.fill",
            iconColors: [.purple, .pink],
            title: "Documents Are Scored",
            description: "Each document is scored 1-5 for relevance. Key passages are extracted as citations with information about whether findings support or refute your claim."
        ),
        MacOnboardingPage(
            icon: "doc.text.fill",
            iconColors: [.indigo, .blue],
            title: "Get Your Evidence Report",
            description: "Receive a verdict (Supported, Not Supported, etc.) along with a detailed summary and clickable references to original PubMed articles."
        ),
        MacOnboardingPage(
            icon: "key.fill",
            iconColors: [.orange, .red],
            title: "You'll Need an API Key",
            description: "This app uses AI language models (like ChatGPT) to analyze research. These services require an API key - a unique password that identifies you to the AI provider."
        ),
        MacOnboardingPage(
            icon: "dollarsign.circle.fill",
            iconColors: [.green, .mint],
            title: "How Pricing Works",
            description: "AI providers charge per \"token\" (roughly 4 characters). A typical fact-check costs $0.01-$0.05. You control spending with budget limits in Settings."
        ),
        MacOnboardingPage(
            icon: "star.fill",
            iconColors: [.yellow, .orange],
            title: "Start Free with Mistral",
            description: "Mistral offers free API credits to get started! Visit console.mistral.ai, create an account, and generate an API key. Then select \"Mistral\" as your provider in Settings."
        ),
        MacOnboardingPage(
            icon: "gear.badge.checkmark",
            iconColors: [.gray, .secondary],
            title: "Quick Setup",
            description: "In Settings: 1) Select your Provider (e.g., Mistral), 2) Paste your API key, 3) Click \"Save API Key\". That's it - you're ready to fact-check!"
        ),
    ]

    var body: some View {
        VStack(spacing: MacSpacing.large) {
            // Page content area
            pageContent

            // Page indicator dots
            HStack(spacing: MacSpacing.medium) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }

            // Navigation buttons
            HStack {
                Button("Back") {
                    withAnimation {
                        currentPage -= 1
                    }
                }
                .disabled(currentPage == 0)
                .opacity(currentPage == 0 ? 0.5 : 1.0)

                Spacer()

                if currentPage < pages.count - 1 {
                    Button("Skip") {
                        onComplete()
                    }
                    .foregroundColor(.secondary)

                    Button("Next") {
                        withAnimation {
                            currentPage += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, MacSpacing.section)
            .padding(.bottom, MacSpacing.large)
        }
        .frame(minWidth: MacLayout.onboardingMinWidth, minHeight: MacLayout.onboardingMinHeight)
    }

    @ViewBuilder
    private var pageContent: some View {
        let page = pages[currentPage]

        VStack(spacing: MacSpacing.xxLarge) {
            Spacer()

            // Icon with gradient
            Image(systemName: page.icon)
                .font(.system(size: MacIconSize.onboardingIcon))
                .foregroundStyle(
                    LinearGradient(
                        colors: page.iconColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Title
            Text(page.title)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MacSpacing.section)

            // Description
            Text(page.description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MacSpacing.disclaimer)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: MacLayout.onboardingMaxContentWidth)

            Spacer()
        }
        .id(currentPage) // Force view refresh on page change
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.3), value: currentPage)
    }
}

#Preview {
    MacOnboardingView(onComplete: {})
}
