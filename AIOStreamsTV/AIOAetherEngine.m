#import "AIOAetherEngine.h"

@import AIOAether;

@interface AIOAetherEngine ()
@property (nonatomic, strong) AIOAetherPlayer *player;
@end

@implementation AIOAetherEngine
@synthesize send = _send;

- (instancetype)initWithHost:(UIView *)host {
    self = [super init];
    if (!self) return nil;
    _send = ^(NSDictionary *message) {};
    _player = [[AIOAetherPlayer alloc] initWithHost:host];
    __weak typeof(self) weakSelf = self;
    _player.send = ^(NSDictionary<NSString *, id> *message) {
        AIOAetherEngine *engine = weakSelf;
        if (engine) engine.send(message);
    };
    return self;
}

+ (NSString *)version {
    return AIOAetherPlayer.engineVersion;
}

- (BOOL)handle:(NSString *)type message:(NSDictionary *)message {
    return [self.player handle:type message:message];
}

- (void)pauseForBackground {
    [self.player pauseForBackground];
}

- (void)shutdown {
    [self.player shutdown];
}

@end
