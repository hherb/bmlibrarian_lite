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

/// Sidebar navigation items.
enum MacNavigationItem: String, CaseIterable, Identifiable {
    case factCheck = "Fact Check"
    case fullText = "Full Text"
    case report = "Report"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .factCheck: return "checkmark.shield"
        case .fullText: return "doc.richtext"
        case .report: return "doc.text"
        case .history: return "clock"
        }
    }
}

/// Main content view with sidebar navigation for macOS.
///
/// Uses a three-column layout on wide screens:
/// - Sidebar: Navigation between main sections
/// - Content: Selected section content
/// - Detail: Document details, reports, etc.
struct MacContentView: View {
    @State private var selectedNavItem: MacNavigationItem? = .factCheck
    @State private var hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")
    @State private var hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    @State private var currentReport: EvidenceReport?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The active fact-check workflow (persisted across tab switches).
    @State private var activeWorkflow: FactCheckWorkflow?

    /// The currently selected document for full-text viewing.
    @State private var selectedFullTextDocument: Document?

    /// Controls showing onboarding from settings.
    @State private var showingOnboardingFromSettings = false

    var body: some View {
        if !hasAcceptedDisclaimer {
            MacDisclaimerView(onAccept: acceptDisclaimer)
        } else if !hasSeenOnboarding {
            MacOnboardingView(onComplete: completeOnboarding)
        } else {
            mainNavigationView
                .sheet(isPresented: $showingOnboardingFromSettings) {
                    MacOnboardingView(onComplete: {
                        showingOnboardingFromSettings = false
                    })
                }
                .onReceive(NotificationCenter.default.publisher(for: .showMacOnboarding)) { _ in
                    showingOnboardingFromSettings = true
                }
        }
    }

    private var mainNavigationView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailView
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        List(selection: $selectedNavItem) {
            Section("Medical Fact Checker") {
                ForEach(MacNavigationItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.rawValue, systemImage: item.icon)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: MacLayout.sidebarMinWidth, ideal: MacLayout.sidebarIdealWidth, max: MacLayout.sidebarMaxWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedNavItem {
        case .factCheck:
            MacFactCheckView(
                workflow: $activeWorkflow,
                onReportGenerated: { report in
                    currentReport = report
                    selectedNavItem = .report
                },
                onShowFullText: { document in
                    selectedFullTextDocument = document
                    selectedNavItem = .fullText
                }
            )
        case .fullText:
            MacFullTextTab(
                workflow: activeWorkflow,
                selectedDocument: $selectedFullTextDocument
            )
        case .report:
            MacReportView(report: currentReport, workflow: activeWorkflow)
        case .history:
            MacHistoryView(
                onReportSelected: { report in
                    currentReport = report
                    selectedNavItem = .report
                }
            )
        case nil:
            Text("Select an item from the sidebar")
                .font(.title2)
                .foregroundColor(.secondary)
        }
    }

    private func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
        withAnimation {
            hasAcceptedDisclaimer = true
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        withAnimation {
            hasSeenOnboarding = true
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the user wants to view onboarding again from settings.
    static let showMacOnboarding = Notification.Name("showMacOnboarding")
}

// MARK: - macOS Disclaimer View

/// Full-window disclaimer for first-time users.
struct MacDisclaimerView: View {
    let onAccept: () -> Void

    var body: some View {
        VStack(spacing: MacSpacing.section) {
            Spacer()

            Image(systemName: "cross.case.circle")
                .font(.system(size: MacIconSize.disclaimerIcon))
                .foregroundColor(.accentColor)

            Text("Medical Fact Checker")
                .font(.largeTitle)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: MacSpacing.large) {
                DisclaimerPoint(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "For Informational Purposes Only",
                    description: "This app provides AI-generated analysis of medical literature. It is not a substitute for professional medical advice."
                )

                DisclaimerPoint(
                    icon: "stethoscope",
                    color: .blue,
                    title: "Consult Healthcare Professionals",
                    description: "Always discuss findings with qualified healthcare providers before making any medical decisions."
                )

                DisclaimerPoint(
                    icon: "brain.head.profile",
                    color: .purple,
                    title: "AI Limitations",
                    description: "AI may misinterpret evidence or miss important context. Use critical thinking when reviewing results."
                )

                DisclaimerPoint(
                    icon: "lock.shield",
                    color: .green,
                    title: "Your Privacy",
                    description: "Your queries are sent to LLM providers for processing. No personal health data is stored externally."
                )
            }
            .frame(maxWidth: MacLayout.disclaimerMaxContentWidth)
            .padding(.horizontal, MacSpacing.disclaimer)

            Spacer()

            Button(action: onAccept) {
                Text("I Understand - Continue")
                    .font(.headline)
                    .padding(.horizontal, MacSpacing.disclaimer)
                    .padding(.vertical, MacSpacing.standard)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(minWidth: MacLayout.disclaimerMinWidth, minHeight: MacLayout.disclaimerMinHeight)
    }
}

/// A single disclaimer point with icon, title, and description.
///
/// Used in the disclaimer view to display important information to the user.
struct DisclaimerPoint: View {
    /// The SF Symbol name for the icon.
    let icon: String
    /// The color for the icon.
    let color: Color
    /// The title text.
    let title: String
    /// The description text.
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: MacSpacing.large) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: MacIconSize.disclaimerIconFrame)

            VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
    }
}

#Preview {
    MacContentView()
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
        .environment(AppSettings.shared)
}
