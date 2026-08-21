import SwiftUI

/// A replayable explanation of iOS's previous-app gesture. This is deliberately
/// a demonstration, not a fake navigation control: the user still swipes the
/// real home indicator at the bottom edge of the device.
struct SwipeBackCoach: View {
    let reduceMotion: Bool
    var compact = false
    var prominent = false

    @State private var progress: CGFloat = 0
    @State private var replayID = 0
    @State private var interactionGeneration = 0
    @State private var dragBaseline: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: VocaMetrics.related) {
            GeometryReader { proxy in
                let width = proxy.size.width

                ZStack(alignment: .bottom) {
                    destinationCard
                        .padding(.horizontal, 4)
                        .opacity(0.45 + progress * 0.55)

                    vocaphoneCard
                        .padding(.horizontal, 10)
                        .scaleEffect(1 - progress * 0.035)
                        .offset(x: progress * width * 0.72, y: -8)
                        .shadow(
                            color: .black.opacity(0.08 + progress * 0.08),
                            radius: 8,
                            x: -3,
                            y: 3
                        )

                    Capsule()
                        .fill(Color.brand.opacity(0.24))
                        .frame(width: 44 + progress * 74, height: 8)
                        .offset(x: -width * 0.22 + progress * width * 0.24, y: -16)

                    ZStack {
                        Circle()
                            .fill(Color.brand)
                            .frame(width: prominent ? 48 : 32, height: prominent ? 48 : 32)
                            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
                        Image(systemName: "hand.point.up.left.fill")
                            .font((prominent ? Font.body : Font.caption).weight(.bold))
                            .foregroundStyle(Color.onBrand)
                    }
                    .offset(x: -width * 0.31 + progress * width * 0.52, y: -26)
                    .opacity(reduceMotion ? 0 : 1 - Double(progress) * 0.45)

                    Capsule()
                        .fill(Color.vocaPrimaryText.opacity(0.72))
                        .frame(width: 82, height: 4)
                        .padding(.bottom, 4)
                }
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onChanged { value in
                            guard !reduceMotion,
                                  abs(value.translation.width) > abs(value.translation.height)
                            else { return }
                            if dragBaseline == nil {
                                interactionGeneration += 1
                                dragBaseline = progress
                            }
                            let baseline = dragBaseline ?? progress
                            progress = min(max(
                                baseline + value.translation.width / max(width * 0.72, 1),
                                0
                            ), 1)
                        }
                        .onEnded { _ in
                            guard dragBaseline != nil else { return }
                            dragBaseline = nil
                            withAnimation(.snappy(duration: 0.3)) {
                                progress = progress >= 0.45 ? 1 : 0
                            }
                        }
                )
            }
            .frame(height: prominent ? 258 : compact ? 150 : 174)
            .allowsHitTesting(!prominent)

            if prominent {
                Label(
                    "Preview only — do not swipe here",
                    systemImage: "play.rectangle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                HStack(spacing: 8) {
                    instruction(number: 1, title: "Touch the home bar")
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    instruction(number: 2, title: "Swipe right")
                }
            }

            if !prominent {
                HStack {
                    Label(
                        progress < 0.5 ? "Try the swipe in this demo" : "The previous app appears",
                        systemImage: progress < 0.5 ? "hand.point.up.left" : "text.cursor"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.brand)
                    .contentTransition(.symbolEffect(.replace))

                    Spacer()

                    Button("Replay swipe", action: replay)
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .task(id: replayID) {
            await play(expectedGeneration: interactionGeneration)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            prominent
                ? "Animation preview. Use the real iPhone home indicator at the bottom of the screen to return to the app where you were typing."
                : "Interactive demonstration. Swipe right along the home indicator to return to the app where you were typing."
        )
        .accessibilityAction(named: "Replay swipe", replay)
    }

    private var destinationCard: some View {
        RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            .fill(Color.vocaRecessedSurface)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Where you were typing", systemImage: "text.cursor")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.brand)
                    HStack(spacing: 3) {
                        Text("Your cursor is still here")
                            .font(.caption)
                        Rectangle()
                            .fill(Color.brand)
                            .frame(width: 2, height: 15)
                    }
                }
                .padding(12)
            }
            .frame(height: prominent ? 232 : compact ? 132 : 156)
    }

    private var vocaphoneCard: some View {
        RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
            .fill(Color.vocaSurface)
            .overlay(
                RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.vocaBorder, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("vocaphone is recording", systemImage: "mic.fill")
                        .font((prominent ? Font.subheadline : Font.caption).weight(.semibold))
                        .foregroundStyle(Color.vocaRecording)
                    HStack(spacing: 4) {
                        ForEach(0..<8, id: \.self) { index in
                            Capsule()
                                .fill(Color.vocaRecording.opacity(0.55))
                                .frame(width: 3, height: CGFloat(7 + (index % 4) * 4))
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: prominent ? 194 : compact ? 112 : 136)
    }

    private func instruction(number: Int, title: String) -> some View {
        HStack(spacing: 5) {
            Text("\(number)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.onBrand)
                .frame(width: 20, height: 20)
                .background(Color.brand, in: Circle())
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func replay() {
        interactionGeneration += 1
        replayID += 1
    }

    private func play(expectedGeneration: Int) async {
        if reduceMotion {
            progress = 1
            return
        }

        progress = 0
        try? await Task.sleep(for: .milliseconds(380))
        guard !Task.isCancelled, expectedGeneration == interactionGeneration else { return }
        withAnimation(.smooth(duration: 0.9)) { progress = 1 }
    }
}

#if DEBUG

#Preview("Swipe back coach") {
    SwipeBackCoach(reduceMotion: false)
        .padding()
        .background(Color.vocaCanvas)
}
#endif
