# Expo

This package works in Expo projects through a bundled config plugin. It has been installed from the
packed npm tarball into a fresh **Expo SDK 57 / RN 0.86** app and run on both platforms.

## Development builds only

Expo Go cannot load this module — it contains native code that is not part of the Expo Go binary. Use
a development build:

```sh
npx expo prebuild
npx expo run:android    # or: npx expo run:ios
```

## The config plugin

Add it to `app.json` and you are done. It writes the iOS `Info.plist` keys; Android needs nothing.

```json
{
  "expo": {
    "plugins": ["react-native-media-picker-kit"]
  }
}
```

Defaults written on `expo prebuild`:

| Key | Plugin option | Default string |
| --- | --- | --- |
| `NSCameraUsageDescription` | `cameraPermission` | Allow $(PRODUCT_NAME) to use the camera to take photos and videos. |
| `NSMicrophoneUsageDescription` | `microphonePermission` | Allow $(PRODUCT_NAME) to use the microphone to record audio with videos. |
| `NSPhotoLibraryUsageDescription` | `photoLibraryPermission` | Allow $(PRODUCT_NAME) to access your photos. |

## Overriding the strings

Pass your own copy, which is what the App Store review actually reads:

```json
{
  "expo": {
    "plugins": [
      ["react-native-media-picker-kit", {
        "cameraPermission": "Take a photo or video to attach.",
        "microphonePermission": "Record audio with your video.",
        "photoLibraryPermission": "Attach a photo from your library."
      }]
    ]
  }
}
```

Pass `false` to **remove** a key for a feature you do not use. If your app never records video, you
have no business asking for the microphone:

```json
["react-native-media-picker-kit", { "microphonePermission": false }]
```

Precedence is: a string you pass to the plugin wins, then whatever is already in your own
`ios.infoPlist`, then the default. So the plugin fills in what is missing rather than overwriting
copy you have already written.

## What you get on Android

Nothing to configure, and nothing added to your manifest except the library's own `FileProvider`,
namespaced to your application id. Verified on a prebuilt Expo app: the merged manifest declares
**no camera and no storage permission**, and the provider authority resolves to
`<your.application.id>.mediapickerprovider`.
