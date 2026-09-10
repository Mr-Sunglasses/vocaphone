import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct StatsShareCard: View {
    let stats: UsageStats
    let now: Date

    static let size = CGSize(width: 1_080, height: 720)
    private let background = Color(red: 0.07, green: 0.09, blue: 0.09)
    private let surface = Color.white.opacity(0.07)

    var body: some View {
        VStack(alignment: .leading, spacing: 38) {
            HStack(spacing: 20) {
                BrandMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("VocaPhone")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("My voice, in numbers")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                }
                Spacer()
                Text("PRIVATE BY DESIGN")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(Color.brand)
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 3),
                spacing: 18
            ) {
                cardStat("Words", StatsFormat.count(stats.totalWords), "text.word.spacing")
                cardStat("Sessions", StatsFormat.count(stats.totalDictations), "waveform")
                cardStat("Voice time", StatsFormat.duration(stats.totalSeconds), "timer")
                cardStat("Speed", "\(Int(stats.averageWordsPerMinute.rounded())) WPM", "bolt.fill")
                cardStat("Streak", "\(stats.currentStreak(at: now)) d", "flame.fill")
                cardStat("Best", "\(stats.bestStreak) d", "trophy.fill")
            }

            HStack {
                Capsule().fill(Color.brand).frame(width: 54, height: 7)
                Text("Voice typing that stays yours.")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("vocaphone.vocahq.com")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .foregroundStyle(.white)
        .padding(56)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(background)
        .environment(\.colorScheme, .dark)
    }

    private func cardStat(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(Color.brand)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(title.uppercased())
                .font(.system(size: 15, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .padding(22)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

@MainActor
enum StatsShareExporter {

    struct PayloadResult: Equatable {
        let cardCopied: Bool
        let textCopied: Bool
    }

    static func renderCard(_ stats: UsageStats, now: Date) -> UIImage? {
        let renderer = ImageRenderer(content: StatsShareCard(stats: stats, now: now))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(StatsShareCard.size)
        return renderer.uiImage
    }

    @discardableResult
    static func copyCard(_ stats: UsageStats, now: Date) -> Bool {
        guard let image = renderCard(stats, now: now) else { return false }
        return copyCard(image)
    }

    static func copyCard(_ image: UIImage) -> Bool {
        UIPasteboard.general.image = image
        return UIPasteboard.general.hasImages
    }

    /// Social deep links cannot carry an image attachment. Keep both pieces on
    /// the local pasteboard so a native app can receive them with Paste, while
    /// preventing private usage totals from syncing to another Apple device.
    static func copySharePayload(image: UIImage?, message: String) -> PayloadResult {
        var items: [[String: Any]] = []
        if let image, let data = image.pngData() {
            items.append([UTType.png.identifier: data])
        }
        items.append([UTType.utf8PlainText.identifier: message])
        UIPasteboard.general.setItems(items, options: [.localOnly: true])
        return PayloadResult(
            cardCopied: image != nil && UIPasteboard.general.hasImages,
            textCopied: UIPasteboard.general.hasStrings
        )
    }
}
