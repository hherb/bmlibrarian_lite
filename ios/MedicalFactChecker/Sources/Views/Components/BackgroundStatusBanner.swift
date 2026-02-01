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

// MARK: - Constants

/// Constants for background status banner layout.
private enum BackgroundBannerConstants {
    /// Corner radius for the banner container.
    static let cornerRadius: CGFloat = 12

    /// Opacity for the banner background.
    static let backgroundOpacity: Double = 0.1

    /// Icon size for the status indicator.
    static let iconSize: CGFloat = 24
}

// MARK: - BackgroundStatusBanner

/// Banner indicating that processing was paused due to app backgrounding.
///
/// Displays a message explaining why processing stopped and provides
/// a Resume button to continue from the last checkpoint.
///
/// ## Usage
///
/// ```swift
/// if workflow.wasPausedByBackground {
///     BackgroundStatusBanner(
///         message: "Processing paused when app was backgrounded",
///         onResume: {
///             Task { await workflow.resumeFromCheckpoint() }
///         }
///     )
/// }
/// ```
struct BackgroundStatusBanner: View {
    /// Message explaining why processing was paused.
    let message: String

    /// Callback when user taps Resume.
    let onResume: () -> Void

    /// Optional callback to dismiss without resuming.
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: "pause.circle.fill")
                .font(.system(size: BackgroundBannerConstants.iconSize))
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            // Message content
            VStack(alignment: .leading, spacing: 2) {
                Text("Processing Paused")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                if let onDismiss = onDismiss {
                    Button("Dismiss") {
                        onDismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Dismiss this notification without resuming")
                }

                Button("Resume") {
                    onResume()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityHint("Continue processing from where it stopped")
            }
        }
        .padding()
        .background(Color.orange.opacity(BackgroundBannerConstants.backgroundOpacity))
        .cornerRadius(BackgroundBannerConstants.cornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing paused. \(message)")
        .accessibilityHint("Tap Resume to continue processing")
    }
}

// MARK: - CompactBackgroundStatusBanner

/// A compact version of the background status banner for toolbar display.
///
/// Shows only an icon and brief text, suitable for embedding in
/// navigation bars or toolbars.
struct CompactBackgroundStatusBanner: View {
    /// Callback when tapped.
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "pause.circle.fill")
                    .foregroundColor(.orange)
                Text("Paused")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .accessibilityLabel("Processing was paused. Tap to view details.")
    }
}

// MARK: - BackgroundProgressBanner

/// Banner showing that processing is continuing in background.
///
/// Displayed briefly when app enters background to reassure user
/// that work will continue.
struct BackgroundProgressBanner: View {
    /// Progress message to display.
    let message: String

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                .scaleEffect(0.9)

            VStack(alignment: .leading, spacing: 2) {
                Text("Continuing in Background")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(BackgroundBannerConstants.cornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Processing continuing in background. \(message)")
    }
}

// MARK: - Preview

#Preview("Background Status Banner") {
    VStack(spacing: 16) {
        BackgroundStatusBanner(
            message: "App was backgrounded during document scoring. 15 of 30 documents completed.",
            onResume: { print("Resume tapped") },
            onDismiss: { print("Dismiss tapped") }
        )

        BackgroundStatusBanner(
            message: "Processing interrupted. Resume to continue.",
            onResume: { print("Resume tapped") }
        )

        BackgroundProgressBanner(
            message: "Scoring document 15 of 30..."
        )

        HStack {
            Text("Toolbar example:")
            Spacer()
            CompactBackgroundStatusBanner(onTap: { print("Compact tapped") })
        }
        .padding()
        #if os(iOS)
        .background(Color(UIColor.systemBackground))
        #else
        .background(Color(NSColor.windowBackgroundColor))
        #endif
    }
    .padding()
}

// MARK: - Platform Imports

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
