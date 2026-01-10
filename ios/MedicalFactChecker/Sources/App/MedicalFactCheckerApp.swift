//
//  MedicalFactCheckerApp.swift
//  MedicalFactChecker
//
//  iOS app for fact-checking medical claims using PubMed and LLM APIs.
//

import SwiftUI
import SwiftData

@main
struct MedicalFactCheckerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppSettings.shared)
        }
        .modelContainer(sharedModelContainer)
    }
}
