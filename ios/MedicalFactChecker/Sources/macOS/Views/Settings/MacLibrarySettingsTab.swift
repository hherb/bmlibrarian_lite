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
/// the app keeps its papers as before; nothing nags. A choice offers to move
/// this app's files in, a switch to copy them along, *Stop using* to copy
/// them back (design §4.7); every offer starts unticked.
struct LibrarySettingsTab: View {
    @Environment(LibrarySession.self) private var session

    /// True while *Stop using this library* waits for its confirmation.
    @State private var confirmingStop = false

    /// How many of this app's files the move would bring in.
    @State private var pending = 0
    /// How many library files this app's documents use.
    @State private var used = 0
    /// *Choose…* moves this app's files into the new library.
    @State private var bring = false
    /// *Choose Another…* copies the files this app uses into the new folder.
    @State private var copyAlong = false
    /// *Stop Using* copies the files this app uses back into the app.
    @State private var copyBack = false
    /// True while *Move Into the Library* runs.
    @State private var moving = false
    /// What the last change did, one line each; empty before any.
    @State private var outcome: [String] = []

    var body: some View {
        Form {
            Section("Paper Library") {
                stateView
                offers
                buttons
                ForEach(outcome, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundColor(line == outcome.first ? .secondary : .orange)
                        .textSelection(.enabled)
                }
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
        .task { await refreshCounts() }
    }

    /// The unticked offers that go with the next change.
    @ViewBuilder
    private var offers: some View {
        if isReachable {
            if used > 0 {
                Toggle("Copy the \(files(used)) this app uses into the new folder when choosing another",
                       isOn: $copyAlong)
            }
            if pending > 0 {
                HStack {
                    Button("Move \(files(pending).capitalized) Kept in This App Into the Library") { moveIn() }
                        .disabled(busy)
                    if moving { ProgressView().controlSize(.small) }
                }
            }
        } else if pending > 0 {
            Toggle("Move the \(files(pending)) kept in this app into the chosen folder", isOn: $bring)
        }
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
                .disabled(busy)
            if session.isWorking { ProgressView().controlSize(.small) }
            Spacer()
            if session.state != .notChosen {
                if confirmingStop {
                    Text("Papers already in the folder stay there.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if isReachable && used > 0 {
                        Toggle("Copy the \(files(used)) this app uses back into this app", isOn: $copyBack)
                    }
                    Button("Cancel") { confirmingStop = false }
                    Button("Stop Using", role: .destructive) { stopUsing() }
                } else {
                    Button("Stop Using This Library…") { confirmingStop = true }
                        .disabled(busy)
                }
            }
        }
    }

    private var isReachable: Bool {
        if case .reachable = session.state { return true }
        return false
    }

    /// True while a change or a move runs: the buttons wait.
    private var busy: Bool { session.isWorking || moving }

    /// "1 file" or "N files".
    private func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }

    /// Count again what the offers name.
    private func refreshCounts() async {
        pending = await LibraryController.pendingCount()
        used = LibraryController.usedCount()
    }

    /// What `summary` did, worded with `done` ("moved into the paper
    /// library"), then one line per file not moved.
    private func lines(_ summary: LibraryMoveSummary?, done: String) -> [String] {
        guard let summary else { return [] }
        let head = summary.moved == 0 && summary.failed.isEmpty
            ? "Nothing was copied or moved."
            : "\(files(summary.moved)) \(done)."
        return [head] + summary.failed.map { "Not moved: \($0)" }
    }

    /// *Move … Into the Library*: this app's files into the held library.
    private func moveIn() {
        guard let access = session.access else { return }
        moving = true
        Task {
            let summary = await LibraryController.moveIn(into: access, onlyWaiting: false)
            outcome = lines(summary, done: "moved into the paper library")
            moving = false
            await refreshCounts()
        }
    }

    /// *Stop Using*: the copy back first when ticked (only while reachable),
    /// else each document with a library file is told it is left there.
    private func stopUsing() {
        let copying = copyBack && isReachable && used > 0
        confirmingStop = false
        Task {
            var summary: LibraryMoveSummary?
            if session.access == nil { LibraryController.noteNoLongerUsed() }
            await session.stopUsing { access in
                summary = await LibraryController.carryBack(from: access, copying: copying)
            }
            outcome = copying ? lines(summary, done: "copied back into this app") : []
            copyBack = false
            await refreshCounts()
        }
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
        let bringing = !isReachable && bring && pending > 0
        let copying = isReachable && copyAlong && used > 0
        Task {
            var summary: LibraryMoveSummary?
            var done = "moved into the paper library"
            await session.choose(url) { old, new in
                if let old {
                    done = "copied into the new folder"
                    summary = await LibraryController.carry(from: old, to: new, copying: copying)
                } else if bringing {
                    summary = await LibraryController.moveIn(into: new, onlyWaiting: false)
                }
            }
            outcome = session.lastError == nil ? lines(summary, done: done) : []
            bring = false
            copyAlong = false
            await refreshCounts()
        }
    }
}
#endif
