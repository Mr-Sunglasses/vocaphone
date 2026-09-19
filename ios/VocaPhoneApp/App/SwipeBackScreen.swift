import SwiftUI

/// The one step vocaphone cannot take for the user.
///
/// A keyboard extension has no way to put the app it came from back on screen;
/// only the person holding the phone can do that, with the system's own
/// previous-app gesture. So the screen is a demonstration and nothing else: no
/// controls to mistake for navigation, no status to read, one sentence and a
/// picture of the gesture running on a loop.
///
/// The phone in the picture is drawn, not photographed, so it follows the
/// palette into dark mode and scales with the space it is given.
struct SwipeBackScreen: View {
    var title = "Swipe back to your app"
    var detail = "Recording follows you there."
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            Color.vocaCanvas
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: VocaMetrics.section) {
                    Spacer(minLength: 0)

                    SwipeBackPhone(reduceMotion: reduceMotion)
                        .frame(maxWidth: 340)
                        .frame(height: 330)

                    VStack(spacing: VocaMetrics.related + 2) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                        Text(detail)
                            .font(.title3)
                            .foregroundStyle(Color.vocaSecondaryText)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, VocaMetrics.grouping)
                .padding(.vertical, VocaMetrics.section)
                .frame(maxWidth: .infinity, minHeight: 640)
            }
        }
    }
}

/// The bottom of a phone, with the gesture playing inside it.
///
/// Only the bottom: the top of a phone has nothing to do with a gesture made at
/// the home indicator, and leaving it out is what keeps the keys underneath big
/// enough to recognise. It ends in a fade rather than a cut — a hard edge across
/// the middle of a phone reads as a drawing mistake.
private struct SwipeBackPhone: View {
    let reduceMotion: Bool

    /// 0 — vocaphone is on screen. 1 — the app the user came from is back, with
    /// the keyboard and the cursor still waiting in it.
    @State private var progress: CGFloat = 0
    @State private var touchOpacity: Double = 0

    /// How far above the drawn area the shell continues before it fades out.
    private static let overhang: CGFloat = 190
    private static let shellWidth: CGFloat = 9
    /// Room under the phone for the finger, which overlaps the bottom edge the
    /// way a real thumb does.
    private static let bottomRoom: CGFloat = 46
    /// The strip the home indicator lives in, which the keys stay clear of.
    static let indicatorRoom: CGFloat = 30
    /// The fade at the top, as fractions of the drawn height. Four stops
    /// rather than two: a straight ramp starts somewhere, and the eye finds
    /// exactly where.
    private static let fade: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .black.opacity(0.18), location: 0.08),
        .init(color: .black.opacity(0.62), location: 0.16),
        .init(color: .black, location: 0.26),
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let phoneHeight = proxy.size.height - Self.bottomRoom
            let shellHeight = phoneHeight + Self.overhang
            let radius = width * 0.155

            ZStack(alignment: .bottom) {
                // The phone, fading out towards the top of the frame.
                ZStack(alignment: .bottom) {
                    screen(
                        width: width,
                        height: shellHeight,
                        visible: phoneHeight,
                        radius: radius
                    )
                    .offset(y: -Self.shellWidth)

                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.vocaPrimaryText, lineWidth: Self.shellWidth)
                        .frame(width: width, height: shellHeight)

                    Capsule()
                        .fill(Color.vocaPrimaryText.opacity(0.8))
                        .frame(width: width * 0.38, height: 5)
                        .padding(.bottom, 22)
                }
                .frame(width: width, height: phoneHeight, alignment: .bottom)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: Self.fade,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .padding(.bottom, Self.bottomRoom)

                // Outside the mask, so it stays solid and can hang past the
                // bottom edge the way a thumb does.
                touch(width: width)
            }
            .frame(width: width, height: proxy.size.height, alignment: .bottom)
        }
        .task(id: reduceMotion) { await play() }
        .accessibilityElement()
        .accessibilityLabel(
            "Animation. A finger swipes right along the bottom edge of a phone, "
                + "and the app the user was typing in comes back with its keyboard."
        )
    }

    private func screen(
        width: CGFloat,
        height: CGFloat,
        visible: CGFloat,
        radius: CGFloat
    ) -> some View {
        ZStack {
            hostApp(width: width)

            vocaphone(visible: visible)
                .offset(x: progress * width)
                .shadow(color: .black.opacity(0.16 * (1 - progress)), radius: 12, x: -6)
        }
        .frame(width: width - 2 * Self.shellWidth, height: height - 2 * Self.shellWidth)
        .clipShape(
            RoundedRectangle(cornerRadius: radius - Self.shellWidth, style: .continuous)
        )
    }

    /// Where the user was typing: the keyboard is still up and the cursor is
    /// still in the field, which is the whole reason the gesture is worth making.
    private func hostApp(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Color.vocaSurface
            SwipeBackKeyboardMark()
                .frame(height: width * 0.6 + Self.indicatorRoom)
        }
    }

    /// The wordmark sits in the part of the screen that is actually drawn.
    /// Centred in the whole screen it would land under the fade, which is how
    /// it came out cropped.
    private func vocaphone(visible: CGFloat) -> some View {
        Color.vocaSurface
            .overlay(alignment: .bottom) {
                VStack(spacing: VocaMetrics.related) {
                    BrandMark(size: 44)
                    Text("vocaphone")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.brand)
                }
                .opacity(0.3)
                .padding(.bottom, visible * 0.34)
            }
    }

    /// The finger. Grey and translucent on purpose — a hand illustration reads
    /// as a control to press, and this one is being watched, not used.
    private func touch(width: CGFloat) -> some View {
        Circle()
            .fill(Color.vocaPrimaryText.opacity(0.26))
            .frame(width: 92, height: 92)
            .offset(
                x: (-0.2 + progress * 0.46) * width,
                y: -(Self.bottomRoom + 8)
            )
            .opacity(touchOpacity)
    }

    private func play() async {
        guard !reduceMotion else {
            progress = 1
            touchOpacity = 0
            return
        }

        // The first pass starts with the screen. A lead-in is fine on the
        // repeats, when the user is watching a loop; on arrival it is dead time
        // in front of somebody who is standing in another app waiting to be
        // told what to do.
        var isFirstPass = true
        while !Task.isCancelled {
            progress = 0
            touchOpacity = 0
            if !isFirstPass {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled else { return }
            }
            isFirstPass = false

            // The finger arrives already moving. Showing it, then waiting, then
            // starting is three beats for one instruction.
            touchOpacity = 1
            withAnimation(.easeInOut(duration: 0.9)) { progress = 1 }
            try? await Task.sleep(for: .milliseconds(1_050))
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.28)) { touchOpacity = 0 }
            try? await Task.sleep(for: .milliseconds(700))
        }
    }
}

/// A keyboard at a glance: four rows, the shape of the thing rather than its
/// letters. The real `KeyGridView` is a different job — it is the keyboard
/// being configured, at the size it will be. This one is scenery, and drawing
/// letters at this scale would only make them unreadable.
private struct SwipeBackKeyboardMark: View {
    private static let rows: [[CGFloat]] = [
        Array(repeating: 1, count: 10),
        Array(repeating: 1, count: 9),
        [1.5] + Array(repeating: 1, count: 7) + [1.5],
        [2.2, 5.4, 2.2],
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let inset = width * 0.022
            let gap = width * 0.013
            // Ten columns, the way a QWERTY row divides a phone. Every other
            // row is measured in the same unit, so a wide key stays as wide as
            // the letters it spans plus the gaps it swallows.
            let unit = (width - 2 * inset - 9 * gap) / 10

            VStack(spacing: gap * 1.5) {
                ForEach(Array(Self.rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: gap) {
                        ForEach(Array(row.enumerated()), id: \.offset) { key, span in
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(fill(row: index, key: key, count: row.count))
                                .frame(width: unit * span + gap * (span - 1))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, inset)
            .padding(.top, gap * 2.5)
            // The bed reaches the bottom edge, the keys stop above the home
            // indicator — which is what iOS does, and what stops the bottom row
            // from sitting on top of the line the finger is following.
            .padding(.bottom, SwipeBackPhone.indicatorRoom)
        }
        .background(Color.vocaRecessedSurface)
    }

    /// Modifier keys sit a shade back, the way they do on the system keyboard.
    private func fill(row: Int, key: Int, count: Int) -> Color {
        let isEdge = key == 0 || key == count - 1
        let isModifier = (row == 2 && isEdge) || (row == 3 && isEdge)
        return isModifier ? Color.vocaBorder.opacity(0.75) : Color.vocaSurface
    }
}

#if DEBUG

#Preview("Swipe back screen") {
    SwipeBackScreen(reduceMotion: false)
}

#Preview("Swipe back screen — reduced motion") {
    SwipeBackScreen(reduceMotion: true)
}
#endif
