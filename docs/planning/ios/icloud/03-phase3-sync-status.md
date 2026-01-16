# Phase 3: Sync Status & Conflict Handling

## Objective

Provide users with visibility into sync status and gracefully handle conflicts that occur when the same data is modified on multiple devices.

## Sync Status Indicators

### Task 3.1: Create Sync Status Monitor

**File:** `Sources/Services/SyncStatusMonitor.swift` (both platforms)

```swift
import Foundation
import SwiftData
import CloudKit
import Combine

/// Monitors and reports CloudKit sync status
@Observable
final class SyncStatusMonitor {
    /// Current sync state
    enum SyncState: Equatable {
        case idle
        case syncing
        case error(String)
        case offline
        case disabled
    }

    /// Current sync state
    private(set) var state: SyncState = .idle

    /// Last successful sync time
    private(set) var lastSyncTime: Date?

    /// Number of pending changes to upload
    private(set) var pendingUploadCount: Int = 0

    /// Number of changes to download
    private(set) var pendingDownloadCount: Int = 0

    /// Detailed error message if in error state
    private(set) var errorMessage: String?

    private var cancellables = Set<AnyCancellable>()
    private let container: CKContainer

    init() {
        self.container = CKContainer(identifier: CloudKitConfiguration.containerIdentifier)
        setupNotificationObservers()
        checkInitialState()
    }

    private func setupNotificationObservers() {
        // Monitor network reachability changes
        NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)
            .sink { [weak self] _ in
                self?.checkInitialState()
            }
            .store(in: &cancellables)

        // Monitor CloudKit account status changes
        NotificationCenter.default.publisher(for: CKContainer.didChangeAccountStatusNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshAccountStatus()
                }
            }
            .store(in: &cancellables)
    }

    private func checkInitialState() {
        guard CloudKitConfiguration.isSyncEnabled else {
            state = .disabled
            return
        }

        guard CloudKitConfiguration.isCloudAvailable else {
            state = .offline
            return
        }

        Task { @MainActor in
            await refreshAccountStatus()
        }
    }

    @MainActor
    private func refreshAccountStatus() async {
        let status = await CloudKitConfiguration.checkAccountStatus()

        switch status {
        case .available:
            state = .idle
        case .noAccount:
            state = .error("No iCloud account")
            errorMessage = "Sign in to iCloud in Settings to sync."
        case .restricted:
            state = .error("Restricted")
            errorMessage = "iCloud access is restricted on this device."
        case .temporarilyUnavailable:
            state = .offline
            errorMessage = "iCloud is temporarily unavailable."
        case .couldNotDetermine:
            state = .error("Unknown")
            errorMessage = "Could not determine iCloud status."
        @unknown default:
            state = .error("Unknown")
        }
    }

    /// Mark sync as in progress (call when making changes)
    func markSyncing() {
        guard state != .disabled && state != .offline else { return }
        state = .syncing
    }

    /// Mark sync as complete
    func markSyncComplete() {
        guard state == .syncing else { return }
        state = .idle
        lastSyncTime = Date()
    }

    /// Mark sync error
    func markSyncError(_ message: String) {
        state = .error(message)
        errorMessage = message
    }
}

extension CKContainer {
    static let didChangeAccountStatusNotification = Notification.Name("CKContainerDidChangeAccountStatus")
}
```

### Task 3.2: Create Sync Status Badge View

**File:** `Sources/Views/Components/SyncStatusBadge.swift` (both platforms)

```swift
import SwiftUI

/// Compact sync status indicator for toolbar/navigation
struct SyncStatusBadge: View {
    let monitor: SyncStatusMonitor

    var body: some View {
        HStack(spacing: 4) {
            statusIcon
            if case .syncing = monitor.state {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .help(statusTooltip)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch monitor.state {
        case .idle:
            Image(systemName: "checkmark.icloud")
                .foregroundStyle(.green)
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath.icloud")
                .foregroundStyle(.blue)
                .symbolEffect(.rotate)
        case .error:
            Image(systemName: "exclamationmark.icloud")
                .foregroundStyle(.red)
        case .offline:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.orange)
        case .disabled:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
        }
    }

    private var statusTooltip: String {
        switch monitor.state {
        case .idle:
            if let lastSync = monitor.lastSyncTime {
                return "Synced \(lastSync.formatted(.relative(presentation: .named)))"
            }
            return "iCloud sync active"
        case .syncing:
            return "Syncing..."
        case .error(let message):
            return "Sync error: \(message)"
        case .offline:
            return "Offline - changes will sync when online"
        case .disabled:
            return "iCloud sync disabled"
        }
    }
}
```

### Task 3.3: Detailed Sync Status View

For settings or a dedicated sync info screen:

**File:** `Sources/Views/Components/SyncStatusDetailView.swift` (both platforms)

```swift
import SwiftUI

/// Detailed sync status for settings or info panel
struct SyncStatusDetailView: View {
    let monitor: SyncStatusMonitor
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status row
            HStack {
                statusIcon
                VStack(alignment: .leading) {
                    Text(statusTitle)
                        .font(.headline)
                    if let subtitle = statusSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if case .error = monitor.state {
                    Button("Details") {
                        showingDetails = true
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Last sync time
            if let lastSync = monitor.lastSyncTime {
                HStack {
                    Text("Last synced:")
                        .foregroundStyle(.secondary)
                    Text(lastSync.formatted(.relative(presentation: .named)))
                }
                .font(.caption)
            }

            // Pending changes
            if monitor.pendingUploadCount > 0 || monitor.pendingDownloadCount > 0 {
                HStack {
                    if monitor.pendingUploadCount > 0 {
                        Label("\(monitor.pendingUploadCount) to upload", systemImage: "arrow.up.circle")
                    }
                    if monitor.pendingDownloadCount > 0 {
                        Label("\(monitor.pendingDownloadCount) to download", systemImage: "arrow.down.circle")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .alert("Sync Error", isPresented: $showingDetails) {
            Button("OK") { }
        } message: {
            Text(monitor.errorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch monitor.state {
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.title2)
        case .syncing:
            ProgressView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.title2)
        case .offline:
            Image(systemName: "wifi.slash")
                .foregroundStyle(.orange)
                .font(.title2)
        case .disabled:
            Image(systemName: "icloud.slash")
                .foregroundStyle(.secondary)
                .font(.title2)
        }
    }

    private var statusTitle: String {
        switch monitor.state {
        case .idle: return "Up to date"
        case .syncing: return "Syncing..."
        case .error: return "Sync error"
        case .offline: return "Offline"
        case .disabled: return "Sync disabled"
        }
    }

    private var statusSubtitle: String? {
        switch monitor.state {
        case .idle: return "All changes synced to iCloud"
        case .syncing: return "Uploading changes..."
        case .error(let msg): return msg
        case .offline: return "Changes will sync when online"
        case .disabled: return "Enable in Settings"
        }
    }
}
```

## Conflict Handling

### Task 3.4: Conflict Resolution Strategy

SwiftData with CloudKit uses **last-write-wins** by default. For this app, that's acceptable because:

1. Sessions are typically used by one person
2. Reports are generated, not collaboratively edited
3. Document scores are deterministic

However, we should notify users when conflicts occur.

**File:** `Sources/Services/ConflictNotifier.swift` (both platforms)

```swift
import Foundation
import UserNotifications

/// Notifies users of sync conflicts
final class ConflictNotifier {
    static let shared = ConflictNotifier()

    private init() {
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    /// Notify user that a conflict was resolved
    func notifyConflictResolved(itemType: String, resolution: String) {
        let content = UNMutableNotificationContent()
        content.title = "Sync Conflict Resolved"
        content.body = "\(itemType) was updated on another device. \(resolution)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    /// Post in-app notification for conflict
    func postConflictNotification(itemType: String, itemTitle: String) {
        NotificationCenter.default.post(
            name: .syncConflictOccurred,
            object: nil,
            userInfo: [
                "itemType": itemType,
                "itemTitle": itemTitle
            ]
        )
    }
}

extension Notification.Name {
    static let syncConflictOccurred = Notification.Name("syncConflictOccurred")
}
```

### Task 3.5: In-App Conflict Banner

Show a non-intrusive banner when conflicts are resolved:

**File:** `Sources/Views/Components/ConflictBanner.swift` (both platforms)

```swift
import SwiftUI

/// Banner showing recent sync conflict resolution
struct ConflictBanner: View {
    @State private var conflictInfo: ConflictInfo?
    @State private var isVisible = false

    struct ConflictInfo: Identifiable {
        let id = UUID()
        let itemType: String
        let itemTitle: String
    }

    var body: some View {
        Group {
            if isVisible, let info = conflictInfo {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Sync conflict resolved")
                            .font(.caption.weight(.semibold))
                        Text("\(info.itemType): \(info.itemTitle)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        withAnimation {
                            isVisible = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncConflictOccurred)) { notification in
            guard let userInfo = notification.userInfo,
                  let itemType = userInfo["itemType"] as? String,
                  let itemTitle = userInfo["itemTitle"] as? String else {
                return
            }

            conflictInfo = ConflictInfo(itemType: itemType, itemTitle: itemTitle)
            withAnimation {
                isVisible = true
            }

            // Auto-dismiss after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    isVisible = false
                }
            }
        }
    }
}
```

### Task 3.6: Integrate Status into Main Views

#### iOS ContentView

```swift
struct ContentView: View {
    @State private var syncMonitor = SyncStatusMonitor()

    var body: some View {
        ZStack(alignment: .top) {
            TabView {
                // Existing tabs...
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if CloudKitConfiguration.isSyncEnabled {
                        SyncStatusBadge(monitor: syncMonitor)
                    }
                }
            }

            ConflictBanner()
        }
        .environment(syncMonitor)
    }
}
```

#### macOS MacContentView

```swift
struct MacContentView: View {
    @State private var syncMonitor = SyncStatusMonitor()

    var body: some View {
        ZStack(alignment: .top) {
            // Existing content...

            ConflictBanner()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if CloudKitConfiguration.isSyncEnabled {
                    SyncStatusBadge(monitor: syncMonitor)
                }
            }
        }
        .environment(syncMonitor)
    }
}
```

## Error Recovery

### Task 3.7: Sync Error Recovery Actions

**File:** `Sources/Views/Components/SyncErrorRecoveryView.swift`

```swift
import SwiftUI

/// Provides recovery actions for sync errors
struct SyncErrorRecoveryView: View {
    let monitor: SyncStatusMonitor
    @Environment(\.openURL) private var openURL

    var body: some View {
        if case .error(let errorType) = monitor.state {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.icloud")
                    .font(.largeTitle)
                    .foregroundStyle(.red)

                Text("Sync Error")
                    .font(.headline)

                Text(monitor.errorMessage ?? "An unknown error occurred")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                // Recovery actions based on error type
                recoveryActions(for: errorType)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func recoveryActions(for errorType: String) -> some View {
        VStack(spacing: 12) {
            switch errorType {
            case "No iCloud account":
                Button("Open Settings") {
                    #if os(iOS)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                    #elseif os(macOS)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane") {
                        openURL(url)
                    }
                    #endif
                }
                .buttonStyle(.borderedProminent)

            case "Restricted":
                Text("Contact your administrator to enable iCloud access.")
                    .font(.caption)

            default:
                Button("Retry") {
                    Task {
                        // Trigger refresh
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
```

## Verification Steps

- [ ] Sync badge appears in toolbar when sync enabled
- [ ] Badge shows correct state (idle/syncing/error/offline)
- [ ] Tooltip/help text is accurate
- [ ] Conflict banner appears when conflicts resolved
- [ ] Conflict banner auto-dismisses
- [ ] Error recovery view shows appropriate actions
- [ ] Offline state detected correctly
- [ ] State updates when coming back online

## Files Created/Modified

| File | Platform | Status |
|------|----------|--------|
| `SyncStatusMonitor.swift` | Both | New |
| `SyncStatusBadge.swift` | Both | New |
| `SyncStatusDetailView.swift` | Both | New |
| `ConflictNotifier.swift` | Both | New |
| `ConflictBanner.swift` | Both | New |
| `SyncErrorRecoveryView.swift` | Both | New |
| `ContentView.swift` | iOS | Modified |
| `MacContentView.swift` | macOS | Modified |

## Next Phase

Proceed to [Phase 4: Full-Text & PDF Sync](04-phase4-fulltext-sync.md) to handle document storage in iCloud.
