#import "MPKMediaFiles.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kTempDirName = @"rn_media_picker";

@implementation MPKMediaFiles

+ (NSString *)tempDirectory
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:kTempDirName];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return dir;
}

+ (NSString *)tempPathWithExtension:(NSString *)extension
{
  NSString *name = [NSString stringWithFormat:@"%@.%@", [[NSUUID UUID] UUIDString], extension];
  return [[self tempDirectory] stringByAppendingPathComponent:name];
}

+ (NSString *)pathFromURI:(NSString *)uri
{
  return [uri hasPrefix:@"file://"] ? [[NSURL URLWithString:uri] path] : uri;
}

/// Resolved before comparing, so neither `rn_media_picker/../../Documents/x`
/// nor a sibling such as `rn_media_picker2/x` passes for a file of ours.
+ (BOOL)isTemporary:(NSString *)path
{
  NSString *dir = [[[self tempDirectory] stringByResolvingSymlinksInPath]
      stringByAppendingString:@"/"];
  NSString *resolved = [[path stringByStandardizingPath] stringByResolvingSymlinksInPath];
  return [resolved hasPrefix:dir];
}

+ (void)removeIfTemporary:(NSString *)path
{
  if ([self isTemporary:path]) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  }
}

+ (void)cleanTempFiles:(NSString *)path
{
  NSFileManager *fm = [NSFileManager defaultManager];
  if (path.length == 0) {
    NSString *dir = [self tempDirectory];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
      [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    }
    return;
  }
  [self removeIfTemporary:[self pathFromURI:path]];
}

+ (NSString *)mimeTypeForPath:(NSString *)path
{
  UTType *type = [UTType typeWithFilenameExtension:path.pathExtension];
  return type.preferredMIMEType ?: @"application/octet-stream";
}

+ (unsigned long long)fileSizeAtPath:(NSString *)path
{
  return [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
}

@end
