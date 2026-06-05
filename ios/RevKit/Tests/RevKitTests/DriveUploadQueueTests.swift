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
