#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Opens a URL through the responder chain that owns the keyboard extension.
///
/// `NSExtensionContext.open` rejects containing-app URLs for custom keyboard
/// extensions on recent iOS releases. A user-initiated keyboard action can
/// instead ask the owning UIApplication or UIScene responder to open the URL.
/// `completion` reports whether the host actually opened the URL. The return
/// value only says a responder accepted the request: it used to be the whole
/// answer, which meant a request that quietly went nowhere still looked like a
/// success and the caller had nothing to tell the user.
FOUNDATION_EXPORT BOOL VocaPhoneOpenURLFromResponderChain(
    UIResponder *responder,
    NSURL *url,
    void (^_Nullable completion)(BOOL)
);

NS_ASSUME_NONNULL_END
