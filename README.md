# react-native-media-picker-kit

Pick photos and videos in React Native — from the gallery **without asking for a single runtime permission**, straight from the camera, cropped, or compressed to a size your backend accepts — all in the same call. Built as a TurboModule for the New Architecture.

[![npm version](https://img.shields.io/npm/v/react-native-media-picker-kit.svg)](https://www.npmjs.com/package/react-native-media-picker-kit)
[![types](https://img.shields.io/npm/types/react-native-media-picker-kit.svg)](src/types.ts)
[![install size](https://img.shields.io/npm/unpacked-size/react-native-media-picker-kit.svg)](https://www.npmjs.com/package/react-native-media-picker-kit)
[![license](https://img.shields.io/npm/l/react-native-media-picker-kit.svg)](./LICENSE)
![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-lightgrey)
![New Architecture](https://img.shields.io/badge/New%20Architecture-required-F0A93B)

## What you get

- **Pick a photo, or take one with the camera.** One call opens the gallery, one opens the camera.
- **Pick a video, or record one.** The same calls. You only change `mediaType`.
- **Make files smaller before you upload them.** Give it a maximum size and anything over 10 MB comes
  back under it. Smaller files are skipped by default, because the work usually costs more than it
  saves — one option turns that off.
- **Progress you can show the user.** Video compression reports how far along it is, so a long
  transcode does not look like a frozen app.
- **Crop images without adding another library.** Turn cropping on and the user gets a crop screen
  after picking or shooting.
- **No permission prompt to pick.** Picking from the gallery asks the user for nothing on either
  platform, and there is nothing to add to your app's settings files. Only the camera needs one line,
  and only on iOS.
- **Works with React Native CLI and with Expo.** Expo projects get their iOS setup written for them
  by the plugin that comes with the package.
- **Files you can upload as they are.** Every result is a real file path you can pass straight to
  `FormData`. On Android you never get a `content://` link that breaks the upload.
- **Nothing to catch.** If the user backs out you get an ordinary result that says so. No call ever
  throws.
- **The same behaviour on both platforms.** The same field names and the same units on iOS and
  Android, so you write the code once.
- **Written in TypeScript.** Every option and every result is typed.

## Install

```sh
npm install react-native-media-picker-kit
# or: yarn add react-native-media-picker-kit

cd ios && pod install
```

Expo projects install and prebuild instead — the bundled config plugin writes the iOS keys for you:

```sh
npx expo install react-native-media-picker-kit
npx expo prebuild
```

Needs React Native **0.79+** with the New Architecture on (`newArchEnabled=true`), Android
`minSdkVersion` 24+, iOS 15.1+. There is no legacy-architecture fallback, and Expo Go cannot load it —
you need a development build. See [Expo](docs/expo.md).

## Use it

```ts
import { pickMedia } from 'react-native-media-picker-kit';

const result = await pickMedia({ mediaType: 'photo' });

if (result.didCancel) return;                       // user backed out
if (result.errorCode) return console.warn(result.errorMessage);

const [asset] = result.assets;
console.log(asset.uri);                             // file:///…/photo.jpg
```

That is the whole setup. No permission request, no `Info.plist` key, no manifest entry — the system
picker runs out of process and hands back only what the user chose. Nothing ever throws: a cancel is
a result, not an error.

### Send it to your backend

Every asset is a real file with the three fields `FormData` wants:

```ts
const body = new FormData();
body.append('file', {
  uri: asset.uri,
  name: asset.fileName,
  type: asset.type,
} as any);

await fetch('https://api.example.com/upload', { method: 'POST', body });
```

## More ways to use it

### Pick several, or video

```ts
const many  = await pickMedia({ mediaType: 'photo', selectionLimit: 5 });
const clips = await pickMedia({ mediaType: 'video' });
const both  = await pickMedia({ mediaType: 'mixed', selectionLimit: 0 });  // 0 = unlimited
```

Images can be resized and re-encoded on the way out, without a second library:

```ts
await pickMedia({ maxWidth: 640, maxHeight: 640, quality: 0.8 });
```

### Shoot with the camera

```ts
import { captureMedia } from 'react-native-media-picker-kit';

const photo = await captureMedia({ mediaType: 'photo', cameraType: 'back' });

const clip = await captureMedia({ mediaType: 'video', durationLimit: 10 });
```

Same options, same result shape, always at most one asset. Camera capture _does_ need one `Info.plist` key on iOS, and still needs nothing on Android — see [Permissions](docs/permissions.md).

### Crop

One flag, and it works identically after a pick or a capture:

```ts
const avatar = await pickMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 1000,
  cropHeight: 1000,
  cropperCircleOverlay: true,
});
```

Both dimensions given means the output is resized to exactly that. See [Cropping](docs/cropping.md).

### Compress to a size your backend accepts

Give it a byte budget and anything over 10 MB comes back fitting it:

```ts
const result = await pickMedia({
  mediaType: 'mixed',
  maxImageFileSize: 2 * 1024 * 1024,   // 2 MB
  maxVideoFileSize: 10 * 1024 * 1024,  // 10 MB
});
```

Images are re-encoded, video is transcoded to H.264/AAC, and compression runs last — after any
resize or crop — so the budget covers the exact bytes you upload. There is also
`compressMedia(path, options)` for a file you already have.

**Nothing under 10 MB is compressed by default**, whatever budget you set. That is
`minimumFileSizeForCompress`, and since typical phone photos are 2–5 MB you will usually want to
lower it for images:

```ts
await pickMedia({
  maxImageFileSize: 2 * 1024 * 1024,
  minimumFileSizeForCompress: 0,   // compress whatever is over, however small
});
```

A skipped file comes back over budget with `asset.compressionSkipped` set to `'below_minimum'` — and
**no** `errorCode`, so check that field if an oversized upload matters. See
[Compression](docs/compression.md).

---

## Features

| Feature | Status |
| --- | --- |
| Gallery picking with **no runtime permission** — PHPicker on iOS, Photo Picker on Android | ✅ Available |
| Camera capture and video recording, still **nothing to declare on Android** ([`captureMedia`](docs/api.md#capturemediaoptions)) | ✅ Available |
| Cropping built in — one flag, after a pick *or* a shot ([details](docs/cropping.md)) | ✅ Available |
| Photos, videos, or both in one pick (`mediaType: 'photo' \| 'video' \| 'mixed'`) | ✅ Available |
| Resize and re-encode on the native side (`maxWidth` / `maxHeight` / `quality` / `forceJpg`) | ✅ Available |
| Compress to a target file size — images **and video** (`maxImageFileSize` / `maxVideoFileSize`) ([details](docs/compression.md)) | ✅ Available |
| Compression progress for video, and cancellation part-way (`cancelCompression`) | ✅ Available |
| Skips files under 10 MB by default, so a short clip is never transcoded to save a little (`minimumFileSizeForCompress`) | ✅ Available |
| Every asset is a real `file://` in app cache — never a raw `content://` URI | ✅ Available |
| Read EXIF and asset metadata (`includeExif`, `includeExtra`) | ✅ Available |
| Temp-file lifecycle API — `cleanTempFiles()` ([details](docs/temp-files.md)) | ✅ Available |
| Expo config plugin, no manual `Info.plist` edits ([details](docs/expo.md)) | ✅ Available |
| Fully typed — the API **never rejects**, cancel is a result not an error | ✅ Available |
| `saveToPhotos` | ❌ Not yet |

## Comparison

The option and result shapes are a merge of the two libraries most people reach for, with the inconsistencies between them resolved.

| | react-native-media-picker-kit | react-native-image-picker | react-native-image-crop-picker |
| --- | --- | --- | --- |
| Cropping | Built in — `cropping: true` on a pick or a capture | Not supported | Built in |
| Cancelling | Resolves with `didCancel: true` | Resolves with `didCancel: true` | **Rejects** — every call site needs a `catch` that string-matches the cancel code |
| Android gallery video | Real `file://` copied into app cache | Read-only `content://` URI, which breaks uploads and `fs` calls | Real file |
| `duration` units | Milliseconds on both platforms | Seconds | Milliseconds |
| Asset field names | One shape everywhere — `uri` / `fileName` / `fileSize` / `type` | `uri` / `fileName` / `fileSize` / `type` | `path` / `filename` / `size` / `mime` |
| Extra Android setup | None | None | Add the JitPack repo to your root `build.gradle` for uCrop |
| Architecture | New Architecture only (TurboModule) | Both, with a legacy fallback | Both |

Reflects the behaviour these libraries document and that this package was built to reconcile — verify against their current releases before relying on a row.

---

## Documentation

-  [**API reference**](docs/api.md) — every option, the `Asset` shape, error codes, and all five exports.
-  [Cropping](docs/cropping.md) — sizing, free-form vs aspect-locked, and what the cropper can't do.
-  [Compression](docs/compression.md) — target file sizes for images and video, and what it costs.
-  [Permissions](docs/permissions.md) — why the gallery needs none, and the one camera key that isn't optional.
-  [Expo](docs/expo.md) — the bundled config plugin and development builds.
-  [Temp files](docs/temp-files.md) — where assets live and how to clean them up.
-  [Troubleshooting](docs/troubleshooting.md) — autolinking, older Android, and the Xcode `fmt` build failure.
-  [Example app](example) — a runnable project with a button per option.


- [Report a bug](https://github.com/Fahme94/react-native-media-picker/issues)

## License

MIT © [Ahmed Fahmy](https://github.com/Fahme94)
