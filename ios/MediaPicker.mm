#import "MediaPicker.h"

#import <React/RCTUtils.h>

#import "MPKCameraCapture.h"
#import "MPKCropper.h"
#import "MPKGalleryPicker.h"
#import "MPKImageProcessing.h"
#import "MPKMediaFiles.h"
#import "MPKResults.h"
#import "MPKVideoProcessing.h"

/// The JS surface. Owns the one call that can be open at a time and walks it
/// through gallery, camera and cropper; what each of those screens does lives in
/// MPKGalleryPicker, MPKCameraCapture and MPKCropper, and the file work in
/// MPKImageProcessing and MPKVideoProcessing.
@interface MediaPicker () <PHPickerViewControllerDelegate,
                           TOCropViewControllerDelegate,
                           UIImagePickerControllerDelegate,
                           UINavigationControllerDelegate>
/// Claimed on the JS thread and finished on whichever queue the call's last
/// step ran on, so both go through @synchronized(self): otherwise a finish
/// clearing these could interleave with the next call's claim, and that call
/// would lose the options it had just stored.
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

#pragma mark - The open call

/// NO when another call already holds the slot.
- (BOOL)claim:(RCTPromiseResolveBlock)resolve options:(NSDictionary *)options
{
  @synchronized (self) {
    if (self.pendingResolve != nil) return NO;
    self.pendingResolve = resolve;
    self.pendingOptions = options;
    return YES;
  }
}

- (void)finishWith:(NSDictionary *)result
{
  RCTPromiseResolveBlock resolve;
  @synchronized (self) {
    resolve = self.pendingResolve;
    self.pendingResolve = nil;
    self.pendingOptions = nil;
    self.pendingCropAsset = nil;
  }
  // Outside the lock: resolving hands control to React, which has no business
  // holding up the next claim.
  if (resolve) resolve(result);
}

- (void)present:(UIViewController *)controller orFailWith:(NSString *)code
{
  UIViewController *presenter = RCTPresentedViewController();
  if (presenter == nil) {
    [self finishWith:[MPKResults errorWithCode:code message:@"No view controller to present from"]];
    return;
  }
  [presenter presentViewController:controller animated:YES completion:nil];
}

#pragma mark - JS surface

- (void)pickMedia:(NSDictionary *)options
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
  if (![self claim:resolve options:options]) {
    resolve([MPKResults errorWithCode:MPKErrorPickerBusy message:@"A picker is already open"]);
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    PHPickerViewController *picker = [MPKGalleryPicker pickerForOptions:options];
    picker.delegate = self;
    [self present:picker orFailWith:MPKErrorOthers];
  });
}

- (void)captureMedia:(NSDictionary *)options
             resolve:(RCTPromiseResolveBlock)resolve
              reject:(RCTPromiseRejectBlock)reject
{
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
  if (![self claim:resolve options:options]) {
    resolve([MPKResults errorWithCode:MPKErrorPickerBusy message:@"A picker is already open"]);
    return;
  }
  NSDictionary *unavailable = [MPKCameraCapture unavailableResultForOptions:options];
  if (unavailable != nil) {
    [self finishWith:unavailable];
    return;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    UIImagePickerController *camera = [MPKCameraCapture cameraForOptions:options];
    camera.delegate = self;
    [self present:camera orFailWith:MPKErrorOthers];
  });
}

- (void)cropImage:(NSDictionary *)options
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject
{
  // A cancel belongs to the batch that was running, not to this one.
  self.compressionCancelled = NO;
  if (![self claim:resolve options:options]) {
    resolve([MPKResults errorWithCode:MPKErrorPickerBusy message:@"A picker is already open"]);
    return;
  }
  NSString *path = options[@"path"];
  if (path.length == 0) {
    [self finishWith:[MPKResults errorWithCode:MPKErrorInvalidOptions message:@"path is required"]];
    return;
  }
  UIImage *image = [UIImage imageWithContentsOfFile:[MPKMediaFiles pathFromURI:path]];
  if (image == nil) {
    [self finishWith:[MPKResults errorWithCode:MPKErrorCannotProcessAsset
                                       message:@"Could not read the image"]];
    return;
  }

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
    resolve([MPKResults errorWithCode:MPKErrorInvalidOptions message:@"path is required"]);
    return;
  }
  NSString *cleanPath = [MPKMediaFiles pathFromURI:path];
  if (![[NSFileManager defaultManager] fileExistsAtPath:cleanPath]) {
    resolve([MPKResults errorWithCode:MPKErrorCannotProcessAsset
                              message:[NSString stringWithFormat:@"There is no file at %@", path]]);
    return;
  }

  NSString *mime = [MPKMediaFiles mimeTypeForPath:cleanPath];
  BOOL isVideo = [mime hasPrefix:@"video/"];
  if (!isVideo && ![mime hasPrefix:@"image/"]) {
    resolve([MPKResults errorWithCode:MPKErrorInvalidOptions
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
      resolve([MPKResults errorWithCode:MPKErrorCompressFailed
                                message:isVideo
                                    ? @"Could not compress the video below maxVideoFileSize"
                                    : @"Could not compress the image below maxImageFileSize"]);
      return;
    }

    // The name follows the bytes, the same way it does after a re-encode.
    NSString *fileName = [[cleanPath.lastPathComponent stringByDeletingPathExtension]
        stringByAppendingPathExtension:compressed.pathExtension];
    NSMutableDictionary *asset =
        [MPKResults assetForPath:compressed
                        fileName:fileName
                            mime:[MPKMediaFiles mimeTypeForPath:compressed]
                         options:options
                 assetIdentifier:nil
                           extra:isVideo ? [MPKVideoProcessing metadataAtPath:compressed] : nil];
    asset[@"originalPath"] = path;
    if (skipped) asset[@"compressionSkipped"] = skipped;
    resolve([MPKResults successWithAssets:@[asset] deselected:nil]);
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
  [MPKMediaFiles cleanTempFiles:path];
  resolve(nil);
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
  [picker dismissViewControllerAnimated:YES completion:nil];

  // Unticking everything and tapping Add also lands here, indistinguishable
  // from Cancel, so nothing is reported as deselected in that case.
  if (results.count == 0) {
    [self finishWith:[MPKResults cancelled]];
    return;
  }

  NSDictionary *options = self.pendingOptions ?: @{};
  NSArray<NSString *> *deselected = nil;
  results = [MPKGalleryPicker freshResults:results options:options deselected:&deselected];

  if (results.count == 0) {
    [self finishWith:[MPKResults successWithAssets:@[] deselected:deselected]];
    return;
  }

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    // The picks load concurrently and finish in any order, so each one lands in
    // its own slot: the assets come back in the order the user picked them.
    NSMutableArray *slots = [NSMutableArray arrayWithCapacity:results.count];
    for (NSUInteger i = 0; i < results.count; i++) [slots addObject:[NSNull null]];
    dispatch_group_t group = dispatch_group_create();
    __block NSString *failure = nil;
    __block NSString *failureCode = nil;

    for (NSUInteger idx = 0; idx < results.count; idx++) {
      dispatch_group_enter(group);
      [self processResult:results[idx]
                  options:options
                    index:idx
                    total:results.count
               completion:^(NSDictionary *asset, NSString *code, NSString *error) {
        @synchronized (slots) {
          if (asset) {
            slots[idx] = asset;
          } else if (error && failure == nil) {
            failure = error;
            failureCode = code;
          }
        }
        dispatch_group_leave(group);
      }];
    }

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSMutableArray<NSDictionary *> *assets = [NSMutableArray array];
    for (id slot in slots) {
      if (slot != [NSNull null]) [assets addObject:slot];
    }

    if (assets.count == 0) {
      [self finishWith:[MPKResults errorWithCode:failureCode ?: MPKErrorCannotProcessAsset
                                         message:failure ?: @"Could not read the selected media"]];
      return;
    }

    BOOL isSingleImage = assets.count == 1 && [assets[0][@"type"] hasPrefix:@"image/"];
    if ([options[@"cropping"] boolValue] && isSingleImage) {
      UIImage *image = [UIImage imageWithContentsOfFile:[MPKMediaFiles pathFromURI:assets[0][@"uri"]]];
      if (image != nil) {
        self.pendingCropAsset = [assets[0] mutableCopy];
        dispatch_async(dispatch_get_main_queue(), ^{
          [self presentCropperWithImage:image options:options];
        });
        return;
      }
    }

    [self finishWith:[MPKResults successWithAssets:assets deselected:deselected]];
  });
}

- (void)processResult:(PHPickerResult *)result
              options:(NSDictionary *)options
                index:(NSUInteger)index
                total:(NSUInteger)total
           completion:(void (^)(NSDictionary *asset, NSString *code, NSString *error))completion
{
  [MPKGalleryPicker copyResult:result
                    completion:^(NSString *path, NSString *fileName, BOOL isVideo, NSString *error) {
    if (path == nil) {
      completion(nil, MPKErrorCannotProcessAsset, error);
      return;
    }

    NSString *compressionError = nil;
    NSDictionary *asset = isVideo
        ? [self videoAssetAtPath:path
                        fileName:fileName
                         options:options
                 assetIdentifier:result.assetIdentifier
                           index:index
                           total:total
                compressionError:&compressionError]
        : [self imageAssetAtPath:path
                        fileName:fileName
                         options:options
                 assetIdentifier:result.assetIdentifier
                compressionError:&compressionError];
    if (asset == nil) {
      completion(nil, MPKErrorCompressFailed, compressionError);
      return;
    }
    completion(asset, nil, nil);
  }];
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
      NSString *destination = [MPKMediaFiles tempPathWithExtension:extension];
      NSError *copyError = nil;
      [[NSFileManager defaultManager] copyItemAtPath:mediaURL.path
                                              toPath:destination
                                               error:&copyError];
      if (copyError != nil) {
        [self finishWith:[MPKResults errorWithCode:MPKErrorCannotProcessAsset
                                           message:copyError.localizedDescription]];
        return;
      }
      NSString *compressionError = nil;
      NSDictionary *asset = [self videoAssetAtPath:destination
                                          fileName:nil
                                           options:options
                                   assetIdentifier:nil
                                             index:0
                                             total:1
                                  compressionError:&compressionError];
      if (asset == nil) {
        [self finishWith:[MPKResults errorWithCode:MPKErrorCompressFailed message:compressionError]];
        return;
      }
      [self finishWith:[MPKResults successWithAssets:@[asset] deselected:nil]];
      return;
    }

    if (image == nil) {
      [self finishWith:[MPKResults errorWithCode:MPKErrorCannotProcessAsset
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
    NSString *path = [MPKMediaFiles tempPathWithExtension:@"jpg"];
    if (data == nil || ![data writeToFile:path atomically:YES]) {
      [self finishWith:[MPKResults errorWithCode:MPKErrorCannotProcessAsset
                                         message:@"Could not write the captured photo"]];
      return;
    }
    NSString *compressionError = nil;
    NSDictionary *asset = [self imageAssetAtPath:path
                                        fileName:nil
                                         options:options
                                 assetIdentifier:nil
                                compressionError:&compressionError];
    if (asset == nil) {
      [self finishWith:[MPKResults errorWithCode:MPKErrorCompressFailed message:compressionError]];
      return;
    }
    [self finishWith:[MPKResults successWithAssets:@[asset] deselected:nil]];
  });
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker
{
  [picker dismissViewControllerAnimated:YES completion:nil];
  [self finishWith:[MPKResults cancelled]];
}

#pragma mark - Building assets

- (nullable NSDictionary *)imageAssetAtPath:(NSString *)path
                                   fileName:(nullable NSString *)fileName
                                    options:(NSDictionary *)options
                            assetIdentifier:(nullable NSString *)assetIdentifier
                           compressionError:(NSString **)compressionError
{
  NSString *mime = [MPKMediaFiles mimeTypeForPath:path];
  NSString *finalPath = [MPKImageProcessing processImageAtPath:path options:options mime:&mime];

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

  NSMutableDictionary *asset = [MPKResults assetForPath:finalPath
                                               fileName:[self reportedName:fileName forPath:finalPath]
                                                   mime:mime
                                                options:options
                                        assetIdentifier:assetIdentifier
                                                  extra:nil];
  if (skipped) asset[@"compressionSkipped"] = skipped;
  return asset;
}

- (nullable NSDictionary *)videoAssetAtPath:(NSString *)path
                                   fileName:(nullable NSString *)fileName
                                    options:(NSDictionary *)options
                            assetIdentifier:(nullable NSString *)assetIdentifier
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
  NSMutableDictionary *asset = [MPKResults assetForPath:compressed
                                               fileName:[self reportedName:fileName forPath:compressed]
                                                   mime:[MPKMediaFiles mimeTypeForPath:compressed]
                                                options:options
                                        assetIdentifier:assetIdentifier
                                                  extra:[MPKVideoProcessing metadataAtPath:compressed]];
  if (skipped) asset[@"compressionSkipped"] = skipped;
  return asset;
}

/// A camera shot or recording has no display name of its own, so the caller
/// passes nil and the file that actually ends up on disk names it -- otherwise a
/// re-encode would leave the asset naming the temp file it just replaced. A
/// gallery pick keeps its name, with the extension the bytes actually have, so
/// a re-encoded PNG is not reported as "shot.png" while `type` says JPEG.
- (NSString *)reportedName:(nullable NSString *)fileName forPath:(NSString *)path
{
  NSString *name = fileName ?: path.lastPathComponent;
  if (path.pathExtension.length > 0 && ![name.pathExtension isEqualToString:path.pathExtension]) {
    name = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:path.pathExtension];
  }
  return name;
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
  unsigned long long minBytes = [options[@"minimumFileSizeForCompress"] unsignedLongLongValue];
  unsigned long long budget =
      [options[isVideo ? @"maxVideoFileSize" : @"maxImageFileSize"] unsignedLongLongValue];
  unsigned long long size = [MPKMediaFiles fileSizeAtPath:path];

  __weak MediaPicker *weakSelf = self;
  NSString *result = isVideo
      ? [MPKVideoProcessing compressVideoAtPath:path
                                     toMaxBytes:budget
                                       minBytes:minBytes
                                       progress:progress
                                    isCancelled:^BOOL { return weakSelf.compressionCancelled; }]
      : [MPKImageProcessing compressImageAtPath:path toMaxBytes:budget minBytes:minBytes];

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

#pragma mark - Cropping

- (void)presentCropperWithImage:(UIImage *)image options:(NSDictionary *)options
{
  TOCropViewController *cropper = [MPKCropper cropperForImage:image options:options];
  cropper.delegate = self;
  [self present:cropper orFailWith:MPKErrorCropFailed];
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
  NSData *data = UIImageJPEGRepresentation([MPKCropper outputForCrop:image options:options], quality);
  if (data == nil) {
    [self finishWith:[MPKResults errorWithCode:MPKErrorCropFailed
                                       message:@"Could not encode the cropped image"]];
    return;
  }

  NSString *path = [MPKMediaFiles tempPathWithExtension:@"jpg"];
  if (![data writeToFile:path atomically:YES]) {
    [self finishWith:[MPKResults errorWithCode:MPKErrorCropFailed
                                       message:@"Could not write the cropped image"]];
    return;
  }

  // The pre-crop temp file is now dead weight.
  NSString *previous = pending[@"uri"];
  if ([previous isKindOfClass:[NSString class]]) {
    [MPKMediaFiles removeIfTemporary:[MPKMediaFiles pathFromURI:previous]];
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
    [self finishWith:[MPKResults errorWithCode:MPKErrorCompressFailed
                                       message:@"Could not compress the image below maxImageFileSize"]];
    return;
  }
  path = compressed;
  CGSize dimensions = [MPKImageProcessing dimensionsAtPath:path];

  NSMutableDictionary *asset = pending ?: [NSMutableDictionary dictionary];
  asset[@"uri"] = [@"file://" stringByAppendingString:path];
  asset[@"type"] = @"image/jpeg";
  asset[@"fileName"] = path.lastPathComponent;
  asset[@"fileSize"] = @([MPKMediaFiles fileSizeAtPath:path]);
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

  [self finishWith:[MPKResults successWithAssets:@[asset] deselected:nil]];
}

- (void)cropViewController:(TOCropViewController *)cropViewController
        didFinishCancelled:(BOOL)cancelled
{
  [cropViewController dismissViewControllerAnimated:YES completion:nil];
  [self finishWith:[MPKResults cancelled]];
}

@end
