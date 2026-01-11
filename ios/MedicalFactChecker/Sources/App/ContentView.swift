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
                    selectedTab = .report
                }
            )
            .tabItem {
                Label("Check", systemImage: "checkmark.shield")
            }
            .tag(AppTab.check)

            ReportTabView(report: currentReport)
                .tabItem {
                    Label("Report", systemImage: "doc.text")
                }
                .tag(AppTab.report)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(AppTab.history)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(AppTab.settings)
        }
    }

    private func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
        withAnimation {
            hasAcceptedDisclaimer = true
        }
    }
}

// MARK: - Report Tab View

/// A wrapper view for displaying reports in a dedicated tab.
///
/// Shows the full report when available, or an empty state when no report exists.
struct ReportTabView: View {
    let report: EvidenceReport?

    var body: some View {
        if let report = report {
            ReportContentView(report: report)
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
