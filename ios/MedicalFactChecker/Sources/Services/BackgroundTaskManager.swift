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

import Foundation
import os.log
#if os(iOS)
import UIKit
import BackgroundTasks
#endif

// MARK: - Notification Names

extension Notification.Name {
    /// Posted when background task is about to expire.
    ///
    /// Listeners should immediately save state and prepare for suspension.
    static let backgroundTaskExpiring = Notification.Name("backgroundTaskExpiring")

    /// Posted when app moves to background.
    ///
    /// Listeners can use this to checkpoint state proactively.
    static let appWillBackground = Notification.Name("appWillBackground")

    /// Posted when app returns to foreground.
    ///
    /// Listeners can use this to refresh state or resume work.
    static let appDidForeground = Notification.Name("appDidForeground")

    /// Posted when background recovery task runs.
    ///
    /// Listeners can use this for cleanup or state verification.
    static let backgroundRecoveryTask = Notification.Name("backgroundRecoveryTask")
}

// MARK: - BackgroundTaskManager

/// Manages background task registration and lifecycle for the app.
///
/// Provides centralized handling of:
/// - `beginBackgroundTask` for extended execution when entering background (iOS)
/// - Scene phase transitions and state preservation
/// - BGProcessingTask registration for recovery operations (iOS)
///
/// On macOS, background processing is always available so this manager
/// primarily posts notifications for lifecycle events.
///
/// ## Usage
///
/// ```swift
/// // In app initialization (iOS only):
/// await BackgroundTaskManager.shared.registerBackgroundTasks()
///
/// // On scene phase changes:
/// await BackgroundTaskManager.shared.didEnterBackground()
/// await BackgroundTaskManager.shared.willEnterForeground()
/// ```
///
/// ## Notifications
///
/// The manager posts notifications for lifecycle events:
/// - `.backgroundTaskExpiring` - Background time about to end (iOS)
/// - `.appWillBackground` - App moving to background
/// - `.appDidForeground` - App returning to foreground
actor BackgroundTaskManager {

    // MARK: - Singleton

    static let shared = BackgroundTaskManager()

    // MARK: - Constants

    /// Identifier for the background processing task.
    static let recoveryTaskIdentifier = "com.bmlibrarian.factchecker.recovery"

    // MARK: - Properties

    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "BackgroundTaskManager"
    )

    #if os(iOS)
    /// Current background task identifier (if active).
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Whether the app is currently backgrounded.
    private(set) var isBackgrounded = false

    /// Whether there is active work that should continue in background.
    private var hasActiveWork = false

    // MARK: - Initialization

    private init() {}

    // MARK: - Background Task Registration

    /// Register background task handlers with the system.
    ///
    /// Call this early in app launch to enable background processing support.
    /// Registration must happen before the app finishes launching.
    ///
    /// On macOS, this is a no-op since background processing is unrestricted.
    func registerBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.recoveryTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            Task {
                await self?.handleRecoveryTask(processingTask)
            }
        }

        logger.info("Registered background task: \(Self.recoveryTaskIdentifier)")
        #else
        logger.debug("Background task registration not needed on macOS")
        #endif
    }

    // MARK: - Scene Phase Handling

    /// Notify that the app is moving to background.
    ///
    /// Requests extended execution time and triggers checkpoint notifications.
    /// Call this from the app's scene phase change handler.
    func didEnterBackground() async {
        isBackgrounded = true

        logger.info("App entering background")

        // Notify listeners to checkpoint state
        await MainActor.run {
            NotificationCenter.default.post(name: .appWillBackground, object: nil)
        }

        #if os(iOS)
        // Request extended background execution
        await beginBackgroundTask()

        // Schedule recovery task if we have active work
        if hasActiveWork {
            scheduleRecoveryTask()
        }
        #endif
    }

    /// Notify that the app is returning to foreground.
    ///
    /// Ends any active background task and posts foreground notification.
    /// Call this from the app's scene phase change handler.
    func willEnterForeground() async {
        isBackgrounded = false

        logger.info("App entering foreground")

        #if os(iOS)
        await endBackgroundTaskIfNeeded()
        #endif

        // Notify listeners that app is active again
        await MainActor.run {
            NotificationCenter.default.post(name: .appDidForeground, object: nil)
        }
    }

    /// Mark whether there is active work that should continue in background.
    ///
    /// Call this when workflow starts/stops to enable background scheduling.
    ///
    /// - Parameter active: True if there is work in progress.
    func setActiveWork(_ active: Bool) {
        hasActiveWork = active
        logger.debug("Active work state: \(active)")
    }

    // MARK: - Extended Background Execution (iOS)

    #if os(iOS)
    /// Request extended background execution time.
    ///
    /// iOS typically grants 30 seconds to 3 minutes of additional execution
    /// time when the app moves to background. Use this time to finish
    /// in-progress work or checkpoint state.
    private func beginBackgroundTask() async {
        guard backgroundTaskID == .invalid else {
            logger.debug("Background task already active")
            return
        }

        backgroundTaskID = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "FactCheckContinuation") { [weak self] in
                Task {
                    await self?.handleBackgroundTaskExpiration()
                }
            }
        }

        if backgroundTaskID == .invalid {
            logger.warning("Unable to begin background task - system denied request")
        } else {
            logger.info("Background task started: \(self.backgroundTaskID.rawValue)")

            // Log remaining background time
            await logRemainingBackgroundTime()
        }
    }

    /// Log the remaining background execution time.
    private func logRemainingBackgroundTime() async {
        let remaining = await MainActor.run {
            UIApplication.shared.backgroundTimeRemaining
        }

        if remaining < Double.infinity {
            logger.info("Remaining background time: \(String(format: "%.1f", remaining)) seconds")
        } else {
            logger.info("Background time: unlimited (foreground)")
        }
    }

    /// Called when background time is about to expire.
    ///
    /// Posts `.backgroundTaskExpiring` notification so listeners can
    /// immediately save state before the app is suspended.
    private func handleBackgroundTaskExpiration() async {
        logger.warning("Background task expiring - forcing immediate checkpoint")

        // Notify workflow to save state immediately
        await MainActor.run {
            NotificationCenter.default.post(name: .backgroundTaskExpiring, object: nil)
        }

        await endBackgroundTaskIfNeeded()
    }

    /// End the active background task if one exists.
    private func endBackgroundTaskIfNeeded() async {
        guard backgroundTaskID != .invalid else { return }

        let taskID = backgroundTaskID
        backgroundTaskID = .invalid

        await MainActor.run {
            UIApplication.shared.endBackgroundTask(taskID)
        }

        logger.info("Background task ended: \(taskID.rawValue)")
    }
    #endif

    // MARK: - BGProcessingTask (iOS)

    #if os(iOS)
    /// Schedule a recovery task for incomplete sessions.
    ///
    /// Called when app enters background with unfinished work. The system
    /// will run this task when conditions are favorable (on power, good
    /// network, etc.).
    private func scheduleRecoveryTask() {
        let request = BGProcessingTaskRequest(identifier: Self.recoveryTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false

        // Request to run within 15 minutes if possible
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled recovery task for earliest: \(request.earliestBeginDate?.description ?? "now")")
        } catch BGTaskScheduler.Error.notPermitted {
            logger.error("BGTask not permitted - check Info.plist configuration")
        } catch BGTaskScheduler.Error.tooManyPendingTaskRequests {
            logger.warning("Too many pending background task requests")
        } catch BGTaskScheduler.Error.unavailable {
            logger.warning("Background tasks unavailable on this device")
        } catch {
            logger.error("Failed to schedule recovery task: \(error.localizedDescription)")
        }
    }

    /// Handle the recovery background task.
    ///
    /// This runs when the system decides to give the app background time
    /// for recovery operations. Use for cleanup, checkpoint verification,
    /// or notifying the user about incomplete work.
    private func handleRecoveryTask(_ task: BGProcessingTask) async {
        logger.info("Recovery task started")

        // Set up expiration handler
        task.expirationHandler = { [logger] in
            logger.warning("Recovery task expired by system")
        }

        // Post notification for any listeners
        await MainActor.run {
            NotificationCenter.default.post(name: .backgroundRecoveryTask, object: nil)
        }

        // Mark task complete
        task.setTaskCompleted(success: true)
        logger.info("Recovery task completed")

        // Schedule next recovery if still needed
        if hasActiveWork {
            scheduleRecoveryTask()
        }
    }
    #endif

    // MARK: - Testing Support

    /// Cancel any pending background task requests.
    ///
    /// Used primarily for testing to clean up scheduled tasks.
    func cancelPendingTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.recoveryTaskIdentifier)
        logger.debug("Cancelled pending background tasks")
        #endif
    }
}
