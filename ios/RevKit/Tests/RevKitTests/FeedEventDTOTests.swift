import Foundation
import Testing
@testable import RevKit

struct FeedEventDTOTests {
    private func decode(_ json: String) throws -> FeedEventDTO {
        try JSONDecoder().decode(FeedEventDTO.self, from: Data(json.utf8))
    }

    @Test func decodesDriveEvent() throws {
        let e = try decode(#"""
        {"id":"e1","type":"drive","user_id":"u1","display_name":"Ada","color":"#FF0000",
         "occurred_at":"2026-06-29 12:00:00.000Z","value":42,"prev_value":1800,"drive_id":"d1"}
        """#)
        #expect(e.type == .drive)
        #expect(e.value == 42)
        #expect(e.prevValue == 1800)
        #expect(e.driveID == "d1")
        #expect(e.displayName == "Ada")
    }

    @Test func decodesCaptureEventWithSubject() throws {
        let e = try decode(#"""
        {"id":"e2","type":"capture","user_id":"u1","display_name":"Ada","color":"#0F0",
         "occurred_at":"2026-06-29 12:00:00.000Z","value":3,"subject_id":"u2","subject_name":"Grace"}
        """#)
        #expect(e.type == .capture)
        #expect(e.value == 3)
        #expect(e.subjectID == "u2")
        #expect(e.subjectName == "Grace")
    }

    @Test func decodesPersonalRecordSubtype() throws {
        let e = try decode(#"""
        {"id":"e3","type":"pr","user_id":"u1","display_name":"Ada","color":"#00F",
         "occurred_at":"2026-06-29 12:00:00.000Z","subtype":"distance","value":5000}
        """#)
        #expect(e.type == .pr)
        #expect(e.subtype == "distance")
        #expect(DrivePRKind(rawValue: e.subtype) == .distance)
    }

    @Test func decodesRankUp() throws {
        let e = try decode(#"""
        {"id":"e4","type":"rank_up","user_id":"u1","display_name":"Ada","color":"#00F",
         "occurred_at":"2026-06-29 12:00:00.000Z","value":3,"prev_value":8}
        """#)
        #expect(e.type == .rankUp)
        #expect(e.value == 3)
        #expect(e.prevValue == 8)
    }

    /// an unfamiliar future type decodes to `.unknown` rather than throwing, so a
    /// new server event never breaks an older client's feed
    @Test func unknownTypeDecodesToUnknown() throws {
        let e = try decode(#"""
        {"id":"e5","type":"some_future_thing","user_id":"u1","display_name":"Ada","color":"#000",
         "occurred_at":"2026-06-29 12:00:00.000Z"}
        """#)
        #expect(e.type == .unknown)
    }

    @Test func missingOptionalFieldsDefault() throws {
        let e = try decode(#"{"id":"e6","type":"streak","value":7}"#)
        #expect(e.type == .streak)
        #expect(e.value == 7)
        #expect(e.subtype == "")
        #expect(e.driveID == "")
        #expect(e.subjectName == "")
    }
}
