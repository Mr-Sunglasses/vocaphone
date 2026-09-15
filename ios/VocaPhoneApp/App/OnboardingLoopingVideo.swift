import AVFoundation
import SwiftUI
import UIKit

/// Silent looping clip for a first-run media well.
///
/// Sized by width: height follows the file's own proportions. Same outer
/// width as the card above it; corners match that card.
/// Does not change the audio session. vocaphone is a dictation host; a
/// decoration must not steal playback from the microphone path.
struct OnboardingLoopingVideo: View {
    var resource: String
    /// Width / height of `SetupKeyboard.mp4` after cropping the island and
    /// leaving 6pt above the nav bar (1180×1258).
    var aspectWidthOverHeight: CGFloat = 1180 / 1258
    /// 1 is file speed; 0.5 is half speed.
    var rate: Float = 0.5
    var cornerRadius: CGFloat = VocaMetrics.cardRadius

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .aspectRatio(aspectWidthOverHeight, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                OnboardingLoopingVideoHost(
                    resource: resource,
                    reduceMotion: reduceMotion,
                    isActive: scenePhase == .active,
                    rate: rate
                )
            }
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

private struct OnboardingLoopingVideoHost: UIViewRepresentable {
    var resource: String
    var reduceMotion: Bool
    var isActive: Bool
    var rate: Float

    func makeUIView(context: Context) -> OnboardingLoopingVideoView {
        let view = OnboardingLoopingVideoView()
        // UIViewRepresentable otherwise hugs and the clip sits inset in its well.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.load(resource: resource, reduceMotion: reduceMotion, isActive: isActive, rate: rate)
        return view
    }

    func updateUIView(_ view: OnboardingLoopingVideoView, context: Context) {
        view.setPlayback(reduceMotion: reduceMotion, isActive: isActive, rate: rate)
    }

    static func dismantleUIView(_ view: OnboardingLoopingVideoView, coordinator: ()) {
        view.stop()
    }
}

final class OnboardingLoopingVideoView: UIView {
    private let playerLayer = AVPlayerLayer()
    private var looper: AVPlayerLooper?
    private var queue: AVQueuePlayer?
    private var rate: Float = 0.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }

    func load(resource: String, reduceMotion: Bool, isActive: Bool, rate: Float) {
        self.rate = rate
        guard queue == nil else {
            setPlayback(reduceMotion: reduceMotion, isActive: isActive, rate: rate)
            return
        }
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            return
        }
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.defaultRate = rate
        looper = AVPlayerLooper(player: queue, templateItem: item)
        self.queue = queue
        playerLayer.player = queue
        setPlayback(reduceMotion: reduceMotion, isActive: isActive, rate: rate)
    }

    func setPlayback(reduceMotion: Bool, isActive: Bool, rate: Float) {
        self.rate = rate
        queue?.defaultRate = rate
        // Pause in Settings instead of looping in the background — that hitch
        // is the stutter on the way out.
        if reduceMotion || !isActive {
            queue?.pause()
            if reduceMotion { queue?.seek(to: .zero) }
        } else if let queue, abs(queue.rate - rate) > 0.01 {
            queue.playImmediately(atRate: rate)
        }
    }

    func stop() {
        queue?.pause()
        queue = nil
        looper = nil
        playerLayer.player = nil
    }
}
