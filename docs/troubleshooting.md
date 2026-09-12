# Troubleshooting

## The module is undefined / autolinking missed it

React Native autolinking should pick the package up. If it does not, register it by hand:

```kotlin
override fun getPackages(): List<ReactPackage> =
  PackageList(this).packages.apply { add(MediaPickerPackage()) }
```

On iOS, re-run `pod install` from the `ios` directory after installing.

Note that `getEnforcing` throws at import time if the TurboModule is not registered, so a missing
module surfaces as a crash on import rather than a silent `undefined`.

## "New Architecture is required"

There is no legacy bridge fallback. Set `newArchEnabled=true` in `android/gradle.properties`, and
make sure your iOS pods were installed with the New Architecture active. RN 0.79+ only.

## The photo picker does not appear on older Android

Below `minSdkVersion` 30 you may need the backported photo picker:

```gradle
// android/app/build.gradle
implementation "androidx.activity:activity:1.9.+"
```

This is the same requirement `react-native-image-picker` documents. Without it, the library falls
back to `ACTION_OPEN_DOCUMENT`, which works but shows the system file browser instead of the photo
grid.

## The cropper has no Done button

Fixed in this library, but worth knowing what it was: `CropImageActivity` puts Done and Cancel in the
options menu, which needs an ActionBar to host. React Native's default theme is
`Theme.AppCompat.DayNight.NoActionBar`, so the cropper inherits a themeless activity and renders with
no way to confirm. This library pins the activity's theme in its own manifest, so you should never
see it. If you do, check whether something in your app is overriding
`com.canhub.cropper.CropImageActivity`'s theme back.

## iOS build fails in `fmt` with a `consteval` error

Affects **React Native 0.81 and older on Xcode 16.3+**. RN vendors `fmt` 11.0.2, whose `consteval`
usage newer Clang rejects, and the app will not compile at all until it is worked around.

This is a React Native issue rather than one of this package, and **RN 0.86 / Expo SDK 57 build
cleanly with no workaround.** Older versions need a Podfile hook:

```ruby
# ios/Podfile, inside post_install
installer.pods_project.targets.each do |target|
  next unless target.name == 'fmt'
  target.build_configurations.each do |config|
    config.build_settings['CLANG_CXX_LANGUAGE_STANDARD'] = 'c++17'
  end
end
```

`fmt` gates `consteval` behind `FMT_CPLUSPLUS >= 201709L` and redefines the macro itself, so
`-DFMT_CONSTEVAL=` cannot win — pinning only that target to C++17 is what actually disables it.
[`example/ios/Podfile`](../example/ios/Podfile) carries this hook.

## Undefined symbols for PHPicker or AVFoundation at link time

Re-run `pod install`. The podspec declares every system framework the Objective-C++ implementation
touches, because Objective-C++ translation units do not get Clang module auto-linking — a stale
Pods project from before that was added will fail here.

## `camera_unavailable` on a simulator

Expected. An iOS simulator renders a camera UI but has no capture pipeline behind it, and reports no
movie support at all, so `captureMedia({ mediaType: 'video' })` resolves with `camera_unavailable`
rather than hanging. Test camera capture on a physical device.

## The promise never settles

It should not be possible — every path resolves, including cancels and errors. If you hit one,
please [open an issue](https://github.com/Fahme94/react-native-media-picker/issues) with the options
you passed and the platform.
