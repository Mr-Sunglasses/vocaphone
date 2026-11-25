import AVFAudio
import Foundation
import UIKit
import WebKit

/// The microphone, from inside the keyboard extension.
///
/// iOS does not let a keyboard extension record (`audiomxd` refuses it: the
/// extension has no record-audio entitlement). WebKit's media capture runs in
/// its own process and is attributed to vocaphone's microphone permission, so
/// a hidden `WKWebView` calling `getUserMedia` can record while the keyboard
/// stays in the app the user is typing into. The orange microphone indicator
/// shows exactly as it does for any other recording. The technique is the one
/// Hex for iPhone uses (github.com/anomalyco/hex, MIT).
///
/// The page sends 16-bit mono PCM at the audio context's own rate; nothing in
/// the page leaves this process.
@MainActor
final class KeyboardMicrophoneCapture: NSObject, WKNavigationDelegate, WKUIDelegate {
    enum Event {
        case started(sampleRate: Double)
        /// Little-endian Int16 mono samples and the chunk's peak (0…1).
        case samples(Data, peak: Float)
        case stopped
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    private let webView: WKWebView
    private var isLoaded = false
    private var startWhenLoaded = false

    /// Whether this iPhone's microphone permission lets WebKit record for us.
    /// The extension cannot ask: an undecided permission is asked for by the
    /// app, which the keyboard then opens as it always has.
    static var isPermitted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    init(host: UIView) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakScriptHandler(self), name: "capture")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isUserInteractionEnabled = false
        webView.isAccessibilityElement = false
        webView.accessibilityElementsHidden = true
        // Off-screen views are not rendered, and a web view that is never
        // rendered may be throttled; nearly transparent keeps it live.
        webView.alpha = 0.01
        host.addSubview(webView)
        load()
    }

    /// A secure origin: getUserMedia is only exposed to one. The host is
    /// reserved (`.invalid`), so nothing can ever be fetched from it.
    private static let origin = URL(string: "https://keyboard.vocaphone.invalid/")!

    private func load() {
        isLoaded = false
        webView.loadHTMLString(Self.page, baseURL: Self.origin)
    }

    /// Moves the page into another instance of the keyboard's view; iOS
    /// recreates the controller while the process, and this page, live on.
    func attach(to host: UIView) {
        guard webView.superview !== host else { return }
        host.addSubview(webView)
    }

    func start() {
        guard isLoaded else {
            startWhenLoaded = true
            return
        }
        Self.configureSharedAudioSession()
        webView.evaluateJavaScript("captureStart()")
    }

    func stop() {
        startWhenLoaded = false
        webView.evaluateJavaScript("captureStop()")
    }

    /// Whether the page is loaded, so the next start skips the load.
    var isWarm: Bool { isLoaded }

    /// Gives the audio route back after a recording, so music that ducked or
    /// paused can resume. The page stays loaded for the next dictation.
    static func releaseAudioSession() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// Activation and release can each block for a noticeable time; one serial
    /// queue keeps them off the main thread and in the order they were asked.
    private static let audioSessionQueue = DispatchQueue(label: "com.vocahq.vocaphone.keyboard-audio-session")

    /// Tears the page down: the web content process and the view are memory
    /// the keyboard wants back once it leaves the screen.
    func dispose() {
        onEvent = nil
        startWhenLoaded = false
        isLoaded = false
        webView.evaluateJavaScript("captureStop()")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "capture")
        webView.stopLoading()
        webView.removeFromSuperview()
        Self.releaseAudioSession()
    }

    /// Music and navigation keep playing: the same mixable category the app
    /// records with, rather than WebKit's default, which pauses them.
    private static func configureSharedAudioSession() {
        audioSessionQueue.async {
            try? AVAudioSession.sharedInstance().setCategory(
                .playAndRecord,
                mode: .default,
                options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
            )
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        if startWhenLoaded {
            startWhenLoaded = false
            start()
        }
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        // Only ever the microphone, and only for the page loaded above.
        let ours = origin.protocol == "https" && origin.host == Self.origin.host && frame.isMainFrame
        decisionHandler(ours && type == .microphone ? .grant : .deny)
    }

    /// The page is the one string above; it never goes anywhere else.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let url = navigationAction.request.url
        let allowed = url?.host == Self.origin.host || url?.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Reloaded straight away, so a page iOS reclaimed while idle is ready
        // again by the next Dictate instead of timing it out.
        load()
        onEvent?(.failed("web_process_terminated"))
    }

    fileprivate func receive(_ body: Any) {
        guard let body = body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "started":
            onEvent?(.started(sampleRate: (body["rate"] as? Double) ?? 48_000))
        case "pcm":
            guard let encoded = body["data"] as? String,
                  let data = Data(base64Encoded: encoded)
            else { return }
            onEvent?(.samples(data, peak: Float((body["peak"] as? Double) ?? 0)))
        case "stopped":
            onEvent?(.stopped)
        case "error":
            onEvent?(.failed((body["message"] as? String) ?? "unknown"))
        default:
            break
        }
    }

    /// No echo cancellation, noise suppression or gain control: the models
    /// are trained on plain microphone audio, which is what the app sends too.
    private static let page = """
    <!doctype html><meta charset="utf-8"><script>
    let ctx = null, stream = null, source = null, node = null, running = false, generation = 0;
    const post = (m) => webkit.messageHandlers.capture.postMessage(m);
    async function captureStart() {
      if (running) return;
      running = true;
      const mine = ++generation;
      try {
        const opened = await navigator.mediaDevices.getUserMedia({ audio: {
          channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false
        } });
        // Stopped (or restarted) while the microphone was opening: this
        // stream belongs to nobody, so it is closed rather than recorded.
        if (mine !== generation || !running) {
          opened.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = opened;
        ctx = new AudioContext();
        await ctx.resume();
        source = ctx.createMediaStreamSource(stream);
        node = ctx.createScriptProcessor(2048, 1, 1);
        node.onaudioprocess = (event) => {
          if (!running) return;
          const input = event.inputBuffer.getChannelData(0);
          const pcm = new Int16Array(input.length);
          let peak = 0;
          for (let i = 0; i < input.length; i++) {
            const s = Math.max(-1, Math.min(1, input[i]));
            const a = Math.abs(s);
            if (a > peak) peak = a;
            pcm[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
          }
          const bytes = new Uint8Array(pcm.buffer);
          let binary = "";
          for (let i = 0; i < bytes.length; i += 0x8000) {
            binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
          }
          post({ type: "pcm", data: btoa(binary), peak });
        };
        source.connect(node);
        node.connect(ctx.destination);
        post({ type: "started", rate: ctx.sampleRate });
      } catch (error) {
        if (mine !== generation) return;
        running = false;
        post({ type: "error", message: (error && error.name) || "capture_failed" });
      }
    }
    function captureStop() {
      const wasRunning = running;
      running = false;
      generation++;
      try { if (node) node.disconnect(); if (source) source.disconnect(); } catch (e) {}
      if (stream) stream.getTracks().forEach((t) => t.stop());
      const closing = ctx;
      ctx = stream = source = node = null;
      // Reported before the context closes: every sample is already posted,
      // and waiting on close() only delayed the upload.
      if (wasRunning) post({ type: "stopped" });
      if (closing) closing.close().catch(() => {});
    }
    </script>
    """
}

/// `WKUserContentController` retains its handlers; this breaks the cycle.
@MainActor
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: KeyboardMicrophoneCapture?

    init(_ target: KeyboardMicrophoneCapture) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
