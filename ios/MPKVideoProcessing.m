#import "MPKVideoProcessing.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>

#import "MPKMediaFiles.h"

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

@implementation MPKVideoProcessing

+ (NSDictionary *)metadataAtPath:(NSString *)path
{
  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetTrack *track = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
  CGSize size = track ? CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform)
                      : CGSizeZero;

  return @{
    @"duration": @(CMTimeGetSeconds(asset.duration) * 1000.0), // ms, to match Android
    @"bitrate": @(track ? track.estimatedDataRate : 0),
    @"width": @(fabs(size.width)),
    @"height": @(fabs(size.height)),
  };
}

+ (nullable NSString *)compressVideoAtPath:(NSString *)path
                                toMaxBytes:(unsigned long long)maxBytes
                                  minBytes:(unsigned long long)minBytes
                                  progress:(nullable void (^)(double))progress
                               isCancelled:(BOOL (^)(void))isCancelled
{
  unsigned long long size = [MPKMediaFiles fileSizeAtPath:path];
  if (maxBytes == 0 || size <= maxBytes) return path;
  // Over budget, but not by enough to be worth a whole transcode. Returns a
  // file that is still over its budget, deliberately.
  if (minBytes > 0 && size < minBytes) return path;

  if (isCancelled()) return path;

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
                                   progress:passProgress
                                isCancelled:isCancelled];
    if (output == nil) {
      // A cancel is not a failure. The caller asked for this, so hand back the
      // original rather than reporting compress_failed.
      if (isCancelled()) return path;
      return nil;
    }

    unsigned long long produced = [MPKMediaFiles fileSizeAtPath:output];
    if (produced <= maxBytes) {
      if (progress) progress(1.0);
      [MPKMediaFiles removeIfTemporary:path];
      return output;
    }
    // Scale the next request by how far this pass actually missed, keeping the
    // margin so the correction lands inside the limit rather than back on it.
    target = (unsigned long long)(target * (maxBytes * kSizeSafetyMargin) / (CGFloat)produced);
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
  }
  return nil;
}

+ (NSString *)mp4AtPath:(NSString *)path
{
  if ([path.pathExtension.lowercaseString isEqualToString:@"mp4"]) return path;

  AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
  AVAssetExportSession *session =
      [AVAssetExportSession exportSessionWithAsset:asset presetName:AVAssetExportPresetPassthrough];
  if (![session.supportedFileTypes containsObject:AVFileTypeMPEG4]) return path;

  NSString *output = [MPKMediaFiles tempPathWithExtension:@"mp4"];
  session.outputURL = [NSURL fileURLWithPath:output];
  session.outputFileType = AVFileTypeMPEG4;
  session.shouldOptimizeForNetworkUse = YES;

  // Every caller is already off the main thread, and a passthrough copy only
  // moves bytes, so waiting here is cheaper than threading a callback through.
  dispatch_semaphore_t done = dispatch_semaphore_create(0);
  [session exportAsynchronouslyWithCompletionHandler:^{
    dispatch_semaphore_signal(done);
  }];
  dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);

  if (session.status != AVAssetExportSessionStatusCompleted) {
    [[NSFileManager defaultManager] removeItemAtPath:output error:nil];
    return path;
  }
  [MPKMediaFiles removeIfTemporary:path];
  return output;
}

+ (nullable NSString *)transcodeAsset:(AVURLAsset *)asset
                                video:(AVAssetTrack *)videoTrack
                              seconds:(Float64)seconds
                               budget:(unsigned long long)budget
                             progress:(nullable void (^)(double))progress
                          isCancelled:(BOOL (^)(void))isCancelled
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

  NSString *output = [MPKMediaFiles tempPathWithExtension:@"mp4"];
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
            onSample:onVideoSample
         isCancelled:isCancelled];
  if (audioInput != nil) {
    [self pumpFrom:audioOutput
                into:audioInput
               label:"audio"
               group:group
     minFrameSeconds:0
            onSample:nil
         isCancelled:isCancelled];
  }
  dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

  // The pumps stop themselves when cancelled, so by here there is only a
  // half-written file to tear down.
  if (isCancelled()) {
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
+ (void)pumpFrom:(AVAssetReaderTrackOutput *)output
               into:(AVAssetWriterInput *)input
              label:(const char *)label
              group:(dispatch_group_t)group
    minFrameSeconds:(double)minFrameSeconds
           onSample:(nullable void (^)(CMTime))onSample
        isCancelled:(BOOL (^)(void))isCancelled
{
  dispatch_queue_t queue = dispatch_queue_create(label, DISPATCH_QUEUE_SERIAL);
  __block double lastKept = -INFINITY;
  dispatch_group_enter(group);
  [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
    while (input.isReadyForMoreMediaData) {
      // Checked every frame so a cancel takes effect in milliseconds rather than
      // at the end of the clip.
      if (isCancelled()) {
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
+ (CGSize)sizeForBitRate:(NSInteger)bitRate naturalSize:(CGSize)size
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

@end
