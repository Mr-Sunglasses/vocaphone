@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A native camera preview which only accepts the authenticated vocaphone QR
/// document. Other QR codes are ignored so the user can keep scanning.
struct PairingScannerView: UIViewControllerRepresentable {
    let paired: (PairingPayload.Value) -> Void
    let unavailable: (String) -> Void

    func makeUIViewController(context: Context) -> PairingScannerViewController {
        PairingScannerViewController(paired: paired, unavailable: unavailable)
    }

    func updateUIViewController(_ uiViewController: PairingScannerViewController, context: Context) {}
}

@MainActor
final class PairingScannerViewController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.vocahq.vocaphone.pairing-camera")
    private let paired: (PairingPayload.Value) -> Void
    private let unavailable: (String) -> Void
    private var hasPaired = false
    private var isCameraConfigured = false

    init(
        paired: @escaping (PairingPayload.Value) -> Void,
        unavailable: @escaping (String) -> Void
    ) {
        self.paired = paired
        self.unavailable = unavailable
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard isCameraConfigured else { return }
        let captureSession = captureSession
        sessionQueue.async {
            guard !captureSession.isRunning else { return }
            captureSession.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let captureSession = captureSession
        sessionQueue.async {
            guard captureSession.isRunning else { return }
            captureSession.stopRunning()
        }
    }

    private func configureCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            installCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    granted ? self.installCamera() : self.reportUnavailable(
                        "Camera access is required to scan the pairing QR code."
                    )
                }
            }
        case .denied, .restricted:
            reportUnavailable("Camera access is required to scan the pairing QR code.")
        @unknown default:
            reportUnavailable("This device cannot grant camera access for QR pairing.")
        }
    }

    private func installCamera() {
        guard captureSession.inputs.isEmpty else { return }
        guard let camera = AVCaptureDevice.default(for: .video) else {
            reportUnavailable("No camera is available to scan the pairing QR code.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                reportUnavailable("The camera could not be configured for QR pairing.")
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                reportUnavailable("The camera could not be configured for QR pairing.")
                return
            }
            captureSession.addOutput(output)
            // The controller is main-actor isolated (like UIViewController),
            // so deliver metadata there before updating its state or SwiftUI.
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            isCameraConfigured = true

            let preview = AVCaptureVideoPreviewLayer(session: captureSession)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            let captureSession = captureSession
            sessionQueue.async {
                guard !captureSession.isRunning else { return }
                captureSession.startRunning()
            }
        } catch {
            reportUnavailable("The camera could not be opened for QR pairing.")
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasPaired,
              let readable = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                  .first(where: { $0.type == .qr }),
              let text = readable.stringValue,
              case let .success(value) = PairingPayload.parse(text)
        else { return }

        hasPaired = true
        captureSession.stopRunning()
        DispatchQueue.main.async { [weak self] in
            self?.paired(value)
        }
    }

    private func reportUnavailable(_ message: String) {
        unavailable(message)
    }
}
