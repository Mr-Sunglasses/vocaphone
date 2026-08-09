import SwiftUI

/// The gateway is the one part of setup the app cannot do for the user, and it
/// is reached from both guided setup and Settings. Keeping the address, token,
/// scanner and health test on one screen stops those two entry points drifting
/// apart.
struct GatewaySetupView: View {
    @Environment(RecordingCoordinator.self) private var coordinator
    @AppStorage("gatewayURL") private var gatewayURL = ""
    @AppStorage(GatewayStatusPreferences.healthMessageKey)
    private var healthMessage = "Not tested"
    @AppStorage(GatewayStatusPreferences.engineKey) private var gatewayEngine = ""
    @AppStorage(GatewayStatusPreferences.engineReadyKey)
    private var gatewayEngineReady = false
    @State private var token = ""
    @State private var isTestingGateway = false
    @State private var isShowingPairingScanner = false

    var body: some View {
        List {
            pairingSection
            addressSection
            statusSection
        }
        .navigationTitle("Gateway")
        .navigationBarTitleDisplayMode(.inline)
        .task { token = (try? KeychainStore.loadToken()) ?? "" }
        .sheet(isPresented: $isShowingPairingScanner) {
            PairingScannerView(
                paired: applyPairing,
                unavailable: handleScannerUnavailable
            )
            .ignoresSafeArea()
        }
        .onChange(of: gatewayURL) {
            healthMessage = "Not tested"
            gatewayEngine = ""
            gatewayEngineReady = false
        }
    }

    private var pairingSection: some View {
        Section {
            Button {
                isShowingPairingScanner = true
            } label: {
                Label("Scan pairing QR code", systemImage: "qrcode.viewfinder")
            }
        } header: {
            Text("Pair")
        } footer: {
            Text(
                "vocaphone transcribes on a gateway you run yourself — on your "
                    + "LAN, over Tailscale, or on your own VPS. Open Overview in "
                    + "its WebUI and scan the Pair phone app QR code to fill in "
                    + "the address and token automatically."
            )
        }
    }

    private var addressSection: some View {
        Section {
            TextField(
                "http://homelabone:8765 or https://dictation.example.com",
                text: $gatewayURL
            )
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)

            SecureField("Pairing token", text: $token)
                .textInputAutocapitalization(.never)

            Button {
                Task { await saveAndTestGateway() }
            } label: {
                HStack(spacing: 8) {
                    if isTestingGateway {
                        ProgressView().controlSize(.small)
                    }
                    Text(isTestingGateway ? "Testing gateway…" : "Save and test")
                }
            }
            .disabled(isTestingGateway)
        } header: {
            Text("Or enter it by hand")
        } footer: {
            if let url = validatedGatewayURL, GatewayEndpoint.usesUnencryptedHTTP(url) {
                Label(
                    "HTTP is unencrypted. Use it only on a trusted private LAN or VPN; "
                        + "use HTTPS for a VPS or any public network.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else {
                Text(
                    "Use any reachable HTTP or HTTPS gateway. HTTPS is recommended and "
                        + "required for safe access over the public internet."
                )
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            // The message beside the dot already says what happened in words, so
            // the dot is decoration here and the row reads without it.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(gatewayEngineReady ? Color.brand : .secondary)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(healthMessage)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !gatewayEngine.isEmpty {
                LabeledContent("Model") {
                    Text(gatewayEngine)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var validatedGatewayURL: URL? {
        GatewayEndpoint.validatedURL(from: gatewayURL)
    }

    @MainActor
    private func applyPairing(_ pairing: PairingPayload.Value) {
        isShowingPairingScanner = false
        gatewayURL = pairing.url.absoluteString
        token = pairing.token
        Task { await saveAndTestGateway() }
    }

    @MainActor
    private func handleScannerUnavailable(_ message: String) {
        isShowingPairingScanner = false
        healthMessage = message
        gatewayEngine = ""
        gatewayEngineReady = false
    }

    @MainActor
    private func saveAndTestGateway() async {
        guard let url = validatedGatewayURL else {
            healthMessage = "Enter a valid HTTP or HTTPS gateway URL."
            gatewayEngine = ""
            gatewayEngineReady = false
            return
        }
        do {
            try KeychainStore.saveToken(token)
        } catch {
            healthMessage = "Could not save the pairing token: \(error.localizedDescription)"
            return
        }
        await testGateway(at: url)
    }

    @MainActor
    private func testGateway(at url: URL) async {
        guard !isTestingGateway else { return }
        isTestingGateway = true
        defer { isTestingGateway = false }
        // Guided setup shows the gateway step from this state, so every exit
        // path below has to leave it refreshed.
        defer { coordinator.refreshSetupStatus() }
        do {
            let client = GatewayClient(baseURL: url, token: token)
            try await client.verifyAuthentication()
            let health = try await client.health()
            healthMessage = health.engineReady
                ? "Gateway, token, and model are ready."
                : "Gateway reachable; model is not ready."
            gatewayEngine = health.engine.trimmingCharacters(in: .whitespacesAndNewlines)
            gatewayEngineReady = health.engineReady
            GatewayStatusPreferences.storeLanguageSupport(health)
            coordinator.updateGateway(baseURL: url, token: token)
        } catch let GatewayError.api(status, _) where status == 401 {
            healthMessage = "Gateway reachable, but the pairing token was rejected."
            gatewayEngine = ""
            gatewayEngineReady = false
        } catch {
            healthMessage = "Gateway test failed: \(error.localizedDescription)"
            gatewayEngine = ""
            gatewayEngineReady = false
        }
    }
}
