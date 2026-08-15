import SwiftUI
import UIKit

/// The small set of shapes the app composes screens from.
///
/// Deliberately small. The design standard asks for one token layer and native
/// controls, not a component library — so what lives here is what more than one
/// screen genuinely shares: a card, a status line, a section heading, and the
/// numbers that keep their spacing and radii from drifting.
enum VocaMetrics {
    /// 4-point foundation, 8-point rhythm.
    static let tight: CGFloat = 4
    static let related: CGFloat = 8
    static let padding: CGFloat = 16
    static let grouping: CGFloat = 20
    static let section: CGFloat = 32

    /// Cards and fields. Keys and the dictation bar have their own vocabulary,
    /// inside the keyboard extension where they belong.
    static let cardRadius: CGFloat = 14
    static let fieldRadius: CGFloat = 12
    /// Large recording and hero surfaces only.
    static let heroRadius: CGFloat = 22

    /// The smallest target iOS considers reliably tappable. A control below
    /// this is not a small control, it is a control that gets missed — and what
    /// the thumb hits instead is whatever is next to it.
    static let minimumTarget: CGFloat = 44
}

/// A coherent state, decision, or task — never a generic wrapper.
///
/// Solid surface, one thin border, no shadow. Depth here comes from the border
/// and the surface contrast, which is what keeps a screen of these from reading
/// as a stack of floating slabs.
struct VocaCard<Content: View>: View {
    var padding: CGFloat = VocaMetrics.padding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .background(Color.vocaSurface, in: shape)
            .overlay(shape.strokeBorder(Color.vocaBorder, lineWidth: 1))
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: VocaMetrics.cardRadius, style: .continuous)
    }
}

/// A screen section's name. Quiet, so the content under it stays dominant.
struct VocaSectionHeader: View {
    let title: String
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: VocaMetrics.related)
            if let action {
                Button(action.title, action: action.perform)
                    .font(.subheadline)
            }
        }
    }
}

/// How a piece of the product is doing right now.
///
/// The colour never carries the meaning alone: every case pairs it with a symbol
/// and the caller supplies words. That is what makes the row survive
/// Differentiate Without Color, and a red/green deficiency.
enum VocaStatus: Equatable {
    case ready
    case recording
    case working
    case attention
    case failed
    case inactive

    var tint: Color {
        switch self {
        case .ready: .brand
        case .recording: .vocaRecording
        case .working, .attention: .vocaWarning
        case .failed: .vocaError
        case .inactive: .vocaDisabled
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .recording: "record.circle"
        case .working: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .attention: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        case .inactive: "circle.dashed"
        }
    }
}

/// A status and its sentence. The symbol and the words are one accessibility
/// element, because reading them apart tells the user nothing.
///
/// The symbol moves above the text at accessibility sizes rather than fighting
/// it for width: side by side, a 60pt headline leaves the symbol perhaps two
/// characters of room, and the two collide.
struct VocaStatusLine: View {
    let status: VocaStatus
    let title: String
    var detail: String?
    /// Set on the home screen's session card, which is the one place on that
    /// screen the eye should land first.
    var isProminent = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: VocaMetrics.related) {
                    symbol
                    text
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: VocaMetrics.related + 2) {
                    symbol
                    text
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var symbol: some View {
        Image(systemName: status.symbolName)
            .foregroundStyle(status.tint)
            .imageScale(isProminent ? .large : .medium)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(isProminent ? .title3.weight(.semibold) : .headline)
            if let detail {
                Text(detail)
                    .font(isProminent ? .callout : .subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A "Copied" confirmation that always behaves the same way.
///
/// Three screens had three copy buttons with three different timings and three
/// different words for the same thing. Copying is the one action on those
/// screens where nothing else on screen changes, so the confirmation is the only
/// feedback there is — and it should not vary by screen.
struct VocaCopyButton: View {
    let title: String
    let value: String?
    var prominent = true

    @State private var didCopy = false

    var body: some View {
        Group {
            if prominent {
                VocaPrimaryButton(
                    title: didCopy ? "Copied" : title,
                    symbol: didCopy ? "checkmark" : "doc.on.doc",
                    action: copy
                )
            } else {
                Button(action: copy) {
                    Label(
                        didCopy ? "Copied" : title,
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                }
            }
        }
        .disabled(value == nil)
        .animation(.easeInOut(duration: 0.18), value: didCopy)
    }

    private func copy() {
        guard let value else { return }
        UIPasteboard.general.string = value
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
}

/// The destructive action, sized to be aimed at.
///
/// Compact rather than full-width, and deliberately not sharing a footprint
/// with the primary action above it. Two stacked full-width buttons put a
/// destructive target directly beneath a constructive one, and a thumb that
/// falls a few points short of Delete selects a model instead — which is the
/// one mistake in this list that costs the user a download.
///
/// A tinted border rather than a filled one: it has to read as destructive
/// without competing with the filled primary for the eye. The role also gives
/// VoiceOver the destructive trait, which the plain text button it replaces
/// never carried.
struct VocaDestructiveButton: View {
    let title: String
    var symbol: String = "trash"
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, VocaMetrics.related)
                .frame(minHeight: VocaMetrics.minimumTarget)
        }
        .buttonStyle(.bordered)
        .tint(Color.vocaError)
    }
}

/// The one filled action a card is allowed.
///
/// A disabled one drops to a bordered treatment rather than staying filled.
/// `.borderedProminent` keeps drawing the label in the colour it was told to
/// use, so a disabled filled button ends up white-on-grey — legible enough to
/// notice and not legible enough to read, which is the worst of both. Bordered
/// says "not available" through shape as well as colour, and its label keeps
/// full contrast.
struct VocaPrimaryButton: View {
    let title: String
    var symbol: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Label(title, systemImage: symbol)
                } else {
                    Text(title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isEnabled ? Color.brand : Color.vocaRecessedSurface)
        .foregroundStyle(isEnabled ? Color.onBrand : Color.vocaSecondaryText)
        .controlSize(.large)
    }
}
