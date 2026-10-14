# Metadata: EXIF, base64 and extra fields

Every asset reports its file, type, size and dimensions. Three options add more, and each costs some
time or memory, so they are off by default.

```ts
const result = await pickMedia({
  includeExif: true,
  includeBase64: true,
  includeExtra: true,
});
```

## Always there

| Field | What it is |
|---|---|
| `uri` | `file://` path of the file in the app's cache. |
| `fileName` | Display name, with the extension of the bytes actually written. |
| `fileSize` | Bytes. |
| `type` | MIME type, e.g. `image/jpeg`. |
| `width`, `height` | Pixels, upright (EXIF rotation already applied). |
| `duration` | Video only. **Milliseconds** on both platforms. |
| `bitrate` | Video only. Bits per second. |
| `originalPath` | Where it came from: a `content://` URI on Android, the `PHAsset` identifier on iOS. Pass it back as `preselected`. |
| `cropRect` | After a crop: the area kept, in the source image's pixels. |
| `compressionSkipped` | Set only when the file is over its budget because compression was skipped or stopped. See [Compression](compression.md). |

## `includeExif`

Images only. Adds `exif`, a map of EXIF tags.

- **iOS** returns the full EXIF dictionary.
- **Android** returns the common tags: date, make, model, orientation, aperture, exposure, focal length,
  ISO, GPS latitude and longitude, and the stored image size.

A photo that was resized or re-encoded has lost its EXIF on the way, so ask for it on picks you leave
at full quality.

## `includeBase64`

Images only. Adds `base64`, the file's bytes as a base64 string. It is about a third larger than the
file and crosses into JavaScript in one piece, so prefer uploading `uri` with `FormData` and keep this
for small images or APIs that only take base64.

On iOS, `writeTempFile: false` skips the file entirely when base64 is all you need; `uri` is then
`null`.

## `includeExtra`

Adds `id` and `timestamp`. The pickers give each platform different information, so these differ:

| Field | iOS | Android |
|---|---|---|
| `id` | `PHAsset` local identifier | Gallery display name (the Android pickers give out no stable id) |
| `timestamp` | Not set | File time, epoch milliseconds as a string |
