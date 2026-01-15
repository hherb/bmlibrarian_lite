# Phase 1: Full-Text Service & Model Extensions (macOS)

This document details the implementation of the `FullTextService` actor and `Document` model extensions for the macOS app.

> **Note:** This phase consists primarily of shared code with the iOS implementation. See `../01-fulltext-service-model.md` for the complete implementation details. This document highlights macOS-specific considerations only.

---

## Goals

1. Extend `Document` model to store full-text content (shared)
2. Create `FullTextService` actor with fallback chain (shared)
3. Implement Europe PMC XML retrieval and conversion (shared)
4. Implement Unpaywall PDF lookup (shared)
5. Implement DOI resolution fallback (shared)

---

## Shared Code Files

The following files are identical to the iOS implementation and should be created in the macOS project:

### 1. Document Model Extensions

**File:** `Sources/Models/Document.swift`

Add the same full-text properties as iOS:

```swift
// MARK: - Full Text

/// The full text content (markdown format for XML sources, nil for PDF-only).
var fullTextContent: String?

/// URL to the locally cached PDF file, if available.
var fullTextPDFPath: String?

/// Source of the full text (for display and debugging).
var fullTextSource: String?  // "europepmc", "unpaywall", "doi"

/// When the full text was fetched.
var fullTextFetchedAt: Date?

/// True if full text fetch was attempted but no source was available.
var fullTextUnavailable: Bool = false

// Computed properties: hasFullText, fullTextAttempted, fullTextSourceDisplay
```

### 2. Full-Text Source Enum

**File:** `Sources/Models/FullTextSource.swift` (new file)

Identical to iOS - see `../01-fulltext-service-model.md` for complete implementation.

### 3. Full-Text Service Actor

**File:** `Sources/Services/FullTextService.swift` (new file)

Identical to iOS - see `../01-fulltext-service-model.md` for complete implementation.

### 4. JATS XML Parser

**File:** `Sources/Utilities/JATSXMLParser.swift` (new file)

Identical to iOS - see `../01-fulltext-service-model.md` for complete implementation.

---

## macOS-Specific Considerations

### PDF Caching Location

On macOS, PDF files should be cached in the Application Support directory:

```swift
extension FullTextService {
    /// Get the cache directory for PDF files on macOS.
    static var pdfCacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = appSupport
            .appendingPathComponent("MedicalFactChecker", isDirectory: true)
            .appendingPathComponent("PDFCache", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )

        return cacheDir
    }

    /// Save PDF data to cache and return the file path.
    func cachePDF(data: Data, for pmid: String) throws -> String {
        let fileURL = Self.pdfCacheDirectory
            .appendingPathComponent("\(pmid).pdf")
        try data.write(to: fileURL)
        return fileURL.path
    }
}
```

### Network Configuration

macOS apps may need different timeout settings for enterprise networks:

```swift
init(email: String) {
    self.email = email

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 45  // Longer for macOS
    config.timeoutIntervalForResource = 180  // Longer for large PDFs
    config.waitsForConnectivity = true  // macOS-specific
    self.session = URLSession(configuration: config)
}
```

---

## Constants Extension

Add to `Sources/MacConstants.swift`:

```swift
// MARK: - Full Text Constants

enum MacFullTextLayout {
    /// Viewer dimensions.
    static let viewerMinWidth: CGFloat = 500
    static let viewerIdealWidth: CGFloat = 700
    static let viewerMaxWidth: CGFloat = 900
    static let viewerMinHeight: CGFloat = 600

    /// Split view proportions.
    static let documentListProportion: CGFloat = 0.4
    static let fullTextProportion: CGFloat = 0.6

    /// PDF viewer constraints.
    static let pdfMinWidth: CGFloat = 400
    static let pdfMinHeight: CGFloat = 500
}

enum MacFullTextColors {
    /// Background for markdown viewer.
    static let markdownBackground = Color(NSColor.textBackgroundColor)

    /// Tint for Europe PMC badge.
    static let europePMCTint = Color.blue

    /// Tint for Unpaywall badge.
    static let unpaywallTint = Color.green

    /// Tint for DOI/website badge.
    static let doiTint = Color.orange
}
```

---

## Testing Checklist

### Unit Tests (Shared with iOS)

- [ ] `FullTextService.fetchFullText` with valid PMC ID returns markdown
- [ ] `FullTextService.fetchFullText` with valid DOI returns PDF URL
- [ ] `FullTextService.fetchFullText` with no identifiers returns web URL
- [ ] `JATSXMLParser` correctly extracts title, abstract, and body
- [ ] `JATSXMLParser` handles nested sections correctly
- [ ] `JATSXMLParser` preserves italic/bold formatting
- [ ] Unpaywall response parsing handles missing fields

### macOS-Specific Tests

- [ ] PDF caching works in Application Support directory
- [ ] Network requests respect macOS timeout settings
- [ ] Service works correctly in sandboxed environment

### Test PMC IDs

```
PMC7614751 - Known Europe PMC article with full text
PMC10767826 - Europe PMC 2023 paper (has full text)
```

### Test DOIs

```
10.1371/journal.pone.0303005 - PLOS ONE (open access)
10.1093/nar/gkad894 - NAR Database issue (open access)
```

---

## Files to Create/Modify

### New Files

- `Sources/Models/FullTextSource.swift`
- `Sources/Services/FullTextService.swift`
- `Sources/Utilities/JATSXMLParser.swift`

### Modified Files

- `Sources/Models/Document.swift` (add full-text properties)
- `Sources/MacConstants.swift` (add layout constants)

---

## Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| Document model extensions | Low | Simple property additions |
| FullTextSource enum | Low | Straightforward enum |
| FullTextService actor | Medium | Multiple API integrations |
| JATSXMLParser | Medium | XML parsing with state machine |
| macOS adaptations | Low | Cache directory, timeouts |
| Unit tests | Medium | Mock network responses |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 2: Full-Text UI (macOS)** (`02-fulltext-ui-macos.md`) to implement the macOS-specific user interface components.
