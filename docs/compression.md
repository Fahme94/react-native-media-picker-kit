# Compression

Give the library a byte budget and it hands back a file that fits. Both options are in **bytes**, the
same unit as `Asset.fileSize`, so the result can be checked against what you asked for directly.

```ts
const result = await pickMedia({
  mediaType: 'mixed',
  maxImageFileSize: 2 * 1024 * 1024,   // 2 MB
  maxVideoFileSize: 10 * 1024 * 1024,  // 10 MB
});

result.assets[0].fileSize <= 2 * 1024 * 1024; // true
```

Each budget applies only to its own kind of media, so setting both is how you handle a `'mixed'` pick.
Either one left unset — or set to `0`, the default — means that kind is not compressed at all.

To compress a file you already have on disk, use
[`compressMedia`](api.md#compressmediapath-options):

```ts
const smaller = await compressMedia(asset.uri, {
  maxImageFileSize: 500 * 1024,
});
```

That one only ever compresses — it takes the two budgets plus `includeBase64` / `includeExif`, and
leaves the file you gave it in place.

## Where it happens in the pipeline

Compression is deliberately the **last** step, after `maxWidth` / `maxHeight` / `quality` and after
any crop:

```
pick or shoot  ->  maxWidth / maxHeight / quality / forceJpg  ->  crop  ->  compress
```

So the budget is measured against the bytes you are actually about to upload, not against some
intermediate the caller never sees. A cropped avatar with `maxImageFileSize` set is squeezed to fit
*after* the crop, not before it.

The reported `fileSize`, `width`, `height` and `type` always describe the returned file. A file that
is already under budget is returned untouched, so a small image costs nothing.

## Images

Quality is searched before pixels are given up, because dropping JPEG quality is nearly free
visually and losing resolution is not:

1. Binary-search the JPEG quality between `0.95` and `0.1` for the highest setting that fits.
2. If even `0.1` overflows, halve the frame and search again.
3. Stop once the short edge would fall below 64 px.

The output is always JPEG, whatever went in.

## Video

The clip is re-encoded to H.264 + AAC at a bitrate its own duration can afford —
`budget x 8 / duration` — split between the tracks:

| | |
| --- | --- |
| Audio | Up to 64 kbps, never below 24 kbps. Skipped entirely when the source has no audio track |
| Video | Whatever is left, with a 120 kbps floor |
| Resolution | Derived from the video bitrate, so the frame never carries more pixels than the bits can describe. Floored at a 144 px short edge |

An encoder treats an average bitrate as something to hover around rather than a ceiling, and key
frames and container overhead do not scale down with it — on a short clip, asking for exactly the
budget measured about 25% over. So the request aims deliberately under the limit, and if the result
still overshoots it is encoded once more against a budget corrected by how far the first pass
actually missed. Two passes is the maximum, and the output usually lands a little under what you
asked for rather than exactly on it.

Rotation is preserved as metadata rather than baked in by re-rendering, and the output is written
with its `moov` atom at the front, so an upload can begin streaming before the whole file arrives.

**Video compression is slow.** A minute of 4K can take tens of seconds on a mid-range device. It runs
off the main thread and the UI stays responsive, but the `pickMedia` promise does not resolve until it
finishes — show a spinner.

## When the budget cannot be met

If even the floors above cannot get under the budget, the call resolves with
`errorCode: 'compress_failed'` rather than quietly handing back an oversized file, so an upload never
fails later for a reason you cannot see. In practice this only happens with budgets far below what
the format can represent: for video that means anything under roughly the 120 kbps floor for the
clip's own length, so a ten-second clip cannot go much below 150 KB however hard it is squeezed.

## What is left alone

| | |
| --- | --- |
| Files already under budget | Returned untouched, no re-encode |
| Animated GIFs on Android | Skipped — re-encoding would flatten them to a single frame. Note that with the default `forceJpg: true` a GIF is already converted to JPEG on iOS before compression is reached |
| Files you pass to `compressMedia` | Never deleted. The library only removes files from its own cache directory, so passing a path of your own is safe |

## Platform notes

iOS uses `AVAssetReader` / `AVAssetWriter` directly and adds no pod.

Android has no public transcoding API — `MediaTranscodingManager` is hidden — so video compression
pulls in [`io.deepmedia.community:transcoder-android`](https://github.com/deepmedia/Transcoder)
(Apache-2.0, ~270 KB, MediaCodec-based, no FFmpeg). Like the cropper it resolves from Maven Central,
so installing this package is still just `yarn add` with nothing to add to your root `build.gradle`.
