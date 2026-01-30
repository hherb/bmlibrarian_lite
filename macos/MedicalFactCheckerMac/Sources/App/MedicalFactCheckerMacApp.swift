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

/// Main macOS app entry point.
///
/// Configures SwiftData persistence, window management, Help menu, and the Settings scene.
@main
struct MedicalFactCheckerMacApp: App {
    /// Window ID for the main fact-checking window.
    static let mainWindowID = "main-window"

    init() {
        // Configure BioMedLit library with app settings
        configureBioMedLit()
    }

    var sharedModelContainer: ModelContainer = {
        // Clear any pending config change flag from previous launch
        CloudKitConfiguration.clearPendingChange()

        // Register custom transformer before creating the container
        StringArrayTransformer.register()

        do {
            // Use migration-aware container creation to preserve user data
            // when upgrading from previous schema versions
            return try CloudKitConfiguration.makeModelContainerWithMigration()
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
        WindowGroup(id: Self.mainWindowID) {
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
        .defaultSize(width: MacLayout.defaultWindowWidth, height: MacLayout.defaultWindowHeight)
        .commands {
            CommandGroup(replacing: .newItem) { }

            // Window menu command to show/reopen main window
            CommandGroup(after: .windowList) {
                ShowMainWindowCommand()
            }

            // Help menu commands
            CommandGroup(replacing: .help) {
                HelpMenuCommands()
            }
        }

        #if os(macOS)
        Settings {
            MacSettingsView()
                .environment(AppSettings.shared)
                .modelContainer(sharedModelContainer)
        }

        // Help window
        Window("Help", id: "help-window") {
            MacHelpWindowView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Privacy window
        Window("Privacy Policy", id: "privacy-window") {
            MacPrivacyWindowView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Acknowledgments window
        Window("Acknowledgments", id: "acknowledgments-window") {
            MacAcknowledgmentsWindowView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        #endif
    }
}

// MARK: - Window Menu Commands

/// Command to show/reopen the main window.
///
/// Uses @Environment(\.openWindow) to open the main window when it has been closed.
struct ShowMainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Medical Fact Checker") {
            openWindow(id: MedicalFactCheckerMacApp.mainWindowID)
        }
        .keyboardShortcut("0", modifiers: .command)
    }
}

// MARK: - Help Menu Commands

/// View containing Help menu command buttons.
///
/// Uses @Environment(\.openWindow) to open auxiliary windows.
struct HelpMenuCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Medical Fact Checker Help") {
            openWindow(id: "help-window")
        }
        .keyboardShortcut("?", modifiers: .command)

        Divider()

        Button("Privacy Policy") {
            openWindow(id: "privacy-window")
        }

        Button("Acknowledgments") {
            openWindow(id: "acknowledgments-window")
        }

        Divider()

        Link("PubMed Website", destination: URL(string: "https://pubmed.ncbi.nlm.nih.gov/")!)

        Link("Report an Issue...", destination: URL(string: "https://github.com/hherb/bmlibrarian_lite/issues")!)
    }
}

// MARK: - BioMedLit Configuration

extension MedicalFactCheckerMacApp {
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
