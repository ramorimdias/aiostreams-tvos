#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol AIOWindowRemote <NSObject>
/** True to take the remote now; false lets UIKit have it, as for a keyboard. */
- (BOOL)takesRemote;
- (void)remotePress:(UIPress *)press;
- (void)remoteTouches:(NSSet<UITouch *> *)touches;
@end

/**
 * Takes the Siri Remote's presses and swipes before UIKit does, so the web
 * view can stay first responder (and its page focused) without seeing them.
 */
@interface AIOWindow : UIWindow
@property (nonatomic, weak, nullable) id<AIOWindowRemote> remote;
@end

NS_ASSUME_NONNULL_END
