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

static const CGFloat kMinJPEGQuality = 0.1;
static const CGFloat kMaxJPEGQuality = 0.95;
static const NSInteger kQualitySearchSteps = 7;
static const CGFloat kMinImageEdge = 64.0;

// Roughly the bits H.264 needs per pixel per frame to still look acceptable.
static const CGFloat kVideoBitsPerPixel = 0.12;
static const NSInteger kVideoFrameRate = 30;
static const NSInteger kMaxAudioBitRate = 64000;
static const NSInteger kMinAudioBitRate = 24000;
static const NSInteger kMinVideoBitRate = 120000;
static const CGFloat kMinVideoEdge = 144.0;
// Aim under the limit rather than at it. An encoder treats an average bitrate as
// something to hover around, and key frames and container overhead do not scale
// down with it -- targeting the limit exactly measured ~25% over on a short clip.
static const CGFloat kSizeSafetyMargin = 0.90;

@interface MediaPicker () <PHPickerViewControllerDelegate,
                           TOCropViewControllerDelegate,
                           UIImagePickerControllerDelegate,
                           UINavigationControllerDelegate>
@property (nonatomic, copy, nullable) RCTPromiseResolveBlock pendingResolve;
@property (nonatomic, strong, nullable) NSDictionary *pendingOptions;
@property (nonatomic, strong, nullable) NSMutableDictionary *pendingCropAsset;
/// Raised by cancelCompression and read from the pump queues, so atomic rather
/// than nonatomic like the rest. Covers a whole batch: cancelling during a
/// multi-select stops the clip being worked on and everything queued behind it.
@property (atomic, assign) BOOL compressionCancelled;
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
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
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
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
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
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
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

- (void)compressMedia:(NSDictionary *)options
              resolve:(RCTPromiseResolveBlock)resolve
               reject:(RCTPromiseRejectBlock)reject
{
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
  NSString *path = options[@"path"];
  if (path.length == 0) {
    resolve([self errorResultWithCode:@"invalid_options" message:@"path is required"]);
    return;
  }
  NSString *cleanPath = [path hasPrefix:@"file://"] ? [[NSURL URLWithString:path] path] : path;
  if (![[NSFileManager defaultManager] fileExistsAtPath:cleanPath]) {
    resolve([self errorResultWithCode:@"cannot_process_asset"
                              message:[NSString stringWithFormat:@"There is no file at %@", path]]);
    return;
  }

  NSString *mime = [self mimeTypeForPath:cleanPath];
  BOOL isVideo = [mime hasPrefix:@"video/"];
  if (!isVideo && ![mime hasPrefix:@"image/"]) {
    resolve([self errorResultWithCode:@"invalid_options"
                              message:[NSString stringWithFormat:
                                          @"%@ is neither an image nor a video", path]]);
    return;
  }

  // No UI, so this neither claims the picker slot nor minds that one is open.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // Only the byte budget applies. Routing through the picker's asset builders
    // would drag maxWidth/quality/forceJpg along with it, and a file already
    // under budget would then not come back untouched after all.
    NSString *skipped = nil;
    NSString *compressed = [self compressedPathFor:cleanPath
                                              mime:mime
                                           options:options
                                          progress:^(double p) {
      [self reportProgress:p index:0 total:1];
    }
                                           skipped:&skipped];
    if (compressed == nil) {
      resolve([self errorResultWithCode:@"compress_failed"
                                message:isVideo
                                    ? @"Could not compress the video below maxVideoFileSize"
                                    : @"Could not compress the image below maxImageFileSize"]);
      return;
    }

    // The name follows the bytes, the same way it does after a re-encode.
    NSString *fileName = [[cleanPath.lastPathComponent stringByDeletingPathExtension]
        stringByAppendingPathExtension:compressed.pathExtension];
    NSMutableDictionary *asset = [[self assetDictForPath:compressed
                                               fileName:fileName
                                                   mime:[self mimeTypeForPath:compressed]
                                                options:options
                                                 result:nil
                                                  extra:isVideo ? [self videoExtrasAtPath:compressed]
                                                                : nil] mutableCopy];
    asset[@"originalPath"] = path;
    if (skipped) asset[@"compressionSkipped"] = skipped;
    resolve(@{@"didCancel": @NO, @"assets": @[asset]});
  });
}

- (void)cancelCompression:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject
{
  // Safe when nothing is running: the flag is cleared before each batch starts.
  self.compressionCancelled = YES;
  resolve(nil);
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
    __block NSString *failureCode = nil;

    for (NSUInteger idx = 0; idx < results.count; idx++) {
      PHPickerResult *result = results[idx];
      dispatch_group_enter(group);
      [self processResult:result
                  options:options
                    index:idx
                    total:results.count
               completion:^(NSDictionary *asset, NSString *code, NSString *error) {
        @synchronized (assets) {
          if (asset) {
            [assets addObject:asset];
          } else if (error && failure == nil) {
            failure = error;
            failureCode = code;
          }
        }
        dispatch_group_leave(group);
      }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    if (assets.count == 0) {
      [self finishWith:[self errorResultWithCode:failureCode ?: @"cannot_process_asset"
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
      NSString *compressionError = nil;
      NSDictionary *asset = [self videoAssetAtPath:destination
                                          fileName:nil
                                           options:options
                                            result:nil
                                             index:0
                                             total:1
                                  compressionError:&compressionError];
      if (asset == nil) {
        [self finishWith:[self errorResultWithCode:@"compress_failed" message:compressionError]];
        return;
      }
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
    NSString *compressionError = nil;
    NSDictionary *asset = [self imageAssetAtPath:path
                                        fileName:nil
                                         options:options
                                          result:nil
                                compressionError:&compressionError];
    if (asset == nil) {
      [self finishWith:[self errorResultWithCode:@"compress_failed" message:compressionError]];
      return;
    }
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
                index:(NSUInteger)index
                total:(NSUInteger)total
           completion:(void (^)(NSDictionary *asset, NSString *code, NSString *error))completion
{
  NSItemProvider *provider = result.itemProvider;
  BOOL isVideo = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
  NSString *typeIdentifier = isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;

  [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
                                  completionHandler:^(NSURL *url, NSError *error) {
    if (url == nil) {
      completion(nil, @"cannot_process_asset",
                 error.localizedDescription ?: @"Asset could not be loaded");
      return;
    }

    // The URL is only valid inside this block, so copy before returning.
    NSString *extension = url.pathExtension.length > 0 ? url.pathExtension : (isVideo ? @"mov" : @"jpg");
    NSString *destination = [self tempPathWithExtension:extension];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destination error:&copyError];
    if (copyError != nil) {
      completion(nil, @"cannot_process_asset", copyError.localizedDescription);
      return;
    }

    NSString *fileName = url.lastPathComponent ?: destination.lastPathComponent;
    NSString *compressionError = nil;
    NSDictionary *asset = isVideo
        ? [self videoAssetAtPath:destination
                        fileName:fileName
                         options:options
                          result:result
                           index:index
                           total:total
                compressionError:&compressionError]
        : [self imageAssetAtPath:destination
                        fileName:fileName
                         options:options
                          result:result
                compressionError:&compressionError];
    if (asset == nil) {
      completion(nil, @"compress_failed", compressionError);
      return;
    }
    completion(asset, nil, nil);
  }];
}

- (nullable NSDictionary *)imageAssetAtPath:(NSString *)path
                                  fileName:(NSString *)fileName
                                   options:(NSDictionary *)options
                                    result:(PHPickerResult *)result
                          compressionError:(NSString **)compressionError
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
          [self removeIfTemporary:path];
          finalPath = jpgPath;
          mime = @"image/jpeg";
        }
      }
    }
  }

  // Last, so the budget is measured against the bytes that actually ship.
  NSString *skipped = nil;
  NSString *compressed = [self compressedPathFor:finalPath
                                            mime:mime
                                         options:options
                                        progress:nil
                                         skipped:&skipped];
  if (compressed == nil) {
    *compressionError = @"Could not compress the image below maxImageFileSize";
    return nil;
  }
  if (![compressed isEqualToString:finalPath]) {
    finalPath = compressed;
    mime = @"image/jpeg";
  }

  // A camera shot has no display name of its own, so the caller passes nil and
  // the file that actually ends up on disk names it -- otherwise a re-encode
  // would leave the asset naming the temp file it just deleted.
  NSString *reportedName = fileName ?: finalPath.lastPathComponent;
  // The library's display name still carries the source extension, so a
  // re-encoded PNG would be reported as "shot.png" while both the file on disk
  // and `type` say JPEG. Report the extension the bytes actually have.
  NSString *finalExtension = finalPath.pathExtension;
  if (finalExtension.length > 0 &&
      ![reportedName.pathExtension isEqualToString:finalExtension]) {
    reportedName = [[reportedName stringByDeletingPathExtension]
        stringByAppendingPathExtension:finalExtension];
  }

  NSMutableDictionary *asset = [[self assetDictForPath:finalPath
                                              fileName:reportedName
                                                  mime:mime
                                               options:options
                                                result:result
                                                 extra:nil] mutableCopy];
  if (skipped) asset[@"compressionSkipped"] = skipped;
  return asset;
}

- (nullable NSDictionary *)videoAssetAtPath:(NSString *)path
                                  fileName:(nullable NSString *)fileName
                                   options:(NSDictionary *)options
                                    result:(PHPickerResult *)result
                                     index:(NSUInteger)index
                                     total:(NSUInteger)total
                          compressionError:(NSString **)compressionError
{
  NSString *skipped = nil;
  NSString *compressed = [self compressedPathFor:path
                                            mime:@"video/mp4"
                                         options:options
                                        progress:^(double p) {
    [self reportProgress:p index:index total:total];
  }
                                         skipped:&skipped];
  if (compressed == nil) {
    *compressionError = @"Could not compress the video below maxVideoFileSize";
    return nil;
  }
  // Every reported dimension, duration and bitrate has to describe the file the
  // caller is handed, so they are all read after compression rather than before.
  path = compressed;

  // A recording has no display name of its own, so the camera path passes nil
  // and the file that ends up on disk names it -- otherwise a transcode would
  // leave the asset naming the temp file it just replaced. A gallery pick does
  // have a name, and it keeps it with the extension the bytes actually have.
  NSString *reportedName = fileName ?: path.lastPathComponent;
  if (path.pathExtension.length > 0 &&
      ![reportedName.pathExtension isEqualToString:path.pathExtension]) {
    reportedName = [[reportedName stringByDeletingPathExtension]
        stringByAppendingPathExtension:path.pathExtension];
  }

  NSMutableDictionary *asset = [[self assetDictForPath:path
                                              fileName:reportedName
                                                  mime:[self mimeTypeForPath:path]
                                               options:options
                                                result:result
                                                 extra:[self videoExtrasAtPath:path]] mutableCopy];
  if (skipped) asset[@"compressionSkipped"] = skipped;
  return asset;
}

/// Dimensions, duration and bitrate of a movie on disk, in the shape the Asset
/// contract expects.
- (NSDictionary *)videoExtrasAtPath:(NSString *)path
{
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  CGSize size = track ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform) : CGSizeZero;

  return @{
    @"duration": @(CMTimeGetSeconds(asset.duration) * 1000.0), // ms, to match Android
    @"bitrate": @(track ? track.estimatedDataRate : 0),
    @"width": @(fabs(size.width)),
    @"height": @(fabs(size.height)),
  };
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
    [self removeIfTemporary:path];
    asset[@"uri"] = [NSNull null];
  }

  return asset;
}

#pragma mark - Compression

/// Dispatches to the right encoder for the media, and is a no-op when the
/// caller set no budget or the file already fits. Returns nil when the budget
/// cannot be met at all.
- (nullable NSString *)compressedPathFor:(NSString *)path
                                    mime:(NSString *)mime
                                 options:(NSDictionary *)options
                                progress:(nullable void (^)(double))progress
                                 skipped:(NSString *_Nullable *_Nullable)skipped
{
  BOOL isVideo = [mime hasPrefix:@"video/"];
  unsigned long long minBytes =
      [options[@"minimumFileSizeForCompress"] unsignedLongLongValue];
  unsigned long long budget =
      [options[isVideo ? @"maxVideoFileSize" : @"maxImageFileSize"] unsignedLongLongValue];
  unsigned long long size =
      [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];

  NSString *result = isVideo
      ? [self compressVideoAtPath:path toMaxBytes:budget minBytes:minBytes progress:progress]
      : [self compressImageAtPath:path toMaxBytes:budget minBytes:minBytes];

  // Unchanged and already inside its budget is the ordinary case; unchanged
  // while still over it means the work was declined, and the caller needs to
  // know which, because the file it is about to upload is too big.
  if (skipped != NULL && result != nil && [result isEqualToString:path] &&
      budget > 0 && size > budget) {
    if (self.compressionCancelled) {
      *skipped = @"cancelled";
    } else if (minBytes > 0 && size < minBytes) {
      *skipped = @"below_minimum";
    }
  }
  return result;
}

/// Re-encode until the file fits. Quality is searched first because it costs no
/// pixels; only when even the lowest quality still overflows does the image get
/// halved and searched again.
- (nullable NSString *)compressImageAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes
{
  NSFileManager *fm = [NSFileManager defaultManager];
  unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
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

  NSString *output = [self tempPathWithExtension:@"jpg"];
  if (![encoded writeToFile:output atomically:YES]) return nil;
  [self removeIfTemporary:path];
  return output;
}

/// Highest JPEG quality whose output still fits, or nil when even the floor does not.
- (nullable NSData *)encodeImage:(UIImage *)image underLimit:(unsigned long long)maxBytes
{
  CGFloat low = kMinJPEGQuality;
  CGFloat high = kMaxJPEGQuality;
  NSData *best = nil;

  for (NSInteger step = 0; step < kQualitySearchSteps; step++) {
    CGFloat quality = (low + high) / 2.0;
    NSData *data = UIImageJPEGRepresentation(image, quality);
    if (data == nil) return nil;
    if (data.length <= maxBytes) {
      best = data;
      low = quality;
    } else {
      high = quality;
    }
  }

  // The search closes in on the floor without ever evaluating it, so a run that
  // found nothing has not actually ruled the floor out yet.
  if (best == nil) {
    NSData *data = UIImageJPEGRepresentation(image, kMinJPEGQuality);
    if (data != nil && data.length <= maxBytes) best = data;
  }
  return best;
}

/// Re-encode to H.264/AAC at a bitrate the clip's own duration can afford.
/// Returns the original untouched when it already fits, nil when even the floor
/// bitrate cannot get under the budget.
- (nullable NSString *)compressVideoAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes
                                  progress:(nullable void (^)(double))progress
{
  NSFileManager *fm = [NSFileManager defaultManager];
  unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
  if (maxBytes == 0 || size <= maxBytes) return path;
  // Over budget, but not by enough to be worth a whole transcode. Returns a
  // file that is still over its budget, deliberately.
  if (minBytes > 0 && size < minBytes) return path;

  if (self.compressionCancelled) return path;

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetTrack *video = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  Float64 seconds = CMTimeGetSeconds(asset.duration);
  if (video == nil || seconds <= 0) return path;

  // An encoder lands near its requested bitrate rather than on it, so the budget
  // gets one correction against what the first pass actually produced.
  unsigned long long target = (unsigned long long)(maxBytes * kSizeSafetyMargin);
  for (NSInteger attempt = 0; attempt < 2; attempt++) {
    // A correction pass would otherwise send a progress bar back to zero, so the
    // first pass owns most of the range and the second one finishes it.
    double from = attempt == 0 ? 0.0 : 0.85;
    double to = attempt == 0 ? 0.85 : 1.0;
    void (^passProgress)(double) = progress ? ^(double p) {
      progress(from + (to - from) * p);
    } : (void (^)(double))nil;

    NSString *output = [self transcodeAsset:asset
                                      video:video
                                    seconds:seconds
                                     budget:target
                                   progress:passProgress];
    if (output == nil) {
      // A cancel is not a failure. The caller asked for this, so hand back the
      // original rather than reporting compress_failed.
      if (self.compressionCancelled) return path;
      return nil;
    }

    unsigned long long produced = [[fm attributesOfItemAtPath:output error:nil] fileSize];
    if (produced <= maxBytes) {
      if (progress) progress(1.0);
      [self removeIfTemporary:path];
      return output;
    }
    // Scale the next request by how far this pass actually missed, keeping the
    // margin so the correction lands inside the limit rather than back on it.
    target = (unsigned long long)(target * (maxBytes * kSizeSafetyMargin) / (CGFloat)produced);
    [fm removeItemAtPath:output error:nil];
  }
  return nil;
}

- (nullable NSString *)transcodeAsset:(AVURLAsset *)asset
                                video:(AVAssetTrack *)videoTrack
                              seconds:(Float64)seconds
                               budget:(unsigned long long)budget
                             progress:(nullable void (^)(double))progress
{
  AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];

  NSInteger totalBitRate = (NSInteger)(budget * 8 / seconds);
  NSInteger audioBitRate = audioTrack
      ? MIN(MAX(totalBitRate / 4, kMinAudioBitRate), kMaxAudioBitRate)
      : 0;
  NSInteger videoBitRate = MAX(totalBitRate - audioBitRate, kMinVideoBitRate);

  NSError *error = nil;
  AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&error];
  if (reader == nil) return nil;

  NSString *output = [self tempPathWithExtension:@"mp4"];
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:output]
                                                   fileType:AVFileTypeMPEG4
                                                      error:&error];
  if (writer == nil) return nil;
  // The point of compressing is uploading, so put the moov atom up front.
  writer.shouldOptimizeForNetworkUse = YES;

  // Sample buffers come out of the track unrotated, so the output is sized from
  // naturalSize and the rotation is carried across as metadata instead of being
  // baked in by re-rendering every frame.
  CGSize target = [self sizeForBitRate:videoBitRate naturalSize:videoTrack.naturalSize];
  if (target.width <= 0 || target.height <= 0) return nil;

  // Decode straight to the size we are going to encode. Left to itself the
  // reader hands back full-resolution buffers and the encoder scales every one
  // of them, which is the same work done later and on more pixels.
  NSDictionary *scaled = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey:
        @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
    (NSString *)kCVPixelBufferWidthKey: @(target.width),
    (NSString *)kCVPixelBufferHeightKey: @(target.height),
  };
  AVAssetReaderTrackOutput *videoOutput =
      [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:videoTrack outputSettings:scaled];
  videoOutput.alwaysCopiesSampleData = NO;

  // Not every source can be scaled on the way out of the decoder; fall back to
  // full-size buffers and let the encoder do it, as it used to.
  if (![reader canAddOutput:videoOutput]) {
    videoOutput = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:videoTrack
                         outputSettings:@{
                           (NSString *)kCVPixelBufferPixelFormatTypeKey:
                               @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
                         }];
    videoOutput.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:videoOutput]) return nil;
  }
  [reader addOutput:videoOutput];

  AVAssetWriterInput *videoInput = [AVAssetWriterInput
      assetWriterInputWithMediaType:AVMediaTypeVideo
                     outputSettings:@{
                       AVVideoCodecKey: AVVideoCodecTypeH264,
                       AVVideoWidthKey: @(target.width),
                       AVVideoHeightKey: @(target.height),
                       AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
                       AVVideoCompressionPropertiesKey: @{
                         AVVideoAverageBitRateKey: @(videoBitRate),
                         AVVideoMaxKeyFrameIntervalKey: @(kVideoFrameRate * 2),
                         AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                       },
                     }];
  videoInput.expectsMediaDataInRealTime = NO;
  videoInput.transform = videoTrack.preferredTransform;
  if (![writer canAddInput:videoInput]) return nil;
  [writer addInput:videoInput];

  AVAssetReaderTrackOutput *audioOutput = nil;
  AVAssetWriterInput *audioInput = nil;
  if (audioTrack != nil) {
    audioOutput = [AVAssetReaderTrackOutput
        assetReaderTrackOutputWithTrack:audioTrack
                         outputSettings:@{AVFormatIDKey: @(kAudioFormatLinearPCM)}];
    audioOutput.alwaysCopiesSampleData = NO;

    // AAC above stereo needs an explicit channel layout, so anything wider is
    // folded down rather than failing the whole export.
    CMFormatDescriptionRef format =
        (__bridge CMFormatDescriptionRef)audioTrack.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *asbd =
        format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    NSInteger channels = (asbd && asbd->mChannelsPerFrame > 0)
        ? MIN((NSInteger)asbd->mChannelsPerFrame, 2)
        : 2;
    Float64 sampleRate = (asbd && asbd->mSampleRate > 0) ? asbd->mSampleRate : 44100.0;

    audioInput = [AVAssetWriterInput
        assetWriterInputWithMediaType:AVMediaTypeAudio
                       outputSettings:@{
                         AVFormatIDKey: @(kAudioFormatMPEG4AAC),
                         AVNumberOfChannelsKey: @(channels),
                         AVSampleRateKey: @(sampleRate),
                         AVEncoderBitRateKey: @(audioBitRate),
                       }];
    audioInput.expectsMediaDataInRealTime = NO;

    if ([reader canAddOutput:audioOutput] && [writer canAddInput:audioInput]) {
      [reader addOutput:audioOutput];
      [writer addInput:audioInput];
    } else {
      // A track that cannot be re-encoded is dropped rather than failing the
      // export; a silent clip under budget beats no clip at all.
      audioOutput = nil;
      audioInput = nil;
    }
  }

  if (![reader startReading] || ![writer startWriting]) {
    [reader cancelReading];
    [writer cancelWriting];
    return nil;
  }
  [writer startSessionAtSourceTime:kCMTimeZero];

  // Only the video track drives the bar, and only whole percents get through:
  // a frame-by-frame event would cost a bridge crossing 30 times a second for
  // an update no UI can use.
  __block double lastReported = -1.0;
  void (^onVideoSample)(CMTime) = progress ? ^(CMTime pts) {
    double p = CMTimeGetSeconds(pts) / seconds;
    if (p - lastReported >= 0.01 || p >= 1.0) {
      lastReported = p;
      progress(MIN(MAX(p, 0.0), 1.0));
    }
  } : (void (^)(CMTime))nil;

  // kVideoFrameRate was only ever used for the key frame interval and the
  // bits-per-pixel maths; nothing dropped frames, so a 60 fps clip encoded twice
  // the frames Android would for the same result. Keep one frame per interval.
  double minFrameSeconds = 0.95 / kVideoFrameRate;

  dispatch_group_t group = dispatch_group_create();
  [self pumpFrom:videoOutput
            into:videoInput
           label:"video"
           group:group
 minFrameSeconds:minFrameSeconds
        onSample:onVideoSample];
  if (audioInput != nil) {
    [self pumpFrom:audioOutput into:audioInput label:"audio" group:group
   minFrameSeconds:0 onSample:nil];
  }
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

  // The pumps stop themselves when cancelled, so by here there is only a
  // half-written file to tear down.
  if (self.compressionCancelled) {
    [reader cancelReading];
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    return nil;
  }

  if (reader.status == AVAssetReaderStatusFailed) {
    [writer cancelWriting];
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    return nil;
  }

  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

  if (writer.status != AVAssetWriterStatusCompleted) {
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    return nil;
  }
  return output;
}

/// Drains one track into its writer input on its own queue, leaving the group
/// when the track runs dry or the writer stops accepting samples.
/// `minFrameSeconds` above zero drops samples that arrive closer together than
/// that, which is how the frame rate cap is enforced. Timestamps are left alone,
/// so the clip keeps its original length and plays at the same speed.
- (void)pumpFrom:(AVAssetReaderTrackOutput *)output
            into:(AVAssetWriterInput *)input
           label:(const char *)label
           group:(dispatch_group_t)group
 minFrameSeconds:(double)minFrameSeconds
        onSample:(nullable void (^)(CMTime))onSample
{
  dispatch_queue_t queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
  __block double lastKept = -INFINITY;
  dispatch_group_enter(group);
  [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
    while (input.isReadyForMoreMediaData) {
      // Checked every frame so a cancel takes effect in milliseconds rather than
      // at the end of the clip.
      if (self.compressionCancelled) {
        [input markAsFinished];
        dispatch_group_leave(group);
        return;
      }
      CMSampleBufferRef buffer = [output copyNextSampleBuffer];
      if (buffer == NULL) {
        [input markAsFinished];
        dispatch_group_leave(group);
        return;
      }
      CMTime pts = CMSampleBufferGetPresentationTimeStamp(buffer);
      if (onSample) onSample(pts);
      if (minFrameSeconds > 0 && CMTimeGetSeconds(pts) - lastKept < minFrameSeconds) {
        CFRelease(buffer);
        continue;
      }
      lastKept = CMTimeGetSeconds(pts);
      BOOL appended = [input appendSampleBuffer:buffer];
      CFRelease(buffer);
      if (!appended) {
        [input markAsFinished];
        dispatch_group_leave(group);
        return;
      }
    }
  }];
}

/// The largest frame the video budget can carry, rounded to the even dimensions
/// H.264 requires.
- (CGSize)sizeForBitRate:(NSInteger)bitRate naturalSize:(CGSize)size
{
  CGFloat width = fabs(size.width);
  CGFloat height = fabs(size.height);
  if (width <= 0 || height <= 0) return CGSizeZero;

  CGFloat targetPixels = bitRate / (kVideoBitsPerPixel * kVideoFrameRate);
  CGFloat scale = MIN(sqrt(targetPixels / (width * height)), 1.0);

  // Never shrink past the point where the clip stops being watchable; the
  // bitrate alone carries the rest of the reduction from there.
  CGFloat floorScale = MIN(kMinVideoEdge / MIN(width, height), 1.0);
  if (scale < floorScale) scale = floorScale;

  return CGSizeMake(MAX(floor(width * scale / 2.0) * 2.0, 2.0),
                    MAX(floor(height * scale / 2.0) * 2.0, 2.0));
}

/// The generated emitOnCompressProgress: invokes _eventEmitterCallback without
/// checking it, and that std::function is only wired when the TurboModule
/// runtime builds the module. Anything that constructs it directly -- the unit
/// tests do -- would trap on an empty function, so the check lives here.
- (void)reportProgress:(double)progress index:(NSUInteger)index total:(NSUInteger)total
{
  if (!_eventEmitterCallback) return;
  [self emitOnCompressProgress:@{
    @"progress": @(progress),
    @"index": @(index),
    @"total": @(total)
  }];
}

/// Replacing a file means dropping the one it replaced -- but compressMedia()
/// takes any path the caller hands it, so only this module's own temp files are
/// ever removed.
- (void)removeIfTemporary:(NSString *)path
{
  if ([path hasPrefix:[self tempDirectory]]) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
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
  NSMutableDictionary *pending = self.pendingCropAsset;

  // Encoding, and now a compression search on top of it, are far too much work
  // for the main thread the cropper calls back on.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self finishCrop:image rect:cropRect options:options pending:pending];
  });
}

- (void)finishCrop:(UIImage *)image
              rect:(CGRect)cropRect
           options:(NSDictionary *)options
           pending:(nullable NSMutableDictionary *)pending
{
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
  NSString *previous = pending[@"uri"];
  if ([previous isKindOfClass:[NSString class]]) {
    NSString *cleanPrevious = [previous hasPrefix:@"file://"] ? [[NSURL URLWithString:previous] path] : previous;
    [self removeIfTemporary:cleanPrevious];
  }

  // Compressing comes after cropping, so the budget covers the cropped result
  // rather than the larger frame it was taken from.
  NSString *skipped = nil;
  NSString *compressed = [self compressedPathFor:path
                                            mime:@"image/jpeg"
                                         options:options
                                        progress:nil
                                         skipped:&skipped];
  if (compressed == nil) {
    [self finishWith:[self errorResultWithCode:@"compress_failed"
                                       message:@"Could not compress the image below maxImageFileSize"]];
    return;
  }
  path = compressed;
  CGSize dimensions = [self imageDimensionsAtPath:path];

  NSMutableDictionary *asset = pending ?: [NSMutableDictionary dictionary];
  asset[@"uri"] = [@"file://" stringByAppendingString:path];
  asset[@"type"] = @"image/jpeg";
  asset[@"fileName"] = path.lastPathComponent;
  asset[@"fileSize"] = @([[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize]);
  asset[@"width"] = @(dimensions.width);
  asset[@"height"] = @(dimensions.height);
  asset[@"cropRect"] = @{
    @"x": @(cropRect.origin.x),
    @"y": @(cropRect.origin.y),
    @"width": @(cropRect.size.width),
    @"height": @(cropRect.size.height)
  };
  if ([options[@"includeBase64"] boolValue]) {
    NSData *finalData = [NSData dataWithContentsOfFile:path];
    if (finalData) asset[@"base64"] = [finalData base64EncodedStringWithOptions:0];
  }
  if (skipped) asset[@"compressionSkipped"] = skipped;

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
