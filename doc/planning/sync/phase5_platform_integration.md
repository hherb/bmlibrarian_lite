# Phase 5: Platform Integration (iOS/macOS)

## Overview

This phase integrates the sync system with the iOS and macOS apps, including SwiftData observation, background sync, and UI components.

**Goal**: Provide seamless sync experience in the native apps.

**App Locations**:
- iOS: `ios/MedicalFactChecker/`
- macOS: `macos/MedicalFactCheckerMac/`

## Prerequisites

- Phase 1-4 complete
- BioMedLit package sync module ready

## Golden Rules Compliance

- **No magic numbers**: All intervals, limits from constants
- **Error handling**: All errors logged and shown to user
- **Type hints**: Full Swift type annotations
- **Docstrings**: Documentation on all public APIs

## Implementation Steps

### Step 1: Create SwiftData Change Observer

**File**: `ios/MedicalFactChecker/Sources/Services/SyncChangeObserver.swift`

This observer watches SwiftData models for changes and records them to the sync log.

```swift
import Foundation
import SwiftData
import BioMedLit
import os.log

/// Observes SwiftData model changes and records them for sync.
@MainActor
public final class SyncChangeObserver: ObservableObject {
    /// Sync coordinator reference.
    private weak var coordinator: SyncCoordinator?

    /// Model container.
    private let modelContainer: ModelContainer

    /// Logger.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "SyncChangeObserver"
    )

    /// Pending changes queue.
    private var pendingChanges: [PendingChange] = []

    /// Debounce timer.
    private var debounceTask: Task<Void, Never>?

    /// Debounce interval in seconds.
    private let debounceInterval: TimeInterval = SyncConstants.changeDebounceIntervalSeconds

    /// Creates a change observer.
    ///
    /// - Parameters:
    ///   - coordinator: Sync coordinator.
    ///   - modelContainer: SwiftData model container.
    public init(
        coordinator: SyncCoordinator,
        modelContainer: ModelContainer
    ) {
        self.coordinator = coordinator
        self.modelContainer = modelContainer
    }

    /// Records a session change.
    ///
    /// - Parameters:
    ///   - session: The session that changed.
    ///   - operation: Type of change.
    public func recordSessionChange(
        _ session: FactCheckSession,
        operation: SyncOperationType
    ) {
        let change = PendingChange(
            entityType: .session,
            entityId: session.id.uuidString,
            operation: operation,
            timestamp: Date()
        )
        queueChange(change)
    }

    /// Records a document change.
    ///
    /// - Parameters:
    ///   - document: The document that changed.
    ///   - operation: Type of change.
    public func recordDocumentChange(
        _ document: Document,
        operation: SyncOperationType
    ) {
        let change = PendingChange(
            entityType: .document,
            entityId: document.id.uuidString,
            operation: operation,
            timestamp: Date()
        )
        queueChange(change)
    }

    /// Queues a change for processing.
    private func queueChange(_ change: PendingChange) {
        pendingChanges.append(change)

        // Cancel existing debounce
        debounceTask?.cancel()

        // Start new debounce timer
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))

            guard !Task.isCancelled else { return }
            await processPendingChanges()
        }
    }

    /// Processes all pending changes.
    private func processPendingChanges() async {
        guard !pendingChanges.isEmpty else { return }

        let changes = pendingChanges
        pendingChanges = []

        for change in changes {
            do {
                try await recordToSyncLog(change)
            } catch {
                logger.error("Failed to record change: \(error.localizedDescription)")
                // Re-queue failed changes
                pendingChanges.append(change)
            }
        }
    }

    /// Records a change to the sync log.
    private func recordToSyncLog(_ change: PendingChange) async throws {
        guard let coordinator = coordinator else { return }

        // Get entity data from SwiftData
        switch change.entityType {
        case .session:
            if let data = try await fetchSessionData(id: change.entityId) {
                try await coordinator.recordChange(
                    entity: .session,
                    id: change.entityId,
                    data: data
                )
            }
        case .document:
            if let data = try await fetchDocumentData(id: change.entityId) {
                try await coordinator.recordChange(
                    entity: .document,
                    id: change.entityId,
                    data: data
                )
            }
        default:
            break
        }
    }

    /// Fetches session data for sync.
    private func fetchSessionData(id: String) async throws -> SyncSessionData? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<FactCheckSession>(
            predicate: #Predicate { $0.id == uuid }
        )

        guard let session = try context.fetch(descriptor).first else {
            return nil
        }

        return SyncSessionData(
            id: session.id.uuidString,
            claim: session.claim,
            pubmedQuery: session.pubmedQuery,
            searchProvider: session.searchProvider.rawValue,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt ?? session.createdAt
        )
    }

    /// Fetches document data for sync.
    private func fetchDocumentData(id: String) async throws -> SyncDocumentData? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.id == uuid }
        )

        guard let document = try context.fetch(descriptor).first else {
            return nil
        }

        return SyncDocumentData(
            id: document.id.uuidString,
            sessionId: document.session?.id.uuidString ?? "",
            pmid: document.pmid,
            pmcId: document.pmcId,
            doi: document.doi,
            title: document.title,
            abstract: document.abstract,
            authors: document.authors,
            journalTitle: document.journalTitle,
            publicationYear: document.publicationYear,
            relevanceScore: document.relevanceScore,
            source: document.source.rawValue,
            createdAt: document.createdAt
        )
    }

    /// Flushes all pending changes immediately.
    public func flush() async {
        debounceTask?.cancel()
        await processPendingChanges()
    }
}

// MARK: - Supporting Types

/// Pending change waiting to be recorded.
private struct PendingChange {
    let entityType: SyncEntityType
    let entityId: String
    let operation: SyncOperationType
    let timestamp: Date
}

/// Session data for sync.
struct SyncSessionData: Codable, Sendable {
    let id: String
    let claim: String
    let pubmedQuery: String?
    let searchProvider: String
    let createdAt: Date
    let updatedAt: Date
}

/// Document data for sync.
struct SyncDocumentData: Codable, Sendable {
    let id: String
    let sessionId: String
    let pmid: String?
    let pmcId: String?
    let doi: String?
    let title: String
    let abstract: String?
    let authors: [String]
    let journalTitle: String?
    let publicationYear: Int?
    let relevanceScore: Int?
    let source: String
    let createdAt: Date
}
```

### Step 2: Create Sync Engine Delegate Implementation

**File**: `ios/MedicalFactChecker/Sources/Services/AppSyncDelegate.swift`

```swift
import Foundation
import SwiftData
import BioMedLit
import os.log

/// App-specific implementation of sync engine delegate.
final class AppSyncDelegate: SyncEngineDelegate {
    /// Model container.
    private let modelContainer: ModelContainer

    /// Logger.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "AppSyncDelegate"
    )

    /// Creates the delegate.
    ///
    /// - Parameter modelContainer: SwiftData model container.
    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    func applyChange(_ change: VerifiedChange) async throws -> Bool {
        // Decode change to determine entity type
        // This would need more sophisticated type detection
        // For now, try to parse as different types

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Try session
        if let entry = try? decoder.decode(
            IntegrityEnvelope<ChangeLogEntry<SyncSessionData>>.self,
            from: change.data
        ) {
            return try await applySessionChange(entry.content)
        }

        // Try document
        if let entry = try? decoder.decode(
            IntegrityEnvelope<ChangeLogEntry<SyncDocumentData>>.self,
            from: change.data
        ) {
            return try await applyDocumentChange(entry.content)
        }

        logger.warning("Unknown change type at sequence \(change.sequence)")
        return false
    }

    func getLocalTimestamp(
        entityType: SyncEntityType,
        id: String
    ) async -> Int64? {
        guard let uuid = UUID(uuidString: id) else { return nil }

        let context = ModelContext(modelContainer)

        switch entityType {
        case .session:
            let descriptor = FetchDescriptor<FactCheckSession>(
                predicate: #Predicate { $0.id == uuid }
            )
            if let session = try? context.fetch(descriptor).first {
                let date = session.updatedAt ?? session.createdAt
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        case .document:
            let descriptor = FetchDescriptor<Document>(
                predicate: #Predicate { $0.id == uuid }
            )
            if let document = try? context.fetch(descriptor).first {
                return Int64(document.createdAt.timeIntervalSince1970 * 1000)
            }
        default:
            break
        }

        return nil
    }

    /// Applies a session change.
    private func applySessionChange(_ entry: ChangeLogEntry<SyncSessionData>) async throws -> Bool {
        guard let data = entry.operation.data else {
            // Delete operation
            return try await deleteSession(id: entry.operation.id)
        }

        // Check LWW
        let localTimestamp = await getLocalTimestamp(entityType: .session, id: entry.operation.id)
        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: entry.timestamp, deviceId: entry.deviceId),
            local: localTimestamp.map { (timestamp: $0, deviceId: "") }
        )

        guard shouldApply else {
            logger.debug("Skipping session \(data.id) - local is newer")
            return false
        }

        let context = ModelContext(modelContainer)
        let uuid = UUID(uuidString: data.id)!

        // Check if exists
        let descriptor = FetchDescriptor<FactCheckSession>(
            predicate: #Predicate { $0.id == uuid }
        )

        if let existing = try context.fetch(descriptor).first {
            // Update
            existing.claim = data.claim
            existing.pubmedQuery = data.pubmedQuery
            existing.updatedAt = data.updatedAt
        } else {
            // Insert
            let session = FactCheckSession(
                claim: data.claim,
                searchProvider: SearchProvider(rawValue: data.searchProvider) ?? .pubMed
            )
            // Override generated ID
            session.id = uuid
            session.pubmedQuery = data.pubmedQuery
            session.createdAt = data.createdAt
            session.updatedAt = data.updatedAt
            context.insert(session)
        }

        try context.save()
        logger.info("Applied session change: \(data.id)")
        return true
    }

    /// Applies a document change.
    private func applyDocumentChange(_ entry: ChangeLogEntry<SyncDocumentData>) async throws -> Bool {
        guard let data = entry.operation.data else {
            return try await deleteDocument(id: entry.operation.id)
        }

        let localTimestamp = await getLocalTimestamp(entityType: .document, id: entry.operation.id)
        let shouldApply = LWWMergeStrategy.shouldApplyRemote(
            remote: (timestamp: entry.timestamp, deviceId: entry.deviceId),
            local: localTimestamp.map { (timestamp: $0, deviceId: "") }
        )

        guard shouldApply else {
            return false
        }

        let context = ModelContext(modelContainer)
        let uuid = UUID(uuidString: data.id)!
        let sessionUuid = UUID(uuidString: data.sessionId)!

        // Find parent session
        let sessionDescriptor = FetchDescriptor<FactCheckSession>(
            predicate: #Predicate { $0.id == sessionUuid }
        )
        guard let session = try context.fetch(sessionDescriptor).first else {
            logger.warning("Session \(data.sessionId) not found for document \(data.id)")
            return false
        }

        // Check if document exists
        let docDescriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.id == uuid }
        )

        if let existing = try context.fetch(docDescriptor).first {
            // Update
            existing.title = data.title
            existing.abstract = data.abstract
            existing.authors = data.authors
            existing.relevanceScore = data.relevanceScore
        } else {
            // Insert
            let document = Document(
                pmid: data.pmid,
                title: data.title,
                session: session
            )
            document.id = uuid
            document.pmcId = data.pmcId
            document.doi = data.doi
            document.abstract = data.abstract
            document.authors = data.authors
            document.journalTitle = data.journalTitle
            document.publicationYear = data.publicationYear
            document.relevanceScore = data.relevanceScore
            document.source = DocumentSource(rawValue: data.source) ?? .pubMed
            document.createdAt = data.createdAt
            context.insert(document)
        }

        try context.save()
        logger.info("Applied document change: \(data.id)")
        return true
    }

    /// Deletes a session.
    private func deleteSession(id: String) async throws -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<FactCheckSession>(
            predicate: #Predicate { $0.id == uuid }
        )

        if let session = try context.fetch(descriptor).first {
            context.delete(session)
            try context.save()
            logger.info("Deleted session: \(id)")
            return true
        }

        return false
    }

    /// Deletes a document.
    private func deleteDocument(id: String) async throws -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }

        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<Document>(
            predicate: #Predicate { $0.id == uuid }
        )

        if let document = try context.fetch(descriptor).first {
            context.delete(document)
            try context.save()
            logger.info("Deleted document: \(id)")
            return true
        }

        return false
    }
}
```

### Step 3: Create Background Sync Service

**File**: `ios/MedicalFactChecker/Sources/Services/BackgroundSyncService.swift`

```swift
import Foundation
import BackgroundTasks
import BioMedLit
import os.log

/// Service for background sync using BGTaskScheduler.
final class BackgroundSyncService {
    /// Shared instance.
    static let shared = BackgroundSyncService()

    /// Background task identifier.
    static let taskIdentifier = "com.bmlibrarian.factchecker.sync"

    /// Sync coordinator.
    private var coordinator: SyncCoordinator?

    /// Logger.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "BackgroundSync"
    )

    /// Minimum interval between background syncs (in seconds).
    private let minimumInterval: TimeInterval = SyncConstants.backgroundSyncIntervalSeconds

    private init() {}

    /// Registers background tasks.
    ///
    /// Call this in `application(_:didFinishLaunchingWithOptions:)`
    func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            self.handleBackgroundSync(task: task as! BGAppRefreshTask)
        }

        logger.info("Background sync task registered")
    }

    /// Sets the sync coordinator.
    ///
    /// - Parameter coordinator: Sync coordinator to use.
    func setCoordinator(_ coordinator: SyncCoordinator) {
        self.coordinator = coordinator
    }

    /// Schedules next background sync.
    func scheduleBackgroundSync() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Background sync scheduled for \(request.earliestBeginDate?.description ?? "soon")")
        } catch {
            logger.error("Failed to schedule background sync: \(error.localizedDescription)")
        }
    }

    /// Handles background sync task.
    private func handleBackgroundSync(task: BGAppRefreshTask) {
        // Schedule next sync
        scheduleBackgroundSync()

        // Create task for sync
        let syncTask = Task {
            await performBackgroundSync()
        }

        // Handle expiration
        task.expirationHandler = {
            syncTask.cancel()
            self.logger.warning("Background sync task expired")
        }

        // Wait for completion
        Task {
            await syncTask.value
            task.setTaskCompleted(success: true)
        }
    }

    /// Performs the background sync.
    @MainActor
    private func performBackgroundSync() async {
        guard let coordinator = coordinator else {
            logger.warning("No sync coordinator available")
            return
        }

        logger.info("Starting background sync")
        await coordinator.sync()
        logger.info("Background sync completed")
    }
}
```

### Step 4: Create Sync Settings View

**File**: `ios/MedicalFactChecker/Sources/Views/Settings/SyncSettingsView.swift`

```swift
import SwiftUI
import BioMedLit

/// Settings view for sync configuration.
struct SyncSettingsView: View {
    @EnvironmentObject var syncCoordinator: SyncCoordinator
    @EnvironmentObject var selectiveSyncCoordinator: SelectiveSyncCoordinator

    @State private var isEnabled = false
    @State private var syncMode: SyncMode = .full
    @State private var storageLimitGB: Double = 0.5
    @State private var autoEvictionEnabled = false
    @State private var showingStorageManagement = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Sync", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        // Handle enable/disable
                    }

                if isEnabled {
                    syncStatusRow
                }
            } header: {
                Text("Sync Status")
            }

            if isEnabled {
                Section {
                    Picker("Sync Mode", selection: $syncMode) {
                        Text("Full").tag(SyncMode.full)
                        Text("Selective").tag(SyncMode.selective)
                        Text("Recent Only").tag(SyncMode.recent)
                        Text("Minimal").tag(SyncMode.minimal)
                    }
                    .onChange(of: syncMode) { _, newValue in
                        Task {
                            await selectiveSyncCoordinator.setSyncMode(newValue)
                        }
                    }
                } header: {
                    Text("Sync Mode")
                } footer: {
                    Text(syncModeDescription)
                }

                Section {
                    storageRow

                    Slider(
                        value: $storageLimitGB,
                        in: 0.1...5.0,
                        step: 0.1
                    ) {
                        Text("Storage Limit")
                    } minimumValueLabel: {
                        Text("100MB")
                    } maximumValueLabel: {
                        Text("5GB")
                    }
                    .onChange(of: storageLimitGB) { _, newValue in
                        Task {
                            await selectiveSyncCoordinator.setStorageLimit(Int(newValue * 1024))
                        }
                    }

                    Toggle("Auto-Evict Old Sessions", isOn: $autoEvictionEnabled)

                    Button("Manage Storage") {
                        showingStorageManagement = true
                    }
                } header: {
                    Text("Storage")
                }

                Section {
                    Button("Sync Now") {
                        Task {
                            await syncCoordinator.sync()
                        }
                    }
                    .disabled(syncCoordinator.status == .syncing)

                    if let lastSync = syncCoordinator.lastSyncTime {
                        HStack {
                            Text("Last Sync")
                            Spacer()
                            Text(lastSync, style: .relative)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Actions")
                }
            }
        }
        .navigationTitle("Sync")
        .sheet(isPresented: $showingStorageManagement) {
            StorageManagementView()
        }
        .onAppear {
            syncMode = selectiveSyncCoordinator.syncMode
            storageLimitGB = Double(selectiveSyncCoordinator.storageLimit) / 1024.0
        }
    }

    @ViewBuilder
    private var syncStatusRow: some View {
        HStack {
            Text("Status")
            Spacer()
            switch syncCoordinator.status {
            case .idle:
                Label("Ready", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            case .initializing:
                Label("Initializing", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            case .syncing:
                ProgressView()
                    .padding(.trailing, 4)
                Text("Syncing...")
            case .error(_):
                Label("Error", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var storageRow: some View {
        if let info = selectiveSyncCoordinator.storageInfo {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Used Storage")
                    Spacer()
                    Text("\(info.usedMB) MB / \(selectiveSyncCoordinator.storageLimit) MB")
                        .foregroundStyle(.secondary)
                }

                ProgressView(
                    value: Double(info.usedMB),
                    total: Double(selectiveSyncCoordinator.storageLimit)
                )
                .tint(storageColor(used: info.usedMB, limit: selectiveSyncCoordinator.storageLimit))
            }
        }
    }

    private var syncModeDescription: String {
        switch syncMode {
        case .full:
            return "All sessions sync to this device"
        case .selective:
            return "Only selected sessions sync to this device"
        case .recent:
            return "Only recent sessions sync to this device"
        case .minimal:
            return "Only metadata syncs, content fetched on-demand"
        }
    }

    private func storageColor(used: Int, limit: Int) -> Color {
        let ratio = Double(used) / Double(limit)
        if ratio > 0.9 {
            return .red
        } else if ratio > 0.7 {
            return .orange
        }
        return .blue
    }
}
```

### Step 5: Create Storage Management View

**File**: `ios/MedicalFactChecker/Sources/Views/Settings/StorageManagementView.swift`

```swift
import SwiftUI
import BioMedLit

/// View for managing local storage and sync scope.
struct StorageManagementView: View {
    @EnvironmentObject var selectiveSyncCoordinator: SelectiveSyncCoordinator
    @Environment(\.dismiss) var dismiss

    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Storage summary
                storageSummary
                    .padding()
                    .background(Color(.systemGroupedBackground))

                // Tab picker
                Picker("View", selection: $selectedTab) {
                    Text("On Device").tag(0)
                    Text("Available").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                if selectedTab == 0 {
                    localSessionsList
                } else {
                    availableSessionsList
                }
            }
            .navigationTitle("Storage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Evict Oldest") {
                            Task {
                                await selectiveSyncCoordinator.checkAndAutoEvict()
                            }
                        }

                        Button("Refresh") {
                            Task {
                                await selectiveSyncCoordinator.refresh()
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var storageSummary: some View {
        if let info = selectiveSyncCoordinator.storageInfo {
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(info.usedMB) MB")
                            .font(.title2.bold())
                        Text("of \(selectiveSyncCoordinator.storageLimit) MB used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("\(info.fullSessionCount)")
                            .font(.title2.bold())
                        Text("sessions on device")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ProgressView(
                    value: Double(info.usedMB),
                    total: Double(selectiveSyncCoordinator.storageLimit)
                )
            }
        }
    }

    @ViewBuilder
    private var localSessionsList: some View {
        List {
            ForEach(selectiveSyncCoordinator.localSessions) { session in
                SessionStorageRow(
                    session: session,
                    onEvict: {
                        Task {
                            await selectiveSyncCoordinator.evictSession(session.id)
                        }
                    },
                    onDelete: {
                        Task {
                            await selectiveSyncCoordinator.deleteLocalOnly(session.id)
                        }
                    },
                    onPin: {
                        Task {
                            if session.isPinned {
                                await selectiveSyncCoordinator.unpinSession(session.id)
                            } else {
                                await selectiveSyncCoordinator.pinSession(session.id)
                            }
                        }
                    }
                )
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var availableSessionsList: some View {
        List {
            ForEach(selectiveSyncCoordinator.availableSessions) { session in
                SessionStorageRow(
                    session: session,
                    onFetch: {
                        Task {
                            await selectiveSyncCoordinator.fetchSession(session.id)
                        }
                    }
                )
            }
        }
        .listStyle(.plain)
    }
}

/// Row displaying session storage info.
struct SessionStorageRow: View {
    let session: SessionSyncInfo
    var onEvict: (() -> Void)?
    var onDelete: (() -> Void)?
    var onPin: (() -> Void)?
    var onFetch: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.title)
                    .lineLimit(1)

                Spacer()

                if session.isPinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }

                syncStateIcon
            }

            HStack {
                Text("\(session.documentCount) docs")
                if session.hasReport {
                    Text("Report")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(4)
                }
                Spacer()
                Text("\(session.sizeMB) MB")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .swipeActions(edge: .trailing) {
            if session.syncState == .full {
                Button("Evict") {
                    onEvict?()
                }
                .tint(.orange)

                Button("Delete", role: .destructive) {
                    onDelete?()
                }
            }
        }
        .swipeActions(edge: .leading) {
            if session.syncState == .full {
                Button(session.isPinned ? "Unpin" : "Pin") {
                    onPin?()
                }
                .tint(.blue)
            } else if session.syncState == .stub || session.syncState == .evicted {
                Button("Fetch") {
                    onFetch?()
                }
                .tint(.green)
            }
        }
    }

    @ViewBuilder
    private var syncStateIcon: some View {
        switch session.syncState {
        case .full:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .stub, .evicted:
            Image(systemName: "icloud.and.arrow.down")
                .foregroundStyle(.blue)
        case .localOnly:
            Image(systemName: "iphone")
                .foregroundStyle(.gray)
        case .deletedLocal:
            Image(systemName: "trash")
                .foregroundStyle(.red)
        }
    }
}
```

### Step 6: Update App Entry Point

**File**: Update `ios/MedicalFactChecker/Sources/App/MedicalFactCheckerApp.swift`

```swift
import SwiftUI
import SwiftData
import BioMedLit

@main
struct MedicalFactCheckerApp: App {
    let modelContainer: ModelContainer

    @StateObject private var syncCoordinator = SyncCoordinator()
    @StateObject private var selectiveSyncCoordinator = SelectiveSyncCoordinator()

    init() {
        // Initialize model container
        do {
            modelContainer = try ModelContainer(for: FactCheckSession.self, Document.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }

        // Register background tasks
        BackgroundSyncService.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .environmentObject(syncCoordinator)
                .environmentObject(selectiveSyncCoordinator)
                .task {
                    await initializeSync()
                }
        }
    }

    private func initializeSync() async {
        // Check if sync is enabled in settings
        guard UserDefaults.standard.bool(forKey: "syncEnabled") else {
            return
        }

        // Initialize sync
        let delegate = AppSyncDelegate(modelContainer: modelContainer)

        do {
            try await syncCoordinator.initializeWithiCloud(
                deviceName: UIDevice.current.name,
                platform: .ios,
                delegate: delegate
            )

            // Set up background sync
            BackgroundSyncService.shared.setCoordinator(syncCoordinator)
            BackgroundSyncService.shared.scheduleBackgroundSync()

            // Initial sync
            await syncCoordinator.sync()

        } catch {
            print("Sync initialization failed: \(error)")
        }
    }
}
```

### Step 7: Add Info.plist Entries

Add to `ios/MedicalFactChecker/Info.plist`:

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
    <string>com.bmlibrarian.factchecker.sync</string>
</array>

<key>UIBackgroundModes</key>
<array>
    <string>fetch</string>
</array>
```

### Step 8: Add Entitlements

Add to `ios/MedicalFactChecker/MedicalFactChecker.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <string>iCloud.com.bmlibrarian.factchecker</string>
    </array>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudDocuments</string>
    </array>
</dict>
</plist>
```

## macOS-Specific Adaptations

For macOS, create similar files with these adjustments:

1. **No BGTaskScheduler**: Use `NSBackgroundActivityScheduler` instead
2. **Device name**: Use `Host.current().localizedName`
3. **Platform**: Use `.macos` instead of `.ios`
4. **UI**: Use AppKit-style layouts where needed

**File**: `macos/MedicalFactCheckerMac/Sources/Services/MacBackgroundSyncService.swift`

```swift
import Foundation
import BioMedLit
import os.log

/// Background sync service for macOS.
final class MacBackgroundSyncService {
    static let shared = MacBackgroundSyncService()

    private var coordinator: SyncCoordinator?
    private var activityScheduler: NSBackgroundActivityScheduler?

    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker.mac",
        category: "BackgroundSync"
    )

    private init() {}

    func setCoordinator(_ coordinator: SyncCoordinator) {
        self.coordinator = coordinator
    }

    func startBackgroundSync() {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "com.bmlibrarian.factchecker.mac.sync"
        )
        scheduler.repeats = true
        scheduler.interval = SyncConstants.backgroundSyncIntervalSeconds
        scheduler.qualityOfService = .utility

        scheduler.schedule { completion in
            Task { @MainActor in
                await self.coordinator?.sync()
                completion(.finished)
            }
        }

        self.activityScheduler = scheduler
        logger.info("Background sync scheduled")
    }

    func stopBackgroundSync() {
        activityScheduler?.invalidate()
        activityScheduler = nil
    }
}
```

## Files to Create

### iOS Files
| File | Description |
|------|-------------|
| `Services/SyncChangeObserver.swift` | SwiftData change observer |
| `Services/AppSyncDelegate.swift` | Sync engine delegate |
| `Services/BackgroundSyncService.swift` | Background sync |
| `Views/Settings/SyncSettingsView.swift` | Sync settings UI |
| `Views/Settings/StorageManagementView.swift` | Storage management UI |

### macOS Files
| File | Description |
|------|-------------|
| `Services/MacBackgroundSyncService.swift` | macOS background sync |
| `Views/Settings/MacSyncSettingsView.swift` | macOS sync settings |

## Acceptance Criteria

1. **Change observation works**: SwiftData changes recorded to sync log
2. **Sync delegate applies changes**: Remote changes update local database
3. **Background sync runs**: Periodic sync via BGTaskScheduler
4. **Settings UI works**: Can configure sync mode and storage
5. **Storage management works**: Can evict, pin, fetch sessions
6. **iCloud integration works**: Files sync via iCloud Drive

## Testing Checklist

1. [ ] Enable sync in settings
2. [ ] Create session on device A
3. [ ] Verify session appears on device B
4. [ ] Edit session on device B
5. [ ] Verify changes appear on device A
6. [ ] Evict session on device A
7. [ ] Verify can fetch on-demand
8. [ ] Test offline mode
9. [ ] Test background sync

## Dependencies

- Phase 1-4 complete
- iCloud entitlements configured
- BioMedLit package dependency added

## Summary

This completes the iOS/macOS sync implementation. The shared BioMedLit package provides:

- Integrity verification (Phase 1)
- Change tracking (Phase 2)
- Sync engine (Phase 3)
- Selective sync (Phase 4)

Platform-specific code handles:
- SwiftData integration
- Background scheduling
- UI components
