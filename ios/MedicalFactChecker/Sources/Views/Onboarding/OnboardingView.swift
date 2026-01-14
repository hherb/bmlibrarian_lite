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
            icon: "gear.badge.checkmark",
            iconColors: [.gray, .secondary],
            title: "Configure in Settings",
            description: "Choose your AI provider (Anthropic, OpenAI, etc.), set budget limits, and customize search parameters. An API key is required for most providers."
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
