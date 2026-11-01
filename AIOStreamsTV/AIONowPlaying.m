#import "AIONowPlaying.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

/** Siri's and the iPhone remote's skip, when they don't say how far. */
static const double kSkipSeconds = 10;

@interface AIONowPlaying ()
@property (nonatomic, copy, nullable) NSDictionary *item;
@property (nonatomic, strong) NSMutableDictionary *info;
@property (nonatomic) double positionMs;
@property (nonatomic) double durationMs;
@property (nonatomic) BOOL paused;
@property (nonatomic) BOOL commandsOn;
/** Elapsed time is told to tvOS on changes, not every report: it counts on from the rate. */
@property (nonatomic) CFTimeInterval toldAt;
@property (nonatomic, copy, nullable) NSString *artworkURL;
@end

@implementation AIONowPlaying

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _send = ^(NSDictionary *message) {};
    _info = [NSMutableDictionary dictionary];
    _paused = YES;
    return self;
}

- (void)setItem:(NSDictionary *)item {
    if (![item isKindOfClass:NSDictionary.class] || ![item[@"title"] isKindOfClass:NSString.class]) {
        _item = nil;
        self.positionMs = 0;
        self.durationMs = 0;
        self.artworkURL = nil;
        [self.info removeAllObjects];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
        [self enableCommands:NO];
        return;
    }
    _item = [item copy];
    self.info[MPMediaItemPropertyTitle] = item[@"title"];
    NSString *subtitle = [item[@"subtitle"] isKindOfClass:NSString.class] ? item[@"subtitle"] : nil;
    if (subtitle.length) self.info[MPMediaItemPropertyArtist] = subtitle;
    else [self.info removeObjectForKey:MPMediaItemPropertyArtist];
    self.info[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeVideo);
    [self enableCommands:YES];
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    center.nextTrackCommand.enabled = [item[@"next"] boolValue];
    center.previousTrackCommand.enabled = [item[@"previous"] boolValue];
    [self loadArtwork:[item[@"artwork"] isKindOfClass:NSString.class] ? item[@"artwork"] : nil];
    [self publish];
}

- (void)playerState:(NSDictionary *)state {
    if (!self.item) return;
    BOOL jumped = NO;
    if ([state[@"durationMs"] isKindOfClass:NSNumber.class]) self.durationMs = [state[@"durationMs"] doubleValue];
    if ([state[@"positionMs"] isKindOfClass:NSNumber.class]) {
        double position = [state[@"positionMs"] doubleValue];
        // A seek, rather than playing on, is worth telling at once.
        jumped = fabs(position - self.positionMs) > 2000;
        self.positionMs = position;
    }
    BOOL pauseChanged = NO;
    if ([state[@"paused"] isKindOfClass:NSNumber.class] && [state[@"paused"] boolValue] != self.paused) {
        self.paused = [state[@"paused"] boolValue];
        pauseChanged = YES;
    }
    if (pauseChanged || jumped || CACurrentMediaTime() - self.toldAt > 15) [self publish];
}

- (void)publish {
    if (!self.item) return;
    self.info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.positionMs / 1000);
    if (self.durationMs > 0) self.info[MPMediaItemPropertyPlaybackDuration] = @(self.durationMs / 1000);
    self.info[MPNowPlayingInfoPropertyPlaybackRate] = @(self.paused ? 0 : 1);
    self.info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = @1;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = self.info;
    self.toldAt = CACurrentMediaTime();
}

- (void)loadArtwork:(nullable NSString *)url {
    if ([url isEqualToString:self.artworkURL]) return;
    self.artworkURL = url;
    [self.info removeObjectForKey:MPMediaItemPropertyArtwork];
    NSURL *address = url ? [NSURL URLWithString:url] : nil;
    if (!address) return;
    [[NSURLSession.sharedSession dataTaskWithURL:address completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.artworkURL isEqualToString:url]) return;
            self.info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc]
                initWithBoundsSize:image.size
                    requestHandler:^UIImage *(CGSize size) { return image; }];
            [self publish];
        });
    }] resume];
}

#pragma mark - Commands

- (void)press:(NSDictionary *)key {
    self.send(@{ @"type": @"media-key", @"key": key });
}

- (void)enableCommands:(BOOL)on {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    if (on && !self.commandsOn) {
        self.commandsOn = YES;
        __weak typeof(self) weakSelf = self;
        [center.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"play" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"pause" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"toggle" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"stop" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"next" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            [weakSelf press:@{ @"action": @"previous" }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        center.skipForwardCommand.preferredIntervals = @[ @(kSkipSeconds) ];
        [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            double seconds = [event isKindOfClass:MPSkipIntervalCommandEvent.class]
                ? ((MPSkipIntervalCommandEvent *)event).interval : kSkipSeconds;
            [weakSelf press:@{ @"action": @"skip", @"offset": @(seconds * 1000) }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        center.skipBackwardCommand.preferredIntervals = @[ @(kSkipSeconds) ];
        [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            double seconds = [event isKindOfClass:MPSkipIntervalCommandEvent.class]
                ? ((MPSkipIntervalCommandEvent *)event).interval : kSkipSeconds;
            [weakSelf press:@{ @"action": @"skip", @"offset": @(-seconds * 1000) }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [center.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            if (![event isKindOfClass:MPChangePlaybackPositionCommandEvent.class]) return MPRemoteCommandHandlerStatusCommandFailed;
            double seconds = ((MPChangePlaybackPositionCommandEvent *)event).positionTime;
            [weakSelf press:@{ @"action": @"seek", @"position": @(seconds * 1000) }];
            return MPRemoteCommandHandlerStatusSuccess;
        }];
    } else if (!on && self.commandsOn) {
        self.commandsOn = NO;
        for (MPRemoteCommand *command in @[ center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                                            center.stopCommand, center.nextTrackCommand, center.previousTrackCommand,
                                            center.skipForwardCommand, center.skipBackwardCommand,
                                            center.changePlaybackPositionCommand ]) {
            [command removeTarget:nil];
        }
    }
    for (MPRemoteCommand *command in @[ center.playCommand, center.pauseCommand, center.togglePlayPauseCommand,
                                        center.stopCommand, center.skipForwardCommand, center.skipBackwardCommand,
                                        center.changePlaybackPositionCommand ]) {
        command.enabled = on;
    }
}

@end
