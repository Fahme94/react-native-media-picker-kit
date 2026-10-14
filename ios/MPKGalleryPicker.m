#import "MPKGalleryPicker.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "MPKMediaFiles.h"

@implementation MPKGalleryPicker

+ (PHPickerViewController *)pickerForOptions:(NSDictionary *)options
{
  NSString *mediaType = options[@"mediaType"] ?: @"photo";

  // The photo library is what makes PHPicker report assetIdentifier, which is
  // both originalPath and the key for preselectedAssetIdentifiers. It needs no
  // library permission.
  PHPickerConfiguration *config =
      [[PHPickerConfiguration alloc] initWithPhotoLibrary:[PHPhotoLibrary sharedPhotoLibrary]];
  config.selectionLimit = [options[@"selectionLimit"] integerValue]; // 0 means unlimited, as in PHPicker
  // Preselected items occupy slots of selectionLimit, which is what the caller
  // asked for: the limit is the total they can hold.
  config.preselectedAssetIdentifiers = options[@"preselected"] ?: @[];

  if ([mediaType isEqualToString:@"photo"]) {
    config.filter = [PHPickerFilter imagesFilter];
  } else if ([mediaType isEqualToString:@"video"]) {
    config.filter = [PHPickerFilter videosFilter];
  } else {
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
      [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
    ]];
  }

  PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
  picker.modalPresentationStyle = [self presentationStyleFrom:options[@"presentationStyle"]];
  return picker;
}

+ (UIModalPresentationStyle)presentationStyleFrom:(NSString *)style
{
  if ([style isEqualToString:@"pageSheet"]) return UIModalPresentationPageSheet;
  if ([style isEqualToString:@"fullScreen"]) return UIModalPresentationFullScreen;
  if ([style isEqualToString:@"formSheet"]) return UIModalPresentationFormSheet;
  if ([style isEqualToString:@"overFullScreen"]) return UIModalPresentationOverFullScreen;
  return UIModalPresentationAutomatic;
}

+ (NSArray<PHPickerResult *> *)freshResults:(NSArray<PHPickerResult *> *)results
                                    options:(NSDictionary *)options
                                 deselected:(NSArray<NSString *> *_Nonnull *_Nonnull)deselected
{
  NSArray<NSString *> *preselected = options[@"preselected"] ?: @[];
  NSSet<NSString *> *preselectedSet = [NSSet setWithArray:preselected];
  NSMutableSet<NSString *> *kept = [NSMutableSet set];
  NSMutableArray<PHPickerResult *> *fresh = [NSMutableArray array];
  for (PHPickerResult *result in results) {
    if (result.assetIdentifier != nil && [preselectedSet containsObject:result.assetIdentifier]) {
      [kept addObject:result.assetIdentifier];
    } else {
      [fresh addObject:result];
    }
  }

  NSMutableArray<NSString *> *unticked = [NSMutableArray array];
  for (NSString *identifier in preselected) {
    if (![kept containsObject:identifier]) [unticked addObject:identifier];
  }
  *deselected = unticked;
  return fresh;
}

+ (void)copyResult:(PHPickerResult *)result
          progress:(nullable void (^)(double))progress
        completion:(void (^)(NSString *_Nullable, NSString *_Nullable, BOOL, NSString *_Nullable))completion
{
  NSItemProvider *provider = result.itemProvider;
  BOOL isVideo = [provider hasItemConformingToTypeIdentifier:UTTypeMovie.identifier];
  NSString *typeIdentifier = isVideo ? UTTypeMovie.identifier : UTTypeImage.identifier;

  // The load hands back an NSProgress but no callback for it, so it is read on a
  // timer. The timer is running before the load starts, and the load stops it,
  // so a load that finishes at once never leaves it behind. Only video is
  // reported: a photo loads too fast for progress to mean anything.
  __block NSProgress *loading = nil;
  dispatch_source_t timer = nil;
  if (progress != nil && isVideo) {
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    __block double reported = -1;
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
      double fraction = loading.fractionCompleted;
      if (loading == nil || fraction - reported < 0.01) return;
      reported = fraction;
      progress(MIN(fraction, 1.0));
    });
    dispatch_resume(timer);
  }

  loading = [provider loadFileRepresentationForTypeIdentifier:typeIdentifier
                                            completionHandler:^(NSURL *url, NSError *error) {
    if (timer != nil) dispatch_source_cancel(timer);
    if (url == nil) {
      completion(nil, nil, isVideo, error.localizedDescription ?: @"Asset could not be loaded");
      return;
    }

    // The URL is only valid inside this block, so copy before returning.
    NSString *extension = url.pathExtension.length > 0 ? url.pathExtension : (isVideo ? @"mov" : @"jpg");
    NSString *destination = [MPKMediaFiles tempPathWithExtension:extension];
    NSError *copyError = nil;
    [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:destination error:&copyError];
    if (copyError != nil) {
      completion(nil, nil, isVideo, copyError.localizedDescription);
      return;
    }
    completion(destination, url.lastPathComponent ?: destination.lastPathComponent, isVideo, nil);
  }];
}

@end
