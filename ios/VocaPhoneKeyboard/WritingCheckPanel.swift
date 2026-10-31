import SwiftUI

/// What the Writing check button and panel show, and what their buttons do.
/// The keyboard controller fills it from ``WritingCheckClient`` and answers
/// the actions, on the main thread, like ``TypingRowState`` beside it. Its own
/// object so a new report redraws the button and the panel and nothing else.
final class WritingPanelModel: ObservableObject {
    @Published var report: WritingCheckClient.Report?
    @Published var isChecking = false
    /// A check the user asked for with the button is on its way.
    @Published var isRunning = false
    /// The rest of the message is being read by walking the cursor.
    @Published var isReadingMessage = false

    /// The Writing check button: check the field now and show the result.
    var onCheck: (() -> Void)?
    var onApply: ((WritingSuggestion) -> Void)?
    var onDismiss: ((WritingSuggestion) -> Void)?
    var onAddWord: ((WritingSuggestion) -> Void)?
    var onAcceptAll: (() -> Void)?
    var onCheckWholeMessage: (() -> Void)?
    var onOpenApp: (() -> Void)?

    var isBusy: Bool { isChecking || isRunning || isReadingMessage }

    /// The mechanical fixes Accept all would make: those within the cursor's reach.
    var acceptAllCount: Int {
        guard let report else { return 0 }
        return report.suggestions.filter { report.canApply($0) && $0.mechanical }.count
    }
}

/// The four groups' colours, lightened for dark mode, and the accept colour.
enum WritingColors {
    static func of(_ category: WritingCategory, isDark: Bool) -> Color {
        switch category {
        case .correctness: isDark ? Color(red: 1.0, green: 0.42, blue: 0.42) : Color(red: 0.85, green: 0.19, blue: 0.15)
        case .clarity: isDark ? Color(red: 0.54, green: 0.71, blue: 0.97) : Color(red: 0.10, green: 0.45, blue: 0.91)
        case .engagement: isDark ? Color(red: 0.51, green: 0.79, blue: 0.58) : Color(red: 0.09, green: 0.50, blue: 0.22)
        case .delivery: isDark ? Color(red: 0.84, green: 0.68, blue: 0.98) : Color(red: 0.56, green: 0.14, blue: 0.67)
        }
    }

    /// The replacement and Accept: one teal for "this is the fix".
    static func fix(isDark: Bool) -> Color {
        isDark ? Color(red: 0.16, green: 0.78, blue: 0.64) : Color(red: 0.0, green: 0.55, blue: 0.45)
    }

    /// Readable on ``fix(isDark:)``.
    static func onFix(isDark: Bool) -> Color {
        isDark ? Color(red: 0.03, green: 0.15, blue: 0.12) : .white
    }

    /// What was there, struck through.
    static func struck(isDark: Bool) -> Color {
        isDark ? Color(red: 1.0, green: 0.42, blue: 0.42) : Color(red: 0.80, green: 0.16, blue: 0.13)
    }

    static func name(_ category: WritingCategory) -> String {
        switch category {
        case .correctness: "Correctness"
        case .clarity: "Clarity"
        case .engagement: "Engagement"
        case .delivery: "Delivery"
        }
    }

    static func symbol(_ category: WritingCategory) -> String {
        switch category {
        case .correctness: "checkmark.circle.fill"
        case .clarity: "eye.circle.fill"
        case .engagement: "sparkles"
        case .delivery: "bubble.left.circle.fill"
        }
    }
}

// MARK: - The button

/// Writing check's button at the start of the suggestion row: a ring to tap
/// before anything is checked, a spinning ring while checking, the number of
/// suggestions in a red disc, or a green tick when there are none. Tapping it
/// checks the whole field now, whether or not "Check while typing" is on.
struct WritingCheckButton: View {
    @ObservedObject var model: WritingPanelModel
    let isDark: Bool
    let foreground: Color
    let diameter: CGFloat

    @State private var spin = false

    private enum Face: Equatable {
        case idle, busy, count(Int), clean
    }

    private var face: Face {
        if model.isBusy, model.report == nil || model.isRunning { return .busy }
        guard let report = model.report else { return .idle }
        return report.count > 0 ? .count(report.count) : .clean
    }

    var body: some View {
        Button {
            model.onCheck?()
        } label: {
            ZStack {
                switch face {
                case .idle:
                    Circle()
                        .strokeBorder(WritingColors.fix(isDark: isDark), lineWidth: 2.5)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(WritingColors.fix(isDark: isDark))
                case .busy:
                    Circle()
                        .strokeBorder(foreground.opacity(0.18), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(WritingColors.fix(isDark: isDark), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .padding(1.25)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            spin = false
                            withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                        }
                case let .count(n):
                    Circle()
                        .fill(WritingColors.of(.correctness, isDark: isDark))
                    Circle()
                        .strokeBorder(.white.opacity(isDark ? 0.18 : 0.35), lineWidth: 1.5)
                    Text(n > 99 ? "99+" : "\(n)")
                        .font(.system(size: n > 9 ? 12 : 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                case .clean:
                    Circle()
                        .fill(WritingColors.fix(isDark: isDark))
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(WritingColors.onFix(isDark: isDark))
                }
            }
            .frame(width: diameter - 14, height: diameter - 14)
            .frame(width: diameter, height: diameter)
            .contentShape(.rect)
            .animation(.snappy(duration: 0.25), value: face)
        }
        .buttonStyle(WritingPressStyle())
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Checks your writing on this iPhone and shows each suggestion.")
    }

    private var accessibilityLabel: String {
        switch face {
        case .idle: "Writing check"
        case .busy: "Writing check, checking"
        case let .count(n): n == 1 ? "Writing check, 1 suggestion" : "Writing check, \(n) suggestions"
        case .clean: "Writing check, no suggestions"
        }
    }
}

/// Shrinks a little under the finger.
private struct WritingPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A Writing check fix in the suggestion row: what kind of fix, small, over
/// the change itself — the old words struck through, the new ones in teal.
struct WritingFixChipLabel: View {
    let candidate: TypingCandidate
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let caption = candidate.caption {
                Text(caption)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle((isDark ? Color.white : Color.black).opacity(0.55))
            }
            Text(change)
                .font(.system(size: 16, weight: .semibold))
        }
        .lineLimit(1)
    }

    private var change: AttributedString {
        var text = AttributedString()
        if let struck = candidate.struck, !struck.isEmpty {
            var old = AttributedString(struck)
            old.strikethroughStyle = .single
            old.foregroundColor = WritingColors.struck(isDark: isDark)
            old.font = .system(size: 16, weight: .regular)
            text += old
            text += AttributedString(" ")
        }
        var new = AttributedString(candidate.text)
        new.foregroundColor = WritingColors.fix(isDark: isDark)
        text += new
        return text
    }
}

// MARK: - The panel

/// The Writing check panel in place of the keys: one suggestion at a time on a
/// card — what kind of fix, the sentence with the old words struck through and
/// the new ones in teal, and why — with Accept and Dismiss under it, and the
/// rest behind "More". Checking shows a pulse; nothing left shows a cheer.
struct WritingPanelView: View {
    @ObservedObject var model: WritingPanelModel
    let isDark: Bool
    let foreground: Color

    @State private var index = 0
    @State private var showsMore = false
    /// Which way the last page turn went, for the slide.
    @State private var forward = true

    private var suggestions: [WritingSuggestion] { model.report?.suggestions ?? [] }

    private var current: WritingSuggestion? {
        suggestions.isEmpty ? nil : suggestions[min(index, suggestions.count - 1)]
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if showsMore {
                    morePage
                        .transition(.opacity)
                } else if let current, !(model.isRunning && model.isBusy) {
                    card(current)
                        .id(current.identity)
                        .transition(.asymmetric(
                            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
                        ))
                } else if model.isBusy {
                    checking
                        .transition(.opacity)
                } else {
                    clean
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(foreground.opacity(isDark ? 0.07 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(foreground.opacity(0.08), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .gesture(swipe)
            actions
                .layoutPriority(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.28), value: current?.identity)
        .animation(.snappy(duration: 0.28), value: model.isBusy)
        .animation(.snappy(duration: 0.2), value: showsMore)
        .onChange(of: suggestions.count) { _, count in
            if index >= count { index = max(0, count - 1) }
        }
    }

    // MARK: The card

    private func card(_ s: WritingSuggestion) -> some View {
        let color = WritingColors.of(s.category, isDark: isDark)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: WritingColors.symbol(s.category))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Text(s.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if suggestions.count > 1 { pager }
            }
            Text(changeLine(s))
                .font(.system(size: 18, weight: .regular))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(changeAccessibility(s))
            Text(s.message)
                .font(.system(size: 14))
                .foregroundStyle(foreground.opacity(0.68))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let tones = toneLine {
                Text(tones)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.5))
                    .lineLimit(1)
            }
            if s.isActionable, model.report?.canApply(s) == false {
                // Read by "Whole message", beyond what the keyboard can edit.
                Text("Move the cursor nearer to fix this.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button { turn(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous suggestion")
            Text("\(min(index, suggestions.count - 1) + 1) of \(suggestions.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(foreground.opacity(0.6))
            Button { turn(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .disabled(index >= suggestions.count - 1)
            .accessibilityLabel("Next suggestion")
        }
        .font(.system(size: 13, weight: .bold))
        .buttonStyle(.plain)
        .foregroundStyle(foreground.opacity(0.7))
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -40 { turn(by: 1) }
                if value.translation.width > 40 { turn(by: -1) }
            }
    }

    private func turn(by step: Int) {
        let next = min(max(index + step, 0), max(suggestions.count - 1, 0))
        guard next != index else { return }
        forward = step > 0
        index = next
    }

    /// The sentence around the change, the old words struck through in red and
    /// the new ones in teal.
    private func changeLine(_ s: WritingSuggestion) -> AttributedString {
        let context = WritingPanelView.context(of: s, in: model.report?.field.text ?? "")
        var text = AttributedString(context.before)
        let original = s.shownOriginal
        let replacement = s.shownReplacement
        if !original.isEmpty {
            var old = AttributedString(original)
            old.strikethroughStyle = .single
            old.foregroundColor = WritingColors.struck(isDark: isDark)
            text += old
        }
        if let replacement, !replacement.isEmpty {
            if !original.isEmpty { text += AttributedString(" ") }
            var new = AttributedString(replacement)
            new.foregroundColor = WritingColors.fix(isDark: isDark)
            new.font = .system(size: 18, weight: .bold)
            text += new
        }
        text += AttributedString(context.after)
        return text
    }

    private func changeAccessibility(_ s: WritingSuggestion) -> String {
        guard let replacement = s.shownReplacement else { return s.shownOriginal }
        if replacement.isEmpty { return "Remove \(s.shownOriginal)" }
        if s.shownOriginal.isEmpty { return "Add \(replacement)" }
        return "\(s.shownOriginal) becomes \(replacement)"
    }

    /// The words before and after `s` within its sentence, at most `limit`
    /// characters each way, with the spacing the change itself trimmed off.
    static func context(of s: WritingSuggestion, in text: String, limit: Int = 60) -> (before: String, after: String) {
        let ns = text as NSString
        guard s.start >= 0, s.end >= s.start, s.end <= ns.length else { return ("", "") }
        var before = ns.substring(to: s.start)
        var after = ns.substring(from: s.end)
        // The spaces the change carried belong to the sentence around it.
        let leading = s.original.prefix(while: \.isWhitespace)
        let trailing = s.original.reversed().prefix(while: \.isWhitespace)
        before += leading
        after = String(trailing) + after
        if s.original.isEmpty, let r = s.replacement {
            before += r.prefix(while: \.isWhitespace)
            after = String(r.reversed().prefix(while: \.isWhitespace)) + after
        }
        let ends = CharacterSet(charactersIn: ".!?\n")
        if let r = before.rangeOfCharacter(from: ends, options: .backwards) {
            before = String(before[r.upperBound...])
        }
        before = String(before.drop(while: \.isWhitespace))
        if let r = after.rangeOfCharacter(from: ends) {
            after = String(after[..<r.upperBound]).trimmingCharacters(in: .newlines)
        }
        if before.count > limit { before = "…" + before.suffix(limit) }
        if after.count > limit { after = after.prefix(limit) + "…" }
        return (before, after)
    }

    private var toneLine: String? {
        let tones = model.report?.tones ?? []
        guard !tones.isEmpty else { return nil }
        return "Sounds " + tones.map { "\($0.emoji) \($0.label)" }.joined(separator: " · ")
    }

    // MARK: Checking and done

    private var checking: some View {
        VStack(spacing: 14) {
            PulsingDots(color: WritingColors.fix(isDark: isDark))
            Text(model.isReadingMessage ? "Reading your message…" : "Checking your writing…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(foreground.opacity(0.75))
        }
    }

    private var clean: some View {
        VStack(spacing: 6) {
            CheerMark(color: WritingColors.fix(isDark: isDark), foreground: foreground)
                .padding(.bottom, 6)
            Text(model.report == nil ? "Nothing to check yet" : "Looking good!")
                .font(.system(size: 18, weight: .bold))
            Text(model.report == nil
                ? "Write a sentence, then tap the check."
                : "No more suggestions. Checked on this iPhone.")
                .font(.system(size: 13))
                .foregroundStyle(foreground.opacity(0.65))
                .multilineTextAlignment(.center)
            if let toneLine {
                Text(toneLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(foreground.opacity(0.5))
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: More

    private var morePage: some View {
        VStack(spacing: 0) {
            if let current, current.kind == "spelling", !current.shownOriginal.contains(where: \.isWhitespace) {
                moreRow("Add “\(current.shownOriginal)” to dictionary", symbol: "book.closed") { model.onAddWord?(current) }
            }
            if model.acceptAllCount >= 2 {
                moreRow("Accept all \(model.acceptAllCount) sure fixes", symbol: "checkmark.circle") { model.onAcceptAll?() }
            }
            moreRow(model.isReadingMessage ? "Reading…" : "Check the whole message", symbol: "text.viewfinder") {
                model.onCheckWholeMessage?()
            }
            moreRow("Open in vocaphone", symbol: "arrow.up.forward.app") { model.onOpenApp?() }
        }
        .padding(.vertical, 6)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func moreRow(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            showsMore = false
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                    .foregroundStyle(WritingColors.fix(isDark: isDark))
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private var actions: some View {
        let reachable = current.map { model.report?.canApply($0) ?? $0.isActionable } ?? false
        let canAccept = current?.isActionable == true && reachable && !showsMore && !model.isRunning
        let canDismiss = current != nil && !showsMore && !model.isRunning
        return HStack(spacing: 10) {
            Button {
                if let current { model.onApply?(current) }
            } label: {
                Text("Accept")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(WritingColors.onFix(isDark: isDark))
                    .padding(.horizontal, 22)
                    .frame(height: 42)
                    .background(Capsule().fill(WritingColors.fix(isDark: isDark)))
            }
            .disabled(!canAccept)
            .opacity(canAccept ? 1 : 0.35)
            Button {
                if let current { model.onDismiss?(current) }
            } label: {
                Text("Dismiss")
                    .font(.system(size: 16, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .background(Capsule().fill(foreground.opacity(isDark ? 0.14 : 0.08)))
            }
            .disabled(!canDismiss)
            .opacity(canDismiss ? 1 : 0.35)
            Spacer(minLength: 0)
            Button {
                showsMore.toggle()
            } label: {
                Image(systemName: showsMore ? "xmark" : "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(foreground.opacity(isDark ? 0.14 : 0.08)))
                    .contentShape(Circle())
            }
            .accessibilityLabel(showsMore ? "Back to suggestions" : "More")
        }
        .buttonStyle(WritingPressStyle())
    }
}

/// Three dots that rise in turn: checking.
private struct PulsingDots: View {
    let color: Color
    @State private var on = false

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                    .scaleEffect(on ? 1 : 0.55)
                    .opacity(on ? 1 : 0.4)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.16), value: on)
            }
        }
        .onAppear { on = true }
        .accessibilityHidden(true)
    }
}

/// A seal with a tick and a few sparkles around it: nothing left to fix.
private struct CheerMark: View {
    let color: Color
    let foreground: Color
    @State private var shown = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.14))
                .frame(width: 64, height: 64)
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(color)
                .scaleEffect(shown ? 1 : 0.6)
            Image(systemName: "sparkle")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(foreground.opacity(0.55))
                .offset(x: -42, y: -18)
                .opacity(shown ? 1 : 0)
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .offset(x: 40, y: -26)
                .opacity(shown ? 1 : 0)
            Image(systemName: "sparkle")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(foreground.opacity(0.45))
                .offset(x: 36, y: 22)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.6)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}

extension WritingSuggestion {
    /// Stable on screen: the same change at the same place.
    var identity: String { "\(kind):\(start):\(end):\(replacement ?? "")" }
}
