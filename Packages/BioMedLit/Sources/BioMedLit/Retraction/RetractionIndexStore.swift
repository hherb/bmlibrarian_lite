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
    /// The download arrived but was not stored; the previous file is kept.
    /// The text is for the log: it is this library's, never the provider's.
    case refused(String)
    /// The download failed; the previous file is kept.
    case failed(RequestFailure)
}

/// The Retraction Watch export, kept as bmlib's index file (the desktop's
/// `retraction_export.py`). An index is consulted only while current; a
/// refresh replaces the file atomically, and any refusal keeps the old one.
public actor RetractionIndexStore {
    private let directory: URL
    private let session: URLSession
    private let email: String
    /// The download under way, which every caller meanwhile awaits.
    private var inFlight: Task<RetractionIndexRefresh, Never>?

    /// - Parameters:
    ///   - directory: Where the index file lives.
    ///   - session: The session the export is downloaded over; production
    ///     uses ``wifiOnlyConfiguration()``.
    ///   - email: Contact address, sent as `mailto=` and in the User-Agent,
    ///     as the desktop's download does.
    public init(directory: URL, session: URLSession, email: String) {
        self.directory = directory
        self.session = session
        self.email = email
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

    private var file: URL { directory.appendingPathComponent(BioMedLitConstants.retractionIndexFileName) }

    /// The stored index, whatever its age; `nil` when missing or unreadable.
    private func storedIndex() -> RetractionIndex? {
        guard let bytes = try? Data(contentsOf: file) else { return nil }
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
    public func currentIndex(now: Date) -> RetractionIndex? {
        guard let index = storedIndex(),
              let asOf = Self.dayFormatter.date(from: index.dataAsOf()),
              let today = Self.dayFormatter.date(from: Self.dayFormatter.string(from: now)),
              let age = Self.utcCalendar.dateComponents([.day], from: asOf, to: today).day,
              age <= BioMedLitConstants.retractionWatchMaxAgeDays
        else { return nil }
        return index
    }

    /// Download and store a new index unless the stored one is current.
    ///
    /// bmlib builds the index, dated `now`'s day; one under
    /// ``BioMedLitConstants/retractionWatchMinKeepRatio`` of the stored
    /// index's notices is refused as truncated.
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
        if currentIndex(now: now) != nil { return .fresh }
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
            build = try buildRetractionIndex(csv: body, dataAsOf: Self.dayFormatter.string(from: now))
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
        if let old = storedIndex()?.noticeCount(),
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
            return .refused("the index could not be stored")
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
