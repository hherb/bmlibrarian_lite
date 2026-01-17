# BioMedLit Package Changes Needed

## Overview

The BioMedLit package needs modifications to better support integration with the iOS and macOS apps. The main issues are:

1. Module name collision with internal enum
2. Missing convenience types/constants
3. Missing error cases

## Issue 1: Module Name Collision (Critical)

### Problem

The package has a public enum named `BioMedLit` inside the `BioMedLit` module:

```swift
// In BioMedLit.swift
public enum BioMedLit {
    public static let version = "1.0.0"
    public static func configure(with config: BioMedLitConfiguration) { ... }
}
```

This causes Swift to resolve `BioMedLit.SearchResult` as:
- Looking for `SearchResult` nested inside the `BioMedLit` **enum**
- Instead of the module-level `SearchResult` **struct**

This is a well-known Swift issue when a module contains a type with the same name as the module.

### Solution: Rename the Enum

**Option A** (Recommended): Rename to `BioMedLitLib`
```swift
// In BioMedLit.swift
public enum BioMedLitLib {
    public static let version = "1.0.0"

    public static func configure(with config: BioMedLitConfiguration) {
        configuration = config
    }

    internal static var configuration: BioMedLitConfiguration?

    internal static var logger: BioMedLitLogger? {
        configuration?.logger
    }
}
```

**Option B**: Use a struct namespace
```swift
public struct BioMedLitConfig {
    public static let version = "1.0.0"

    private init() {} // Prevent instantiation

    public static func configure(with config: BioMedLitConfiguration) { ... }
}
```

**Option C**: Free functions (simplest)
```swift
// Remove the enum entirely, use module-level functions
public let bioMedLitVersion = "1.0.0"

private var bioMedLitConfiguration: BioMedLitConfiguration?

public func configureBioMedLit(with config: BioMedLitConfiguration) {
    bioMedLitConfiguration = config
}

internal var bioMedLitLogger: BioMedLitLogger? {
    bioMedLitConfiguration?.logger
}
```

### Migration Impact

If using Option A (recommended), update apps:
```swift
// Old:
BioMedLit.configure(with: config)

// New:
BioMedLitLib.configure(with: config)
```

## Issue 2: Missing PubMedFilters

### Problem

Apps use `PubMedFilters.clinicalPublicationFilter` for query building.

### Solution: Add to Constants.swift

```swift
// In Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift

/// PubMed publication type filters for clinical relevance.
public enum PubMedFilters {
    /// Filter for high-quality clinical publication types.
    ///
    /// Includes: RCTs, Meta-Analyses, Systematic Reviews, Clinical Trials,
    /// Reviews, Guidelines, and Practice Guidelines.
    public static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR \
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR \
        Guideline[pt] OR Practice Guideline[pt])
        """

    /// Filter for human studies only.
    public static let humanFilter = "AND humans[MeSH]"

    /// Filter for English language articles.
    public static let englishFilter = "AND English[lang]"

    /// Combined filter for clinical human studies in English.
    public static let combinedClinicalFilter = """
        \(clinicalPublicationFilter) \(humanFilter) \(englishFilter)
        """
}
```

## Issue 3: Missing PubMedError.noResults

### Problem

Apps throw `PubMedError.noResults` when search returns empty.

### Current PubMedError Definition

```swift
// In Services/PubMedService.swift
public enum PubMedError: LocalizedError, RetryableError, Sendable {
    case invalidQuery(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)
    case rateLimited
}
```

### Solution: Add noResults Case

```swift
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
        case .invalidQuery(let query):
            return "Invalid search query: \(query)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let statusCode):
            return "Server error (HTTP \(statusCode)). Retrying..."
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        case .rateLimited:
            return "Rate limited. Please wait and try again."
        case .noResults:  // ADD THIS
            return "No results found for the search query"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .networkError, .rateLimited:
            return true
        case .invalidQuery, .httpError, .parseError, .noResults:  // UPDATE THIS
            return false
        }
    }
}
```

## Issue 4: SearchResult Initializer Parameters

### Problem

Apps create `SearchResult` with minimal parameters, but the current initializer requires `query` and `provider`.

### Current Definition

```swift
public struct SearchResult: Sendable {
    public init(
        articles: [SearchArticle],
        totalCount: Int,
        nextCursor: String? = nil,
        nextOffset: Int? = nil,
        query: String,           // Required
        provider: SearchProvider  // Required
    )
}
```

### Solution: Add Convenience Initializer

```swift
public struct SearchResult: Sendable {
    // ... existing properties ...

    /// Full initializer with all parameters.
    public init(
        articles: [SearchArticle],
        totalCount: Int,
        nextCursor: String? = nil,
        nextOffset: Int? = nil,
        query: String,
        provider: SearchProvider
    ) {
        // ... existing implementation ...
    }

    /// Convenience initializer for creating results from merged data.
    public init(
        articles: [SearchArticle],
        totalCount: Int,
        nextCursor: String? = nil,
        nextOffset: Int? = nil
    ) {
        self.articles = articles
        self.totalCount = totalCount
        self.nextCursor = nextCursor
        self.nextOffset = nextOffset
        self.query = ""
        self.provider = .pubmed
    }
}
```

## Complete Change List

### File: BioMedLit.swift

```swift
// BEFORE
public enum BioMedLit {
    public static let version = "1.0.0"
    // ...
}

// AFTER
public enum BioMedLitLib {
    public static let version = "1.0.0"
    // ...
}
```

### File: Utilities/Constants.swift

Add at end of file:
```swift
// MARK: - PubMed Filters

public enum PubMedFilters {
    public static let clinicalPublicationFilter = """
        AND (Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR \
        Systematic Review[pt] OR Clinical Trial[pt] OR Review[pt] OR \
        Guideline[pt] OR Practice Guideline[pt])
        """

    public static let humanFilter = "AND humans[MeSH]"
    public static let englishFilter = "AND English[lang]"
}
```

### File: Services/PubMedService.swift

Add `noResults` case to `PubMedError` enum.

### File: Models/SearchProvider.swift

Add convenience initializer to `SearchResult` struct.

## Step-by-Step Implementation

### Step 1: Rename BioMedLit enum
```bash
# In BioMedLit.swift
sed -i '' 's/public enum BioMedLit/public enum BioMedLitLib/g' \
  Packages/BioMedLit/Sources/BioMedLit/BioMedLit.swift
```

### Step 2: Update internal references
```bash
# Find all internal uses of BioMedLit. prefix
grep -rn "BioMedLit\." Packages/BioMedLit/Sources/ --include="*.swift"
```

Update each to use `BioMedLitLib.` instead.

### Step 3: Add PubMedFilters
Edit `Constants.swift` and add the `PubMedFilters` enum.

### Step 4: Add noResults error
Edit `PubMedService.swift` and add the `noResults` case.

### Step 5: Add convenience initializer
Edit `SearchProvider.swift` (which contains `SearchResult`) and add the convenience initializer.

### Step 6: Build and test package
```bash
cd Packages/BioMedLit
swift build
swift test
```

### Step 7: Update app code
Update both iOS and macOS apps:
```swift
// Change:
BioMedLit.configure(with: config)
// To:
BioMedLitLib.configure(with: config)
```

## Testing

After changes, verify:
- [ ] Package builds: `swift build`
- [ ] Package tests pass: `swift test`
- [ ] iOS app builds with package
- [ ] macOS app builds with package
- [ ] Search services work correctly
- [ ] Full-text services work correctly

## API Compatibility

These changes **break API compatibility**:
- `BioMedLit.configure()` → `BioMedLitLib.configure()`
- `BioMedLit.version` → `BioMedLitLib.version`

Since the package is not yet in production, this is acceptable. Document the change in the package README.
