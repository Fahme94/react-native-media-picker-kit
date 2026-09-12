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
    memset(CVPixelBufferGetBaseAddress(buffer), (int)(i * 8) & 0xFF,
           CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer));
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

@end
