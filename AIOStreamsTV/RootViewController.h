#import <UIKit/UIKit.h>

#import "AIOWindow.h"

NS_ASSUME_NONNULL_BEGIN

/** The video beneath, the page over it, and the bridge between them. */
@interface RootViewController : UIViewController <AIOWindowRemote>
- (void)appWillResignActive;
/** An `aiostreams://` link the app was opened with, as from the Top Shelf. */
- (void)openLink:(NSURL *)url;
- (void)appDidBecomeActive;
@end

NS_ASSUME_NONNULL_END
