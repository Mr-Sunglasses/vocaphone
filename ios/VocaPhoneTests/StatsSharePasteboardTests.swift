import Testing
import UIKit

/// Composers paste through `UIPasteboard.string` and `.image`, which read only
/// the first pasteboard item, so this checks what a Paste into X receives.
@MainActor
struct StatsSharePasteboardTests {
    @Test func xPastesTheCardBecauseItsTextIsPrefilled() throws {
        let card = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let board = try #require(UIPasteboard(name: .init(UUID().uuidString), create: true))
        defer { UIPasteboard.remove(withName: board.name) }
        board.items = StatsShareComposer.xPasteboardItems(cardPNG: card, message: "hello")
        #expect(board.image != nil)
        #expect(board.strings == ["hello"])
    }
}
