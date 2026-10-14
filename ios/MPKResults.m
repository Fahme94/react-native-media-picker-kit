#import "MPKResults.h"

#import "MPKImageProcessing.h"
#import "MPKMediaFiles.h"

NSString *const MPKErrorPermission = @"permission";
NSString *const MPKErrorCannotProcessAsset = @"cannot_process_asset";
NSString *const MPKErrorCropFailed = @"crop_failed";
NSString *const MPKErrorCompressFailed = @"compress_failed";
NSString *const MPKErrorCameraUnavailable = @"camera_unavailable";
NSString *const MPKErrorInvalidOptions = @"invalid_options";
NSString *const MPKErrorPickerBusy = @"picker_busy";
NSString *const MPKErrorOthers = @"others";

@implementation MPKResults

+ (NSDictionary *)cancelled
{
  return @{@"didCancel": @YES, @"assets": @[]};
}

+ (NSDictionary *)errorWithCode:(NSString *)code message:(nullable NSString *)message
{
  return @{@"didCancel": @NO, @"errorCode": code, @"errorMessage": message ?: @"", @"assets": @[]};
}

+ (NSDictionary *)successWithAssets:(NSArray<NSDictionary *> *)assets
                         deselected:(nullable NSArray<NSString *> *)deselected
{
  if (deselected == nil) return @{@"didCancel": @NO, @"assets": assets};
  return @{@"didCancel": @NO, @"assets": assets, @"deselected": deselected};
}

+ (NSMutableDictionary *)assetForPath:(NSString *)path
                             fileName:(NSString *)fileName
                                 mime:(NSString *)mime
                              options:(NSDictionary *)options
                      assetIdentifier:(nullable NSString *)assetIdentifier
                                extra:(nullable NSDictionary *)extra
{
  NSMutableDictionary *asset = [NSMutableDictionary dictionary];
  BOOL writeTempFile = options[@"writeTempFile"] == nil || [options[@"writeTempFile"] boolValue];

  asset[@"fileName"] = fileName;
  asset[@"fileSize"] = @([MPKMediaFiles fileSizeAtPath:path]);
  asset[@"type"] = mime;

  if (extra != nil) {
    [asset addEntriesFromDictionary:extra];
  } else {
    CGSize dimensions = [MPKImageProcessing dimensionsAtPath:path];
    asset[@"width"] = @(dimensions.width);
    asset[@"height"] = @(dimensions.height);
    if ([options[@"includeExif"] boolValue]) {
      NSDictionary *exif = [MPKImageProcessing exifAtPath:path];
      if (exif) asset[@"exif"] = exif;
    }
    if ([options[@"includeBase64"] boolValue]) {
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (data) asset[@"base64"] = [data base64EncodedStringWithOptions:0];
    }
  }

  if (assetIdentifier != nil) {
    asset[@"originalPath"] = assetIdentifier;
    if ([options[@"includeExtra"] boolValue]) asset[@"id"] = assetIdentifier;
  }

  if (writeTempFile) {
    asset[@"uri"] = [@"file://" stringByAppendingString:path];
  } else {
    [MPKMediaFiles removeIfTemporary:path];
    asset[@"uri"] = [NSNull null];
  }

  return asset;
}

@end
