import Foundation
import Network
import Observation

/// Whether the connection currently in use bills by the byte.
///
/// The model catalog has always justified its shape by what a 670 MB download
/// costs "on cellular", but nothing ever asked. This is the ask: one path
/// monitor for the app, read by the setup card before it offers a download.
///
/// `isExpensive` covers cellular and personal hotspots; `isConstrained` covers
/// Low Data Mode, which is the user saying the same thing explicitly. Either is
/// enough to be worth a sentence.
@MainActor
@Observable
final class NetworkConditions {
    static let shared = NetworkConditions()

    /// Starts false rather than true: a warning shown on Wi-Fi because the
    /// first path update has not landed yet is worse than one that appears a
    /// moment late, and the monitor reports within milliseconds of starting.
    private(set) var isMetered = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var isMonitoring = false

    private init() {}

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.isMetered = metered }
        }
        monitor.start(queue: DispatchQueue(label: "com.vocahq.vocaphone.network-conditions"))
    }
}
