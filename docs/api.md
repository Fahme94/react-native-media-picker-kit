# API reference

Seven exports. The ones that do work are promise-returning and none of them ever reject; each
resolves with a [`PickerResult`](#pickerresult). The other two subscribe to progress and stop work
in flight.

```ts
import {
  pickMedia,
  captureMedia,
  cropImage,
  compressMedia,
  addCompressProgressListener,
  cancelCompression,
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

**The 10 MB floor applies here too.** Asking this function for a budget is not enough on its own: a
3 MB file with `maxImageFileSize: 1024 * 1024` comes back unchanged, with
`compressionSkipped: 'below_minimum'`. Pass `minimumFileSizeForCompress: 0` when you mean it
regardless of size.

This function **only compresses**. It takes `maxImageFileSize`, `maxVideoFileSize`, `includeBase64`
and `includeExif` — the `CompressOptions` type — and nothing else: `maxWidth`, `quality` and
`forceJpg` belong to picking, and honouring them here would mean a file already under budget did not
come back untouched after all.

Unlike the picker functions it never opens any UI, so it works while a picker is open and is never
`picker_busy`. It also never deletes the file you hand it. See [Compression](compression.md).

### addCompressProgressListener(listener)

Reports how far along video compression is, so you can show something other than a frozen spinner.
Returns a subscription; call `remove()` when you are done with it.

```ts
useEffect(() => {
  const sub = addCompressProgressListener(({ progress, index, total }) => {
    setLabel(`Compressing ${index + 1} of ${total}: ${Math.round(progress * 100)}%`);
  });
  return () => sub.remove();
}, []);
```

| Field | Type | |
| --- | --- | --- |
| `progress` | `number` | `0..1` for the asset being compressed. Never goes backwards |
| `index` | `number` | Which asset of the batch, from `0` |
| `total` | `number` | How many assets this call is compressing |

**Only video reports progress.** Images finish too quickly for it to mean anything, so a call that
compresses no video emits nothing. It is a module-wide subscription rather than a per-call callback,
so subscribe once where you show the spinner. See [Compression](compression.md#progress).

### cancelCompression()

Stops video compression that is currently running. Safe to call when nothing is.

```ts
<Button title="Stop" onPress={() => cancelCompression()} />
```

The call being compressed still resolves normally — you get the asset back
**uncompressed and over its budget**, with `asset.compressionSkipped` set to `'cancelled'`. A long
transcode is the one thing here a user may reasonably want to back out of, so it is a cancel rather
than an error. During a multi-select it stops the clip being worked on and everything queued behind
it.

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
| `compressionSkipped` | `'below_minimum' \| 'cancelled'` | Present **only** when the file is over its budget, saying why. `'below_minimum'` is common, not an edge case: the 10 MB floor is on by default. Absent means the budget was met, or none was asked for. |

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
| `maxImageFileSize` | `number` | `0` | Compress images until the file fits in this many **bytes**. `0` means no limit. A ceiling only above `minimumFileSizeForCompress` |
| `maxVideoFileSize` | `number` | `0` | Same for video, which is re-encoded to H.264/AAC. `0` means no limit, and video is otherwise never re-encoded |
| `minimumFileSizeForCompress` | `number` | `10485760` | Skip compression for files below this many **bytes**, even when they are over budget. **10 MB by default** — set `0` to always compress what is over |

Applied last, after the image options above and after any crop, so the budget covers the bytes you
actually upload. See [Compression](compression.md).

### The 10 MB floor, and what it costs you

`minimumFileSizeForCompress` defaults to **10 MB**, so out of the box nothing smaller than that is
compressed, whatever budget you set. It applies to images as well as video, and to every call
including `compressMedia`. A 4 MB photo with `maxImageFileSize: 2 * 1024 * 1024` comes back at 4 MB.

Two consequences worth knowing before you rely on a budget:

- **A budget is a ceiling only above the floor.** `asset.fileSize <= maxImageFileSize` holds for
  files over 10 MB, not below it.
- **`compress_failed` does not fire below the floor.** A skipped file resolves *successfully*, so
  code that only checks `errorCode` will upload something larger than it asked for without noticing.
  Check `asset.compressionSkipped === 'below_minimum'` when that matters.

Set `minimumFileSizeForCompress: 0` to get an unconditional ceiling.

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
