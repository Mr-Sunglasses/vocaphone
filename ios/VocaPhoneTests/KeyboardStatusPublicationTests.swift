import Foundation
import Testing

struct KeyboardStatusPublicationTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func firstProofIsPublished() {
        #expect(KeyboardStatusPublication.shouldPublish(
            lastPublishedAt: nil,
            lastPublishedFullAccess: nil,
            fullAccess: false,
            now: now,
            minimumInterval: 10
        ))
    }

    @Test func identicalProofIsThrottled() {
        #expect(!KeyboardStatusPublication.shouldPublish(
            lastPublishedAt: now,
            lastPublishedFullAccess: true,
            fullAccess: true,
            now: now.addingTimeInterval(1),
            minimumInterval: 10
        ))
    }

    @Test func changedFullAccessBypassesTheThrottle() {
        #expect(KeyboardStatusPublication.shouldPublish(
            lastPublishedAt: now,
            lastPublishedFullAccess: false,
            fullAccess: true,
            now: now.addingTimeInterval(1),
            minimumInterval: 10
        ))
    }
}
