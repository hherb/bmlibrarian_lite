//
//  OnboardingView.swift
//  MedicalFactChecker
//
//  Swipeable onboarding flow explaining how to use the app.
//

import SwiftUI
import UIKit

/// A single onboarding page with icon, title, and description.
struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let iconColors: [Color]
    let title: String
    let description: String
}

/// Swipeable onboarding view shown on first launch.
///
/// Walks users through the key features and workflow of the app.
struct OnboardingView: View {
    /// Callback when user completes onboarding.
    let onComplete: () -> Void

    /// Current page index.
    @State private var currentPage = 0

    /// Onboarding pages content.
    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "checkmark.shield.fill",
            iconColors: [.blue, .cyan],
            title: "Welcome to Medical Fact Checker",
            description: "Evaluate medical claims using peer-reviewed scientific literature from PubMed and AI-powered analysis."
        ),
        OnboardingPage(
            icon: "text.badge.checkmark",
            iconColors: [.green, .mint],
            title: "Enter a Medical Claim",
            description: "Type any health-related claim or question. For example: \"Vitamin D supplementation reduces respiratory infections\" or \"Does omega-3 help with depression?\""
        ),
        OnboardingPage(
            icon: "magnifyingglass.circle.fill",
            iconColors: [.orange, .yellow],
            title: "AI Searches PubMed",
            description: "Your claim is converted into an optimized search query. The app retrieves relevant research abstracts from over 36 million biomedical citations."
        ),
        OnboardingPage(
            icon: "chart.bar.doc.horizontal.fill",
            iconColors: [.purple, .pink],
            title: "Documents Are Scored",
            description: "Each document is scored 1-5 for relevance. Key passages are extracted as citations with information about whether findings support or refute your claim."
        ),
        OnboardingPage(
            icon: "doc.text.fill",
            iconColors: [.indigo, .blue],
            title: "Get Your Evidence Report",
            description: "Receive a verdict (Supported, Not Supported, etc.) along with a detailed summary and clickable references to original PubMed articles."
        ),
        OnboardingPage(
            icon: "key.fill",
            iconColors: [.orange, .red],
            title: "You'll Need an API Key",
            description: "This app uses AI language models (like ChatGPT) to analyze research. These services require an API key - a unique password that identifies you to the AI provider."
        ),
        OnboardingPage(
            icon: "dollarsign.circle.fill",
            iconColors: [.green, .mint],
            title: "How Pricing Works",
            description: "AI providers charge per \"token\" (roughly 4 characters). A typical fact-check costs $0.01-$0.05. You control spending with budget limits in Settings."
        ),
        OnboardingPage(
            icon: "star.fill",
            iconColors: [.yellow, .orange],
            title: "Start Free with Mistral",
            description: "Mistral offers free API credits to get started! Visit console.mistral.ai, create an account, and generate an API key. Then select \"Mistral\" as your provider in Settings."
        ),
        OnboardingPage(
            icon: "gear.badge.checkmark",
            iconColors: [.gray, .secondary],
            title: "Quick Setup",
            description: "In Settings: 1) Select your Provider (e.g., Mistral), 2) Paste your API key, 3) Tap \"Save API Key\". That's it - you're ready to fact-check!"
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            TabView(selection: $currentPage) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                    OnboardingPageView(page: page)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: currentPage)

            // Custom page indicator
            HStack(spacing: 8) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }
            .padding(.top, 16)

            // Navigation buttons
            HStack {
                if currentPage > 0 {
                    Button("Back") {
                        withAnimation {
                            currentPage -= 1
                        }
                    }
                    .foregroundColor(.secondary)
                } else {
                    Spacer()
                        .frame(width: 60)
                }

                Spacer()

                if currentPage < pages.count - 1 {
                    Button("Next") {
                        withAnimation {
                            currentPage += 1
                        }
                    }
                    .fontWeight(.semibold)
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(10)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)

            // Skip button (only on non-final pages)
            if currentPage < pages.count - 1 {
                Button("Skip") {
                    onComplete()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)
            } else {
                Spacer()
                    .frame(height: 38)
            }
        }
        .background(Color(uiColor: .systemBackground))
    }
}

/// Individual onboarding page content.
struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon with gradient
            Image(systemName: page.icon)
                .font(.system(size: 80))
                .foregroundStyle(
                    LinearGradient(
                        colors: page.iconColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Title
            Text(page.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Description
            Text(page.description)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
            Spacer()
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
}
