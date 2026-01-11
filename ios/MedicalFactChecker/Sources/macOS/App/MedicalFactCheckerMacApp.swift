//
//  MedicalFactCheckerMacApp.swift
//  MedicalFactChecker
//
//  macOS app entry point for fact-checking medical claims using PubMed and LLM APIs.
//

import SwiftUI
import SwiftData

/// Main macOS app entry point.
///
/// Configures SwiftData persistence, window management, and the Settings scene.
@main
struct MedicalFactCheckerMacApp: App {
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
            print("ModelContainer creation failed:")
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

    var body: some Scene {
        WindowGroup {
            MacContentView()
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
        .windowStyle(.automatic)
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    // Placeholder for update checking
                }
            }
        }

        #if os(macOS)
        Settings {
            MacSettingsView()
                .environment(AppSettings.shared)
                .modelContainer(sharedModelContainer)
        }
        #endif
    }
}
