#if DEBUG
import SwiftUI

/// The four ways every screen has to be looked at before it is finished.
///
/// The app has been seen in exactly one of them: default size, light, English,
/// left to right. The design standard asks for the other three — "scalable type
/// without clipped content or unreachable controls" and "localization-safe
/// layouts for longer labels and right-to-left scripts" — and until now the only
/// way to check either was to change a system setting and rebuild.
enum PreviewVariant: String, CaseIterable, Identifiable {
    case standard
    case dark
    /// `.accessibility5` is the largest size iOS offers, and the one where a
    /// side-by-side `HStack` stops fitting. Anything that survives it survives
    /// the four sizes below it.
    case accessibility
    /// Arabic, mirrored. Catches hardcoded leading padding, symbols that should
    /// have flipped, and anything positioned with a fixed offset.
    case rightToLeft

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "Default"
        case .dark: "Dark"
        case .accessibility: "Accessibility 5"
        case .rightToLeft: "Right to left"
        }
    }

    var colorScheme: ColorScheme {
        self == .dark ? .dark : .light
    }

    var dynamicTypeSize: DynamicTypeSize {
        self == .accessibility ? .accessibility5 : .large
    }

    var layoutDirection: LayoutDirection {
        self == .rightToLeft ? .rightToLeft : .leftToRight
    }

    /// The locale only mirrors the layout and the date formats; the copy stays
    /// English until there is a String Catalog to translate it from. Seeing an
    /// English sentence laid out right to left is still the check that matters
    /// here — it is the *layout* that has never been looked at.
    var locale: Locale {
        self == .rightToLeft ? Locale(identifier: "ar") : Locale(identifier: "en_US")
    }
}

/// One screen, in one variant, with the environment it needs to render.
///
/// Every preview in the app goes through this rather than assembling its own
/// stack of modifiers, so a screen cannot be previewed against a coordinator or
/// a defaults store that the next screen does not use.
struct PreviewHost<Content: View>: View {
    var variant: PreviewVariant = .standard
    var coordinator: RecordingCoordinator = .previewIdle()
    var store: UserDefaults = PreviewFixtures.defaults
    var content: () -> Content

    init(
        _ variant: PreviewVariant = .standard,
        coordinator: RecordingCoordinator = .previewIdle(),
        store: UserDefaults = PreviewFixtures.defaults,
        hasDictatedOnce: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.variant = variant
        self.coordinator = coordinator
        self.store = store
        self.content = content
        // Registration only — see `PreviewFixtures.defaults`. Repeating it per
        // host is free and means no preview depends on another having run.
        //
        // App Group values cannot be redirected the way `defaultAppStorage`
        // redirects the standard store, so this one is process-wide: two
        // previews open at once share whichever value rendered last. That is
        // only visible for the first-run copy on the home screen, and only in a
        // canvas showing both variants of it simultaneously.
        PreviewFixtures.registerAppGroupDefaults(hasDictatedOnce: hasDictatedOnce)
    }

    var body: some View {
        content()
            .environment(coordinator)
            // Redirects every `@AppStorage` that names no store away from the
            // container the installed app writes to.
            .defaultAppStorage(store)
            .environment(\.colorScheme, variant.colorScheme)
            .environment(\.dynamicTypeSize, variant.dynamicTypeSize)
            .environment(\.layoutDirection, variant.layoutDirection)
            .environment(\.locale, variant.locale)
            .background(Color.vocaCanvas)
    }
}

/// The same screen in all four variants, side by side.
///
/// Use it as the last preview in a file. The per-state previews above it answer
/// "does this state read correctly"; this one answers "does it still fit", which
/// is the question the app has never been asked.
struct PreviewMatrix<Content: View>: View {
    var coordinator: RecordingCoordinator = .previewIdle()
    var store: UserDefaults = PreviewFixtures.defaults
    var hasDictatedOnce = true
    var content: () -> Content

    init(
        coordinator: RecordingCoordinator = .previewIdle(),
        store: UserDefaults = PreviewFixtures.defaults,
        hasDictatedOnce: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.coordinator = coordinator
        self.store = store
        self.hasDictatedOnce = hasDictatedOnce
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ForEach(PreviewVariant.allCases) { variant in
                VStack(spacing: 8) {
                    Text(variant.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    PreviewHost(
                        variant,
                        coordinator: coordinator,
                        store: store,
                        hasDictatedOnce: hasDictatedOnce,
                        content: content
                    )
                        // A phone's worth of width and height, so what clips
                        // here clips on the device.
                        .frame(width: 360, height: 760)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(.separator)
                        )
                }
            }
        }
        .padding(24)
    }
}
#endif
