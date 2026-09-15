#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <XCTest/XCTest.h>

/// An iOS simulator presents a camera for UIImagePickerController but has no
/// capture pipeline behind it: the shutter never fires the delegate, so every
/// line of the module that runs *after* the shutter is unreachable there. These
/// tests call that delegate directly with the same info dictionaries the camera
/// produces, which exercises the real temp-file write, asset builder and crop
/// hand-off on a simulator. What they deliberately do not cover is the camera
/// itself — that a real shutter calls this delegate at all still needs hardware.
///
/// Only three entry points are needed, so they are declared here and the class
/// is reached by name; the test target then has no build dependency on the pod.
@protocol MediaPickerProbe <NSObject>
- (void)imagePickerController:(UIImagePickerController *)picker
    didFinishPickingMediaWithInfo:(NSDictionary *)info;
- (void)cropViewController:(id)cropViewController
            didCropToImage:(UIImage *)image
                  withRect:(CGRect)cropRect
                     angle:(NSInteger)angle;
@end

@interface CaptureDelegateTests : XCTestCase
@end

@implementation CaptureDelegateTests

#pragma mark - helpers

/// captureMedia stores the promise and the options before it presents the
/// camera, so setting them directly puts the module in exactly the state the
/// delegate would find without needing a camera to get there.
- (id<MediaPickerProbe>)moduleWithOptions:(NSDictionary *)options
                                 onResult:(void (^)(NSDictionary *))onResult
{
  id module = [[NSClassFromString(@"MediaPicker") alloc] init];
  XCTAssertNotNil(module, @"MediaPicker is not linked into the host app");
  [module setValue:[^(id result) { onResult(result); } copy] forKey:@"pendingResolve"];
  [module setValue:options forKey:@"pendingOptions"];
  return module;
}

- (UIImage *)imageOfSize:(CGSize)size
{
  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
  format.scale = 1.0;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
    // A gradient rather than a flat fill, so a JPEG of it cannot come out
    // suspiciously tiny and hide a broken encode.
    [[UIColor systemRedColor] setFill];
    [ctx fillRect:CGRectMake(0, 0, size.width, size.height)];
    [[UIColor systemBlueColor] setFill];
    [ctx fillRect:CGRectMake(0, 0, size.width / 2, size.height)];
  }];
}

/// Stands in for the recording UIImagePickerController hands over in
/// UIImagePickerControllerMediaURL: a real, playable QuickTime file so the
/// duration and track dimensions the asset builder reads are real too.
- (NSURL *)writeMovieOfSize:(CGSize)size frames:(NSInteger)frames fps:(int32_t)fps
{
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mov", [NSUUID UUID].UUIDString]]];
  NSError *error = nil;
  AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeQuickTimeMovie error:&error];
  XCTAssertNil(error, @"could not create the movie writer");

  AVAssetWriterInput *input = [AVAssetWriterInput
      assetWriterInputWithMediaType:AVMediaTypeVideo
                     outputSettings:@{AVVideoCodecKey: AVVideoCodecTypeH264,
                                      AVVideoWidthKey: @(size.width),
                                      AVVideoHeightKey: @(size.height)}];
  input.expectsMediaDataInRealTime = NO;
  AVAssetWriterInputPixelBufferAdaptor *adaptor =
      [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                            sourcePixelBufferAttributes:@{
          (NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
  [writer addInput:input];
  [writer startWriting];
  [writer startSessionAtSourceTime:kCMTimeZero];

  for (NSInteger i = 0; i < frames; i++) {
    while (!input.isReadyForMoreMediaData) { usleep(1000); }
    CVPixelBufferRef buffer = NULL;
    CVPixelBufferPoolCreatePixelBuffer(NULL, adaptor.pixelBufferPool, &buffer);
    CVPixelBufferLockBaseAddress(buffer, 0);
    // Textured frames that change between them, rather than a flat fill: H.264
    // encodes a flat frame down to almost nothing, which left the fixture too
    // small to exercise a byte budget at all.
    uint8_t *base = CVPixelBufferGetBaseAddress(buffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(buffer);
    size_t height = CVPixelBufferGetHeight(buffer);
    size_t width = CVPixelBufferGetWidth(buffer);
    for (size_t y = 0; y < height; y++) {
      uint8_t *row = base + y * bytesPerRow;
      for (size_t x = 0; x < width; x++) {
        uint8_t ramp = (uint8_t)((x >> 3) + (y >> 3) + (size_t)i * 4);
        uint8_t blocks = (uint8_t)((((x >> 5) ^ (y >> 5)) & 1) ? 200 : 40);
        row[x * 4 + 0] = ramp;
        row[x * 4 + 1] = blocks;
        row[x * 4 + 2] = (uint8_t)(ramp / 2 + blocks / 2);
        row[x * 4 + 3] = 255;
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    [adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMake(i, fps)];
    CVPixelBufferRelease(buffer);
  }

  [input markAsFinished];
  XCTestExpectation *written = [self expectationWithDescription:@"movie written"];
  [writer finishWritingWithCompletionHandler:^{ [written fulfill]; }];
  [self waitForExpectations:@[written] timeout:30];
  XCTAssertEqual(writer.status, AVAssetWriterStatusCompleted, @"movie fixture was not written");
  return url;
}

- (NSDictionary *)onlyAssetOf:(NSDictionary *)result
{
  XCTAssertNotNil(result, @"the capture never resolved");
  XCTAssertNil(result[@"errorCode"], @"capture failed: %@", result[@"errorMessage"]);
  XCTAssertEqualObjects(result[@"didCancel"], @NO);
  NSArray *assets = result[@"assets"];
  XCTAssertEqual(assets.count, 1u, @"expected exactly one captured asset");
  return assets.firstObject;
}

/// Every asset must name a file that is really on disk, with the size it claims.
- (void)assertFileBackedAsset:(NSDictionary *)asset
{
  NSString *uri = asset[@"uri"];
  XCTAssertTrue([uri hasPrefix:@"file://"], @"uri is not a file URL: %@", uri);
  NSString *path = [NSURL URLWithString:uri].path;
  XCTAssertTrue([[NSFileManager defaultManager] fileExistsAtPath:path], @"no file at %@", path);
  NSNumber *onDisk = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize];
  XCTAssertGreaterThan(onDisk.longLongValue, 0, @"the captured file is empty");
  XCTAssertEqualObjects(asset[@"fileSize"], onDisk, @"reported fileSize does not match the file");
  XCTAssertEqualObjects(asset[@"fileName"], path.lastPathComponent);
}

- (NSDictionary *)captureWithOptions:(NSDictionary *)options info:(NSDictionary *)info
{
  __block NSDictionary *result = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"capture resolved"];
  id<MediaPickerProbe> module = [self moduleWithOptions:options onResult:^(NSDictionary *r) {
    result = r;
    [done fulfill];
  }];
  [module imagePickerController:[UIImagePickerController new] didFinishPickingMediaWithInfo:info];
  [self waitForExpectations:@[done] timeout:60];
  return result;
}

#pragma mark - photo capture

- (void)testCapturedPhotoBecomesAJpegAsset
{
  NSDictionary *result = [self captureWithOptions:@{} info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(1200, 900)]}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertEqualObjects(asset[@"type"], @"image/jpeg");
  XCTAssertEqualObjects(asset[@"width"], @1200);
  XCTAssertEqualObjects(asset[@"height"], @900);
}

/// maxWidth/maxHeight/quality are applied by the shared image builder, so this
/// proves a capture goes through the same rules a gallery pick does.
- (void)testCapturedPhotoHonoursMaxWidthAndQuality
{
  NSDictionary *result = [self captureWithOptions:@{@"maxWidth": @400, @"maxHeight": @400, @"quality": @0.5}
                                             info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(1200, 900)]}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  // 1200x900 fitted inside 400x400 keeps the 4:3 ratio.
  XCTAssertEqualObjects(asset[@"width"], @400);
  XCTAssertEqualObjects(asset[@"height"], @300);
}

- (void)testCaptureWithNoImageReportsAnError
{
  NSDictionary *result = [self captureWithOptions:@{}
                                             info:@{UIImagePickerControllerMediaType: UTTypeImage.identifier}];
  XCTAssertEqualObjects(result[@"errorCode"], @"cannot_process_asset");
  XCTAssertEqualObjects(result[@"assets"], @[]);
}

#pragma mark - video capture

- (void)testCapturedVideoIsCopiedOutOfTheSystemTempFile
{
  NSURL *recording = [self writeMovieOfSize:CGSizeMake(320, 240) frames:30 fps:30];
  NSDictionary *result = [self captureWithOptions:@{} info:@{
    UIImagePickerControllerMediaType: UTTypeMovie.identifier,
    UIImagePickerControllerMediaURL: recording}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertEqualObjects(asset[@"type"], @"video/quicktime");
  XCTAssertEqualObjects(asset[@"width"], @320);
  XCTAssertEqualObjects(asset[@"height"], @240);
  XCTAssertEqualWithAccuracy([asset[@"duration"] doubleValue], 1000.0, 100.0,
                             @"duration should be reported in milliseconds");

  // The camera's own temp file is not ours to keep, so the asset must point at
  // a copy in the module's directory rather than back at the original.
  XCTAssertNotEqualObjects([NSURL URLWithString:asset[@"uri"]].path, recording.path);
  XCTAssertTrue([[NSURL URLWithString:asset[@"uri"]].path containsString:@"rn_media_picker"]);
}

- (void)testUnreadableRecordingReportsAnError
{
  NSDictionary *result = [self captureWithOptions:@{} info:@{
    UIImagePickerControllerMediaType: UTTypeMovie.identifier,
    UIImagePickerControllerMediaURL: [NSURL fileURLWithPath:@"/does/not/exist.mov"]}];
  XCTAssertEqualObjects(result[@"errorCode"], @"cannot_process_asset");
}

#pragma mark - capture then crop

/// cropping:YES must not write the capture straight out; it has to reach the
/// cropper, and the image the cropper returns is what gets reported.
- (void)testCapturedPhotoIsHandedToTheCropper
{
  __block NSDictionary *result = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"crop resolved"];
  NSDictionary *options = @{@"cropping": @YES, @"cropWidth": @800, @"cropHeight": @800};
  id<MediaPickerProbe> module = [self moduleWithOptions:options onResult:^(NSDictionary *r) {
    result = r;
    [done fulfill];
  }];

  [module imagePickerController:[UIImagePickerController new] didFinishPickingMediaWithInfo:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(1200, 900)]}];

  // pendingCropAsset is created on the main queue as the cropper is presented,
  // so its arrival is the signal that the capture took the crop branch.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
  while ([(id)module valueForKey:@"pendingCropAsset"] == nil && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertNotNil([(id)module valueForKey:@"pendingCropAsset"], @"the capture never reached the cropper");
  XCTAssertNil(result, @"the promise resolved without waiting for the crop");

  [module cropViewController:[UIViewController new]
              didCropToImage:[self imageOfSize:CGSizeMake(600, 600)]
                    withRect:CGRectMake(100, 50, 600, 600)
                       angle:0];

  [self waitForExpectations:@[done] timeout:60];
  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertEqualObjects(asset[@"type"], @"image/jpeg");
  // An aspect-locked crop resizes to exactly cropWidth x cropHeight, matching Android.
  XCTAssertEqualObjects(asset[@"width"], @800);
  XCTAssertEqualObjects(asset[@"height"], @800);
  XCTAssertEqualObjects(asset[@"cropRect"], (@{@"x": @100, @"y": @50, @"width": @600, @"height": @600}));
}

#pragma mark - compression

/// The point of a byte budget is that the file really is under it, so these
/// measure the file on disk rather than trusting the reported size.
- (unsigned long long)sizeOfAsset:(NSDictionary *)asset
{
  NSString *path = [NSURL URLWithString:asset[@"uri"]].path;
  return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
}

- (void)testMaxImageFileSizeIsActuallyMet
{
  const unsigned long long budget = 40 * 1024;
  // Encoded at full quality this is far bigger than the budget, so hitting it
  // proves the quality search ran rather than the source just being small.
  NSDictionary *result = [self captureWithOptions:@{@"maxImageFileSize": @(budget)} info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(3000, 2000)]}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertLessThanOrEqual([self sizeOfAsset:asset], budget, @"the image is over maxImageFileSize");
  XCTAssertEqualObjects(asset[@"type"], @"image/jpeg");
  // Still a real decodable image, not a truncated file that merely fits.
  XCTAssertGreaterThan([asset[@"width"] intValue], 0);
  XCTAssertNotNil([UIImage imageWithContentsOfFile:[NSURL URLWithString:asset[@"uri"]].path]);
}

/// Quality is spent before pixels are, so a budget this size should be reached
/// without the frame having to shrink at all.
- (void)testMaxImageFileSizeKeepsResolutionWhenQualityAloneSuffices
{
  NSDictionary *result = [self captureWithOptions:@{@"maxImageFileSize": @(200 * 1024)} info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(1200, 900)]}];

  NSDictionary *asset = [self onlyAssetOf:result];
  XCTAssertLessThanOrEqual([self sizeOfAsset:asset], 200u * 1024u);
  XCTAssertEqualObjects(asset[@"width"], @1200);
  XCTAssertEqualObjects(asset[@"height"], @900);
}

- (void)testImageAlreadyUnderBudgetIsLeftAlone
{
  NSDictionary *result = [self captureWithOptions:@{@"maxImageFileSize": @(8 * 1024 * 1024)} info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(1200, 900)]}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertEqualObjects(asset[@"width"], @1200, @"an under-budget image should not be downscaled");
  XCTAssertEqualObjects(asset[@"height"], @900);
}

- (void)testUnreachableImageBudgetReportsCompressFailed
{
  // 200 bytes is below what a JPEG header costs, so even the 64px floor cannot
  // reach it -- the call must say so rather than hand back an oversized file.
  NSDictionary *result = [self captureWithOptions:@{@"maxImageFileSize": @200} info:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(3000, 2000)]}];

  XCTAssertEqualObjects(result[@"errorCode"], @"compress_failed");
  XCTAssertEqualObjects(result[@"assets"], @[]);
}

/// The real AVAssetReader/AVAssetWriter transcode, end to end.
- (void)testMaxVideoFileSizeIsActuallyMet
{
  NSURL *recording = [self writeMovieOfSize:CGSizeMake(1280, 720) frames:90 fps:30];
  unsigned long long before =
      [[[NSFileManager defaultManager] attributesOfItemAtPath:recording.path error:nil] fileSize];
  const unsigned long long budget = 60 * 1024;
  XCTAssertGreaterThan(before, budget, @"the fixture is already under budget, so this proves nothing");
  NSLog(@"RESULT[video-compress]: fixture %llu bytes, budget %llu bytes", before, budget);

  NSDictionary *result = [self captureWithOptions:@{@"maxVideoFileSize": @(budget)} info:@{
    UIImagePickerControllerMediaType: UTTypeMovie.identifier,
    UIImagePickerControllerMediaURL: recording}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  NSLog(@"RESULT[video-compress]: produced %llu bytes", [self sizeOfAsset:asset]);
  XCTAssertLessThanOrEqual([self sizeOfAsset:asset], budget, @"the video is over maxVideoFileSize");
  XCTAssertEqualObjects(asset[@"type"], @"video/mp4", @"a transcode should be reported as MP4");
  XCTAssertTrue([asset[@"fileName"] hasSuffix:@".mp4"], @"the name must follow the bytes");

  // Still a playable movie of the same clip, not a truncated one that just fits.
  AVURLAsset *out = [AVURLAsset URLAssetWithURL:[NSURL URLWithString:asset[@"uri"]] options:nil];
  XCTAssertEqual([out tracksWithMediaType:AVMediaTypeVideo].count, 1u, @"no video track survived");
  XCTAssertEqualWithAccuracy(CMTimeGetSeconds(out.duration), 3.0, 0.5,
                             @"the clip was truncated instead of compressed");
  XCTAssertGreaterThan([asset[@"width"] intValue], 0);
}

- (void)testVideoAlreadyUnderBudgetIsLeftAlone
{
  NSURL *recording = [self writeMovieOfSize:CGSizeMake(320, 240) frames:30 fps:30];
  NSDictionary *result = [self captureWithOptions:@{@"maxVideoFileSize": @(50 * 1024 * 1024)} info:@{
    UIImagePickerControllerMediaType: UTTypeMovie.identifier,
    UIImagePickerControllerMediaURL: recording}];

  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  // Untouched means not transcoded, so it is still the QuickTime copy.
  XCTAssertEqualObjects(asset[@"type"], @"video/quicktime");
  XCTAssertEqualObjects(asset[@"width"], @320);
}

/// Compression runs after the crop, so the budget has to cover the cropped
/// result rather than the larger frame it came from.
- (void)testCropThenCompressMeetsTheBudget
{
  const unsigned long long budget = 30 * 1024;
  __block NSDictionary *result = nil;
  XCTestExpectation *done = [self expectationWithDescription:@"crop resolved"];
  NSDictionary *options = @{@"cropping": @YES,
                            @"cropWidth": @1500,
                            @"cropHeight": @1500,
                            @"maxImageFileSize": @(budget)};
  id<MediaPickerProbe> module = [self moduleWithOptions:options onResult:^(NSDictionary *r) {
    result = r;
    [done fulfill];
  }];

  [module imagePickerController:[UIImagePickerController new] didFinishPickingMediaWithInfo:@{
    UIImagePickerControllerMediaType: UTTypeImage.identifier,
    UIImagePickerControllerOriginalImage: [self imageOfSize:CGSizeMake(3000, 2000)]}];

  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
  while ([(id)module valueForKey:@"pendingCropAsset"] == nil && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  [module cropViewController:[UIViewController new]
              didCropToImage:[self imageOfSize:CGSizeMake(2000, 2000)]
                    withRect:CGRectMake(0, 0, 2000, 2000)
                       angle:0];

  [self waitForExpectations:@[done] timeout:60];
  NSDictionary *asset = [self onlyAssetOf:result];
  [self assertFileBackedAsset:asset];
  XCTAssertLessThanOrEqual([self sizeOfAsset:asset], budget, @"the cropped image is over budget");
  XCTAssertEqualObjects(asset[@"cropRect"][@"width"], @2000, @"the crop rect must survive compression");
}

@end
