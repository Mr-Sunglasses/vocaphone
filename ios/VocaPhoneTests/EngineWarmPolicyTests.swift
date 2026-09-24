import Testing

struct EngineWarmPolicyTests {
    private let megabyte: Int64 = 1024 * 1024

    @Test func warmsWithRoomForTheModelAndHeadroom() {
        #expect(EngineWarmPolicy.hasRoom(
            availableBytes: UInt64(2048 * megabyte),
            modelBytes: 670 * megabyte
        ))
    }

    @Test func declinesWhenTheModelWouldEatTheHeadroom() {
        // 1 GB free, 670 MB model: loads, but leaves the keyboard next to
        // nothing. A dictation would still load it; a guess must not.
        #expect(!EngineWarmPolicy.hasRoom(
            availableBytes: UInt64(1024 * megabyte),
            modelBytes: 670 * megabyte
        ))
    }

    @Test func countsTheEngineItWouldReplace() {
        // The resident model is released before the next one is built.
        #expect(EngineWarmPolicy.hasRoom(
            availableBytes: UInt64(700 * megabyte),
            modelBytes: 670 * megabyte,
            residentBytes: 600 * megabyte
        ))
    }

    @Test func unknownMemoryIsNotAReasonToRefuse() {
        // `os_proc_available_memory` reports zero where it has no answer, the
        // simulator among them.
        #expect(EngineWarmPolicy.hasRoom(availableBytes: 0, modelBytes: 1600 * megabyte))
    }

    @Test func warmsOnlyOnThePagesThatLeadToTryDictating() {
        let warmed = OnboardingStage.allCases.filter(OnboardingPresentation.warmsSelectedModel(on:))
        #expect(warmed == [.microphone, .keyboard, .keyboardSwitch, .practice])
    }
}
