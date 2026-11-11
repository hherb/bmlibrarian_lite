// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import Foundation
import BmlibCore

/// What a refresh of the stored index did.
public enum RetractionIndexRefresh: Equatable, Sendable {
    /// The stored index is current; nothing was downloaded.
    case fresh
    /// A new index was built and stored.
    case refreshed(noticeCount: UInt64)
    /// The export itself was refused (bmlib could not build it, or it shrank)
    /// and is not downloaded again for a day; the previous file is kept.
    /// The text is for the log: it is this library's, never the provider's.
    case refused(String)
    /// The export was built but could not be written here (a full disk, or
    /// file protection while the device is locked), or too little space was
    /// free to download it (#702). Nothing was learned about the export, so
    /// no wait is recorded: the next refresh tries again (#700). The
    /// previous file is kept.
    case notStored
    /// The download failed; the previous file is kept.
    case failed(RequestFailure)
}

/// The Retraction Watch export, kept as bmlib's index file (the desktop's
/// `retraction_export.py`). An index is consulted only while current; a
/// refresh replaces the file atomically, and any refusal keeps the old one.
public actor RetractionIndexStore {
    private let directory: URL
    /// Internal so a test can see which session ``production(email:)`` built.
    let session: URLSession
    private let email: String
    /// bmlib's `buildRetractionIndex`; a test injects one it can hold.
    private let build: @Sendable (Data, String) throws -> RetractionIndexBuild
    /// The free space at the index's folder (`nil`: unknown); a test stands in for a full disk.
    private let freeBytes: @Sendable (URL) -> Int64?
    /// The download under way, which every caller meanwhile awaits.
    private var inFlight: Task<RetractionIndexRefresh, Never>?

    /// - Parameters:
    ///   - directory: Where the index file lives.
    ///   - session: The session the export is downloaded over; production
    ///     uses ``wifiOnlyConfiguration()``.
    ///   - email: Contact address, sent as `mailto=` and in the User-Agent,
    ///     as the desktop's download does.
    public init(directory: URL, session: URLSession, email: String) {
        self.init(directory: directory, session: session, email: email) {
            try buildRetractionIndex(csv: $0, dataAsOf: $1)
        }
    }

    init(
        directory: URL,
        session: URLSession,
        email: String,
        freeBytes: @escaping @Sendable (URL) -> Int64? = RetractionIndexStore.availableBytes(at:),
        build: @escaping @Sendable (Data, String) throws -> RetractionIndexBuild
    ) {
        self.directory = directory
        self.session = session
        self.email = email
        self.freeBytes = freeBytes
        self.build = build
    }

    /// The space free for important use on `directory`'s volume, made first
    /// (a missing folder has no resource values); `nil` when unknown. A
    /// folder that cannot be made has none, as Android's `usableSpace`: the
    /// index could not be written there, so nothing is downloaded.
    static func availableBytes(at directory: URL) -> Int64? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            BioMedLitLib.logger?.warning("Retraction Watch folder not made: \(error)", category: .network)
            return 0
        }
        return (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The store the app uses: ``productionDirectory`` over a Wi-Fi-only session.
    ///
    /// - Parameter email: Contact address for Crossref.
    public static func production(email: String) -> RetractionIndexStore {
        RetractionIndexStore(
            directory: productionDirectory,
            session: URLSession(configuration: wifiOnlyConfiguration()),
            email: email
        )
    }

    /// Application Support/``BioMedLitConstants/appSupportFolderName``/``BioMedLitConstants/retractionFolderName``.
    public static var productionDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(BioMedLitConstants.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.retractionFolderName, isDirectory: true)
    }

    /// The export's session configuration: the ~68 MB download never uses
    /// cellular or Low Data Mode networks.
    public static func wifiOnlyConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        config.timeoutIntervalForRequest = BioMedLitConstants.retractionWatchDownloadTimeoutSeconds
        return config
    }

    private nonisolated var file: URL { directory.appendingPathComponent(BioMedLitConstants.retractionIndexFileName) }

    /// When a download was last refused, and why, kept across launches; the next waits a day (#647).
    private nonisolated var refusalFile: URL {
        directory.appendingPathComponent("\(BioMedLitConstants.retractionIndexFileName).refused")
    }

    /// The last refusal's time and reason; `nil` when there is none (or its
    /// record is unreadable, so a download may be tried).
    private func lastRefusal() -> (at: Date, reason: String)? {
        guard let text = try? String(contentsOf: refusalFile, encoding: .utf8) else { return nil }
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let seconds = TimeInterval(parts[0]) else {
            BioMedLitLib.logger?.warning("Retraction Watch refusal unreadable", category: .network)
            return nil
        }
        return (Date(timeIntervalSince1970: seconds), String(parts[1]))
    }

    /// Record a refusal at `at`, so the next launch waits out the day too.
    private func recordRefusal(at: Date, reason: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "\(at.timeIntervalSince1970)\n\(reason)".write(to: refusalFile, atomically: true, encoding: .utf8)
        } catch {
            BioMedLitLib.logger?.warning("Retraction Watch refusal not recorded: \(error)", category: .network)
        }
    }

    /// The stored index, whatever its age; `nil` when missing or unreadable.
    private nonisolated func storedIndex() -> RetractionIndex? {
        let bytes: Data
        do {
            bytes = try Data(contentsOf: file)
        } catch {
            // unreadable is not absent: say so, though both download it again (#647)
            if FileManager.default.fileExists(atPath: file.path) {
                BioMedLitLib.logger?.warning("Retraction Watch index file unreadable: \(error)", category: .network)
            }
            return nil
        }
        do {
            return try RetractionIndex.fromBytes(bytes: bytes)
        } catch {
            BioMedLitLib.logger?.warning("Retraction Watch index unreadable: \(error)", category: .network)
            return nil
        }
    }

    /// The index to consult.
    ///
    /// - Parameter now: The current time.
    /// - Returns: `nil` when the file is missing, unreadable, or its
    ///   `dataAsOf` is more than ``BioMedLitConstants/retractionWatchMaxAgeDays``
    ///   days before `now`'s day (UTC): the export is then not consulted.
    ///
    /// Nonisolated, so a run never waits for a refresh building the index;
    /// the file is replaced atomically, so it reads the old copy or the new.
    public nonisolated func currentIndex(now: Date) async -> RetractionIndex? {
        storedIndex().flatMap { Self.isCurrent($0, now: now) ? $0 : nil }
    }

    /// Whether `index` may be consulted at `now`: its `dataAsOf` is at most
    /// ``BioMedLitConstants/retractionWatchMaxAgeDays`` days before `now`'s day (UTC).
    private static func isCurrent(_ index: RetractionIndex, now: Date) -> Bool {
        guard let asOf = dayFormatter.date(from: index.dataAsOf()),
              let today = dayFormatter.date(from: dayFormatter.string(from: now)),
              let age = utcCalendar.dateComponents([.day], from: asOf, to: today).day
        else { return false }
        return age <= BioMedLitConstants.retractionWatchMaxAgeDays
    }

    /// Download and store a new index unless the stored one is current.
    ///
    /// bmlib builds the index, dated `now`'s day; one under
    /// ``BioMedLitConstants/retractionWatchMinKeepRatio`` of the stored
    /// index's notices is refused as truncated.
    ///
    /// A refused download is not tried again for
    /// ``BioMedLitConstants/retractionWatchRefusedBackoffSeconds``, across
    /// launches; meanwhile the refusal is returned again.
    ///
    /// One download at a time: a call made while one is under way awaits
    /// it (the launch's and a run's refresh never download twice). The
    /// download is not the caller's task, so cancelling a caller leaves it
    /// running for the others.
    ///
    /// - Parameter now: The current time.
    /// - Returns: What happened; on anything but `.refreshed` the file is
    ///   untouched. This never throws.
    public func refreshIfStale(now: Date) async -> RetractionIndexRefresh {
        if let inFlight { return await inFlight.value }
        let task = Task { await self.refresh(now: now) }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    /// ``refreshIfStale(now:)``'s work, run once per download.
    private func refresh(now: Date) async -> RetractionIndexRefresh {
        // Parsed once, and only its count kept through the download (#647).
        let stored = storedIndex().map { (current: Self.isCurrent($0, now: now), notices: $0.noticeCount()) }
        if stored?.current == true { return .fresh }
        // a refusal dated ahead of `now` (a clock set back since) is not waited out
        if let refusal = lastRefusal(),
           (0..<BioMedLitConstants.retractionWatchRefusedBackoffSeconds).contains(now.timeIntervalSince(refusal.at)) {
            return .refused(refusal.reason)
        }
        // unknown free space is no reason to skip: the write still reports a failure
        if let free = freeBytes(directory), free < BioMedLitConstants.retractionWatchMinFreeBytes {
            BioMedLitLib.logger?.warning(
                "Retraction Watch export not downloaded: \(free) bytes free, \(BioMedLitConstants.retractionWatchMinFreeBytes) needed",
                category: .network)
            return .notStored
        }
        let outcome = await download(now: now, storedNotices: stored?.notices)
        if case .refused(let reason) = outcome {
            recordRefusal(at: now, reason: reason)
        } else if case .refreshed = outcome {
            try? FileManager.default.removeItem(at: refusalFile)
        }
        return outcome
    }

    /// Download and build the export, storing it unless it shrank below
    /// `storedNotices` (the stored index's count, if any).
    private func download(now: Date, storedNotices: UInt64?) async -> RetractionIndexRefresh {
        var components = URLComponents(string: BioMedLitConstants.retractionWatchExportURL)
        components?.queryItems = [URLQueryItem(name: "mailto", value: email)]
        guard let url = components?.url else { return .failed(.requestFailed) }
        var request = URLRequest(url: url)
        request.setValue(
            "\(BioMedLitConstants.retractionUserAgentProduct) (mailto:\(email))",
            forHTTPHeaderField: "User-Agent"
        )

        let body: Data
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .failed(.requestFailed) }
            guard http.statusCode == BioMedLitConstants.httpStatusOK else {
                return .failed(.httpStatus(http.statusCode))
            }
            // A content-encoded body arrives decoded, so only a plain one can be measured.
            if http.value(forHTTPHeaderField: "Content-Encoding") == nil,
               let declared = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
               declared != data.count {
                BioMedLitLib.logger?.warning(
                    "Retraction Watch export cut short: \(data.count) of \(declared) bytes", category: .network
                )
                return .failed(.incompleteResponse)
            }
            body = data
        } catch {
            return .failed(SearchTransport.failure(for: error))
        }

        let build: RetractionIndexBuild
        do {
            build = try self.build(body, Self.dayFormatter.string(from: now))
        } catch {
            BioMedLitLib.logger?.warning("Retraction Watch export refused: \(error)", category: .network)
            return .refused("the export could not be built")
        }
        if build.skippedRows > 0 {
            BioMedLitLib.logger?.info("Retraction Watch export: \(build.skippedRows) rows skipped", category: .network)
        }
        if !build.unknownNatures.isEmpty {
            // Their notices decide nothing: Retraction Watch's vocabulary moved.
            BioMedLitLib.logger?.warning(
                "Retraction Watch natures not recognised: \(build.unknownNatures.joined(separator: ", "))",
                category: .network
            )
        }
        let count = build.index.noticeCount()
        if let old = storedNotices,
           Double(count) < Double(old) * BioMedLitConstants.retractionWatchMinKeepRatio {
            BioMedLitLib.logger?.warning("Retraction Watch export shrank from \(old) to \(count) notices", category: .network)
            return .refused("the export shrank from \(old) to \(count) notices")
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // downloaded again on a new device, never backed up
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
            // `.atomic` writes beside the file and renames over it.
            try build.index.toBytes().write(to: file, options: .atomic)
        } catch {
            BioMedLitLib.logger?.warning("Retraction Watch index not stored: \(error)", category: .network)
            return .notStored
        }
        return .refreshed(noticeCount: count)
    }

    /// UTC days as `yyyy-MM-dd`, the form bmlib's `dataAsOf` takes.
    private static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
