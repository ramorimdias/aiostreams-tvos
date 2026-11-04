#import "RootViewController.h"

#import <Network/Network.h>
#import <objc/message.h>


#import "AIOAetherEngine.h"
#import "AIOMPVPlayer.h"
#import "AIONowPlaying.h"
#import "AIOPlayerEngine.h"
#import "AIOVLCPlayer.h"
#import "AIOWebView.h"

static NSString *const kServerKey = @"serverURL";
/** The page's route for the server it was on, which a launch goes back to. */
static NSString *const kRouteKey = @"lastRoute";
/** Waits before trying an unreachable server again, the last repeating. */
static const NSTimeInterval kRetryDelays[] = { 3, 5, 10, 20, 30 };
/** The page's localStorage by origin, which tvOS may not keep for the web view. */
static NSString *const kStorageKey = @"webStorage";
/** tvOS keeps an app's settings to well under a megabyte, so the copy stays small. */
static const NSUInteger kStorageMaxChars = 350000;
static const NSUInteger kStorageMaxValue = 100000;
/** `mpv` (the default) or `vlc`. */
static NSString *const kEngineKey = @"playerEngine";
/** Held this long, Play/Pause opens the app's own menu instead. */
static const NSTimeInterval kMenuHold = 1.0;
static const NSTimeInterval kRepeatDelay = 0.45;
static const NSTimeInterval kRepeatEvery = 0.11;
/** How far a swipe on the touch surface goes for one step. */
static const CGFloat kSwipeStepX = 190;
static const CGFloat kSwipeStepY = 150;

/** The search keyboard, which says when it goes away. */
@interface AIOKeyboardContainer : UISearchContainerViewController
@property (nonatomic, copy, nullable) void (^onClose)(void);
@end

@implementation AIOKeyboardContainer

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed && self.onClose) {
        void (^close)(void) = self.onClose;
        self.onClose = nil;
        close();
    }
}
@end

/**
 * Shows the keyboard as a panel over the right half of the screen, so it sits
 * top right with the page and its results in view to its left. tvOS lays the
 * keyboard out across whatever it is given, so the panel's frame decides.
 */
@interface AIORightPanelPresentation : UIPresentationController
@end

@implementation AIORightPanelPresentation
- (CGRect)frameOfPresentedViewInContainerView {
    CGRect bounds = self.containerView.bounds;
    CGFloat width = floor(bounds.size.width / 2);
    return CGRectMake(CGRectGetMaxX(bounds) - width, 0, width, bounds.size.height);
}

- (BOOL)shouldRemovePresentersView {
    return NO;
}

- (void)containerViewWillLayoutSubviews {
    [super containerViewWillLayoutSubviews];
    self.presentedView.frame = self.frameOfPresentedViewInContainerView;
}
@end

@interface AIORightPanel : NSObject <UIViewControllerTransitioningDelegate>
@end

@implementation AIORightPanel
- (UIPresentationController *)presentationControllerForPresentedViewController:(UIViewController *)presented
                                                      presentingViewController:(UIViewController *)presenting
                                                          sourceViewController:(UIViewController *)source {
    return [[AIORightPanelPresentation alloc] initWithPresentedViewController:presented presentingViewController:presenting];
}
@end

@interface RootViewController () <UISearchResultsUpdating, UISearchBarDelegate>
/** Kept while the keyboard shows: a transitioning delegate isn't retained by what it presents. */
@property (nonatomic, strong, nullable) AIORightPanel *rightPanel;
@property (nonatomic, strong) AIONowPlaying *nowPlaying;
/** The text on the open search keyboard, which goes into the page as it changes. */
@property (nonatomic, copy, nullable) NSString *typed;
@property (nonatomic, strong) UIView *videoView;
@property (nonatomic, strong) AIOWebView *web;
/** The player chosen in the menu. */
@property (nonatomic, strong) id<AIOPlayerEngine> player;
/** VLC, standing in for mpv on a file mpv couldn't play, until the next one. */
@property (nonatomic, strong, nullable) id<AIOPlayerEngine> fallback;
/** The one the page's player messages go to, and whose reports reach the page. */
@property (nonatomic, weak, nullable) id<AIOPlayerEngine> active;
/** What the page last asked of its player, for VLC to start from on a fallback. */
@property (nonatomic, copy, nullable) NSDictionary *lastLoad;
@property (nonatomic, strong) NSMutableDictionary *lastSet;
@property (nonatomic, copy, nullable) NSDictionary *lastStyle;
@property (nonatomic, copy, nullable) NSDictionary *lastSettings;
@property (nonatomic, copy, nullable) NSDictionary *lastSkips;
@property (nonatomic) double lastPositionMs;
@property (nonatomic) BOOL fellBack;
@property (nonatomic, strong) UILabel *status;
/** The logo and a spinner while the page loads. */
@property (nonatomic, strong) UIView *splash;

/** The page has said hello, so it takes Back. */
@property (nonatomic) BOOL connected;
@property (nonatomic) BOOL pageFullscreen;
/** A video is open and not paused, which keeps the screensaver off. */
@property (nonatomic) BOOL videoOpen;
@property (nonatomic) BOOL videoPaused;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *webStorage;

@property (nonatomic, strong, nullable) NSTimer *repeat;
@property (nonatomic, copy, nullable) NSString *repeating;
@property (nonatomic, strong, nullable) NSTimer *menuHold;
@property (nonatomic) BOOL menuOpened;
@property (nonatomic) CGPoint swipeAnchor;

// Reaching the server.
@property (nonatomic) NSUInteger retries;
@property (nonatomic, strong, nullable) NSTimer *retryTimer;
@property (nonatomic) BOOL loadFailed;
@property (nonatomic, strong, nullable) nw_path_monitor_t pathMonitor;
/** The first load goes back to the route the page was on last time. */
@property (nonatomic) BOOL restoredRoute;

// `aiostreams://` links, held until the page says it listens.
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingLinks;
@property (nonatomic) BOOL linksReady;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    [self loadWebStorage];

    self.videoView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.videoView.backgroundColor = UIColor.blackColor;
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.videoView.userInteractionEnabled = NO;
    [self.view addSubview:self.videoView];

    self.web = [[AIOWebView alloc] initWithFrame:self.view.bounds documentStartScript:[self bridgeScript]];
    self.web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.web];

    self.status = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 160, 160)];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.status.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.status.font = [UIFont systemFontOfSize:36 weight:UIFontWeightMedium];
    self.status.textAlignment = NSTextAlignmentCenter;
    self.status.numberOfLines = 0;
    [self.view addSubview:self.status];
    [self buildSplash];

    [self makePlayer];
    __weak typeof(self) weakSelf = self;
    self.nowPlaying = [AIONowPlaying new];
    self.nowPlaying.send = ^(NSDictionary *message) {
        [weakSelf sendToPage:message];
    };
    self.web.onMessage = ^(NSDictionary *message) {
        [weakSelf receive:message];
    };
    self.web.onLoadFinished = ^{
        [weakSelf loadSucceeded];
        weakSelf.status.hidden = YES;
        [weakSelf.web focusPage];
    };
    self.web.onProcessEnded = ^{
        // Most often memory; the page loads again where it was.
        [weakSelf flashStatus:@"The page ran out of memory and reloaded."];
    };
    self.web.onLoadFailed = ^(NSString *error) {
        weakSelf.connected = NO;
        [weakSelf loadFailedWith:error];
    };
    self.pendingLinks = [NSMutableArray array];
    [self watchNetwork];

    if (!self.web.available) {
        [self showStatus:@"This version of tvOS has no web engine the app can use."];
        return;
    }
    [self loadServer];
}

/**
 * Cancels tvOS's safe area for the whole screen: the page lays out edge to
 * edge and keeps its own margins, as on Android TV.
 */
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    UIEdgeInsets safe = self.view.safeAreaInsets;
    UIEdgeInsets added = self.additionalSafeAreaInsets;
    UIEdgeInsets system = UIEdgeInsetsMake(safe.top - added.top, safe.left - added.left,
                                           safe.bottom - added.bottom, safe.right - added.right);
    UIEdgeInsets cancel = UIEdgeInsetsMake(-system.top, -system.left, -system.bottom, -system.right);
    if (!UIEdgeInsetsEqualToEdgeInsets(added, cancel)) self.additionalSafeAreaInsets = cancel;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (![self serverURL]) {
        [self askForServer];
    }
    [self.web focusPage];
}

- (void)showStatus:(NSString *)text {
    [self hideSplash];
    self.status.text = text;
    self.status.hidden = NO;
}

- (void)buildSplash {
    UIView *splash = [[UIView alloc] initWithFrame:self.view.bounds];
    splash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    splash.backgroundColor = [UIColor colorWithRed:7 / 255.0 green:7 / 255.0 blue:9 / 255.0 alpha:1];
    splash.userInteractionEnabled = NO;
    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"SplashLogo"]];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spinner.color = [UIColor colorWithWhite:1 alpha:0.7];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [splash addSubview:logo];
    [splash addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [logo.centerXAnchor constraintEqualToAnchor:splash.centerXAnchor],
        [logo.centerYAnchor constraintEqualToAnchor:splash.centerYAnchor constant:-40],
        [logo.widthAnchor constraintEqualToConstant:240],
        [logo.heightAnchor constraintEqualToConstant:240],
        [spinner.centerXAnchor constraintEqualToAnchor:splash.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:logo.bottomAnchor constant:60],
    ]];
    [self.view addSubview:splash];
    self.splash = splash;
}

- (void)showSplash {
    self.status.hidden = YES;
    self.splash.alpha = 1;
    self.splash.hidden = NO;
}

- (void)hideSplash {
    if (self.splash.hidden) return;
    [UIView animateWithDuration:0.3 animations:^{
        self.splash.alpha = 0;
    } completion:^(BOOL finished) {
        if (finished) self.splash.hidden = YES;
    }];
}

/** A notice that clears itself. */
- (void)flashStatus:(NSString *)text {
    [self showStatus:text];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if ([self.status.text isEqualToString:text]) self.status.hidden = YES;
    });
}

#pragma mark - The page's storage

- (void)loadWebStorage {
    self.webStorage = [NSMutableDictionary dictionary];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kStorageKey];
    for (NSString *origin in saved) {
        NSDictionary *items = saved[origin];
        if (![items isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *copy = [NSMutableDictionary dictionary];
        for (NSString *key in items) {
            if ([items[key] isKindOfClass:NSString.class]) copy[key] = items[key];
        }
        self.webStorage[origin] = copy;
    }
}

- (NSUInteger)webStorageSize {
    NSUInteger size = 0;
    for (NSString *origin in self.webStorage) {
        NSDictionary *items = self.webStorage[origin];
        for (NSString *key in items) size += key.length + [items[key] length];
    }
    return size;
}

- (void)storageChanged:(NSDictionary *)message {
    NSString *origin = [message[@"origin"] isKindOfClass:NSString.class] ? message[@"origin"] : nil;
    if (!origin.length) return;
    NSMutableDictionary *items = self.webStorage[origin];
    if (!items) self.webStorage[origin] = items = [NSMutableDictionary dictionary];
    if ([message[@"clear"] boolValue]) {
        [items removeAllObjects];
    } else {
        NSString *key = [message[@"key"] isKindOfClass:NSString.class] ? message[@"key"] : nil;
        if (!key) return;
        id value = message[@"value"];
        [items removeObjectForKey:key];
        if ([value isKindOfClass:NSString.class] && [value length] <= kStorageMaxValue &&
            self.webStorageSize + key.length + [value length] <= kStorageMaxChars) {
            items[key] = value;
        }
    }
    // Saved once a burst of changes settles.
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveWebStorage) object:nil];
    [self performSelector:@selector(saveWebStorage) withObject:nil afterDelay:1.0];
}

- (void)saveWebStorage {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveWebStorage) object:nil];
    [NSUserDefaults.standardUserDefaults setObject:self.webStorage forKey:kStorageKey];
}

#pragma mark - Server

- (nullable NSURL *)serverURL {
    // Asked for on first launch and kept on the device; nothing is built in.
    return [self normalized:[NSUserDefaults.standardUserDefaults stringForKey:kServerKey]];
}

/** Takes the address as copied from the browser, with or without `/web/`. */
- (nullable NSURL *)normalized:(nullable NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return nil;
    if (![trimmed containsString:@"://"]) trimmed = [@"https://" stringByAppendingString:trimmed];
    NSURL *url = [NSURL URLWithString:trimmed];
    if (!url.host) return nil;
    if ([url.path containsString:@"/jellyfin/"] && ![url.path containsString:@"/web"]) {
        NSString *base = [trimmed hasSuffix:@"/"] ? trimmed : [trimmed stringByAppendingString:@"/"];
        url = [NSURL URLWithString:[base stringByAppendingString:@"web/"]];
    }
    return url;
}

- (void)loadServer {
    NSURL *url = [self serverURL];
    [self.retryTimer invalidate];
    self.retryTimer = nil;
    if (!url) {
        [self showStatus:@"No AIOStreams address yet.\n\nHold Play/Pause to enter it."];
        return;
    }
    self.connected = NO;
    self.linksReady = NO;
    [self showSplash];
    [self.web loadURL:[self withSavedRoute:url]];
}

#pragma mark - Where the page was

/** The address with the route the page was last on, on the first load of a launch. */
- (NSURL *)withSavedRoute:(NSURL *)server {
    if (self.restoredRoute) return server;
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kRouteKey];
    NSString *hash = [saved[@"hash"] isKindOfClass:NSString.class] ? saved[@"hash"] : nil;
    if (![saved[@"server"] isEqual:server.absoluteString] || ![hash hasPrefix:@"#/"]) return server;
    // A link waiting to open goes where it says instead.
    if (self.pendingLinks.count) return server;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:server resolvingAgainstBaseURL:NO];
    parts.fragment = [hash substringFromIndex:1];
    return parts.URL ?: server;
}

/** Saved as the page moves; the player and trailers are left out, as they'd start playing. */
- (void)routeChanged:(NSString *)hash {
    NSString *server = [self serverURL].absoluteString;
    if (!server || ![hash isKindOfClass:NSString.class]) return;
    if ([hash hasPrefix:@"#/play"]) return;
    [NSUserDefaults.standardUserDefaults setObject:@{ @"server": server, @"hash": hash } forKey:kRouteKey];
}

#pragma mark - Reaching the server

- (void)loadSucceeded {
    [self hideSplash];
    self.restoredRoute = YES;
    self.loadFailed = NO;
    self.retries = 0;
    [self.retryTimer invalidate];
    self.retryTimer = nil;
}

/** Tries again by itself, sooner at first, and at once when the network comes back. */
- (void)loadFailedWith:(NSString *)error {
    self.loadFailed = YES;
    NSUInteger count = sizeof(kRetryDelays) / sizeof(kRetryDelays[0]);
    NSTimeInterval delay = kRetryDelays[MIN(self.retries, count - 1)];
    self.retries++;
    [self showStatus:[NSString stringWithFormat:
        @"Couldn't reach AIOStreams.\n%@\n\nTrying again in %.0f seconds. Hold Play/Pause for options.", error, delay]];
    [self.retryTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        [weakSelf loadServer];
    }];
}

- (void)watchNetwork {
    nw_path_monitor_t monitor = nw_path_monitor_create();
    __weak typeof(self) weakSelf = self;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (nw_path_get_status(path) != nw_path_status_satisfied) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.loadFailed) [weakSelf loadServer];
        });
    });
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_start(monitor);
    self.pathMonitor = monitor;
}

#pragma mark - Links

- (void)openLink:(NSURL *)url {
    [self.pendingLinks addObject:url.absoluteString];
    [self sendLinks];
}

- (void)sendLinks {
    if (!self.linksReady) return;
    for (NSString *link in self.pendingLinks) [self sendToPage:@{ @"type": @"link", @"url": link }];
    [self.pendingLinks removeAllObjects];
}

- (void)askForServer {
    if (self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"AIOStreams address"
                         message:@"Your instance's web app address, e.g. https://aio.example.com/jellyfin/…/web/"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [self serverURL].absoluteString;
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = weakAlert.textFields.firstObject.text;
        if ([self normalized:text]) {
            [NSUserDefaults.standardUserDefaults setObject:text forKey:kServerKey];
            [self loadServer];
        }
        [self.web focusPage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self.web focusPage];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAppMenu {
    if (self.presentedViewController) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"AIOStreams TV"
                                                                  message:[self serverURL].host
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Reload" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self loadServer];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Change address" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self askForServer];
        });
    }]];
    NSString *player = [NSString stringWithFormat:@"Player: %@", [self playerTitle:self.engineName]];
    [menu addAction:[UIAlertAction actionWithTitle:player style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self choosePlayer];
        });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self.web focusPage];
    }]];
    [self presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Player

/** mpv, vlc or aether. */
- (NSString *)engineName {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:kEngineKey];
    return [@[ @"vlc", @"aether" ] containsObject:name] ? name : @"mpv";
}

- (BOOL)usesVLC {
    return [self.engineName isEqualToString:@"vlc"];
}

- (NSString *)playerTitle:(NSString *)name {
    if ([name isEqualToString:@"vlc"]) return @"VLC";
    if ([name isEqualToString:@"aether"]) return @"AetherEngine";
    return @"mpv";
}

- (void)choosePlayer {
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:@"Player"
                         message:@"AetherEngine keeps Dolby Vision and Atmos; mpv plays the most files; VLC is the fallback for both."
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in @[ @"mpv", @"aether", @"vlc" ]) {
        BOOL current = [name isEqualToString:self.engineName];
        NSString *title = current ? [[self playerTitle:name] stringByAppendingString:@" ✓"] : [self playerTitle:name];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (current) {
                [self.web focusPage];
                return;
            }
            [self switchPlayerTo:name];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self.web focusPage];
    }]];
    [self presentViewController:menu animated:YES completion:nil];
}

- (id<AIOPlayerEngine>)makeVLC {
    UIView *view = [[UIView alloc] initWithFrame:self.videoView.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = UIColor.blackColor;
    view.userInteractionEnabled = NO;
    [self.videoView addSubview:view];
    return [[AIOVLCPlayer alloc] initWithVideoView:view];
}

/** Reports reach the page only from the player it is using. */
- (void)connect:(id<AIOPlayerEngine>)engine {
    __weak typeof(self) weakSelf = self;
    __weak id<AIOPlayerEngine> weakEngine = engine;
    engine.send = ^(NSDictionary *message) {
        [weakSelf engine:weakEngine sent:message];
    };
}

/** The chosen player, in a fresh view beneath the page. */
- (void)makePlayer {
    [self.fallback shutdown];
    self.fallback = nil;
    [self.player shutdown];
    NSString *name = self.engineName;
    if ([name isEqualToString:@"vlc"]) {
        self.player = [self makeVLC];
    } else if ([name isEqualToString:@"aether"]) {
        self.player = [[AIOAetherEngine alloc] initWithHost:self.videoView];
    } else {
        self.player = [[AIOMPVPlayer alloc] initWithHost:self.videoView];
    }
    [self connect:self.player];
    self.active = self.player;
    if (!self.lastSet) self.lastSet = [NSMutableDictionary dictionary];
}

/** What the page asks of its player, kept to start VLC from, and sent to the one in use. */
- (BOOL)routeToPlayer:(NSString *)type message:(NSDictionary *)message {
    if (![type hasPrefix:@"player-"] && ![type isEqualToString:@"subtitle-file"]) return NO;
    if ([type isEqualToString:@"player-load"]) {
        // Each file starts on the chosen player again.
        [self useChosenPlayer];
        self.lastLoad = message;
        self.lastPositionMs = [message[@"startMs"] isKindOfClass:NSNumber.class] ? [message[@"startMs"] doubleValue] : 0;
        self.fellBack = NO;
    } else if ([type isEqualToString:@"player-set"]) {
        // Track ids differ between the players, so those stay out.
        for (NSString *key in @[ @"paused", @"volume", @"muted", @"speed", @"subtitleDelayMs" ]) {
            if (message[key]) self.lastSet[key] = message[key];
        }
    } else if ([type isEqualToString:@"player-style"]) {
        self.lastStyle = message;
    } else if ([type isEqualToString:@"player-settings"]) {
        self.lastSettings = message;
    } else if ([type isEqualToString:@"player-skips"]) {
        self.lastSkips = message;
    }
    [self.active handle:type message:message];
    if ([type isEqualToString:@"player-stop"]) {
        self.lastLoad = nil;
        [self useChosenPlayer];
    }
    return YES;
}

- (void)useChosenPlayer {
    if (self.active == self.player) return;
    [self.active handle:@"player-stop" message:@{ @"type": @"player-stop" }];
    self.active = self.player;
}

- (void)engine:(id<AIOPlayerEngine>)engine sent:(NSDictionary *)message {
    if (!engine || engine != self.active) return;
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"player-state"] && [message[@"positionMs"] isKindOfClass:NSNumber.class]) {
        self.lastPositionMs = [message[@"positionMs"] doubleValue];
    }
    // mpv or AetherEngine couldn't play the file: VLC tries it, unless the link itself refused.
    BOOL failed = [type isEqualToString:@"player-ended"] && [message[@"reason"] isEqual:@"error"];
    BOOL linkRefused = message[@"status"] != nil;
    if (failed && !linkRefused && !self.fellBack && self.lastLoad && ![engine isKindOfClass:AIOVLCPlayer.class]) {
        [self fallBackToVLC];
        return;
    }
    [self sendToPage:message];
}

- (void)fallBackToVLC {
    self.fellBack = YES;
    if (!self.fallback) {
        self.fallback = [self makeVLC];
        [self connect:self.fallback];
    }
    [self.player handle:@"player-stop" message:@{ @"type": @"player-stop" }];
    self.active = self.fallback;
    [self flashStatus:[NSString stringWithFormat:@"%@ couldn't play this; trying VLC.", [self playerTitle:self.engineName]]];
    for (NSDictionary *message in @[ self.lastSettings ?: @{}, self.lastStyle ?: @{}, self.lastSkips ?: @{} ]) {
        if ([message[@"type"] isKindOfClass:NSString.class]) [self.fallback handle:message[@"type"] message:message];
    }
    NSMutableDictionary *set = [self.lastSet mutableCopy];
    set[@"type"] = @"player-set";
    [self.fallback handle:@"player-set" message:set];
    NSMutableDictionary *load = [self.lastLoad mutableCopy];
    if (self.lastPositionMs > 0) load[@"startMs"] = @(self.lastPositionMs);
    [self.fallback handle:@"player-load" message:load];
}

- (void)switchPlayerTo:(NSString *)name {
    [NSUserDefaults.standardUserDefaults setObject:name forKey:kEngineKey];
    [self makePlayer];
    // The page's player started on the other one; reloading starts it afresh.
    [self loadServer];
}

#pragma mark - Bridge

- (NSString *)bridgeScript {
    NSString *path = [NSBundle.mainBundle pathForResource:@"bridge" ofType:@"js"];
    NSString *script = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
    NSString *deviceId = UIDevice.currentDevice.identifierForVendor.UUIDString ?: NSUUID.UUID.UUIDString;
    NSDictionary *values = @{
        @"__VERSION__": [NSString stringWithFormat:@"%@-tvos", version],
        @"__DEVICE__": UIDevice.currentDevice.name ?: @"Apple TV",
        @"__DEVICE_ID__": deviceId,
    };
    for (NSString *placeholder in values) {
        script = [script stringByReplacingOccurrencesOfString:placeholder withString:[self jsonString:values[placeholder]]];
    }
    NSData *storage = [NSJSONSerialization dataWithJSONObject:self.webStorage ?: @{} options:0 error:nil];
    NSString *storageJSON = storage ? [[NSString alloc] initWithData:storage encoding:NSUTF8StringEncoding] : @"null";
    return [script stringByReplacingOccurrencesOfString:@"__STORAGE__" withString:storageJSON];
}

- (NSString *)jsonString:(NSString *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"\"\"";
}

/** The screensaver stays off while a video plays, and comes back once it pauses or closes. */
- (void)followPlayback:(NSDictionary *)message {
    NSString *type = message[@"type"];
    if ([type isEqualToString:@"now-playing"]) {
        id item = message[@"item"];
        [self.nowPlaying setItem:[item isKindOfClass:NSDictionary.class] ? item : nil];
        return;
    }
    if ([type isEqualToString:@"player-state"]) {
        [self.nowPlaying playerState:message];
        if ([message[@"paused"] isKindOfClass:NSNumber.class]) self.videoPaused = [message[@"paused"] boolValue];
        if ([message[@"idle"] isEqual:@YES]) self.videoOpen = NO;
        if ([message[@"idle"] isEqual:@NO]) self.videoOpen = YES;
    } else if ([type isEqualToString:@"player-ended"]) {
        self.videoOpen = NO;
    } else if ([type isEqualToString:@"player-load"]) {
        self.videoOpen = YES;
    } else if ([type isEqualToString:@"player-stop"]) {
        self.videoOpen = NO;
    } else {
        return;
    }
    UIApplication.sharedApplication.idleTimerDisabled = self.videoOpen && !self.videoPaused;
}

- (void)sendToPage:(NSDictionary *)message {
    [self followPlayback:message];
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.__aioReceive&&window.__aioReceive(%@)", json]];
}

- (void)callTV:(NSString *)call {
    [self.web evaluateJavaScript:[NSString stringWithFormat:@"window.__aioTV&&window.__aioTV.%@", call]];
}

- (void)receive:(NSDictionary *)message {
    NSString *type = [message[@"type"] isKindOfClass:NSString.class] ? message[@"type"] : @"";
    [self followPlayback:message];
    if ([self routeToPlayer:type message:message]) return;

    if ([type isEqualToString:@"hello"]) {
        [self hideSplash];
        self.connected = YES;
        self.linksReady = NO;
        self.status.hidden = YES;
        [self.web focusPage];
    } else if ([type isEqualToString:@"app-info"]) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
        [self sendToPage:@{
            @"type": @"app-info", @"app": [version stringByAppendingString:@" (tvOS)"], @"platform": @"android",
            @"mpv": [self.engineName isEqualToString:@"mpv"] ? @"libmpv (MPVKit)" : NSNull.null, @"ffmpeg": NSNull.null,
            @"player": [self.engineName isEqualToString:@"aether"]
                ? [@"AetherEngine " stringByAppendingString:AIOAetherEngine.version]
                : self.usesVLC ? @"VLCKit" : @"mpv",
            @"ac3Encoder": @NO,
        }];
    } else if ([type isEqualToString:@"fullscreen"]) {
        id value = message[@"value"];
        self.pageFullscreen = [value isKindOfClass:NSNumber.class] ? [value boolValue] : !self.pageFullscreen;
        [self sendToPage:@{ @"type": @"fullscreen", @"value": @(self.pageFullscreen) }];
    } else if ([type isEqualToString:@"levels"]) {
        [self sendToPage:@{ @"type": @"levels", @"volume": @1, @"brightness": @1 }];
    } else if ([type isEqualToString:@"crash-report"]) {
        [self sendToPage:@{ @"type": @"crash-report" }];
    } else if ([type isEqualToString:@"update-check"]) {
        // Updates come from rebuilding; the page itself updates with the server.
        [self sendToPage:@{ @"type": @"update-state", @"state": @"off", @"channel": NSNull.null,
                            @"version": NSNull.null, @"error": NSNull.null }];
    } else if ([type isEqualToString:@"youtube-resolve"]) {
        [self sendToPage:@{ @"type": @"youtube-resolved", @"request": message[@"request"] ?: @"", @"url": NSNull.null }];
    } else if ([type isEqualToString:@"diagnostics"]) {
        NSString *text = [NSString stringWithFormat:@"AIOStreams TV %@\ntvOS %@\nServer %@",
                          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
                          UIDevice.currentDevice.systemVersion, [self serverURL].host ?: @"none"];
        [self sendToPage:@{ @"type": @"diagnostics", @"text": text }];
    } else if ([type isEqualToString:@"exit"]) {
        [self leaveApp];
    } else if ([type isEqualToString:@"links-ready"]) {
        self.linksReady = YES;
        [self sendLinks];
    } else if ([type isEqualToString:@"tvos-route"]) {
        [self routeChanged:message[@"hash"]];
    } else if ([type isEqualToString:@"tvos-storage"]) {
        [self storageChanged:message];
    } else if ([type isEqualToString:@"tvos-keyboard"]) {
        [self showKeyboard:message];
    } else if ([type isEqualToString:@"web-error"]) {
        NSLog(@"[page] %@", message[@"message"]);
    }
    // Others (watch-next, keyboard-completions, ...) have nothing on tvOS.
}

/** Back to the Home screen, as Menu on the first page does in other apps. */
- (void)leaveApp {
    [self.active pauseForBackground];
    SEL suspend = NSSelectorFromString(@"suspend");
    UIApplication *app = UIApplication.sharedApplication;
    if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
}

- (void)showKeyboard:(NSDictionary *)message {
    if (self.presentedViewController) return;
    // Plain text goes into the page as it is typed; passwords and PINs keep the confirm box.
    if (![message[@"secure"] boolValue] && ![message[@"numeric"] boolValue]) {
        [self showLiveKeyboard:message];
        return;
    }
    NSString *label = [message[@"label"] isKindOfClass:NSString.class] ? message[@"label"] : @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:label.length ? label : @"Enter text"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [message[@"value"] isKindOfClass:NSString.class] ? message[@"value"] : @"";
        field.secureTextEntry = [message[@"secure"] boolValue];
        if ([message[@"email"] boolValue]) field.keyboardType = UIKeyboardTypeEmailAddress;
        if ([message[@"url"] boolValue]) field.keyboardType = UIKeyboardTypeURL;
        // A PIN gets the digits-only keyboard.
        if ([message[@"numeric"] boolValue]) field.keyboardType = UIKeyboardTypeNumberPad;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = weakAlert.textFields.firstObject.text ?: @"";
        // A PIN is the last thing its form asks for, so Done sends it.
        BOOL submit = [message[@"numeric"] boolValue];
        [self callTV:[NSString stringWithFormat:@"type(%@,%@)", [self jsonString:text], submit ? @"true" : @"false"]];
        [self.web focusPage];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self.web focusPage];
    }]];
    [self presentViewController:alert animated:YES completion:^{
        // Straight to the keyboard rather than the alert's field.
        [weakAlert.textFields.firstObject becomeFirstResponder];
    }];
}

/**
 * tvOS's own search keyboard over the page, each change going straight into
 * the page's field, so its results update while typing. Menu or Done closes it.
 */
- (void)showLiveKeyboard:(NSDictionary *)message {
    NSString *label = [message[@"label"] isKindOfClass:NSString.class] ? message[@"label"] : @"";
    NSString *value = [message[@"value"] isKindOfClass:NSString.class] ? message[@"value"] : @"";
    self.typed = value;

    UIViewController *results = [UIViewController new];
    results.view.backgroundColor = UIColor.clearColor;
    UISearchController *search = [[UISearchController alloc] initWithSearchResultsController:results];
    search.searchResultsUpdater = self;
    search.obscuresBackgroundDuringPresentation = NO;
    search.searchBar.delegate = self;
    search.searchBar.text = value;
    search.searchBar.placeholder = label.length ? label : @"Search";
    search.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    if ([message[@"email"] boolValue]) search.searchBar.keyboardType = UIKeyboardTypeEmailAddress;
    if ([message[@"url"] boolValue]) search.searchBar.keyboardType = UIKeyboardTypeURL;

    AIOKeyboardContainer *container = [[AIOKeyboardContainer alloc] initWithSearchController:search];
    // A panel on the right half, over the page, whose results show to its left.
    self.rightPanel = [AIORightPanel new];
    container.modalPresentationStyle = UIModalPresentationCustom;
    container.transitioningDelegate = self.rightPanel;
    container.view.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.85];
    __weak typeof(self) weakSelf = self;
    container.onClose = ^{
        weakSelf.rightPanel = nil;
        [weakSelf finishTyping];
    };
    [self presentViewController:container animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *text = searchController.searchBar.text ?: @"";
    if ([text isEqualToString:self.typed]) return;
    self.typed = text;
    [self callTV:[NSString stringWithFormat:@"live(%@)", [self jsonString:text]]];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self dismissViewControllerAnimated:YES completion:nil];
}

/** The keyboard closed: the field keeps what was typed, and the remote is back on the page. */
- (void)finishTyping {
    NSString *text = self.typed ?: @"";
    self.typed = nil;
    [self callTV:[NSString stringWithFormat:@"type(%@,false)", [self jsonString:text]]];
    [self.web focusPage];
}

#pragma mark - Remote

- (BOOL)takesRemote {
    return self.presentedViewController == nil;
}

- (nullable NSString *)keyForPress:(UIPressType)type {
    switch (type) {
        case UIPressTypeUpArrow: return @"ArrowUp";
        case UIPressTypeDownArrow: return @"ArrowDown";
        case UIPressTypeLeftArrow: return @"ArrowLeft";
        case UIPressTypeRightArrow: return @"ArrowRight";
        case UIPressTypeSelect: return @"Enter";
        default: return nil;
    }
}

- (void)remotePress:(UIPress *)press {
    BOOL began = press.phase == UIPressPhaseBegan;
    BOOL ended = press.phase == UIPressPhaseEnded || press.phase == UIPressPhaseCancelled;
    if (!began && !ended) return;

    if (press.type == UIPressTypeMenu) {
        if (!began) return;
        if (self.connected) [self sendToPage:@{ @"type": @"back" }];
        else [self leaveApp];
        return;
    }

    if (press.type == UIPressTypePlayPause) {
        if (began) {
            self.menuOpened = NO;
            [self.menuHold invalidate];
            self.menuHold = [NSTimer scheduledTimerWithTimeInterval:kMenuHold repeats:NO block:^(NSTimer *timer) {
                self.menuOpened = YES;
                [self showAppMenu];
            }];
        } else {
            [self.menuHold invalidate];
            self.menuHold = nil;
            if (!self.menuOpened) [self tapKey:@"MediaPlayPause"];
        }
        return;
    }

    NSString *key = [self keyForPress:press.type];
    if (!key) return;
    if (began) {
        [self keyDown:key repeat:NO];
        if (![key isEqualToString:@"Enter"]) [self startRepeating:key];
    } else {
        [self stopRepeating];
        [self keyUp:key];
    }
}

- (void)keyDown:(NSString *)key repeat:(BOOL)repeat {
    [self callTV:[NSString stringWithFormat:@"down(%@,%@)", [self jsonString:key], repeat ? @"true" : @"false"]];
}

- (void)keyUp:(NSString *)key {
    [self callTV:[NSString stringWithFormat:@"up(%@)", [self jsonString:key]]];
}

- (void)tapKey:(NSString *)key {
    [self keyDown:key repeat:NO];
    [self keyUp:key];
}

- (void)startRepeating:(NSString *)key {
    [self stopRepeating];
    self.repeating = key;
    __weak typeof(self) weakSelf = self;
    self.repeat = [NSTimer scheduledTimerWithTimeInterval:kRepeatDelay repeats:NO block:^(NSTimer *first) {
        weakSelf.repeat = [NSTimer scheduledTimerWithTimeInterval:kRepeatEvery repeats:YES block:^(NSTimer *timer) {
            if (weakSelf.repeating) [weakSelf keyDown:weakSelf.repeating repeat:YES];
        }];
    }];
}

- (void)stopRepeating {
    [self.repeat invalidate];
    self.repeat = nil;
    self.repeating = nil;
}

/** Swipes on the touch surface step like the arrows. */
- (void)remoteTouches:(NSSet<UITouch *> *)touches {
    UITouch *touch = touches.anyObject;
    CGPoint at = [touch locationInView:nil];
    switch (touch.phase) {
        case UITouchPhaseBegan:
            self.swipeAnchor = at;
            break;
        case UITouchPhaseMoved: {
            CGFloat dx = at.x - self.swipeAnchor.x;
            CGFloat dy = at.y - self.swipeAnchor.y;
            if (fabs(dx) >= kSwipeStepX && fabs(dx) > fabs(dy)) {
                [self tapKey:dx > 0 ? @"ArrowRight" : @"ArrowLeft"];
                self.swipeAnchor = at;
            } else if (fabs(dy) >= kSwipeStepY && fabs(dy) > fabs(dx)) {
                [self tapKey:dy > 0 ? @"ArrowDown" : @"ArrowUp"];
                self.swipeAnchor = at;
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - App state

- (void)appWillResignActive {
    [self saveWebStorage];
    [self stopRepeating];
    [self.active pauseForBackground];
}

- (void)appDidBecomeActive {
    [self.web focusPage];
}

@end
