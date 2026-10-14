#import "MPKImageProcessing.h"

#import <ImageIO/ImageIO.h>

#import "MPKMediaFiles.h"

static const CGFloat kMinJPEGQuality = 0.1;
static const CGFloat kMaxJPEGQuality = 0.95;
static const NSInteger kQualitySearchSteps = 7;
static const CGFloat kMinImageEdge = 64.0;

@implementation MPKImageProcessing

+ (NSString *)processImageAtPath:(NSString *)path
                         options:(NSDictionary *)options
                            mime:(NSString *_Nonnull *_Nonnull)mime
{
  BOOL forceJpg = options[@"forceJpg"] == nil || [options[@"forceJpg"] boolValue];
  CGFloat maxWidth = [options[@"maxWidth"] floatValue];
  CGFloat maxHeight = [options[@"maxHeight"] floatValue];
  CGFloat quality = options[@"quality"] ? [options[@"quality"] floatValue] : 1.0;

  BOOL needsWork = maxWidth > 0 || maxHeight > 0 || quality < 1.0 ||
      (forceJpg && ![*mime isEqualToString:@"image/jpeg"]);
  if (!needsWork) return path;

  UIImage *image = [UIImage imageWithContentsOfFile:path];
  if (image == nil) return path;
  UIImage *resized = [self image:image scaledToMaxWidth:maxWidth maxHeight:maxHeight];
  NSData *data = UIImageJPEGRepresentation(resized, quality);
  if (data == nil) return path;

  NSString *jpgPath = [MPKMediaFiles tempPathWithExtension:@"jpg"];
  if (![data writeToFile:jpgPath atomically:YES]) return path;
  [MPKMediaFiles removeIfTemporary:path];
  *mime = @"image/jpeg";
  return jpgPath;
}

/// Quality is searched first because it costs no pixels; only when even the
/// lowest quality still overflows does the image get halved and searched again.
+ (nullable NSString *)compressImageAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes
{
  unsigned long long size = [MPKMediaFiles fileSizeAtPath:path];
  if (maxBytes == 0 || size <= maxBytes) return path;
  // Over budget, but not by enough to be worth the work the caller asked us to
  // avoid. Returns a file that is still over its budget, deliberately.
  if (minBytes > 0 && size < minBytes) return path;

  UIImage *image = [UIImage imageWithContentsOfFile:path];
  if (image == nil) return path;

  NSData *encoded = nil;
  while (YES) {
    encoded = [self encodeImage:image underLimit:maxBytes];
    CGFloat shortEdge = MIN(image.size.width, image.size.height);
    if (encoded != nil || shortEdge / 2.0 < kMinImageEdge) break;
    image = [self image:image
        scaledToMaxWidth:floor(image.size.width / 2.0)
               maxHeight:floor(image.size.height / 2.0)];
  }
  if (encoded == nil) return nil;

  NSString *output = [MPKMediaFiles tempPathWithExtension:@"jpg"];
  if (![encoded writeToFile:output atomically:YES]) return nil;
  [MPKMediaFiles removeIfTemporary:path];
  return output;
}

/// Highest JPEG quality whose output still fits, or nil when even the floor does not.
+ (nullable NSData *)encodeImage:(UIImage *)image underLimit:(unsigned long long)maxBytes
{
  // The floor first: when even it overflows, no quality will fit at this size,
  // and finding that out by bisection would cost a whole search per halving.
  NSData *best = UIImageJPEGRepresentation(image, kMinJPEGQuality);
  if (best == nil || best.length > maxBytes) return nil;

  CGFloat low = kMinJPEGQuality;
  CGFloat high = kMaxJPEGQuality;
  for (NSInteger step = 0; step < kQualitySearchSteps; step++) {
    CGFloat quality = (low + high) / 2.0;
    NSData *data = UIImageJPEGRepresentation(image, quality);
    if (data == nil) break;
    if (data.length <= maxBytes) {
      best = data;
      low = quality;
    } else {
      high = quality;
    }
  }
  return best;
}

+ (UIImage *)image:(UIImage *)image resizedExactlyToWidth:(CGFloat)width height:(CGFloat)height
{
  CGSize size = CGSizeMake(floor(width), floor(height));
  if (size.width <= 0 || size.height <= 0) return image;

  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = 1.0;
  format.opaque = NO;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size
                                                                             format:format];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
  }];
}

+ (UIImage *)image:(UIImage *)image scaledToMaxWidth:(CGFloat)maxWidth maxHeight:(CGFloat)maxHeight
{
  if (maxWidth <= 0 && maxHeight <= 0) return image;
  CGFloat targetW = maxWidth > 0 ? maxWidth : image.size.width;
  CGFloat targetH = maxHeight > 0 ? maxHeight : image.size.height;
  CGFloat scale = MIN(MIN(targetW / image.size.width, targetH / image.size.height), 1.0);
  if (scale >= 1.0) return image;

  CGSize newSize = CGSizeMake(floor(image.size.width * scale), floor(image.size.height * scale));

  // UIGraphicsImageRenderer defaults to the screen's scale, so on a 3x device a
  // 400pt render produces a 1200px image and maxWidth is silently tripled.
  // Pixels are what the caller asked for, so pin the scale to 1.
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = 1.0;
  format.opaque = NO;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:newSize
                                                                             format:format];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [image drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
  }];
}

+ (CGSize)dimensionsAtPath:(NSString *)path
{
  CGImageSourceRef source =
      CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (source == NULL) return CGSizeZero;
  NSDictionary *props =
      (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
  CFRelease(source);
  return CGSizeMake([props[(NSString *)kCGImagePropertyPixelWidth] floatValue],
                    [props[(NSString *)kCGImagePropertyPixelHeight] floatValue]);
}

+ (nullable NSDictionary *)exifAtPath:(NSString *)path
{
  CGImageSourceRef source =
      CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (source == NULL) return nil;
  NSDictionary *props =
      (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
  CFRelease(source);
  return props[(NSString *)kCGImagePropertyExifDictionary] ?: props;
}

@end
