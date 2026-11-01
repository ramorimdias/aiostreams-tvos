#import "AIOWindow.h"

@implementation AIOWindow

- (void)sendEvent:(UIEvent *)event {
    id<AIOWindowRemote> remote = self.remote;
    if (!remote || ![remote takesRemote]) {
        [super sendEvent:event];
        return;
    }
    if (event.type == UIEventTypePresses) {
        for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
            [remote remotePress:press];
        }
        return;
    }
    if (event.type == UIEventTypeTouches) {
        NSMutableSet<UITouch *> *remoteTouches = [NSMutableSet set];
        for (UITouch *touch in event.allTouches) {
            if (touch.type == UITouchTypeIndirect) [remoteTouches addObject:touch];
        }
        if (remoteTouches.count) {
            [remote remoteTouches:remoteTouches];
            return;
        }
    }
    [super sendEvent:event];
}

@end
