import UIKit

/// What happened to every finger that touched the keyboard, written where a
/// Mac can read it.
///
/// Letters go missing at speed and only at speed, which is the one condition a
/// person cannot hold still long enough to look at. Three different things
/// would look identical from the outside — the touch never reaching the grid,
/// the grid resolving no key under it, and the key resolving but never
/// committing — and each has a different fix. This tells them apart.
///
/// Debug only, and off unless something turns it on: the flush is a file write
/// on the main thread, which is not a thing a keyboard should be doing while
/// somebody types on it.
@MainActor
enum TouchTrace {
    /// Armed for the whole of a debug build, and impossible to arm in a release
    /// one: the fault this exists for only appears at full typing speed, which
    /// is not a state anybody can reach while also reaching for a switch.
    ///
    /// What it records is deliberately not everything. A character key's name is
    /// the character, so ``KeyGridView/traceNamesKeys`` withholds it in a field
    /// that has switched typing intelligence off.
    static var isEnabled = false

    private static var lines: [String] = []
    private static var origin: CFTimeInterval = 0
    private static var flushTimer: Timer?

    /// A short, readable name for a `UITouch`.
    ///
    /// Deliberately the object's own address: UIKit pools `UITouch` instances
    /// and hands the same object to the next finger, and a tracked entry that
    /// outlived its sequence would then be matched by `===` against a touch it
    /// has nothing to do with. If that is what is happening, the same name
    /// appearing twice without an end between is what shows it.
    static func name(_ touch: UITouch) -> String {
        let address = UInt(bitPattern: ObjectIdentifier(touch).hashValue)
        return String(format: "t%03X", address & 0xFFF)
    }

    static func note(_ text: @autoclosure () -> String) {
#if DEBUG
        guard isEnabled else { return }
        if origin == 0 { origin = CACurrentMediaTime() }
        lines.append(
            String(format: "%9.1f  %@", (CACurrentMediaTime() - origin) * 1000, text())
        )
        if lines.count >= 400 { flush() }
#endif
    }

    /// Marks a new run in the file, so a trace pulled after several attempts
    /// still says which keystrokes belong together.
    static func beginSession(_ label: String) {
#if DEBUG
        guard isEnabled else { return }
        origin = CACurrentMediaTime()
        scheduleFlush()
        lines.append("\n===== \(label) — \(Date()) =====")
        scheduleFlush()
#endif
    }

    /// One repeating timer, not one per line.
    ///
    /// This used to invalidate and re-schedule on every note. A keystroke emits
    /// about fifteen of them, so typing churned fifteen runloop timers per
    /// letter — an instrument that got heavier the longer it was left running,
    /// which is precisely the shape of the fault it was armed to find.
    private static func scheduleFlush() {
        guard flushTimer == nil else { return }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { flushIfIdle() }
        }
    }

    private static func flushIfIdle() {
        guard !lines.isEmpty else { return }
        flush(keepingTimer: true)
    }

    static func flush() { flush(keepingTimer: false) }

    /// The writes happen here, off the main thread.
    ///
    /// This is the mistake an instrument must not make. Appending the buffer to
    /// the App Group container took a `FileHandle` open, a seek to the end of a
    /// file that grows to a megabyte, a write and a close — and it did all of it
    /// on the main thread, once a second, for as long as somebody was typing.
    /// Measured on device, that was frames of 48 to 195 ms arriving about once a
    /// second while the keyboard's own code was doing nothing at all: the
    /// instrument was producing the fault it was armed to find.
    private static let writer = DispatchQueue(label: "vocaphone.touch-trace")

    private static func flush(keepingTimer: Bool) {
        if !keepingTimer {
            flushTimer?.invalidate()
            flushTimer = nil
        }
        guard !lines.isEmpty, let url = fileURL else { return }
        let payload = lines.joined(separator: "\n") + "\n"
        lines.removeAll(keepingCapacity: true)
        guard let data = payload.data(using: .utf8) else { return }
        writer.async { append(data, to: url) }
    }

    nonisolated private static func append(_ data: Data, to url: URL) {
        // Every appearance of the keyboard appends, and it appears dozens of
        // times a day. A trace that has outgrown the fault it was armed for is
        // worth less than the one about to be recorded.
        if let size = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int,
            size > 1_000_000
        {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    static let fileName = "touch-trace.txt"

    private static var fileURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConfiguration.appGroupIdentifier
        )?.appendingPathComponent(fileName)
    }

    /// Starts the next run from an empty file, so what comes back is only the
    /// typing that was done to reproduce the fault.
    static func reset() {
        lines.removeAll(keepingCapacity: true)
        origin = 0
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
