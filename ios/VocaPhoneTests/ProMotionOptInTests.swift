import Foundation
import Testing

/// ProMotion is opt-in, per bundle, and silent when it is missing.
///
/// `CADisableMinimumFrameDurationOnPhone` is what lets Core Animation and
/// `CADisplayLink` run above 60Hz on an iPhone. Without it iOS clamps the whole
/// process and returns no error, so `SwipeTrailView` asking for
/// `CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)` was answered at
/// 60 on a 120Hz panel and nothing said so.
///
/// The keyboard runs in its own process, so its own `Info.plist` has to carry
/// the key — inheriting the containing app's would not have helped it. That is
/// the part easiest to drop, which is why it is pinned here rather than left to
/// be noticed on a device.
struct ProMotionOptInTests {
    @Test(arguments: ["VocaPhoneApp", "VocaPhoneKeyboard"])
    func everyBundleThatDrawsOptsIntoTheFullFrameRate(target: String) throws {
        let plist = Self.iosDirectory
            .appendingPathComponent(target)
            .appendingPathComponent("Info.plist")
        let contents = try Data(contentsOf: plist)
        let parsed = try PropertyListSerialization.propertyList(
            from: contents,
            format: nil
        ) as? [String: Any]

        #expect(parsed?["CADisableMinimumFrameDurationOnPhone"] as? Bool == true)
    }

    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
