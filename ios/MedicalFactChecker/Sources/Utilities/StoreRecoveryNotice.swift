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

import SwiftUI

/// Tells the user, once, that the fact checks they had saved could not be opened.
///
/// The store is opened while the app is starting, before there is any window to
/// say so in, so ``StoreRecovery`` writes down what happened and the first view
/// to appear shows it. Without this the user meets an empty History and no
/// explanation, which is the reader-facing half of golden rule 8 (#285).
///
/// Shared by both platforms' root views, so what iOS and macOS say is the same
/// sentence.
struct StoreRecoveryNotice: ViewModifier {
    /// What the user has yet to be told, read once the view appears.
    @State private var message: String?

    func body(content: Content) -> some View {
        content
            .onAppear { message = StoreRecovery.pendingMessage() }
            .alert(
                "Your saved fact checks could not be opened",
                isPresented: Binding(
                    get: { message != nil },
                    set: { if !$0 { acknowledge() } }
                )
            ) {
                Button("OK", role: .cancel) { acknowledge() }
            } message: {
                Text(message ?? "")
            }
    }

    /// Forget the message, so the user is told once rather than at every launch.
    private func acknowledge() {
        StoreRecovery.clearPendingMessage()
        message = nil
    }
}

extension View {
    /// Show what became of a store that could not be opened, once.
    ///
    /// - Returns: The view, showing the pending message at its first appearance.
    func storeRecoveryNotice() -> some View {
        modifier(StoreRecoveryNotice())
    }
}
