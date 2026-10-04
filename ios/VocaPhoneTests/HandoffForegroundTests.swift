import Foundation
import Testing

/// The keyboard's answer to "is vocaphone the app I am typing in?". Saying yes
/// skips the swipe-back screen, so a yes nobody can vouch for must read as no.
struct HandoffForegroundTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aFreshHeartbeatVouchesForTheFlag() {
        #expect(KeyboardPreferences.isVerifiablyForeground(
            flag: true, heartbeat: now.addingTimeInterval(-2), now: now
        ))
    }

    @Test func aFlagLeftByADeadProcessIsIgnored() {
        #expect(!KeyboardPreferences.isVerifiablyForeground(
            flag: true, heartbeat: now.addingTimeInterval(-60), now: now
        ))
        #expect(!KeyboardPreferences.isVerifiablyForeground(flag: true, heartbeat: nil, now: now))
    }

    @Test func aClearedFlagStaysCleared() {
        #expect(!KeyboardPreferences.isVerifiablyForeground(flag: false, heartbeat: now, now: now))
    }
}
