import Foundation
import Testing
@testable import RevKit

struct TokenStoreTests {
    @Test func inMemoryRoundTrips() {
        let store = InMemoryTokenStore()
        #expect(store.load() == nil)

        store.save("abc.def.ghi")
        #expect(store.load() == "abc.def.ghi")

        store.save("replaced")
        #expect(store.load() == "replaced")

        store.clear()
        #expect(store.load() == nil)
    }

    @Test func seededTokenLoads() {
        let store = InMemoryTokenStore(token: "preset")
        #expect(store.load() == "preset")
    }
}
