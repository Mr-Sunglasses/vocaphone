import Foundation
import Testing

struct RecordingLengthLimitTests {
    @Test func theDefaultIsFiveMinutesAndTheChoicesAreOneTwoFiveAndTen() {
        #expect(MaximumRecordingLength.default == .fiveMinutes)
        #expect(MaximumRecordingLength.allCases.map(\.seconds) == [60, 120, 300, 600])
        #expect(MaximumRecordingLength.allCases.map(\.displayName)
            == ["1 minute", "2 minutes", "5 minutes", "10 minutes"])
        #expect(MaximumRecordingLength.longest.seconds
            == MaximumRecordingLength.allCases.map(\.seconds).max())
    }

    /// On this iPhone nothing else has a say.
    @Test func onDeviceTheSettingIsTheCap() {
        for choice in MaximumRecordingLength.allCases {
            for reported in [nil, 60, 300, 1_200] as [Int?] {
                #expect(RecordingLengthLimit.effectiveSeconds(
                    choice: choice,
                    location: .onDevice,
                    gatewayReportedSeconds: reported
                ) == choice.seconds)
            }
        }
    }

    @Test func onTheGatewayTheSmallerLimitWins() {
        #expect(RecordingLengthLimit.effectiveSeconds(
            choice: .tenMinutes, location: .gateway, gatewayReportedSeconds: 300
        ) == 300)
        #expect(RecordingLengthLimit.effectiveSeconds(
            choice: .oneMinute, location: .gateway, gatewayReportedSeconds: 300
        ) == 60)
        #expect(RecordingLengthLimit.effectiveSeconds(
            choice: .fiveMinutes, location: .gateway, gatewayReportedSeconds: 300
        ) == 300)
        #expect(RecordingLengthLimit.effectiveSeconds(
            choice: .tenMinutes, location: .gateway, gatewayReportedSeconds: 3_600
        ) == 600)
    }

    /// An older gateway accepts two minutes and does not say so. Assuming it
    /// means no recording it receives is refused for its length.
    @Test func aGatewayThatReportsNoLimitIsTreatedAsTwoMinutes() {
        for reported in [nil, 0, -5] as [Int?] {
            #expect(RecordingLengthLimit.effectiveSeconds(
                choice: .fiveMinutes, location: .gateway, gatewayReportedSeconds: reported
            ) == 120)
            #expect(RecordingLengthLimit.effectiveSeconds(
                choice: .oneMinute, location: .gateway, gatewayReportedSeconds: reported
            ) == 60)
        }
    }

    /// A route or gateway switched after recording began can meet a recording
    /// longer than the gateway takes. It is caught before the upload, and a
    /// recording the cap itself stopped is never caught by mistake.
    @Test func aRecordingLongerThanTheGatewayAcceptsIsCaughtBeforeUpload() {
        #expect(RecordingLengthLimit.exceedsGateway(recordedSeconds: 300, gatewayReportedSeconds: 120))
        #expect(RecordingLengthLimit.exceedsGateway(recordedSeconds: 300, gatewayReportedSeconds: nil))
        #expect(!RecordingLengthLimit.exceedsGateway(recordedSeconds: 120.4, gatewayReportedSeconds: 120))
        #expect(!RecordingLengthLimit.exceedsGateway(recordedSeconds: 300, gatewayReportedSeconds: 300))
        #expect(!RecordingLengthLimit.exceedsGateway(recordedSeconds: nil, gatewayReportedSeconds: 60))
        #expect(DictationFailure(code: DictationFailure.tooLongForGatewayCode) == .tooLongForGateway)
        #expect(DictationFailure.tooLongForGateway.keyboardLine.count < 60)
        #expect(RecordingLengthLimit.tooLongForGatewayMessage(gatewayReportedSeconds: nil)
            .contains("up to 2 minutes"))
    }

    @Test func settingsNotesOnlyAGatewayThatStopsSooner() {
        #expect(RecordingLengthLimit.gatewayNote(choice: .fiveMinutes, gatewayReportedSeconds: nil)
            == "Your gateway accepts up to 2 minutes. Update the gateway to record longer.")
        #expect(RecordingLengthLimit.gatewayNote(choice: .tenMinutes, gatewayReportedSeconds: 90)
            == "Your gateway accepts up to 90 seconds. Update the gateway to record longer.")
        #expect(RecordingLengthLimit.gatewayNote(choice: .twoMinutes, gatewayReportedSeconds: nil) == nil)
        #expect(RecordingLengthLimit.gatewayNote(choice: .fiveMinutes, gatewayReportedSeconds: 300) == nil)
        #expect(RecordingLengthLimit.gatewayNote(choice: .oneMinute, gatewayReportedSeconds: 60) == nil)
    }

    @Test func healthReadsTheGatewayLimitWhenItIsThere() throws {
        let json = Data("""
        {"status":"ok","engine_ready":true,"engine":"whisper","languages":["en"],
         "maximum_duration_seconds":300}
        """.utf8)
        let health = try JSONDecoder().decode(GatewayHealth.self, from: json)
        #expect(health.maximumDurationSeconds == 300)
        #expect(health.engineReady)
    }

    @Test func healthFromAnOlderGatewayStillDecodes() throws {
        let json = Data("""
        {"status":"ok","engine_ready":true,"engine":"whisper"}
        """.utf8)
        let health = try JSONDecoder().decode(GatewayHealth.self, from: json)
        #expect(health.maximumDurationSeconds == nil)
        #expect(health.languages == nil)
    }

    /// A limit belongs to the gateway that reported it. A different address
    /// has not reported anything yet.
    @Test func aStoredLimitIsOnlyTrustedForTheGatewayThatReportedIt() throws {
        let url = try #require(URL(string: "https://gateway.example.test"))
        let other = try #require(URL(string: "https://other.example.test"))
        #expect(GatewayStatusPreferences.reportedMaximumDuration(
            storedSeconds: 300, storedBaseURL: url.absoluteString, currentBaseURL: url
        ) == 300)
        #expect(GatewayStatusPreferences.reportedMaximumDuration(
            storedSeconds: 300, storedBaseURL: url.absoluteString, currentBaseURL: other
        ) == nil)
        #expect(GatewayStatusPreferences.reportedMaximumDuration(
            storedSeconds: nil, storedBaseURL: url.absoluteString, currentBaseURL: url
        ) == nil)
        #expect(GatewayStatusPreferences.reportedMaximumDuration(
            storedSeconds: 0, storedBaseURL: url.absoluteString, currentBaseURL: url
        ) == nil)
        #expect(GatewayStatusPreferences.reportedMaximumDuration(
            storedSeconds: 300, storedBaseURL: url.absoluteString, currentBaseURL: nil
        ) == nil)
    }

    /// The keyboard expires a live recording without knowing which length was
    /// chosen, so its window has to clear the longest.
    @Test func theKeyboardNeverExpiresARecordingInsideTheLongestChoice() {
        #expect(SessionExpiryPolicy.captureWindow > MaximumRecordingLength.longest.seconds)
    }
}
