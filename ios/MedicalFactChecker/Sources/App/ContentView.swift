//
//  ContentView.swift
//  MedicalFactChecker
//
//  Main tab view for the app.
//

import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
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
