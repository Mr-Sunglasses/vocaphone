import LinkPresentation
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

    /// The pasteboard stays local so private usage totals don't sync to
    /// another Apple device.
    static func copyXPayload(image: UIImage?, message: String) -> PayloadResult {
        let items = StatsShareComposer.xPasteboardItems(
            cardPNG: image?.pngData(),
            message: message
        )
        UIPasteboard.general.setItems(items, options: [.localOnly: true])
        return PayloadResult(
            cardCopied: items.count > 1 && UIPasteboard.general.hasImages,
            textCopied: UIPasteboard.general.hasStrings
        )
    }

    /// Hands the card and post to whichever app the person picks. Several
    /// (LinkedIn and Instagram among them) keep the image and drop the text,
    /// so the post text also waits on the local pasteboard.
    static func presentShareSheet(card: UIImage?, message: String) -> Bool {
        guard let presenter = topViewController() else { return false }
        var items: [Any] = []
        if let card { items.append(StatsCardActivityItem(card: card)) }
        items.append(message)
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.excludedActivityTypes = [.assignToContact, .addToReadingList]
        if let popover = sheet.popoverPresentationController {
            let bounds = presenter.view.bounds
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: message]],
            options: [.localOnly: true]
        )
        presenter.present(sheet, animated: true)
        return true
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// Gives the share sheet's header the card as its preview and a readable
/// title, rather than a generic "Image".
private final class StatsCardActivityItem: NSObject, UIActivityItemSource {
    private let card: UIImage

    init(card: UIImage) {
        self.card = card
    }

    func activityViewControllerPlaceholderItem(_: UIActivityViewController) -> Any {
        card
    }

    func activityViewController(
        _: UIActivityViewController,
        itemForActivityType _: UIActivity.ActivityType?
    ) -> Any? {
        card
    }

    func activityViewControllerLinkMetadata(_: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = "My VocaPhone stats"
        metadata.imageProvider = NSItemProvider(object: card)
        metadata.iconProvider = NSItemProvider(object: card)
        return metadata
    }
}
