# Cross-Platform Sync Protocol Specification

## Overview

This document defines the platform-agnostic sync protocol for BMLibrarian Lite. The protocol is designed to work with **any folder-based sync provider** (Dropbox, Google Drive, iCloud, OneDrive, Syncthing, network shares, etc.) without requiring provider-specific APIs.

### Design Principles

1. **Provider Agnostic**: Works with any service that syncs folders
2. **Offline-First**: Full functionality without network connectivity
3. **Conflict-Free**: Last-Write-Wins (LWW) with deterministic tiebreakers
4. **Incremental**: Only sync changes since last sync
5. **Integrity Verified**: Checksums on all sync files
6. **Single Workspace**: One synced workspace per user

---

## Folder Structure

All sync data resides in a user-selected folder. The structure is identical across all platforms:

```
<sync-root>/                      # User-selected folder (e.g., ~/Dropbox/BMLibrarian)
├── workspace.json                # Workspace metadata and schema version
├── devices/                      # Device registrations
│   ├── <device-id-1>.json       # Device 1 config
│   ├── <device-id-2>.json       # Device 2 config
│   └── ...
├── changes/                      # Change logs (append-only)
│   ├── <device-id-1>/           # Changes from device 1
│   │   ├── manifest.json        # Index of change files
│   │   ├── 000001-<ts>-session-upsert.json
│   │   ├── 000002-<ts>-document-upsert.json
│   │   └── ...
│   └── <device-id-2>/
│       └── ...
└── .quarantine/                  # Corrupt files (hidden)
    └── ...
```

---

## File Formats

### 1. Workspace Configuration (`workspace.json`)

Created on first sync initialization. All devices share this file.

```json
{
  "schemaVersion": 1,
  "minCompatibleVersion": 1,
  "createdAt": 1706745600000,
  "encryptionMode": "none"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `schemaVersion` | int | Current schema version (increment on breaking changes) |
| `minCompatibleVersion` | int | Minimum version that can read this workspace |
| `createdAt` | int64 | Unix timestamp milliseconds |
| `encryptionMode` | string | `"none"` or `"aes-256-gcm"` (future) |

### 2. Device Configuration (`devices/<device-id>.json`)

Each device registers itself on first sync.

```json
{
  "deviceId": "550e8400-e29b-41d4-a716-446655440000",
  "deviceName": "John's Pixel 8",
  "platform": "android",
  "appVersion": "1.2.0",
  "lastSeenAt": 1706745600000,
  "syncScope": {
    "mode": "full",
    "maxStorageMB": null
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `deviceId` | string | UUID v4, generated once per device |
| `deviceName` | string | Human-readable device name |
| `platform` | string | `"ios"`, `"macos"`, `"android"`, `"desktop"` |
| `appVersion` | string | App version for compatibility checks |
| `lastSeenAt` | int64 | Last sync timestamp (milliseconds) |
| `syncScope.mode` | string | `"full"`, `"selective"`, `"recent"`, `"minimal"` |
| `syncScope.maxStorageMB` | int? | Optional storage limit |

### 3. Change Manifest (`changes/<device-id>/manifest.json`)

Index of all change files from a device. Updated after each change file write.

```json
{
  "deviceId": "550e8400-e29b-41d4-a716-446655440000",
  "lastSequence": 42,
  "files": [
    {
      "sequence": 1,
      "filename": "000001-1706745600000-session-upsert.json",
      "checksum": "sha256:abc123...",
      "size": 1234
    },
    {
      "sequence": 2,
      "filename": "000002-1706745601000-document-upsert.json",
      "checksum": "sha256:def456...",
      "size": 5678
    }
  ]
}
```

### 4. Change File (`changes/<device-id>/<sequence>-<timestamp>-<entity>-<operation>.json`)

Individual change records wrapped in an integrity envelope.

**Filename format**: `{sequence:06d}-{timestamp}-{entityType}-{operation}.json`
- `sequence`: 6-digit zero-padded sequence number (per device)
- `timestamp`: Unix milliseconds when change was recorded
- `entityType`: `session`, `document`, `citation`, `report`, `usage`, `settings`
- `operation`: `upsert` or `delete`

**File contents**:

```json
{
  "envelope": {
    "version": 1,
    "algorithm": "sha256",
    "checksum": "abc123..."
  },
  "payload": {
    "sequence": 1,
    "deviceId": "550e8400-e29b-41d4-a716-446655440000",
    "timestamp": 1706745600000,
    "entityType": "session",
    "operation": "upsert",
    "entityId": "session-uuid-here",
    "previousHash": null,
    "vectorClock": {
      "550e8400-e29b-41d4-a716-446655440000": 1
    },
    "data": {
      // Entity-specific fields (see Entity Schemas below)
    }
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `envelope.version` | int | Envelope format version |
| `envelope.algorithm` | string | Checksum algorithm |
| `envelope.checksum` | string | SHA-256 of payload JSON |
| `payload.sequence` | int | Monotonic sequence per device |
| `payload.deviceId` | string | Originating device |
| `payload.timestamp` | int64 | When change was recorded |
| `payload.entityType` | string | Type of entity changed |
| `payload.operation` | string | `upsert` or `delete` |
| `payload.entityId` | string | Primary key of entity |
| `payload.previousHash` | string? | Hash of previous change (chain) |
| `payload.vectorClock` | map | Causality tracking |
| `payload.data` | object | Entity data (null for delete) |

---

## Entity Schemas

### Session Entity

```json
{
  "id": "uuid",
  "claim": "Original claim text",
  "createdAt": 1706745600000,
  "updatedAt": 1706745600000,
  "status": "completed",
  "pubmedQuery": "converted search query",
  "totalDocumentsFound": 150,
  "documentsScored": 50,
  "reportGenerated": true
}
```

### Document Entity

```json
{
  "id": "uuid",
  "sessionId": "session-uuid",
  "pmid": "12345678",
  "pmcid": "PMC1234567",
  "doi": "10.1234/example",
  "title": "Document title",
  "abstract": "Abstract text...",
  "authors": ["Author One", "Author Two"],
  "journal": "Journal Name",
  "publicationDate": "2024-01-15",
  "relevanceScore": 4,
  "relevanceExplanation": "Highly relevant because...",
  "fullTextAvailable": true,
  "fullTextSource": "pmc_oa",
  "createdAt": 1706745600000,
  "updatedAt": 1706745600000
}
```

### Citation Entity

```json
{
  "id": "uuid",
  "sessionId": "session-uuid",
  "documentId": "document-uuid",
  "text": "Citation text extracted...",
  "pageOrSection": "Results",
  "relevanceToClaimExplanation": "Supports claim because...",
  "createdAt": 1706745600000
}
```

### Report Entity

```json
{
  "id": "uuid",
  "sessionId": "session-uuid",
  "content": "Full report markdown...",
  "format": "markdown",
  "createdAt": 1706745600000
}
```

### Usage Record Entity

```json
{
  "id": "uuid",
  "sessionId": "session-uuid",
  "provider": "anthropic",
  "model": "claude-sonnet-4-5-20250929",
  "inputTokens": 1500,
  "outputTokens": 500,
  "costUSD": 0.012,
  "operation": "scoring",
  "createdAt": 1706745600000
}
```

---

## Sync Algorithm

### Local Change Recording

When a local entity changes:

1. Generate change record with current timestamp and next sequence number
2. Compute SHA-256 of previous change (for hash chain)
3. Update vector clock: increment own device's counter
4. Write change file with integrity envelope
5. Update manifest with new file entry

```
recordChange(entity, operation):
    sequence = getNextSequence()
    timestamp = currentTimeMillis()
    previousHash = getLastChangeHash()

    vectorClock = getCurrentVectorClock()
    vectorClock[myDeviceId] = vectorClock[myDeviceId] + 1

    change = {
        sequence, deviceId, timestamp, entityType,
        operation, entityId, previousHash, vectorClock,
        data: (operation == "upsert") ? entity.toSyncData() : null
    }

    envelope = wrapWithIntegrity(change)
    filename = formatFilename(sequence, timestamp, entityType, operation)

    writeFile("changes/{deviceId}/{filename}", envelope)
    updateManifest(filename, checksum, size)
```

### Full Sync Cycle

Executed periodically or on-demand:

```
sync():
    // 1. Update our last-seen timestamp
    updateDeviceLastSeen()

    // 2. Discover all devices
    devices = listDevices()

    // 3. For each remote device, apply their changes
    for device in devices where device.id != myDeviceId:
        watermark = getWatermark(device.id)  // Our last-seen sequence
        manifest = readManifest(device.id)

        newChanges = manifest.files.filter(f => f.sequence > watermark)
        for change in newChanges.sortedBy(sequence):
            if verifyIntegrity(change):
                applyChange(change)
                setWatermark(device.id, change.sequence)
            else:
                quarantineFile(change.filename, "integrity_failure")

    // 4. Write any pending local changes
    flushPendingChanges()
```

### Applying Remote Changes (LWW Merge)

```
applyChange(change):
    localEntity = database.find(change.entityType, change.entityId)

    if change.operation == "delete":
        if localEntity == null:
            return  // Already deleted or never existed

        if shouldApplyRemote(
            remote: (change.timestamp, change.deviceId),
            local: (localEntity.updatedAt, localEntity.lastModifiedBy)
        ):
            database.delete(change.entityType, change.entityId)

    else:  // upsert
        if localEntity == null:
            database.insert(change.data)
        else:
            if shouldApplyRemote(
                remote: (change.timestamp, change.deviceId),
                local: (localEntity.updatedAt, localEntity.lastModifiedBy)
            ):
                database.update(change.data)

shouldApplyRemote(remote, local):
    if local == null:
        return true
    if remote.timestamp > local.timestamp:
        return true
    if remote.timestamp == local.timestamp:
        return remote.deviceId > local.deviceId  // Deterministic tiebreaker
    return false
```

---

## Implementation Requirements

### Storage Interface

All platforms must implement this interface:

```
interface SyncStorage:
    listFiles(path: String) -> List<FileInfo>
    listDirectories(path: String) -> List<String>
    readFile(path: String) -> ByteArray
    writeFile(data: ByteArray, path: String)
    deleteFile(path: String)
    fileExists(path: String) -> Boolean
    createDirectory(path: String)
    quarantineFile(path: String, reason: String) -> String
    watchForChanges(callback: (String) -> Unit) -> Token
```

### Platform Implementations

| Platform | Storage Implementation |
|----------|----------------------|
| iOS/macOS | `LocalFolderSyncStorage` (existing), `iCloudSyncStorage` (existing) |
| Android | `LocalFolderSyncStorage` (new) |
| Desktop | `LocalFolderSyncStorage` (new) |

The `LocalFolderSyncStorage` works with any folder the user selects, including:
- Local device storage
- Dropbox-synced folder
- Google Drive-synced folder
- iCloud Drive folder
- OneDrive folder
- Syncthing folder
- Network share (SMB/NFS)

---

## Error Handling

### Integrity Failures

Files failing checksum verification are moved to `.quarantine/` with metadata:

```
.quarantine/
└── 2024-01-15T10-30-00_000042-1706745600000-session-upsert.json
    # Original filename prefixed with ISO timestamp
```

### Conflict Resolution

LWW ensures all devices converge to the same state:
- Later timestamp always wins
- Equal timestamps: higher device ID wins (lexicographic)
- This is deterministic - all devices make the same decision

### Network/Sync Failures

- Sync operations are idempotent - safe to retry
- Watermarks only advance on successful apply
- Partial syncs leave system in consistent state

---

## Security Considerations

### Current (v1)

- No encryption at rest (rely on provider encryption)
- No authentication (folder access = sync access)
- Checksums prevent tampering detection

### Future (v2)

- Optional AES-256-GCM encryption with user passphrase
- Key derivation via Argon2id
- Encrypted payloads, plaintext envelope

---

## Version Compatibility

| Schema Version | Min Compatible | Changes |
|---------------|----------------|---------|
| 1 | 1 | Initial release |

When `schemaVersion` increases:
- Check `minCompatibleVersion` against app's supported version
- Reject workspace if incompatible
- Prompt user to update app

---

## Testing Checklist

- [ ] Two devices sync a new session
- [ ] Concurrent edits resolve via LWW
- [ ] Delete propagates to all devices
- [ ] Corrupt file is quarantined
- [ ] Offline changes sync when back online
- [ ] Large document collection syncs incrementally
- [ ] Storage limit enforced (if configured)
- [ ] New device joins existing workspace
- [ ] Device removal doesn't break sync
