import Foundation
import Testing

struct PairingPayloadTests {
    @Test func parsesVersionOneGatewayDocument() {
        let result = PairingPayload.parse(
            """
            {"v":1,"url":"  http://192.168.1.75:8765/  ","token":"  test-token-with-at-least-thirty-two-characters  "}
            """
        )

        #expect(
            result == .success(
                .init(
                    url: URL(string: "http://192.168.1.75:8765/")!,
                    token: "test-token-with-at-least-thirty-two-characters"
                )
            )
        )
    }

    @Test func acceptsLegacyVersionKey() {
        let result = PairingPayload.parse(
            """
            {"version":1,"url":"https://dictation.example.com","token":"test-token-with-at-least-thirty-two-characters"}
            """
        )

        guard case let .success(value) = result else {
            Issue.record("Expected a valid pairing document")
            return
        }
        #expect(value.url == URL(string: "https://dictation.example.com")!)
    }

    @Test func rejectsInvalidPairingDocuments() {
        let shortToken = "{\"v\":1,\"url\":\"http://192.168.1.20:8765\",\"token\":\"too-short\"}"
        let wrongVersion = "{\"v\":99,\"url\":\"http://192.168.1.20:8765\",\"token\":\"test-token-with-at-least-thirty-two-characters\"}"
        let publicHTTP = "{\"v\":1,\"url\":\"http://flow.example.com:8765\",\"token\":\"test-token-with-at-least-thirty-two-characters\"}"

        for value in ["", "not-json", shortToken, wrongVersion, publicHTTP] {
            guard case .failure = PairingPayload.parse(value) else {
                Issue.record("Expected invalid pairing document: \(value)")
                continue
            }
        }
    }
}
