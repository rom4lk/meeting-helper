import XCTest
@testable import MeetingHelper

@MainActor
final class SpeakerProfileStoreTests: XCTestCase {

    private func makeStore() -> (SpeakerProfileStore, URL) {
        let url = URL.temporaryProfileStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (SpeakerProfileStore(url: url), url)
    }

    func testARememberedVoiceIsReadBackByANewStore() {
        let (store, url) = makeStore()

        store.remember(email: "ivan@example.com", name: "Ivan Petrov", embedding: [0.1, 0.2])

        let reopened = SpeakerProfileStore(url: url)
        XCTAssertEqual(reopened.profiles.count, 1)
        XCTAssertEqual(reopened.profiles.first?.name, "Ivan Petrov")
        XCTAssertEqual(reopened.profiles.first?.embedding, [0.1, 0.2])
    }

    func testRememberingTheSameAddressReplacesTheVoiceRatherThanAddingOne() {
        let (store, _) = makeStore()

        store.remember(email: "ivan@example.com", name: "Ivan", embedding: [0.1])
        store.remember(email: "IVAN@example.com", name: "Ivan Petrov", embedding: [0.9])

        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.name, "Ivan Petrov")
        XCTAssertEqual(store.profiles.first?.embedding, [0.9])
    }

    func testAnEmptyEmbeddingIsNotStored() {
        let (store, _) = makeStore()

        store.remember(email: "ivan@example.com", name: "Ivan", embedding: [])

        XCTAssertTrue(store.profiles.isEmpty)
    }

    /// Only the people on the invitation are worth comparing a meeting's voices against. Widening
    /// it to every voice ever stored trades a missing name for a wrong one.
    func testOnlyInvitedPeopleAreOfferedForSeeding() {
        let (store, _) = makeStore()
        store.remember(email: "ivan@example.com", name: "Ivan", embedding: [0.1])
        store.remember(email: "stranger@example.com", name: "Stranger", embedding: [0.2])

        let seeded = store.profiles(for: [CalendarAttendee(email: "IVAN@example.com")])

        XCTAssertEqual(seeded.map(\.email), ["ivan@example.com"])
    }

    func testForgettingEverythingClearsTheFile() {
        let (store, url) = makeStore()
        store.remember(email: "ivan@example.com", name: "Ivan", embedding: [0.1])

        store.removeAll()

        XCTAssertTrue(SpeakerProfileStore(url: url).profiles.isEmpty)
    }

    func testAMissingFileIsAnEmptyStore() {
        let (store, _) = makeStore()

        XCTAssertTrue(store.profiles.isEmpty)
    }
}
