#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * What plays, for tvOS: the iPhone's remote and Control Center show its
 * title, artwork and progress, and their buttons and Siri ("pause", "skip
 * ahead 30 seconds") come back to the page as the `media-key` messages it
 * already handles for the Android app.
 */
@interface AIONowPlaying : NSObject

/** Sends a `media-key` message to the page. */
@property (nonatomic, copy) void (^send)(NSDictionary *message);

/** The page's `now-playing` item, or nil when the player closes. */
- (void)setItem:(nullable NSDictionary *)item;
/** The player's `player-state` reports, for position, length and pause. */
- (void)playerState:(NSDictionary *)state;

@end

NS_ASSUME_NONNULL_END
