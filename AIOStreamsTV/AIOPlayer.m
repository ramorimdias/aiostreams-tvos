#import "AIOPlayer.h"

#import <TVVLCKit/TVVLCKit.h>

/** How often the position goes to the page, as the Android app throttles it. */
static const NSTimeInterval kTick = 0.25;
/** Playing with the clock stood still this long counts as buffering. */
static const NSTimeInterval kStallSeconds = 0.75;

static NSString *AIOString(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSNumber *AIONumber(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

/** ISO 639-1 codes against the 639-2 ones containers and Jellyfin use. */
static NSString *AIOLanguage(NSString *code) {
    NSString *lower = code.lowercaseString;
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"en": @"eng", @"pt": @"por", @"es": @"spa", @"fr": @"fre", @"fra": @"fre",
            @"de": @"ger", @"deu": @"ger", @"it": @"ita", @"ja": @"jpn", @"zh": @"chi",
            @"zho": @"chi", @"nl": @"dut", @"nld": @"dut", @"ru": @"rus", @"ko": @"kor",
            @"ar": @"ara", @"pl": @"pol", @"tr": @"tur", @"sv": @"swe", @"no": @"nor",
            @"da": @"dan", @"fi": @"fin", @"cs": @"cze", @"ces": @"cze", @"el": @"gre",
            @"ell": @"gre", @"he": @"heb", @"hi": @"hin", @"hu": @"hun", @"ro": @"rum",
            @"ron": @"rum", @"uk": @"ukr", @"th": @"tha", @"vi": @"vie", @"id": @"ind",
        };
    });
    return map[lower] ?: lower;
}

static BOOL AIOContains(NSString *text, NSString *needle, NSStringCompareOptions options) {
    return text.length > 0 && [text rangeOfString:needle options:options].location != NSNotFound;
}

static BOOL AIOSameLanguage(NSString *a, NSString *b) {
    if (a.length == 0 || b.length == 0) return NO;
    return [AIOLanguage(a) isEqualToString:AIOLanguage(b)];
}

@interface AIOPlayer () <VLCMediaPlayerDelegate>
@property (nonatomic, strong) VLCMediaPlayer *player;
@property (nonatomic, strong, nullable) NSTimer *ticker;

// The file playing and what the page asked for it.
@property (nonatomic, copy, nullable) NSString *url;
@property (nonatomic, copy) NSArray<NSString *> *audioLanguages;
@property (nonatomic, copy) NSArray<NSString *> *subtitleLanguages;
@property (nonatomic, copy) NSString *subtitleMode;
@property (nonatomic) BOOL loadedSent;
@property (nonatomic) BOOL wantPaused;
@property (nonatomic) BOOL stopping;

// What was last sent, so only changes go out.
@property (nonatomic) int sentPosition;
@property (nonatomic) int sentDuration;
@property (nonatomic) BOOL sentPaused;
@property (nonatomic) BOOL sentBuffering;
@property (nonatomic, copy, nullable) NSString *sentTracks;
@property (nonatomic, copy, nullable) NSString *sentAudio;
@property (nonatomic, copy, nullable) NSString *sentSubtitle;

// Buffering and seeking, which VLC doesn't report reliably.
@property (nonatomic) int lastClock;
@property (nonatomic, strong) NSDate *clockMoved;
@property (nonatomic) BOOL seeking;
@property (nonatomic) int seekTarget;
@property (nonatomic, strong, nullable) NSDate *seekStarted;

/** Subtitle files added by URL, by the track id VLC gave them. */
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *external;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *externalTitles;
@property (nonatomic, copy, nullable) NSSet<NSString *> *subtitleIdsBeforeAdd;
@property (nonatomic, copy, nullable) NSString *pendingSubtitleURL;
@property (nonatomic, copy, nullable) NSString *pendingSubtitleTitle;

/** Stretches to skip on reaching them. */
@property (nonatomic, copy) NSArray<NSDictionary *> *autoSkips;

// What the page set, which a new player for the next file takes over.
/** The page's volume, where 1 is full; VLC's 100. */
@property (nonatomic) double volume;
@property (nonatomic) BOOL muted;
@property (nonatomic) float speed;
/** VLC's subtitle look, from the page's `player-style`; changes apply from the next file. */
@property (nonatomic, copy) NSArray<NSString *> *subtitleOptions;
@property (nonatomic, copy, nullable) NSArray<NSString *> *playerOptions;
@property (nonatomic) NSInteger audioDelayUs;
@end

@implementation AIOPlayer

- (instancetype)initWithVideoView:(UIView *)videoView {
    self = [super init];
    if (!self) return nil;
    _videoView = videoView;
    _volume = 1;
    _speed = 1;
    _subtitleOptions = [AIOPlayer subtitleOptionsFor:nil];
    [self makePlayer];
    _audioLanguages = @[];
    _subtitleLanguages = @[];
    _subtitleMode = @"default";
    _external = [NSMutableDictionary dictionary];
    _externalTitles = [NSMutableDictionary dictionary];
    _autoSkips = @[];
    _clockMoved = [NSDate date];
    _send = ^(NSDictionary *message) {};
    videoView.hidden = YES;
    return self;
}

/**
 * VLC takes its subtitle look only as it starts, so a file with a different
 * look gets a new player.
 */
- (void)makePlayer {
    if (self.player && [self.playerOptions isEqualToArray:self.subtitleOptions]) return;
    if (self.player) {
        self.player.delegate = nil;
        [self.player stop];
    }
    self.playerOptions = self.subtitleOptions;
    self.player = [[VLCMediaPlayer alloc] initWithOptions:self.subtitleOptions];
    self.player.delegate = self;
    self.player.drawable = self.videoView;
}

/** What the page's volume, mute and speed come to in VLC. */
- (void)applyLevels {
    self.player.audio.volume = (int)lround(MAX(0, MIN(2, self.volume)) * 100);
    self.player.audio.muted = self.muted;
    self.player.rate = self.speed > 0 ? self.speed : 1;
}

/** `#AARRGGBB` or `#RRGGBB` as VLC's RGB number and 0-255 opacity. */
static BOOL AIOParseColor(NSString *text, int *rgb, int *alpha) {
    if (![text hasPrefix:@"#"]) return NO;
    NSString *hex = [text substringFromIndex:1];
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&value]) return NO;
    if (hex.length == 8) {
        *alpha = (value >> 24) & 0xff;
        *rgb = value & 0xffffff;
    } else if (hex.length == 6) {
        *alpha = 255;
        *rgb = value;
    } else {
        return NO;
    }
    return YES;
}

/**
 * The page's subtitle look (sizes in mpv's units) as VLC's freetype options.
 * VLC sizes text as a fraction of the video's height: a larger number is smaller text.
 */
+ (NSArray<NSString *> *)subtitleOptionsFor:(nullable NSDictionary *)look {
    double scale = [AIONumber(look[@"scale"]) doubleValue] ?: 1;
    int relative = (int)lround(22 / MAX(0.5, MIN(2, scale)));
    NSMutableArray *options = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"--freetype-rel-fontsize=%d", relative], nil];
    if ([look[@"bold"] boolValue]) [options addObject:@"--freetype-bold"];

    int rgb = 0, alpha = 0;
    if (AIOParseColor(AIOString(look[@"color"]), &rgb, &alpha)) {
        [options addObject:[NSString stringWithFormat:@"--freetype-color=%d", rgb]];
        [options addObject:[NSString stringWithFormat:@"--freetype-opacity=%d", alpha]];
    }
    double outline = [AIONumber(look[@"outlineSize"]) doubleValue];
    if (!look) outline = 1.65;
    int thickness = outline <= 0 ? 0 : outline < 1.3 ? 2 : outline < 2.3 ? 4 : 6;
    [options addObject:[NSString stringWithFormat:@"--freetype-outline-thickness=%d", thickness]];
    if (AIOParseColor(AIOString(look[@"outlineColor"]), &rgb, &alpha)) {
        [options addObject:[NSString stringWithFormat:@"--freetype-outline-color=%d", rgb]];
        [options addObject:[NSString stringWithFormat:@"--freetype-outline-opacity=%d", alpha]];
    }
    if ([look[@"box"] boolValue] && AIOParseColor(AIOString(look[@"backColor"]), &rgb, &alpha)) {
        [options addObject:[NSString stringWithFormat:@"--freetype-background-color=%d", rgb]];
        [options addObject:[NSString stringWithFormat:@"--freetype-background-opacity=%d", alpha]];
    } else {
        [options addObject:@"--freetype-background-opacity=0"];
    }
    BOOL shadow = [AIONumber(look[@"shadowSize"]) doubleValue] > 0;
    [options addObject:[NSString stringWithFormat:@"--freetype-shadow-opacity=%d", shadow ? 128 : 0]];
    return options;
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
        NSNumber *ms = AIONumber(message[@"positionMs"]);
        if (ms) [self seekTo:ms.intValue];
    } else if ([type isEqualToString:@"player-sync"]) {
        [self sync];
    } else if ([type isEqualToString:@"player-skips"]) {
        [self setSkips:message[@"segments"]];
    } else if ([type isEqualToString:@"player-subtitle-add"]) {
        [self addSubtitle:message];
    } else if ([type isEqualToString:@"player-settings"]) {
        NSNumber *delay = AIONumber(message[@"audioDelayMs"]);
        self.audioDelayUs = (NSInteger)(delay.doubleValue * 1000);
        if (self.url) self.player.currentAudioPlaybackDelay = self.audioDelayUs;
    } else if ([type isEqualToString:@"player-style"]) {
        NSDictionary *look = [message[@"subtitles"] isKindOfClass:NSDictionary.class] ? message[@"subtitles"] : nil;
        if (look) self.subtitleOptions = [AIOPlayer subtitleOptionsFor:look];
    } else if ([type isEqualToString:@"player-thumbnail"]) {
        // No seek-bar thumbnails here; the page shows none.
        self.send(@{ @"type": @"player-thumbnail", @"url": AIOString(message[@"url"]) ?: @"", @"src": NSNull.null });
    } else if ([type isEqualToString:@"player-subtitle-index"]) {
        self.send(@{ @"type": @"player-subtitle-index", @"tracks": NSNull.null });
    } else if ([type hasPrefix:@"player-"]) {
        // player-style, player-stats-overlay, player-subtitle-lines, player-controls,
        // player-engine, player-retry: nothing VLC does here.
    } else if ([type isEqualToString:@"subtitle-file"]) {
        [self addSubtitleFile:message];
    } else {
        return NO;
    }
    return YES;
}

- (void)load:(NSDictionary *)message {
    NSString *urlString = AIOString(message[@"url"]);
    NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
    if (!url || !([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"])) {
        self.send(@{ @"type": @"error", @"message": @"only http(s) urls play" });
        return;
    }
    self.stopping = YES;
    [self.player stop];
    [self makePlayer];
    [self applyLevels];
    self.stopping = NO;

    self.url = urlString;
    self.audioLanguages = [message[@"audioLanguages"] isKindOfClass:NSArray.class] ? message[@"audioLanguages"] : @[];
    self.subtitleLanguages = [message[@"subtitleLanguages"] isKindOfClass:NSArray.class] ? message[@"subtitleLanguages"] : @[];
    self.subtitleMode = AIOString(message[@"subtitleMode"]) ?: @"default";
    self.loadedSent = NO;
    self.seeking = NO;
    self.sentTracks = nil;
    self.sentAudio = nil;
    self.sentSubtitle = nil;
    self.sentPosition = -1;
    self.sentDuration = -1;
    [self.external removeAllObjects];
    [self.externalTitles removeAllObjects];
    self.autoSkips = @[];

    VLCMedia *media = [VLCMedia mediaWithURL:url];
    NSMutableDictionary *options = [NSMutableDictionary dictionary];
    double startMs = AIONumber(message[@"startMs"]).doubleValue;
    if (startMs > 0) options[@"start-time"] = [NSString stringWithFormat:@"%.3f", startMs / 1000.0];
    // Debrid and usenet links come from far away; a deeper buffer rides out stalls.
    options[@"network-caching"] = @"3000";
    NSDictionary *headers = [message[@"headers"] isKindOfClass:NSDictionary.class] ? message[@"headers"] : @{};
    for (NSString *name in headers) {
        NSString *value = AIOString(headers[name]);
        if (!value) continue;
        // VLC sets only these two of a request's headers.
        if ([name caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) options[@"http-user-agent"] = value;
        if ([name caseInsensitiveCompare:@"Referer"] == NSOrderedSame) options[@"http-referrer"] = value;
    }
    [media addOptions:options];

    self.videoView.hidden = NO;
    self.player.media = media;
    [self.player play];
    self.clockMoved = [NSDate date];
    self.lastClock = -1;
    [self startTicking];

    self.send(@{ @"type": @"player-event", @"name": @"start" });
    [self sendState:@{ @"idle": @NO, @"paused": @NO, @"buffering": @YES }];
    self.sentPaused = NO;
    self.sentBuffering = YES;
}

- (void)stop {
    self.url = nil;
    self.stopping = YES;
    [self.player stop];
    self.stopping = NO;
    [self stopTicking];
    self.videoView.hidden = YES;
    [self sendState:@{ @"idle": @YES }];
}

- (void)change:(NSDictionary *)message {
    NSNumber *paused = AIONumber(message[@"paused"]);
    if (paused) {
        self.wantPaused = paused.boolValue;
        if (self.url && self.loadedSent) {
            if (paused.boolValue) [self.player pause];
            else [self.player play];
        }
    }
    // The page's volume runs from 0 to its max, 1 being full, as mpv's 100.
    NSNumber *volume = AIONumber(message[@"volume"]);
    if (volume) self.volume = volume.doubleValue;
    NSNumber *muted = AIONumber(message[@"muted"]);
    if (muted) self.muted = muted.boolValue;
    NSNumber *speed = AIONumber(message[@"speed"]);
    if (speed && speed.floatValue > 0) self.speed = speed.floatValue;
    if (volume || muted || speed) [self applyLevels];
    NSNumber *delay = AIONumber(message[@"subtitleDelayMs"]);
    if (delay) self.player.currentVideoSubTitleDelay = (NSInteger)(delay.doubleValue * 1000);

    // A key with null picks none; a missing key leaves the track as it is.
    id audio = message[@"audio"];
    if (audio == NSNull.null) self.player.currentAudioTrackIndex = -1;
    else if (AIOString(audio)) self.player.currentAudioTrackIndex = AIOString(audio).intValue;
    id subtitle = message[@"subtitle"];
    if (subtitle == NSNull.null) self.player.currentVideoSubTitleIndex = -1;
    else if (AIOString(subtitle)) self.player.currentVideoSubTitleIndex = AIOString(subtitle).intValue;
    if (audio || subtitle) [self sendTrackPicks];
}

- (void)seekTo:(int)ms {
    if (!self.url) return;
    self.seeking = YES;
    self.seekTarget = ms;
    self.seekStarted = [NSDate date];
    self.player.time = [VLCTime timeWithInt:MAX(0, ms)];
    [self sendState:@{ @"seeking": @YES, @"positionMs": @(ms) }];
}

- (void)sync {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"idle"] = @(self.url == nil);
    if (self.url) {
        state[@"paused"] = @(self.sentPaused);
        state[@"buffering"] = @(self.sentBuffering);
        int duration = self.player.media.length.intValue;
        if (duration > 0) state[@"durationMs"] = @(duration);
        state[@"positionMs"] = @(MAX(0, self.player.time.intValue));
    }
    state[@"volume"] = @(self.volume);
    state[@"maxVolume"] = @2;
    state[@"muted"] = @(self.muted);
    state[@"speed"] = @(self.speed > 0 ? self.speed : 1);
    [self sendState:state];
    self.sentTracks = nil;
    if (self.url && self.loadedSent) [self sendTracksIfChanged];
    self.send(@{ @"type": @"player-chapters", @"chapters": @[] });
}

- (void)setSkips:(id)segments {
    NSMutableArray *skips = [NSMutableArray array];
    if ([segments isKindOfClass:NSArray.class]) {
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class]) continue;
            if (![AIONumber(segment[@"auto"]) boolValue]) continue;
            NSNumber *start = AIONumber(segment[@"startMs"]);
            NSNumber *end = AIONumber(segment[@"endMs"]);
            if (start && end && end.doubleValue > start.doubleValue) [skips addObject:@{ @"start": start, @"end": end }];
        }
    }
    self.autoSkips = skips;
}

- (void)addSubtitle:(NSDictionary *)message {
    NSString *urlString = AIOString(message[@"url"]);
    NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
    if (!url || !self.url) return;
    // VLC can't drop a track it was given, so a replaced one just stays listed.
    self.subtitleIdsBeforeAdd = [NSSet setWithArray:[self idsOf:self.player.videoSubTitlesIndexes]];
    self.pendingSubtitleURL = urlString;
    self.pendingSubtitleTitle = AIOString(message[@"title"]);
    [self.player addPlaybackSlave:url type:VLCMediaPlaybackSlaveTypeSubtitle enforce:YES];
}

/** A subtitle file the user picked, sent as base64. */
- (void)addSubtitleFile:(NSDictionary *)message {
    NSString *name = AIOString(message[@"name"]) ?: @"subtitle.srt";
    NSData *data = [[NSData alloc] initWithBase64EncodedString:AIOString(message[@"data"]) ?: @""
                                                       options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!data.length || !self.url) return;
    NSString *extension = name.pathExtension.length ? name.pathExtension : @"srt";
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"%@.%@", NSUUID.UUID.UUIDString, extension]];
    if (![data writeToFile:path atomically:YES]) return;
    self.subtitleIdsBeforeAdd = [NSSet setWithArray:[self idsOf:self.player.videoSubTitlesIndexes]];
    self.pendingSubtitleURL = nil;
    self.pendingSubtitleTitle = [name substringToIndex:MIN((NSUInteger)200, name.length)];
    [self.player addPlaybackSlave:[NSURL fileURLWithPath:path] type:VLCMediaPlaybackSlaveTypeSubtitle enforce:YES];
}

- (void)pauseForBackground {
    if (self.url && self.player.isPlaying) {
        self.wantPaused = YES;
        [self.player pause];
    }
}

#pragma mark - VLC

- (void)mediaPlayerStateChanged:(NSNotification *)notification {
    if (!self.url || self.stopping) return;
    switch (self.player.state) {
        case VLCMediaPlayerStatePlaying:
            if (!self.loadedSent) [self fileLoaded];
            [self sendPaused:NO];
            break;
        case VLCMediaPlayerStatePaused:
            [self sendPaused:YES];
            break;
        case VLCMediaPlayerStateEnded:
            [self ended:@"eof" error:nil];
            break;
        case VLCMediaPlayerStateError:
            [self ended:@"error" error:@"VLC could not play this version"];
            break;
        default:
            break;
    }
}

- (void)mediaPlayerTimeChanged:(NSNotification *)notification {
    // The ticker reads the clock; this only marks it moving.
    int now = self.player.time.intValue;
    if (now != self.lastClock) {
        self.lastClock = now;
        self.clockMoved = [NSDate date];
    }
}

- (void)fileLoaded {
    self.loadedSent = YES;
    // VLC drops a volume set before its audio output opens.
    [self applyLevels];
    self.player.currentAudioPlaybackDelay = self.audioDelayUs;
    [self pickTracks];
    [self sendTracksIfChanged];
    self.send(@{ @"type": @"player-event", @"name": @"loaded" });
    self.send(@{ @"type": @"player-event", @"name": @"restart" });
    int duration = self.player.media.length.intValue;
    if (duration > 0) {
        self.sentDuration = duration;
        [self sendState:@{ @"durationMs": @(duration) }];
    }
    if (self.wantPaused) [self.player pause];
}

- (void)ended:(NSString *)reason error:(nullable NSString *)error {
    [self stopTicking];
    self.url = nil;
    self.videoView.hidden = YES;
    self.send(@{ @"type": @"player-ended", @"reason": reason, @"error": error ?: NSNull.null });
    [self sendState:@{ @"idle": @YES }];
}

#pragma mark - Reports

- (void)startTicking {
    [self.ticker invalidate];
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:kTick target:self selector:@selector(tick) userInfo:nil repeats:YES];
}

- (void)stopTicking {
    [self.ticker invalidate];
    self.ticker = nil;
}

- (void)tick {
    if (!self.url) return;
    int position = MAX(0, self.player.time.intValue);
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    if (position != self.sentPosition) {
        self.sentPosition = position;
        state[@"positionMs"] = @(position);
    }
    int duration = self.player.media.length.intValue;
    if (duration > 0 && duration != self.sentDuration) {
        self.sentDuration = duration;
        state[@"durationMs"] = @(duration);
    }

    if (self.seeking) {
        // There once the clock moves after the seek, near where it was sent.
        BOOL moved = [self.clockMoved compare:self.seekStarted] == NSOrderedDescending;
        BOOL near = abs(position - self.seekTarget) < 3000;
        BOOL arrived = near && (moved || self.sentPaused);
        BOOL gaveUp = [[NSDate date] timeIntervalSinceDate:self.seekStarted] > 10;
        if (arrived || gaveUp) {
            self.seeking = NO;
            state[@"seeking"] = @NO;
            self.send(@{ @"type": @"player-event", @"name": @"restart" });
        }
    }

    BOOL stalled = !self.sentPaused && [[NSDate date] timeIntervalSinceDate:self.clockMoved] > kStallSeconds;
    BOOL buffering = !self.loadedSent || stalled;
    if (buffering != self.sentBuffering) {
        self.sentBuffering = buffering;
        state[@"buffering"] = @(buffering);
    }

    if (state.count) [self sendState:state];
    if (self.loadedSent) {
        [self sendTracksIfChanged];
        [self skipIfInSegment:position];
    }
}

- (void)skipIfInSegment:(int)position {
    if (self.seeking) return;
    for (NSDictionary *skip in self.autoSkips) {
        double start = [skip[@"start"] doubleValue];
        double end = [skip[@"end"] doubleValue];
        if (position >= start && position < end - 500) {
            [self seekTo:(int)end];
            return;
        }
    }
}

- (void)sendPaused:(BOOL)paused {
    if (paused == self.sentPaused) return;
    self.sentPaused = paused;
    self.clockMoved = [NSDate date];
    [self sendState:@{ @"paused": @(paused) }];
}

- (void)sendState:(NSDictionary *)fields {
    NSMutableDictionary *message = [fields mutableCopy];
    message[@"type"] = @"player-state";
    self.send(message);
}

- (NSArray<NSString *> *)idsOf:(NSArray *)indexes {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSNumber *index in indexes) {
        if (![index isKindOfClass:NSNumber.class] || index.intValue < 0) continue;
        [ids addObject:index.stringValue];
    }
    return ids;
}

/** The container's language and codec for each track, by VLC's id. */
- (NSDictionary<NSString *, NSDictionary *> *)trackInfo {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    for (NSDictionary *track in self.player.media.tracksInformation) {
        NSNumber *trackId = AIONumber(track[VLCMediaTracksInformationId]);
        if (trackId) info[trackId.stringValue] = track;
    }
    return info;
}

- (NSArray<NSDictionary *> *)tracks {
    NSDictionary *info = [self trackInfo];
    NSMutableArray *tracks = [NSMutableArray array];

    // New subtitle ids since an add are the added file.
    NSArray<NSString *> *subtitleIds = [self idsOf:self.player.videoSubTitlesIndexes];
    if (self.subtitleIdsBeforeAdd) {
        for (NSString *subtitleId in subtitleIds) {
            if ([self.subtitleIdsBeforeAdd containsObject:subtitleId]) continue;
            self.external[subtitleId] = self.pendingSubtitleURL ?: @"";
            if (self.pendingSubtitleTitle) self.externalTitles[subtitleId] = self.pendingSubtitleTitle;
            self.subtitleIdsBeforeAdd = nil;
            break;
        }
    }

    NSArray *groups = @[
        @[ @"audio", self.player.audioTrackIndexes ?: @[], self.player.audioTrackNames ?: @[] ],
        @[ @"subtitle", self.player.videoSubTitlesIndexes ?: @[], self.player.videoSubTitlesNames ?: @[] ],
    ];
    for (NSArray *group in groups) {
        NSString *type = group[0];
        NSArray *indexes = group[1];
        NSArray *names = group[2];
        for (NSUInteger i = 0; i < indexes.count; i++) {
            NSNumber *index = indexes[i];
            if (![index isKindOfClass:NSNumber.class] || index.intValue < 0) continue;
            NSString *trackId = index.stringValue;
            NSString *name = i < names.count ? AIOString(names[i]) : nil;
            NSDictionary *details = info[trackId];
            NSString *language = AIOString(details[VLCMediaTracksInformationLanguage]);
            BOOL external = self.external[trackId] != nil;
            NSString *title = external ? (self.externalTitles[trackId] ?: name) : name;
            NSMutableDictionary *track = [@{
                @"id": trackId,
                @"type": type,
                @"default": @NO,
                @"forced": @(AIOContains(name, @"forced", NSCaseInsensitiveSearch)),
                @"hearingImpaired": @(AIOContains(name, @"SDH", 0)),
                @"visualImpaired": @NO,
                @"external": @(external),
            } mutableCopy];
            if (title.length) track[@"title"] = title;
            if (language.length) track[@"language"] = language;
            if (external && self.external[trackId].length) track[@"url"] = self.external[trackId];
            [tracks addObject:track];
        }
    }
    return tracks;
}

- (void)sendTracksIfChanged {
    NSArray *tracks = [self tracks];
    NSData *data = [NSJSONSerialization dataWithJSONObject:tracks options:0 error:nil];
    NSString *key = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if (![key isEqualToString:self.sentTracks]) {
        self.sentTracks = key;
        self.send(@{ @"type": @"player-tracks", @"tracks": tracks });
    }
    [self sendTrackPicks];
}

- (void)sendTrackPicks {
    int audioIndex = self.player.currentAudioTrackIndex;
    int subtitleIndex = self.player.currentVideoSubTitleIndex;
    NSString *audio = audioIndex >= 0 ? @(audioIndex).stringValue : @"";
    NSString *subtitle = subtitleIndex >= 0 ? @(subtitleIndex).stringValue : @"";
    if ([audio isEqualToString:self.sentAudio] && [subtitle isEqualToString:self.sentSubtitle]) return;
    self.sentAudio = audio;
    self.sentSubtitle = subtitle;
    [self sendState:@{
        @"audio": audio.length ? audio : NSNull.null,
        @"subtitle": subtitle.length ? subtitle : NSNull.null,
    }];
}

/** The page's language preferences and subtitle mode, applied as the file opens. */
- (void)pickTracks {
    NSArray<NSDictionary *> *tracks = [self tracks];
    NSString *audioLanguage = nil;

    for (NSString *wanted in self.audioLanguages) {
        NSDictionary *match = nil;
        for (NSDictionary *track in tracks) {
            if ([track[@"type"] isEqualToString:@"audio"] && AIOSameLanguage(track[@"language"], wanted)) {
                match = track;
                break;
            }
        }
        if (match) {
            self.player.currentAudioTrackIndex = [match[@"id"] intValue];
            audioLanguage = match[@"language"];
            break;
        }
    }
    if (!audioLanguage) {
        NSString *current = @(self.player.currentAudioTrackIndex).stringValue;
        for (NSDictionary *track in tracks) {
            if ([track[@"id"] isEqualToString:current] && [track[@"type"] isEqualToString:@"audio"]) audioLanguage = track[@"language"];
        }
    }

    NSDictionary *(^subtitleIn)(BOOL) = ^NSDictionary *(BOOL forcedOnly) {
        for (NSString *wanted in self.subtitleLanguages) {
            for (NSDictionary *track in tracks) {
                if (![track[@"type"] isEqualToString:@"subtitle"]) continue;
                if (forcedOnly && ![track[@"forced"] boolValue]) continue;
                if (AIOSameLanguage(track[@"language"], wanted)) return track;
            }
        }
        return nil;
    };

    BOOL audioIsWanted = NO;
    for (NSString *wanted in self.subtitleLanguages) {
        if (AIOSameLanguage(audioLanguage, wanted)) audioIsWanted = YES;
    }

    NSDictionary *subtitle = nil;
    NSString *mode = self.subtitleMode;
    if ([mode isEqualToString:@"none"]) {
        subtitle = nil;
    } else if ([mode isEqualToString:@"always"]) {
        subtitle = subtitleIn(NO);
    } else if ([mode isEqualToString:@"smart"]) {
        // Subtitles when the sound isn't in a language the user reads.
        subtitle = audioIsWanted ? subtitleIn(YES) : subtitleIn(NO);
    } else {
        subtitle = subtitleIn(YES);
    }
    self.player.currentVideoSubTitleIndex = subtitle ? [subtitle[@"id"] intValue] : -1;
}

@end
