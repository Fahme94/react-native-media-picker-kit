#import "MediaPicker.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <React/RCTUtils.h>
#import <TOCropViewController/TOCropViewController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kTempDirName = @"rn_media_picker";

@interface MediaPicker () <PHPickerViewControllerDelegate,
                           TOCropViewControllerDelegate,
                           UIImagePickerControllerDelegate,
                           UINavigationControllerDelegate>
@property (nonatomic, copy, nullable) RCTPromiseResolveBlock pendingResolve;
@property (nonatomic, strong, nullable) NSDictionary *pendingOptions;
@property (nonatomic, strong, nullable) NSMutableDictionary *pendingCropAsset;
@end

@implementation MediaPicker

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup { return NO; }

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
  return std::make_shared<facebook::react::NativeMediaPickerSpecJSI>(params);
}

#pragma mark - Temp directory

- (NSString *)tempDirectory
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:kTempDirName];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
  return dir;
}

- (NSString *)tempPathWithExtension:(NSString *)ext
{
  NSString *name = [NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], ext];
  return [[self tempDirectory] stringByAppendingPathComponent:name];
}

#pragma mark - Results

- (NSDictionary *)cancelledResult
{
  return @{@"didCancel": @YES, @"assets": @[]};
}

- (NSDictionary *)errorResultWithCode:(NSString *)code message:(NSString *)message
{
  return @{@"didCancel": @NO, @"errorCode": code, @"errorMessage": message ?: @"", @"assets": @[]};
}

- (void)finishWith:(NSDictionary *)result
{
  RCTPromiseResolveBlock resolve = self.pendingResolve;
  self.pendingResolve = nil;
  self.pendingOptions = nil;
  self.pendingCropAsset = nil;
  if (resolve) resolve(result);
}

#pragma mark - JS surface

- (void)pickMedia:(NSDictionary *)options
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  if (self.pendingResolve != nil) {
    resolve([self errorResultWithCode:@"picker_busy" message:@"A picker is already open"]);
    return;
  }
  self.pendingResolve = resolve;
  self.pendingOptions = options;

  NSString *mediaType = options[@"mediaType"] ?: @"photo";
  NSInteger selectionLimit = [options[@"selectionLimit"] integerValue];
  BOOL includeExtra = [options[@"includeExtra"] boolValue];

  PHPickerConfiguration *config = includeExtra
      ? [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]]
      : [[PHPickerConfiguration alloc] init];
  config.selectionLimit = selectionLimit; // 0 means unlimited, same as PHPicker

  if ([mediaType isEqualToString:@"photo"]) {
    config.filter = [PHPickerFilter imagesFilter];
  } else if ([mediaType isEqualToString:@"video"]) {
    config.filter = [PHPickerFilter videosFilter];
  } else {
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
      [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
    ]];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.modalPresentationStyle = [self presentationStyleFrom:options[@"presentationStyle"]];
    UIViewController *presenter = RCTPresentedViewController();
    if (presenter == nil) {
      [self finishWith:[self errorResultWithCode:@"others" message:@"No view controller to present from"]];
      return;
    }
    [presenter presentViewController:picker animated:YES completion:nil];
  });
}

- (void)captureMedia:(NSDictionary *)options
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  if (self.pendingResolve != nil) {
    resolve([self errorResultWithCode:@"picker_busy" message:@"A picker is already open"]);
    return;
  }
  if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypeCamera]) {
    resolve([self errorResultWithCode:@"camera_unavailable"
                              message:@"This device has no camera available"]);
    return;
  }

  // UIImagePickerController raises its own permission prompt, but a previously
  // denied app would just get a black viewfinder. Failing up front turns that
  // into a result the caller can act on.
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  if (status == AVAuthorizationStatusDenied || status == AVAuthorizationStatusRestricted) {
    resolve([self errorResultWithCode:@"permission" message:@"Camera access is not permitted"]);
    return;
  }

  BOOL isVideo = [options[@"mediaType"] isEqualToString:@"video"];
  NSString *wantedType = isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;

  // A camera that exists does not necessarily record video. Assigning a
  // mediaTypes value the source cannot supply leaves the controller unable to
  // present, and the promise would then never settle at all.
  NSArray<NSString *> *availableTypes =
      [UIImagePickerController availableMediaTypesForSourceType:UIImagePickerControllerSourceTypeCamera];
  if (![availableTypes containsObject:wantedType]) {
    resolve([self errorResultWithCode:@"camera_unavailable"
                              message:isVideo ? @"This camera cannot record video"
                                              : @"This camera cannot take photos"]);
    return;
  }

  self.pendingResolve = resolve;
  self.pendingOptions = options;

  dispatch_async(dispatch_get_main_queue(), ^{
    UIImagePickerController *camera = [[UIImagePickerController alloc] init];
    camera.sourceType = UIImagePickerControllerSourceTypeCamera;
    camera.delegate = self;
    camera.mediaTypes = @[wantedType];

    if ([options[@"cameraType"] isEqualToString:@"front"] &&
        [UIImagePickerController isCameraDeviceAvailable:UIImagePickerControllerCameraDeviceFront]) {
      camera.cameraDevice = UIImagePickerControllerCameraDeviceFront;
    }

    if (isVideo) {
      NSTimeInterval limit = [options[@"durationLimit"] doubleValue];
      if (limit > 0) camera.videoMaximumDuration = limit;
      camera.videoQuality = [options[@"videoQuality"] isEqualToString:@"low"]
          ? UIImagePickerControllerQualityTypeLow
          : UIImagePickerControllerQualityTypeHigh;
    }

    UIViewController *presenter = RCTPresentedViewController();
    if (presenter == nil) {
      [self finishWith:[self errorResultWithCode:@"others"
                                         message:@"No view controller to present from"]];
      return;
    }
    [presenter presentViewController:camera animated:YES completion:nil];
  });
}

- (void)cropImage:(NSDictionary *)options
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  if (self.pendingResolve != nil) {
    resolve([self errorResultWithCode:@"picker_busy" message:@"A picker is already open"]);
    return;
  }
  NSString *path = options[@"path"];
  if (path.length == 0) {
    resolve([self errorResultWithCode:@"invalid_options" message:@"path is required"]);
    return;
  }
  NSString *cleanPath = [path hasPrefix:@"file://"] ? [[NSURL URLWithString:path] path] : path;
  UIImage *image = [UIImage imageWithContentsOfFile:cleanPath];
  if (image == nil) {
    resolve([self errorResultWithCode:@"cannot_process_asset" message:@"Could not read the image"]);
    return;
  }

  self.pendingResolve = resolve;
  self.pendingOptions = options;
  self.pendingCropAsset = [@{@"originalPath": path} mutableCopy];
  [self presentCropperWithImage:image options:options];
}

- (void)cleanTempFiles:(NSString *)path
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *dir = [self tempDirectory];

  if (path.length == 0) {
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
      [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    }
    resolve(nil);
    return;
  }

  NSString *cleanPath = [path hasPrefix:@"file://"] ? [[NSURL URLWithString:path] path] : path;
  // Only ever delete inside our own temp directory.
  if ([cleanPath hasPrefix:dir]) [fm removeItemAtPath:cleanPath error:nil];
  resolve(nil);
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
  [picker dismissViewControllerAnimated:YES completion:nil];

  if (results.count == 0) {
    [self finishWith:[self cancelledResult]];
    return;
  }

  NSDictionary *options = self.pendingOptions ?: @{};
  BOOL wantsCrop = [options[@"cropping"] boolValue];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSMutableArray<NSDictionary *> *assets = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    __block NSString *failure = nil;

    for (PHPickerResult *result in results) {
      dispatch_group_enter(group);
      [self processResult:result
                  options:options
               completion:^(NSDictionary *asset, NSString *error) {
        @synchronized (assets) {
          if (asset) [assets addObject:asset];
          else if (error && failure == nil) failure = error;
        }
        dispatch_group_leave(group);
      }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (assets.count == 0) {
      [self finishWith:[self errorResultWithCode:@"cannot_process_asset"
                                         message:failure ?: @"Could not read the selected media"]];
      return;
    }

    BOOL isSingleImage = assets.count == 1 &&
        [assets[0][@"type"] hasPrefix:@"image/"];

    if (wantsCrop && isSingleImage) {
      NSString *path = assets[0][@"uri"];
      NSString *cleanPath = [path hasPrefix:@"file://"] ? [[NSURL URLWithString:path] path] : path;
      UIImage *image = [UIImage imageWithContentsOfFile:cleanPath];
      if (image != nil) {
        self.pendingCropAsset = [assets[0] mutableCopy];
        dispatch_async(dispatch_get_main_queue(), ^{
          [self presentCropperWithImage:image options:options];
        });
        return;
      }
    }

    [self finishWith:@{@"didCancel": @NO, @"assets": assets}];
  });
}

#pragma mark - UIImagePickerControllerDelegate (camera)

- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info
{
  [picker dismissViewControllerAnimated:YES completion:nil];

  NSDictionary *options = self.pendingOptions ?: @{};
  NSURL *mediaURL = info[UIImagePickerControllerMediaURL];
  UIImage *image = info[UIImagePickerControllerOriginalImage];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    if (mediaURL != nil) {
      // The recording sits in a system temp file that is not ours to keep, so
      // copy it into the module's own directory before reporting it.
      NSString *extension = mediaURL.pathExtension.length > 0 ? mediaURL.pathExtension : @"mov";
      NSString *destination = [self tempPathWithExtension:extension];
      NSError *copyError = nil;
      [[NSFileManager defaultManager] copyItemAtPath:mediaURL.path
                                              toPath:destination
                                               error:&copyError];
      if (copyError != nil) {
        [self finishWith:[self errorResultWithCode:@"cannot_process_asset"
                                           message:copyError.localizedDescription]];
        return;
      }
      NSDictionary *asset = [self videoAssetAtPath:destination
                                          fileName:destination.lastPathComponent
                                           options:options
                                            result:nil];
      [self finishWith:@{@"didCancel": @NO, @"assets": @[asset]}];
      return;
    }

    if (image == nil) {
      [self finishWith:[self errorResultWithCode:@"cannot_process_asset"
                                         message:@"The camera returned no media"]];
      return;
    }

    if ([options[@"cropping"] boolValue]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        // Nothing has been written to disk yet, so there is no pre-crop temp
        // file for the cropper delegate to clean up.
        self.pendingCropAsset = [NSMutableDictionary dictionary];
        [self presentCropperWithImage:image options:options];
      });
      return;
    }

    // Write the capture untouched and let the shared image builder apply
    // maxWidth/maxHeight/quality/forceJpg, so camera and gallery assets go
    // through exactly the same rules.
    NSData *data = UIImageJPEGRepresentation(image, 1.0);
    NSString *path = [self tempPathWithExtension:@"jpg"];
    if (data == nil || ![data writeToFile:path atomically:YES]) {
      [self finishWith:[self errorResultWithCode:@"cannot_process_asset"
                                         message:@"Could not write the captured photo"]];
      return;
    }
    NSDictionary *asset = [self imageAssetAtPath:path
                                        fileName:path.lastPathComponent
                                         options:options
                                          result:nil];
    [self finishWith:@{@"didCancel": @NO, @"assets": @[asset]}];
  });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWith:[self cancelledResult]];
}

#pragma mark - Asset processing

- (void)processResult:(PHPickerResult *)result
              options:(NSDictionary *)options
           completion:(void (^)(NSDictionary *asset, NSString *error))completion
{
  NSItemProvider *provider = result.itemProvider;
  BOOL isVideo = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
  NSString *typeIdentifier = isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;

  [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
                                  completionHandler:^(NSURL *url, NSError *error) {
    if (url == nil) {
      completion(nil, error.localizedDescription ?: @"Asset could not be loaded");
      return;
    }

    // The URL is only valid inside this block, so copy before returning.
    NSString *extension = url.pathExtension.length > 0 ? url.pathExtension : (isVideo ? @"mov" : @"jpg");
    NSString *destination = [self tempPathWithExtension:extension];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destination error:&copyError];
    if (copyError != nil) {
      completion(nil, copyError.localizedDescription);
      return;
    }

    NSString *fileName = url.lastPathComponent ?: destination.lastPathComponent;
    NSDictionary *asset = isVideo
        ? [self videoAssetAtPath:destination fileName:fileName options:options result:result]
        : [self imageAssetAtPath:destination fileName:fileName options:options result:result];
    completion(asset, nil);
  }];
}

- (NSDictionary *)imageAssetAtPath:(NSString *)path
                          fileName:(NSString *)fileName
                           options:(NSDictionary *)options
                            result:(PHPickerResult *)result
{
  BOOL forceJpg = options[@"forceJpg"] == nil || [options[@"forceJpg"] boolValue];
  CGFloat maxWidth = [options[@"maxWidth"] floatValue];
  CGFloat maxHeight = [options[@"maxHeight"] floatValue];
  CGFloat quality = options[@"quality"] ? [options[@"quality"] floatValue] : 1.0;

  NSString *finalPath = path;
  NSString *mime = [self mimeTypeForPath:path];
  BOOL needsWork = maxWidth > 0 || maxHeight > 0 || quality < 1.0 ||
      (forceJpg && ![mime isEqualToString:@"image/jpeg"]);

  if (needsWork) {
    UIImage *image = [UIImage imageWithContentsOfFile:path];
    if (image != nil) {
      UIImage *resized = [self image:image scaledToMaxWidth:maxWidth maxHeight:maxHeight];
      NSData *data = UIImageJPEGRepresentation(resized, quality);
      if (data != nil) {
        NSString *jpgPath = [self tempPathWithExtension:@"jpg"];
        if ([data writeToFile:jpgPath atomically:YES]) {
          [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
          finalPath = jpgPath;
          mime = @"image/jpeg";
        }
      }
    }
  }

  // The library's display name still carries the source extension, so a
  // re-encoded PNG would be reported as "shot.png" while both the file on disk
  // and `type` say JPEG. Report the extension the bytes actually have.
  NSString *reportedName = fileName;
  NSString *finalExtension = finalPath.pathExtension;
  if (finalExtension.length > 0 &&
      ![fileName.pathExtension isEqualToString:finalExtension]) {
    reportedName = [[fileName stringByDeletingPathExtension]
        stringByAppendingPathExtension:finalExtension];
  }

  return [self assetDictForPath:finalPath
                       fileName:reportedName
                           mime:mime
                        options:options
                         result:result
                          extra:nil];
}

- (NSDictionary *)videoAssetAtPath:(NSString *)path
                          fileName:(NSString *)fileName
                           options:(NSDictionary *)options
                            result:(PHPickerResult *)result
{
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  CGSize size = track ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform) : CGSizeZero;

  NSMutableDictionary *extra = [NSMutableDictionary dictionary];
  extra[@"duration"] = @(CMTimeGetSeconds(asset.duration) * 1000.0); // ms, to match Android
  extra[@"bitrate"] = @(track ? track.estimatedDataRate : 0);
  extra[@"width"] = @(fabs(size.width));
  extra[@"height"] = @(fabs(size.height));

  return [self assetDictForPath:path
                       fileName:fileName
                           mime:[self mimeTypeForPath:path]
                        options:options
                         result:result
                          extra:extra];
}

- (NSDictionary *)assetDictForPath:(NSString *)path
                          fileName:(NSString *)fileName
                              mime:(NSString *)mime
                           options:(NSDictionary *)options
                            result:(nullable PHPickerResult *)result
                             extra:(nullable NSDictionary *)extra
{
  NSMutableDictionary *asset = [NSMutableDictionary dictionary];
  NSFileManager *fm = [NSFileManager defaultManager];
  unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];

  BOOL writeTempFile = options[@"writeTempFile"] == nil || [options[@"writeTempFile"] boolValue];

  asset[@"fileName"] = fileName;
  asset[@"fileSize"] = @(size);
  asset[@"type"] = mime;

  if (extra != nil) {
    [asset addEntriesFromDictionary:extra];
  } else {
    CGSize dimensions = [self imageDimensionsAtPath:path];
    asset[@"width"] = @(dimensions.width);
    asset[@"height"] = @(dimensions.height);
    if ([options[@"includeExif"] boolValue]) {
      NSDictionary *exif = [self exifAtPath:path];
      if (exif) asset[@"exif"] = exif;
    }
    if ([options[@"includeBase64"] boolValue]) {
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (data) asset[@"base64"] = [data base64EncodedStringWithOptions:0];
    }
  }

  if ([options[@"includeExtra"] boolValue] && result.assetIdentifier != nil) {
    asset[@"id"] = result.assetIdentifier;
    asset[@"originalPath"] = result.assetIdentifier;
  }

  if (writeTempFile) {
    asset[@"uri"] = [@"file://" stringByAppendingString:path];
  } else {
    [fm removeItemAtPath:path error:nil];
    asset[@"uri"] = [NSNull null];
  }

  return asset;
}

#pragma mark - Cropping

- (void)presentCropperWithImage:(UIImage *)image options:(NSDictionary *)options
{
  BOOL circle = [options[@"cropperCircleOverlay"] boolValue];
  BOOL freeStyle = [options[@"freeStyleCropEnabled"] boolValue];
  CGFloat cropWidth = [options[@"cropWidth"] floatValue];
  CGFloat cropHeight = [options[@"cropHeight"] floatValue];

  TOCropViewCroppingStyle style = circle ? TOCropViewCroppingStyleCircular : TOCropViewCroppingStyleDefault;
  TOCropViewController *cropper = [[TOCropViewController alloc] initWithCroppingStyle:style image:image];
  cropper.delegate = self;
  cropper.title = options[@"cropperToolbarTitle"];
  cropper.doneButtonTitle = options[@"cropperChooseText"];
  cropper.cancelButtonTitle = options[@"cropperCancelText"];
  cropper.aspectRatioPickerButtonHidden = YES;

  if (cropWidth > 0 && cropHeight > 0) {
    cropper.customAspectRatio = CGSizeMake(cropWidth, cropHeight);
    cropper.aspectRatioLockEnabled = !freeStyle;
    cropper.resetAspectRatioEnabled = freeStyle;
  }

  UIViewController *presenter = RCTPresentedViewController();
  if (presenter == nil) {
    [self finishWith:[self errorResultWithCode:@"crop_failed" message:@"No view controller to present from"]];
    return;
  }
  [presenter presentViewController:cropper animated:YES completion:nil];
}

- (void)cropViewController:(TOCropViewController *)cropViewController
            didCropToImage:(UIImage *)image
                  withRect:(CGRect)cropRect
                     angle:(NSInteger)angle
{
  [cropViewController dismissViewControllerAnimated:YES completion:nil];

  NSDictionary *options = self.pendingOptions ?: @{};
  CGFloat quality = options[@"quality"] ? [options[@"quality"] floatValue] : 1.0;

  // TOCropViewController only crops; it has no notion of an output size, so
  // cropWidth/cropHeight would otherwise mean "aspect ratio" here and "exact
  // output size" on Android. Match Android: an aspect-locked crop resizes
  // exactly, a free-form one fits inside without stretching.
  CGFloat cropWidth = [options[@"cropWidth"] floatValue];
  CGFloat cropHeight = [options[@"cropHeight"] floatValue];
  UIImage *output = image;
  if (cropWidth > 0 && cropHeight > 0) {
    output = [options[@"freeStyleCropEnabled"] boolValue]
        ? [self image:image scaledToMaxWidth:cropWidth maxHeight:cropHeight]
        : [self image:image resizedExactlyToWidth:cropWidth height:cropHeight];
  }

  NSData *data = UIImageJPEGRepresentation(output, quality);
  if (data == nil) {
    [self finishWith:[self errorResultWithCode:@"crop_failed" message:@"Could not encode the cropped image"]];
    return;
  }

  NSString *path = [self tempPathWithExtension:@"jpg"];
  if (![data writeToFile:path atomically:YES]) {
    [self finishWith:[self errorResultWithCode:@"crop_failed" message:@"Could not write the cropped image"]];
    return;
  }

  // The pre-crop temp file is now dead weight.
  NSString *previous = self.pendingCropAsset[@"uri"];
  if ([previous isKindOfClass:[NSString class]]) {
    NSString *cleanPrevious = [previous hasPrefix:@"file://"] ? [[NSURL URLWithString:previous] path] : previous;
    if ([cleanPrevious hasPrefix:[self tempDirectory]]) {
      [[NSFileManager defaultManager] removeItemAtPath:cleanPrevious error:nil];
    }
  }

  NSMutableDictionary *asset = self.pendingCropAsset ?: [NSMutableDictionary dictionary];
  asset[@"uri"] = [@"file://" stringByAppendingString:path];
  asset[@"type"] = @"image/jpeg";
  asset[@"fileName"] = path.lastPathComponent;
  asset[@"fileSize"] = @(data.length);
  asset[@"width"] = @(output.size.width * output.scale);
  asset[@"height"] = @(output.size.height * output.scale);
  asset[@"cropRect"] = @{
    @"x": @(cropRect.origin.x),
    @"y": @(cropRect.origin.y),
    @"width": @(cropRect.size.width),
    @"height": @(cropRect.size.height)
  };
  if ([options[@"includeBase64"] boolValue]) {
    asset[@"base64"] = [data base64EncodedStringWithOptions:0];
  }

  [self finishWith:@{@"didCancel": @NO, @"assets": @[asset]}];
}

- (void)cropViewController:(TOCropViewController *)cropViewController
      didFinishCancelled:(BOOL)cancelled
{
  [cropViewController dismissViewControllerAnimated:YES completion:nil];
  [self finishWith:[self cancelledResult]];
}

#pragma mark - Helpers

- (UIModalPresentationStyle)presentationStyleFrom:(NSString *)style
{
  if ([style isEqualToString:@"pageSheet"]) return UIModalPresentationPageSheet;
  if ([style isEqualToString:@"fullScreen"]) return UIModalPresentationFullScreen;
  if ([style isEqualToString:@"formSheet"]) return UIModalPresentationFormSheet;
  if ([style isEqualToString:@"overFullScreen"]) return UIModalPresentationOverFullScreen;
  return UIModalPresentationAutomatic;
}

- (NSString *)mimeTypeForPath:(NSString *)path
{
  UTType *type = [UTType typeWithFilenameExtension:path.pathExtension];
  return type.preferredMIMEType ?: @"application/octet-stream";
}

- (CGSize)imageDimensionsAtPath:(NSString *)path
{
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (source == NULL) return CGSizeZero;
  NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
  CFRelease(source);
  return CGSizeMake([props[(NSString *)kCGImagePropertyPixelWidth] floatValue],
                    [props[(NSString *)kCGImagePropertyPixelHeight] floatValue]);
}

- (nullable NSDictionary *)exifAtPath:(NSString *)path
{
  CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
  if (source == NULL) return nil;
  NSDictionary *props = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
  CFRelease(source);
  return props[(NSString *)kCGImagePropertyExifDictionary] ?: props;
}

/// Unconditional resize to an exact pixel size, used for aspect-locked crops
/// where the caller asked for a specific output size.
- (UIImage *)image:(UIImage *)image resizedExactlyToWidth:(CGFloat)width height:(CGFloat)height
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

- (UIImage *)image:(UIImage *)image scaledToMaxWidth:(CGFloat)maxWidth maxHeight:(CGFloat)maxHeight
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

@end
