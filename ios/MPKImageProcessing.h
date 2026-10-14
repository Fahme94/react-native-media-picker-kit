#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Resizing, re-encoding and compressing still images, and reading what they carry.
@interface MPKImageProcessing : NSObject

/// Applies maxWidth/maxHeight/quality/forceJpg. Returns the file to report --
/// the original when no work was needed -- and updates `mime` to match it.
+ (NSString *)processImageAtPath:(NSString *)path
                         options:(NSDictionary *)options
                            mime:(NSString *_Nonnull *_Nonnull)mime;

/// Re-encode until the file fits. Returns the original when it already fits or
/// is under `minBytes`, nil when even the smallest acceptable encode overflows.
+ (nullable NSString *)compressImageAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes;

+ (UIImage *)image:(UIImage *)image scaledToMaxWidth:(CGFloat)maxWidth maxHeight:(CGFloat)maxHeight;

/// Unconditional resize to an exact pixel size, used for aspect-locked crops
/// where the caller asked for a specific output size.
+ (UIImage *)image:(UIImage *)image resizedExactlyToWidth:(CGFloat)width height:(CGFloat)height;

+ (CGSize)dimensionsAtPath:(NSString *)path;
+ (nullable NSDictionary *)exifAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
