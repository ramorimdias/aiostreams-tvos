#import <UIKit/UIKit.h>

#import "AIOWindow.h"

NS_ASSUME_NONNULL_BEGIN

/** The video beneath, the page over it, and the bridge between them. */
@interface RootViewController : UIViewController <AIOWindowRemote>
- (void)appWillResignActive;
- (void)appDidBecomeActive;
@end

NS_ASSUME_NONNULL_END
