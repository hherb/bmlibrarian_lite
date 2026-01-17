# iOS App BioMedLit Integration Issues

## Current Build Errors

```
Sources/Services/FullTextService.swift:73:17: error: invalid redeclaration of 'create(from:)'
Sources/Services/FullTextService.swift:96:23: error: cannot find type 'FullTextResult' in scope
Sources/Services/FullTextService.swift:136:64: error: cannot find type 'FullTextResult' in scope
```

Additional errors (after type collision fix):
```
Sources/Services/FactCheckWorkflow.swift:482: error: cannot find 'PubMedFilters' in scope
Sources/Services/FactCheckWorkflow.swift:538: error: cannot find 'PubMedFilters' in scope
Sources/Services/FactCheckWorkflow.swift:582: error: type 'PubMedError' has no member 'noResults'
```

## Issues and Solutions

### Issue 1: Type Name Collisions

**Problem**: Both the app and BioMedLit define types with the same names:
- `FullTextResult` (app struct vs BioMedLit enum)
- `FullTextSource` (app enum vs BioMedLit enum)
- `SearchProvider` (app enum vs BioMedLit enum)

**Current Partial Fix**:
- Renamed app types to `AppFullTextResult` and `AppFullTextSource` in `FullTextSource.swift`
- Used sed to update references in view files

**Files Already Updated**:
- `Sources/Models/FullTextSource.swift` - types renamed
- `Sources/Views/FactCheck/FullTextViewer.swift` - references updated
- `Sources/Views/FactCheck/ScoredDocumentsView.swift` - references updated
- `Sources/Views/Components/FullTextSourceBadge.swift` - references updated

**Remaining Fix Needed**:
- `Sources/Services/FullTextService.swift` - Update return types

**Step-by-step**:
```swift
// In FullTextService.swift, change:
func fetchFullText(...) async throws -> FullTextResult
// To:
func fetchFullText(...) async throws -> AppFullTextResult

// And change all internal returns:
return FullTextResult(content: .markdown(markdown), source: .europePMC)
// To:
return AppFullTextResult(content: .markdown(markdown), source: .europePMC)
```

### Issue 2: Duplicate `create(from:)` Method

**Problem**: `FullTextService.create(from:)` exists in both:
- `Sources/Services/FullTextService.swift` (line 73)
- `Sources/Utilities/BioMedLitAdapters.swift` (as extension on `BMLFullTextService`)

**Solution**: Remove the extension from `BioMedLitAdapters.swift` since the app's `FullTextService` is separate from BioMedLit's:

```swift
// In BioMedLitAdapters.swift, REMOVE this extension:
extension BMLFullTextService {
    static func create(from settings: AppSettings) -> BMLFullTextService {
        ...
    }
}
```

The app will continue to use its own `FullTextService` (not BioMedLit's) since the full-text retrieval isn't being migrated yet.

### Issue 3: Missing PubMedFilters

**Problem**: `PubMedFilters.clinicalPublicationFilter` was defined in the deleted `PubMedService.swift`.

**Location of Usage** (FactCheckWorkflow.swift):
- Line 482: Fallback query building
- Line 538: Empty concepts fallback
- Line 543: Query suffix

**Solution Options**:

**Option A**: Add to BioMedLit package (recommended)
```swift
// Add to Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift
public enum PubMedFilters {
    /// Filter for clinical publication types (RCTs, systematic reviews, etc.)
    public static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR
        Guideline[pt] OR Practice Guideline[pt])
        """
}
```

**Option B**: Add locally in iOS app
```swift
// Create Sources/Utilities/PubMedFilters.swift
enum PubMedFilters {
    static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR
        Guideline[pt] OR Practice Guideline[pt])
        """
}
```

### Issue 4: Missing PubMedError.noResults

**Problem**: `PubMedError.noResults` was part of the deleted `PubMedService.swift`.

**Location of Usage**:
- `FactCheckWorkflow.swift` line 582

**Solution Options**:

**Option A**: Add `noResults` case to BioMedLit's `PubMedError`
```swift
// In Packages/BioMedLit/Sources/BioMedLit/Services/PubMedService.swift
public enum PubMedError: LocalizedError, RetryableError, Sendable {
    case invalidQuery(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)
    case rateLimited
    case noResults  // ADD THIS

    public var errorDescription: String? {
        switch self {
        // ... existing cases ...
        case .noResults:
            return "No results found for the search query"
        }
    }
}
```

**Option B**: Create local error type
```swift
// In FactCheckWorkflow.swift, add:
enum FactCheckError: LocalizedError {
    case noResults

    var errorDescription: String? {
        switch self {
        case .noResults:
            return "No results found for the search query"
        }
    }
}

// Then change:
throw PubMedError.noResults
// To:
throw FactCheckError.noResults
```

## Step-by-Step Fix Plan

### Step 1: Fix FullTextService.swift
```bash
# Update return types from FullTextResult to AppFullTextResult
sed -i '' 's/-> FullTextResult/-> AppFullTextResult/g' \
  ios/MedicalFactChecker/Sources/Services/FullTextService.swift
```

### Step 2: Remove duplicate create(from:) from adapters
Edit `Sources/Utilities/BioMedLitAdapters.swift`:
- Remove the `extension BMLFullTextService` block entirely

### Step 3: Add missing PubMedFilters
Create `Sources/Utilities/PubMedFilters.swift`:
```swift
import Foundation

/// PubMed publication type filters for clinical relevance.
enum PubMedFilters {
    /// Filter for high-quality clinical publication types.
    static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR \
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR \
        Guideline[pt] OR Practice Guideline[pt])
        """
}
```

### Step 4: Add PubMedFilters.swift to Xcode project
Add file reference to `MedicalFactChecker.xcodeproj/project.pbxproj`:
- Add PBXFileReference
- Add to Utilities PBXGroup
- Add PBXBuildFile for Sources build phase

### Step 5: Add missing error case
Either add to BioMedLit package (preferred) or create local `FactCheckError` enum.

### Step 6: Verify build
```bash
cd ios/MedicalFactChecker
xcodebuild -project MedicalFactChecker.xcodeproj \
  -scheme MedicalFactChecker \
  -destination 'generic/platform=iOS Simulator' \
  build
```

## Files to Modify

| File | Change |
|------|--------|
| `Sources/Services/FullTextService.swift` | Change `FullTextResult` to `AppFullTextResult` |
| `Sources/Utilities/BioMedLitAdapters.swift` | Remove `extension BMLFullTextService` |
| `Sources/Utilities/PubMedFilters.swift` | **CREATE** - Add filter constants |
| `MedicalFactChecker.xcodeproj/project.pbxproj` | Add PubMedFilters.swift reference |
| `Sources/Services/FactCheckWorkflow.swift` | Update error handling if using local error type |

## Testing Checklist

After fixes, verify:
- [ ] App builds without errors
- [ ] Search functionality works (PubMed)
- [ ] Search functionality works (Europe PMC)
- [ ] Full-text viewer displays correctly
- [ ] Error handling for no results works
