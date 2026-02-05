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

/// Tab identifiers for the main navigation.
enum AppTab: Int {
    case check = 0
    case fullText = 1
    case report = 2
    case history = 3
    case settings = 4
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var selectedTab: AppTab = .check
    @State private var hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")
    @State private var hasSeenOnboarding = UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    @State private var currentReport: EvidenceReport?

    /// Tracks which tabs have been visited for lazy loading.
    @State private var visitedTabs: Set<AppTab> = [.check]

    /// Preserved state for FactCheckView to survive tab switches.
    @State private var factCheckClaimText: String = ""
    @State private var factCheckWorkflow: FactCheckWorkflow?

    /// Controls showing onboarding from settings.
    @State private var showingOnboardingFromSettings = false

    /// Currently selected document for full-text viewing.
    @State private var selectedFullTextDocument: Document?

    var body: some View {
        if !hasAcceptedDisclaimer {
            DisclaimerView(onAccept: acceptDisclaimer)
        } else if !hasSeenOnboarding {
            OnboardingView(onComplete: completeOnboarding)
        } else {
            mainTabView
                .sheet(isPresented: $showingOnboardingFromSettings) {
                    OnboardingView(onComplete: {
                        showingOnboardingFromSettings = false
                    })
                }
                .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
                    showingOnboardingFromSettings = true
                }
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            FactCheckView(
                onReportGenerated: { report in
                    currentReport = report
                    visitedTabs.insert(.report)
                    selectedTab = .report
                },
                claimText: $factCheckClaimText,
                workflow: $factCheckWorkflow
            )
            .tabItem {
                Label("Check", systemImage: "checkmark.shield")
            }
            .tag(AppTab.check)

            LazyTabContent(tab: .fullText, visitedTabs: $visitedTabs) {
                FullTextTab(
                    workflow: factCheckWorkflow,
                    selectedDocument: $selectedFullTextDocument
                )
            }
            .tabItem {
                Label("Full Text", systemImage: "doc.richtext")
            }
            .tag(AppTab.fullText)

            LazyTabContent(tab: .report, visitedTabs: $visitedTabs) {
                ReportTabView(report: currentReport, workflow: factCheckWorkflow)
            }
            .tabItem {
                Label("Report", systemImage: "chart.bar.doc.horizontal")
            }
            .tag(AppTab.report)

            LazyTabContent(tab: .history, visitedTabs: $visitedTabs) {
                HistoryView(onContinueSession: { session in
                    restoreSession(session)
                })
            }
            .tabItem {
                Label("History", systemImage: "clock")
            }
            .tag(AppTab.history)

            LazyTabContent(tab: .settings, visitedTabs: $visitedTabs) {
                SettingsView()
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(AppTab.settings)
        }
        .onChange(of: selectedTab) { _, newTab in
            visitedTabs.insert(newTab)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettings)) { _ in
            visitedTabs.insert(.settings)
            selectedTab = .settings
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

    // MARK: - Session Restoration

    /// Restores a session from history for viewing.
    ///
    /// This method is called when the user taps a history item. It:
    /// 1. Restores the original claim text to the input field
    /// 2. Creates a workflow with the session loaded (without running it)
    /// 3. Sets up callbacks for any subsequent actions (like "Add More Results")
    /// 4. Sets the current report so the Report tab shows it
    /// 5. Navigates to the Check tab
    ///
    /// The session's documents, scores, and report are displayed without
    /// re-running the workflow. The user can then click "Add More Results"
    /// to fetch additional documents if more are available.
    ///
    /// - Parameter session: The fact-check session to restore for viewing.
    private func restoreSession(_ session: FactCheckSession) {
        // Restore the claim text to the input field
        factCheckClaimText = session.claim

        // Create a new workflow for this session
        let restoredWorkflow = FactCheckWorkflow(
            modelContext: modelContext,
            settings: AppSettings.shared
        )

        // Configure workflow callbacks for any subsequent actions

        // Called when workflow completes successfully with a report
        restoredWorkflow.onComplete = { report in
            currentReport = report
            visitedTabs.insert(.report)
            selectedTab = .report
        }

        // Called when an error occurs during workflow execution
        restoredWorkflow.onError = { error in
            print("[ContentView] Workflow error: \(error.localizedDescription)")
        }

        // Called when budget limit is exceeded
        restoredWorkflow.onBudgetExceeded = { message in
            print("[ContentView] Budget exceeded: \(message)")
        }

        // Restore session for viewing (does not run the workflow)
        restoredWorkflow.restoreForViewing(session)

        // Set the workflow binding so FactCheckView receives it
        factCheckWorkflow = restoredWorkflow

        // Set the current report so Report tab shows it
        if let report = session.report {
            currentReport = report
        }

        // Navigate to Check tab
        visitedTabs.insert(.check)
        selectedTab = .check
    }
}

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when the user wants to view onboarding again from settings.
    static let showOnboarding = Notification.Name("showOnboarding")

    /// Posted when the user taps the configuration warning to navigate to settings.
    static let navigateToSettings = Notification.Name("navigateToSettings")
}

// MARK: - Lazy Tab Content

/// Wrapper that defers rendering of tab content until the tab is first visited.
///
/// This prevents unnecessary initialization of views (like SettingsView calling
/// `loadModels()`) before the user actually navigates to that tab.
struct LazyTabContent<Content: View>: View {
    let tab: AppTab
    @Binding var visitedTabs: Set<AppTab>
    @ViewBuilder let content: () -> Content

    var body: some View {
        if visitedTabs.contains(tab) {
            content()
        } else {
            // Placeholder shown briefly before tab is visited
            Color.clear
        }
    }
}

// MARK: - Report Tab View

/// A wrapper view for displaying reports in a dedicated tab.
///
/// Shows the full report when available, or an empty state when no report exists.
/// Passes the workflow to enable "Get More Evidence" functionality.
struct ReportTabView: View {
    let report: EvidenceReport?
    var workflow: FactCheckWorkflow?

    var body: some View {
        if let report = report {
            ReportContentView(report: report, workflow: workflow)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 60))
                .foregroundColor(.secondary.opacity(0.5))

            Text("No Report Yet")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Run a fact-check to generate an evidence report")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ], inMemory: true)
        .environment(AppSettings.shared)
}

#endif // os(iOS)
