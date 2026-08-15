import Testing

/// The route model decides what the product is allowed to *claim* about where
/// speech becomes text, which makes it the most load-bearing copy in the app.
struct TranscriptionSourceTests {
    private let readyGateway = TranscriptionSourceStatus(
        selected: .gateway,
        gatewayAddress: "http://homelabone:8765",
        isGatewayReady: true
    )

    private let readyOnDevice = TranscriptionSourceStatus(
        selected: .onDevice,
        onDeviceModelName: "Whisper Small",
        isOnDeviceReady: true
    )

    /// Only the selected route can block anything. A phone set to transcribe on
    /// device is not broken because no gateway was ever configured — which is
    /// exactly what the old single `gatewayReady` flag reported.
    @Test func onlyTheSelectedRouteDecidesReadiness() {
        #expect(readyOnDevice.isReady)
        #expect(readyOnDevice.attentionHeadline == nil)

        var onDeviceWithBrokenGateway = readyOnDevice
        onDeviceWithBrokenGateway.isGatewayReady = false
        #expect(onDeviceWithBrokenGateway.isReady)

        var gatewayWithNoModel = readyGateway
        gatewayWithNoModel.isOnDeviceReady = false
        #expect(gatewayWithNoModel.isReady)
    }

    @Test func anUnreadyRouteNamesWhatIsMissing() {
        var noModel = readyOnDevice
        noModel.onDeviceModelName = nil
        noModel.isOnDeviceReady = false
        #expect(noModel.attentionHeadline == "No speech-to-text model downloaded")

        var unverifiedModel = readyOnDevice
        unverifiedModel.isOnDeviceReady = false
        #expect(unverifiedModel.attentionHeadline == "The on-device model is not ready")

        var noGateway = readyGateway
        noGateway.isGatewayReady = false
        noGateway.gatewayAddress = ""
        #expect(noGateway.attentionHeadline == "No transcription gateway yet")

        var unreachable = readyGateway
        unreachable.isGatewayReady = false
        #expect(unreachable.attentionHeadline == "Your gateway is not responding")
    }

    /// The words that carry the privacy boundary. "Local", "private" and
    /// "on-device" are not interchangeable, and a gateway genuinely receives
    /// audio — saying otherwise would be the one lie this product cannot tell.
    @Test func eachRouteStatesWhereTheAudioActuallyGoes() {
        #expect(readyOnDevice.boundaryDetail.contains("stay on this iPhone"))
        #expect(readyOnDevice.boundaryDetail.contains("No network"))

        #expect(readyGateway.boundaryDetail.contains("sent to the gateway"))
        #expect(!readyGateway.boundaryDetail.localizedCaseInsensitiveContains("local"))
    }

    /// Never "your Mac": a gateway may be a Linux box, a home server, or a VPS.
    @Test func noCopyEverGuessesTheGatewaysHardware() {
        for source in [readyGateway, readyOnDevice] {
            for copy in [
                source.title, source.readinessDetail, source.boundaryDetail,
                source.alternativeSummary, source.recoveryActionTitle,
                source.attentionHeadline ?? "",
            ] {
                #expect(!copy.localizedCaseInsensitiveContains("your Mac"))
                #expect(!copy.localizedCaseInsensitiveContains("cloud"))
            }
        }
    }

    /// The unselected route is described as available, never as broken.
    @Test func theUnselectedRouteIsAnOfferNotAFault() {
        #expect(readyOnDevice.alternativeSummary.contains("gateway"))
        #expect(!readyOnDevice.alternativeSummary.localizedCaseInsensitiveContains("not ready"))

        var gatewayWithoutModel = readyGateway
        gatewayWithoutModel.isOnDeviceReady = false
        #expect(gatewayWithoutModel.alternativeSummary.contains("Download an on-device model"))
    }

    @Test func theRecoveryActionMatchesWhatIsActuallyWrong() {
        var noGateway = readyGateway
        noGateway.gatewayAddress = ""
        #expect(noGateway.recoveryActionTitle == "Set up a gateway")
        #expect(readyGateway.recoveryActionTitle == "Test the gateway")
        #expect(readyOnDevice.recoveryActionTitle == "Manage on-device models")
    }

    /// "Downloaded" is not "verified". Claiming offline readiness before every
    /// pinned file has passed its checksum is how a dictation fails at the one
    /// moment there is no network to fall back on.
    @Test func aModelIsNotOfferedAsOfflineReadyUntilItIsVerified() {
        var downloading = readyOnDevice
        downloading.isOnDeviceReady = false

        #expect(!downloading.isReady)
        #expect(!downloading.readinessDetail.localizedCaseInsensitiveContains("verified"))
        #expect(readyOnDevice.readinessDetail.contains("verified"))
    }
}
