#import "AIOShared.h"

/** The app's bundle id as built. */
static NSString *const kBaseId = @"io.github.aiostreamstv.app";
/**
 * The App Group as declared in both entitlements. Not group.<bundle id>: Apple
 * refused that name, with the team id added, as "not available".
 */
static NSString *const kGroup = @"group.io.github.aiostreamstv.shared";
static NSString *const kWatchNextFile = @"watch-next.json";

@implementation AIOShared

/** The app's id as installed, which a signing tool may have suffixed, from the extension too. */
+ (NSString *)appBundleId {
    NSBundle *bundle = NSBundle.mainBundle;
    if ([bundle.bundlePath.pathExtension isEqualToString:@"appex"]) {
        NSString *app = bundle.bundlePath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        bundle = [NSBundle bundleWithPath:app] ?: bundle;
    }
    return bundle.bundleIdentifier ?: kBaseId;
}

/** Nil without the group, as when a signing tool couldn't register it: nothing is shared, and the app runs as usual. */
+ (NSURL *)container {
    static NSURL *found;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *app = [self appBundleId];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        NSString *prefix = [kBaseId stringByAppendingString:@"."];
        if ([app hasPrefix:prefix]) {
            // Impactor (ATVLoadly) registers the group as <group>.<team>, the team being the id's suffix.
            NSString *team = [app substringFromIndex:prefix.length];
            [names addObject:[NSString stringWithFormat:@"%@.%@", kGroup, team]];
        }
        [names addObject:kGroup];
        for (NSString *name in names) {
            NSURL *url = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:name];
            if (url) {
                found = url;
                break;
            }
        }
    });
    return found;
}

+ (void)saveWatchNext:(NSArray<NSDictionary *> *)items {
    NSURL *container = [self container];
    if (!container) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
    [data writeToURL:[container URLByAppendingPathComponent:kWatchNextFile] atomically:YES];
}

+ (NSArray<NSDictionary *> *)watchNext {
    NSURL *container = [self container];
    if (!container) return @[];
    NSData *data = [NSData dataWithContentsOfURL:[container URLByAppendingPathComponent:kWatchNextFile]];
    id items = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![items isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id item in items) {
        if ([item isKindOfClass:NSDictionary.class]) [valid addObject:item];
    }
    return valid;
}

@end
