#import <Foundation/Foundation.h>
#import <RNMediaPickerSpec/RNMediaPickerSpec.h>

NS_ASSUME_NONNULL_BEGIN

// NativeMediaPickerSpecBase rather than NSObject: emitOnCompressProgress is
// generated onto the base, so events are unavailable without it.
@interface MediaPicker : NativeMediaPickerSpecBase <NativeMediaPickerSpec>
@end

NS_ASSUME_NONNULL_END
