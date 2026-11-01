#import <UIKit/UIKit.h>

#import "AIOPlayerEngine.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * The page's player on libmpv, as AIOStreams' desktop and Android apps play
 * (packages/desktop/core/src/playback.rs maps the same messages). Video goes
 * to an AVSampleBufferDisplayLayer through vo_avfoundation, which hands HDR
 * through to the TV; the app asks tvOS to switch the TV's mode to match.
 */
@interface AIOMPVPlayer : NSObject <AIOPlayerEngine>

@property (nonatomic, copy) void (^send)(NSDictionary *message);

/** Adds its video view to `host`, filling it. */
- (instancetype)initWithHost:(UIView *)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
