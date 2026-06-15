import Foundation
import SwiftData
#if canImport(os)
import os
#endif

/// one drive awaiting upload
public struct PendingDrive: Sendable, Equatable {
    public let id: UUID
    public let payload: DriveUploadPayload

    public init(id: UUID, payload: DriveUploadPayload) {
        self.id = id
        self.payload = payload
    }
}

extension DriveUploadPayload: Equatable {
    public static func == (lhs: DriveUploadPayload, rhs: DriveUploadPayload) -> Bool {
        lhs.startedAt == rhs.startedAt
            && lhs.endedAt == rhs.endedAt
            && lhs.rawPath == rhs.rawPath
            && lhs.perTileScores == rhs.perTileScores
    }
}

/// source of drives that still need uploading
@MainActor
public protocol UnsentDriveSource: AnyObject {
    func unsent() -> [PendingDrive]
    func markUploaded(_ id: UUID)
}

/// sends drives where `DriveRecord.uploaded == false` to the server, flipping
/// the flag on success (REF: docs/tech-stack.md §Sync Model)
@MainActor
public final class DriveUploadQueue {
    private let client: PocketBaseClient
    private let source: UnsentDriveSource
    #if canImport(os)
    private let logger = Logger(subsystem: "app.driverev.RevKit", category: "DriveUploadQueue")
    #endif

    public init(client: PocketBaseClient, source: UnsentDriveSource) {
        self.client = client
        self.source = source
    }

    /// upload every pending drive.
    ///
    /// drives upload oldest-first, so a single drive the server will never accept
    /// (a malformed or otherwise permanently-rejected payload) would otherwise sit
    /// at the head of the queue and block every later drive on every drain. such a
    /// drive is dropped (flagged uploaded so it isn't retried) and the drain
    /// continues. the local tile state was already applied optimistically, so
    /// nothing the player can see is lost. a transient failure (offline, 5xx, rate
    /// limit) or an auth failure still stops the drain so the caller can retry or
    /// prompt re-auth.
    @discardableResult
    public func drain() async -> (uploaded: Int, dropped: Int, failed: Bool, error: Error?) {
        var uploaded = 0
        var dropped = 0
        for pending in source.unsent() {
            do {
                _ = try await client.createDrive(pending.payload)
                source.markUploaded(pending.id)
                uploaded += 1
            } catch {
                if isPermanentRejection(error) {
                    source.markUploaded(pending.id)
                    dropped += 1
                    logDrop(pending.id, error: error)
                    continue
                }
                return (uploaded, dropped, true, error)
            }
        }
        return (uploaded, dropped, false, nil)
    }

    /// a 4xx the server will return again for the same payload, so retrying is
    /// pointless. 401/403 (auth) and 408/429 (timeout / rate limit) are excluded:
    /// those are recoverable and must stop the drain rather than drop the drive.
    private func isPermanentRejection(_ error: Error) -> Bool {
        guard case let PocketBaseError.http(status, _) = error else { return false }
        switch status {
        case 401, 403, 408, 429:
            return false
        case 400..<500:
            return true
        default:
            return false
        }
    }

    private func logDrop(_ id: UUID, error: Error) {
        #if canImport(os)
        logger.error("dropping permanently-rejected drive \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        #else
        print("DriveUploadQueue dropping permanently-rejected drive \(id): \(error)")
        #endif
    }
}

/// bounds the GPS path size of an uploaded drive
enum DrivePathLimit {
    /// the server caps drives.raw_path at 5 MB. cap the uploaded fix count so a
    /// very long drive still uploads (and still resolves enclosures) instead of
    /// being rejected outright. a few thousand fixes is plenty to reconstruct the
    /// path, and stays well under the byte cap.
    static let maxUploadSamples = 15_000

    /// uniformly downsample a path to at most `maxSamples` fixes, preserving the
    /// first and last fix so the drive's extent and overall shape survive
    static func downsample(_ path: [GPSSample], maxSamples: Int = maxUploadSamples) -> [GPSSample] {
        guard maxSamples >= 2, path.count > maxSamples else { return path }
        var result: [GPSSample] = []
        result.reserveCapacity(maxSamples)
        let last = path.count - 1
        for i in 0..<maxSamples {
            let index = Int((Double(i) * Double(last) / Double(maxSamples - 1)).rounded())
            result.append(path[index])
        }
        return result
    }
}

/// SwiftData-backed source: reads unsent `DriveRecord`s and maps them to upload
/// payloads, then flips `uploaded` once the server accepts them. the backend
/// assigns the drive owner from the auth token
@MainActor
public final class SwiftDataDriveSource: UnsentDriveSource {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func unsent() -> [PendingDrive] {
        let descriptor = FetchDescriptor<DriveRecord>(
            predicate: #Predicate { $0.uploaded == false },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        let records = (try? context.fetch(descriptor)) ?? []
        return records.map { record in
            PendingDrive(
                id: record.id,
                payload: DriveUploadPayload(
                    startedAt: record.startedAt,
                    endedAt: record.endedAt,
                    rawPath: DrivePathLimit.downsample(record.rawPath),
                    perTileScores: record.perTileScores
                )
            )
        }
    }

    public func markUploaded(_ id: UUID) {
        let descriptor = FetchDescriptor<DriveRecord>(predicate: #Predicate { $0.id == id })
        guard let record = try? context.fetch(descriptor).first else { return }
        record.uploaded = true
        try? context.save()
    }
}
