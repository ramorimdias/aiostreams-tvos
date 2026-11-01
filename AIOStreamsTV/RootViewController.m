#import "RootViewController.h"

#import <objc/message.h>

#import "AIOPlayer.h"
#import "AIOWebView.h"

static NSString *const kServerKey = @"serverURL";
/** Held this long, Play/Pause opens the app's own menu instead. */
static const NSTimeInterval kMenuHold = 1.0;
static const NSTimeInterval kRepeatDelay = 0.45;
static const NSTimeInterval kRepeatEvery = 0.11;
/** How far a swipe on the touch surface goes for one step. */
static const CGFloat kSwipeStepX = 190;
static const CGFloat kSwipeStepY = 150;

@interface RootViewController ()
@property (nonatomic, strong) UIView *videoView;
@property (nonatomic, strong) AIOWebView *web;
@property (nonatomic, strong) AIOPlayer *player;
@property (nonatomic, strong) UILabel *status;

/** The page has said hello, so it takes Back. */
@property (nonatomic) BOOL connected;
@property (nonatomic) BOOL pageFullscreen;

@property (nonatomic, strong, nullable) NSTimer *repeat;
@property (nonatomic, copy, nullable) NSString *repeating;
@property (nonatomic, strong, nullable) NSTimer *menuHold;
@property (nonatomic) BOOL menuOpened;
@property (nonatomic) CGPoint swipeAnchor;
@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

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

    self.player = [[AIOPlayer alloc] initWithVideoView:self.videoView];
    __weak typeof(self) weakSelf = self;
    self.player.send = ^(NSDictionary *message) {
        [weakSelf sendToPage:message];
    };
    self.web.onMessage = ^(NSDictionary *message) {
        [weakSelf receive:message];
    };
    self.web.onLoadFinished = ^{
        weakSelf.status.hidden = YES;
        [weakSelf.web focusPage];
    };
    self.web.onLoadFailed = ^(NSString *error) {
        weakSelf.connected = NO;
        [weakSelf showStatus:[NSString stringWithFormat:@"Couldn't reach AIOStreams.\n%@\n\nHold Play/Pause for options.", error]];
    };

    if (!self.web.available) {
        [self showStatus:@"This version of tvOS has no web engine the app can use."];
        return;
    }
    [self loadServer];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (![self serverURL]) {
        [self askForServer];
    }
    [self.web focusPage];
}

- (void)showStatus:(NSString *)text {
    self.status.text = text;
    self.status.hidden = NO;
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
    if (!url) {
        [self showStatus:@"No AIOStreams address yet.\n\nHold Play/Pause to enter it."];
        return;
    }
    self.connected = NO;
    [self showStatus:@"Loading AIOStreams…"];
    [self.web loadURL:url];
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
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self.web focusPage];
    }]];
    [self presentViewController:menu animated:YES completion:nil];
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
    return script;
}

- (NSString *)jsonString:(NSString *)value {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingFragmentsAllowed error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"\"\"";
}

- (void)sendToPage:(NSDictionary *)message {
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
    if ([self.player handle:type message:message]) return;

    if ([type isEqualToString:@"hello"]) {
        self.connected = YES;
        self.status.hidden = YES;
        [self.web focusPage];
    } else if ([type isEqualToString:@"app-info"]) {
        NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0";
        [self sendToPage:@{
            @"type": @"app-info", @"app": [version stringByAppendingString:@" (tvOS)"], @"platform": @"android",
            @"mpv": NSNull.null, @"ffmpeg": NSNull.null, @"player": @"VLCKit", @"ac3Encoder": @NO,
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
    } else if ([type isEqualToString:@"tvos-keyboard"]) {
        [self showKeyboard:message];
    } else if ([type isEqualToString:@"web-error"]) {
        NSLog(@"[page] %@", message[@"message"]);
    }
    // Others (watch-next, now-playing, keyboard-completions, ...) have nothing on tvOS.
}

/** Back to the Home screen, as Menu on the first page does in other apps. */
- (void)leaveApp {
    [self.player pauseForBackground];
    SEL suspend = NSSelectorFromString(@"suspend");
    UIApplication *app = UIApplication.sharedApplication;
    if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
}

- (void)showKeyboard:(NSDictionary *)message {
    if (self.presentedViewController) return;
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
    [self stopRepeating];
    [self.player pauseForBackground];
}

- (void)appDidBecomeActive {
    [self.web focusPage];
}

@end
