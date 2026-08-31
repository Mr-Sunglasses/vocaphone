import Foundation
import Testing

/// The App Group is the only channel the keyboard and the containing app have.
///
/// It is named twice: in three `.entitlements` files, which is what the App
/// Store profile is minted against, and in `AppConfiguration`, which is what
/// the running code asks for. Nothing in the build makes those agree — an
/// archive whose entitlement grants one group while the code opens another
/// signs, uploads and installs perfectly, and then cannot reach its own shared
/// container: no session records, no transcript ever leaves the keyboard.
/// Dictation does not degrade, it stops.
///
/// This has happened. A local development group was committed into
/// `AppConfiguration` alongside an unrelated keyboard change and reached main,
/// where the release workflow's own check could not see it — that check greps
/// the entitlements, which were right, and never reads the Swift constant.
///
/// So the constant is checked against the files rather than against another
/// copy of itself, and all three targets are checked, because an extension that
/// is missing the group is exactly as broken as a wrong one.
struct AppGroupEntitlementTests {
    @Test(
        arguments: [
            "VocaPhoneApp/VocaPhoneApp.entitlements",
            "VocaPhoneKeyboard/VocaPhoneKeyboard.entitlements",
            "VocaPhoneLiveActivity/VocaPhoneLiveActivity.entitlements",
        ]
    )
    func everyTargetGrantsTheGroupTheCodeOpens(entitlementPath: String) throws {
        let url = Self.iosDirectory.appendingPathComponent(entitlementPath)
        let parsed = try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url),
            format: nil
        ) as? [String: Any]
        let groups = parsed?["com.apple.security.application-groups"] as? [String]

        #expect(groups?.contains(AppConfiguration.appGroupIdentifier) == true)
    }

    /// The identifier a release is actually signed for. Pinned as a literal so
    /// that changing `AppConfiguration` alone — the exact shape of the incident
    /// above — fails here instead of at a user's cursor.
    @Test func theSharedContainerIsTheOneRegisteredToTheShippingTeam() {
        #expect(AppConfiguration.appGroupIdentifier == "group.com.vocahq")
    }

    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
