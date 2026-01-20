# Cross-Platform Sync Research for BMLibrarian Lite

## Executive Summary

This document researches options for synchronizing user data across iOS, macOS, Android, and Python desktop platforms without requiring custom server infrastructure. The recommended approach is a **file-based sync with CRDT semantics** using cloud storage providers (iCloud, Google Drive, Dropbox, or shared directories).

## Requirements

1. **No self-hosted server infrastructure** - use existing cloud storage services
2. **Support multiple providers**: iCloud, Google Drive, Dropbox, shared directories
3. **Offline-first** - work fully offline, sync when connected
4. **Collision-free** - handle concurrent edits without data loss
5. **Cross-platform** - iOS, macOS, Android, Python desktop

## Data Models to Sync

Based on codebase analysis, the following entities need synchronization:

| Entity | Description | Sync Priority |
|--------|-------------|---------------|
| FactCheckSession | Research questions/claims | High |
| Document | Literature search results with scores | High |
| Citation | Extracted evidence passages | High |
| EvidenceReport | Final reports with verdicts | High |
| UsageRecord | Token/cost tracking | Medium |
| AppSettings | User preferences (excluding API keys) | Low |

### Key Fields for Sync

All entities already use UUIDs, which is essential for distributed sync. Key timestamp fields (`createdAt`, `updatedAt`) exist across platforms.

## Option 1: File-Based Sync with CRDTs (Recommended)

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cloud Storage (iCloud/GDrive/Dropbox)        │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │  /BMLibrarian/                                               ││
│  │  ├── index.json              (workspace metadata)            ││
│  │  ├── devices/                                                ││
│  │  │   ├── {device_uuid}.json  (device registry)               ││
│  │  ├── changes/                                                ││
│  │  │   ├── {device_uuid}/      (per-device change log)         ││
│  │  │   │   ├── 000001.json                                     ││
│  │  │   │   ├── 000002.json                                     ││
│  │  │   │   └── ...                                             ││
│  │  └── snapshots/              (periodic full state snapshots) ││
│  │      └── {timestamp}_{device}.json                           ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │                    │                    │
    ┌────┴────┐         ┌────┴────┐         ┌────┴────┐
    │ iOS App │         │ Android │         │ Python  │
    │ SQLite  │         │  Room   │         │ SQLite  │
    └─────────┘         └─────────┘         └─────────┘
```

### File Naming Convention

```
{sequence_number}_{timestamp_ms}_{operation_type}.json

Example: 000142_1705772400000_session_create.json
```

- **sequence_number**: Monotonic counter per device (6 digits, zero-padded)
- **timestamp_ms**: Milliseconds since Unix epoch
- **operation_type**: Entity and operation (e.g., `session_create`, `document_score`)

### Change Log Format (JSON)

```json
{
  "version": 1,
  "deviceId": "550e8400-e29b-41d4-a716-446655440000",
  "sequence": 142,
  "timestamp": 1705772400000,
  "operation": {
    "type": "upsert",
    "entity": "session",
    "id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "data": {
      "claim": "Aspirin reduces heart attack risk",
      "pubmedQuery": "aspirin cardiovascular prevention",
      "createdAt": "2024-01-20T15:00:00Z",
      "updatedAt": "2024-01-20T15:30:00Z"
    },
    "vectorClock": {
      "550e8400-e29b-41d4-a716-446655440000": 142,
      "661f9511-f30c-52e5-b827-557766551111": 98
    }
  }
}
```

### CRDT Strategy: Last-Write-Wins Register (LWW)

For BMLibrarian's use case (single-user, multi-device), LWW is appropriate:

1. Each field has an associated timestamp
2. When merging, the field with the latest timestamp wins
3. Vector clocks track causality across devices

**Why LWW works here:**
- Single user won't have conflicting semantic intent
- Documents, scores, and reports are typically set once
- If user edits same session on two devices, most recent edit is likely intended

### Sync Protocol

```python
# Pseudocode for sync process

def sync():
    # 1. Discover changes from other devices
    remote_changes = list_remote_change_files()
    local_last_seen = get_local_watermarks()

    new_changes = []
    for device_id, files in remote_changes.items():
        if device_id == MY_DEVICE_ID:
            continue
        for file in files:
            if file.sequence > local_last_seen.get(device_id, 0):
                new_changes.append(read_json(file))

    # 2. Sort by vector clock / timestamp
    new_changes.sort(key=lambda c: (c.timestamp, c.deviceId))

    # 3. Apply changes with LWW merge
    for change in new_changes:
        apply_with_lww_merge(change)
        update_watermark(change.deviceId, change.sequence)

    # 4. Upload local pending changes
    for pending in get_pending_local_changes():
        upload_change_file(pending)
        mark_as_synced(pending)
```

### Advantages

- **Platform agnostic**: Works with any file sync service
- **No server required**: Uses existing cloud storage
- **Offline-first**: Full local database, sync when available
- **Auditable**: Change history preserved in files
- **Simple**: No complex networking or real-time protocols

### Disadvantages

- **Not real-time**: Sync latency depends on cloud provider
- **Storage growth**: Change logs accumulate (mitigate with compaction)
- **File conflicts**: Cloud provider may create conflict files (rare with per-device directories)

## Option 2: Automerge CRDT Library

[Automerge](https://automerge.github.io/) is a mature CRDT implementation with cross-platform support.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Automerge Core (Rust)                   │
├─────────────┬─────────────┬─────────────┬───────────────────────┤
│ Swift Binding│Kotlin Binding│ Python Binding│ automerge-repo    │
│ (automerge- │  (planned)   │ (automerge-  │ (sync protocol)     │
│    swift)   │              │    py)       │                     │
└─────────────┴─────────────┴─────────────┴───────────────────────┘
```

### Platform Support (as of 2025)

| Platform | Library | Status |
|----------|---------|--------|
| Swift/iOS/macOS | [automerge-swift](https://github.com/automerge/automerge-swift) | Stable |
| Python | [automerge-py](https://github.com/automerge/automerge-py) | Stable |
| Kotlin/Android | Bindings via Rust | In development |
| JavaScript | automerge (npm) | Stable |

### Usage Example (Swift)

```swift
import Automerge

// Create a document
var doc = Document()
let sessions = try! doc.putObject(obj: .ROOT, key: "sessions", ty: .List)
let session = try! doc.putObject(obj: sessions, index: 0, ty: .Map)
try! doc.put(obj: session, key: "claim", value: .String("Aspirin study"))

// Get sync message to send
let syncState = SyncState()
let message = doc.generateSyncMessage(state: syncState)

// Apply received sync message
try doc.receiveSyncMessage(state: syncState, message: receivedMessage)
```

### Sync via File Storage

Automerge documents can be saved and loaded as binary blobs:

```swift
// Save
let data = doc.save()
try data.write(to: cloudURL)

// Load and merge
let remoteData = try Data(contentsOf: cloudURL)
let remoteDoc = try Document(remoteData)
try doc.merge(other: remoteDoc)
```

### Advantages

- **Proven CRDT semantics**: Battle-tested merge algorithms
- **Rich data types**: Maps, lists, text, counters
- **Efficient sync**: Binary format, incremental sync messages
- **Cross-platform consistency**: Same Rust core everywhere

### Disadvantages

- **Kotlin support incomplete**: May need to wait or contribute
- **Learning curve**: Different mental model than SQL/ORM
- **Binary format**: Harder to debug than JSON
- **Migration required**: Need to move from existing data stores

## Option 3: PowerSync (Requires Service)

[PowerSync](https://www.powersync.com/) provides SQLite sync with a cloud service.

### How It Works

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│  PowerSync  │◀────│   Backend   │
│   SQLite    │     │   Service   │     │   Postgres  │
└─────────────┘     └─────────────┘     └─────────────┘
```

### Platform Support

| Platform | SDK Status |
|----------|------------|
| Flutter/Dart | Stable |
| JavaScript/React Native | Stable |
| Swift/iOS | Roadmap |
| Kotlin/Android | Roadmap |
| Python | Not available |

### Disadvantages for BMLibrarian

- **Requires backend database**: Needs Postgres/MongoDB server
- **Missing platform support**: No Python, Swift/Kotlin not ready
- **Not truly serverless**: Needs PowerSync service (self-hosted or cloud)

## Option 4: SQLiteChangesetSync (Apple Only)

[SQLiteChangesetSync](https://github.com/gerdemb/SQLiteChangesetSync) captures SQLite changesets for sync.

### Advantages

- Uses SQLite's built-in Session Extension
- Works with CloudKit for Apple platforms
- Git-like push/fetch model

### Disadvantages

- **Swift only**: No Android or Python support
- **CloudKit dependency**: Apple ecosystem only

## Option 5: Platform-Specific Sync (Not Recommended)

Each platform has its own sync solution:

| Platform | Native Sync |
|----------|-------------|
| iOS/macOS | CloudKit + SwiftData |
| Android | Google Drive API |
| Python | None built-in |

This fragments the user experience and requires three separate implementations.

## Recommended Implementation: Hybrid File-Based CRDT

### Phase 1: Core Infrastructure

1. **Define sync schema** (JSON Schema or Protocol Buffers)
   - Canonical representation of each entity
   - Version field for schema evolution
   - Vector clock fields for causality

2. **Implement change tracking**
   - Hook into local database writes
   - Generate change events with timestamps
   - Queue for upload

3. **Implement sync service abstraction**
   ```
   protocol SyncStorageProvider {
       func listFiles(path: String) -> [FileInfo]
       func readFile(path: String) -> Data
       func writeFile(path: String, data: Data)
       func watchForChanges(callback: (String) -> Void)
   }
   ```

4. **Implement providers**
   - `iCloudSyncProvider` (iOS/macOS)
   - `GoogleDriveSyncProvider` (Android, Python)
   - `DropboxSyncProvider` (all platforms)
   - `LocalFolderSyncProvider` (all platforms, for testing/LAN)

### Phase 2: Sync Engine

1. **Change log writer**: Serialize local changes to files
2. **Change log reader**: Discover and parse remote changes
3. **Merge engine**: Apply LWW or custom merge logic
4. **Compaction**: Periodically consolidate change logs

### Phase 3: Per-Platform Integration

| Platform | Local DB | Change Hook | Sync Trigger |
|----------|----------|-------------|--------------|
| iOS/macOS | SwiftData | `@ModelActor` observation | App launch, background refresh |
| Android | Room | Flow + DAO interceptors | WorkManager, app lifecycle |
| Python | SQLite | `post_commit` hook | CLI command, GUI button |

### File Structure for BMLibrarian

```
/BMLibrarian/
├── workspace.json                    # Workspace metadata
│   {
│     "version": 1,
│     "createdAt": "2024-01-20T00:00:00Z",
│     "encryption": "none"            # or "aes-256-gcm"
│   }
├── devices/
│   ├── iphone_abc123.json
│   │   {
│   │     "deviceId": "abc123...",
│   │     "name": "John's iPhone",
│   │     "platform": "ios",
│   │     "lastSeen": "2024-01-20T15:00:00Z"
│   │   }
│   └── pixel_def456.json
├── changes/
│   ├── abc123/                       # iPhone's changes
│   │   ├── 000001.json
│   │   ├── 000002.json
│   │   └── cursor.json               # Last processed sequence
│   └── def456/                       # Pixel's changes
│       ├── 000001.json
│       └── cursor.json
└── snapshots/                        # Optional full state snapshots
    └── 2024-01-20_abc123.json.gz
```

### Encryption (Optional)

For sensitive medical research data:

```json
{
  "encryption": "aes-256-gcm",
  "keyDerivation": "argon2id",
  "salt": "base64...",
  "encryptedData": "base64..."
}
```

User provides passphrase; each platform derives the same key.

## Implementation Roadmap

### Milestone 1: Foundation

- [ ] Define canonical JSON schema for all entities
- [ ] Implement `SyncStorageProvider` protocol
- [ ] Implement `LocalFolderSyncProvider` for testing
- [ ] Add change tracking to Python desktop app

### Milestone 2: iOS/macOS Sync

- [ ] Implement `iCloudSyncProvider` using iCloud Drive
- [ ] Add change tracking to SwiftData models
- [ ] Implement background sync with `BGTaskScheduler`

### Milestone 3: Android Sync

- [ ] Implement `GoogleDriveSyncProvider`
- [ ] Add change tracking to Room DAOs
- [ ] Implement WorkManager for background sync

### Milestone 4: Additional Providers

- [ ] Implement `DropboxSyncProvider`
- [ ] Implement `GoogleDriveSyncProvider` for Python
- [ ] Add sync UI to all platforms

### Milestone 5: Polish

- [ ] Implement encryption
- [ ] Add conflict resolution UI for edge cases
- [ ] Implement change log compaction
- [ ] Add sync status indicators

## Alternative: Automerge + File Sync

If Kotlin bindings mature, Automerge with file-based storage is an excellent alternative:

```swift
// Save Automerge document to cloud file
let data = doc.save()
try data.write(to: iCloudURL)

// On other device, load and merge
let remoteData = try Data(contentsOf: iCloudURL)
let remoteDoc = try Document(remoteData)
try localDoc.merge(other: remoteDoc)
let mergedData = localDoc.save()
try mergedData.write(to: iCloudURL)
```

This provides:
- Automatic CRDT merge semantics
- Efficient binary storage
- Cross-platform consistency (once Kotlin is ready)

## Sources

### CRDT & Sync Architecture
- [About CRDTs](https://crdt.tech/)
- [CRDT Implementations](https://crdt.tech/implementations)
- [Local-first software](https://www.inkandswitch.com/local-first/)
- [Resilient Sync for Local First](https://holtwick.de/en/blog/localfirst-resilient-sync)
- [CRDT with file sync (Tonsky)](https://tonsky.me/blog/crdt-filesync/)

### Automerge
- [Automerge CRDT](https://automerge.github.io/)
- [Introducing Automerge 2.0](https://automerge.org/blog/automerge-2/)
- [Automerge Swift (Swift Forums)](https://forums.swift.org/t/introducing-automerge-enable-collaborative-asynchronous-syncing-for-your-data-structures/67985)
- [Automerge Anywhere](https://automerge.org/blog/automerge-anywhere/)

### SQLite & CloudKit
- [SQLiteChangesetSync](https://github.com/gerdemb/SQLiteChangesetSync)
- [SQLiteData with CloudKit](https://www.pointfree.co/blog/posts/184-sqlitedata-1-0-an-alternative-to-swiftdata-with-cloudkit-sync-and-sharing)
- [CloudKit Guide (Toptal)](https://www.toptal.com/ios/sync-data-across-devices-with-cloudkit)

### PowerSync
- [PowerSync Overview](https://www.powersync.com/)
- [PowerSync Documentation](https://docs.powersync.com/intro/powersync-overview)

### UUID & Timestamps
- [RFC 9562 - UUIDs](https://www.rfc-editor.org/rfc/rfc9562.html)
- [Time-based UUIDs (Baeldung)](https://www.baeldung.com/java-generating-time-based-uuids)

### Frameworks
- [Expo Local-First Guide](https://docs.expo.dev/guides/local-first/)
- [Android Offline-First Guide](https://developer.android.com/topic/architecture/data-layer/offline-first)
- [Synk Kotlin CRDT Library](https://dev.to/charlietap/synking-all-the-things-with-crdts-local-first-development-3241)

## Conclusion

The **file-based sync with LWW CRDT semantics** approach best meets BMLibrarian's requirements:

1. **No server needed**: Uses existing cloud storage (iCloud, Google Drive, Dropbox)
2. **Truly cross-platform**: JSON files work everywhere
3. **Offline-first**: Local database is authoritative
4. **Collision-resistant**: Per-device change directories + LWW merge
5. **Auditable**: Full change history preserved
6. **Implementable incrementally**: Start with Python, add mobile platforms

The user's intuition about "simple text files with unique naming" is validated by modern local-first architecture patterns. Adding vector clocks and LWW semantics provides the collision avoidance needed for multi-device use.
