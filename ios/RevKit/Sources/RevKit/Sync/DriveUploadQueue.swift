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
        lhs.user == rhs.user
            && lhs.startedAt == rhs.startedAt
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
    public func drain() async -> (uploaded: Int, failed: Bool) {
        var uploaded = 0
        for pending in source.unsent() {
            do {
                _ = try await client.createDrive(pending.payload)
                source.markUploaded(pending.id)
                uploaded += 1
            } catch {
                return (uploaded, true)
            }
        }
        return (uploaded, false)
    }
}

/// SwiftData-backed source: reads unsent `DriveRecord`s and maps them to upload
/// payloads, then flips `uploaded` once the server accepts them.
///
/// FUTURE (server-side): `userID` is the authenticated PocketBase user id. Until
/// Sign in with Apple is wired, uploads are gated on having one (the local
/// player's id is not a server id).
@MainActor
public final class SwiftDataDriveSource: UnsentDriveSource {
    private let context: ModelContext
    private let userID: String

    public init(context: ModelContext, userID: String) {
        self.context = context
        self.userID = userID
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
                    user: userID,
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
