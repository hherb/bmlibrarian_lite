#if os(macOS)
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

import AppKit
import SwiftUI
import BioMedLit

/// The Library setting: the shared paper library folder, shared with the
/// other bmlib-family apps (StudyAnalyzer), or none (design §4.1). Without one
/// the app keeps its papers as before; nothing nags.
struct LibrarySettingsTab: View {
    @Environment(LibrarySession.self) private var session

    /// True while *Stop using this library* waits for its confirmation.
    @State private var confirmingStop = false

    var body: some View {
        Form {
            Section("Paper Library") {
                stateView
                buttons
                if let error = session.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }

            Section("About the library") {
                Text("A library is a folder you choose, kept on your own disk (or a synced folder). Papers saved there are kept once and can be read by the other apps that use it, such as StudyAnalyzer. Nothing in it is ever deleted automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @ViewBuilder
    private var stateView: some View {
        switch session.state {
        case .notChosen where session.isReaching:
            Text(BioMedLitConstants.libraryReachingText)
                .foregroundColor(.secondary)
        case .notChosen:
            Text("No library folder is set. Papers are kept in this app's own storage.")
                .foregroundColor(.secondary)
        case let .reachable(folderName, path):
            Label(folderName, systemImage: "books.vertical.fill")
            Text(path)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        case let .unreachable(reason):
            Label("The library folder cannot be reached: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .textSelection(.enabled)
        }
        if let unsaved = session.unsaved {
            Label(BioMedLitConstants.libraryUnsavedPrefix + unsaved, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.orange)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            Button(isReachable ? "Choose Another…" : "Choose…") { pickFolder() }
                .disabled(session.isWorking)
            if session.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            if session.state != .notChosen {
                if confirmingStop {
                    Text("Papers already in the folder stay there.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Cancel") { confirmingStop = false }
                    Button("Stop Using", role: .destructive) {
                        session.stopUsing()
                        confirmingStop = false
                    }
                } else {
                    Button("Stop Using This Library…") { confirmingStop = true }
                        .disabled(session.isWorking)
                }
            }
        }
    }

    private var isReachable: Bool {
        if case .reachable = session.state { return true }
        return false
    }

    /// The folder picker; a chosen folder is handed to the session.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Library"
        panel.message = "Choose an empty folder for a new library, or a folder that already holds one."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirmingStop = false
        Task { await session.choose(url) }
    }
}
#endif
