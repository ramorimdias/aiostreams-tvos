#import "AppDelegate.h"

#import <AVFoundation/AVFoundation.h>

#import "AIOWindow.h"
#import "RootViewController.h"

@interface AppDelegate ()
@property (nonatomic, strong) RootViewController *root;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                            mode:AVAudioSessionModeMoviePlayback
                                         options:0
                                           error:nil];
    [[AVAudioSession sharedInstance] setActive:YES error:nil];

    AIOWindow *window = [[AIOWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.root = [RootViewController new];
    window.rootViewController = self.root;
    window.remote = self.root;
    window.backgroundColor = UIColor.blackColor;
    self.window = window;
    [window makeKeyAndVisible];
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    [self.root appWillResignActive];
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    [self.root appDidBecomeActive];
}

@end
