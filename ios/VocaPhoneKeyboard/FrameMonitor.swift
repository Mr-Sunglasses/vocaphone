import Foundation
import os
import QuartzCore

/// How long the keyboard's frames actually take.
///
/// Everything else measured here is main-thread CPU: how long the code for a
/// keystroke runs. That is not what a person means by a keyboard feeling laggy.
/// A key press is a picture, and the picture arrives when a frame is composited
/// — which can be several frames after the code that asked for it, if the work
/// between them is on the render server rather than in this process. A backdrop
/// blur is exactly that kind of work, and a keyboard extension shares its render
/// server with the app it is typing into.
///
/// So this measures the other half: the interval between frames, and how many of
/// them missed. A press that costs one millisecond of code and three frames of
/// compositing looks, to the finger, like a press that took 50 ms.
@MainActor
enum FrameMonitor {
    private static var link: CADisplayLink?
    private static var observer: CFRunLoopObserver?
    /// What the current runloop turn was asked to redraw, and when.
    private static var pending: (label: String, at: CFTimeInterval)?

    /// Records that something set state the view layer will have to act on.
    ///
    /// The cost of a SwiftUI update is not where the code that causes it runs.
    /// Setting a published property is free; evaluating the bodies it
    /// invalidated, laying them out and committing the transaction happens at
    /// the end of the runloop turn, after every measurement this keyboard could
    /// take from the inside. Timed from the outside instead: from the state
    /// change to the moment the runloop goes back to sleep.
    static func noteStateChange(_ label: String) {
        guard isEnabled else { return }
        guard pending == nil else { return }
        pending = (label, CACurrentMediaTime())
    }

    private static var isEnabled: Bool { link != nil }

    private static func installObserver() {
        guard observer == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(
            nil,
            CFRunLoopActivity.beforeWaiting.rawValue,
            true,
            0
        ) { _, _ in
            MainActor.assumeIsolated {
                guard let work = pending else { return }
                pending = nil
                let elapsed = (CACurrentMediaTime() - work.at) * 1000
                guard elapsed > 4 else { return }
                TouchTrace.note(String(format: "    commit %@ %.1fms", work.label, elapsed))
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }
    private static var lastTimestamp: CFTimeInterval = 0
    private static var expected: CFTimeInterval = 1.0 / 60
    /// Frame intervals since the last report, in milliseconds.
    private static var intervals: [Double] = []
    private static var reportedAt: CFTimeInterval = 0

    static func start() {
        guard link == nil, TouchTrace.isEnabled else { return }
        let link = CADisplayLink(target: Proxy.shared, selector: #selector(Proxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        installObserver()
    }

    static func stop() {
        link?.invalidate()
        link = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        pending = nil
        report()
    }

    fileprivate static func tick(_ link: CADisplayLink) {
        expected = link.targetTimestamp - link.timestamp
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else {
            reportedAt = link.timestamp
            return
        }
        let interval = (link.timestamp - lastTimestamp) * 1000
        intervals.append(interval)
        // A frame that took more than twice its budget is one a finger can see.
        if interval > expected * 2000 {
            TouchTrace.note(String(format: "    FRAME %.1fms (budget %.1f)", interval, expected * 1000))
        }
        if link.timestamp - reportedAt >= 2 {
            reportedAt = link.timestamp
            report()
        }
    }

    private static func report() {
        guard !intervals.isEmpty else { return }
        let sorted = intervals.sorted()
        let budget = expected * 1000
        let missed = intervals.filter { $0 > budget * 1.5 }.count
        // Alongside the frames, because an extension that is running out of
        // room does not fail — it is throttled, and the only symptom is that
        // everything gets slower the longer it is used.
        let availableMB = Double(os_proc_available_memory()) / 1_048_576
        TouchTrace.note(
            String(
                format: "frames n=%d budget=%.1fms p50=%.1f p90=%.1f max=%.1f missed=%d "
                    + "free=%.1fMB",
                intervals.count,
                budget,
                sorted[sorted.count / 2],
                sorted[Int(Double(sorted.count) * 0.9)],
                sorted[sorted.count - 1],
                missed,
                availableMB
            )
        )
        intervals.removeAll(keepingCapacity: true)
    }

    /// `CADisplayLink` keeps its target alive and wants an object; the state
    /// above is the enum's.
    @MainActor
    private final class Proxy: NSObject {
        static let shared = Proxy()
        @objc func tick(_ link: CADisplayLink) {
            FrameMonitor.tick(link)
        }
    }
}
