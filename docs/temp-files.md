# Temp files

Every asset this library returns is a real file in your app's cache directory. Nothing deletes them
for you.

## Where they live

| Platform | Location |
| --- | --- |
| Android | `<app cache>/rn_media_picker/` |
| iOS | `NSTemporaryDirectory()/rn_media_picker/` |

Both are private to your app and both are subject to the OS reclaiming space under pressure — treat
an asset as valid for the current session, not as permanent storage. Copy it somewhere durable if you
need it to survive.

## Why a copy at all

On Android a gallery pick hands back a `content://` URI. Passing that to JavaScript is what
`react-native-image-picker` does for videos, and it breaks anything that expects a path — uploads,
`fs` calls, video players. This library copies every asset into its own cache first, so `uri` is
always a readable `file://`.

Captures are copied for the same reason: the camera app writes to a temp location that is not yours
to keep.

## Cleaning up

```ts
import { cleanTempFiles } from 'react-native-media-picker-kit';

await cleanTempFiles();           // everything this library wrote
await cleanTempFiles(asset.uri);  // just one asset
```

A good moment is after you have uploaded or persisted the assets — not in a screen unmount, since the
user may still be looking at a preview backed by that file.

Both platforms refuse to delete anything outside the library's own cache directory, so passing a bad
path cannot erase user data or another library's files.

## Skipping the write on iOS

If you only need base64 and never touch the file, `writeTempFile: false` avoids leaving one behind:

```ts
const result = await pickMedia({ includeBase64: true, writeTempFile: false });
result.assets[0].uri; // null
```

Be aware of what this does and does not do: the file is written and then deleted, rather than never
being written at all. It saves storage churn, not the write itself.
