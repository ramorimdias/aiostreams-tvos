#import <UIKit/UIKit.h>

#import "AIOPlayerEngine.h"

NS_ASSUME_NONNULL_BEGIN

/** AetherEngine as one of the app's players: the Swift player in AIOAether, driven like the others. */
@interface AIOAetherEngine : NSObject <AIOPlayerEngine>

- (instancetype)initWithHost:(UIView *)host;
- (instancetype)init NS_UNAVAILABLE;

/** The engine's version, for the page's about screen. */
+ (NSString *)version;

@end

NS_ASSUME_NONNULL_END
