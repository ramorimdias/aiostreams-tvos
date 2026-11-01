#import <UIKit/UIKit.h>

#import "AIOPlayerEngine.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * The page's `player-*` messages played through VLC, and VLC's reports sent
 * back in the shapes the page reads (packages/web/src/lib/hosts/shell/player.ts).
 * The fallback player; mpv is the default.
 */
@interface AIOVLCPlayer : NSObject <AIOPlayerEngine>

/** Where the video is drawn, beneath the page. */
@property (nonatomic, strong, readonly) UIView *videoView;
@property (nonatomic, copy) void (^send)(NSDictionary *message);

- (instancetype)initWithVideoView:(UIView *)videoView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
