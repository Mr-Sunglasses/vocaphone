#import "KeyboardURLLauncher.h"

#import <objc/message.h>

BOOL VocaPhoneOpenURLFromResponderChain(
    UIResponder *responder,
    NSURL *url,
    void (^_Nullable completion)(BOOL)
) {
    SEL modernSelector = NSSelectorFromString(
        @"openURL:options:completionHandler:"
    );

    for (UIResponder *candidate = responder;
         candidate != nil;
         candidate = candidate.nextResponder) {
        if (![candidate respondsToSelector:modernSelector]) {
            continue;
        }

        typedef void (*ModernOpenURLFunction)(
            id,
            SEL,
            NSURL *,
            NSDictionary *,
            void (^ _Nullable)(BOOL)
        );
        ModernOpenURLFunction openURL =
            (ModernOpenURLFunction)(void *)objc_msgSend;
        // UIScene and UIApplication expose the same selector with different
        // option types. UIApplication accepts an NSDictionary, while UIScene
        // expects UISceneOpenExternalURLOptions. Passing a dictionary to the
        // scene variant crashes on iOS 26 when UIKit reads universalLinksOnly.
        // A nil scene-options value is explicitly supported and means the
        // normal (non-universal-link-only) opening behavior.
        id options = [candidate isKindOfClass:[UIScene class]] ? nil : @{};
        openURL(candidate, modernSelector, url, options, completion);
        return YES;
    }

    // Keep the older single-argument selector as a fallback for iOS 17 hosts.
    SEL legacySelector = NSSelectorFromString(@"openURL:");
    for (UIResponder *candidate = responder;
         candidate != nil;
         candidate = candidate.nextResponder) {
        if (![candidate respondsToSelector:legacySelector]) {
            continue;
        }

        typedef BOOL (*LegacyOpenURLFunction)(id, SEL, NSURL *);
        LegacyOpenURLFunction openURL =
            (LegacyOpenURLFunction)(void *)objc_msgSend;
        BOOL opened = openURL(candidate, legacySelector, url);
        if (completion != nil) {
            completion(opened);
        }
        return opened;
    }

    return NO;
}
