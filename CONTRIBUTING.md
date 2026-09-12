# Contributing

Everything here is the detail that would clutter the README: why the native side is built the way it is,
exactly what has been run on a device, and how a release goes out.

## Design notes

**Codegen uses `UnsafeObject` for options and results** rather than generated structs. Generated structs for
a 20+ field options bag are painful to consume in Obj-C++ and force a native change for every new option.
Typing lives in `src/types.ts`, and `src/index.ts` validates before calling native.

**The Android cropper is `com.vanniktech:android-image-cropper`, not Yalantis uCrop.** uCrop ships on
JitPack, so `react-native-image-crop-picker` makes every consuming app add the JitPack repo to its root
`build.gradle`. This one is on Maven Central, so installing is just `yarn add`.

**The cropper activity's theme is pinned by this library.** The cropper declares `CropImageActivity` without
a theme, so it inherits the host app's — and React Native's default is `Theme.AppCompat.DayNight.NoActionBar`.
`CropImageActivity` puts Done/Cancel in the options menu, which needs an ActionBar to host, so under the stock
RN theme the cropper renders with no way to confirm the crop. This library's manifest overrides the theme so
consuming apps don't have to touch theirs.

**`pickMedia` and `captureMedia` converge on one path.** Both end in the same `deliver()` step that decides
between the cropper and a plain result, so cropping behaves identically whether the image came from the
gallery or the camera.

**iOS system frameworks are declared in the podspec.** Objective-C++ translation units don't get Clang module
auto-linking, so every framework the implementation touches has to be listed in `s.frameworks` or the app
fails at link time with undefined PHPicker/AVFoundation symbols.

## Running the example

`example/` is a React Native CLI app that links the package and builds on both platforms.

```bash
cd example
yarn install
yarn android            # or: yarn ios  (cd ios && pod install first)
```

It renders one button per test case and dumps the raw `PickerResult` JSON on screen, so every option can be
exercised by hand.

## iOS test targets

Both run from one command:

```bash
cd example/ios
xcodebuild test -workspace MediaPickerExample.xcworkspace -scheme MediaPickerExample \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

- **`MediaPickerExampleUITests`** — XCUITests that drive the real PHPicker, camera and cropper.
- **`MediaPickerCaptureTests`** — unit tests hosted by the app. A simulator renders a camera but has no
  capture pipeline behind it, so its shutter never fires the delegate and everything the module does *after*
  a shot is unreachable from a UI test. These call that delegate directly with the same info dictionaries
  `UIImagePickerController` produces, which runs the real temp-file write, asset builder and crop hand-off.

## Verification status

### Android — emulator, API 36

No permission prompt in any flow.

- picking a photo, a video, and three photos at once from the gallery
- capturing a photo and recording a video with the camera
- cropping after a pick and after a capture, with `cropRect` and output size checked against the source
- `maxWidth`/`maxHeight`/`quality`, `includeBase64`, `includeExif`, `includeExtra`
- `cameraType: 'front'` completes, but the AOSP camera ignores the hint — as documented, it is best-effort
- `invalid_options` for `mediaType: 'mixed'` on capture

### Android — emulator, API 31

The `ACTION_OPEN_DOCUMENT` fallback engages (the photo picker is absent), returns a
`com.android.providers.media.documents` URI, and copies to cache like any other asset.

### iOS — simulator, iOS 26

14 passing tests, no permission prompt beyond the system camera alert.

- picking one photo and three, cropping after a pick, `includeBase64`/`includeExif`/`includeExtra`,
  `maxWidth`/`quality`
- `captureMedia` presenting the camera in photo mode, and the shutter leaving the promise unsettled rather
  than hanging
- video capture turned away by the media-type guard with `camera_unavailable` — the simulated camera reports
  no movie support, and without the guard the promise would never settle at all
- a captured photo becoming a file-backed `image/jpeg` asset at its true pixel size, with `fileSize` matching
  the bytes on disk
- a captured photo honouring `maxWidth`/`maxHeight`/`quality` through the same builder a gallery pick uses
- a captured recording copied out of the system temp file into the module's own directory, with duration in
  milliseconds and the track's real dimensions
- a captured photo with `cropping: true` reaching the cropper instead of resolving early, then resolving at
  exactly `cropWidth` × `cropHeight` with the `cropRect` it was cropped at
- `cannot_process_asset` when the camera returns no image, and when the recording cannot be read

### Expo — SDK 57 / RN 0.86

Installed from the packed npm tarball, not a symlink, so the published layout and the `files` allowlist are
part of the test. `expo prebuild` runs the config plugin and writes all three `Info.plist` keys (custom
overrides honoured), CocoaPods links the pod, and both platforms build. The merged Android manifest
namespaces the FileProvider to the app's own id and declares no camera or storage permission. Picking and
capturing a photo both work on an emulator; on the iOS simulator the module loads and round-trips.

### Not verified anywhere

On iOS, that a real shutter calls the delegate at all — every line that runs after it is covered above, but
the camera hardware itself is not, and neither is video *recording*, since no simulator offers it. Both need
a physical device; `test8CaptureShutter` runs the full flow through **Use Photo** when one is attached.

## Releasing

`files` in `package.json` is an allowlist, so there is no `.npmignore`: only `src`, the built `lib`, the
native sources, the podspec and the Expo plugin are published. `src` has to ship because React Native's
codegen reads the TurboModule spec out of it when the consuming app builds. `prepare` runs `bob build`,
which npm invokes before packing, so a stale `lib` can't be published.

```bash
npm pack --dry-run   # 36 files, no build output, no example app
npm publish
git tag "v$(node -p "require('./package.json').version")" && git push --tags
```

The podspec takes its version from `package.json` and its tag from `v<version>`, so tagging that way is what
lets CocoaPods resolve a release.
