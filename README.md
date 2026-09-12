# react-native-media-picker

Media picker for React Native's New Architecture. Picks or captures images (optionally with a crop step) and videos on Android and iOS.

The option and result shapes are a merge of `react-native-image-picker` and `react-native-image-crop-picker`, with the inconsistencies between them resolved:

- **Cancel is not an error.** Every call resolves with a result object; `didCancel: true` on cancel. `image-crop-picker` rejects, which forces a `catch` that string-matches the cancel code in every call site.
- **One asset shape.** `uri`/`fileName`/`fileSize`/`type` everywhere, not `path`/`filename`/`size`/`mime` on one platform's library and something else on the other.
- **`duration` is milliseconds on both platforms.** `image-picker` reports seconds, `image-crop-picker` reports milliseconds; picking one avoids a class of silent bugs.
- **Android always returns a real file.** `react-native-image-picker` returns a read-only `content://` URI for gallery videos on Android, which breaks anything downstream. Here every asset is copied into app cache before it crosses the bridge.

## Install

```bash
yarn add react-native-media-picker
cd ios && pod install
```

Requires the New Architecture (`newArchEnabled=true`); there is no legacy bridge fallback. The `react-native` peer range is `>=0.79.0`, which is the oldest release this has actually been built against — RN 0.79 (CLI) and RN 0.86 / Expo SDK 57 are both verified. `expo` is an optional peer, needed only if you use the config plugin.

### Android

`minSdkVersion` 24+. **No manifest changes and no permissions of any kind**, for picking or for capturing:

- `ACTION_PICK_IMAGES` (API 33+) and `ACTION_OPEN_DOCUMENT` (below that) both return a URI the app is already granted.
- `ACTION_IMAGE_CAPTURE` / `ACTION_VIDEO_CAPTURE` hand the work to the camera app, which holds its own permissions. This library declares no `CAMERA` permission on purpose: declaring it would *force* a runtime grant that is otherwise unnecessary.
- If your app declares `CAMERA` anyway — usually pulled in by another library — Android then requires it to be granted before the capture intent will run. `captureMedia` detects that case and requests it for you, resolving with `errorCode: 'permission'` on denial. You still write no permission code.

The module ships its own `FileProvider` on a `${applicationId}.mediapickerprovider` authority, scoped to its own cache directory, because capture intents cannot be handed a `file://` URI on API 24+. It is merged in automatically.

If your app's `minSdkVersion` is below 30 you may need `androidx.activity:activity:1.9.+` in `app/build.gradle` to pull in the backported photo picker, the same requirement `react-native-image-picker` documents.

Register the package if autolinking doesn't pick it up:

```kotlin
override fun getPackages(): List<ReactPackage> =
  PackageList(this).packages.apply { add(MediaPickerPackage()) }
```

### iOS

iOS 15.1+.

**Expo** — add the config plugin and you are done:

```json
{"expo": {"plugins": ["react-native-media-picker"]}}
```

It writes the keys below, and accepts overrides: `["react-native-media-picker", {"cameraPermission": "…", "microphonePermission": false}]`. Passing `false` removes a key for features you do not use. Expo Go cannot load this module; use `expo prebuild` or a dev client.

**React Native CLI** — add to `Info.plist` by hand:

| Key | Needed for |
| --- | --- |
| `NSCameraUsageDescription` | **Required for `captureMedia`.** iOS terminates the app when the camera is presented without it; no native module can supply it at runtime. |
| `NSMicrophoneUsageDescription` | Capturing video with audio. |
| `NSPhotoLibraryUsageDescription` | Only when `includeExtra: true`, which opens the picker against the photo library to get asset identifiers. A plain pick needs no permission at all. |

## Usage

```ts
import { pickMedia, cleanTempFiles } from 'react-native-media-picker';

// Square-cropped avatar
const result = await pickMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 1000,
  cropHeight: 1000,
  cropperCircleOverlay: true,
  quality: 0.9,
});

if (result.didCancel) return;
if (result.errorCode) return console.warn(result.errorCode, result.errorMessage);

const [asset] = result.assets;
console.log(asset.uri, asset.fileSize, asset.width, asset.height);
```

```ts
// Up to five photos or videos, no cropping
const result = await pickMedia({ mediaType: 'mixed', selectionLimit: 5 });
```

```ts
import { captureMedia } from 'react-native-media-picker';

// Shoot a photo and crop it square
const shot = await captureMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 800,
  cropHeight: 800,
});

// Record up to 10 seconds of video on the front camera
const clip = await captureMedia({
  mediaType: 'video',
  durationLimit: 10,
  cameraType: 'front',
});
```

`captureMedia` takes the same options and returns the same result shape as `pickMedia`, always with at most one asset. `mediaType: 'mixed'` is rejected with `invalid_options`: Android has two separate capture intents and no "either" intent, so it cannot be honoured the same way on both platforms.

Temp files are not cleaned up automatically. Call `cleanTempFiles()` when you're done with the assets, or `cleanTempFiles(asset.uri)` for a single one. Both platforms refuse to delete anything outside the module's own cache directory.

## Cropping constraints

Cropping requires `mediaType: 'photo'` and `selectionLimit: 1`, and rejects with `invalid_options` otherwise. Both underlying croppers operate on a single still image; `image-crop-picker` handles the multi-select case by quietly cropping only the first asset, which is worse than a loud error.

## Options

All options are optional; the JS layer fills defaults before anything reaches native, so the native side always receives a fully populated object.

`mediaType` · `selectionLimit` · `restrictMimeTypes` (Android SAF fallback) · `maxWidth` · `maxHeight` · `quality` · `forceJpg` · `includeBase64` · `includeExif` · `includeExtra` · `writeTempFile` (iOS) · `presentationStyle` (iOS) · `cameraType` · `durationLimit` · `videoQuality` · `cropping` · `cropWidth` · `cropHeight` · `freeStyleCropEnabled` · `cropperCircleOverlay` · `cropperToolbarTitle` · `cropperToolbarColor` · `cropperActiveWidgetColor` · `cropperChooseText` · `cropperCancelText`

See `src/types.ts` for the full documented shape.

## Design notes

**Codegen uses `UnsafeObject` for options and results** rather than generated structs. Generated structs for a 20+ field options bag are painful to consume in Obj-C++ and force a native change for every new option. Typing lives in `src/types.ts` and `src/index.ts` validates before calling native.

**The Android cropper is `com.vanniktech:android-image-cropper`, not Yalantis uCrop.** uCrop ships on JitPack, so `image-crop-picker` makes every consuming app add the JitPack repo to its root `build.gradle`. This one is on Maven Central, so installing is just `yarn add`.

**The cropper activity's theme is pinned by this library.** The cropper declares `CropImageActivity` without a theme, so it inherits the host app's — and React Native's default is `Theme.AppCompat.DayNight.NoActionBar`. `CropImageActivity` puts Done/Cancel in the options menu, which needs an ActionBar to host, so under the stock RN theme the cropper renders with no way to confirm the crop. This library's manifest overrides the theme so consuming apps do not have to touch theirs.

**`pickMedia` and `captureMedia` converge on one path.** Both end in the same `deliver()` step that decides between the cropper and a plain result, so cropping behaves identically whether the image came from the gallery or the camera.

## Not implemented yet

- **Video compression.** Nothing here reduces video size; `quality`/`maxWidth`/`maxHeight` apply to images only. `videoQuality` only selects the camera's own recording profile at capture time.
- **`saveToPhotos`.** Captures are not written to the device gallery. Adding it would pull `WRITE_EXTERNAL_STORAGE` (API ≤ 28) and `NSPhotoLibraryAddUsageDescription` into every consuming app, which is at odds with the zero-setup goal above.
- **iOS `writeTempFile: false`** writes the file and then deletes it rather than never touching disk, so it saves storage churn but not the write itself.
- **`cropperCancelText` on Android** — the cropper's back arrow carries no label. `cropperChooseText` and `cropperToolbarTitle` are applied on both platforms.
- iOS-only `sortOrder` and `smartAlbums`; PHPicker doesn't expose them.

## Verification status

`example/` is a React Native CLI app that links this package and builds on both platforms. It carries two iOS test targets, both run by `xcodebuild test -workspace MediaPickerExample.xcworkspace -scheme MediaPickerExample -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`:

- `MediaPickerExampleUITests` — XCUITests that drive the real PHPicker, camera and cropper.
- `MediaPickerCaptureTests` — unit tests hosted by the app. A simulator renders a camera but has no capture pipeline, so its shutter never fires the delegate and everything the module does *after* a shot is unreachable from a UI test. These call that delegate directly with the same info dictionaries `UIImagePickerController` produces, which runs the real temp-file write, asset builder and crop hand-off.

**Android, exercised on an emulator (API 36) — no permission prompt in any flow:**

- picking a photo, a video, and three photos at once from the gallery
- capturing a photo and recording a video with the camera
- cropping after a pick and after a capture, with `cropRect` and output size checked against the source
- `maxWidth`/`maxHeight`/`quality`, `includeBase64`, `includeExif`, `includeExtra`
- `cameraType: 'front'` completes, but the AOSP camera ignores the hint — as documented, it is best-effort
- `invalid_options` for `mediaType: 'mixed'` on capture

**Android, exercised on an emulator (API 31):** the `ACTION_OPEN_DOCUMENT` fallback engages (the photo picker is absent), returns a `com.android.providers.media.documents` URI, and copies to cache like any other asset.

**iOS, exercised on a simulator (iOS 26) — 14 passing tests, no permission prompt beyond the system camera alert:**

- picking one photo and three, cropping after a pick, `includeBase64`/`includeExif`/`includeExtra`, `maxWidth`/`quality`
- `captureMedia` presenting the camera in photo mode, and the shutter leaving the promise unsettled rather than hanging
- video capture turned away by the media-type guard with `camera_unavailable` — the simulated camera reports no movie support, and without the guard the promise would never settle at all
- a captured photo becoming a file-backed `image/jpeg` asset at its true pixel size, with `fileSize` matching the bytes on disk
- a captured photo honouring `maxWidth`/`maxHeight`/`quality` through the same builder a gallery pick uses
- a captured recording copied out of the system temp file into the module's own directory, with duration in milliseconds and the track's real dimensions
- a captured photo with `cropping: true` reaching the cropper instead of resolving early, then resolving at exactly `cropWidth` × `cropHeight` with the `cropRect` it was cropped at
- `cannot_process_asset` when the camera returns no image, and when the recording cannot be read

**Expo, verified end to end (SDK 57 / RN 0.86):** installed from the packed npm tarball — not a symlink — so the published layout and the `files` allowlist are part of the test. `expo prebuild` runs the config plugin and writes all three `Info.plist` keys (custom overrides honoured), CocoaPods links the pod, and both platforms build. The merged Android manifest namespaces the FileProvider to the app's own id and declares **no camera or storage permission**. Picking and capturing a photo both work on an emulator; on the iOS simulator the module loads and round-trips.

**Not verified anywhere:** on iOS, that a real shutter calls the delegate at all — every line that runs after it is covered above, but the camera hardware itself is not, and neither is video *recording*, since no simulator offers it. Both need a physical device; `test8CaptureShutter` runs the full flow through **Use Photo** when one is attached. `saveToPhotos` is not implemented, and video compression is not implemented.

## Releasing

`files` in `package.json` is an allowlist, so there is no `.npmignore`: only `src`, the built `lib`, the
native sources, the podspec and the Expo plugin are published. `src` has to ship because React Native's
codegen reads the TurboModule spec out of it when the consuming app builds. `prepare` runs `bob build`,
which npm invokes before packing, so a stale `lib` cannot be published.

```bash
npm pack --dry-run   # 36 files, no build output, no example app
npm publish
git tag v$(node -p "require('./package.json').version") && git push --tags
```

The podspec takes its version from `package.json` and its tag from `v<version>`, so tagging that way is
what lets CocoaPods resolve a release.

## Xcode 16.3+ / Xcode 26 (RN 0.81 and older)

React Native vendors `fmt` 11.0.2 up to and including 0.81, whose `consteval` usage newer Clang rejects, and such an app will not compile at all until it is worked around. This is a React Native issue rather than one of this package. **RN 0.86 / Expo SDK 57 builds cleanly with no workaround**; only older versions need the hook that `example/ios/Podfile` carries:

```ruby
installer.pods_project.targets.each do |target|
  next unless target.name == 'fmt'
  target.build_configurations.each do |config|
    config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
  end
end
```

`fmt` gates `consteval` behind `FMT_CPLUSPLUS >= 201709L` and redefines the macro itself, so `-DFMT_CONSTEVAL=` cannot win; pinning only that target to C++17 is what actually disables it.
