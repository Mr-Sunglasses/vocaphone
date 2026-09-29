import Testing

/// When an off-screen keyboard ends its process instead of being reused.
struct KeyboardMemoryBudgetTests {
    /// The limit is whatever the device allows: the footprint plus what is
    /// left. Measured on an iPhone 14 Pro, that was 77 MB.
    @Test func recyclesPastItsShareOfTheLimit() {
        #expect(!KeyboardMemoryBudget.shouldRecycle(footprint: 30, available: 47))
        #expect(!KeyboardMemoryBudget.shouldRecycle(footprint: 45, available: 32))
        #expect(KeyboardMemoryBudget.shouldRecycle(footprint: 47, available: 30))
        #expect(KeyboardMemoryBudget.shouldRecycle(footprint: 62, available: 15))
    }

    /// A smaller phone's smaller limit moves the line with it.
    @Test func followsTheDevicesLimit() {
        #expect(KeyboardMemoryBudget.shouldRecycle(footprint: 30, available: 18))
        #expect(!KeyboardMemoryBudget.shouldRecycle(footprint: 30, available: 40))
    }

    @Test func anUnreadableLimitNeverRecycles() {
        #expect(!KeyboardMemoryBudget.shouldRecycle(footprint: 0, available: 0))
    }

    @Test func theFootprintIsReadable() {
        #expect((KeyboardMemoryBudget.footprintMegabytes ?? 0) > 0)
    }

    private static func recycling(footprint: Int?, available: Int?) -> KeyboardRecycling {
        KeyboardRecycling(footprint: { footprint }, available: { available })
    }

    /// The dismissal path: bloated and off screen ends the process, reporting
    /// the headroom it had for the diagnostic line.
    @Test func aBloatedKeyboardLeavingTheScreenRecycles() {
        let bloated = Self.recycling(footprint: 62, available: 15)
        #expect(bloated.headroomIfRecycling(isVisible: false, isInserting: false) == 15)
    }

    @Test func neverOnScreenOrMidInsertion() {
        let bloated = Self.recycling(footprint: 62, available: 15)
        #expect(bloated.headroomIfRecycling(isVisible: true, isInserting: false) == nil)
        #expect(bloated.headroomIfRecycling(isVisible: false, isInserting: true) == nil)
    }

    @Test func aHealthyKeyboardIsKept() {
        let healthy = Self.recycling(footprint: 30, available: 47)
        #expect(healthy.headroomIfRecycling(isVisible: false, isInserting: false) == nil)
    }

    /// The simulator, or a failed `task_info`: no reading, no exit.
    @Test func aMissingReadingNeverRecycles() {
        #expect(Self.recycling(footprint: 62, available: nil)
            .headroomIfRecycling(isVisible: false, isInserting: false) == nil)
        #expect(Self.recycling(footprint: nil, available: 15)
            .headroomIfRecycling(isVisible: false, isInserting: false) == nil)
    }
}
