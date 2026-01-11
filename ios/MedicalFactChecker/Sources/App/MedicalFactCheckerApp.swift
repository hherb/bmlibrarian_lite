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
            // Print detailed error information
            print("❌ ModelContainer creation failed:")
            print("Error: \(error)")
            print("Localized description: \(error.localizedDescription)")
            if let nsError = error as NSError? {
                print("Domain: \(nsError.domain)")
                print("Code: \(nsError.code)")
                print("UserInfo: \(nsError.userInfo)")
            }
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// Currently selected document for reference popup (shared via environment).
    @State private var selectedReferenceDocument: Document?
    @State private var showingReferenceSheet = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppSettings.shared)
                .environment(\.openURL, OpenURLAction { url in
                    // Intercept our custom docref:// URLs
                    if url.scheme == "docref" {
                        NotificationCenter.default.post(
                            name: .documentReferenceClicked,
                            object: nil,
                            userInfo: ["url": url]
                        )
                        return .handled
                    }
                    return .systemAction
                })
        }
        .modelContainer(sharedModelContainer)
    }
}

