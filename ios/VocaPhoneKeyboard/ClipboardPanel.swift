import SwiftUI

/// What the clipboard panel shows, and what its buttons do. The controller
/// loads it from ``ClipboardHistoryStore`` when the panel opens and answers
/// the actions. Its own object so the list redraws without the surface.
final class ClipboardPanelModel: ObservableObject {
    @Published private(set) var clips: [ClipboardClip] = []

    var onInsert: ((ClipboardClip) -> Void)?
    var onTogglePin: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onClearUnpinned: (() -> Void)?

    func show(_ history: ClipboardHistory) {
        guard history.clips != clips else { return }
        clips = history.clips
    }

    var hasUnpinned: Bool { clips.contains { !$0.isPinned } }
}

/// Recent text clips, newest first, in the room the keys leave. Tap one to
/// type it; swipe one away; pin one to keep it past the retention window.
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardPanelModel
    let isDark: Bool
    let foreground: Color

    var body: some View {
        VStack(spacing: 6) {
            if model.clips.isEmpty {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 26, weight: .regular))
                    Text("Nothing copied yet")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Text you copy shows up here. Pinned clips stay until you remove them.")
                        .font(.system(size: 13))
                        .multilineTextAlignment(.center)
                        .opacity(0.7)
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 24)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(model.clips) { clip in
                        row(clip)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2))
                            .listRowSeparator(.hidden)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    model.onDelete?(clip.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    model.onTogglePin?(clip.id)
                                } label: {
                                    Label(clip.isPinned ? "Unpin" : "Pin", systemImage: clip.isPinned ? "pin.slash" : "pin")
                                }
                                .tint(.orange)
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 40)
            }
            if model.hasUnpinned {
                HStack {
                    Spacer()
                    Button("Clear") { model.onClearUnpinned?() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(foreground)
                        .frame(minHeight: 32)
                        .accessibilityHint("Removes every clip that is not pinned")
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ clip: ClipboardClip) -> some View {
        HStack(spacing: 8) {
            Button {
                model.onInsert?(clip)
            } label: {
                Text(Self.preview(clip.text))
                    .font(.system(size: 15))
                    .foregroundStyle(foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clip.text)
            .accessibilityHint("Types this clip")
            Button {
                model.onTogglePin?(clip.id)
            } label: {
                Image(systemName: clip.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(foreground.opacity(clip.isPinned ? 1 : 0.5))
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(clip.isPinned ? "Unpin" : "Pin")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(KeyboardPalette(isDark: isDark).standardKey))
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: clip.isPinned ? "Unpin" : "Pin") { model.onTogglePin?(clip.id) }
        .accessibilityAction(named: "Delete") { model.onDelete?(clip.id) }
    }

    /// One line's worth of the clip: line breaks shown as spaces, so a clip
    /// of several lines still reads as its start.
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
