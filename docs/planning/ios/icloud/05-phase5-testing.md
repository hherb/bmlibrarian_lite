# Phase 5: Testing & Migration

## Objective

Ensure reliable sync behavior through comprehensive testing, and safely migrate existing users to the new iCloud-enabled version.

## Test Environment Setup

### Required Devices/Simulators

| Device | Purpose |
|--------|---------|
| iPhone (physical) | Primary iOS testing |
| iPad (physical or sim) | Cross-device iOS sync |
| Mac (physical) | macOS app testing |
| Second iCloud account | Multi-account testing |

### CloudKit Dashboard Access

1. Log in to [CloudKit Dashboard](https://icloud.developer.apple.com/dashboard/)
2. Select your container
3. Familiarize yourself with:
   - **Schema** - View record types
   - **Records** - Browse/query data
   - **Logs** - Debug sync issues
   - **Telemetry** - Monitor usage

## Test Cases

### TC-1: Basic Sync Functionality

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 1.1 | Enable sync on iPhone | Setting saved, restart prompt shown | |
| 1.2 | Restart app | CloudKit container initialized | |
| 1.3 | Create new fact-check session | Session appears in CloudKit Dashboard | |
| 1.4 | Enable sync on Mac (same account) | Same setting UI works | |
| 1.5 | Verify session appears on Mac | Session in History view within 30s | |
| 1.6 | Complete fact-check on iPhone | Report syncs to Mac | |

### TC-2: Offline Behavior

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 2.1 | Enable airplane mode on iPhone | Sync badge shows offline | |
| 2.2 | Create session while offline | Session created locally | |
| 2.3 | Disable airplane mode | Session syncs automatically | |
| 2.4 | Check Mac | Session appears after sync | |
| 2.5 | Make changes on Mac while iPhone offline | Changes queue | |
| 2.6 | Bring iPhone online | Mac changes appear on iPhone | |

### TC-3: Conflict Resolution

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 3.1 | Open same session on both devices | Both show same data | |
| 3.2 | Put both devices offline | No sync possible | |
| 3.3 | Score document differently on each | Different scores saved locally | |
| 3.4 | Bring both online simultaneously | Last-write-wins, conflict banner shown | |
| 3.5 | Verify data consistency | Same data on both devices | |

### TC-4: iCloud Account Changes

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 4.1 | Sign out of iCloud | Sync badge shows error | |
| 4.2 | App continues working locally | No crash, data preserved | |
| 4.3 | Sign in to different iCloud account | Prompt about data mismatch | |
| 4.4 | Sign back in to original account | Previous data accessible | |

### TC-5: Sync Enable/Disable

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 5.1 | Disable sync (previously enabled) | Confirmation dialog shown | |
| 5.2 | Confirm disable, restart | App works locally | |
| 5.3 | Verify local data intact | All sessions still present | |
| 5.4 | Re-enable sync | Restart prompt shown | |
| 5.5 | Verify cloud data restored | All synced sessions return | |
| 5.6 | Check for duplicates | No duplicate sessions | |

### TC-6: PDF/Document Sync (Phase 4)

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 6.1 | Download PDF on iPhone | PDF saved to iCloud Documents | |
| 6.2 | Check PDF status on Mac | Shows "in cloud" indicator | |
| 6.3 | Tap to download on Mac | PDF downloads successfully | |
| 6.4 | Clear local cache on iPhone | PDFs removed locally | |
| 6.5 | Re-access PDF | Downloads from cloud | |
| 6.6 | Check storage usage | Correct size shown | |

### TC-7: Performance & Scale

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 7.1 | Create 50 sessions | All sync correctly | |
| 7.2 | Session with 200 documents | Syncs within reasonable time | |
| 7.3 | Initial sync with large dataset | Progress indication shown | |
| 7.4 | App launch time with sync enabled | < 3 second increase | |
| 7.5 | Memory usage during sync | No significant increase | |

### TC-8: Error Handling

| ID | Test | Expected Result | Status |
|----|------|-----------------|--------|
| 8.1 | CloudKit quota exceeded | Error message, local operation continues | |
| 8.2 | Network timeout during sync | Retry automatically | |
| 8.3 | Corrupted record in cloud | Skip record, log error | |
| 8.4 | Partial sync failure | Successful items sync, failures reported | |

## Migration Strategy

### Pre-Release Checklist

- [ ] Privacy policy updated to mention iCloud storage
- [ ] App Store description updated
- [ ] Help documentation updated
- [ ] Support FAQ prepared for sync questions

### Rollout Phases

#### Phase A: Internal Testing (1 week)

1. Deploy to TestFlight (internal group)
2. Test all TC-1 through TC-8
3. Monitor CloudKit Dashboard for errors
4. Fix critical issues

#### Phase B: Beta Testing (2 weeks)

1. Expand TestFlight to external testers
2. Collect feedback on:
   - Sync reliability
   - UI clarity
   - Performance
3. Monitor crash reports
4. Address major issues

#### Phase C: Production Release

1. Submit to App Store
2. Staged rollout (if available):
   - Day 1: 10% of users
   - Day 3: 25% of users
   - Day 7: 50% of users
   - Day 14: 100% of users
3. Monitor reviews and support requests

### Data Migration for Existing Users

When existing users update to the iCloud-enabled version:

```swift
/// Called on first launch after update
func handleMigrationIfNeeded() {
    let migrationKey = "icloud_migration_v1_complete"

    guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

    // Show migration prompt
    showMigrationAlert(
        title: "iCloud Sync Available",
        message: "You can now sync your fact-check sessions across all your Apple devices. Would you like to enable iCloud sync?",
        enableAction: {
            CloudKitConfiguration.isSyncEnabled = true
            // Note: Requires restart
        },
        laterAction: {
            // User can enable later in Settings
        }
    )

    UserDefaults.standard.set(true, forKey: migrationKey)
}
```

### Rollback Plan

If critical issues discovered post-release:

1. **Immediate**: Disable CloudKit in next build
   ```swift
   // Emergency override
   static var isSyncEnabled: Bool {
       return false // Force disable
   }
   ```

2. **Submit hotfix** to App Store (expedited review)

3. **User communication**:
   - In-app message explaining temporary disable
   - Support article with workarounds

4. **Data preservation**:
   - Local data always preserved
   - CloudKit data remains (accessible when fixed)

## Monitoring & Metrics

### CloudKit Dashboard Metrics

Monitor these in CloudKit Dashboard → Telemetry:

| Metric | Alert Threshold |
|--------|-----------------|
| Sync errors/hour | > 100 |
| Average sync latency | > 10 seconds |
| Failed push notifications | > 5% |
| Quota warnings | Any |

### App Analytics

Track these events:

```swift
enum SyncAnalyticsEvent {
    case syncEnabled
    case syncDisabled
    case syncCompleted(duration: TimeInterval)
    case syncError(code: String)
    case conflictResolved
    case pdfDownloaded
    case pdfUploadedToCloud
}
```

### Support Preparation

Common issues and responses:

| Issue | Response |
|-------|----------|
| "Sessions not appearing on other device" | Check same iCloud account, wait 30s, restart apps |
| "Sync stuck" | Check internet, sign out/in iCloud, restart |
| "Missing PDFs" | Tap to download, check iCloud storage space |
| "Data disappeared" | Check iCloud account, sync may be disabled |

## Documentation Updates

### User-Facing Documentation

Create/update:

- [ ] In-app help article: "Using iCloud Sync"
- [ ] FAQ: "iCloud Sync Troubleshooting"
- [ ] Privacy policy section on iCloud data

### Developer Documentation

Update:

- [ ] CLAUDE.md with iCloud architecture
- [ ] README with sync configuration
- [ ] Code comments in CloudKit classes

## Final Verification Checklist

Before production release:

- [ ] All test cases pass
- [ ] No memory leaks in sync code
- [ ] Crash-free rate > 99.5%
- [ ] CloudKit Dashboard shows no schema issues
- [ ] Privacy policy published
- [ ] Help documentation complete
- [ ] Support team briefed
- [ ] Rollback plan tested

## Post-Release Monitoring

### Week 1

- Daily CloudKit Dashboard review
- Monitor App Store reviews for sync complaints
- Check crash reports for sync-related crashes
- Respond to support requests within 24 hours

### Week 2-4

- Weekly metric review
- Address any persistent issues
- Gather user feedback for improvements

### Ongoing

- Monthly CloudKit usage review
- Quarterly sync performance audit
- Update based on iOS/macOS changes

## Success Metrics

| Metric | Target |
|--------|--------|
| Sync adoption rate | > 40% of users |
| Sync success rate | > 99% |
| Average sync latency | < 5 seconds |
| Sync-related crashes | < 0.1% |
| Support tickets about sync | < 5% of total |
| User satisfaction (if surveyed) | > 4.0/5.0 |
