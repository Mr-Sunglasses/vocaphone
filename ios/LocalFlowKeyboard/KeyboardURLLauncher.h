#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Opens a URL through the responder chain that owns the keyboard extension.
///
/// `NSExtensionContext.open` rejects containing-app URLs for custom keyboard
/// extensions on recent iOS releases. A user-initiated keyboard action can
/// instead ask the owning UIApplication or UIScene responder to open the URL.
FOUNDATION_EXPORT BOOL LFOpenURLFromResponderChain(
    UIResponder *responder,
    NSURL *url
);

NS_ASSUME_NONNULL_END
