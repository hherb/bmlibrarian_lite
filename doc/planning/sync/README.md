# Cross-Platform Sync Implementation Plan

## Overview

This document provides a comprehensive implementation plan for adding cross-platform synchronization to BMLibrarian Lite's iOS and macOS apps. The implementation maximizes code sharing through the BioMedLit Swift package with a strong preference for pure functions.

**Design Philosophy**:
- File-based sync with CRDT semantics (no custom server required)
- Multi-layer integrity verification (SHA-256 checksums, chain hashes)
- Selective sync for storage-constrained devices
- Pure functions for all transformation and verification logic

## Phase Summary

| Phase | Description | Key Deliverables |
|-------|-------------|------------------|
| [Phase 1](phase1_core_foundation.md) | Core Foundation | Integrity types, checksum functions, constants |
| [Phase 2](phase2_change_tracking.md) | Change Tracking | Storage protocol, change log reader/writer |
| [Phase 3](phase3_sync_engine.md) | Sync Engine | LWW merge, sync orchestration, iCloud provider |
| [Phase 4](phase4_selective_sync.md) | Selective Sync | Eviction, on-demand fetch, storage management |
| [Phase 5](phase5_platform_integration.md) | Platform Integration | SwiftData observer, background sync, UI |

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    BioMedLit Swift Package                          │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  Sync Module (Packages/BioMedLit/Sources/BioMedLit/Sync/)       ││
│  │                                                                  ││
│  │  Phase 1: Core Foundation                                        ││
│  │  ├── SyncConstants.swift         (all magic numbers)             ││
│  │  ├── IntegrityError.swift        (error types)                   ││
│  │  ├── IntegrityModels.swift       (envelope, vector clock)        ││
│  │  ├── IntegrityFunctions.swift    (pure: checksum, verify)        ││
│  │  └── SyncFileNaming.swift        (pure: file naming)             ││
│  │                                                                  ││
│  │  Phase 2: Change Tracking                                        ││
│  │  ├── SyncStorageProtocol.swift   (storage abstraction)           ││
│  │  ├── LocalFolderSyncStorage.swift (local implementation)         ││
│  │  ├── WorkspaceModels.swift       (device, workspace config)      ││
│  │  ├── ChangeLogWriter.swift       (records changes)               ││
│  │  ├── ChangeLogReader.swift       (reads remote changes)          ││
│  │  └── SyncStateManager.swift      (watermarks, exclusions)        ││
│  │                                                                  ││
│  │  Phase 3: Sync Engine                                            ││
│  │  ├── LWWMergeStrategy.swift      (pure: conflict resolution)     ││
│  │  ├── SyncEngine.swift            (orchestration)                 ││
│  │  ├── iCloudSyncStorage.swift     (iCloud implementation)         ││
│  │  ├── WorkspaceInitializer.swift  (setup)                         ││
│  │  └── SyncCoordinator.swift       (high-level API)                ││
│  │                                                                  ││
│  │  Phase 4: Selective Sync                                         ││
│  │  ├── StorageMonitor.swift        (usage tracking)                ││
│  │  ├── SessionEvictionManager.swift (eviction logic)               ││
│  │  ├── OnDemandFetcher.swift       (fetch on-demand)               ││
│  │  ├── SyncScopeManager.swift      (scope configuration)           ││
│  │  └── SelectiveSyncCoordinator.swift (high-level API)             ││
│  └─────────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────────┘
         ▲                                           ▲
         │                                           │
┌────────┴────────┐                         ┌───────┴────────┐
│   iOS App       │                         │   macOS App    │
│                 │                         │                │
│  Phase 5:       │                         │  Phase 5:      │
│  - SyncChange-  │                         │  - MacSync-    │
│    Observer     │                         │    Observer    │
│  - AppSync-     │                         │  - MacAppSync- │
│    Delegate     │                         │    Delegate    │
│  - Background-  │                         │  - MacBG-      │
│    SyncService  │                         │    SyncService │
│  - SyncSettings │                         │  - MacSync-    │
│    View         │                         │    SettingsView│
│  - Storage-     │                         │  - MacStorage- │
│    Management-  │                         │    Management- │
│    View         │                         │    View        │
└─────────────────┘                         └────────────────┘
```

## Pure Functions

The following functions are pure (no side effects, deterministic):

### Phase 1
- `toCanonicalJSON<T>(_:) -> Data` - Serialize to canonical JSON
- `calculateChecksum(_:) -> String` - SHA-256 hash
- `createIntegrityEnvelope<T>(_:) -> IntegrityEnvelope<T>` - Wrap with checksum
- `verifyAndExtract<T>(_:) -> T` - Verify and unwrap
- `verifyChainLink(change:previousChange:) -> Bool` - Verify chain hash
- `computeManifestChecksum(_:) -> String` - Combined file checksum

### Phase 2
- `SyncFileNaming.changeFileName(...)` - Generate file name
- `SyncFileNaming.parseChangeFileName(_:)` - Parse file name

### Phase 3
- `LWWMergeStrategy.resolve(local:remote:)` - Determine winner
- `LWWMergeStrategy.shouldApplyRemote(...)` - Check if remote wins
- `LWWMergeStrategy.mergeFields(...)` - Per-field merge

### Phase 4
- `selectEvictionCandidates(from:strategy:minKeep:)` - Select sessions to evict

## Data Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Local Change                                │
│                                                                     │
│  User Action ──▶ SwiftData ──▶ SyncChangeObserver ──▶ ChangeLog    │
│                     │                                    Writer     │
│                     ▼                                      │        │
│              Local Database                                ▼        │
│                                                     iCloud Drive    │
│                                                     /BMLibrarian/   │
│                                                     changes/{id}/   │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│                         Remote Change                               │
│                                                                     │
│  iCloud ──▶ ChangeLogReader ──▶ verifyAndExtract ──▶ LWWMerge     │
│  Drive           │                     │                  │         │
│                  ▼                     ▼                  ▼         │
│             Discover           Integrity Check      Apply if        │
│             Devices                                 Remote Wins     │
│                                                          │          │
│                                                          ▼          │
│                                              AppSyncDelegate        │
│                                              ──▶ SwiftData          │
└─────────────────────────────────────────────────────────────────────┘
```

## Golden Rules Compliance

All implementation follows the project's golden rules:

| Rule | Compliance |
|------|------------|
| No magic numbers | All in `SyncConstants` |
| No hardcoded paths | Directory names in constants |
| Type hints | Full Swift annotations |
| Docstrings | All public APIs documented |
| Error handling | `IntegrityError`, `SyncStorageError`, etc. |
| Thread safety | Actor isolation, `@MainActor` |
| Retry with backoff | Network operations via `RetryHelper` |

## File Sync Structure

```
/BMLibrarian/                          # iCloud Drive container
├── workspace.json                     # Workspace metadata
├── devices/
│   ├── {device_uuid}.json            # Device registration
│   └── ...
├── changes/
│   ├── {device_uuid}/                # Per-device change logs
│   │   ├── manifest.json             # File listing with checksums
│   │   ├── 000001_ts_entity_op.json  # Change files
│   │   └── ...
│   └── ...
├── snapshots/                        # Periodic full-state snapshots
│   └── {timestamp}_{device}.json.gz
└── .quarantine/                      # Corrupt files for analysis
```

## Integrity Layers

1. **Per-File Checksum**: Every file has SHA-256 in `_integrity` envelope
2. **Manifest Checksum**: Device manifest lists all files with checksums
3. **Chain Hash**: Each change references previous change's hash
4. **Snapshot Verification**: Full state checksum for recovery

## Sync Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `full` | Sync all sessions | Desktop with storage |
| `selective` | Whitelist sessions | Curated sync |
| `recent` | Last N days | Auto-cleanup |
| `minimal` | Metadata only | Browsing, fetch on-demand |

## Eviction Strategies

| Strategy | Order | Best For |
|----------|-------|----------|
| `lru` | Least recently accessed | General use |
| `largest` | Biggest first | Quick space recovery |
| `oldest` | Creation date | Archive old work |
| `noReport` | No report first | Keep completed work |

## Implementation Order

Recommended implementation sequence:

1. **Phase 1** - Core foundation (can be unit tested independently)
2. **Phase 2** - Change tracking (requires Phase 1)
3. **Phase 3** - Sync engine (requires Phase 2)
4. **Phase 4** - Selective sync (requires Phase 3)
5. **Phase 5** - Platform integration (requires Phase 1-4)

Each phase can be implemented and tested before moving to the next.

## Testing Strategy

### Unit Tests (Package)
- Canonical JSON consistency
- Checksum calculation
- Integrity envelope round-trip
- Vector clock operations
- Chain verification
- File naming
- LWW merge logic
- Eviction candidate selection

### Integration Tests (Package)
- Local folder storage
- Workspace initialization
- Two-device sync simulation

### UI Tests (Apps)
- Settings view interactions
- Storage management

### Manual Tests
- Real iCloud sync between devices
- Background sync behavior
- Offline/online transitions

## Dependencies

### BioMedLit Package
- `CryptoKit` (SHA-256)
- `Foundation` (JSON, FileManager)

### iOS App
- `SwiftData`
- `BackgroundTasks`
- iCloud entitlements

### macOS App
- `SwiftData`
- `NSBackgroundActivityScheduler`
- iCloud entitlements

## Security Considerations

1. **No secrets in sync files**: API keys stay in Keychain
2. **Integrity verification**: All data verified before use
3. **Quarantine corrupt files**: Don't process suspicious data
4. **Optional encryption**: AES-256-GCM available for sensitive data

## Future Enhancements

After initial implementation:

1. **Encryption**: Add AES-256-GCM encryption option
2. **Conflict UI**: Show conflicts for user resolution
3. **Compaction**: Consolidate old change logs
4. **Dropbox/Google Drive**: Additional storage providers
5. **Sync status indicators**: Per-session sync badges

## References

- [Cross-Platform Sync Research](../cross_platform_sync_research.md) - Original research document
- [BioMedLit Package](../../../Packages/BioMedLit/) - Shared Swift package
- [Golden Rules](../../llm/golden_rules.md) - Project coding standards
