# Cross-Platform Sync Research for BMLibrarian Lite

## Executive Summary

This document researches options for synchronizing user data across iOS, macOS, Android, and Python desktop platforms without requiring custom server infrastructure. The recommended approach is a **file-based sync with CRDT semantics** using cloud storage providers (iCloud, Google Drive, Dropbox, or shared directories).

## Requirements

1. **No self-hosted server infrastructure** - use existing cloud storage services
2. **Support multiple providers**: iCloud, Google Drive, Dropbox, shared directories
3. **Offline-first** - work fully offline, sync when connected
4. **Collision-free** - handle concurrent edits without data loss
5. **Cross-platform** - iOS, macOS, Android, Python desktop
6. **Data integrity** - checksums to detect and prevent corruption
7. **Selective sync** - manually choose which records to sync per device
8. **Local-only deletion** - free space without affecting other devices

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

## Data Integrity Guarantees

Data integrity is critical to prevent corruption from incomplete transfers, storage failures, or transmission errors. This section defines a multi-layered integrity system.

### Integrity Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Integrity Layers                           │
├─────────────────────────────────────────────────────────────────┤
│  Layer 1: Per-File Checksum (SHA-256)                           │
│  - Every file includes its own checksum                         │
│  - Verified on read, before any processing                      │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Manifest File (Per-Device)                            │
│  - Lists all files with checksums and sizes                     │
│  - Allows detection of missing or extra files                   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: Chain Hash (Merkle-like)                              │
│  - Each change references previous change's hash                │
│  - Detects gaps or reordering in change log                     │
├─────────────────────────────────────────────────────────────────┤
│  Layer 4: Periodic Snapshots with Full Verification             │
│  - Complete state checksum for recovery validation              │
└─────────────────────────────────────────────────────────────────┘
```

### Layer 1: Per-File Checksums

Every sync file includes an integrity envelope:

```json
{
  "_integrity": {
    "version": 1,
    "algorithm": "sha256",
    "checksum": "a1b2c3d4e5f6...",
    "contentLength": 1234
  },
  "_content": {
    "version": 1,
    "deviceId": "550e8400-e29b-41d4-a716-446655440000",
    "sequence": 142,
    "timestamp": 1705772400000,
    "operation": { ... }
  }
}
```

**Checksum Calculation:**

```python
import hashlib
import json

def calculate_checksum(content: dict) -> str:
    """Calculate SHA-256 checksum of content."""
    # Canonical JSON: sorted keys, no extra whitespace, UTF-8
    canonical = json.dumps(content, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(canonical.encode('utf-8')).hexdigest()

def create_integrity_envelope(content: dict) -> dict:
    """Wrap content with integrity metadata."""
    canonical = json.dumps(content, sort_keys=True, separators=(',', ':'))
    return {
        "_integrity": {
            "version": 1,
            "algorithm": "sha256",
            "checksum": hashlib.sha256(canonical.encode('utf-8')).hexdigest(),
            "contentLength": len(canonical.encode('utf-8'))
        },
        "_content": content
    }

def verify_and_extract(envelope: dict) -> dict:
    """Verify integrity and return content, or raise exception."""
    integrity = envelope.get("_integrity")
    content = envelope.get("_content")

    if not integrity or not content:
        raise IntegrityError("Missing integrity envelope")

    if integrity["algorithm"] != "sha256":
        raise IntegrityError(f"Unsupported algorithm: {integrity['algorithm']}")

    canonical = json.dumps(content, sort_keys=True, separators=(',', ':'))
    actual_checksum = hashlib.sha256(canonical.encode('utf-8')).hexdigest()

    if actual_checksum != integrity["checksum"]:
        raise IntegrityError(
            f"Checksum mismatch: expected {integrity['checksum']}, "
            f"got {actual_checksum}"
        )

    if len(canonical.encode('utf-8')) != integrity["contentLength"]:
        raise IntegrityError("Content length mismatch")

    return content
```

**Swift Implementation:**

```swift
import CryptoKit
import Foundation

struct IntegrityEnvelope<T: Codable>: Codable {
    let integrity: IntegrityMetadata
    let content: T

    enum CodingKeys: String, CodingKey {
        case integrity = "_integrity"
        case content = "_content"
    }
}

struct IntegrityMetadata: Codable {
    let version: Int
    let algorithm: String
    let checksum: String
    let contentLength: Int
}

func calculateChecksum<T: Encodable>(_ content: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(content)
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
}

func verifyAndExtract<T: Decodable>(_ envelope: IntegrityEnvelope<T>) throws -> T {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let contentData = try encoder.encode(envelope.content)

    let actualChecksum = SHA256.hash(data: contentData)
        .compactMap { String(format: "%02x", $0) }.joined()

    guard actualChecksum == envelope.integrity.checksum else {
        throw IntegrityError.checksumMismatch(
            expected: envelope.integrity.checksum,
            actual: actualChecksum
        )
    }

    guard contentData.count == envelope.integrity.contentLength else {
        throw IntegrityError.lengthMismatch
    }

    return envelope.content
}
```

**Kotlin Implementation:**

```kotlin
import java.security.MessageDigest
import kotlinx.serialization.json.Json
import kotlinx.serialization.encodeToString

data class IntegrityMetadata(
    val version: Int,
    val algorithm: String,
    val checksum: String,
    val contentLength: Int
)

fun calculateChecksum(content: Any): String {
    val json = Json {
        prettyPrint = false
        encodeDefaults = true
    }
    val canonical = json.encodeToString(content)
    val digest = MessageDigest.getInstance("SHA-256")
    val hashBytes = digest.digest(canonical.toByteArray(Charsets.UTF_8))
    return hashBytes.joinToString("") { "%02x".format(it) }
}

fun <T> verifyAndExtract(envelope: IntegrityEnvelope<T>): T {
    val json = Json { prettyPrint = false }
    val contentJson = json.encodeToString(envelope.content)
    val actualChecksum = calculateChecksum(envelope.content)

    require(actualChecksum == envelope.integrity.checksum) {
        "Checksum mismatch: expected ${envelope.integrity.checksum}, got $actualChecksum"
    }

    require(contentJson.toByteArray(Charsets.UTF_8).size == envelope.integrity.contentLength) {
        "Content length mismatch"
    }

    return envelope.content
}
```

### Layer 2: Device Manifest

Each device maintains a manifest file listing all its change files:

```
/BMLibrarian/changes/{device_id}/manifest.json
```

```json
{
  "_integrity": {
    "version": 1,
    "algorithm": "sha256",
    "checksum": "...",
    "contentLength": 2048
  },
  "_content": {
    "deviceId": "550e8400-e29b-41d4-a716-446655440000",
    "lastUpdated": "2024-01-20T15:30:00Z",
    "headSequence": 142,
    "files": [
      {
        "sequence": 1,
        "filename": "000001_1705600000000_session_create.json",
        "checksum": "abc123...",
        "size": 512,
        "timestamp": 1705600000000
      },
      {
        "sequence": 2,
        "filename": "000002_1705600100000_document_score.json",
        "checksum": "def456...",
        "size": 1024,
        "timestamp": 1705600100000
      }
    ],
    "manifestChecksum": "xyz789..."
  }
}
```

The `manifestChecksum` is computed over all file entries, providing a quick way to verify the entire change log:

```python
def compute_manifest_checksum(files: list[dict]) -> str:
    """Compute checksum over all file checksums."""
    combined = ''.join(f['checksum'] for f in sorted(files, key=lambda x: x['sequence']))
    return hashlib.sha256(combined.encode('utf-8')).hexdigest()
```

### Layer 3: Chain Hash (Change Log Integrity)

Each change references the previous change's hash, creating an unbroken chain:

```json
{
  "_content": {
    "sequence": 142,
    "previousHash": "hash_of_change_141",
    "operation": { ... }
  }
}
```

**Verification:**

```python
def verify_change_chain(changes: list[dict]) -> bool:
    """Verify the integrity of the change chain."""
    if not changes:
        return True

    # First change has no previous
    if changes[0].get('previousHash') is not None:
        raise IntegrityError("First change should not have previousHash")

    for i in range(1, len(changes)):
        expected_hash = calculate_checksum(changes[i-1])
        actual_previous = changes[i].get('previousHash')

        if expected_hash != actual_previous:
            raise IntegrityError(
                f"Chain broken at sequence {changes[i]['sequence']}: "
                f"expected {expected_hash}, got {actual_previous}"
            )

    return True
```

**Benefits:**
- Detects missing changes (gap in chain)
- Detects reordered changes
- Detects tampering with historical changes
- Allows partial verification (only need to verify back to last known-good state)

### Layer 4: Snapshot Integrity

Periodic snapshots include a comprehensive integrity block:

```json
{
  "_integrity": {
    "version": 1,
    "algorithm": "sha256",
    "checksum": "...",
    "contentLength": 50000
  },
  "_content": {
    "snapshotId": "uuid",
    "deviceId": "...",
    "timestamp": "2024-01-20T00:00:00Z",
    "basedOnSequence": 142,
    "changeLogHash": "hash_of_manifest",
    "entityCounts": {
      "sessions": 15,
      "documents": 450,
      "citations": 120,
      "reports": 15
    },
    "entities": {
      "sessions": [ ... ],
      "documents": [ ... ],
      "citations": [ ... ],
      "reports": [ ... ]
    }
  }
}
```

### Handling Corrupt Data

When corruption is detected:

```python
class CorruptionHandler:
    def handle_corrupt_file(self, file_path: str, error: IntegrityError):
        """Handle a corrupt sync file."""

        # 1. Log the corruption
        self.log_corruption(file_path, error)

        # 2. Quarantine the corrupt file (don't delete - for forensics)
        quarantine_path = self.quarantine_file(file_path)

        # 3. Check if we can recover
        recovery_options = self.assess_recovery_options(file_path)

        if recovery_options.can_skip:
            # Non-critical file, skip and continue
            self.mark_as_skipped(file_path)
            return RecoveryResult.SKIPPED

        elif recovery_options.can_rebuild_from_snapshot:
            # Rebuild from last good snapshot
            self.rebuild_from_snapshot(recovery_options.snapshot_id)
            return RecoveryResult.REBUILT

        elif recovery_options.can_request_resend:
            # Request the source device to resend
            self.request_resend(file_path)
            return RecoveryResult.PENDING_RESEND

        else:
            # Unrecoverable - notify user
            self.notify_user_corruption(file_path, recovery_options)
            return RecoveryResult.FAILED

    def verify_full_state(self) -> IntegrityReport:
        """Full integrity verification of all sync data."""
        report = IntegrityReport()

        # Verify workspace.json
        report.add(self.verify_file("workspace.json"))

        # Verify all device manifests
        for device_dir in self.list_device_directories():
            manifest = self.verify_manifest(device_dir)
            report.add(manifest)

            # Verify all changes for this device
            for change_file in self.list_changes(device_dir):
                report.add(self.verify_change_file(change_file))

            # Verify chain integrity
            report.add(self.verify_chain(device_dir))

        # Verify snapshots
        for snapshot in self.list_snapshots():
            report.add(self.verify_snapshot(snapshot))

        return report
```

### Sync Protocol with Integrity

Updated sync protocol incorporating integrity checks:

```python
def sync_with_integrity():
    """Sync with full integrity verification."""

    # 1. Fetch remote manifest
    remote_manifests = fetch_remote_manifests()

    for device_id, manifest in remote_manifests.items():
        if device_id == MY_DEVICE_ID:
            continue

        # 2. Verify manifest integrity
        try:
            verified_manifest = verify_and_extract(manifest)
        except IntegrityError as e:
            handle_corrupt_manifest(device_id, e)
            continue

        # 3. Compare with local watermark
        local_watermark = get_watermark(device_id)

        # 4. Fetch and verify new changes
        for file_info in verified_manifest['files']:
            if file_info['sequence'] <= local_watermark:
                continue

            # Download file
            file_data = download_file(device_id, file_info['filename'])

            # Verify file checksum matches manifest
            if calculate_checksum(file_data) != file_info['checksum']:
                handle_corrupt_file(file_info['filename'], "Manifest mismatch")
                continue

            # Verify internal integrity
            try:
                change = verify_and_extract(file_data)
            except IntegrityError as e:
                handle_corrupt_file(file_info['filename'], e)
                continue

            # Verify chain (optional, for extra safety)
            if not verify_chain_link(change, local_watermark):
                handle_chain_break(device_id, change['sequence'])
                continue

            # Apply change
            apply_change(change)
            update_watermark(device_id, change['sequence'])

    # 5. Upload local changes with integrity
    for pending in get_pending_changes():
        envelope = create_integrity_envelope(pending)
        upload_with_retry(envelope)
        update_manifest()
```

### Integrity Constants

```python
# constants.py additions

# Integrity
INTEGRITY_ALGORITHM = "sha256"
INTEGRITY_VERSION = 1

# Corruption handling
QUARANTINE_DIR = ".quarantine"
MAX_RESEND_ATTEMPTS = 3
CORRUPTION_LOG_FILE = "corruption.log"

# Verification thresholds
FULL_VERIFY_INTERVAL_HOURS = 24
CHAIN_VERIFY_DEPTH = 100  # Verify last N changes on each sync
```

### Platform-Specific Notes

**iOS/macOS:**
- Use `CryptoKit.SHA256` for checksums
- Store quarantined files in app's `Caches` directory
- Use `OSLog` for corruption logging

**Android:**
- Use `java.security.MessageDigest` for SHA-256
- Store quarantined files in `context.cacheDir`
- Use `android.util.Log` for corruption logging

**Python:**
- Use `hashlib.sha256` for checksums
- Store quarantined files in `~/.bmlibrarian_lite/.quarantine`
- Use Python `logging` module

## Selective Sync & Storage Management

Users may have limited storage on some devices (e.g., 64GB phone vs 2TB desktop). The sync system must support:

1. **Selective sync** - manually choose which records to sync to a device
2. **Local-only deletion** - free up space without affecting other devices
3. **On-demand fetch** - download specific records when needed

### Sync Scope Model

Each device maintains a **sync scope** that defines what it wants:

```
/BMLibrarian/devices/{device_id}.json
```

```json
{
  "_integrity": { ... },
  "_content": {
    "deviceId": "iphone_abc123",
    "name": "John's iPhone",
    "platform": "ios",
    "lastSeen": "2024-01-20T15:00:00Z",
    "syncScope": {
      "mode": "selective",
      "sessions": {
        "mode": "whitelist",
        "ids": [
          "session-uuid-1",
          "session-uuid-2"
        ]
      },
      "maxLocalStorageMB": 500,
      "autoEvictOlderThanDays": 90
    }
  }
}
```

### Sync Scope Modes

| Mode | Description |
|------|-------------|
| `full` | Sync everything (default for desktops) |
| `selective` | Only sync whitelisted sessions |
| `recent` | Only sync sessions from last N days |
| `minimal` | Only sync metadata, fetch content on-demand |

### Record States

Each record on a device can be in one of these states:

```
┌─────────────────────────────────────────────────────────────────┐
│                      Record States                              │
├─────────────────────────────────────────────────────────────────┤
│  FULL         - Complete record with all content                │
│  STUB         - Metadata only, content available on-demand      │
│  EVICTED      - Was full, now stub (freed local storage)        │
│  LOCAL_ONLY   - Exists only on this device, not synced          │
│  DELETED_LOCAL- Deleted locally, still exists in cloud          │
└─────────────────────────────────────────────────────────────────┘
```

### Local Database Schema Extension

```sql
-- Add to each synced table
ALTER TABLE sessions ADD COLUMN sync_state TEXT DEFAULT 'full';
-- Values: 'full', 'stub', 'evicted', 'local_only', 'deleted_local'

ALTER TABLE sessions ADD COLUMN sync_scope TEXT DEFAULT 'synced';
-- Values: 'synced', 'local_only'

ALTER TABLE sessions ADD COLUMN evicted_at TIMESTAMP NULL;
ALTER TABLE sessions ADD COLUMN content_size_bytes INTEGER DEFAULT 0;
```

### Selective Sync Operations

#### 1. Add Session to Sync Scope

User manually selects a session to sync to their device:

```python
def add_to_sync_scope(session_id: str):
    """Add a session to this device's sync scope."""
    # Update local sync scope
    scope = get_local_sync_scope()
    scope['sessions']['ids'].append(session_id)
    save_sync_scope(scope)

    # Upload updated device config
    upload_device_config()

    # Fetch the session content
    fetch_session_content(session_id)
```

#### 2. Remove from Sync Scope (Keep in Cloud)

User removes a session from sync but keeps it in cloud:

```python
def remove_from_sync_scope(session_id: str, delete_local: bool = True):
    """Remove session from sync scope, optionally delete local copy."""
    # Update sync scope
    scope = get_local_sync_scope()
    scope['sessions']['ids'].remove(session_id)
    save_sync_scope(scope)

    if delete_local:
        # Convert to stub (keep metadata, delete content)
        evict_session_content(session_id)

    # Upload updated device config
    upload_device_config()

    # NOTE: Does NOT create a delete operation in change log
    # The session remains in cloud for other devices
```

#### 3. Evict Content (Free Local Storage)

Convert full records to stubs to free space:

```python
def evict_session_content(session_id: str):
    """Free local storage by removing content, keeping metadata."""
    session = get_session(session_id)

    # Store minimal metadata
    stub = {
        'id': session.id,
        'claim': session.claim,
        'created_at': session.created_at,
        'document_count': len(session.documents),
        'has_report': session.report is not None,
        'content_size_bytes': calculate_size(session)
    }

    # Delete content (documents, citations, full text, report)
    delete_session_content(session_id)

    # Update state
    update_session_state(session_id,
        sync_state='evicted',
        evicted_at=now()
    )

    # Keep stub for UI display
    save_session_stub(stub)
```

#### 4. Fetch On-Demand

When user opens an evicted/stub session:

```python
def fetch_session_on_demand(session_id: str) -> Session:
    """Fetch full session content from cloud."""
    if get_sync_state(session_id) == 'full':
        return get_session(session_id)

    # Find which device has the full content
    source_device = find_device_with_content(session_id)

    if source_device:
        # Fetch from that device's change log
        content = fetch_from_device(source_device, session_id)
    else:
        # Fetch from latest snapshot
        content = fetch_from_snapshot(session_id)

    # Store locally
    save_session_full(content)
    update_session_state(session_id, sync_state='full')

    return content
```

### Local-Only Deletion

Delete locally without propagating to other devices:

```python
def delete_local_only(session_id: str):
    """Delete session from this device only."""
    # Mark as deleted locally (don't create sync operation)
    update_session_state(session_id, sync_state='deleted_local')

    # Remove from local database
    delete_session_local(session_id)

    # Add to local exclusion list (prevent re-sync)
    add_to_local_exclusions(session_id)

    # NOTE: No change log entry created
    # Other devices still have the session
```

**Exclusion List:**

```json
{
  "localExclusions": {
    "sessions": ["session-uuid-deleted-locally"],
    "reason": {
      "session-uuid-deleted-locally": "user_deleted_local"
    }
  }
}
```

### Global Deletion (All Devices)

When user wants to delete everywhere:

```python
def delete_globally(session_id: str):
    """Delete session from all devices."""
    # Create delete operation in change log
    operation = {
        "type": "delete",
        "entity": "session",
        "id": session_id,
        "cascade": True,  # Also delete documents, citations, report
        "timestamp": now_ms(),
        "previousHash": get_previous_hash()
    }

    # Write to local change log
    write_change(operation)

    # Delete locally
    delete_session_local(session_id)

    # Upload change (will propagate to other devices)
    upload_pending_changes()
```

### Storage Management UI

```
┌─────────────────────────────────────────────────────────────────┐
│  Storage Management                                    [?] Help │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Local Storage: 450 MB / 500 MB limit                          │
│  ████████████████████████████████████░░░░░  90%                │
│                                                                 │
│  Cloud Storage: 2.3 GB (shared across devices)                  │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  Sessions on this device:                                       │
│                                                                 │
│  ☑ Aspirin cardiovascular study      125 MB   [Evict] [Delete] │
│    └─ 45 documents, report generated                            │
│                                                                 │
│  ☑ Metformin diabetes meta-analysis  230 MB   [Evict] [Delete] │
│    └─ 120 documents, report generated                           │
│                                                                 │
│  ☐ COVID vaccine efficacy (stub)      --      [Fetch] [Remove] │
│    └─ 89 documents (not downloaded)                             │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  Available in cloud (not on this device):                       │
│                                                                 │
│  ☐ Statin muscle pain review         340 MB   [Add to device]  │
│  ☐ Blood pressure medication study   180 MB   [Add to device]  │
│                                                                 │
├─────────────────────────────────────────────────────────────────┤
│  [Auto-manage storage]  [Evict oldest]  [Sync settings]        │
└─────────────────────────────────────────────────────────────────┘
```

### Auto-Eviction Policy

For devices with limited storage:

```json
{
  "syncScope": {
    "mode": "selective",
    "autoEviction": {
      "enabled": true,
      "maxLocalStorageMB": 500,
      "evictionStrategy": "lru",
      "keepMinimumSessions": 5,
      "neverEvict": ["session-uuid-pinned"],
      "evictOlderThanDays": 90
    }
  }
}
```

**Eviction Strategies:**

| Strategy | Description |
|----------|-------------|
| `lru` | Least Recently Used - evict oldest accessed first |
| `largest` | Evict largest sessions first |
| `oldest` | Evict by creation date |
| `no_report` | Evict sessions without reports first |

```python
def auto_evict_if_needed():
    """Automatically evict content if storage limit exceeded."""
    current_size = get_local_storage_size()
    max_size = get_max_storage_size()

    if current_size <= max_size:
        return

    sessions = get_sessions_by_eviction_priority()
    pinned = get_pinned_sessions()

    for session in sessions:
        if session.id in pinned:
            continue

        if session.sync_state == 'evicted':
            continue

        evict_session_content(session.id)
        current_size = get_local_storage_size()

        if current_size <= max_size * 0.9:  # 90% threshold
            break
```

### Sync Protocol with Selective Sync

Updated sync to respect device scope:

```python
def sync_with_scope():
    """Sync respecting this device's sync scope."""
    scope = get_local_sync_scope()
    exclusions = get_local_exclusions()

    for device_id, manifest in fetch_remote_manifests().items():
        if device_id == MY_DEVICE_ID:
            continue

        for change in get_new_changes(device_id, manifest):
            # Skip if entity is excluded locally
            if is_excluded(change['entity'], change['id'], exclusions):
                update_watermark(device_id, change['sequence'])
                continue

            # Check if in sync scope
            if not is_in_scope(change['entity'], change['id'], scope):
                # Store as stub only
                if change['type'] == 'upsert':
                    store_as_stub(change)
                update_watermark(device_id, change['sequence'])
                continue

            # Full sync for in-scope entities
            apply_change(change)
            update_watermark(device_id, change['sequence'])
```

### Integrity Considerations

Selective sync must maintain integrity guarantees:

1. **Stubs have checksums too** - metadata stub has its own integrity envelope
2. **Exclusions are local** - not synced, stored in local config
3. **Chain integrity preserved** - watermarks advance even for skipped changes
4. **On-demand fetch verifies** - fetched content verified against original checksum

```python
def fetch_and_verify(session_id: str, expected_checksum: str) -> dict:
    """Fetch content and verify against known checksum."""
    content = fetch_session_content(session_id)
    actual_checksum = calculate_checksum(content)

    if actual_checksum != expected_checksum:
        raise IntegrityError(
            f"Fetched content checksum mismatch for {session_id}"
        )

    return content
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

### Milestone 1: Foundation & Integrity Core

- [ ] Define canonical JSON schema for all entities
- [ ] Implement integrity envelope (SHA-256 checksums)
- [ ] Implement `verify_and_extract()` for all platforms
- [ ] Create `IntegrityError` exception hierarchy
- [ ] Implement `SyncStorageProvider` protocol
- [ ] Implement `LocalFolderSyncProvider` for testing
- [ ] Add change tracking to Python desktop app

### Milestone 2: iOS/macOS Sync

- [ ] Implement `iCloudSyncProvider` using iCloud Drive
- [ ] Add change tracking to SwiftData models
- [ ] Implement integrity verification (CryptoKit)
- [ ] Implement background sync with `BGTaskScheduler`

### Milestone 3: Android Sync

- [ ] Implement `GoogleDriveSyncProvider`
- [ ] Add change tracking to Room DAOs
- [ ] Implement integrity verification (MessageDigest)
- [ ] Implement WorkManager for background sync

### Milestone 4: Advanced Integrity

- [ ] Implement device manifest with file checksums
- [ ] Implement chain hash verification
- [ ] Add corruption quarantine and recovery
- [ ] Implement periodic full-state verification
- [ ] Add integrity status to sync UI

### Milestone 5: Selective Sync & Storage Management

- [ ] Implement sync scope model (full, selective, recent, minimal)
- [ ] Add record states (full, stub, evicted, local_only, deleted_local)
- [ ] Implement local-only deletion with exclusion list
- [ ] Implement on-demand content fetch
- [ ] Add auto-eviction policies (LRU, largest, oldest)
- [ ] Build storage management UI for all platforms

### Milestone 6: Additional Providers

- [ ] Implement `DropboxSyncProvider`
- [ ] Implement `GoogleDriveSyncProvider` for Python
- [ ] Add sync UI to all platforms

### Milestone 7: Polish

- [ ] Implement encryption (AES-256-GCM)
- [ ] Add conflict resolution UI for edge cases
- [ ] Implement change log compaction
- [ ] Add sync status indicators
- [ ] Comprehensive integrity test suite

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
6. **Data integrity guaranteed**: Multi-layer checksums prevent corruption
7. **Storage-efficient**: Selective sync and local-only deletion for constrained devices
8. **Implementable incrementally**: Start with Python, add mobile platforms

The user's intuition about "simple text files with unique naming" is validated by modern local-first architecture patterns. Adding vector clocks and LWW semantics provides the collision avoidance needed for multi-device use.

The four-layer integrity system (per-file checksums, device manifests, chain hashes, and snapshot verification) ensures that corrupt data is never silently accepted. SHA-256 provides cryptographic strength while being available natively on all target platforms (Python `hashlib`, Swift `CryptoKit`, Kotlin `MessageDigest`).

The selective sync model (sync scopes, stubs, on-demand fetch, local-only deletion) allows users with limited device storage to participate fully in sync without downloading everything. Auto-eviction policies help manage storage automatically while preserving user control over what stays local.
