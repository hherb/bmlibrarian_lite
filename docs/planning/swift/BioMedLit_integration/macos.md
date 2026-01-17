# macOS App BioMedLit Integration Issues

## Current Build Errors

```
error: Build input files cannot be found:
  - '/Users/.../Sources/Services/PubMedService.swift'
  - '/Users/.../Sources/Services/EuropePMCService.swift'
  - '/Users/.../Sources/Utilities/RetryHelper.swift'
```

## Issues and Solutions

### Issue 1: Xcode Project Still References Deleted Files

**Problem**: The `project.pbxproj` still has file references to deleted files:
- `PubMedService.swift`
- `EuropePMCService.swift`
- `RetryHelper.swift`

These files were removed from disk but their references remain in:
- PBXFileReference section
- PBXBuildFile section
- PBXGroup (Services, Utilities)
- PBXSourcesBuildPhase

**Solution**: Remove these references from `project.pbxproj`

**Step-by-step**:

1. Find and remove from **PBXBuildFile section**:
```
A1000040 /* PubMedService.swift in Sources */
A100003A /* EuropePMCService.swift in Sources */ (or similar)
A1000036 /* RetryHelper.swift in Sources */ (or similar)
```

2. Find and remove from **PBXFileReference section**:
```
A2000041 /* PubMedService.swift */
A2000047 /* EuropePMCService.swift */
A2000038 /* RetryHelper.swift */
```

3. Remove from **PBXGroup** (Services group):
```
A2000041 /* PubMedService.swift */,
A2000047 /* EuropePMCService.swift */,
```

4. Remove from **PBXGroup** (Utilities group):
```
A2000038 /* RetryHelper.swift */,
```

5. Remove from **PBXSourcesBuildPhase**:
```
A1000040 /* PubMedService.swift in Sources */,
A100003A /* EuropePMCService.swift in Sources */,
A1000036 /* RetryHelper.swift in Sources */,
```

### Issue 2: Type Name Collisions (Same as iOS)

**Problem**: macOS app has similar type collisions:
- `FullTextResult` in `Models/FullTextSource.swift`
- `FullTextSource` in `Models/FullTextSource.swift`
- `SearchProvider` in `Models/SearchProvider.swift`

**Solution**: Same approach as iOS - rename app types or use BioMedLit types directly.

**Files to Check**:
```bash
grep -rn "FullTextResult\|FullTextSource" Sources/ --include="*.swift"
```

### Issue 3: SearchServiceFactory Uses Deleted Types

**Problem**: `SearchServiceFactory.swift` was updated to use BioMedLit but may have issues.

**Verify**: After fixing project references, check for compile errors related to:
- `PubMedFilters`
- `PubMedError`
- Type mismatches

### Issue 4: FactCheckWorkflow Uses Deleted Types

**Problem**: Similar to iOS, the workflow uses:
- `PubMedFilters.clinicalPublicationFilter`
- `PubMedError.noResults` (possibly)

## Step-by-Step Fix Plan

### Step 1: Clean Xcode Project References

**Option A**: Manual edit of project.pbxproj

Search for and remove all references to:
- `PubMedService.swift`
- `EuropePMCService.swift`
- `RetryHelper.swift`

**Option B**: Use Xcode GUI
1. Open project in Xcode
2. In Project Navigator, find files marked red (missing)
3. Right-click → Delete (choose "Remove Reference")
4. Save project

**Option C**: Script approach (careful with this)
```bash
cd macos/MedicalFactCheckerMac

# Backup first
cp MedicalFactCheckerMac.xcodeproj/project.pbxproj \
   MedicalFactCheckerMac.xcodeproj/project.pbxproj.backup

# Remove references (verify IDs first by grepping the file)
# These are example IDs - actual IDs may differ
sed -i '' '/PubMedService\.swift/d' MedicalFactCheckerMac.xcodeproj/project.pbxproj
sed -i '' '/EuropePMCService\.swift/d' MedicalFactCheckerMac.xcodeproj/project.pbxproj
sed -i '' '/RetryHelper\.swift/d' MedicalFactCheckerMac.xcodeproj/project.pbxproj
```

### Step 2: Check for Type Collisions

After fixing references, build and look for collision errors:
```bash
xcodebuild -project MedicalFactCheckerMac.xcodeproj \
  -scheme MedicalFactCheckerMac \
  -destination 'platform=macOS' \
  build 2>&1 | grep -E "error:"
```

### Step 3: Rename Conflicting Types (if needed)

Same approach as iOS:
```bash
# In Sources/Models/FullTextSource.swift
# Rename FullTextResult → AppFullTextResult
# Rename FullTextSource → AppFullTextSource

# Update all references
find Sources/ -name "*.swift" -exec grep -l "FullTextResult\|FullTextSource" {} \;
```

### Step 4: Add Missing PubMedFilters (if needed)

Create `Sources/Utilities/PubMedFilters.swift` if `FactCheckWorkflow` uses it.

### Step 5: Verify Build

```bash
xcodebuild -project MedicalFactCheckerMac.xcodeproj \
  -scheme MedicalFactCheckerMac \
  -destination 'platform=macOS' \
  build
```

## Files to Modify

| File | Change |
|------|--------|
| `MedicalFactCheckerMac.xcodeproj/project.pbxproj` | Remove references to deleted files |
| `Sources/Models/FullTextSource.swift` | Rename types if collision exists |
| `Sources/Views/**/*.swift` | Update type references |
| `Sources/Services/FullTextService.swift` | Update type references |
| `Sources/Utilities/PubMedFilters.swift` | **CREATE** if needed |

## Detailed pbxproj Changes

### IDs to Remove (verify in actual file first)

Search the project.pbxproj for these patterns:

```
/* PubMedService.swift */ = {isa = PBXFileReference;
/* PubMedService.swift in Sources */ = {isa = PBXBuildFile;
A2000041 /* PubMedService.swift */,

/* EuropePMCService.swift */ = {isa = PBXFileReference;
/* EuropePMCService.swift in Sources */ = {isa = PBXBuildFile;
A2000047 /* EuropePMCService.swift */,

/* RetryHelper.swift */ = {isa = PBXFileReference;
/* RetryHelper.swift in Sources */ = {isa = PBXBuildFile;
A2000038 /* RetryHelper.swift */,
```

Remove entire lines containing these patterns.

## Testing Checklist

After fixes, verify:
- [ ] App builds without errors
- [ ] App launches successfully
- [ ] Search functionality works (PubMed)
- [ ] Search functionality works (Europe PMC)
- [ ] Full-text viewer displays correctly
- [ ] Combined search (both providers) works
