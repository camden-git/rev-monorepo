import Foundation
import SwiftData

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

    public init(client: PocketBaseClient, source: UnsentDriveSource) {
        self.client = client
        self.source = source
    }

    /// upload every pending drive
    @discardableResult
    public func drain() async -> (uploaded: Int, failed: Bool, error: Error?) {
        var uploaded = 0
        for pending in source.unsent() {
            do {
                _ = try await client.createDrive(pending.payload)
                source.markUploaded(pending.id)
                uploaded += 1
            } catch {
                return (uploaded, true, error)
            }
        }
        return (uploaded, false, nil)
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
                    rawPath: record.rawPath,
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
