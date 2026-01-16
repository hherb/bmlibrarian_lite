# iCloud Sync Implementation Plan

## Overview

This plan outlines the implementation of iCloud sync for the Medical Fact Checker applications (iOS and macOS), enabling users to access their research sessions, reports, and documents across all their Apple devices.

## Goals

1. **Cross-device access**: Users can start a fact-check on iPhone and review results on Mac
2. **Report persistence**: Evidence reports available everywhere without re-running searches
3. **Optional feature**: Users choose whether to enable iCloud sync
4. **Storage optimization**: Handle PDFs/full-text efficiently without consuming excessive cloud storage

## Current Architecture

Both iOS and macOS apps share identical SwiftData models:

| Model | Purpose | Sync Priority |
|-------|---------|---------------|
| `FactCheckSession` | Workflow state, claims, progress | High |
| `Document` | PubMed articles with scores | High |
| `Citation` | Extracted evidence passages | High |
| `EvidenceReport` | Final reports with verdicts | High |
| `UsageRecord` | Budget/cost tracking | Medium |

Current configuration explicitly disables CloudKit:
```swift
let modelConfiguration = ModelConfiguration(
    schema: schema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .none  // ← To be made configurable
)
```

## Implementation Phases

| Phase | Description | Documents |
|-------|-------------|-----------|
| 1 | Core CloudKit Integration | [01-phase1-core-cloudkit.md](01-phase1-core-cloudkit.md) |
| 2 | Settings & User Control | [02-phase2-settings-ui.md](02-phase2-settings-ui.md) |
| 3 | Sync Status & Conflict Handling | [03-phase3-sync-status.md](03-phase3-sync-status.md) |
| 4 | Full-Text & PDF Sync | [04-phase4-fulltext-sync.md](04-phase4-fulltext-sync.md) |
| 5 | Testing & Migration | [05-phase5-testing.md](05-phase5-testing.md) |

## Technical Approach

### SwiftData + CloudKit

SwiftData provides built-in CloudKit sync via `ModelConfiguration`:

```swift
// With iCloud enabled
ModelConfiguration(
    schema: schema,
    isStoredInMemoryOnly: false,
    cloudKitDatabase: .automatic
)
```

This automatically:
- Creates CloudKit record types for each `@Model`
- Syncs changes bidirectionally
- Handles offline queuing
- Maintains relationships across devices

### What Syncs vs. What Stays Local

| Data | Sync Strategy |
|------|---------------|
| Sessions, Documents, Citations, Reports | CloudKit (automatic) |
| User preferences | `NSUbiquitousKeyValueStore` (optional) |
| API keys | Keychain (device-local, never sync) |
| Full-text PDFs | iCloud Drive container (Phase 4) |
| Cached embeddings | Local only (re-compute on demand) |

## Prerequisites

1. **Apple Developer Program membership** (paid account required for CloudKit)
2. **CloudKit container** created in Apple Developer portal
3. **Entitlements** added to both iOS and macOS targets
4. **Privacy policy update** mentioning iCloud data storage

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| CloudKit quota limits (1GB free) | Lazy PDF sync, user controls |
| Sync conflicts on concurrent edits | Last-write-wins with notification |
| Data loss during migration | Backup reminder, staged rollout |
| iCloud unavailable | Graceful fallback to local-only |
| Medical data privacy concerns | Clear privacy disclosure, encryption at rest |

## Success Criteria

- [ ] User can enable/disable iCloud sync in Settings
- [ ] New sessions appear on all devices within 30 seconds
- [ ] Reports are readable on any device
- [ ] Disabling sync keeps local data intact
- [ ] No data loss during enable/disable cycles
- [ ] Clear sync status indicator in UI

## Timeline Estimate

| Phase | Effort |
|-------|--------|
| Phase 1: Core CloudKit | 2-3 days |
| Phase 2: Settings UI | 1-2 days |
| Phase 3: Sync Status | 2-3 days |
| Phase 4: PDF Sync | 2-3 days |
| Phase 5: Testing | 2-3 days |
| **Total** | **9-14 days** |

## File Index

- [00-overview.md](00-overview.md) - This document
- [01-phase1-core-cloudkit.md](01-phase1-core-cloudkit.md) - CloudKit container setup and SwiftData configuration
- [02-phase2-settings-ui.md](02-phase2-settings-ui.md) - User toggle and preferences sync
- [03-phase3-sync-status.md](03-phase3-sync-status.md) - UI indicators and conflict resolution
- [04-phase4-fulltext-sync.md](04-phase4-fulltext-sync.md) - PDF and full-text document handling
- [05-phase5-testing.md](05-phase5-testing.md) - Test plan and migration strategy
