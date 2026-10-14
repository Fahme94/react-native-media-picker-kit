#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Reading video metadata, and transcoding a clip down to a byte budget.
@interface MPKVideoProcessing : NSObject

/// Dimensions, duration and bitrate of a movie on disk, in the shape the Asset
/// contract expects.
+ (NSDictionary *)metadataAtPath:(NSString *)path;

/// Re-encode to H.264/AAC at a bitrate the clip's own duration can afford.
/// Returns the original untouched when it already fits, is under `minBytes`, or
/// `isCancelled` turns true part-way; nil when even the floor bitrate cannot get
/// under the budget.
+ (nullable NSString *)compressVideoAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes
                                  progress:(nullable void (^)(double))progress
                               isCancelled:(BOOL (^)(void))isCancelled;

/// Rewrap a clip as MP4 without re-encoding it. iOS records and exports
/// QuickTime, which most upload services refuse even though the H.264/HEVC and
/// AAC tracks inside it are exactly what MP4 carries. Returns the original when
/// it already is MP4, or when its tracks cannot go into an MP4 container.
+ (NSString *)mp4AtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
