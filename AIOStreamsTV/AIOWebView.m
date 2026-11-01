#import "AIOWebView.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kHandlerName = @"aiostreamsNative";

static void AIOLoadWebKit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (NSClassFromString(@"WKWebView") != Nil) return;
        NSArray<NSString *> *paths = @[
            @"/System/Library/Frameworks/WebKit.framework/WebKit",
            @"/System/Library/PrivateFrameworks/WebKit.framework/WebKit",
            @"/System/Library/StagedFrameworks/Safari/WebKit.framework/WebKit",
        ];
        for (NSString *path in paths) {
            if (dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL) != NULL && NSClassFromString(@"WKWebView") != Nil) break;
        }
    });
}

static id AIOSend0(id target, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, sel);
}

static void AIOSendObject(id target, NSString *selectorName, id value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(target, sel, value);
}

static void AIOSendBool(id target, NSString *selectorName, BOOL value) {
    SEL sel = NSSelectorFromString(selectorName);
    if (target == nil || ![target respondsToSelector:sel]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(target, sel, value);
}

#pragma mark - Delegate

/**
 * Takes WebKit's delegate calls for the view. The user content controller keeps
 * it strongly, so it holds the view weakly.
 */
@interface AIOWebKitDelegate : NSObject
@property (nonatomic, weak) AIOWebView *owner;
@end

@interface AIOWebView ()
@property (nonatomic, strong, nullable) id webView;
@property (nonatomic, strong) AIOWebKitDelegate *delegate;
@property (nonatomic, strong, nullable) NSURL *lastURL;
- (void)receiveBody:(id)body;
- (void)navigationFinished;
- (void)navigationFailed:(NSError *)error;
- (void)contentProcessEnded;
@end

@implementation AIOWebKitDelegate

+ (void)initialize {
    if (self != [AIOWebKitDelegate class]) return;
    AIOLoadWebKit();
    // WebKit checks some delegates for these at runtime.
    for (NSString *name in @[@"WKScriptMessageHandler", @"WKNavigationDelegate", @"WKUIDelegate"]) {
        Protocol *protocol = objc_getProtocol(name.UTF8String);
        if (protocol) class_addProtocol(self, protocol);
    }
}

- (void)userContentController:(id)controller didReceiveScriptMessage:(id)message {
    [self.owner receiveBody:AIOSend0(message, @"body")];
}

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.owner navigationFinished];
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self.owner navigationFailed:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    [self.owner contentProcessEnded];
}

@end

#pragma mark - View

@implementation AIOWebView

- (instancetype)initWithFrame:(CGRect)frame documentStartScript:(NSString *)script {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    _delegate = [AIOWebKitDelegate new];
    _delegate.owner = self;
    [self buildWithScript:script];
    return self;
}

- (BOOL)available {
    return self.webView != nil;
}

- (void)buildWithScript:(NSString *)script {
    AIOLoadWebKit();
    Class configurationClass = NSClassFromString(@"WKWebViewConfiguration");
    Class webViewClass = NSClassFromString(@"WKWebView");
    Class controllerClass = NSClassFromString(@"WKUserContentController");
    Class scriptClass = NSClassFromString(@"WKUserScript");
    if (!configurationClass || !webViewClass || !controllerClass || !scriptClass) return;

    id configuration = [configurationClass new];
    id controller = [controllerClass new];

    // At document start, in the main frame only, before the page's own scripts.
    SEL scriptInit = NSSelectorFromString(@"initWithSource:injectionTime:forMainFrameOnly:");
    if ([scriptClass instancesRespondToSelector:scriptInit]) {
        id userScript = ((id (*)(id, SEL))objc_msgSend)(scriptClass, @selector(alloc));
        userScript = ((id (*)(id, SEL, id, NSInteger, BOOL))objc_msgSend)(userScript, scriptInit, script, 0, YES);
        AIOSendObject(controller, @"addUserScript:", userScript);
    }

    SEL addHandler = NSSelectorFromString(@"addScriptMessageHandler:name:");
    if ([controller respondsToSelector:addHandler]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(controller, addHandler, self.delegate, kHandlerName);
    }
    AIOSendObject(configuration, @"setUserContentController:", controller);
    AIOSendBool(configuration, @"setAllowsInlineMediaPlayback:", YES);
    AIOSendBool(configuration, @"setMediaPlaybackRequiresUserAction:", NO);
    SEL mediaTypes = NSSelectorFromString(@"setMediaTypesRequiringUserActionForPlayback:");
    if ([configuration respondsToSelector:mediaTypes]) {
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(configuration, mediaTypes, 0);
    }

    id webView = ((id (*)(id, SEL))objc_msgSend)(webViewClass, @selector(alloc));
    SEL init = NSSelectorFromString(@"initWithFrame:configuration:");
    webView = ((id (*)(id, SEL, CGRect, id))objc_msgSend)(webView, init, self.bounds, configuration);
    if (!webView) return;

    UIView *view = (UIView *)webView;
    view.frame = self.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // The player is drawn beneath, so the page must be see-through.
    view.opaque = NO;
    view.backgroundColor = UIColor.clearColor;
    UIScrollView *scrollView = AIOSend0(webView, @"scrollView");
    scrollView.backgroundColor = UIColor.clearColor;
    scrollView.opaque = NO;
    // The page lays itself out to the screen and scrolls itself.
    scrollView.scrollEnabled = NO;
    if (@available(tvOS 11.0, *)) {
        scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    AIOSendObject(webView, @"setUnderPageBackgroundColor:", UIColor.clearColor);
    AIOSendObject(webView, @"setNavigationDelegate:", self.delegate);
    AIOSendObject(webView, @"setUIDelegate:", self.delegate);
    // Lets Safari on a Mac inspect the page, for debugging.
    AIOSendBool(webView, @"setInspectable:", YES);
    AIOSendObject(webView, @"setApplicationNameForUserAgent:", @"AIOStreamsTV");

    [self addSubview:view];
    self.webView = webView;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    ((UIView *)self.webView).frame = self.bounds;
}

- (void)loadURL:(NSURL *)url {
    self.lastURL = url;
    AIOSendObject(self.webView, @"loadRequest:", [NSURLRequest requestWithURL:url]);
}

- (void)reload {
    if (self.lastURL) [self loadURL:self.lastURL];
}

- (void)evaluateJavaScript:(NSString *)script {
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (!self.webView || ![self.webView respondsToSelector:sel]) return;
    ((void (*)(id, SEL, id, id))objc_msgSend)(self.webView, sel, script, nil);
}

- (void)focusPage {
    UIView *view = (UIView *)self.webView;
    if (!view) return;
    // WebKit counts the page focused while its content view is first responder.
    UIView *content = [self contentViewIn:view];
    if (![content becomeFirstResponder]) [view becomeFirstResponder];
}

- (nullable UIView *)contentViewIn:(UIView *)view {
    if ([NSStringFromClass(view.class) hasPrefix:@"WKContentView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = [self contentViewIn:subview];
        if (found) return found;
    }
    return nil;
}

#pragma mark Delegate calls

- (void)receiveBody:(id)body {
    if (![body isKindOfClass:NSString.class] || !self.onMessage) return;
    NSData *data = [(NSString *)body dataUsingEncoding:NSUTF8StringEncoding];
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([json isKindOfClass:NSDictionary.class]) self.onMessage(json);
}

- (void)navigationFinished {
    if (self.onLoadFinished) self.onLoadFinished();
}

- (void)navigationFailed:(NSError *)error {
    // A navigation the page replaced with another is not a failure.
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) return;
    if (self.onLoadFailed) self.onLoadFailed(error.localizedDescription ?: @"The page could not load.");
}

- (void)contentProcessEnded {
    [self reload];
}

@end
