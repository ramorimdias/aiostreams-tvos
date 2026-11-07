#import "AIOYouTube.h"

/** One of YouTube's own apps, as the player API is asked by it. */
@interface AIOYouTubeClient : NSObject
@property (nonatomic, copy) NSString *name, *clientID, *version, *userAgent;
@property (nonatomic, copy, nullable) NSString *key;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *fields;
/** Answers with an HLS playlist, rather than a single file. */
@property (nonatomic) BOOL hls;
@end

@implementation AIOYouTubeClient
@end

@implementation AIOYouTube

+ (NSArray<AIOYouTubeClient *> *)clients {
    static NSArray *clients;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AIOYouTubeClient *vision = [AIOYouTubeClient new];
        vision.name = @"VISIONOS";
        vision.clientID = @"101";
        vision.version = @"1.02";
        vision.userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                           @"Version/26.0 Safari/605.1.15";
        vision.fields = @{ @"deviceMake": @"Apple", @"deviceModel": @"RealityDevice17,1",
                           @"osName": @"visionOS", @"osVersion": @"26.5.23O471" };
        vision.hls = YES;

        AIOYouTubeClient *android = [AIOYouTubeClient new];
        android.name = @"ANDROID";
        android.clientID = @"3";
        android.version = @"20.10.41";
        android.userAgent = @"com.google.android.youtube/20.10.41 (Linux; U; Android 11) gzip";
        android.key = @"AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w";
        android.fields = @{ @"deviceMake": @"Google", @"deviceModel": @"Pixel 5", @"osName": @"Android",
                            @"osVersion": @"11", @"androidSdkVersion": @"30", @"platform": @"MOBILE" };
        android.hls = NO;
        clients = @[ vision, android ];
    });
    return clients;
}

+ (void)resolve:(NSString *)videoID completion:(void (^)(NSString *_Nullable))completion {
    NSRegularExpression *valid = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_-]{11}$" options:0 error:nil];
    if (![valid firstMatchInString:videoID options:0 range:NSMakeRange(0, videoID.length)]) {
        completion(nil);
        return;
    }
    [self tryClient:0 video:videoID visitor:nil attempt:0 completion:^(NSString *url) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(url);
        });
    }];
}

/** Each client in turn; each asked twice, the second time as the visitor YouTube named. */
+ (void)tryClient:(NSUInteger)index
            video:(NSString *)videoID
          visitor:(nullable NSString *)visitor
          attempt:(NSUInteger)attempt
       completion:(void (^)(NSString *_Nullable))completion {
    NSArray<AIOYouTubeClient *> *clients = self.clients;
    if (index >= clients.count) {
        completion(nil);
        return;
    }
    AIOYouTubeClient *client = clients[index];
    void (^next)(void) = ^{
        [self tryClient:index + 1 video:videoID visitor:nil attempt:0 completion:completion];
    };
    [self ask:client video:videoID visitor:visitor completion:^(NSDictionary *answer) {
        if (!answer) {
            next();
            return;
        }
        NSDictionary *status = [answer[@"playabilityStatus"] isKindOfClass:NSDictionary.class] ? answer[@"playabilityStatus"] : nil;
        NSDictionary *streaming = [answer[@"streamingData"] isKindOfClass:NSDictionary.class] ? answer[@"streamingData"] : nil;
        if ([status[@"status"] isEqual:@"OK"] && streaming) {
            NSString *url = nil;
            if (client.hls) {
                url = [streaming[@"hlsManifestUrl"] isKindOfClass:NSString.class] ? streaming[@"hlsManifestUrl"] : nil;
            } else {
                for (NSDictionary *format in [streaming[@"formats"] isKindOfClass:NSArray.class] ? streaming[@"formats"] : @[]) {
                    if ([format isKindOfClass:NSDictionary.class] && [format[@"url"] isKindOfClass:NSString.class]) {
                        url = format[@"url"];
                        break;
                    }
                }
            }
            if (url) {
                completion(url);
            } else {
                next();
            }
            return;
        }
        NSDictionary *context = [answer[@"responseContext"] isKindOfClass:NSDictionary.class] ? answer[@"responseContext"] : nil;
        NSString *named = [context[@"visitorData"] isKindOfClass:NSString.class] ? context[@"visitorData"] : nil;
        if (named && attempt == 0) {
            [self tryClient:index video:videoID visitor:named attempt:1 completion:completion];
        } else {
            NSLog(@"[youtube] %@: %@", client.name, status[@"status"] ?: @"no answer");
            next();
        }
    }];
}

+ (void)ask:(AIOYouTubeClient *)client
      video:(NSString *)videoID
    visitor:(nullable NSString *)visitor
 completion:(void (^)(NSDictionary *_Nullable))completion {
    NSMutableDictionary *about = [@{ @"clientName": client.name, @"clientVersion": client.version,
                                     @"hl": @"en", @"gl": @"US" } mutableCopy];
    if (visitor) about[@"visitorData"] = visitor;
    [about addEntriesFromDictionary:client.fields];
    NSDictionary *body = @{ @"videoId": videoID, @"context": @{ @"client": about },
                            @"contentCheckOk": @YES, @"racyCheckOk": @YES };

    NSString *address = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/player?%@prettyPrint=false",
                                                   client.key ? [NSString stringWithFormat:@"key=%@&", client.key] : @""];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    request.timeoutInterval = 8;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:client.userAgent forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.youtube.com/" forHTTPHeaderField:@"Referer"];
    [request setValue:client.clientID forHTTPHeaderField:@"X-YouTube-Client-Name"];
    [request setValue:client.version forHTTPHeaderField:@"X-YouTube-Client-Version"];
    if (visitor) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];

    [[NSURLSession.sharedSession dataTaskWithRequest:request
                                   completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error || code < 200 || code >= 300 || !data) {
            NSLog(@"[youtube] %@: %@", client.name, error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]);
            completion(nil);
            return;
        }
        id answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        completion([answer isKindOfClass:NSDictionary.class] ? answer : nil);
    }] resume];
}

@end
