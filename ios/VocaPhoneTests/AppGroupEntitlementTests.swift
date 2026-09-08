import Foundation
import Testing

/// The App Group is the only channel the keyboard and the containing app have.
///
/// It is named in three `.entitlements` files, which is what the App Store
/// profile is minted against, and it is what the running code asks for.
/// Nothing in the build makes those agree on its own — a bundle whose
/// entitlement grants one group while the code opens another signs, uploads
/// and installs perfectly, and then cannot reach its own shared container: no
/// session records, no transcript ever leaves the keyboard. Dictation does not
/// degrade, it stops.
///
/// This has happened. A local development group was committed into
/// `AppConfiguration` alongside an unrelated keyboard change and reached main,
/// where the release workflow's own check could not see it — that check greps
/// the entitlements, which were right, and never read the Swift constant.
///
/// The constant is now gone: every bundle carries its group in `Info.plist`,
/// expanded from the same `VOCAPHONE_APP_GROUP` build setting that selects its
/// entitlement file, so the two cannot drift within a built bundle. What is
/// left to check is that the wiring is present in all three targets and that
/// the shipping default has not been replaced by somebody's local one.
struct AppGroupEntitlementTests {
    private static let entitlementPaths = [
        "VocaPhoneApp/VocaPhoneApp.entitlements",
        "VocaPhoneKeyboard/VocaPhoneKeyboard.entitlements",
        "VocaPhoneLiveActivity/VocaPhoneLiveActivity.entitlements",
    ]

    private static let infoPlistPaths = [
        "VocaPhoneApp/Info.plist",
        "VocaPhoneKeyboard/Info.plist",
        "VocaPhoneLiveActivity/Info.plist",
    ]

    /// The tracked entitlement files are the ones a release is signed against,
    /// so they stay literal — the release workflow copies them into the archive
    /// verbatim and would ship an unexpanded `$(…)` as the group name. Local
    /// signing points `CODE_SIGN_ENTITLEMENTS` at generated copies instead.
    @Test(arguments: entitlementPaths)
    func everyTargetShipsTheGroupTheReleaseIsSignedFor(entitlementPath: String) throws {
        let parsed = try Self.plist(at: entitlementPath)
        let groups = parsed?["com.apple.security.application-groups"] as? [String]

        #expect(groups == [AppConfiguration.shippingAppGroupIdentifier])
    }

    /// Without this key a bundle falls back to the shipping group while its
    /// entitlement grants the local one — exactly the invisible split the
    /// incident above produced, reintroduced one target at a time.
    @Test(arguments: infoPlistPaths)
    func everyTargetDeclaresTheGroupItIsEntitledTo(infoPlistPath: String) throws {
        let parsed = try Self.plist(at: infoPlistPath)
        let declared = parsed?[AppConfiguration.appGroupInfoDictionaryKey] as? String

        #expect(declared == "$(VOCAPHONE_APP_GROUP)")
    }

    /// The identifiers a release is actually signed for, pinned as literals so
    /// that a local signing setup committed into `project.yml` fails here
    /// rather than at a user's cursor.
    @Test func theProjectStillDefaultsToTheShippingIdentity() throws {
        let spec = try String(
            contentsOf: Self.iosDirectory.appendingPathComponent("project.yml"),
            encoding: .utf8
        )

        #expect(spec.contains("$(LOCAL_APP_GROUP:default=group.com.vocahq)"))
        #expect(spec.contains("$(LOCAL_APP_BUNDLE_ID:default=com.vocahq.vocaphone)"))
        #expect(spec.contains("$(LOCAL_DEVELOPMENT_TEAM:default=92962VK378)"))
    }

    @Test func theSharedContainerIsTheOneRegisteredToTheShippingTeam() {
        #expect(AppConfiguration.shippingAppGroupIdentifier == "group.com.vocahq")
    }

    /// A bundle that declares nothing is the unit-test host, and a bundle whose
    /// variable never expanded names no container at all. Both fall back rather
    /// than handing `UserDefaults(suiteName:)` a string it will refuse.
    @Test(arguments: [nil, "", "$(VOCAPHONE_APP_GROUP)"] as [String?])
    func anUnusableDeclarationFallsBackToTheShippingGroup(declared: String?) {
        #expect(
            AppConfiguration.declaredAppGroupIdentifier(in: declared)
                == AppConfiguration.shippingAppGroupIdentifier
        )
    }

    @Test func aRenamedGroupIsUsedAsDeclared() {
        #expect(
            AppConfiguration.declaredAppGroupIdentifier(in: "group.dev.example.vocaphone")
                == "group.dev.example.vocaphone"
        )
    }

    private static func plist(at path: String) throws -> [String: Any]? {
        let url = iosDirectory.appendingPathComponent(path)
        return try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url),
            format: nil
        ) as? [String: Any]
    }

    private static var iosDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
