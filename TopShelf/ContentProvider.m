#import <TVServices/TVServices.h>

#import "AIOShared.h"

/**
 * The Top Shelf while AIOStreams is in the top row: the page's Continue
 * Watching and Next Up, each with its backdrop, as a full-screen carousel.
 * Play starts it; select opens its page. With nothing saved yet, tvOS shows
 * the app's own Top Shelf image.
 */
@interface ContentProvider : TVTopShelfContentProvider
@end

/** The page asks for small landscape art; the shelf fills the screen. */
static NSURL *AIOWideImage(NSString *url, NSUInteger width) {
    if (url.length == 0) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:url];
    if (!parts) return nil;
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray array];
    BOOL sized = NO;
    for (NSURLQueryItem *item in parts.queryItems) {
        if ([item.name caseInsensitiveCompare:@"maxWidth"] == NSOrderedSame) {
            [query addObject:[NSURLQueryItem queryItemWithName:item.name value:@(width).stringValue]];
            sized = YES;
        } else {
            [query addObject:item];
        }
    }
    if (sized) parts.queryItems = query;
    return parts.URL;
}

/** An `aiostreams://play/…` link's item page instead, which select opens. */
static NSURL *AIOItemLink(NSString *itemId, NSString *playLink) {
    NSURLComponents *play = [NSURLComponents componentsWithString:playLink ?: @""];
    NSString *server = nil;
    for (NSURLQueryItem *item in play.queryItems) {
        if ([item.name isEqualToString:@"server"]) server = item.value;
    }
    NSURLComponents *link = [NSURLComponents new];
    link.scheme = @"aiostreams";
    link.host = @"item";
    link.path = [@"/" stringByAppendingString:itemId];
    if (server) link.queryItems = @[ [NSURLQueryItem queryItemWithName:@"server" value:server] ];
    return link.URL;
}

@implementation ContentProvider

- (void)loadTopShelfContentWithCompletionHandler:(void (^)(id<TVTopShelfContent> _Nullable))completionHandler {
    NSMutableArray<TVTopShelfCarouselItem *> *items = [NSMutableArray array];
    for (NSDictionary *saved in [AIOShared watchNext]) {
        NSString *itemId = [saved[@"id"] isKindOfClass:NSString.class] ? saved[@"id"] : nil;
        NSString *link = [saved[@"link"] isKindOfClass:NSString.class] ? saved[@"link"] : nil;
        NSString *title = [saved[@"title"] isKindOfClass:NSString.class] ? saved[@"title"] : nil;
        if (!itemId || !link || !title) continue;

        TVTopShelfCarouselItem *item = [[TVTopShelfCarouselItem alloc] initWithIdentifier:itemId];
        NSNumber *season = [saved[@"season"] isKindOfClass:NSNumber.class] ? saved[@"season"] : nil;
        NSNumber *episode = [saved[@"episode"] isKindOfClass:NSNumber.class] ? saved[@"episode"] : nil;
        NSString *episodeTitle = [saved[@"episodeTitle"] isKindOfClass:NSString.class] ? saved[@"episodeTitle"] : nil;
        if (season && episode) {
            item.title = [NSString stringWithFormat:@"%@ · S%@E%@%@", title, season, episode,
                          episodeTitle.length ? [@" · " stringByAppendingString:episodeTitle] : @""];
        } else {
            item.title = title;
        }
        if ([saved[@"description"] isKindOfClass:NSString.class]) item.summary = saved[@"description"];

        double position = [saved[@"positionMs"] doubleValue];
        double duration = [saved[@"durationMs"] doubleValue];
        // The carousel has no progress bar, so the time left goes in its label.
        if (duration > 0) item.duration = duration / 1000;
        if (position > 0 && duration > position) {
            long minutes = lround((duration - position) / 60000);
            item.contextTitle = minutes > 0
                ? [NSString stringWithFormat:@"Continue Watching · %ld min left", minutes]
                : @"Continue Watching";
        } else {
            item.contextTitle = position > 0 ? @"Continue Watching" : @"Next Up";
        }

        NSString *image = [saved[@"image"] isKindOfClass:NSString.class] ? saved[@"image"] : nil;
        NSURL *small = AIOWideImage(image, 1920);
        NSURL *large = AIOWideImage(image, 3840);
        if (small) [item setImageURL:small forTraits:TVTopShelfItemImageTraitScreenScale1x];
        if (large) [item setImageURL:large forTraits:TVTopShelfItemImageTraitScreenScale2x];

        NSURL *play = [NSURL URLWithString:link];
        if (play) item.playAction = [[TVTopShelfAction alloc] initWithURL:play];
        NSURL *open = AIOItemLink(itemId, link);
        if (open) item.displayAction = [[TVTopShelfAction alloc] initWithURL:open];
        [items addObject:item];
    }
    if (!items.count) {
        completionHandler(nil);
        return;
    }
    completionHandler([[TVTopShelfCarouselContent alloc] initWithStyle:TVTopShelfCarouselContentStyleActions
                                                                 items:items]);
}

@end
