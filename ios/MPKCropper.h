#import <TOCropViewController/TOCropViewController.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The crop screen, and sizing what it hands back.
@interface MPKCropper : NSObject

+ (TOCropViewController *)cropperForImage:(UIImage *)image options:(NSDictionary *)options;

/// TOCropViewController only crops; it has no notion of an output size, so
/// cropWidth/cropHeight would otherwise mean "aspect ratio" here and "exact
/// output size" on Android. Match Android: an aspect-locked crop resizes
/// exactly, a free-form one fits inside without stretching.
+ (UIImage *)outputForCrop:(UIImage *)image options:(NSDictionary *)options;

@end

NS_ASSUME_NONNULL_END
