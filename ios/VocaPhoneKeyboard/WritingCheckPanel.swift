import SwiftUI

/// What the Writing check panel shows, and what its buttons do. The keyboard
/// controller fills it from ``WritingCheckClient`` and answers the actions,
/// on the main thread, like ``TypingRowState`` beside it.
final class WritingPanelModel: ObservableObject {
    @Published var report: WritingCheckClient.Report?
    @Published var isChecking = false
    /// The rest of the message is being read by walking the cursor.
    @Published var isReadingMessage = false

    var onApply: ((WritingSuggestion) -> Void)?
    var onDismiss: ((WritingSuggestion) -> Void)?
    var onAddWord: ((WritingSuggestion) -> Void)?
    var onAcceptAll: (() -> Void)?
    var onCheckWholeMessage: (() -> Void)?
    var onOpenApp: (() -> Void)?

    /// The mechanical fixes Accept all would make: those within the cursor's reach.
    var acceptAllCount: Int {
        guard let report else { return 0 }
        return report.suggestions.filter { report.canApply($0) && $0.mechanical }.count
    }
}

/// Grammarly's four colours: red, blue, green, purple, lightened for dark mode.
enum WritingColors {
    static func of(_ category: WritingCategory, isDark: Bool) -> Color {
        switch category {
        case .correctness: isDark ? Color(red: 1.0, green: 0.54, blue: 0.50) : Color(red: 0.85, green: 0.19, blue: 0.15)
        case .clarity: isDark ? Color(red: 0.54, green: 0.71, blue: 0.97) : Color(red: 0.10, green: 0.45, blue: 0.91)
        case .engagement: isDark ? Color(red: 0.51, green: 0.79, blue: 0.58) : Color(red: 0.09, green: 0.50, blue: 0.22)
        case .delivery: isDark ? Color(red: 0.84, green: 0.68, blue: 0.98) : Color(red: 0.56, green: 0.14, blue: 0.67)
        }
    }

    static func name(_ category: WritingCategory) -> String {
        switch category {
        case .correctness: "Correctness"
        case .clarity: "Clarity"
        case .engagement: "Engagement"
        case .delivery: "Delivery"
        }
    }
}

/// Grammarly's revision view in place of the keys: a card per suggestion with
/// its group, the change (struck through, then the replacement), why, and
/// Accept / Ignore / Add to dictionary. The tone and the actions close it.
struct WritingPanelView: View {
    @ObservedObject var model: WritingPanelModel
    let isDark: Bool
    let foreground: Color

    var body: some View {
        VStack(spacing: 6) {
            let suggestions = model.report?.suggestions ?? []
            if suggestions.isEmpty {
                VStack(spacing: 4) {
                    Text(emptyTitle)
                        .font(.system(size: 17, weight: .semibold))
                    Text("Checked on this iPhone. Nothing you type is sent anywhere.")
                        .font(.system(size: 13))
                        .foregroundStyle(foreground.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(suggestions, id: \.identity) { suggestion in
                            card(suggestion)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            footer
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
    }

    private var emptyTitle: String {
        if model.isChecking || model.isReadingMessage { return "Checking…" }
        return model.report == nil ? "Nothing to check yet" : "No issues found"
    }

    private func card(_ s: WritingSuggestion) -> some View {
        let color = WritingColors.of(s.category, isDark: isDark)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("\(WritingColors.name(s.category)) · \(s.title)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.7))
                    .lineLimit(1)
            }
            if let replacement = s.shownReplacement {
                change(s.shownOriginal, replacement, color: color)
            }
            Text(s.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            let reachable = model.report?.canApply(s) ?? s.isActionable
            if s.isActionable, !reachable {
                // Read by "Whole message", beyond what the keyboard can edit.
                Text("Move the cursor nearer to fix this.")
                    .font(.system(size: 12))
                    .foregroundStyle(foreground.opacity(0.6))
            }
            HStack(spacing: 14) {
                if s.isActionable {
                    Button("Accept") { model.onApply?(s) }
                        .fontWeight(.semibold)
                        .disabled(!reachable)
                }
                Button("Ignore") { model.onDismiss?(s) }
                if s.kind == "spelling", !s.shownOriginal.contains(where: \.isWhitespace) {
                    Button("Add to dictionary") { model.onAddWord?(s) }
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(Color(BrandPalette.accent(isDark: isDark)))
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(foreground.opacity(0.07)))
        .accessibilityElement(children: .contain)
    }

    private func change(_ original: String, _ replacement: String, color: Color) -> some View {
        var text = AttributedString()
        if !original.isEmpty {
            var struck = AttributedString(original)
            struck.strikethroughStyle = .single
            struck.foregroundColor = foreground.opacity(0.6)
            text += struck
            if !replacement.isEmpty { text += AttributedString("  ") }
        }
        if !replacement.isEmpty {
            var added = AttributedString(replacement)
            added.foregroundColor = color
            added.font = .system(size: 16, weight: .semibold)
            text += added
        } else {
            text += AttributedString("  (remove)")
        }
        return Text(text)
            .font(.system(size: 16))
            .lineLimit(2)
            .accessibilityLabel(replacement.isEmpty ? "Remove \(original)" : "\(original) becomes \(replacement)")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            let tones = model.report?.tones ?? []
            Text(tones.isEmpty ? "" : "Sounds " + tones.map { "\($0.emoji) \($0.label)" }.joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundStyle(foreground.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.acceptAllCount >= 2 {
                Button("Accept all \(model.acceptAllCount)") { model.onAcceptAll?() }
            }
            Button(model.isReadingMessage ? "Reading…" : "Whole message") { model.onCheckWholeMessage?() }
                .disabled(model.isReadingMessage)
            Button("Open app") { model.onOpenApp?() }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(Color(BrandPalette.accent(isDark: isDark)))
        .frame(minHeight: 36)
    }
}

extension WritingSuggestion {
    /// Stable on screen: the same change at the same place.
    var identity: String { "\(kind):\(start):\(end):\(replacement ?? "")" }
}
