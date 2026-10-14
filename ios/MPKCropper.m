#import "MPKCropper.h"

#import "MPKImageProcessing.h"

@implementation MPKCropper

+ (TOCropViewController *)cropperForImage:(UIImage *)image options:(NSDictionary *)options
{
  BOOL circle = [options[@"cropperCircleOverlay"] boolValue];
  BOOL freeStyle = [options[@"freeStyleCropEnabled"] boolValue];
  CGFloat cropWidth = [options[@"cropWidth"] floatValue];
  CGFloat cropHeight = [options[@"cropHeight"] floatValue];

  TOCropViewCroppingStyle style =
      circle ? TOCropViewCroppingStyleCircular : TOCropViewCroppingStyleDefault;
  TOCropViewController *cropper = [[TOCropViewController alloc] initWithCroppingStyle:style
                                                                                image:image];
  cropper.title = options[@"cropperToolbarTitle"];
  cropper.doneButtonTitle = options[@"cropperChooseText"];
  cropper.cancelButtonTitle = options[@"cropperCancelText"];
  cropper.aspectRatioPickerButtonHidden = YES;

  if (cropWidth > 0 && cropHeight > 0) {
    cropper.customAspectRatio = CGSizeMake(cropWidth, cropHeight);
    cropper.aspectRatioLockEnabled = !freeStyle;
    cropper.resetAspectRatioEnabled = freeStyle;
  }
  return cropper;
}

+ (UIImage *)outputForCrop:(UIImage *)image options:(NSDictionary *)options
{
  CGFloat cropWidth = [options[@"cropWidth"] floatValue];
  CGFloat cropHeight = [options[@"cropHeight"] floatValue];
  if (cropWidth <= 0 || cropHeight <= 0) return image;

  return [options[@"freeStyleCropEnabled"] boolValue]
      ? [MPKImageProcessing image:image scaledToMaxWidth:cropWidth maxHeight:cropHeight]
      : [MPKImageProcessing image:image resizedExactlyToWidth:cropWidth height:cropHeight];
}

@end
