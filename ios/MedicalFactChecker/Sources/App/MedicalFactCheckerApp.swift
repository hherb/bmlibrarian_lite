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
import BioMedLit

@main
struct MedicalFactCheckerApp: App {
    /// Tracks the current scene phase for background handling.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Configure BioMedLit library with app settings
        configureBioMedLit()

        // Register background task handlers (iOS only)
        Task {
            await BackgroundTaskManager.shared.registerBackgroundTasks()
        }
    }

    var sharedModelContainer: ModelContainer = {
        // Clear any pending config change flag from previous launch
        CloudKitConfiguration.clearPendingChange()

        // Register custom transformer before creating the container
        StringArrayTransformer.register()

        let schema = Schema([
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self,
            ProcessingCheckpoint.self,
        ])

        // Use CloudKitConfiguration to determine sync settings
        let modelConfiguration = CloudKitConfiguration.makeModelConfiguration(schema: schema)

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
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    /// Handle scene phase transitions for background processing.
    ///
    /// Notifies the BackgroundTaskManager when the app enters or exits
    /// background state, allowing it to manage extended execution time
    /// and schedule recovery tasks.
    ///
    /// - Parameters:
    ///   - oldPhase: The previous scene phase.
    ///   - newPhase: The new scene phase.
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        Task {
            switch newPhase {
            case .background:
                await BackgroundTaskManager.shared.didEnterBackground()
            case .active:
                if oldPhase == .background {
                    await BackgroundTaskManager.shared.willEnterForeground()
                }
            case .inactive:
                // Transitional state - no action needed
                break
            @unknown default:
                break
            }
        }
    }

    /// Configure the BioMedLit library with current app settings.
    private func configureBioMedLit() {
        let settings = AppSettings.shared
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let config = BioMedLitConfiguration(
            ncbiEmail: email,
            logger: nil  // Use default console logger in debug
        )
        BioMedLitLib.configure(with: config)
    }
}

