#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A player the page drives through its `player-*` messages
 * (packages/web/src/lib/hosts/shell/player.ts), drawn beneath the page.
 */
@protocol AIOPlayerEngine <NSObject>

/** Sends a message to the page; set before any message is handled. */
@property (nonatomic, copy) void (^send)(NSDictionary *message);

/** False for a message that isn't the player's. */
- (BOOL)handle:(NSString *)type message:(NSDictionary *)message;
/** Pauses for the app going to the background. */
- (void)pauseForBackground;
/** Stops at once, sound first, and lets go of the video view, for another player to take over. */
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
