# Phase 2: Settings & User Control

## Objective

Add user-facing controls for iCloud sync, allowing users to enable/disable sync and understand its status.

## Design Principles

1. **Opt-in by default**: Sync is disabled until user explicitly enables it
2. **Clear communication**: User understands what syncs and what doesn't
3. **Graceful degradation**: Handle cases where iCloud is unavailable
4. **No data loss**: Disabling sync doesn't delete local or cloud data

## Implementation

### Task 2.1: Add Sync Settings to AppSettings

**File:** `Sources/Models/AppSettings.swift` (both platforms)

Add iCloud-related properties:

```swift
// MARK: - iCloud Sync Settings

/// Whether iCloud sync is enabled
var iCloudSyncEnabled: Bool {
    get { CloudKitConfiguration.isSyncEnabled }
    set {
        CloudKitConfiguration.requestSyncChange(enabled: newValue)
        objectWillChange.send()
    }
}

/// Whether iCloud is available on this device
var iCloudAvailable: Bool {
    CloudKitConfiguration.isCloudAvailable
}

/// Whether app needs restart to apply sync changes
var syncChangesPending: Bool {
    CloudKitConfiguration.pendingConfigChange
}
```

### Task 2.2: Create iCloud Settings Section (iOS)

**File:** `ios/MedicalFactChecker/Sources/Views/Settings/ICloudSettingsSection.swift`

```swift
import SwiftUI
import CloudKit

/// Settings section for iCloud sync configuration
struct ICloudSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var showingRestartAlert = false
    @State private var showingDisableConfirmation = false

    var body: some View {
        Section {
            // Main toggle
            Toggle(isOn: Binding(
                get: { settings.iCloudSyncEnabled },
                set: { newValue in
                    if newValue {
                        enableSync()
                    } else {
                        showingDisableConfirmation = true
                    }
                }
            )) {
                Label("Sync with iCloud", systemImage: "icloud")
            }
            .disabled(!settings.iCloudAvailable)

            // Status indicator
            if settings.iCloudSyncEnabled {
                HStack {
                    Text("Status")
                    Spacer()
                    statusView
                }
            }

            // Pending restart notice
            if settings.syncChangesPending {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Restart app to apply changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("iCloud")
        } footer: {
            Text("Sync your fact-check sessions, reports, and documents across all your Apple devices. API keys are never synced.")
        }
        .task {
            accountStatus = await CloudKitConfiguration.checkAccountStatus()
        }
        .alert("Restart Required", isPresented: $showingRestartAlert) {
            Button("OK") { }
        } message: {
            Text("Please restart the app to enable iCloud sync.")
        }
        .confirmationDialog(
            "Disable iCloud Sync?",
            isPresented: $showingDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disable Sync", role: .destructive) {
                disableSync()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your data will remain on this device and in iCloud, but changes won't sync between devices.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch accountStatus {
        case .available:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .noAccount:
            Label("No iCloud Account", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        case .restricted:
            Label("Restricted", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .temporarilyUnavailable:
            Label("Temporarily Unavailable", systemImage: "clock.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .couldNotDetermine:
            ProgressView()
                .scaleEffect(0.7)
        @unknown default:
            Label("Unknown", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private func enableSync() {
        settings.iCloudSyncEnabled = true
        showingRestartAlert = true
    }

    private func disableSync() {
        settings.iCloudSyncEnabled = false
        showingRestartAlert = true
    }
}
```

### Task 2.3: Create iCloud Settings Section (macOS)

**File:** `macos/MedicalFactCheckerMac/Sources/Views/Settings/ICloudSettingsSection.swift`

```swift
import SwiftUI
import CloudKit

/// Settings section for iCloud sync configuration (macOS)
struct ICloudSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var accountStatus: CKAccountStatus = .couldNotDetermine
    @State private var showingRestartAlert = false
    @State private var showingDisableConfirmation = false

    var body: some View {
        GroupBox("iCloud Sync") {
            VStack(alignment: .leading, spacing: 12) {
                // Main toggle
                Toggle(isOn: Binding(
                    get: { settings.iCloudSyncEnabled },
                    set: { newValue in
                        if newValue {
                            enableSync()
                        } else {
                            showingDisableConfirmation = true
                        }
                    }
                )) {
                    HStack {
                        Image(systemName: "icloud")
                        Text("Sync with iCloud")
                    }
                }
                .disabled(!settings.iCloudAvailable)

                // Unavailable notice
                if !settings.iCloudAvailable {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("iCloud is not available. Sign in to iCloud in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Status when enabled
                if settings.iCloudSyncEnabled && settings.iCloudAvailable {
                    Divider()
                    HStack {
                        Text("Status:")
                            .foregroundStyle(.secondary)
                        statusView
                    }
                }

                // Pending restart notice
                if settings.syncChangesPending {
                    Divider()
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Restart the app to apply changes")
                            .font(.caption)
                    }
                }

                Divider()

                Text("Sync your fact-check sessions, reports, and documents across all your Apple devices. API keys are stored securely on each device and are never synced.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .task {
            accountStatus = await CloudKitConfiguration.checkAccountStatus()
        }
        .alert("Restart Required", isPresented: $showingRestartAlert) {
            Button("OK") { }
        } message: {
            Text("Please quit and reopen the app to apply iCloud sync changes.")
        }
        .confirmationDialog(
            "Disable iCloud Sync?",
            isPresented: $showingDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disable Sync", role: .destructive) {
                disableSync()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Your data will remain on this Mac and in iCloud, but changes won't sync between devices.")
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch accountStatus {
        case .available:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Connected")
            }
        case .noAccount:
            HStack(spacing: 4) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text("No iCloud Account")
            }
        case .restricted:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Restricted")
            }
        case .temporarilyUnavailable:
            HStack(spacing: 4) {
                Image(systemName: "clock.fill")
                    .foregroundStyle(.orange)
                Text("Temporarily Unavailable")
            }
        case .couldNotDetermine:
            ProgressView()
                .scaleEffect(0.7)
        @unknown default:
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle.fill")
                Text("Unknown")
            }
        }
    }

    private func enableSync() {
        settings.iCloudSyncEnabled = true
        showingRestartAlert = true
    }

    private func disableSync() {
        settings.iCloudSyncEnabled = false
        showingRestartAlert = true
    }
}
```

### Task 2.4: Integrate into Settings Views

#### iOS: Update SettingsView.swift

Add the iCloud section to the existing settings form:

```swift
// In SettingsView.swift body
Form {
    // Existing sections...

    ICloudSettingsSection()  // Add this

    // Rest of existing sections...
}
```

#### macOS: Update MacSettingsView.swift

Add the iCloud section:

```swift
// In MacSettingsView.swift body
VStack(alignment: .leading, spacing: 16) {
    // Existing sections...

    ICloudSettingsSection()  // Add this

    // Rest of existing sections...
}
```

### Task 2.5: Optional - Sync User Preferences

For users who want settings to sync (model, thresholds, etc.), use `NSUbiquitousKeyValueStore`:

**File:** `Sources/Utilities/CloudPreferences.swift` (both platforms)

```swift
import Foundation

/// Manages user preferences that sync via iCloud Key-Value Store
/// Note: Limited to 1MB total, 1024 keys max
final class CloudPreferences {
    static let shared = CloudPreferences()

    private let store = NSUbiquitousKeyValueStore.default

    private init() {
        // Register for external change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storeDidChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store
        )
        // Trigger initial sync
        store.synchronize()
    }

    // MARK: - Synced Preferences

    var syncedBatchSize: Int? {
        get { store.object(forKey: "batch_size") as? Int }
        set {
            if let value = newValue {
                store.set(value, forKey: "batch_size")
            } else {
                store.removeObject(forKey: "batch_size")
            }
        }
    }

    var syncedMinScoreThreshold: Int? {
        get { store.object(forKey: "min_score_threshold") as? Int }
        set {
            if let value = newValue {
                store.set(value, forKey: "min_score_threshold")
            } else {
                store.removeObject(forKey: "min_score_threshold")
            }
        }
    }

    var syncedSelectedModel: String? {
        get { store.string(forKey: "selected_model") }
        set {
            if let value = newValue {
                store.set(value, forKey: "selected_model")
            } else {
                store.removeObject(forKey: "selected_model")
            }
        }
    }

    // MARK: - Change Handling

    @objc private func storeDidChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int else {
            return
        }

        switch reason {
        case NSUbiquitousKeyValueStoreServerChange,
             NSUbiquitousKeyValueStoreInitialSyncChange:
            // External changes - notify app to update UI
            NotificationCenter.default.post(
                name: .cloudPreferencesDidChange,
                object: self
            )

        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            // Over quota - log warning
            print("Warning: iCloud Key-Value Store quota exceeded")

        case NSUbiquitousKeyValueStoreAccountChange:
            // Account changed - may need to reset
            print("iCloud account changed")

        default:
            break
        }
    }
}

extension Notification.Name {
    static let cloudPreferencesDidChange = Notification.Name("cloudPreferencesDidChange")
}
```

### Task 2.6: First-Launch iCloud Prompt (Optional)

Show a one-time prompt during onboarding:

```swift
/// Shows iCloud sync option during first launch
struct ICloudOnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Binding var isPresented: Bool
    @State private var enableSync = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "icloud")
                .font(.system(size: 60))
                .foregroundStyle(.blue)

            Text("Sync with iCloud")
                .font(.title)
                .fontWeight(.semibold)

            Text("Keep your fact-check sessions and reports in sync across all your Apple devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Toggle("Enable iCloud Sync", isOn: $enableSync)
                .toggleStyle(.switch)
                .padding(.horizontal)

            Text("You can change this later in Settings. API keys are stored securely on each device and never synced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Continue") {
                if enableSync {
                    settings.iCloudSyncEnabled = true
                }
                isPresented = false
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}
```

## UI/UX Guidelines

### Toggle States

| State | UI Treatment |
|-------|--------------|
| Sync disabled | Toggle off, neutral appearance |
| Sync enabled, connected | Toggle on, green checkmark |
| Sync enabled, no account | Toggle on, red X, message to sign in |
| iCloud unavailable | Toggle disabled, explanation text |
| Restart pending | Orange warning, restart prompt |

### Information Disclosure

Always make clear:
- What syncs: Sessions, documents, citations, reports
- What doesn't sync: API keys (security), cached data
- Storage: Uses iCloud storage quota

## Verification Steps

- [ ] Toggle appears in iOS Settings
- [ ] Toggle appears in macOS Settings
- [ ] Toggle disabled when iCloud unavailable
- [ ] Status indicator shows correct state
- [ ] Restart alert appears when toggling
- [ ] Disable confirmation dialog works
- [ ] Footer text is clear and accurate

## Files Created/Modified

| File | Platform | Status |
|------|----------|--------|
| `ICloudSettingsSection.swift` | iOS | New |
| `ICloudSettingsSection.swift` | macOS | New |
| `CloudPreferences.swift` | Both | New (optional) |
| `ICloudOnboardingView.swift` | Both | New (optional) |
| `SettingsView.swift` | iOS | Modified |
| `MacSettingsView.swift` | macOS | Modified |
| `AppSettings.swift` | Both | Modified |

## Next Phase

Proceed to [Phase 3: Sync Status & Conflict Handling](03-phase3-sync-status.md) to add real-time sync indicators and handle conflicts.
