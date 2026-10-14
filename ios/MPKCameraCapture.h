#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The system camera, through UIImagePickerController.
@interface MPKCameraCapture : NSObject

/// Nil when the camera can be opened for these options; otherwise the error
/// result to resolve with instead.
+ (nullable NSDictionary *)unavailableResultForOptions:(NSDictionary *)options;

/// Only call after unavailableResultForOptions: returned nil.
+ (UIImagePickerController *)cameraForOptions:(NSDictionary *)options;

@end

NS_ASSUME_NONNULL_END
