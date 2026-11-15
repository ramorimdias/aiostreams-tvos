#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * What the app saw, for finding out what went wrong on the device: a log of
 * the remote, the page's messages and the players, and, while it's turned on
 * in the app menu, a small web server on the local network that hands it out
 * with the page's own log and the app's system log. Addresses in it are cut
 * to their host and file name, as debrid links and the server's address carry
 * tokens.
 */
@interface AIODiagnostics : NSObject

@property (class, nonatomic, readonly) AIODiagnostics *shared;

/** Adds a line, from `source` (remote, page, player, app...). Any thread. */
- (void)log:(NSString *)source text:(NSString *)text;

/** The server is on; kept across launches. */
@property (nonatomic, readonly) BOOL serving;
- (void)setServing:(BOOL)serving;
/** Where the server is, e.g. `http://192.168.1.216:8642/`, while it's on. */
@property (nonatomic, readonly, nullable) NSString *address;

/** The page's log after line `since`, as text; called on the main thread. */
@property (nonatomic, copy, nullable) void (^pageLog)(NSUInteger since, void (^done)(NSString *text));
/** The app's state as text; called on the main thread. */
@property (nonatomic, copy, nullable) NSString *(^state)(void);
/** Empties the page's log; called on the main thread. */
@property (nonatomic, copy, nullable) void (^clearPage)(void);

/** The page's log as a reload began, which the reload would otherwise lose; served at /page-before. */
- (void)keepPreviousPage:(NSString *)text;

/** Debrid links and server addresses cut to their host and file name. */
+ (NSString *)redact:(NSString *)text;

@end

/** A line in the diagnostics log. */
void AIOLog(NSString *source, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

NS_ASSUME_NONNULL_END
