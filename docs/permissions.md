# Permissions

The short version: **picking needs nothing on either platform.** Capturing needs one `Info.plist` key
on iOS and still nothing on Android.

| | Android | iOS |
| --- | --- | --- |
| Pick from gallery | Nothing | Nothing |
| Capture photo / video | Nothing | `NSCameraUsageDescription` |
| Capture video with audio | Nothing | `NSCameraUsageDescription` + `NSMicrophoneUsageDescription` |
| `includeExtra: true` | Nothing | `NSPhotoLibraryUsageDescription` |

## Android — why there are genuinely none

This is not "the library requests them for you". There is nothing to request.

- **Picking.** `ACTION_PICK_IMAGES` (API 33+) and `ACTION_OPEN_DOCUMENT` (below that) both run out of
  process and return a URI your app has already been granted. Reading it needs no permission.
- **Capturing.** `ACTION_IMAGE_CAPTURE` and `ACTION_VIDEO_CAPTURE` hand the work to the camera app,
  which holds its own permissions. This library declares no `CAMERA` permission **on purpose**:
  declaring it would *force* a runtime grant that is otherwise unnecessary.

### The one case where a prompt appears

If your app declares `CAMERA` anyway — usually pulled in by another library's manifest — Android then
requires it to be granted before the capture intent will run, even though this library never asked
for it. `captureMedia` detects that situation and requests it for you, resolving with
`errorCode: 'permission'` if the user denies.

You still write no permission code either way.

### FileProvider

The library ships its own `FileProvider` on a `${applicationId}.mediapickerprovider` authority,
scoped to its own cache directory, because capture intents cannot be handed a `file://` URI on API
24+. It is merged into your manifest automatically and is namespaced to your application id, so it
cannot collide with another app's provider.

The provider is declared as `com.mediapicker.MediaPickerFileProvider`, a subclass, rather than as
`androidx.core.content.FileProvider` directly. The manifest merger keys `<provider>` elements by
`android:name`, so two dependencies that both declare the bare `androidx.core.content.FileProvider`
fail your build on their differing `android:authorities` even though those authorities could never
clash at runtime. Owning a distinct class name keeps this library out of that fight, and means you
never need a `tools:replace` on the provider in your own manifest.

## iOS

Add these to `Info.plist`, or let the [Expo config plugin](expo.md) write them.

| Key | When you need it |
| --- | --- |
| `NSCameraUsageDescription` | **Required for `captureMedia`.** iOS terminates the app the moment the camera is presented without it, and no native module can supply it at runtime. |
| `NSMicrophoneUsageDescription` | Recording video with audio. |
| `NSPhotoLibraryUsageDescription` | Only when `includeExtra: true`, which opens the picker against the photo library to read asset identifiers. A plain pick needs no permission at all. |

```xml
<key>NSCameraUsageDescription</key>
<string>Take a photo or video to attach.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Record audio with your video.</string>
```

`captureMedia` also checks `AVCaptureDevice` authorization before presenting. A previously denied app
would otherwise get a black viewfinder; instead the call resolves with `errorCode: 'permission'`.
