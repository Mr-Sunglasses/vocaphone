#if DEBUG
import Testing
import UIKit

/// Not an assertion suite: it writes the pressed-key preview to a PNG so the
/// balloon, its taper and the neck over the key can be looked at without
/// installing the keyboard on a device. Set VOCA_RENDER_DIR to collect them.
@MainActor
struct KeyPreviewRenderTests {
    @Test func renderPressedKeyPreview() throws {
        guard let directory = ProcessInfo.processInfo.environment["VOCA_RENDER_DIR"] else { return }

        let metrics = KeyboardMetrics.resolved(for: UITraitCollection {
            $0.verticalSizeClass = .regular
        })
        for (name, isDark) in [("preview-light", false), ("preview-dark", true)] {
            let palette = KeyboardPalette(isDark: isDark)
            let grid = KeyGridView(metrics: metrics, palette: palette)
            let canvas = UIView(
                frame: CGRect(x: 0, y: 0, width: 393, height: metrics.gridHeight + 60)
            )
            canvas.backgroundColor = palette.background
            grid.frame = CGRect(
                x: 0,
                y: 60,
                width: 393,
                height: metrics.gridHeight
            )
            canvas.addSubview(grid)
            canvas.layoutIfNeeded()

            // Press one key in the middle of the row and one against the left
            // edge, where the balloon is clamped and the neck sits off-centre.
            for letter in ["g", "q"] {
                guard let key = grid.keyViews.first(where: { $0.spec.cap == KeyCap.character(letter) })
                else { continue }
                key.isHighlighted = true
                grid.previewKeyForRendering(key)
            }
            canvas.layoutIfNeeded()

            // `drawHierarchy` renders nothing for a view that was never in a
            // window, which is every view in a unit test.
            let image = UIGraphicsImageRenderer(bounds: canvas.bounds).image { context in
                canvas.layer.render(in: context.cgContext)
            }
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
            try #require(image.pngData()).write(to: url)
        }
    }
}
#endif
