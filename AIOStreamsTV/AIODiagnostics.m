#import "AIODiagnostics.h"

#import <Network/Network.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <mach/mach.h>
#import <net/if.h>

@import AIOAether;

static NSString *const kServingKey = @"diagnosticsServer";
static const char *kPort = "8642";
/** Lines kept; older ones go first. */
static const NSUInteger kMaxLines = 5000;
/** The app's system log is read this far back, at most this many lines. */
static const double kSystemLogSeconds = 900;
static const NSInteger kSystemLogLines = 3000;

@interface AIODiagnostics ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
/** The number of the newest line; lines are numbered from 1 since launch. */
@property (nonatomic) NSUInteger lastSeq;
@property (nonatomic, strong) NSDateFormatter *time;
@property (nonatomic, strong, nullable) nw_listener_t listener;
@property (nonatomic, readwrite) BOOL serving;
@property (nonatomic, strong) NSDate *launched;
/** The page's log as the last reload began. */
@property (nonatomic, copy) NSString *previousPage;
@end

@implementation AIODiagnostics

+ (AIODiagnostics *)shared {
    static AIODiagnostics *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [AIODiagnostics new];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("aio.diagnostics", DISPATCH_QUEUE_SERIAL);
    _lines = [NSMutableArray array];
    _time = [NSDateFormatter new];
    _time.dateFormat = @"HH:mm:ss.SSS";
    _launched = [NSDate date];
    if ([NSUserDefaults.standardUserDefaults boolForKey:kServingKey]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startServer];
        });
    }
    return self;
}

#pragma mark - The log

- (void)log:(NSString *)source text:(NSString *)text {
    NSDate *now = [NSDate date];
    dispatch_async(self.queue, ^{
        self.lastSeq++;
        NSString *line = [NSString stringWithFormat:@"#%lu %@ [%@] %@", (unsigned long)self.lastSeq,
                          [self.time stringFromDate:now], source, [AIODiagnostics redact:text]];
        [self.lines addObject:line];
        if (self.lines.count > kMaxLines) [self.lines removeObjectsInRange:NSMakeRange(0, self.lines.count - kMaxLines)];
    });
}

- (NSString *)linesSince:(NSUInteger)since {
    __block NSString *text;
    dispatch_sync(self.queue, ^{
        NSUInteger first = self.lastSeq - self.lines.count + 1;
        NSUInteger skip = since >= first ? MIN(since - first + 1, self.lines.count) : 0;
        NSArray *wanted = [self.lines subarrayWithRange:NSMakeRange(skip, self.lines.count - skip)];
        text = [wanted componentsJoinedByString:@"\n"];
    });
    return text;
}

- (void)keepPreviousPage:(NSString *)text {
    self.previousPage = text;
}

- (void)clear {
    dispatch_sync(self.queue, ^{
        [self.lines removeAllObjects];
    });
}

+ (NSString *)redact:(NSString *)text {
    static NSRegularExpression *links, *secrets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        links = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:https?|wss?)://[^\\s\"'<>()\\[\\]{}]+" options:0 error:nil];
        secrets = [NSRegularExpression
            regularExpressionWithPattern:@"\\b(api_key|apikey|access_token|token|password|X-Emby-Token|X-MediaBrowser-Token)=[^&\\s\"']+"
                                 options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (!text.length) return text ?: @"";
    NSMutableString *out = [NSMutableString string];
    __block NSUInteger at = 0;
    [links enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                         usingBlock:^(NSTextCheckingResult *match, NSMatchingFlags flags, BOOL *stop) {
        [out appendString:[text substringWithRange:NSMakeRange(at, match.range.location - at)]];
        [out appendString:[self shortLink:[text substringWithRange:match.range]]];
        at = NSMaxRange(match.range);
    }];
    [out appendString:[text substringFromIndex:at]];
    return [secrets stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"$1=…"];
}

/** `https://host/…/file`, without the path's other parts or the query; the page's route stays. */
+ (NSString *)shortLink:(NSString *)link {
    NSURLComponents *parts = [NSURLComponents componentsWithString:link];
    if (!parts.host) return @"(link)";
    NSString *path = parts.percentEncodedPath ?: @"";
    NSArray *pieces = [[path componentsSeparatedByString:@"/"] filteredArrayUsingPredicate:
                       [NSPredicate predicateWithFormat:@"length > 0"]];
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@://%@", parts.scheme, parts.host];
    if (parts.port) [out appendFormat:@":%@", parts.port];
    if (pieces.count > 1) [out appendString:@"/…"];
    NSString *last = pieces.lastObject;
    if (last) [out appendFormat:@"/%@", last.length > 60 ? [[last substringToIndex:60] stringByAppendingString:@"…"] : last];
    if (parts.percentEncodedQuery.length) [out appendString:@"?…"];
    if (parts.percentEncodedFragment.length) [out appendFormat:@"#%@", parts.percentEncodedFragment];
    return out;
}

#pragma mark - The server

- (void)setServing:(BOOL)serving {
    [NSUserDefaults.standardUserDefaults setBool:serving forKey:kServingKey];
    if (serving) [self startServer];
    else [self stopServer];
}

- (nullable NSString *)address {
    if (!self.serving) return nil;
    NSString *ip = [AIODiagnostics localAddress];
    return [NSString stringWithFormat:@"http://%@:%s/", ip ?: @"<this Apple TV>", kPort];
}

- (void)startServer {
    if (self.listener) return;
    nw_parameters_t parameters = nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,
                                                                 NW_PARAMETERS_DEFAULT_CONFIGURATION);
    nw_parameters_set_reuse_local_address(parameters, true);
    nw_listener_t listener = nw_listener_create_with_port(kPort, parameters);
    if (!listener) {
        AIOLog(@"diagnostics", @"the server couldn't start on port %s", kPort);
        return;
    }
    __weak typeof(self) weakSelf = self;
    nw_listener_set_queue(listener, dispatch_get_main_queue());
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_ready) AIOLog(@"diagnostics", @"serving at %@", weakSelf.address);
        if (state == nw_listener_state_failed) {
            AIOLog(@"diagnostics", @"the server stopped: error %d", error ? nw_error_get_error_code(error) : 0);
            weakSelf.listener = nil;
            weakSelf.serving = NO;
        }
    });
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        [weakSelf serve:connection];
    });
    self.listener = listener;
    self.serving = YES;
    nw_listener_start(listener);
}

- (void)stopServer {
    if (self.listener) nw_listener_cancel(self.listener);
    self.listener = nil;
    self.serving = NO;
}

- (void)serve:(nw_connection_t)connection {
    nw_connection_set_queue(connection, dispatch_get_main_queue());
    nw_connection_start(connection);
    __weak typeof(self) weakSelf = self;
    nw_connection_receive(connection, 1, 64 * 1024, ^(dispatch_data_t content, nw_content_context_t context,
                                                      bool complete, nw_error_t error) {
        NSString *request = content ? [[NSString alloc] initWithData:(NSData *)content encoding:NSUTF8StringEncoding] : nil;
        NSArray *words = [[request componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
        if (words.count < 2 || ![words[0] isEqualToString:@"GET"]) {
            [weakSelf reply:connection status:@"400 Bad Request" body:@"GET only.\n"];
            return;
        }
        NSURLComponents *url = [NSURLComponents componentsWithString:[@"http://tv" stringByAppendingString:words[1]]];
        [weakSelf answer:url.path ?: @"/" query:url.queryItems ?: @[] done:^(NSString *body) {
            [weakSelf reply:connection status:@"200 OK" body:body];
        }];
    });
}

- (void)answer:(NSString *)path query:(NSArray<NSURLQueryItem *> *)query done:(void (^)(NSString *body))done {
    NSUInteger since = 0;
    for (NSURLQueryItem *item in query) {
        if ([item.name isEqualToString:@"since"]) since = (NSUInteger)MAX(0, item.value.integerValue);
    }
    if ([path isEqualToString:@"/state"]) {
        done([self stateText]);
    } else if ([path isEqualToString:@"/native"]) {
        done([self linesSince:since]);
    } else if ([path isEqualToString:@"/page"]) {
        [self pageSince:since done:done];
    } else if ([path isEqualToString:@"/page-before"]) {
        done(self.previousPage.length ? [AIODiagnostics redact:self.previousPage] : @"(no reload yet)");
    } else if ([path isEqualToString:@"/oslog"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *text = [AIODiagnostics redact:[AIOLogStore recentWithSeconds:kSystemLogSeconds limit:kSystemLogLines]];
            dispatch_async(dispatch_get_main_queue(), ^{
                done(text);
            });
        });
    } else if ([path isEqualToString:@"/all"]) {
        NSString *state = [self stateText];
        NSString *native = [self linesSince:since];
        [self pageSince:since done:^(NSString *page) {
            done([NSString stringWithFormat:@"== State\n%@\n\n== App\n%@\n\n== Page\n%@\n", state, native, page]);
        }];
    } else if ([path isEqualToString:@"/clear"]) {
        [self clear];
        self.previousPage = nil;
        if (self.clearPage) self.clearPage();
        done(@"Cleared.\n");
    } else {
        done(@"AIOStreams TV diagnostics\n\n"
             @"/all     state, the app's log and the page's log (?since=N for lines after N)\n"
             @"/state   version, memory, player, page\n"
             @"/native  the app's log: remote, page messages, players (?since=N)\n"
             @"/page    the page's log: keys, focus, clicks, errors (?since=N)\n"
             @"/page-before  the page's log as the last reload began\n"
             @"/oslog   the app's system log, last 15 minutes (NSLog, AetherEngine)\n"
             @"/clear   empties the app's and the page's logs\n");
    }
}

- (void)pageSince:(NSUInteger)since done:(void (^)(NSString *text))done {
    if (!self.pageLog) {
        done(@"(no page)");
        return;
    }
    __block BOOL answered = NO;
    void (^once)(NSString *) = ^(NSString *text) {
        if (answered) return;
        answered = YES;
        done([AIODiagnostics redact:text ?: @""]);
    };
    self.pageLog(since, once);
    // A page that's busy or gone doesn't hold the answer up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        once(@"(the page didn't answer)");
    });
}

- (NSString *)stateText {
    NSBundle *bundle = NSBundle.mainBundle;
    NSMutableString *text = [NSMutableString stringWithFormat:
        @"AIOStreams TV %@ (%@)\ntvOS %@, %@\nUp %.0f s, memory %.0f MB\n",
        [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"],
        [bundle objectForInfoDictionaryKey:@"CFBundleVersion"],
        UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model,
        -self.launched.timeIntervalSinceNow, [AIODiagnostics footprintMB]];
    if (self.state) [text appendString:[AIODiagnostics redact:self.state()]];
    return text;
}

- (void)reply:(nw_connection_t)connection status:(NSString *)status body:(NSString *)body {
    NSData *payload = [body dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %@\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\n"
        @"Cache-Control: no-store\r\nConnection: close\r\n\r\n", status, (unsigned long)payload.length];
    NSMutableData *data = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [data appendData:payload];
    NSData *bytes = data;
    dispatch_data_t message = dispatch_data_create(bytes.bytes, bytes.length, dispatch_get_main_queue(), ^{
        (void)bytes;
    });
    nw_connection_send(connection, message, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t error) {
        nw_connection_cancel(connection);
    });
}

#pragma mark - The device

+ (double)footprintMB {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint / 1048576.0;
}

/** The Apple TV's IPv4 address on the local network, Ethernet or Wi-Fi. */
+ (nullable NSString *)localAddress {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return nil;
    NSString *found = nil;
    for (struct ifaddrs *entry = list; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        if ((entry->ifa_flags & IFF_LOOPBACK) || !(entry->ifa_flags & IFF_UP)) continue;
        NSString *name = @(entry->ifa_name);
        if (![name hasPrefix:@"en"]) continue;
        char text[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &((struct sockaddr_in *)entry->ifa_addr)->sin_addr, text, sizeof(text));
        found = @(text);
        if ([name isEqualToString:@"en0"]) break;
    }
    freeifaddrs(list);
    return found;
}

@end

void AIOLog(NSString *source, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    [AIODiagnostics.shared log:source text:text];
}
