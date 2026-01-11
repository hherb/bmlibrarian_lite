//
//  ContentView.swift
//  MedicalFactChecker
//
//  Main tab view for the app.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var hasAcceptedDisclaimer = UserDefaults.standard.bool(forKey: "hasAcceptedDisclaimer")

    var body: some View {
        if hasAcceptedDisclaimer {
            mainTabView
        } else {
            DisclaimerView(onAccept: acceptDisclaimer)
        }
    }

    private var mainTabView: some View {
        TabView(selection: $selectedTab) {
            FactCheckView()
                .tabItem {
                    Label("Check", systemImage: "checkmark.shield")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }

    private func acceptDisclaimer() {
        UserDefaults.standard.set(true, forKey: "hasAcceptedDisclaimer")
        withAnimation {
            hasAcceptedDisclaimer = true
        }
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
