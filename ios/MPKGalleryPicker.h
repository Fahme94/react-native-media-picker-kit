#import <PhotosUI/PhotosUI.h>

NS_ASSUME_NONNULL_BEGIN

/// PHPicker: how it is opened, and what it hands back.
@interface MPKGalleryPicker : NSObject

+ (PHPickerViewController *)pickerForOptions:(NSDictionary *)options;

/// The picker returns the whole selection, preselected items included. Only the
/// new ones need copying -- the caller already holds the rest -- and every
/// preselected item missing from the selection was unticked.
+ (NSArray<PHPickerResult *> *)freshResults:(NSArray<PHPickerResult *> *)results
                                    options:(NSDictionary *)options
                                 deselected:(NSArray<NSString *> *_Nonnull *_Nonnull)deselected;

/// Copies one pick out of the picker's short-lived URL into the temp directory.
/// `path` is nil on failure, with `error` saying why. `progress` follows the
/// library's own load, which includes downloading the original from iCloud.
/// Videos only.
+ (void)copyResult:(PHPickerResult *)result
          progress:(nullable void (^)(double fraction))progress
        completion:(void (^)(NSString *_Nullable path,
                             NSString *_Nullable fileName,
                             BOOL isVideo,
                             NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
