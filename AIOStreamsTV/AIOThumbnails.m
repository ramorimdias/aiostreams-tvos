#import "AIOThumbnails.h"

#import <MPVKit/MPVKit.h>

/** Wide enough for the seek bar's picture on a 4K TV, small enough to send often. */
static const char *kScale = "scale=w=480:h=-2";
/** Gives up on a keyframe that doesn't come, so later asks still get answers. */
static const double kSeekTimeout = 8;

static void AIOThumbWakeup(void *context);

@interface AIOThumbnails ()
/** Everything below is used on `queue` only. */
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, assign) mpv_handle *mpv;
@property (nonatomic, copy, nullable) NSString *url;
@property (nonatomic, copy, nullable) NSString *folder;
/** The file is open and its first frame out of the way. */
@property (nonatomic) BOOL ready;
@property (nonatomic) BOOL failed;
@property (nonatomic) BOOL seeking;
@property (nonatomic) NSUInteger seekId;
/** Only the newest ask waits; the page asks again for what it still wants. */
@property (nonatomic, strong, nullable) NSNumber *pending;
@end

@implementation AIOThumbnails

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _queue = dispatch_queue_create("aiostreams.thumbnails", DISPATCH_QUEUE_SERIAL);
    _send = ^(NSDictionary *message) {};
    return self;
}

- (void)want:(NSString *)url headers:(NSDictionary *)headers positionMs:(NSNumber *)positionMs {
    dispatch_async(self.queue, ^{
        if (![url isEqualToString:self.url]) [self open:url headers:headers];
        if (self.failed) {
            [self answer:nil positionMs:0];
            return;
        }
        if (positionMs) {
            self.pending = positionMs;
            [self next];
        }
    });
}

- (void)stop {
    dispatch_async(self.queue, ^{
        [self close];
    });
}

#pragma mark - On `queue`

- (void)close {
    mpv_handle *mpv = self.mpv;
    self.mpv = NULL;
    if (mpv) {
        mpv_set_wakeup_callback(mpv, NULL, NULL);
        mpv_terminate_destroy(mpv);
    }
    if (self.folder) [NSFileManager.defaultManager removeItemAtPath:self.folder error:nil];
    self.folder = nil;
    self.url = nil;
    self.ready = NO;
    self.failed = NO;
    self.seeking = NO;
    self.pending = nil;
}

static void AIOThumbSet(mpv_handle *mpv, const char *name, const char *value) {
    mpv_set_option_string(mpv, name, value);
}

- (void)open:(NSString *)url headers:(NSDictionary *)headers {
    [self close];
    self.url = url;
    NSString *scheme = [NSURL URLWithString:url].scheme.lowercaseString;
    mpv_handle *mpv = ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) ? mpv_create() : NULL;
    if (!mpv) {
        self.failed = YES;
        return;
    }
    self.folder = [NSTemporaryDirectory() stringByAppendingPathComponent:
                   [@"thumbnails-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:self.folder withIntermediateDirectories:YES attributes:nil error:nil];

    // Each frame it shows is written to the folder, scaled down first.
    AIOThumbSet(mpv, "vo", "image");
    AIOThumbSet(mpv, "vo-image-format", "jpg");
    AIOThumbSet(mpv, "vo-image-jpeg-quality", "70");
    AIOThumbSet(mpv, "vo-image-outdir", self.folder.UTF8String);
    AIOThumbSet(mpv, "vf", kScale);
    AIOThumbSet(mpv, "hwdec", "videotoolbox-copy");
    AIOThumbSet(mpv, "vd-lavc-skiploopfilter", "all");
    AIOThumbSet(mpv, "vd-lavc-fast", "yes");
    // Only the picture, held still, landing on keyframes.
    AIOThumbSet(mpv, "ao", "null");
    AIOThumbSet(mpv, "aid", "no");
    AIOThumbSet(mpv, "sid", "no");
    AIOThumbSet(mpv, "sub-auto", "no");
    AIOThumbSet(mpv, "audio-file-auto", "no");
    AIOThumbSet(mpv, "pause", "yes");
    AIOThumbSet(mpv, "keep-open", "always");
    AIOThumbSet(mpv, "hr-seek", "no");
    AIOThumbSet(mpv, "idle", "yes");
    AIOThumbSet(mpv, "config", "no");
    AIOThumbSet(mpv, "terminal", "no");
    AIOThumbSet(mpv, "ytdl", "no");
    AIOThumbSet(mpv, "osc", "no");
    AIOThumbSet(mpv, "load-scripts", "no");
    AIOThumbSet(mpv, "input-default-bindings", "no");
    // A little cache: it reads only around each keyframe, beside the player's own reading.
    AIOThumbSet(mpv, "demuxer-max-bytes", "16MiB");
    AIOThumbSet(mpv, "demuxer-max-back-bytes", "4MiB");
    AIOThumbSet(mpv, "demuxer-readahead-secs", "1");
    AIOThumbSet(mpv, "stream-lavf-o", "reconnect=1,reconnect_delay_max=5");
    if (mpv_initialize(mpv) < 0) {
        mpv_terminate_destroy(mpv);
        self.failed = YES;
        return;
    }
    self.mpv = mpv;
    mpv_set_wakeup_callback(mpv, AIOThumbWakeup, (__bridge void *)self);

    NSMutableArray *fields = [NSMutableArray array];
    if ([headers isKindOfClass:NSDictionary.class]) {
        for (NSString *name in headers) {
            NSString *value = [headers[name] isKindOfClass:NSString.class] ? headers[name] : nil;
            if (!value || [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":,\r\n"]].location != NSNotFound ||
                [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound || [value hasSuffix:@"\\"]) continue;
            [fields addObject:[NSString stringWithFormat:@"%@: %@", name, [value stringByReplacingOccurrencesOfString:@"," withString:@"\\,"]]];
        }
    }
    NSString *options = @"";
    if (fields.count) {
        NSString *joined = [fields componentsJoinedByString:@","];
        options = [NSString stringWithFormat:@"http-header-fields=%%%lu%%%@",
                   (unsigned long)[joined lengthOfBytesUsingEncoding:NSUTF8StringEncoding], joined];
    }
    const char *args[] = { "loadfile", url.UTF8String, "replace", "-1", options.UTF8String, NULL };
    if (mpv_command(mpv, args) < 0) self.failed = YES;
}

static void AIOThumbWakeup(void *context) {
    AIOThumbnails *thumbnails = (__bridge AIOThumbnails *)context;
    dispatch_async(thumbnails.queue, ^{
        [thumbnails drain];
    });
}

- (void)drain {
    while (self.mpv) {
        mpv_event *event = mpv_wait_event(self.mpv, 0);
        if (event->event_id == MPV_EVENT_NONE) break;
        switch (event->event_id) {
            case MPV_EVENT_PLAYBACK_RESTART:
                [self restarted];
                break;
            case MPV_EVENT_END_FILE: {
                mpv_event_end_file *end = event->data;
                if (end->reason == MPV_END_FILE_REASON_ERROR) {
                    self.failed = YES;
                    self.seeking = NO;
                    self.pending = nil;
                    // The page stops asking once told the file has none.
                    [self answer:nil positionMs:0];
                }
                break;
            }
            default:
                break;
        }
    }
}

- (void)restarted {
    if (!self.ready) {
        // The file's first frame, before anything was asked; cleared once written.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), self.queue, ^{
            [self clearFolder];
            self.ready = YES;
            [self next];
        });
        return;
    }
    if (!self.seeking) return;
    [self capture:self.seekId tries:25];
}

- (void)next {
    if (!self.mpv || !self.ready || self.seeking || !self.pending || self.failed) return;
    double ms = self.pending.doubleValue;
    self.pending = nil;
    self.seeking = YES;
    NSUInteger seekId = ++self.seekId;
    [self clearFolder];
    NSString *seconds = [NSString stringWithFormat:@"%.3f", MAX(0, ms) / 1000.0];
    const char *args[] = { "seek", seconds.UTF8String, "absolute+keyframes", NULL };
    if (mpv_command(self.mpv, args) < 0) {
        self.seeking = NO;
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSeekTimeout * NSEC_PER_SEC)), self.queue, ^{
        if (self.seeking && self.seekId == seekId) {
            self.seeking = NO;
            [self next];
        }
    });
}

/** The frame the seek landed on, once the picture is written out. */
- (void)capture:(NSUInteger)seekId tries:(int)tries {
    if (!self.seeking || self.seekId != seekId || !self.mpv) return;
    NSString *file = [self newestPicture];
    if (!file) {
        if (tries > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), self.queue, ^{
                [self capture:seekId tries:tries - 1];
            });
        } else {
            self.seeking = NO;
            [self next];
        }
        return;
    }
    // A moment more, in case the writer hasn't finished the file.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), self.queue, ^{
        if (self.seekId != seekId) return;
        NSData *jpeg = [NSData dataWithContentsOfFile:file];
        double position = 0;
        mpv_get_property(self.mpv, "time-pos", MPV_FORMAT_DOUBLE, &position);
        [self clearFolder];
        self.seeking = NO;
        if (jpeg.length) {
            NSString *src = [@"data:image/jpeg;base64," stringByAppendingString:[jpeg base64EncodedStringWithOptions:0]];
            [self answer:src positionMs:position * 1000];
        }
        [self next];
    });
}

- (nullable NSString *)newestPicture {
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil]
                      sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names.reverseObjectEnumerator) {
        if ([name.pathExtension isEqualToString:@"jpg"]) return [self.folder stringByAppendingPathComponent:name];
    }
    return nil;
}

- (void)clearFolder {
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.folder error:nil]) {
        [NSFileManager.defaultManager removeItemAtPath:[self.folder stringByAppendingPathComponent:name] error:nil];
    }
}

/** A picture of the keyframe at `positionMs`, or with no `src`, word that the file has none. */
- (void)answer:(nullable NSString *)src positionMs:(double)positionMs {
    NSMutableDictionary *message = [@{ @"type": @"player-thumbnail", @"url": self.url ?: @"", @"src": src ?: NSNull.null } mutableCopy];
    if (src) message[@"positionMs"] = @(positionMs);
    void (^send)(NSDictionary *) = self.send;
    dispatch_async(dispatch_get_main_queue(), ^{
        send(message);
    });
}

@end
