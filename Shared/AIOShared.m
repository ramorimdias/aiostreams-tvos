#import "AIOShared.h"

/** The app's bundle id as built, and its App Group as declared. */
static NSString *const kBaseId = @"io.github.aiostreamstv.app";
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

+ (NSURL *)container {
    static NSURL *found;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *app = [self appBundleId];
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        NSString *prefix = [kBaseId stringByAppendingString:@"."];
        if ([app hasPrefix:prefix]) {
            // Impactor (ATVLoadly) names the group group.<id>.<team>, the team being the id's suffix.
            NSString *team = [app substringFromIndex:prefix.length];
            [names addObject:[NSString stringWithFormat:@"group.%@.%@", kBaseId, team]];
        }
        [names addObject:[@"group." stringByAppendingString:kBaseId]];
        if (![app isEqualToString:kBaseId]) [names addObject:[@"group." stringByAppendingString:app]];
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
