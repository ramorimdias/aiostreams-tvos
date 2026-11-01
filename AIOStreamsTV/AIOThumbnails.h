#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * The seek bar's pictures: a second mpv, with no screen, opens the same file
 * and seeks to the keyframe at or before each position asked for, writing it
 * out as a small JPEG that goes to the page as a data URL. Answers the page's
 * `player-thumbnail` asks (packages/web/src/lib/hosts/shell/player.ts).
 */
@interface AIOThumbnails : NSObject

/** Sends a `player-thumbnail` answer to the page, on the main thread. */
@property (nonatomic, copy) void (^send)(NSDictionary *message);

/** `positionMs` nil only opens the file, ahead of the first ask. */
- (void)want:(NSString *)url headers:(nullable NSDictionary *)headers positionMs:(nullable NSNumber *)positionMs;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
