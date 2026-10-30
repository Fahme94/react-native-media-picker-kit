# Migrating from react-native-image-crop-picker

Most options keep their names, so the move is mostly mechanical. The three changes that touch every
call site are: a cancel no longer rejects, the result is always an `assets` array, and asset fields
use `uri` / `fileName` / `fileSize` / `type`.

Check the [supported versions](../README.md#supported-versions) first: this library needs the New
Architecture and has no legacy fallback.

## Before and after

```ts
// react-native-image-crop-picker
import ImagePicker from 'react-native-image-crop-picker';

try {
  const image = await ImagePicker.openPicker({
    width: 1000,
    height: 1000,
    cropping: true,
    cropperCircleOverlay: true,
  });
  upload(image.path, image.mime);
} catch (e) {
  if (e.code !== 'E_PICKER_CANCELLED') showError(e.message);
}
```

```ts
// react-native-media-picker-kit
import { pickMedia } from 'react-native-media-picker-kit';

const result = await pickMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 1000,
  cropHeight: 1000,
  cropperCircleOverlay: true,
});

if (result.didCancel) return;
if (result.errorCode) return showError(result.errorMessage);

const [image] = result.assets;
upload(image.uri, image.type);
```

Nothing here throws, so the `try`/`catch` and the cancel-code string match go away. See
[error codes](api.md#error-codes) for what `errorCode` can be.

## Functions

| image-crop-picker | This library |
| --- | --- |
| `openPicker(options)` | [`pickMedia(options)`](api.md#pickmediaoptions) |
| `openCamera(options)` | [`captureMedia(options)`](api.md#capturemediaoptions) |
| `openCropper({ path, ...options })` | [`cropImage(path, options)`](api.md#cropimagepath-options) |
| `clean()` | [`cleanTempFiles()`](api.md#cleantempfilespath) |
| `cleanSingle(path)` | `cleanTempFiles(path)` |
| | [`compressMedia(path, options)`](api.md#compressmediapath-options), to shrink a file you already have |

## Options

| image-crop-picker | This library | Notes |
| --- | --- | --- |
| `mediaType: 'photo' \| 'video' \| 'any'` | `mediaType: 'photo' \| 'video' \| 'mixed'` | |
| `multiple: true` | `selectionLimit: 0` | 0 is unlimited |
| `multiple: true, maxFiles: n` | `selectionLimit: n` | Honoured on both platforms |
| `cropping` | `cropping` | Requires `mediaType: 'photo'` and a single pick. See below. |
| `width`, `height` | `cropWidth`, `cropHeight` | Exact output size, the same on both platforms. See [Cropping](cropping.md#output-size). |
| `freeStyleCropEnabled` | `freeStyleCropEnabled` | |
| `cropperCircleOverlay` | `cropperCircleOverlay` | |
| `cropperToolbarTitle`, `cropperToolbarColor`, `cropperActiveWidgetColor`, `cropperChooseText`, `cropperCancelText` | Same names | `cropperCancelText` is iOS only |
| `compressImageMaxWidth`, `compressImageMaxHeight` | `maxWidth`, `maxHeight` | |
| `compressImageQuality` | `quality` | 0 to 1 |
| `forceJpg` | `forceJpg` | **Defaults to `true` here.** Pass `false` to keep HEIC and PNG. |
| `compressVideoPreset` | `maxVideoFileSize` | A byte budget instead of a preset. See [Compression](compression.md#video). |
| `useFrontCamera: true` | `cameraType: 'front'` | A hint on Android. See [Camera](camera.md#options). |
| `includeBase64`, `includeExif` | Same names | |
| `writeTempFile` | `writeTempFile` | iOS only, in both libraries |
| `smartAlbums`, `sortOrder`, `showsSelectedCount`, `loadingLabelText` | None | The system picker draws its own UI |

New here, with no image-crop-picker equivalent: [`maxImageFileSize`](compression.md#images) to
compress to a byte budget, [`preselected`](preselection.md) to reopen the picker with earlier picks
ticked, and [`durationLimit`](camera.md#options) for recordings.

## Results

image-crop-picker returns one object, or an array when `multiple` is set. This library always
returns `result.assets`, an array, so single and multiple picks are handled the same way.

| image-crop-picker | This library |
| --- | --- |
| `path` | `uri` |
| `mime` | `type` |
| `size` | `fileSize` |
| `filename` (iOS only) | `fileName` (both platforms) |
| `data` | `base64` |
| `width`, `height`, `exif`, `cropRect` | Same names |
| `duration` (milliseconds) | `duration` (milliseconds) |
| `sourceURL`, `localIdentifier` | `originalPath` |

## Behaviour changes to watch for

- **Cropping with several images is an error.** image-crop-picker crops only the first asset of a
  multiple pick and returns the rest uncropped. Here the call resolves with
  `errorCode: 'invalid_options'`. See [Cropping](cropping.md#constraints).
- **Compression has a 10 MB floor.** `maxImageFileSize` and `maxVideoFileSize` leave smaller files
  alone unless you lower `minimumFileSizeForCompress`. See
  [the 10 MB floor](compression.md#the-10-mb-floor).
- **Temp files stay until you clean them**, as with image-crop-picker. See [Temp files](temp-files.md).

## Cleanup

Once nothing imports image-crop-picker:

- Remove the JitPack repository from your root `build.gradle` if you added it only for uCrop.
- Remove any `READ_EXTERNAL_STORAGE`, `READ_MEDIA_IMAGES` or `READ_MEDIA_VIDEO` permission you
  declared for the picker. This library picks without them, and Google Play asks apps without a
  core need for broad photo access not to declare them.
- On iOS, drop `NSPhotoLibraryUsageDescription` unless you use `includeExtra`. Keep
  `NSCameraUsageDescription`. See [Permissions](permissions.md).
