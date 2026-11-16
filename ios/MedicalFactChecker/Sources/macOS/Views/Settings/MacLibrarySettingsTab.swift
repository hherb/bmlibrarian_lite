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
                outcomeLines(outcome)
                outcomeLines(LibraryController.settleReport.lines)
                if let error = session.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .textSelection(.enabled)
                }
            }

            if isReachable, let access = session.access {
                // A new folder's list starts unread
                LibraryPapersSection(access: access, busy: busy) { await refreshCounts() }
                    .id(ObjectIdentifier(access))
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

    /// What a change or the waiting settle did: the first line plain, a line
    /// per file not moved in orange.
    private func outcomeLines(_ lines: [String]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
            Text(line)
                .font(.caption)
                .foregroundColor(index == 0 ? .secondary : .orange)
                .textSelection(.enabled)
        }
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

    /// What `summary` did, worded with `done`, or nothing for no summary.
    private func lines(_ summary: LibraryMoveSummary?, done: String) -> [String] {
        summary?.lines(done: done) ?? []
    }

    /// *Move … Into the Library*: this app's files into the held library.
    private func moveIn() {
        guard let access = session.access else { return }
        moving = true
        Task {
            let summary = await LibraryController.moveIn(into: access, onlyWaiting: false)
            outcome = lines(summary, done: BioMedLitConstants.libraryMovedInDone)
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
            outcome = copying ? lines(summary, done: BioMedLitConstants.libraryCopiedBackDone) : []
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
        let oldUnreachable: Bool
        if case .unreachable = session.state { oldUnreachable = true } else { oldUnreachable = false }
        Task {
            var summary: LibraryMoveSummary?
            var done = BioMedLitConstants.libraryMovedInDone
            await session.choose(url) { old, new in
                if let old {
                    done = BioMedLitConstants.libraryCopiedAlongDone
                    summary = await LibraryController.carry(from: old, to: new, copying: copying)
                } else {
                    if oldUnreachable { LibraryController.noteUnreachableLeft() }
                    if bringing { summary = await LibraryController.moveIn(into: new, onlyWaiting: false) }
                }
            }
            outcome = session.lastError == nil ? lines(summary, done: done) : []
            bring = false
            copyAlong = false
            await refreshCounts()
        }
    }
}

/// The manual clear (design §4.8): on request, the library's papers, each
/// with its size, its files and the apps that use them. The user removes a
/// paper (its folder) or one file after a confirmation naming the other apps
/// still using it; nothing is removed otherwise. The list is read again after
/// every removal, a failed one too (the list may be stale).
private struct LibraryPapersSection: View {
    /// The held library.
    let access: LibraryAccess
    /// True while the setting's own change or move runs: the buttons wait.
    let busy: Bool
    /// Run after a removal, so the setting counts its files again.
    let changed: () async -> Void

    /// A removal waiting for the user's answer.
    private struct Removal {
        /// What it removes, as the list shows it.
        let what: String
        /// The confirmation (``LibraryClear/removeQuestion(what:usedBy:usedHere:usersUnknown:)``).
        let question: String
        /// The paper's folder.
        let folder: String
        /// The file's name, or nil for the whole folder.
        let name: String?
    }

    /// The library's papers, or nil until asked for (or after a failed read).
    @State private var listing: LibraryListing?
    /// True while the list is read or a removal runs.
    @State private var working = false
    /// The removal awaiting confirmation, if any.
    @State private var pending: Removal?
    /// What the last removal did.
    @State private var note: String?
    /// Why the last read or removal failed.
    @State private var failure: String?

    var body: some View {
        Section("Papers in the Library") {
            if let note {
                Text(note).font(.caption).foregroundColor(.secondary)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .textSelection(.enabled)
            }
            HStack {
                Button(listing == nil ? "Show the Library's Papers" : "Read the List Again") {
                    Task { await load() }
                }
                .disabled(busy || working)
                if working { ProgressView().controlSize(.small) }
            }
            if let listing {
                if listing.papers.isEmpty {
                    Text("The library holds no papers.").foregroundColor(.secondary)
                }
                ForEach(listing.papers, id: \.folder) { paper in
                    DisclosureGroup {
                        ForEach(paper.files, id: \.name) { file in
                            // A record the scan could not read may list the file too
                            row(file.name, detail: LibraryClear.sizeText(file.size) + ", "
                                + LibraryClear.usersText(usedBy: file.usedBy, usedHere: file.usedHere,
                                                         usersUnknown: paper.usersUnknown),
                                button: "Remove File…") {
                                ask(file.name, usedBy: file.usedBy, usedHere: file.usedHere,
                                    usersUnknown: paper.usersUnknown, folder: paper.folder, name: file.name)
                            }
                        }
                    } label: {
                        row(paper.label, detail: LibraryClear.sizeText(of: paper) + ", "
                            + LibraryClear.usersText(usedBy: paper.usedBy, usedHere: paper.usedHere,
                                                     usersUnknown: paper.usersUnknown),
                            button: "Remove Paper…") {
                            ask(paper.label, usedBy: paper.usedBy, usedHere: paper.usedHere,
                                usersUnknown: paper.usersUnknown, folder: paper.folder, name: nil)
                        }
                    }
                }
                if let problems = LibraryClear.problemsText(listing.problems) {
                    Text(problems)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .alert("Remove from the Paper Library",
               isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { removal in
            Button("Remove", role: .destructive) { Task { await remove(removal) } }
            Button("Keep It", role: .cancel) {}
        } message: { removal in
            Text(removal.question)
        }
    }

    /// One line of the list: what it is, its size and users, and its button.
    private func row(_ title: String, detail: String, button: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(title).textSelection(.enabled)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(button, action: action).disabled(busy || working)
        }
    }

    /// Ask before removing `what`, naming who else uses it.
    private func ask(_ what: String, usedBy: [String], usedHere: Bool, usersUnknown: Bool,
                     folder: String, name: String?) {
        note = nil
        pending = Removal(what: what, question: LibraryClear.removeQuestion(what: what, usedBy: usedBy,
                                                                            usedHere: usedHere,
                                                                            usersUnknown: usersUnknown),
                          folder: folder, name: name)
    }

    /// Read the library's papers; on failure the list shown goes, since it
    /// may be out of date.
    private func load() async {
        working = true
        switch await LibraryController.listLibrary(access) {
        case let .success(read):
            listing = read
            failure = nil
        case let .failure(why):
            listing = nil
            failure = why.description
        }
        working = false
    }

    /// Run the confirmed removal, read the list again, then say what the
    /// removal did; its failures are shown with the reread's own, if any.
    private func remove(_ removal: Removal) async {
        working = true
        let done = await LibraryController.removeFromLibrary(access, folder: removal.folder, name: removal.name)
        await load()
        if done.removed { note = BioMedLitConstants.libraryClearRemoved(what: removal.what) }
        let failures = [failure].compactMap { $0 } + done.failures
        failure = failures.isEmpty ? nil : failures.joined(separator: "\n")
        await changed()
    }
}
#endif
