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

/// A progress view component for displaying document processing status.
///
/// Shows a labeled progress bar with counts for completed, skipped, and failed
/// documents. Designed for use during scoring and citation extraction phases.
///
/// ## Features
///
/// - Linear progress bar with smooth animations
/// - Displays current/total count
/// - Shows skipped count (resumed from checkpoint)
/// - Shows failed count with error styling
/// - Adapts to light/dark mode
///
/// ## Example Usage
///
/// ```swift
/// ProcessingProgressView(
///     step: "Scoring",
///     current: 15,
///     total: 50,
///     skipped: 10,
///     failed: 2
/// )
/// ```
struct ProcessingProgressView: View {
    /// The processing step name (e.g., "Scoring", "Citations").
    let step: String

    /// Number of documents completed so far.
    let current: Int

    /// Total number of documents to process.
    let total: Int

    /// Number of documents skipped (restored from checkpoint).
    let skipped: Int

    /// Number of documents that failed processing.
    let failed: Int

    /// Computed progress fraction (0.0 to 1.0).
    private var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with step name and count
            HStack {
                Text(step.capitalized)
                    .font(.headline)
                Spacer()
                Text("\(current)/\(total)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Progress bar
            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.3), value: progressFraction)

            // Status indicators
            HStack(spacing: 16) {
                if skipped > 0 {
                    Label("\(skipped) skipped", systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if failed > 0 {
                    Label("\(failed) failed", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

/// A compact progress indicator for inline use.
///
/// Shows just the progress bar and percentage, suitable for
/// embedding in list rows or toolbar items.
struct CompactProgressView: View {
    /// Progress fraction (0.0 to 1.0).
    let progress: Double

    /// Optional label text.
    let label: String?

    init(progress: Double, label: String? = nil) {
        self.progress = progress
        self.label = label
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label = label {
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 60)

            Text("\(Int(progress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .trailing)
        }
    }
}

/// Combined progress view showing both scoring and citation phases.
///
/// Displays two progress bars stacked vertically with overall
/// completion percentage.
struct DualPhaseProgressView: View {
    /// Progress state for scoring phase.
    let scoringProgress: PhaseProgress

    /// Progress state for citation phase.
    let citationProgress: PhaseProgress

    /// Overall progress (0.0 to 1.0).
    private var overallProgress: Double {
        let totalWork = Double(scoringProgress.total + citationProgress.total)
        guard totalWork > 0 else { return 0 }
        let completedWork = Double(scoringProgress.completed + citationProgress.completed)
        return completedWork / totalWork
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Overall header
            HStack {
                Text("Processing Documents")
                    .font(.headline)
                Spacer()
                Text("\(Int(overallProgress * 100))% complete")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Scoring phase
            PhaseProgressRow(
                name: "Scoring",
                progress: scoringProgress,
                icon: "star.fill"
            )

            // Citation phase
            PhaseProgressRow(
                name: "Citations",
                progress: citationProgress,
                icon: "quote.bubble.fill"
            )
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(12)
    }
}

/// A single phase progress row for use in DualPhaseProgressView.
private struct PhaseProgressRow: View {
    let name: String
    let progress: PhaseProgress
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.accentColor)
                    .font(.caption)

                Text(name)
                    .font(.subheadline)

                Spacer()

                // Status badges
                HStack(spacing: 8) {
                    if progress.skipped > 0 {
                        Badge(count: progress.skipped, label: "skipped", color: .orange)
                    }
                    if progress.failed > 0 {
                        Badge(count: progress.failed, label: "failed", color: .red)
                    }

                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ProgressView(value: progress.progressFraction)
                .progressViewStyle(.linear)
                .animation(.easeInOut(duration: 0.3), value: progress.progressFraction)
        }
    }
}

/// A small badge showing count and label.
private struct Badge: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        Text("\(count) \(label)")
            .font(.caption2)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }
}

// MARK: - Previews

#Preview("Processing Progress") {
    VStack(spacing: 20) {
        ProcessingProgressView(
            step: "Scoring",
            current: 15,
            total: 50,
            skipped: 10,
            failed: 2
        )

        ProcessingProgressView(
            step: "Citations",
            current: 8,
            total: 20,
            skipped: 0,
            failed: 0
        )
    }
    .padding()
}

#Preview("Compact Progress") {
    VStack(spacing: 12) {
        CompactProgressView(progress: 0.75, label: "Scoring")
        CompactProgressView(progress: 0.33)
    }
    .padding()
}

#Preview("Dual Phase Progress") {
    DualPhaseProgressView(
        scoringProgress: PhaseProgress(
            step: "scoring",
            total: 50,
            completed: 35,
            skipped: 10,
            failed: 2
        ),
        citationProgress: PhaseProgress(
            step: "citation",
            total: 20,
            completed: 8,
            skipped: 0,
            failed: 1
        )
    )
    .padding()
}
