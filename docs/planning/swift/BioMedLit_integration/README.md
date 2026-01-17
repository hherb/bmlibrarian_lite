# BioMedLit Package Integration Plan

## Overview

This document describes the remaining work needed to integrate the shared BioMedLit Swift package into both the iOS and macOS apps. The goal is to eliminate duplicate code for:
- PubMed search services
- Europe PMC search services
- Full-text retrieval (JATS XML parsing, Unpaywall, DOI resolution)
- Retry logic and constants

## Current State (as of 2026-01-17)

### Completed Work

1. **Package Dependencies Added**
   - Both iOS and macOS Xcode projects have BioMedLit added as a local Swift package dependency
   - `XCLocalSwiftPackageReference` and `XCSwiftPackageProductDependency` sections added to both project.pbxproj files

2. **Configuration**
   - `BioMedLit.configure()` added to both app entry points
   - macOS Package.swift created with BioMedLit dependency

3. **Adapter Files Created**
   - `BioMedLitAdapters.swift` created in both apps
   - Type aliases defined (BMLSearchResult, BMLPubMedService, etc.)
   - `ArticleMetadata` struct defined for intermediate data passing

4. **Service Files Updated**
   - `SearchServiceFactory.swift` (macOS) and `SearchServiceProtocol.swift` (iOS) updated to use BioMedLit services
   - `FactCheckWorkflow.swift` in both apps updated to use BMLPubMedService

5. **Duplicate Files Removed**
   - iOS: Removed `PubMedService.swift`, `EuropePMCService.swift`
   - macOS: Removed `PubMedService.swift`, `EuropePMCService.swift`, `RetryHelper.swift`

### Blocking Issues

See individual platform documentation:
- [iOS Integration Issues](./ios.md)
- [macOS Integration Issues](./macos.md)
- [BioMedLit Package Changes](./package.md)

## Root Cause: Module Name Collision

The BioMedLit module contains a public enum named `BioMedLit`:

```swift
// In BioMedLit.swift
public enum BioMedLit {
    public static let version = "1.0.0"
    public static func configure(with config: BioMedLitConfiguration) { ... }
}
```

This causes Swift to resolve `BioMedLit.SearchResult` as looking for `SearchResult` nested inside the `BioMedLit` enum, rather than the module-level `SearchResult` type.

**Solution Options:**
1. **Recommended**: Rename the `BioMedLit` enum to something else (e.g., `BioMedLitLib` or just remove it and make `configure()` a free function)
2. Use type aliases without module prefix (current approach, but causes collisions with app types)
3. Rename all conflicting app types (partial solution implemented)

## Quick Fix vs. Proper Fix

### Quick Fix (get builds working)
1. Restore deleted service files in apps
2. Keep BioMedLit dependency for future use
3. Gradually migrate one service at a time

### Proper Fix (complete migration)
1. Rename `BioMedLit` enum in package to `BioMedLitLib`
2. Add missing types to package (`PubMedFilters`, error types)
3. Update all app code to use BioMedLit types directly
4. Remove duplicate app code

## Estimated Effort

| Task | Effort |
|------|--------|
| Package changes (rename enum, add types) | 1-2 hours |
| iOS app fixes | 2-3 hours |
| macOS app fixes | 2-3 hours |
| Testing and debugging | 2-3 hours |
| **Total** | **7-11 hours** |

## File Index

| Document | Description |
|----------|-------------|
| [ios.md](./ios.md) | iOS app specific issues and fixes |
| [macos.md](./macos.md) | macOS app specific issues and fixes |
| [package.md](./package.md) | BioMedLit package changes needed |
