import SwiftUI
import Testing

/// The design system's load-bearing numbers, checked rather than trusted.
@MainActor
struct DesignSystemTests {
    /// The destructive button exists because the control it replaced was a
    /// footnote-sized text button sitting directly under "Use this model": a
    /// target about sixteen points tall, next to the one action it must never
    /// be mistaken for. Anything that shrinks it again brings that back.
    @Test func theDestructiveButtonIsAReliableTouchTarget() {
        let renderer = ImageRenderer(content: VocaDestructiveButton(title: "Delete model") {})
        let size = renderer.uiImage?.size ?? .zero
        #expect(size.height >= VocaMetrics.minimumTarget)
        // Compact, not full width. Sharing a footprint with the filled primary
        // above it is half of what made the two confusable.
        #expect(size.width < 320)
    }

    /// 44 points is Apple's own floor, and the reason this token exists at all.
    @Test func theMinimumTargetIsTheOneAppleSpecifies() {
        #expect(VocaMetrics.minimumTarget == 44)
    }
}
