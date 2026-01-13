//
//  ContentView.swift
//  MedicalFactChecker
//
//  Main tab view for the app.
//

import SwiftUI

/// Tab identifiers for the main navigation.
enum AppTab: Int {
    case check = 0
    case report = 1
    case history = 2
    case settings = 3
}

struct ContentView: View {
    @State private var selectedTab: AppTab = .check
    @State private var hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")
    @State private var currentReport: EvidenceReport?

    /// Tracks which tabs have been visited for lazy loading.
    @State private var visitedTabs: Set<AppTab> = [.check]

    /// Preserved state for FactCheckView to survive tab switches.
    @State private var factCheckClaimText: String = ""
    @State private var factCheckWorkflow: FactCheckWorkflow?

    var body: some View {
        if hasAcceptedDisclaimer {
            mainTabView
        } else {
            DisclaimerView(onAccept: acceptDisclaimer)
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

            LazyTabContent(tab: .report, visitedTabs: $visitedTabs) {
                ReportTabView(report: currentReport, workflow: factCheckWorkflow)
            }
            .tabItem {
                Label("Report", systemImage: "doc.text")
            }
            .tag(AppTab.report)

            LazyTabContent(tab: .history, visitedTabs: $visitedTabs) {
                HistoryView()
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
    }

    private func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
        withAnimation {
            hasAcceptedDisclaimer = true
        }
    }
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
