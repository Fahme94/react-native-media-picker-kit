# Cropping

One flag. It behaves identically whether the image came from the gallery or the camera, because both
paths converge on the same delivery step before the cropper is reached.

```ts
const avatar = await pickMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 1000,
  cropHeight: 1000,
  cropperCircleOverlay: true,
  quality: 0.9,
});

const banner = await captureMedia({
  mediaType: 'photo',
  cropping: true,
  cropWidth: 1200,
  cropHeight: 900,
});
```

To crop a file you already have on disk, use [`cropImage`](api.md#cropimagepath-options).

## Output size

`cropWidth` and `cropHeight` mean **exact output size**, not just an aspect ratio.

| `cropWidth` / `cropHeight` | `freeStyleCropEnabled` | Result |
| --- | --- | --- |
| Both set | `false` | Aspect ratio locked to that shape, output resized to exactly those pixels |
| Both set | `true` | User picks any shape; output fits inside the box, aspect ratio preserved |
| Both `0` | either | Free-form crop, output is whatever the user framed |

Both platforms follow the same rule. Getting this consistent took explicit work — the iOS cropper has
no notion of an output size on its own, so a resize step was added to match Android rather than
letting `cropWidth` quietly mean two different things per platform.

The result carries `cropRect` with the region the user selected, in source-image coordinates.

## Constraints

**Cropping requires `mediaType: 'photo'` and `selectionLimit: 1`.** Any other combination resolves
with `errorCode: 'invalid_options'`.

Both underlying croppers operate on a single still image. `react-native-image-crop-picker` handles
the multi-select case by quietly cropping only the first asset, which is worse than a loud error —
you get back fewer edited images than the user thinks they chose, with nothing to indicate it.

## Appearance

| Option | Default | |
| --- | --- | --- |
| `cropperToolbarTitle` | `'Edit Photo'` | |
| `cropperToolbarColor` | `'#424242'` | Android toolbar background / iOS accent |
| `cropperActiveWidgetColor` | `'#424242'` | |
| `cropperChooseText` | `'Choose'` | Confirm button label, both platforms |
| `cropperCancelText` | `'Cancel'` | **iOS only** — the Android cropper uses an unlabelled back arrow |
| `cropperCircleOverlay` | `false` | Circular mask over a square crop |

## Under the hood

- **Android**: [`com.vanniktech:android-image-cropper`](https://github.com/CanHub/Android-Image-Cropper),
  from Maven Central. Deliberately not Yalantis uCrop, which ships on JitPack and would force every
  consuming app to add that repository to its root `build.gradle`.
- **iOS**: [`TOCropViewController`](https://github.com/TimOliver/TOCropViewController), pulled in by
  the podspec.

The library pins the Android cropper activity's theme in its own manifest. `CropImageActivity` puts
Done/Cancel in the options menu, which needs an ActionBar to host — and React Native's default theme
is `NoActionBar`, so under the stock setup the cropper would render with no way to confirm the crop.
Overriding it here means consuming apps do not have to touch their own theme.
