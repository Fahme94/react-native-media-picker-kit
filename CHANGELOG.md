# Changelog

All notable changes to this package. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and from 1.0.0 the package follows [Semantic Versioning](https://semver.org/): option names, result fields
and error codes only change in a major version.

## [1.0.0] - 2026-10-14

The API is now stable. Nothing a caller uses changes from 0.2.2 apart from the one removal below.

### Removed

- `no_library_permission` from `ErrorCode`. No platform ever returned it: the gallery needs no permission,
  `includeExtra` included. Code that only compared against it can drop the branch.

### Fixed

- Several photos picked at once on iOS now come back in the order the user tapped them, not the order they
  finished loading.
- Android: several photos picked at once come back in the order the user tapped them on every photo picker
  that supports ordered selection (SDK extension R-12), not only on the ones that kept that order by default.
- A second call made while a picker is still settling can no longer resolve the first call's promise, on
  either platform.
- `cleanTempFiles(path)` refuses any path outside the module's own temp directory, including one that
  reaches it through `..` or a symlink.
- Android: a picked `.mov` keeps its `.mov` extension instead of being renamed `.mp4`.
- Android: image compression tries the lowest JPEG quality first, so an image that cannot meet its budget
  fails fast instead of after a full quality search.
- The `expo` peer dependency now asks for SDK 53 or later, the first on React Native 0.79. It said 50.

### Changed

- iOS: videos come back as MP4 (`video/mp4`, `.mp4`), picked or recorded. The camera and most library
  clips are QuickTime `.mov`, which was handed over untouched whenever no transcode ran, and many upload
  services refuse it. The clip is rewrapped without re-encoding, so quality and size stay the same; one
  whose tracks an MP4 cannot hold is still returned as it was. `compressMedia` is unchanged.
- The native code on both platforms is split into one file per job (picker, camera, cropper, image and
  video processing, files, results). See [Code layout](CONTRIBUTING.md#code-layout).

### Added

- `addProcessProgressListener`: progress for the steps before compression on iOS, copying a picked video
  out of the photo library (`stage: 'loading'`, iCloud download included) and rewrapping it as MP4
  (`stage: 'converting'`). See [Progress](docs/compression.md#before-compression-ios).
- Supported versions table in the README, and a guide per feature under `docs/`, with recordings.
- CI on every pull request: lint, type check and JS tests, then the native test suites on an Android
  emulator and an iOS simulator.

## [0.2.2] - 2026-10-12

### Added

- `preselected`: reopen the gallery with earlier picks still ticked. Picks the user unticks come back in
  the new `deselected` field, which every result now carries. See [Keeping earlier picks selected](docs/preselection.md).
- `MediaType`, `CameraType` and `VideoQuality` constants, so `MediaType.photo` can be written instead of
  `'photo'`. The string values still work.

## [0.2.1] - 2026-09-27

### Fixed

- Android: resizing a photo taken in portrait used the stored, unrotated size, so `maxWidth` and
  `maxHeight` were applied to the wrong edges.

## [0.2.0] - 2026-09-21

### Added

- `addCompressProgressListener` and `cancelCompression` for video compression. A cancelled asset comes
  back uncompressed with `compressionSkipped: 'cancelled'`.
- `minimumFileSizeForCompress`, which defaults to 10 MB.

### Changed

- Files under 10 MB are no longer compressed, whatever `maxImageFileSize` or `maxVideoFileSize` says, and
  come back with `compressionSkipped: 'below_minimum'`. Set `minimumFileSizeForCompress: 0` for the
  0.1.1 behaviour.

## [0.1.1] - 2026-09-15

### Added

- `compressMedia`, and the `maxImageFileSize` and `maxVideoFileSize` options on every call, to bring a
  file under a byte budget.

### Fixed

- Android: the FileProvider uses its own class, so it no longer clashes with another library's provider
  in the same app.

## [0.1.0] - 2026-09-12

First release: `pickMedia`, `captureMedia`, `cropImage` and `cleanTempFiles`, with the Expo config plugin.

[1.0.0]: https://github.com/Fahme94/react-native-media-picker/compare/v0.2.2...v1.0.0
[0.2.2]: https://github.com/Fahme94/react-native-media-picker/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/Fahme94/react-native-media-picker/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/Fahme94/react-native-media-picker/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/Fahme94/react-native-media-picker/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Fahme94/react-native-media-picker/releases/tag/v0.1.0
