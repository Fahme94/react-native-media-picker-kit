#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The module's temp directory, and what it needs to know about files in general.
@interface MPKMediaFiles : NSObject

+ (NSString *)tempDirectory;
+ (NSString *)tempPathWithExtension:(NSString *)extension;

/// A plain path for either a `file://` URI or a path that already is one.
+ (NSString *)pathFromURI:(NSString *)uri;

/// Replacing a file means dropping the one it replaced -- but compressMedia()
/// takes any path the caller hands it, so only this module's own temp files are
/// ever removed.
+ (void)removeIfTemporary:(NSString *)path;

/// An empty path clears the whole temp directory.
+ (void)cleanTempFiles:(NSString *)path;

+ (NSString *)mimeTypeForPath:(NSString *)path;
+ (unsigned long long)fileSizeAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
