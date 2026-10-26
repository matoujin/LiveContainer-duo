#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Keys that force SplashBoard / SpringBoard into fixed-size Classic Mode (e.g. 375×667).
FOUNDATION_EXPORT NSArray<NSString *> *LCLegacyLaunchInfoKeys(void);

/// Returns YES when the Info.plist still contains legacy launch-image / storyboard / full-screen keys.
BOOL LCInfoPlistNeedsModernLaunchScreen(NSDictionary *infoPlist);

/// Strip legacy launch keys and inject modern empty `UILaunchScreen` so iOS 27.1+ Duo
/// does not lock the window into phone-compat letterboxing.
/// Mutates `infoPlist` in place. Returns YES if any change was made.
BOOL LCModernizeInfoPlistForDuo(NSMutableDictionary *infoPlist);

/// Apply modern launch-screen keys onto a read-only Info.plist snapshot (for probes / hooks).
NSDictionary *LCModernizedInfoPlistSnapshot(NSDictionary *infoPlist);

NS_ASSUME_NONNULL_END
