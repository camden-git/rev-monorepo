import Foundation
import Testing
@testable import RevKit

@MainActor
struct DriveUploadQueueTests {
    @Test func drainUploadsAllAndMarksThem() async {
        let a = SyncFixtures.payload()
        let b = SyncFixtures.payload()
        let source = FakeUnsentDriveSource([a, b])
        let client = MockPocketBaseClient()

        let queue = DriveUploadQueue(client: client, source: source)
        let result = await queue.drain()

        #expect(result.uploaded == 2)
        #expect(result.failed == false)
        #expect(Set(source.marked) == Set([a.id, b.id]))
        #expect(client.createdPayloads.count == 2)
        // nothing left to send on a second drain
        #expect(source.unsent().isEmpty)
    }

    @Test func failureLeavesDriveUnflaggedForRetry() async {
        let a = SyncFixtures.payload()
        let source = FakeUnsentDriveSource([a])
        let client = MockPocketBaseClient()
        client.onCreateDrive = { _ in throw PocketBaseError.http(status: 500, body: "boom") }

        let queue = DriveUploadQueue(client: client, source: source)
        let result = await queue.drain()

        #expect(result.uploaded == 0)
        #expect(result.failed == true)
        #expect(source.marked.isEmpty)
        // still pending and will be retried later
        #expect(source.unsent().count == 1)
    }

    @Test func permanentlyRejectedDriveIsDroppedSoTheQueueKeepsDraining() async {
        let poison = SyncFixtures.payload()
        let good = SyncFixtures.payload()
        let source = FakeUnsentDriveSource([poison, good])
        let client = MockPocketBaseClient()
        // the first (oldest) drive is permanently rejected, the next is fine
        let counter = Counter()
        client.onCreateDrive = { _ in
            if counter.next() == 0 {
                throw PocketBaseError.http(status: 400, body: #"{"message":"invalid raw_path"}"#)
            }
            return DriveRecordDTO(id: "ok", created: nil)
        }

        let result = await DriveUploadQueue(client: client, source: source).drain()

        #expect(result.uploaded == 1)
        #expect(result.dropped == 1)
        #expect(result.failed == false)
        // both are flagged so neither is retried, and the good drive got through
        #expect(Set(source.marked) == Set([poison.id, good.id]))
        #expect(source.unsent().isEmpty)
    }

    @Test func authFailureStopsDrainWithoutDropping() async {
        let a = SyncFixtures.payload()
        let b = SyncFixtures.payload()
        let source = FakeUnsentDriveSource([a, b])
        let client = MockPocketBaseClient()
        client.onCreateDrive = { _ in throw PocketBaseError.http(status: 401, body: "expired") }

        let result = await DriveUploadQueue(client: client, source: source).drain()

        // 401 is recoverable via re-auth, so nothing is dropped and the drain stops
        #expect(result.uploaded == 0)
        #expect(result.dropped == 0)
        #expect(result.failed == true)
        #expect(source.marked.isEmpty)
    }

    @Test func rateLimitStopsDrainWithoutDropping() async {
        let a = SyncFixtures.payload()
        let source = FakeUnsentDriveSource([a])
        let client = MockPocketBaseClient()
        client.onCreateDrive = { _ in throw PocketBaseError.http(status: 429, body: "slow down") }

        let result = await DriveUploadQueue(client: client, source: source).drain()

        #expect(result.failed == true)
        #expect(result.dropped == 0)
        #expect(source.marked.isEmpty)
    }

    @Test func drainStopsAtFirstFailure() async {
        let source = FakeUnsentDriveSource([SyncFixtures.payload(), SyncFixtures.payload()])
        let client = MockPocketBaseClient()
        // succeed once, then fail
        let counter = Counter()
        client.onCreateDrive = { _ in
            if counter.next() == 0 { return DriveRecordDTO(id: "ok", created: nil) }
            throw PocketBaseError.http(status: 500, body: "boom")
        }

        let result = await DriveUploadQueue(client: client, source: source).drain()

        #expect(result.uploaded == 1)
        #expect(result.failed == true)
        #expect(source.marked.count == 1)
    }
}

/// tiny thread-safe counter for ordering assertions
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = value; value += 1; return v
    }
}
