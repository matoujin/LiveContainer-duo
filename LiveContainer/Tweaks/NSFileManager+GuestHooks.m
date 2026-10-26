@import Foundation;
#import "utils.h"
#import "LCSharedUtils.h"
#import "Tweaks.h"
#include "../../litehook/src/litehook.h"
#include "../LCMachOUtils.h"
#include <dlfcn.h>
#include <stdatomic.h>

BOOL isolateAppGroup = NO;
void* webKitHeader = 0;

// While appGroupID / bootstrap probe system containers, skip guest remapping and
// call through to the real NSFileManager implementation (post-swizzle: hook_*).
static atomic_int gLCAppGroupProbePassThrough = 0;

void LCAppGroupProbePassThroughBegin(void) {
    atomic_fetch_add_explicit(&gLCAppGroupProbePassThrough, 1, memory_order_acq_rel);
}

void LCAppGroupProbePassThroughEnd(void) {
    atomic_fetch_sub_explicit(&gLCAppGroupProbePassThrough, 1, memory_order_acq_rel);
}

static BOOL LCAppGroupProbePassThroughActive(void) {
    return atomic_load_explicit(&gLCAppGroupProbePassThrough, memory_order_acquire) > 0;
}

static NSURL *LCSafeFileURLWithPath(NSString *path) {
    if (path.length == 0) {
        return nil;
    }
    return [NSURL fileURLWithPath:path];
}

static NSString *LCFallbackAppGroupRoot(void) {
    const char *lcHome = getenv("LC_HOME_PATH");
    if (!lcHome || lcHome[0] == '\0') {
        lcHome = getenv("HOME");
    }
    if (!lcHome || lcHome[0] == '\0') {
        return nil;
    }
    return [NSString stringWithFormat:@"%s/Documents/Data/AppGroup", lcHome];
}

void NSFMGuestHooksInit(void) {
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    isolateAppGroup = [infoDict[@"isolateAppGroup"] boolValue];
    swizzle(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:), @selector(hook_containerURLForSecurityApplicationGroupIdentifier:));
    
    /// To fix https://github.com/LiveContainer/LiveContainer/issues/888 i.e. WebKit being unable to save cookie issue, we have to hook -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] so that WebKit still creates bookmark for the symlinked lc's cookies folder, which is resolved by the kernel to the app's cookies folder
    /// see https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxExtensionCocoa.mm#L159 and https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/UIProcess/WebsiteData/WebsiteDataStore.cpp#L2225
    /// WebKit::WebsiteDataStore::createHandleFromResolvedPathIfPossible requires WebKit::WebsiteDataStore::resolvedCookieStorageDirectory to return a non-empty path to create a bookmark, which is possible when WebKit::resolveAndCreateReadWriteDirectoryForSandboxExtension is non-empty. However if -[NSFileManager createDirectoryAtPath:withIntermediateDirectories:attributes:error:] returns false for cookies folder since it's a symlink, resolveAndCreateReadWriteDirectoryForSandboxExtension will return empty value. So that com.apple.WebKit.Networking process does not receive the bookmark and is unable to access the cookies folder.
    /// So the hook is simple, we just check if the path is lc's cookies folder and return YES. For performance, we check if caller's address falls in WebKit+0 to WebKit+32M
    /// If you have a better solution, please let us know.
    void* dscPtr = getDSCAddr();
    webKitHeader = getCachedSymbol(@"webKitHeader", dscPtr);
    
    if(!webKitHeader) {
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_GLOBAL);
        webKitHeader = LCGetLoadedImageHeader(0, "/System/Library/Frameworks/WebKit.framework/WebKit");
        saveCachedSymbol(@"webKitHeader", dscPtr, webKitHeader-dscPtr);
    }
    
    swizzle(NSFileManager.class, @selector(createDirectoryAtPath:withIntermediateDirectories:attributes:error:), @selector(hook_createDirectoryAtPath:withIntermediateDirectories:attributes:error:));
    
}

// NSFileManager simulate app group
@implementation NSFileManager(LiveContainerHooks)

- (nullable NSURL *)hook_containerURLForSecurityApplicationGroupIdentifier:(NSString *)groupIdentifier {
    // Probe pass-through: after swizzle, this selector holds the ORIGINAL IMP.
    if (LCAppGroupProbePassThroughActive()) {
        return [self hook_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }

    if (groupIdentifier.length == 0) {
        return nil;
    }

    // Never call +[LCSharedUtils appGroupID] here — that method probes via
    // containerURL and would re-enter this hook / dispatch_once.
    // Use the cached ID written after resolution (may be nil before bootstrap).
    NSString *cachedGroupID = LCSharedUtilsCachedAppGroupID();
    if (cachedGroupID.length > 0 &&
        ![cachedGroupID isEqualToString:@"Unknown"] &&
        [groupIdentifier isEqualToString:cachedGroupID]) {
        NSString *path = NSUserDefaults.lcAppGroupPath;
        NSURL *url = LCSafeFileURLWithPath(path);
        if (url) {
            return url;
        }
        // System / bootstrap path missing — fall through to sandbox remap below.
    }

    NSString *pathString = nil;
    if (isolateAppGroup) {
        const char *home = getenv("HOME");
        if (home && home[0] != '\0') {
            pathString = [NSString stringWithFormat:@"%s/LCAppGroup/%@", home, groupIdentifier];
        }
    } else if (NSUserDefaults.lcAppGroupPath.length > 0) {
        pathString = [NSString stringWithFormat:@"%@/LiveContainer/Data/AppGroup/%@", NSUserDefaults.lcAppGroupPath, groupIdentifier];
    } else {
        NSString *root = LCFallbackAppGroupRoot();
        if (root.length > 0) {
            pathString = [root stringByAppendingPathComponent:groupIdentifier];
        }
    }

    NSURL *result = LCSafeFileURLWithPath(pathString);
    if (!result) {
        // Last resort: original system implementation (may return nil; never crash).
        return [self hook_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
    }

    [NSFileManager.defaultManager createDirectoryAtURL:[result URLByAppendingPathComponent:@"Library/Caches"] withIntermediateDirectories:YES attributes:nil error:nil];
    return result;
}

- (bool)hook_createDirectoryAtPath:(NSString *)path withIntermediateDirectories:(BOOL)createIntermediates attributes:(NSDictionary<NSFileAttributeKey,id> *)attributes error:(NSError *__autoreleasing  _Nullable *)error {
    bool ans = [self hook_createDirectoryAtPath:path withIntermediateDirectories:createIntermediates attributes:attributes error:error];
    void* callerAddr = __builtin_return_address(0);
    if(callerAddr > webKitHeader && callerAddr < (webKitHeader + (32 << 20) )) {
        if([path hasSuffix:@"Library/Cookies"]) {
            // symlink Cookies folder
            // https://github.com/apple-oss-distributions/WebKit/blob/0c8cf3581e5c01d970ea411128007c9325ba2d48/Source/WebKit/Shared/Cocoa/SandboxUtilities.mm#L56
            // unfortunately we cannot hook sandbox_container_path_for_pid, so we symlink Cookies folder in normal mode
            // see NSFileManager+GuestHooks.m for more info
            NSFileManager *fm = NSFileManager.defaultManager;
            const char *lcHomePath = getenv(NSUserDefaults.isLiveProcess ? "LP_HOME_PATH" : "LC_HOME_PATH");
            if (!lcHomePath || lcHomePath[0] == '\0') {
                return ans;
            }
            NSString *libraryPath = [@(lcHomePath) stringByAppendingPathComponent:@"Library"];
            NSString *cookies2Path = [libraryPath stringByAppendingPathComponent:@"Cookies2"];
            NSString *cookiesPath = [libraryPath stringByAppendingPathComponent:@"Cookies"];
            const char *home = getenv("HOME");
            if (!home || home[0] == '\0') {
                return ans;
            }
            NSString* appCookiesPath = [@(home) stringByAppendingPathComponent:@"Library/Cookies"];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:cookies2Path isDirectory:&isDir]) {
                if([fm fileExistsAtPath:cookiesPath isDirectory:&isDir]) {
                    [fm moveItemAtPath:cookiesPath toPath:cookies2Path error:nil];
                } else {
                    [fm createDirectoryAtPath:cookies2Path withIntermediateDirectories:YES attributes:nil error:nil];
                }
            }
            remove(cookiesPath.UTF8String);
            symlink(appCookiesPath.UTF8String, cookiesPath.UTF8String);
            return YES;
        }
    }
    return ans;
}

@end
