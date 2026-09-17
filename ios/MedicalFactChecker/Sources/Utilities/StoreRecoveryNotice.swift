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

/// The one message about the store, for the whole app.
///
/// App-scoped rather than per-view because the message is app-scoped: macOS
/// restores several windows of the same `WindowGroup`, and a copy held in each
/// window's own `@State` is told to the user once per window.
///
/// It is also what stops the message being thrown away unread. It is forgotten
/// only when ``acknowledge()`` is called, which only the alert's button does —
/// never SwiftUI dismissing the alert for reasons of its own.
@Observable
final class StoreRecoveryMessage {
    /// The app's message, read once when the app starts.
    static let shared = StoreRecoveryMessage()

    /// What the user has yet to be told, or `nil` on an ordinary launch.
    private(set) var pending: String?

    /// Where the message waits between launches.
    private let defaults: UserDefaults

    /// - Parameter defaults: Where the message was kept; the default is the
    ///   standard defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.pending = StoreRecovery.pendingMessage(in: defaults)
    }

    /// Forget the message, now that the user has read it.
    ///
    /// Called only from the alert's button, so a message the user never saw is
    /// still there to be shown again.
    func acknowledge() {
        pending = nil
        StoreRecovery.clearPendingMessage(in: defaults)
    }
}

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
    /// The message this view shows, app-scoped so it is shown once.
    let message: StoreRecoveryMessage

    func body(content: Content) -> some View {
        content
            .alert(
                StoreRecovery.noticeTitle,
                isPresented: Binding(
                    get: { message.pending != nil },
                    // Deliberately does nothing. SwiftUI drives this to `false`
                    // for reasons that are not the user reading it — a view torn
                    // down, or a sibling alert on the same view presented
                    // instead — and a message dropped then is the very silence
                    // #285 is about. Only the button below forgets it.
                    set: { _ in }
                )
            ) {
                Button("OK", role: .cancel) { message.acknowledge() }
            } message: {
                Text(message.pending ?? "")
            }
    }
}

extension View {
    /// Show what became of a store that could not be opened, once.
    ///
    /// - Parameter message: The message to show; the default is the app's.
    /// - Returns: The view, showing the pending message when there is one.
    func storeRecoveryNotice(_ message: StoreRecoveryMessage = .shared) -> some View {
        modifier(StoreRecoveryNotice(message: message))
    }
}
