#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Every `errorCode` the module reports; mirrors `ErrorCode` in src/types.ts.
extern NSString *const MPKErrorPermission;
extern NSString *const MPKErrorCannotProcessAsset;
extern NSString *const MPKErrorCropFailed;
extern NSString *const MPKErrorCompressFailed;
extern NSString *const MPKErrorCameraUnavailable;
extern NSString *const MPKErrorInvalidOptions;
extern NSString *const MPKErrorPickerBusy;
extern NSString *const MPKErrorOthers;

/// The result and asset dictionaries handed back to JS.
@interface MPKResults : NSObject

+ (NSDictionary *)cancelled;
+ (NSDictionary *)errorWithCode:(NSString *)code message:(nullable NSString *)message;

/// `deselected` is left out when nil; only a pick that sent `preselected` reports it.
+ (NSDictionary *)successWithAssets:(NSArray<NSDictionary *> *)assets
                         deselected:(nullable NSArray<NSString *> *)deselected;

/// The fields every asset carries. `extra` holds a video's dimensions, duration
/// and bitrate; without it the file is measured as an image.
+ (NSMutableDictionary *)assetForPath:(NSString *)path
                             fileName:(NSString *)fileName
                                 mime:(NSString *)mime
                              options:(NSDictionary *)options
                      assetIdentifier:(nullable NSString *)assetIdentifier
                                extra:(nullable NSDictionary *)extra;

@end

NS_ASSUME_NONNULL_END
