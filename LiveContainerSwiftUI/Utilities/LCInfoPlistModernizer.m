#import "LCInfoPlistModernizer.h"

NSArray<NSString *> *LCLegacyLaunchInfoKeys(void) {
    return @[
        @"UILaunchImages",
        @"UILaunchImageFile",
        @"UILaunchStoryboardName",
        @"UILaunchStoryboards",
        @"UIRequiresFullScreen",
    ];
}

BOOL LCInfoPlistNeedsModernLaunchScreen(NSDictionary *infoPlist) {
    if (![infoPlist isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    for (NSString *key in LCLegacyLaunchInfoKeys()) {
        if (infoPlist[key] != nil) {
            return YES;
        }
    }
    id launchScreen = infoPlist[@"UILaunchScreen"];
    if (![launchScreen isKindOfClass:NSDictionary.class]) {
        return YES;
    }
    return NO;
}

BOOL LCModernizeInfoPlistForDuo(NSMutableDictionary *infoPlist) {
    if (![infoPlist isKindOfClass:NSMutableDictionary.class]) {
        return NO;
    }
    BOOL changed = NO;
    for (NSString *key in LCLegacyLaunchInfoKeys()) {
        if (infoPlist[key] != nil) {
            [infoPlist removeObjectForKey:key];
            changed = YES;
        }
    }
    id launchScreen = infoPlist[@"UILaunchScreen"];
    if (![launchScreen isKindOfClass:NSDictionary.class]) {
        infoPlist[@"UILaunchScreen"] = @{};
        changed = YES;
    }
    return changed;
}

NSDictionary *LCModernizedInfoPlistSnapshot(NSDictionary *infoPlist) {
    NSMutableDictionary *mutable = infoPlist.mutableCopy ?: [NSMutableDictionary new];
    LCModernizeInfoPlistForDuo(mutable);
    return mutable.copy;
}
