# Phase 1: Core CloudKit Integration

## Objective

Enable SwiftData models to sync via CloudKit with minimal code changes, creating the foundation for cross-device data access.

## Prerequisites

### 1. CloudKit Container Setup (Apple Developer Portal)

1. Log in to [Apple Developer Portal](https://developer.apple.com/account/)
2. Navigate to **Certificates, Identifiers & Profiles** → **Identifiers**
3. Create a new **CloudKit Container**:
   - Identifier: `iCloud.com.hherb.MedicalFactChecker`
   - Description: "Medical Fact Checker Sync"
4. Associate container with both app identifiers (iOS and macOS)

### 2. Xcode Project Configuration

#### iOS Target (`MedicalFactChecker`)

1. Select target → **Signing & Capabilities**
2. Click **+ Capability** → Add **iCloud**
3. Check **CloudKit**
4. Select or create container: `iCloud.com.hherb.MedicalFactChecker`

This adds to `MedicalFactChecker.entitlements`:
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.hherb.MedicalFactChecker</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
```

#### macOS Target (`MedicalFactCheckerMac`)

Same process - add iCloud capability with CloudKit and the same container identifier.

Adds to `MedicalFactCheckerMac.entitlements`:
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.hherb.MedicalFactChecker</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudKit</string>
</array>
```

## Implementation

### Task 1.1: Create CloudKit Configuration Helper

Create a new utility to manage CloudKit configuration state.

**File:** `Sources/Utilities/CloudKitConfiguration.swift` (both platforms)

```swift
import Foundation
import SwiftData
import CloudKit

/// Manages CloudKit sync configuration and state
enum CloudKitConfiguration {

    /// CloudKit container identifier (must match entitlements)
    static let containerIdentifier = "iCloud.com.hherb.MedicalFactChecker"

    /// UserDefaults key for sync preference
    private static let syncEnabledKey = "icloud_sync_enabled"

    /// Whether iCloud sync is enabled by user preference
    static var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: syncEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: syncEnabledKey) }
    }

    /// Check if iCloud is available on this device
    static var isCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// Create ModelConfiguration based on current settings
    /// - Parameter schema: The SwiftData schema to use
    /// - Returns: Configured ModelConfiguration for SwiftData
    static func makeModelConfiguration(schema: Schema) -> ModelConfiguration {
        let useCloudKit = isSyncEnabled && isCloudAvailable

        return ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: useCloudKit ? .automatic : .none
        )
    }

    /// Check CloudKit account status
    /// - Returns: Current account status
    static func checkAccountStatus() async -> CKAccountStatus {
        do {
            return try await CKContainer(identifier: containerIdentifier).accountStatus()
        } catch {
            return .couldNotDetermine
        }
    }
}
```

### Task 1.2: Update iOS App Entry Point

**File:** `ios/MedicalFactChecker/Sources/App/MedicalFactCheckerApp.swift`

```swift
import SwiftUI
import SwiftData

@main
struct MedicalFactCheckerApp: App {
    let modelContainer: ModelContainer

    init() {
        // Register value transformer for [String] arrays
        StringArrayTransformer.register()

        let schema = Schema([
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self
        ])

        // Use CloudKit configuration helper
        let modelConfiguration = CloudKitConfiguration.makeModelConfiguration(schema: schema)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}
```

### Task 1.3: Update macOS App Entry Point

**File:** `macos/MedicalFactCheckerMac/Sources/App/MedicalFactCheckerMacApp.swift`

Apply the same changes as iOS:

```swift
import SwiftUI
import SwiftData

@main
struct MedicalFactCheckerMacApp: App {
    let modelContainer: ModelContainer

    init() {
        // Register value transformer for [String] arrays
        StringArrayTransformer.register()

        let schema = Schema([
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
            UsageRecord.self
        ])

        // Use CloudKit configuration helper
        let modelConfiguration = CloudKitConfiguration.makeModelConfiguration(schema: schema)

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MacContentView()
        }
        .modelContainer(modelContainer)

        #if os(macOS)
        Settings {
            MacSettingsView()
        }
        .modelContainer(modelContainer)
        #endif
    }
}
```

### Task 1.4: Model Compatibility Review

SwiftData models must be CloudKit-compatible. Review each model for:

#### CloudKit Requirements

1. **All properties must be optional OR have default values**
2. **No unique constraints** (CloudKit doesn't support them)
3. **Relationships must use standard patterns**

#### Model Audit

**FactCheckSession.swift** - Review needed:
```swift
@Model
final class FactCheckSession {
    var id: UUID = UUID()  // ✅ Has default
    var claim: String = "" // ✅ Has default
    var createdAt: Date = Date()  // ✅ Has default
    // ... check all properties
}
```

**Document.swift** - Review needed:
```swift
@Model
final class Document {
    var id: String = ""  // ✅ Has default
    var pmid: String = ""  // ✅ Has default
    var title: String = ""  // ✅ Has default
    var relevanceScore: Int? = nil  // ✅ Optional
    // ... check all properties
}
```

**Citation.swift** - Likely OK (simple model)

**EvidenceReport.swift** - Likely OK

**UsageRecord.swift** - Likely OK

### Task 1.5: Handle App Restart for Config Changes

Since `ModelContainer` is created at app launch, enabling/disabling sync requires app restart.

**Add to CloudKitConfiguration:**

```swift
/// Whether a restart is needed to apply sync changes
static var pendingConfigChange: Bool {
    get { UserDefaults.standard.bool(forKey: "icloud_pending_restart") }
    set { UserDefaults.standard.set(newValue, forKey: "icloud_pending_restart") }
}

/// Request sync setting change (requires restart)
static func requestSyncChange(enabled: Bool) {
    guard enabled != isSyncEnabled else { return }
    isSyncEnabled = enabled
    pendingConfigChange = true
}

/// Clear pending change flag (called at app launch)
static func clearPendingChange() {
    pendingConfigChange = false
}
```

## Verification Steps

### 1. Build and Run

- [ ] iOS app builds without errors
- [ ] macOS app builds without errors
- [ ] No CloudKit-related crashes at launch

### 2. CloudKit Dashboard

1. Open [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/)
2. Select your container
3. Verify record types are created:
   - `CD_FactCheckSession`
   - `CD_Document`
   - `CD_Citation`
   - `CD_EvidenceReport`
   - `CD_UsageRecord`

### 3. Basic Sync Test

1. Enable sync on iOS device
2. Create a new fact-check session
3. Check CloudKit Dashboard → **Records** → verify data appears
4. Enable sync on macOS
5. Verify session appears in History view

## Rollback Plan

If issues arise:

1. Set `CloudKitConfiguration.isSyncEnabled = false`
2. Users restart app
3. App runs in local-only mode
4. Data created while sync was enabled remains in CloudKit but is inaccessible

## Files Modified

| File | Platform | Changes |
|------|----------|---------|
| `MedicalFactCheckerApp.swift` | iOS | Use CloudKitConfiguration |
| `MedicalFactCheckerMacApp.swift` | macOS | Use CloudKitConfiguration |
| `CloudKitConfiguration.swift` | Both | New file |
| `MedicalFactChecker.entitlements` | iOS | Add iCloud capability |
| `MedicalFactCheckerMac.entitlements` | macOS | Add iCloud capability |

## Next Phase

Once core CloudKit integration is verified, proceed to [Phase 2: Settings UI](02-phase2-settings-ui.md) to add user controls.
