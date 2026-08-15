import Foundation

/// Where speech-to-text will run, and whether that place is actually ready.
///
/// The two routes are a *choice*, not two requirements. Guided setup used to
/// present the gateway as the one true path and the on-device model as an
/// afterthought below it, which meant a phone with a downloaded model still
/// reported "No transcription gateway yet" on the main screen. One selection
/// governs both, and only the selected route can block anything.
///
/// Pure and `Equatable` on purpose: the home card, the setup step and the
/// settings summary all render from this, so it can be tested without an audio
/// stack, a network, or a downloaded model.
struct TranscriptionSourceStatus: Equatable, Sendable {
    var selected: SessionProcessingLocation = .gateway

    /// The chosen on-device model, if one has been chosen.
    var onDeviceModelName: String?
    /// Every required file is downloaded and has passed its integrity check.
    /// Nothing may claim offline readiness before that.
    var isOnDeviceReady = false

    var gatewayAddress = ""
    /// The gateway answered, the token was accepted, and it reported a loaded
    /// speech-to-text model. Anything less is not ready.
    var isGatewayReady = false
    /// The gateway's own last words, in the app's voice. Empty before any test.
    var gatewayMessage = ""

    /// Whether dictation can happen at all. Only the selected route counts: an
    /// unconfigured gateway is not a fault on a phone set to transcribe locally.
    var isReady: Bool {
        switch selected {
        case .onDevice: isOnDeviceReady
        case .gateway: isGatewayReady
        }
    }

    /// The route's name in user-facing copy. Never "local" — that word covers
    /// both routes and distinguishes neither — and never "your Mac".
    var title: String {
        switch selected {
        case .onDevice: "On this iPhone"
        case .gateway: "Your gateway"
        }
    }

    var symbolName: String {
        switch selected {
        case .onDevice: "iphone"
        case .gateway: "server.rack"
        }
    }

    /// One line naming what is loaded and whether it is usable.
    var readinessDetail: String {
        switch selected {
        case .onDevice:
            guard let onDeviceModelName else {
                return "Choose a speech-to-text model to download."
            }
            return isOnDeviceReady
                ? "\(onDeviceModelName) is downloaded and verified."
                : "\(onDeviceModelName) is not ready to use yet."
        case .gateway:
            if isGatewayReady {
                return gatewayAddress.isEmpty
                    ? "Gateway, token, and speech-to-text model are ready."
                    : "Ready at \(gatewayAddress)."
            }
            if gatewayAddress.isEmpty { return "No gateway is configured yet." }
            return gatewayMessage.isEmpty
                ? "\(gatewayAddress) has not answered yet."
                : gatewayMessage
        }
    }

    /// Where the audio goes. Said on every surface that offers the choice,
    /// because it is the difference between the two routes that matters.
    var boundaryDetail: String {
        switch selected {
        case .onDevice:
            "Audio and the speech-to-text model stay on this iPhone. No network is used."
        case .gateway:
            "Audio is sent to the gateway you configured. It runs the speech-to-text "
                + "model and returns the text."
        }
    }

    /// What the *other* route offers, so the unselected one never reads as
    /// broken — it is simply not the one in use.
    var alternativeSummary: String {
        switch selected {
        case .onDevice:
            isGatewayReady
                ? "Your gateway is also configured and ready to switch back to."
                : "A self-hosted gateway is available when you want a different model."
        case .gateway:
            isOnDeviceReady
                ? "An on-device model is downloaded and ready to switch to."
                : "Download an on-device model to dictate with no network at all."
        }
    }

    /// The main screen's blocking headline for this route, or `nil` when it can
    /// do its job.
    var attentionHeadline: String? {
        guard !isReady else { return nil }
        switch selected {
        case .onDevice:
            return onDeviceModelName == nil
                ? "No speech-to-text model downloaded"
                : "The on-device model is not ready"
        case .gateway:
            return gatewayAddress.isEmpty
                ? "No transcription gateway yet"
                : "Your gateway is not responding"
        }
    }

    /// The verb on the button that fixes it.
    var recoveryActionTitle: String {
        switch selected {
        case .onDevice: "Manage on-device models"
        case .gateway: gatewayAddress.isEmpty ? "Set up a gateway" : "Test the gateway"
        }
    }
}
