# API reference

Five exports, all promise-returning, none of which ever reject. Every call resolves with a
[`PickerResult`](#pickerresult).

```ts
import {
  pickMedia,
  captureMedia,
  cropImage,
  compressMedia,
  cleanTempFiles,
} from 'react-native-media-picker-kit';
```

## Functions

### pickMedia(options)

Opens the system gallery picker. No runtime permission on either platform.

```ts
const result = await pickMedia({ mediaType: 'mixed', selectionLimit: 5 });
```

Returns up to `selectionLimit` assets, or all of them when `selectionLimit: 0`.

### captureMedia(options)

Opens the camera. Takes the same options as `pickMedia` and returns the same shape, always with **at
most one asset**.

```ts
const photo = await captureMedia({ mediaType: 'photo' });
const clip = await captureMedia({ mediaType: 'video', durationLimit: 10 });
```

`mediaType: 'mixed'` rejects with `invalid_options`: Android has separate photo and video capture
intents and no "either" intent, so it cannot behave the same on both platforms.

Needs `NSCameraUsageDescription` on iOS — see [Permissions](permissions.md).

### cropImage(path, options)

Crops an image that is already on disk, such as one a previous pick returned.

```ts
const recropped = await cropImage(asset.uri, {
  cropWidth: 1000,
  cropHeight: 1000,
  cropperCircleOverlay: true,
});
```

`mediaType`, `selectionLimit` and `cropping` do not apply and are not accepted. An empty `path`
resolves with `invalid_options`.

### compressMedia(path, options)

Shrinks a file already on disk under a byte budget, with no UI. Useful when the file came from
somewhere other than this library, or when you only decide on a size limit later.

```ts
const smaller = await compressMedia(asset.uri, {
  maxImageFileSize: 500 * 1024,   // 500 KB
  maxVideoFileSize: 5 * 1024 * 1024,
});
```

Pass whichever budget matches the file, or both when it could be either — at least one is required,
otherwise the call resolves with `invalid_options`, as it does for an empty `path` or a path that is
neither an image nor a video. Resolves with exactly one re-measured asset.

This function **only compresses**. It takes `maxImageFileSize`, `maxVideoFileSize`, `includeBase64`
and `includeExif` — the `CompressOptions` type — and nothing else: `maxWidth`, `quality` and
`forceJpg` belong to picking, and honouring them here would mean a file already under budget did not
come back untouched after all.

Unlike the picker functions it never opens any UI, so it works while a picker is open and is never
`picker_busy`. It also never deletes the file you hand it. See [Compression](compression.md).

### cleanTempFiles(path?)

Deletes what this library wrote. See [Temp files](temp-files.md).

```ts
await cleanTempFiles();           // everything
await cleanTempFiles(asset.uri);  // one asset
```

## PickerResult

```ts
interface PickerResult {
  didCancel: boolean;
  errorCode?: ErrorCode;
  errorMessage?: string;
  assets: Asset[];
}
```

Three outcomes, and none of them throw:

```ts
const result = await pickMedia({ mediaType: 'photo' });

if (result.didCancel) return;                    // user backed out
if (result.errorCode) {                          // something went wrong
  console.warn(result.errorCode, result.errorMessage);
  return;
}

for (const asset of result.assets) {             // success
  console.log(asset.uri, asset.type, asset.width, asset.height);
}
```

`assets` is always an array — empty on cancel or error, never `undefined`.

## Asset

| Field | Type | Notes |
| --- | --- | --- |
| `uri` | `string \| null` | `file://` path in app cache. `null` only with `writeTempFile: false` on iOS. |
| `fileName` | `string` | The extension always matches the actual bytes, even after a re-encode. |
| `fileSize` | `number` | Bytes. |
| `type` | `string` | MIME type, e.g. `image/jpeg`. |
| `width`, `height` | `number` | Pixels. |
| `duration` | `number?` | Video only. **Milliseconds**, on both platforms. |
| `bitrate` | `number?` | Video only. Bits per second. |
| `base64` | `string?` | With `includeBase64`. |
| `exif` | `object?` | With `includeExif`. |
| `id` | `string?` | With `includeExtra`. iOS: the PHAsset local identifier. Android: the gallery display name, because the Android pickers hand back no stable id. |
| `timestamp` | `string?` | With `includeExtra`. **Android only** — epoch milliseconds as a string. |
| `originalPath` | `string?` | Android: the source `content://`. iOS: the PHAsset identifier. |
| `cropRect` | `object?` | `{ x, y, width, height }`, present when the asset was cropped. |

Uploading one:

```ts
const [asset] = result.assets;
const body = new FormData();
body.append('file', {
  uri: asset.uri,
  name: asset.fileName,
  type: asset.type,
} as any);
```

## Error codes

| Code | Meaning |
| --- | --- |
| `invalid_options` | Options that cannot be honoured — see [Cropping](cropping.md) and `captureMedia` above. |
| `permission` | Camera permission denied. Only reachable if your app declares `CAMERA` itself. |
| `camera_unavailable` | No camera, or this camera cannot record video. |
| `cannot_process_asset` | The file could not be read or copied. |
| `crop_failed` | The cropper could not encode or write the result. |
| `compress_failed` | The file could not be brought under `maxImageFileSize` / `maxVideoFileSize`. See [Compression](compression.md). |
| `picker_busy` | A picker is already open. |
| `no_library_permission` | Photo library access denied (`includeExtra` on iOS). |
| `others` | Anything else; read `errorMessage`. |

## Options

Every option is optional. Defaults are filled in JS before anything reaches native, so the native
side always receives a fully populated object.

### Selection

| Option | Type | Default | |
| --- | --- | --- | --- |
| `mediaType` | `'photo' \| 'video' \| 'mixed'` | `'photo'` | |
| `selectionLimit` | `number` | `1` | `0` for unlimited (iOS 14+ / Android 13+) |
| `restrictMimeTypes` | `string[]` | `[]` | Android SAF fallback only, e.g. `['image/jpeg']` |

### Image output

| Option | Type | Default | |
| --- | --- | --- | --- |
| `maxWidth` | `number` | `0` | Fit inside this box, aspect ratio preserved. `0` means no limit |
| `maxHeight` | `number` | `0` | |
| `quality` | `number` | `1` | JPEG quality `0..1` |
| `forceJpg` | `boolean` | `true` | Convert HEIC/HEIF/PNG output to JPEG |

These apply to images only.

### File size

| Option | Type | Default | |
| --- | --- | --- | --- |
| `maxImageFileSize` | `number` | `0` | Compress images until the file fits in this many **bytes**. `0` means no limit |
| `maxVideoFileSize` | `number` | `0` | Same for video, which is re-encoded to H.264/AAC. `0` means no limit, and video is otherwise never re-encoded |

Applied last, after the image options above and after any crop, so the budget covers the bytes you
actually upload. See [Compression](compression.md).

### Extras

| Option | Type | Default | |
| --- | --- | --- | --- |
| `includeBase64` | `boolean` | `false` | Adds `base64` |
| `includeExif` | `boolean` | `false` | Adds `exif` |
| `includeExtra` | `boolean` | `false` | Adds `id` and `timestamp`. May require library permission on iOS |
| `writeTempFile` | `boolean` | `true` | iOS only. See [Temp files](temp-files.md) |
| `presentationStyle` | `PresentationStyle` | `'currentContext'` | iOS only. `'currentContext'` · `'pageSheet'` · `'fullScreen'` · `'formSheet'` · `'overFullScreen'` |

### Camera

`captureMedia` only.

| Option | Type | Default | |
| --- | --- | --- | --- |
| `cameraType` | `'back' \| 'front'` | `'back'` | Honoured exactly on iOS. On Android it is a hint the camera app is free to ignore, because the capture intents have no standard lens-selection extra |
| `durationLimit` | `number` | `0` | Maximum seconds of video; `0` for no limit |
| `videoQuality` | `'low' \| 'high'` | `'high'` | Selects the camera's recording profile |

### Cropping

See [Cropping](cropping.md) for behaviour and constraints.

| Option | Type | Default | |
| --- | --- | --- | --- |
| `cropping` | `boolean` | `false` | Open the cropper after picking or shooting |
| `cropWidth` | `number` | `0` | Exact output width |
| `cropHeight` | `number` | `0` | Exact output height |
| `freeStyleCropEnabled` | `boolean` | `false` | Let the user change the aspect ratio |
| `cropperCircleOverlay` | `boolean` | `false` | Circular mask |
| `cropperToolbarTitle` | `string` | `'Edit Photo'` | |
| `cropperToolbarColor` | `string` | `'#424242'` | Hex. Android toolbar / iOS accent |
| `cropperActiveWidgetColor` | `string` | `'#424242'` | Hex |
| `cropperChooseText` | `string` | `'Choose'` | Confirm button label |
| `cropperCancelText` | `string` | `'Cancel'` | iOS only — the Android cropper uses an unlabelled back arrow |

Full documented types live in [`src/types.ts`](../src/types.ts).
