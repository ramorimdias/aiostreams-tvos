#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * A YouTube video's stream for a trailer, asked of YouTube's player API as
 * AIOStreams' Android app (YouTube.kt) and desktop app (youtube.rs) ask it.
 */
@interface AIOYouTube : NSObject

/** Answers on the main queue with the stream's address, or nil. */
+ (void)resolve:(NSString *)videoID completion:(void (^)(NSString *_Nullable url))completion;

@end

NS_ASSUME_NONNULL_END
