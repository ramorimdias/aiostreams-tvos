#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The page's `player-*` messages played through VLC, and VLC's reports sent
 * back in the shapes the page reads (packages/web/src/lib/hosts/shell/player.ts).
 */
@interface AIOPlayer : NSObject

/** Where the video is drawn, beneath the page. */
@property (nonatomic, strong, readonly) UIView *videoView;
/** Sends a message to the page. */
@property (nonatomic, copy) void (^send)(NSDictionary *message);

- (instancetype)initWithVideoView:(UIView *)videoView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/** False for a message that isn't the player's. */
- (BOOL)handle:(NSString *)type message:(NSDictionary *)message;
/** Pauses for the app going to the background. */
- (void)pauseForBackground;

@end

NS_ASSUME_NONNULL_END
