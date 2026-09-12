# react-native-media-picker-kit

Pick photos and videos in React Native — from the gallery **without asking for a single runtime permission**, straight from the camera, or cropped in the same call. Built as a TurboModule for the New Architecture.

[![npm version](https://img.shields.io/npm/v/react-native-media-picker-kit.svg)](https://www.npmjs.com/package/react-native-media-picker-kit)
[![npm downloads](https://img.shields.io/npm/dm/react-native-media-picker-kit.svg)](https://www.npmjs.com/package/react-native-media-picker-kit)
[![license](https://img.shields.io/npm/l/react-native-media-picker-kit.svg)](./LICENSE)
![platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-lightgrey)
![New Architecture](https://img.shields.io/badge/New%20Architecture-required-F0A93B)

## Features

| Feature | Status |
| --- | --- |
| Gallery picking with **no runtime permission** — PHPicker on iOS, Photo Picker on Android | ✅ Available |
| Camera capture and video recording, still **nothing to declare on Android** ([`captureMedia`](docs/api.md#capturemediaoptions)) | ✅ Available |
| Cropping built in — one flag, after a pick *or* a shot ([details](docs/cropping.md)) | ✅ Available |
| Photos, videos, or both in one pick (`mediaType: 'photo' \| 'video' \| 'mixed'`) | ✅ Available |
| Resize and re-encode on the native side (`maxWidth` / `maxHeight` / `quality` / `forceJpg`) | ✅ Available |
| Every asset is a real `file://` in app cache — never a raw `content://` URI | ✅ Available |
| Read EXIF and asset metadata (`includeExif`, `includeExtra`) | ✅ Available |
| Temp-file lifecycle API — `cleanTempFiles()` ([details](docs/temp-files.md)) | ✅ Available |
| Expo config plugin, no manual `Info.plist` edits ([details](docs/expo.md)) | ✅ Available |
| Fully typed — the API **never rejects**, cancel is a result not an error | ✅ Available |
| Video compression and `saveToPhotos` | ❌ Not yet |

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

## Quick start

### Requirements

React Native **0.79+** with the New Architecture enabled (`newArchEnabled=true`). There is no legacy-architecture fallback. Android `minSdkVersion` 24+, iOS 15.1+.

### Install

```sh
npm install react-native-media-picker-kit
cd ios && pod install
```

Expo projects need a development build — see [Expo](docs/expo.md).

### Pick from the gallery

```ts
import { pickMedia } from 'react-native-media-picker-kit';

const result = await pickMedia({
  mediaType: 'photo',    // 'photo' | 'video' | 'mixed'
  selectionLimit: 1,     // 0 = unlimited
  maxWidth: 640,
  maxHeight: 640,
  quality: 0.8,          // 0..1
});

if (result.didCancel) return;
if (result.errorCode) {
  console.warn(result.errorCode, result.errorMessage);
  return;
}
console.log(result.assets[0].uri); // file:///…/photo.jpg
```

No permission request, no `Info.plist` key, no manifest entry — the system picker runs out of process and hands back only what the user chose.

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

---

## Documentation

-  [**API reference**](docs/api.md) — every option, the `Asset` shape, error codes, and all four exports.
-  [Cropping](docs/cropping.md) — sizing, free-form vs aspect-locked, and what the cropper can't do.
-  [Permissions](docs/permissions.md) — why the gallery needs none, and the one camera key that isn't optional.
-  [Expo](docs/expo.md) — the bundled config plugin and development builds.
-  [Temp files](docs/temp-files.md) — where assets live and how to clean them up.
-  [Troubleshooting](docs/troubleshooting.md) — autolinking, older Android, and the Xcode `fmt` build failure.
-  [Example app](example) — a runnable project with a button per option.


- [Report a bug](https://github.com/Fahme94/react-native-media-picker/issues)

## License

MIT © [Ahmed Fahmy](https://github.com/Fahme94)
