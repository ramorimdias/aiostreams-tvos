#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * What the app and its Top Shelf extension share, through their App Group.
 * Sideloading tools rename the group (Impactor/ATVLoadly add the team id), so
 * both look for it under the names it may have.
 */
@interface AIOShared : NSObject

/** The page's watch-next items (see packages/web/src/components/watch-next.tsx). */
+ (void)saveWatchNext:(NSArray<NSDictionary *> *)items;
+ (NSArray<NSDictionary *> *)watchNext;

/** Where the group's files live, or nil without the group. */
+ (nullable NSURL *)container;

@end

NS_ASSUME_NONNULL_END
