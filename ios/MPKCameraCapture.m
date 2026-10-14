#import "MPKCameraCapture.h"

#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "MPKResults.h"

@implementation MPKCameraCapture

+ (NSString *)wantedTypeForOptions:(NSDictionary *)options
{
  return [options[@"mediaType"] isEqualToString:@"video"] ? UTTypeMovie.identifier
                                                          : UTTypeImage.identifier;
}

+ (nullable NSDictionary *)unavailableResultForOptions:(NSDictionary *)options
{
  if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    return [MPKResults errorWithCode:MPKErrorCameraUnavailable
                             message:@"This device has no camera available"];
  }

  // UIImagePickerController raises its own permission prompt, but a previously
  // denied app would just get a black viewfinder. Failing up front turns that
  // into a result the caller can act on.
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
    return [MPKResults errorWithCode:MPKErrorPermission message:@"Camera access is not permitted"];
  }

  // A camera that exists does not necessarily record video. Assigning a
  // mediaTypes value the source cannot supply leaves the controller unable to
  // present, and the promise would then never settle at all.
  NSArray<NSString *> *availableTypes =
      [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  if (![availableTypes containsObject:[self wantedTypeForOptions:options]]) {
    BOOL isVideo = [options[@"mediaType"] isEqualToString:@"video"];
    return [MPKResults errorWithCode:MPKErrorCameraUnavailable
                             message:isVideo ? @"This camera cannot record video"
                                             : @"This camera cannot take photos"];
  }
  return nil;
}

+ (UIImagePickerController *)cameraForOptions:(NSDictionary *)options
{
  UIImagePickerController *camera = [[UIImagePickerController alloc] init];
  camera.sourceType = UIImagePickerControllerSourceTypeCamera;
  camera.mediaTypes = @[[self wantedTypeForOptions:options]];

  if ([options[@"cameraType"] isEqualToString:@"front"] &&
      [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront]) {
    camera.cameraDevice = UIImagePickerControllerCameraDeviceFront;
  }

  if ([options[@"mediaType"] isEqualToString:@"video"]) {
    NSTimeInterval limit = [options[@"durationLimit"] doubleValue];
    if (limit > 0) camera.videoMaximumDuration = limit;
    camera.videoQuality = [options[@"videoQuality"] isEqualToString:@"low"]
        ? UIImagePickerControllerQualityTypeLow
        : UIImagePickerControllerQualityTypeHigh;
  }
  return camera;
}

@end
