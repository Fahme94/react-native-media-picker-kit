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

@end

NS_ASSUME_NONNULL_END
