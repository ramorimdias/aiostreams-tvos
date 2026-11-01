#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A WKWebView created at runtime. tvOS ships WebKit but its SDK leaves it out,
 * so every call goes through the Objective-C runtime. Fine for a sideloaded
 * app; the App Store would refuse it.
 */
@interface AIOWebView : UIView

/** False when this tvOS has no WebKit to load. */
@property (nonatomic, readonly) BOOL available;
/** A message the page posted to `aiostreamsNative`, parsed from JSON. */
@property (nonatomic, copy, nullable) void (^onMessage)(NSDictionary *message);
@property (nonatomic, copy, nullable) void (^onLoadFailed)(NSString *error);
@property (nonatomic, copy, nullable) void (^onLoadFinished)(void);

- (instancetype)initWithFrame:(CGRect)frame documentStartScript:(NSString *)script NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)loadURL:(NSURL *)url;
- (void)reload;
- (void)evaluateJavaScript:(NSString *)script;
/** Makes the page focused and active, which `:focus` and `:focus-visible` need. */
- (void)focusPage;

@end

NS_ASSUME_NONNULL_END
