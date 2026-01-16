# Phase 4: Full-Text & PDF Sync

## Objective

Enable optional synchronization of downloaded PDFs and full-text content across devices, with user control over storage usage.

## Storage Considerations

### iCloud Storage Limits

- Free tier: 5 GB total (shared across all apps)
- PDFs average 1-5 MB each
- A typical session might download 10-20 PDFs = 10-100 MB
- Heavy users could accumulate hundreds of PDFs

### Strategy Options

| Option | Pros | Cons |
|--------|------|------|
| **A: No PDF sync** | Simple, no quota issues | Must re-download on each device |
| **B: Sync all PDFs** | Full access everywhere | Can hit quota limits |
| **C: User choice** | Flexible | More complex UI |
| **D: On-demand sync** | Best of both worlds | Most complex |

**Recommendation:** Option D (on-demand) with Option C fallback

## Implementation

### Task 4.1: Create iCloud Documents Container

PDFs should use iCloud Drive (separate from CloudKit database) for better file management.

**Xcode Configuration:**

1. Add **iCloud Documents** capability (in addition to CloudKit)
2. Create documents container: `iCloud.com.yourcompany.MedicalFactChecker.Documents`

This adds to entitlements:
```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.yourcompany.MedicalFactChecker</string>
    <string>iCloud.com.yourcompany.MedicalFactChecker.Documents</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.com.yourcompany.MedicalFactChecker.Documents</string>
</array>
```

### Task 4.2: Create Cloud Document Manager

**File:** `Sources/Services/CloudDocumentManager.swift` (both platforms)

```swift
import Foundation

/// Manages PDF and full-text document storage in iCloud Drive
final class CloudDocumentManager {
    static let shared = CloudDocumentManager()

    /// Container identifier for documents
    private let containerIdentifier = "iCloud.com.yourcompany.MedicalFactChecker.Documents"

    /// Local cache directory for downloaded cloud documents
    private var localCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudDocuments", isDirectory: true)
    }

    /// iCloud Documents container URL (nil if unavailable)
    private var cloudContainerURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Whether cloud document storage is available
    var isCloudStorageAvailable: Bool {
        cloudContainerURL != nil && CloudKitConfiguration.isSyncEnabled
    }

    private init() {
        createLocalCacheDirectory()
    }

    private func createLocalCacheDirectory() {
        try? FileManager.default.createDirectory(
            at: localCacheURL,
            withIntermediateDirectories: true
        )
    }

    // MARK: - PDF Storage

    /// Save PDF to cloud storage
    /// - Parameters:
    ///   - data: PDF data
    ///   - documentId: Document identifier (e.g., "pmid-12345678")
    /// - Returns: Relative path for storage in Document model
    func savePDF(_ data: Data, for documentId: String) async throws -> String {
        let filename = "\(documentId).pdf"

        if isCloudStorageAvailable, let cloudURL = cloudContainerURL {
            // Save to iCloud
            let fileURL = cloudURL.appendingPathComponent(filename)
            try await createCloudDirectoryIfNeeded()
            try data.write(to: fileURL)
            return "cloud://\(filename)"
        } else {
            // Save locally
            let fileURL = localCacheURL.appendingPathComponent(filename)
            try data.write(to: fileURL)
            return "local://\(filename)"
        }
    }

    /// Get PDF data for a document
    /// - Parameter path: Path returned from savePDF
    /// - Returns: PDF data if available
    func getPDF(at path: String) async throws -> Data? {
        let (scheme, filename) = parsePath(path)

        switch scheme {
        case "cloud":
            return try await getCloudPDF(filename: filename)
        case "local":
            return getLocalPDF(filename: filename)
        default:
            // Legacy path - try local
            return getLocalPDF(filename: path)
        }
    }

    /// Check if PDF exists and is downloaded
    /// - Parameter path: Path returned from savePDF
    /// - Returns: Availability status
    func pdfStatus(at path: String) -> PDFStatus {
        let (scheme, filename) = parsePath(path)

        switch scheme {
        case "cloud":
            return cloudPDFStatus(filename: filename)
        case "local":
            let url = localCacheURL.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? .available : .notFound
        default:
            return .notFound
        }
    }

    // MARK: - Full-Text Content Storage

    /// Save full-text markdown content
    func saveFullText(_ content: String, for documentId: String) async throws -> String {
        let filename = "\(documentId).md"
        let data = content.data(using: .utf8) ?? Data()

        if isCloudStorageAvailable, let cloudURL = cloudContainerURL {
            let fileURL = cloudURL.appendingPathComponent("fulltext", isDirectory: true)
                .appendingPathComponent(filename)
            try await createCloudDirectoryIfNeeded(subdirectory: "fulltext")
            try data.write(to: fileURL)
            return "cloud://fulltext/\(filename)"
        } else {
            let fileURL = localCacheURL.appendingPathComponent(filename)
            try data.write(to: fileURL)
            return "local://\(filename)"
        }
    }

    /// Get full-text content
    func getFullText(at path: String) async throws -> String? {
        guard let data = try await getPDF(at: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Cloud File Operations

    private func createCloudDirectoryIfNeeded(subdirectory: String? = nil) async throws {
        guard let cloudURL = cloudContainerURL else { return }

        var targetURL = cloudURL
        if let subdir = subdirectory {
            targetURL = cloudURL.appendingPathComponent(subdir, isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.createDirectory(
                at: targetURL,
                withIntermediateDirectories: true
            )
        }
    }

    private func getCloudPDF(filename: String) async throws -> Data? {
        guard let cloudURL = cloudContainerURL else { return nil }

        let fileURL = cloudURL.appendingPathComponent(filename)

        // Check if file needs downloading
        var isDownloaded = false
        var isDownloading = false

        if let resourceValues = try? fileURL.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]) {
            isDownloaded = resourceValues.ubiquitousItemDownloadingStatus == .current
            isDownloading = resourceValues.ubiquitousItemIsDownloading ?? false
        }

        if !isDownloaded && !isDownloading {
            // Trigger download
            try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)

            // Wait for download (with timeout)
            try await waitForDownload(fileURL: fileURL, timeout: 60)
        }

        return try Data(contentsOf: fileURL)
    }

    private func waitForDownload(fileURL: URL, timeout: TimeInterval) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey
            ]), resourceValues.ubiquitousItemDownloadingStatus == .current {
                return
            }

            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        throw CloudDocumentError.downloadTimeout
    }

    private func getLocalPDF(filename: String) -> Data? {
        let url = localCacheURL.appendingPathComponent(filename)
        return try? Data(contentsOf: url)
    }

    private func cloudPDFStatus(filename: String) -> PDFStatus {
        guard let cloudURL = cloudContainerURL else { return .notFound }

        let fileURL = cloudURL.appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .notFound
        }

        if let resourceValues = try? fileURL.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey
        ]) {
            if resourceValues.ubiquitousItemDownloadingStatus == .current {
                return .available
            }
            if resourceValues.ubiquitousItemIsDownloading == true {
                return .downloading
            }
            return .inCloud
        }

        return .available
    }

    private func parsePath(_ path: String) -> (scheme: String, filename: String) {
        if path.hasPrefix("cloud://") {
            return ("cloud", String(path.dropFirst(8)))
        } else if path.hasPrefix("local://") {
            return ("local", String(path.dropFirst(8)))
        }
        return ("unknown", path)
    }

    // MARK: - Storage Management

    /// Calculate total cloud storage used by documents
    func cloudStorageUsed() async -> Int64 {
        guard let cloudURL = cloudContainerURL else { return 0 }

        var totalSize: Int64 = 0

        if let enumerator = FileManager.default.enumerator(
            at: cloudURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    /// Delete cloud document
    func deleteCloudDocument(at path: String) throws {
        let (scheme, filename) = parsePath(path)

        guard scheme == "cloud", let cloudURL = cloudContainerURL else { return }

        let fileURL = cloudURL.appendingPathComponent(filename)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Clear local cache
    func clearLocalCache() throws {
        try FileManager.default.removeItem(at: localCacheURL)
        createLocalCacheDirectory()
    }
}

// MARK: - Supporting Types

enum PDFStatus {
    case available      // Downloaded and ready
    case inCloud        // In iCloud, needs download
    case downloading    // Currently downloading
    case notFound       // Doesn't exist
}

enum CloudDocumentError: Error, LocalizedError {
    case downloadTimeout
    case cloudUnavailable
    case writeError(Error)

    var errorDescription: String? {
        switch self {
        case .downloadTimeout:
            return "Download timed out. Please try again."
        case .cloudUnavailable:
            return "iCloud storage is not available."
        case .writeError(let error):
            return "Failed to save document: \(error.localizedDescription)"
        }
    }
}
```

### Task 4.3: Update Document Model

Add helper methods to `Document.swift`:

```swift
extension Document {
    /// PDF availability status
    var pdfStatus: PDFStatus {
        guard let path = fullTextPDFPath else { return .notFound }
        return CloudDocumentManager.shared.pdfStatus(at: path)
    }

    /// Whether PDF is stored in cloud
    var isPDFInCloud: Bool {
        fullTextPDFPath?.hasPrefix("cloud://") ?? false
    }

    /// Get PDF data (may trigger download)
    func loadPDF() async throws -> Data? {
        guard let path = fullTextPDFPath else { return nil }
        return try await CloudDocumentManager.shared.getPDF(at: path)
    }
}
```

### Task 4.4: Update FullTextService

Modify `FullTextService` to use `CloudDocumentManager`:

```swift
// In FullTextService.swift

/// Save downloaded PDF
private func savePDF(_ data: Data, for document: Document) async throws {
    let path = try await CloudDocumentManager.shared.savePDF(data, for: document.id)
    document.fullTextPDFPath = path
}

/// Save extracted full-text content
private func saveFullText(_ content: String, for document: Document) async throws {
    // Store markdown in the model directly (syncs via CloudKit)
    document.fullTextContent = content
}
```

### Task 4.5: PDF Download Status UI

Show download status in document cards:

**File:** `Sources/Views/Components/PDFStatusIndicator.swift`

```swift
import SwiftUI

/// Shows PDF availability and download status
struct PDFStatusIndicator: View {
    let document: Document
    @State private var isDownloading = false

    var body: some View {
        HStack(spacing: 4) {
            switch document.pdfStatus {
            case .available:
                Image(systemName: "doc.fill")
                    .foregroundStyle(.green)
                Text("PDF")
                    .font(.caption2)

            case .inCloud:
                Button {
                    triggerDownload()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundStyle(.blue)
                        Text("Download")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)

            case .downloading:
                ProgressView()
                    .scaleEffect(0.6)
                Text("Downloading...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

            case .notFound:
                EmptyView()
            }
        }
    }

    private func triggerDownload() {
        isDownloading = true
        Task {
            _ = try? await document.loadPDF()
            isDownloading = false
        }
    }
}
```

### Task 4.6: Storage Settings Section

Add storage management to settings:

**File:** `Sources/Views/Settings/CloudStorageSection.swift`

```swift
import SwiftUI

/// Settings section for cloud storage management
struct CloudStorageSection: View {
    @State private var cloudStorageUsed: Int64 = 0
    @State private var isCalculating = false
    @State private var showingClearConfirmation = false

    var body: some View {
        Section {
            // Storage usage
            HStack {
                Text("iCloud Documents")
                Spacer()
                if isCalculating {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: cloudStorageUsed, countStyle: .file))
                        .foregroundStyle(.secondary)
                }
            }

            // PDF sync toggle
            Toggle("Sync PDFs to iCloud", isOn: .constant(true))

            // Clear cache
            Button("Clear Local Cache") {
                showingClearConfirmation = true
            }
            .foregroundStyle(.red)
        } header: {
            Text("Document Storage")
        } footer: {
            Text("PDFs are stored in iCloud Drive and download on-demand to save device storage.")
        }
        .task {
            await calculateStorage()
        }
        .confirmationDialog(
            "Clear Local Cache?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                clearCache()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove downloaded PDFs from this device. They can be re-downloaded from iCloud.")
        }
    }

    private func calculateStorage() async {
        isCalculating = true
        cloudStorageUsed = await CloudDocumentManager.shared.cloudStorageUsed()
        isCalculating = false
    }

    private func clearCache() {
        try? CloudDocumentManager.shared.clearLocalCache()
    }
}
```

### Task 4.7: Migration for Existing Documents

Handle documents created before cloud sync was enabled:

**File:** `Sources/Utilities/DocumentMigration.swift`

```swift
import Foundation
import SwiftData

/// Migrates existing local documents to cloud storage
final class DocumentMigration {

    /// Migrate local PDFs to cloud storage
    /// - Parameter modelContext: SwiftData context
    /// - Returns: Number of documents migrated
    @MainActor
    static func migrateToCloud(modelContext: ModelContext) async -> Int {
        guard CloudDocumentManager.shared.isCloudStorageAvailable else { return 0 }

        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { document in
                document.fullTextPDFPath != nil
            }
        )

        guard let documents = try? modelContext.fetch(descriptor) else { return 0 }

        var migratedCount = 0

        for document in documents {
            guard let path = document.fullTextPDFPath,
                  !path.hasPrefix("cloud://"),
                  let data = try? await CloudDocumentManager.shared.getPDF(at: path) else {
                continue
            }

            do {
                let cloudPath = try await CloudDocumentManager.shared.savePDF(data, for: document.id)
                document.fullTextPDFPath = cloudPath
                migratedCount += 1
            } catch {
                print("Failed to migrate document \(document.id): \(error)")
            }
        }

        try? modelContext.save()
        return migratedCount
    }
}
```

## Storage Optimization Options

### Option A: Aggressive (Default)

- Always save to cloud when available
- Auto-evict local copies after 7 days
- Re-download on demand

### Option B: Conservative

- Keep local copies always
- Upload to cloud as backup
- Never auto-delete

### Option C: User Choice

Add settings toggle:
- "Optimize Storage" - evict old local files
- "Keep All Downloads" - preserve everything locally

## Verification Steps

- [ ] PDFs save to iCloud Documents container
- [ ] PDF status indicator shows correct state
- [ ] Cloud PDFs download on-demand
- [ ] Download progress shown
- [ ] Storage usage calculated correctly
- [ ] Clear cache works
- [ ] Migration handles existing documents
- [ ] Works when iCloud unavailable (local fallback)

## Files Created/Modified

| File | Platform | Status |
|------|----------|--------|
| `CloudDocumentManager.swift` | Both | New |
| `PDFStatusIndicator.swift` | Both | New |
| `CloudStorageSection.swift` | Both | New |
| `DocumentMigration.swift` | Both | New |
| `Document.swift` | Both | Modified |
| `FullTextService.swift` | Both | Modified |
| Entitlements files | Both | Modified (add Documents container) |

## Next Phase

Proceed to [Phase 5: Testing & Migration](05-phase5-testing.md) for comprehensive testing and production rollout.
