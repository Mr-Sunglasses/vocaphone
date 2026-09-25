import SwiftUI

/// A first-launch invitation before the existing explanation and setup pages.
/// The moving words illustrate speech; this screen never starts recording.
struct OnboardingMotionIntroView: View {
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 42

    private let canvas = Color(red: 17 / 255, green: 26 / 255, blue: 21 / 255)
    private let mint = Color(red: 165 / 255, green: 239 / 255, blue: 200 / 255)
    private let paper = Color(red: 236 / 255, green: 245 / 255, blue: 237 / 255)

    var body: some View {
        GeometryReader { geometry in
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView {
                        content(width: geometry.size.width, flexibleStage: false)
                    }
                } else {
                    content(width: geometry.size.width, flexibleStage: true)
                        .frame(height: geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(canvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func content(width: CGFloat, flexibleStage: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 9) {
                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<5, id: \.self) { index in
                        Capsule()
                            .fill(mint)
                            .frame(width: 2, height: [10.0, 18.0, 25.0, 18.0, 10.0][index])
                    }
                }
                .frame(width: 27)
                Text("voca.")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .tracking(-1)
                    .foregroundStyle(mint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("VocaPhone")

            VStack(alignment: .leading, spacing: 0) {
                Text("Your words,")
                    .foregroundStyle(paper)
                Text("your way.")
                    .foregroundStyle(mint)
            }
            .font(.system(size: min(titleSize, width * 0.12), weight: .regular, design: .serif))
            .tracking(-2)
            .minimumScaleFactor(0.75)
            .padding(.top, 25)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text("Speak naturally. We'll keep up, whichever language feels right.")
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 174 / 255, green: 193 / 255, blue: 176 / 255))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .frame(maxWidth: 300, alignment: .leading)

            OnboardingMotionWordStage(reduceMotion: reduceMotion)
                .frame(height: flexibleStage ? nil : 270)
                .frame(maxWidth: .infinity, maxHeight: flexibleStage ? .infinity : nil)
                .padding(.top, flexibleStage ? 0 : 12)

            TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
                let blink = reduceMotion ? 1.0 : 0.35 + 0.65 * abs(cos(context.date.timeIntervalSinceReferenceDate * .pi / 1.8))
                HStack(spacing: 8) {
                    Circle()
                        .fill(mint)
                        .frame(width: 6, height: 6)
                        .opacity(blink)
                        .shadow(color: mint.opacity(0.7), radius: 5)
                    Text("A place for every voice")
                        .font(.system(size: 12))
                        .tracking(0.9)
                        .foregroundStyle(Color(red: 133 / 255, green: 165 / 255, blue: 143 / 255))
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 18)

            Button(action: onContinue) {
                HStack {
                    Text("Get started")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 19, weight: .medium))
                }
                .foregroundStyle(Color(red: 20 / 255, green: 38 / 255, blue: 26 / 255))
                .padding(.horizontal, 21)
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .background(mint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .accessibilityHint("Opens the introduction to how VocaPhone works")

            HStack(spacing: 6) {
                Capsule().fill(mint).frame(width: 17, height: 5)
                Circle().fill(Color(red: 73 / 255, green: 99 / 255, blue: 77 / 255))
                    .frame(width: 5, height: 5)
                Circle().fill(Color(red: 73 / 255, green: 99 / 255, blue: 77 / 255))
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 25)
        .padding(.top, 25)
        .padding(.bottom, 14)
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingMotionWordStage: View {
    let reduceMotion: Bool

    @State private var startedAt = Date()

    private struct Greeting: Identifiable {
        let id: Int
        let language: String
        let word: String
        let x: CGFloat
        let y: CGFloat
        let scale: CGFloat
    }

    private static let greetings: [Greeting] = [
        .init(id: 0, language: "English", word: "Hello", x: -92, y: -90, scale: 0.88),
        .init(id: 1, language: "हिन्दी", word: "नमस्ते", x: 88, y: -73, scale: 0.92),
        .init(id: 2, language: "Español", word: "Hola", x: -110, y: 24, scale: 0.79),
        .init(id: 3, language: "العربية", word: "مرحبا", x: 102, y: 36, scale: 0.84),
        .init(id: 4, language: "日本語", word: "こんにちは", x: -75, y: 100, scale: 0.8),
        .init(id: 5, language: "Français", word: "Bonjour", x: 64, y: 108, scale: 0.87),
        .init(id: 6, language: "ਪੰਜਾਬੀ", word: "ਸਤ ਸ੍ਰੀ ਅਕਾਲ", x: -126, y: -27, scale: 0.75),
        .init(id: 7, language: "Italiano", word: "Ciao", x: 120, y: -22, scale: 0.8),
    ]

    private let mint = Color(red: 165 / 255, green: 239 / 255, blue: 200 / 255)
    private let paper = Color(red: 232 / 255, green: 247 / 255, blue: 235 / 255)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            GeometryReader { geometry in
                let diameter = min(228, geometry.size.width - 20, geometry.size.height * 0.77)
                let scale = diameter / 228
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height * 0.53)
                let active = reduceMotion ? 0 : Int(elapsed / 0.95) % Self.greetings.count

                ZStack {
                    ForEach([1.0, 190.0 / 228, 142.0 / 228], id: \.self) { ring in
                        Circle()
                            .strokeBorder(ring == 1
                                ? Color(red: 65 / 255, green: 107 / 255, blue: 75 / 255)
                                : Color(red: 53 / 255, green: 88 / 255, blue: 60 / 255), lineWidth: 1)
                            .frame(width: diameter * ring, height: diameter * ring)
                            .scaleEffect(reduceMotion ? 1 : 0.96 + 0.11 * breathing(elapsed))
                            .opacity(reduceMotion ? 0.62 : 0.42 + 0.36 * breathing(elapsed))
                            .position(center)
                    }

                    ForEach(Self.greetings) { greeting in
                        let progress = progress(for: greeting.id, elapsed: elapsed)
                        if progress < 1 {
                            let travel = cubicBezier(progress, x1: 0.17, y1: 0.68, x2: 0.21, y2: 1)
                            Text(greeting.word)
                                .font(.system(size: greeting.word.count > 8 ? 15 : 18,
                                              weight: .medium))
                                .foregroundStyle(greeting.id.isMultiple(of: 3) ? mint : paper)
                                .fixedSize()
                                .scaleEffect(0.58 + (greeting.scale - 0.58) * travel)
                                .opacity(reduceMotion ? 0.72 : wordOpacity(progress))
                                .shadow(color: Color(red: 11 / 255, green: 16 / 255, blue: 14 / 255), radius: 12, x: 0, y: 1)
                                .position(
                                    x: center.x + greeting.x * scale * travel,
                                    y: center.y + greeting.y * scale * travel
                                )
                        }
                    }

                    Circle()
                        .fill(mint.opacity(0.06))
                        .frame(width: 136 * scale, height: 136 * scale)
                        .position(center)
                    Circle()
                        .fill(mint.opacity(0.09))
                        .frame(width: 106 * scale, height: 106 * scale)
                        .position(center)
                    Circle()
                        .fill(mint)
                        .frame(width: 88 * scale, height: 88 * scale)
                        .position(center)

                    HStack(alignment: .center, spacing: 3 * scale) {
                        ForEach(0..<7, id: \.self) { index in
                            Capsule()
                                .fill(Color(red: 28 / 255, green: 61 / 255, blue: 41 / 255))
                                .frame(width: 3 * scale,
                                       height: barHeight(index: index, elapsed: elapsed) * scale)
                        }
                    }
                    .position(center)

                    VStack(spacing: 4) {
                        Text(Self.greetings[active].language.uppercased())
                            .font(.system(size: 12, weight: .bold))
                            .tracking(2)
                            .foregroundStyle(mint)
                        Text(Self.greetings[active].word)
                            .font(.system(size: 21, design: .serif))
                            .foregroundStyle(paper)
                    }
                    .position(x: geometry.size.width / 2, y: 31)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Greetings in English, Hindi, Spanish, Arabic, Japanese, French, Punjabi, and Italian flow around a voice pulse")
    }

    private func progress(for index: Int, elapsed: TimeInterval) -> CGFloat {
        if reduceMotion { return index < 4 ? 0.82 : 2 }
        let cycle = Double(Self.greetings.count) * 0.95
        if elapsed < Double(index) * 0.95 { return 2 }
        let shifted = (elapsed - Double(index) * 0.95).truncatingRemainder(dividingBy: cycle)
        let phase = shifted < 0 ? shifted + cycle : shifted
        return CGFloat(phase / 3.3)
    }

    private func barHeight(index: Int, elapsed: TimeInterval) -> CGFloat {
        let envelope: [CGFloat] = [12, 21, 31, 18, 26, 14, 23]
        if reduceMotion { return envelope[index] }
        let bar = index + 1
        let delay = bar.isMultiple(of: 3) ? 0.57 : (bar.isMultiple(of: 2) ? 0.33 : 0)
        let phase = (elapsed + delay).truncatingRemainder(dividingBy: 1)
        let travel = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return envelope[index] * (0.48 + 0.8 * cubicBezier(travel, x1: 0.42, y1: 0, x2: 0.58, y2: 1))
    }

    private func breathing(_ elapsed: TimeInterval) -> CGFloat {
        let phase = elapsed.truncatingRemainder(dividingBy: 4) / 4
        let travel = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        return cubicBezier(travel, x1: 0.42, y1: 0, x2: 0.58, y2: 1)
    }

    private func wordOpacity(_ progress: CGFloat) -> CGFloat {
        if progress < 0.12 {
            return 0.95 * cubicBezier(progress / 0.12, x1: 0.17, y1: 0.68, x2: 0.21, y2: 1)
        }
        if progress < 0.72 {
            let eased = cubicBezier((progress - 0.12) / 0.6, x1: 0.17, y1: 0.68, x2: 0.21, y2: 1)
            return 0.95 - 0.1 * eased
        }
        let eased = cubicBezier((progress - 0.72) / 0.28, x1: 0.17, y1: 0.68, x2: 0.21, y2: 1)
        return 0.85 * (1 - eased)
    }

    private func cubicBezier(_ progress: CGFloat, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) -> CGFloat {
        let target = min(max(progress, 0), 1)
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<12 {
            let t = (low + high) / 2
            let inverse = 1 - t
            let x = 3 * inverse * inverse * t * x1 + 3 * inverse * t * t * x2 + t * t * t
            if x < target { low = t } else { high = t }
        }
        let t = (low + high) / 2
        let inverse = 1 - t
        return 3 * inverse * inverse * t * y1 + 3 * inverse * t * t * y2 + t * t * t
    }
}

#if DEBUG
#Preview("Motion intro") {
    OnboardingMotionIntroView(onContinue: {})
}
#endif
