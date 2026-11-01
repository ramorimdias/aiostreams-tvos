#import "AIOMPVPlayer.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreMedia/CoreMedia.h>
#import <MPVKit/MPVKit.h>

#import "AIOThumbnails.h"

/** Positions and cache ranges go to the page at most this often, as on the desktop. */
static const double kThrottleSeconds = 0.25;
/** Picture subtitles keep their own size. */
static NSArray<NSString *> *AIOPictureCodecs(void) {
    return @[ @"hdmv_pgs_subtitle", @"dvd_subtitle", @"dvb_subtitle" ];
}

static NSString *AIOStr(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSNumber *AIONum(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

static NSString *AIOFlag(BOOL on) {
    return on ? @"yes" : @"no";
}

static NSString *AIOSeconds(double ms) {
    return [NSString stringWithFormat:@"%.3f", ms / 1000.0];
}

static id AIOJSON(const char *text) {
    if (!text) return nil;
    NSData *data = [NSData dataWithBytes:text length:strlen(text)];
    return [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
}

/** The view mpv draws into: its own layer is the display layer. */
@interface AIOSampleBufferView : UIView
@end

@implementation AIOSampleBufferView
+ (Class)layerClass {
    return AVSampleBufferDisplayLayer.class;
}
@end

@interface AIOMPVPlayer ()
@property (nonatomic, strong) AIOSampleBufferView *videoView;
@property (nonatomic, strong) AIOThumbnails *thumbnails;
/** Every libmpv call goes through here, never the main thread: mpv's video output waits on the main thread as it starts. */
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) mpv_handle *mpv;

// Read and written on `queue` only.
@property (nonatomic, strong) NSMutableDictionary *heldState;
@property (nonatomic) BOOL flushScheduled;
@property (nonatomic) CFTimeInterval lastFlush;
@property (nonatomic, copy) NSArray<NSDictionary *> *autoSkips;
@property (nonatomic) double positionMs;
@property (nonatomic) BOOL skipping;
@property (nonatomic, copy, nullable) NSString *shownSubtitle;
@property (nonatomic, copy) NSSet<NSString *> *pictureSubtitles;
@property (nonatomic) double subtitleScale;
@property (nonatomic, copy, nullable) NSString *statsPage;
/** The reader's first error since the file started, which says why loading failed. */
@property (nonatomic, copy, nullable) NSString *cause;
@property (nonatomic) BOOL playing;
/** The mute the page asked for, which a stop's silencing doesn't change. */
@property (nonatomic) BOOL wantMuted;
@end

static void AIOWakeup(void *context);

/** Sets a flag without waiting on mpv, so the main thread never blocks on it. */
static void AIOSetFlagNow(mpv_handle *mpv, const char *name, BOOL on) {
    if (!mpv) return;
    int value = on ? 1 : 0;
    mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &value);
}

@implementation AIOMPVPlayer

- (instancetype)initWithHost:(UIView *)host {
    self = [super init];
    if (!self) return nil;
    _send = ^(NSDictionary *message) {};
    _queue = dispatch_queue_create("aiostreams.mpv", DISPATCH_QUEUE_SERIAL);
    _heldState = [NSMutableDictionary dictionary];
    _autoSkips = @[];
    _pictureSubtitles = [NSSet set];
    _subtitleScale = 1;
    _thumbnails = [AIOThumbnails new];
    __weak typeof(self) weakSelf = self;
    _thumbnails.send = ^(NSDictionary *message) {
        AIOMPVPlayer *player = weakSelf;
        if (player) player.send(message);
    };

    _videoView = [[AIOSampleBufferView alloc] initWithFrame:host.bounds];
    _videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _videoView.backgroundColor = UIColor.blackColor;
    _videoView.userInteractionEnabled = NO;
    _videoView.hidden = YES;
    ((AVSampleBufferDisplayLayer *)_videoView.layer).videoGravity = AVLayerVideoGravityResizeAspect;
    [host addSubview:_videoView];

    [self start];
    return self;
}

#pragma mark - mpv

- (void)start {
    mpv_handle *mpv = mpv_create();
    if (!mpv) {
        NSLog(@"[mpv] mpv_create failed");
        return;
    }
    // vo_avfoundation draws into this layer; it doesn't retain it, and the view outlives mpv.
    int64_t layer = (int64_t)(intptr_t)(__bridge void *)self.videoView.layer;
    mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &layer);
    // In this order: Streamyfin found tvOS freezes leaving the player otherwise.
    mpv_set_option_string(mpv, "vo", "avfoundation");
    mpv_set_option_string(mpv, "avfoundation-composite-osd", "no");
    mpv_set_option_string(mpv, "hwdec", "videotoolbox");
    mpv_set_option_string(mpv, "hwdec-codecs", "all");
    mpv_set_option_string(mpv, "hwdec-software-fallback", "yes");
    // Tells the display layer the video's colours, so HDR reaches the TV as HDR.
    mpv_set_option_string(mpv, "target-colorspace-hint", "yes");
    // audiounit keeps video timed to the HDMI output's real clock.
    mpv_set_option_string(mpv, "ao", "audiounit");
    mpv_set_option_string(mpv, "audio-client-name", "AIOStreams");

    // The page drives playback, as in the desktop app.
    NSDictionary<NSString *, NSString *> *options = @{
        @"idle": @"yes",
        @"keep-open": @"no",
        @"input-default-bindings": @"no",
        @"input-vo-keyboard": @"no",
        @"osc": @"no",
        @"osd-bar": @"no",
        @"ytdl": @"no",
        @"config": @"no",
        @"terminal": @"no",
        // A TV has little memory to spare for the stream's cache.
        @"demuxer-max-bytes": @"150MiB",
        @"demuxer-max-back-bytes": @"50MiB",
        @"stream-lavf-o": @"reconnect=1,reconnect_on_http_error=%23%408,429,500,502,503,504,reconnect_delay_max=15",
        @"sub-font": @"Noto Sans",
        @"sub-scale-with-window": @"no",
        @"sub-use-margins": @"no",
    };
    for (NSString *name in options) {
        mpv_set_option_string(mpv, name.UTF8String, options[name].UTF8String);
    }
    // libass can't open tvOS's own font files, so it gets the bundled one.
    NSString *fonts = [self fontsDirectory];
    if (fonts) mpv_set_option_string(mpv, "sub-fonts-dir", fonts.UTF8String);

    if (mpv_initialize(mpv) < 0) {
        NSLog(@"[mpv] mpv_initialize failed");
        mpv_terminate_destroy(mpv);
        return;
    }
    mpv_request_log_messages(mpv, "warn");

    NSArray *observed = @[
        @[ @"time-pos", @(MPV_FORMAT_DOUBLE) ],
        @[ @"duration", @(MPV_FORMAT_DOUBLE) ],
        @[ @"demuxer-cache-state", @(MPV_FORMAT_STRING) ],
        @[ @"pause", @(MPV_FORMAT_FLAG) ],
        @[ @"paused-for-cache", @(MPV_FORMAT_FLAG) ],
        @[ @"seeking", @(MPV_FORMAT_FLAG) ],
        @[ @"idle-active", @(MPV_FORMAT_FLAG) ],
        @[ @"volume", @(MPV_FORMAT_DOUBLE) ],
        @[ @"volume-max", @(MPV_FORMAT_DOUBLE) ],
        @[ @"mute", @(MPV_FORMAT_FLAG) ],
        @[ @"speed", @(MPV_FORMAT_DOUBLE) ],
        @[ @"aid", @(MPV_FORMAT_STRING) ],
        @[ @"sid", @(MPV_FORMAT_STRING) ],
        @[ @"track-list", @(MPV_FORMAT_STRING) ],
        @[ @"chapter-list", @(MPV_FORMAT_STRING) ],
        @[ @"video-params", @(MPV_FORMAT_STRING) ],
    ];
    for (NSArray *property in observed) {
        mpv_observe_property(mpv, 0, [property[0] UTF8String], (mpv_format)[property[1] intValue]);
    }

    self.mpv = mpv;
    mpv_set_wakeup_callback(mpv, AIOWakeup, (__bridge void *)self);
}

static void AIOWakeup(void *context) {
    AIOMPVPlayer *player = (__bridge AIOMPVPlayer *)context;
    dispatch_async(player.queue, ^{
        [player drainEvents];
    });
}

- (NSString *)fontsDirectory {
    // Its own folder: libass reads in every file of the folder it's given.
    NSString *font = [NSBundle.mainBundle pathForResource:@"NotoSans-Regular" ofType:@"ttf" inDirectory:@"Fonts"];
    if (!font) return nil;
    return font.stringByDeletingLastPathComponent;
}

/** Runs `block` with the handle, off the main thread. */
- (void)withMPV:(void (^)(mpv_handle *mpv))block {
    dispatch_async(self.queue, ^{
        if (self.mpv) block(self.mpv);
    });
}

static int AIOCommand(mpv_handle *mpv, NSArray<NSString *> *args) {
    const char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = args[i].UTF8String;
    int result = mpv_command(mpv, argv);
    if (result < 0) NSLog(@"[mpv] %@: %s", args.firstObject, mpv_error_string(result));
    free(argv);
    return result;
}

static void AIOSet(mpv_handle *mpv, NSString *name, NSString *value) {
    int result = mpv_set_property_string(mpv, name.UTF8String, value.UTF8String);
    if (result < 0) NSLog(@"[mpv] %@=%@: %s", name, value, mpv_error_string(result));
}

- (void)shutdown {
    mpv_handle *mpv = self.mpv;
    if (mpv) {
        AIOSetFlagNow(mpv, "mute", YES);
        mpv_set_wakeup_callback(mpv, NULL, NULL);
    }
    dispatch_async(self.queue, ^{
        self.mpv = NULL;
        if (mpv) mpv_terminate_destroy(mpv);
    });
    [self.thumbnails stop];
    [self resetDisplayMode];
    [self.videoView removeFromSuperview];
}

#pragma mark - Messages from the page

- (BOOL)handle:(NSString *)type message:(NSDictionary *)message {
    if ([type isEqualToString:@"player-load"]) {
        [self load:message];
    } else if ([type isEqualToString:@"player-stop"]) {
        [self stop];
    } else if ([type isEqualToString:@"player-set"]) {
        [self change:message];
    } else if ([type isEqualToString:@"player-seek"]) {
        NSNumber *ms = AIONum(message[@"positionMs"]);
        BOOL snap = AIONum(message[@"snapMs"]).doubleValue > 0;
        if (ms) [self withMPV:^(mpv_handle *mpv) {
            AIOCommand(mpv, @[ @"seek", AIOSeconds(ms.doubleValue), snap ? @"absolute+keyframes" : @"absolute+exact" ]);
        }];
    } else if ([type isEqualToString:@"player-sync"]) {
        [self sync];
    } else if ([type isEqualToString:@"player-skips"]) {
        [self setSkips:message[@"segments"]];
    } else if ([type isEqualToString:@"player-style"]) {
        [self style:message];
    } else if ([type isEqualToString:@"player-settings"]) {
        [self settings:message];
    } else if ([type isEqualToString:@"player-subtitle-add"]) {
        [self addSubtitle:message];
    } else if ([type isEqualToString:@"player-stats-overlay"]) {
        [self showStats:AIOStr(message[@"page"])];
    } else if ([type isEqualToString:@"player-thumbnail"]) {
        NSString *url = AIOStr(message[@"url"]);
        if (url) [self.thumbnails want:url headers:message[@"headers"] positionMs:AIONum(message[@"positionMs"])];
    } else if ([type isEqualToString:@"player-subtitle-index"]) {
        self.send(@{ @"type": @"player-subtitle-index", @"tracks": NSNull.null });
    } else if ([type hasPrefix:@"player-"]) {
        // player-subtitle-lines, player-controls, player-engine, player-retry:
        // nothing on tvOS.
    } else if ([type isEqualToString:@"subtitle-file"]) {
        [self addSubtitleFile:message];
    } else {
        return NO;
    }
    return YES;
}

static BOOL AIOIsLanguage(NSString *value) {
    if (value.length == 0 || value.length > 16) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-"];
    return [value stringByTrimmingCharactersInSet:allowed].length == 0;
}

/** Header names and values that can't break out of mpv's option list. */
static BOOL AIOSafeHeader(NSString *name, NSString *value) {
    NSCharacterSet *token = [NSCharacterSet characterSetWithCharactersInString:
                             @"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
    if (name.length == 0 || [name stringByTrimmingCharactersInSet:token].length) return NO;
    if ([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return NO;
    return ![value hasSuffix:@"\\"];
}

/** The page's load as mpv's `loadfile` options, as the desktop app builds them. */
- (void)load:(NSDictionary *)message {
    NSString *url = AIOStr(message[@"url"]);
    NSString *scheme = url ? [NSURL URLWithString:url].scheme.lowercaseString : nil;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        self.send(@{ @"type": @"error", @"message": @"only http(s) urls play" });
        return;
    }
    NSMutableArray<NSString *> *options = [NSMutableArray array];
    double startMs = AIONum(message[@"startMs"]).doubleValue;
    if (startMs > 0) [options addObject:[NSString stringWithFormat:@"start=%@", AIOSeconds(startMs)]];

    NSArray *(^list)(NSString *, id) = ^NSArray *(NSString *name, id values) {
        NSMutableArray *out = [NSMutableArray array];
        if (![values isKindOfClass:NSArray.class]) return out;
        for (id value in values) {
            if (!AIOIsLanguage(AIOStr(value))) continue;
            [out addObject:[NSString stringWithFormat:@"%@%@=%@", name, out.count ? @"-append" : @"", value]];
        }
        return out;
    };
    [options addObjectsFromArray:list(@"alang", message[@"audioLanguages"])];
    NSArray *slang = list(@"slang", message[@"subtitleLanguages"]);
    NSString *mode = AIOStr(message[@"subtitleMode"]) ?: @"default";
    if ([mode isEqualToString:@"none"]) {
        [options addObject:@"sid=no"];
    } else if ([mode isEqualToString:@"forced"]) {
        [options addObjectsFromArray:@[ @"subs-fallback=no", @"subs-fallback-forced=always" ]];
    } else if ([mode isEqualToString:@"always"]) {
        [options addObjectsFromArray:slang];
        [options addObjectsFromArray:@[ @"subs-fallback=yes", @"subs-with-matching-audio=yes" ]];
    } else if ([mode isEqualToString:@"smart"]) {
        [options addObjectsFromArray:slang];
        [options addObject:@"subs-with-matching-audio=no"];
    } else {
        [options addObjectsFromArray:slang];
    }

    NSDictionary *headers = [message[@"headers"] isKindOfClass:NSDictionary.class] ? message[@"headers"] : @{};
    NSMutableArray *fields = [NSMutableArray array];
    for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *value = AIOStr(headers[name]);
        if (!value || !AIOSafeHeader(name, value)) continue;
        [fields addObject:[NSString stringWithFormat:@"%@: %@", name,
                           [value stringByReplacingOccurrencesOfString:@"," withString:@"\\,"]]];
    }
    if (fields.count) {
        NSString *joined = [fields componentsJoinedByString:@","];
        // The length prefix keeps the list's commas inside the one option.
        [options addObject:[NSString stringWithFormat:@"http-header-fields=%%%lu%%%@",
                            (unsigned long)[joined lengthOfBytesUsingEncoding:NSUTF8StringEncoding], joined]];
    }

    BOOL append = [message[@"append"] boolValue];
    BOOL muted = self.wantMuted;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoView.hidden = NO;
    });
    [self withMPV:^(mpv_handle *mpv) {
        self.playing = YES;
        self.cause = nil;
        // Back to the page's mute after a stop, which silenced it on the way out.
        AIOSet(mpv, @"mute", AIOFlag(muted));
        if (append) AIOCommand(mpv, @[ @"playlist-clear" ]);
        AIOCommand(mpv, @[ @"loadfile", url, append ? @"append" : @"replace", @"-1",
                           [options componentsJoinedByString:@","] ]);
    }];
}

/** Silent at once: mpv's stop lets the audio already queued play out. */
- (void)stop {
    AIOSetFlagNow(self.mpv, "mute", YES);
    AIOSetFlagNow(self.mpv, "pause", YES);
    [self withMPV:^(mpv_handle *handle) {
        self.playing = NO;
        AIOCommand(handle, @[ @"stop" ]);
    }];
    [self.thumbnails stop];
    self.videoView.hidden = YES;
    [self resetDisplayMode];
}

- (void)change:(NSDictionary *)message {
    NSMutableArray<NSArray *> *props = [NSMutableArray array];
    NSNumber *paused = AIONum(message[@"paused"]);
    if (paused) [props addObject:@[ @"pause", AIOFlag(paused.boolValue) ]];
    // The page's volume runs to its max with 1 as full; mpv's 100.
    NSNumber *volume = AIONum(message[@"volume"]);
    if (volume) [props addObject:@[ @"volume", [NSString stringWithFormat:@"%.0f", volume.doubleValue * 100] ]];
    NSNumber *muted = AIONum(message[@"muted"]);
    if (muted) {
        self.wantMuted = muted.boolValue;
        [props addObject:@[ @"mute", AIOFlag(muted.boolValue) ]];
    }
    NSNumber *speed = AIONum(message[@"speed"]);
    if (speed) [props addObject:@[ @"speed", speed.stringValue ]];
    // A null track is none; a track id is a number.
    for (NSString *key in @[ @"audio", @"subtitle" ]) {
        id value = message[key];
        if (!value) continue;
        NSString *name = [key isEqualToString:@"audio"] ? @"aid" : @"sid";
        if (value == NSNull.null) [props addObject:@[ name, @"no" ]];
        else if (AIOStr(value).intValue > 0) [props addObject:@[ name, @(AIOStr(value).intValue).stringValue ]];
    }
    NSNumber *delay = AIONum(message[@"subtitleDelayMs"]);
    if (delay) [props addObject:@[ @"sub-delay", AIOSeconds(delay.doubleValue) ]];
    if (!props.count) return;
    [self withMPV:^(mpv_handle *mpv) {
        for (NSArray *prop in props) AIOSet(mpv, prop[0], prop[1]);
    }];
}

- (void)sync {
    [self withMPV:^(mpv_handle *mpv) {
        NSMutableDictionary *state = [NSMutableDictionary dictionary];
        int flag = 0;
        double number = 0;
        if (mpv_get_property(mpv, "idle-active", MPV_FORMAT_FLAG, &flag) >= 0) state[@"idle"] = @(flag != 0);
        if (mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &flag) >= 0) state[@"paused"] = @(flag != 0);
        if (mpv_get_property(mpv, "paused-for-cache", MPV_FORMAT_FLAG, &flag) >= 0) state[@"buffering"] = @(flag != 0);
        if (mpv_get_property(mpv, "mute", MPV_FORMAT_FLAG, &flag) >= 0) state[@"muted"] = @(flag != 0);
        if (mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &number) >= 0) state[@"positionMs"] = @(number * 1000);
        if (mpv_get_property(mpv, "duration", MPV_FORMAT_DOUBLE, &number) >= 0) state[@"durationMs"] = @(number * 1000);
        if (mpv_get_property(mpv, "volume", MPV_FORMAT_DOUBLE, &number) >= 0) state[@"volume"] = @(number / 100);
        if (mpv_get_property(mpv, "volume-max", MPV_FORMAT_DOUBLE, &number) >= 0) state[@"maxVolume"] = @(number / 100);
        if (mpv_get_property(mpv, "speed", MPV_FORMAT_DOUBLE, &number) >= 0) state[@"speed"] = @(number);
        [self sendState:state];
        char *tracks = mpv_get_property_string(mpv, "track-list");
        [self sendTracks:AIOJSON(tracks)];
        mpv_free(tracks);
        char *chapters = mpv_get_property_string(mpv, "chapter-list");
        [self sendChapters:AIOJSON(chapters)];
        mpv_free(chapters);
    }];
}

- (void)setSkips:(id)segments {
    NSMutableArray *skips = [NSMutableArray array];
    if ([segments isKindOfClass:NSArray.class]) {
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class] || ![AIONum(segment[@"auto"]) boolValue]) continue;
            NSNumber *start = AIONum(segment[@"startMs"]);
            NSNumber *end = AIONum(segment[@"endMs"]);
            if (start && end && end.doubleValue > start.doubleValue) [skips addObject:@{ @"start": start, @"end": end }];
        }
    }
    dispatch_async(self.queue, ^{
        self.autoSkips = skips;
    });
}

static BOOL AIOIsColour(NSString *text) {
    if (![text hasPrefix:@"#"] || !(text.length == 7 || text.length == 9)) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [[text substringFromIndex:1] stringByTrimmingCharactersInSet:hex].length == 0;
}

/** The page's subtitle look and fit, as the desktop app sets them. */
- (void)style:(NSDictionary *)message {
    NSDictionary *look = [message[@"subtitles"] isKindOfClass:NSDictionary.class] ? message[@"subtitles"] : nil;
    if (!look) return;
    NSString *fit = AIOStr(message[@"fit"]) ?: @"fit";
    NSMutableArray<NSArray *> *props = [NSMutableArray arrayWithArray:@[
        @[ @"keepaspect", AIOFlag(![fit isEqualToString:@"stretch"]) ],
        @[ @"panscan", [fit isEqualToString:@"crop"] ? @"1" : @"0" ],
        @[ @"sub-ass-force-margins", AIOFlag([fit isEqualToString:@"crop"]) ],
        @[ @"sub-bold", AIOFlag([look[@"bold"] boolValue]) ],
        @[ @"sub-outline-size", [AIONum(look[@"outlineSize"]) ?: @0 stringValue] ],
        @[ @"sub-shadow-offset", [AIONum(look[@"shadowSize"]) ?: @0 stringValue] ],
        @[ @"sub-border-style", [look[@"box"] boolValue] ? @"background-box" : @"outline-and-shadow" ],
        @[ @"sub-ass-override", [AIOStr(look[@"override"]) isEqualToString:@"force"] ? @"force" : @"scale" ],
        @[ @"sub-pos", [AIONum(look[@"position"]) ?: @100 stringValue] ],
    ]];
    for (NSArray *colour in @[ @[ @"sub-color", @"color" ], @[ @"sub-outline-color", @"outlineColor" ],
                               @[ @"sub-shadow-color", @"outlineColor" ], @[ @"sub-back-color", @"backColor" ] ]) {
        NSString *value = AIOStr(look[colour[1]]);
        if (AIOIsColour(value)) [props addObject:@[ colour[0], value ]];
    }
    double scale = AIONum(look[@"scale"]).doubleValue ?: 1;
    [self withMPV:^(mpv_handle *mpv) {
        for (NSArray *prop in props) AIOSet(mpv, prop[0], prop[1]);
        self.subtitleScale = scale;
        [self applySubtitleScale:mpv];
    }];
}

/** On `queue`: a picture subtitle keeps its own size. */
- (void)applySubtitleScale:(mpv_handle *)mpv {
    BOOL picture = self.shownSubtitle && [self.pictureSubtitles containsObject:self.shownSubtitle];
    AIOSet(mpv, @"sub-scale", [NSString stringWithFormat:@"%.3f", picture ? 1 : self.subtitleScale]);
}

- (void)settings:(NSDictionary *)message {
    NSMutableArray<NSArray *> *props = [NSMutableArray array];
    if (message[@"hardwareDecoding"]) {
        [props addObject:@[ @"hwdec", [message[@"hardwareDecoding"] boolValue] ? @"videotoolbox" : @"no" ]];
    }
    NSString *channels = AIOStr(message[@"audioChannels"]);
    if (channels) {
        BOOL fixed = [@[ @"stereo", @"5.1", @"7.1" ] containsObject:channels];
        [props addObject:@[ @"audio-channels", fixed ? channels : @"auto-safe" ]];
    }
    NSNumber *delay = AIONum(message[@"audioDelayMs"]);
    if (delay) [props addObject:@[ @"audio-delay", AIOSeconds(delay.doubleValue) ]];
    NSNumber *cacheMb = AIONum(message[@"cacheMb"]);
    if (cacheMb.intValue > 0) {
        long long bytes = MIN(cacheMb.longLongValue, 400) * 1000000LL;
        [props addObject:@[ @"demuxer-max-bytes", @(bytes - bytes / 4).stringValue ]];
        [props addObject:@[ @"demuxer-max-back-bytes", @(bytes / 4).stringValue ]];
    }
    [self withMPV:^(mpv_handle *mpv) {
        for (NSArray *prop in props) AIOSet(mpv, prop[0], prop[1]);
    }];
}

- (void)addSubtitle:(NSDictionary *)message {
    NSString *url = AIOStr(message[@"url"]);
    NSString *scheme = url ? [NSURL URLWithString:url].scheme.lowercaseString : nil;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) {
        self.send(@{ @"type": @"error", @"message": @"only http(s) subtitles load" });
        return;
    }
    NSNumber *replace = AIONum(message[@"replace"]);
    NSString *title = AIOStr(message[@"title"]) ?: @"";
    NSString *language = AIOStr(message[@"language"]) ?: @"";
    [self withMPV:^(mpv_handle *mpv) {
        if (replace) AIOCommand(mpv, @[ @"sub-remove", replace.stringValue ]);
        AIOCommand(mpv, @[ @"sub-add", url, @"select", title, language ]);
    }];
}

/** A subtitle file the user picked, sent as base64, written out for mpv to open. */
- (void)addSubtitleFile:(NSDictionary *)message {
    NSString *name = AIOStr(message[@"name"]) ?: @"subtitle.srt";
    NSString *extension = name.pathExtension.lowercaseString;
    if (![@[ @"srt", @"vtt", @"ass", @"ssa", @"sub", @"sup" ] containsObject:extension]) return;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:AIOStr(message[@"data"]) ?: @""
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data.length || data.length > (10 << 20)) return;
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, extension]];
    if (![data writeToFile:path atomically:YES]) return;
    NSString *title = [name substringToIndex:MIN((NSUInteger)200, name.length)];
    [self withMPV:^(mpv_handle *mpv) {
        AIOCommand(mpv, @[ @"sub-add", path, @"select", title ]);
    }];
}

/** mpv's own stats overlay, by the desktop app's page numbers. */
- (void)showStats:(nullable NSString *)page {
    if (page && ![@[ @"1", @"2", @"3", @"5" ] containsObject:page]) return;
    [self withMPV:^(mpv_handle *mpv) {
        if (self.statsPage) AIOCommand(mpv, @[ @"script-binding", @"stats/display-stats-toggle" ]);
        if (page) AIOCommand(mpv, @[ @"script-binding", [NSString stringWithFormat:@"stats/display-page-%@-toggle", page] ]);
        self.statsPage = page;
    }];
}

- (void)pauseForBackground {
    [self withMPV:^(mpv_handle *mpv) {
        AIOSet(mpv, @"pause", @"yes");
    }];
}

#pragma mark - Reports, on `queue`

- (void)drainEvents {
    mpv_handle *mpv = self.mpv;
    if (!mpv) return;
    while (YES) {
        mpv_event *event = mpv_wait_event(mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
            case MPV_EVENT_PROPERTY_CHANGE:
                [self propertyChanged:(mpv_event_property *)event->data];
                break;
            case MPV_EVENT_START_FILE:
                self.cause = nil;
                [self sendEvent:@"start"];
                break;
            case MPV_EVENT_FILE_LOADED:
                [self sendEvent:@"loaded"];
                break;
            case MPV_EVENT_PLAYBACK_RESTART:
                [self sendEvent:@"restart"];
                break;
            case MPV_EVENT_END_FILE:
                [self fileEnded:(mpv_event_end_file *)event->data];
                break;
            case MPV_EVENT_LOG_MESSAGE:
                [self logged:(mpv_event_log_message *)event->data];
                break;
            case MPV_EVENT_SHUTDOWN:
                return;
            default:
                break;
        }
    }
}

- (void)logged:(mpv_event_log_message *)log {
    NSString *text = [[NSString stringWithUTF8String:log->text ?: ""]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *prefix = [NSString stringWithUTF8String:log->prefix ?: ""];
    NSLog(@"[mpv/%@] %@", prefix, text);
    BOOL reader = [prefix hasPrefix:@"ffmpeg"] || [prefix hasPrefix:@"stream"] || [prefix hasPrefix:@"lavf"];
    if (reader && !self.cause && text.length && log->log_level <= MPV_LOG_LEVEL_ERROR) self.cause = text;
}

- (void)propertyChanged:(mpv_event_property *)property {
    NSString *name = [NSString stringWithUTF8String:property->name];
    void *data = property->data;
    BOOL has = property->format != MPV_FORMAT_NONE && data != NULL;
    double number = has && property->format == MPV_FORMAT_DOUBLE ? *(double *)data : 0;
    BOOL flag = has && property->format == MPV_FORMAT_FLAG ? *(int *)data != 0 : NO;
    const char *text = has && property->format == MPV_FORMAT_STRING ? *(char **)data : NULL;

    if ([name isEqualToString:@"time-pos"]) {
        if (!has) return;
        self.positionMs = number * 1000;
        [self hold:@{ @"positionMs": @(self.positionMs) }];
        [self skipIfInSegment];
    } else if ([name isEqualToString:@"demuxer-cache-state"]) {
        if (text) [self hold:@{ @"buffered": [self cacheRanges:AIOJSON(text)] }];
    } else if ([name isEqualToString:@"duration"]) {
        if (has) [self sendState:@{ @"durationMs": @(number * 1000) }];
    } else if ([name isEqualToString:@"pause"]) {
        if (has) [self sendState:@{ @"paused": @(flag) }];
    } else if ([name isEqualToString:@"paused-for-cache"]) {
        if (has) [self sendState:@{ @"buffering": @(flag) }];
    } else if ([name isEqualToString:@"seeking"]) {
        if (has) [self sendState:@{ @"seeking": @(flag) }];
    } else if ([name isEqualToString:@"idle-active"]) {
        if (has) [self sendState:@{ @"idle": @(flag) }];
    } else if ([name isEqualToString:@"volume"]) {
        if (has) [self sendState:@{ @"volume": @(number / 100) }];
    } else if ([name isEqualToString:@"volume-max"]) {
        if (has) [self sendState:@{ @"maxVolume": @(number / 100) }];
    } else if ([name isEqualToString:@"mute"]) {
        // A stop mutes on the way out, which the page didn't ask for.
        if (has && self.playing) [self sendState:@{ @"muted": @(flag) }];
    } else if ([name isEqualToString:@"speed"]) {
        if (has) [self sendState:@{ @"speed": @(number) }];
    } else if ([name isEqualToString:@"aid"] || [name isEqualToString:@"sid"]) {
        NSString *value = text ? [NSString stringWithUTF8String:text] : nil;
        NSString *track = value.length && value.intValue > 0 ? @(value.intValue).stringValue : nil;
        BOOL audio = [name isEqualToString:@"aid"];
        NSString *key = audio ? @"audio" : @"subtitle";
        id picked = track ?: (id)NSNull.null;
        [self sendState:@{ key: picked }];
        if (!audio) {
            self.shownSubtitle = track;
            [self applySubtitleScale:self.mpv];
        }
    } else if ([name isEqualToString:@"track-list"]) {
        id tracks = AIOJSON(text);
        [self notePictureSubtitles:tracks];
        [self sendTracks:tracks];
    } else if ([name isEqualToString:@"chapter-list"]) {
        [self sendChapters:AIOJSON(text)];
    } else if ([name isEqualToString:@"video-params"]) {
        [self videoParamsChanged:AIOJSON(text)];
    }
}

- (void)notePictureSubtitles:(id)tracks {
    NSMutableSet *pictures = [NSMutableSet set];
    if ([tracks isKindOfClass:NSArray.class]) {
        for (NSDictionary *track in tracks) {
            if (![track isKindOfClass:NSDictionary.class]) continue;
            if ([track[@"type"] isEqual:@"sub"] && [AIOPictureCodecs() containsObject:AIOStr(track[@"codec"]) ?: @""]) {
                [pictures addObject:[AIONum(track[@"id"]) stringValue] ?: @""];
            }
        }
    }
    self.pictureSubtitles = pictures;
    [self applySubtitleScale:self.mpv];
}

- (void)fileEnded:(mpv_event_end_file *)end {
    NSString *reason;
    switch (end->reason) {
        case MPV_END_FILE_REASON_EOF: reason = @"eof"; break;
        case MPV_END_FILE_REASON_STOP: reason = @"stop"; break;
        case MPV_END_FILE_REASON_QUIT: reason = @"quit"; break;
        case MPV_END_FILE_REASON_ERROR: reason = @"error"; break;
        case MPV_END_FILE_REASON_REDIRECT: reason = @"redirect"; break;
        default: reason = @"unknown"; break;
    }
    NSMutableDictionary *message = [@{ @"type": @"player-ended", @"reason": reason } mutableCopy];
    if (end->reason == MPV_END_FILE_REASON_ERROR) {
        message[@"error"] = [NSString stringWithUTF8String:mpv_error_string(end->error)];
        if (self.cause) {
            message[@"cause"] = self.cause;
            NSRange http = [self.cause rangeOfString:@"HTTP error "];
            if (http.location != NSNotFound && self.cause.length >= NSMaxRange(http) + 3) {
                int status = [[self.cause substringWithRange:NSMakeRange(NSMaxRange(http), 3)] intValue];
                if (status >= 100) message[@"status"] = @(status);
            }
        }
    } else {
        message[@"error"] = NSNull.null;
    }
    [self post:message];
}

- (NSArray *)cacheRanges:(id)state {
    NSMutableArray *ranges = [NSMutableArray array];
    if (![state isKindOfClass:NSDictionary.class]) return ranges;
    for (NSDictionary *range in state[@"seekable-ranges"]) {
        if (![range isKindOfClass:NSDictionary.class]) continue;
        NSNumber *start = AIONum(range[@"start"]);
        NSNumber *end = AIONum(range[@"end"]);
        if (start && end) [ranges addObject:@{ @"startMs": @(start.doubleValue * 1000), @"endMs": @(end.doubleValue * 1000) }];
    }
    if (!ranges.count) {
        NSNumber *start = AIONum(state[@"reader-pts"]);
        NSNumber *end = AIONum(state[@"cache-end"]);
        if (start && end) [ranges addObject:@{ @"startMs": @(start.doubleValue * 1000), @"endMs": @(end.doubleValue * 1000) }];
    }
    [ranges sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"startMs"] compare:b[@"startMs"]];
    }];
    return ranges;
}

- (void)sendTracks:(id)list {
    NSMutableArray *tracks = [NSMutableArray array];
    if ([list isKindOfClass:NSArray.class]) {
        for (NSDictionary *t in list) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            NSString *kind = [t[@"type"] isEqual:@"audio"] ? @"audio" : [t[@"type"] isEqual:@"sub"] ? @"subtitle" : nil;
            NSNumber *trackId = AIONum(t[@"id"]);
            if (!kind || !trackId) continue;
            NSMutableDictionary *track = [@{
                @"id": trackId.stringValue,
                @"type": kind,
                @"default": @([t[@"default"] isEqual:@YES]),
                @"forced": @([t[@"forced"] isEqual:@YES]),
                @"hearingImpaired": @([t[@"hearing-impaired"] isEqual:@YES]),
                @"visualImpaired": @([t[@"visual-impaired"] isEqual:@YES]),
                @"external": @([t[@"external"] isEqual:@YES]),
            } mutableCopy];
            if (AIOStr(t[@"title"])) track[@"title"] = t[@"title"];
            if (AIOStr(t[@"lang"])) track[@"language"] = t[@"lang"];
            if (AIOStr(t[@"codec"])) track[@"codec"] = t[@"codec"];
            if (AIOStr(t[@"external-filename"])) track[@"url"] = t[@"external-filename"];
            [tracks addObject:track];
        }
    }
    [self post:@{ @"type": @"player-tracks", @"tracks": tracks }];
}

- (void)sendChapters:(id)list {
    NSMutableArray *chapters = [NSMutableArray array];
    if ([list isKindOfClass:NSArray.class]) {
        for (NSDictionary *c in list) {
            if (![c isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *chapter = [@{ @"startMs": @([AIONum(c[@"time"]) doubleValue] * 1000) } mutableCopy];
            if (AIOStr(c[@"title"])) chapter[@"title"] = c[@"title"];
            [chapters addObject:chapter];
        }
    }
    [self post:@{ @"type": @"player-chapters", @"chapters": chapters }];
}

- (void)sendEvent:(NSString *)name {
    [self post:@{ @"type": @"player-event", @"name": name }];
}

/** Sends at once, with anything held back going first. */
- (void)sendState:(NSDictionary *)fields {
    NSMutableDictionary *state = [self.heldState mutableCopy];
    [self.heldState removeAllObjects];
    [state addEntriesFromDictionary:fields];
    state[@"type"] = @"player-state";
    self.lastFlush = CACurrentMediaTime();
    [self post:state];
}

/** Positions and cache ranges, at most every 250 ms. */
- (void)hold:(NSDictionary *)fields {
    [self.heldState addEntriesFromDictionary:fields];
    double wait = kThrottleSeconds - (CACurrentMediaTime() - self.lastFlush);
    if (wait <= 0) {
        [self sendState:@{}];
        return;
    }
    if (self.flushScheduled) return;
    self.flushScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), self.queue, ^{
        self.flushScheduled = NO;
        if (self.heldState.count) [self sendState:@{}];
    });
}

- (void)post:(NSDictionary *)message {
    void (^send)(NSDictionary *) = self.send;
    dispatch_async(dispatch_get_main_queue(), ^{
        send(message);
    });
}

- (void)skipIfInSegment {
    if (self.skipping) return;
    for (NSDictionary *skip in self.autoSkips) {
        double start = [skip[@"start"] doubleValue];
        double end = [skip[@"end"] doubleValue];
        if (self.positionMs >= start && self.positionMs < end - 500) {
            self.skipping = YES;
            AIOCommand(self.mpv, @[ @"seek", AIOSeconds(end), @"absolute" ]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), self.queue, ^{
                self.skipping = NO;
            });
            return;
        }
    }
}

#pragma mark - The TV's picture mode

/**
 * Asks tvOS for the TV mode the video wants (HDR10, HLG or SDR, at its frame
 * rate), which it applies where the user turned on Match Content.
 */
- (void)videoParamsChanged:(id)params {
    if (![params isKindOfClass:NSDictionary.class]) return;
    NSString *primaries = AIOStr(params[@"primaries"]) ?: @"";
    NSString *gamma = AIOStr(params[@"gamma"]) ?: @"";
    double fps = 0;
    mpv_get_property(self.mpv, "container-fps", MPV_FORMAT_DOUBLE, &fps);
    if (fps <= 0) fps = 24;
    BOOL wide = [primaries hasPrefix:@"bt.2020"];
    NSString *mode = [gamma isEqualToString:@"pq"] || (wide && ![gamma isEqualToString:@"hlg"]) ? @"pq"
                   : [gamma isEqualToString:@"hlg"] ? @"hlg" : @"sdr";
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setDisplayMode:mode fps:(float)fps];
    });
}

- (void)setDisplayMode:(NSString *)mode fps:(float)fps {
    UIWindow *window = self.videoView.window;
    if (!window) return;
    NSMutableDictionary *extensions = [@{ (__bridge NSString *)kCMFormatDescriptionExtension_FullRangeVideo: @NO } mutableCopy];
    if ([mode isEqualToString:@"sdr"]) {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries] = (__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_709_2;
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] = (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_709_2;
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix] = (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2;
    } else {
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_ColorPrimaries] = (__bridge NSString *)kCMFormatDescriptionColorPrimaries_ITU_R_2020;
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_TransferFunction] = [mode isEqualToString:@"hlg"]
            ? (__bridge NSString *)kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            : (__bridge NSString *)kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ;
        extensions[(__bridge NSString *)kCMFormatDescriptionExtension_YCbCrMatrix] = (__bridge NSString *)kCMFormatDescriptionYCbCrMatrix_ITU_R_2020;
    }
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_HEVC, 3840, 2160,
                                                     (__bridge CFDictionaryRef)extensions, &format);
    if (status != noErr || !format) return;
    window.avDisplayManager.preferredDisplayCriteria =
        [[AVDisplayCriteria alloc] initWithRefreshRate:fps formatDescription:format];
    CFRelease(format);
}

- (void)resetDisplayMode {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.videoView.window.avDisplayManager.preferredDisplayCriteria = nil;
    });
}

@end
