# Compression

Give the library a byte budget and it hands back a file that fits. Both options are in **bytes**, the
same unit as `Asset.fileSize`, so the result can be checked against what you asked for directly.

```ts
const result = await pickMedia({
  mediaType: 'mixed',
  maxImageFileSize: 2 * 1024 * 1024,   // 2 MB
  maxVideoFileSize: 10 * 1024 * 1024,  // 10 MB
});

result.assets[0].fileSize <= 2 * 1024 * 1024; // true, if it was over 10 MB to begin with
```

Each budget applies only to its own kind of media, so setting both is how you handle a `'mixed'` pick.
Either one left unset — or set to `0`, the default — means that kind is not compressed at all.

**Read [the 10 MB floor](#the-10-mb-floor) before relying on a budget.** By default nothing under
10 MB is compressed at all, whatever budget you set, so for most phone photos these options do
nothing until you lower `minimumFileSizeForCompress`.

To compress a file you already have on disk, use
[`compressMedia`](api.md#compressmediapath-options):

```ts
const smaller = await compressMedia(asset.uri, {
  maxImageFileSize: 500 * 1024,
});
```

That one only ever compresses — it takes the two budgets plus `includeBase64` / `includeExif`, and
leaves the file you gave it in place. It is **not** exempt from the floor: under 10 MB it returns the
file unchanged, so pass `minimumFileSizeForCompress: 0` if you mean it regardless of size.

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
| Frame rate | Capped at 30 fps on both platforms. A 60 fps recording comes back at 30 fps, which halves the frames to encode and so roughly halves the time |

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
finishes — show a spinner, and drive it from [progress](#progress).

Most of the cost scales with the length of the clip: measured on one device, time was very close to
linear in duration and changed much less with source resolution.

**A tighter budget does not make it faster, and can make it markedly slower.** A budget loose enough
to be met in one encode is the quick case. A budget tight enough that the first encode overshoots
costs a second one, which measured roughly twice the time for a *smaller* result. If you only need
the file under some limit, ask for that limit rather than the smallest number you can think of. If the clips come from your own camera flow, capping them at capture with
`videoQuality: 'low'` or `durationLimit` is the bigger lever than compressing a large original
afterwards.

On Android the encoder matters more than anything this library does. A device with a hardware H.264
encoder is far quicker than one falling back to software — which is also why an emulator, where the
codec is always software and OpenGL may be too, is a poor place to judge how fast this feels.

## The 10 MB floor

A file only slightly over its budget still costs a full transcode to bring under it, and that trade
is usually a bad one. So `minimumFileSizeForCompress` **defaults to 10 MB**: nothing smaller is
compressed, whatever budget you set.

```ts
await pickMedia({ maxImageFileSize: 2 * 1024 * 1024 });
// a 4 MB photo comes back at 4 MB, with compressionSkipped: 'below_minimum'

await pickMedia({
  maxImageFileSize: 2 * 1024 * 1024,
  minimumFileSizeForCompress: 0,          // now the budget is an absolute ceiling
});
// the same 4 MB photo comes back at 2 MB
```

It applies to **images as well as video**, and to **every call including `compressMedia`**. Two
things follow that are easy to be caught by:

- **A budget is a ceiling only above the floor.** Below it, a file comes back over budget by design.
- **`compress_failed` does not fire below the floor.** The call resolves *successfully* with an
  oversized file, so code that only inspects `errorCode` gets no signal. Check
  `asset.compressionSkipped` instead.

Typical phone photos are 2–5 MB, so with the default floor `maxImageFileSize` does nothing for most
of them. If you want photos compressed, set `minimumFileSizeForCompress: 0` — the cost the floor
exists to avoid is a video transcode, and image compression is a sub-second quality search.

## Progress

Video compression is the slow part, so it reports how far along it is:

```ts
const sub = addCompressProgressListener(({ progress, index, total }) => {
  setLabel(`Compressing ${index + 1} of ${total}: ${Math.round(progress * 100)}%`);
});
// later
sub.remove();
```

Images do not report: they finish too quickly for a bar to mean anything, so a call that compresses
no video emits nothing at all.

`progress` never goes backwards, including when the correction pass runs — the first encode owns `0`
to `0.85` of the range and the correction finishes it, rather than restarting at zero. Events are
throttled to whole percents, because the underlying encoders report far more often than any UI can
use and every event costs a bridge crossing.

## Letting the user stop it

A long transcode is worth being able to back out of:

```ts
await cancelCompression();
```

The call still resolves: you get the asset **uncompressed and over its budget**, with
`asset.compressionSkipped` set to `'cancelled'`. Nothing is left half-written, and during a
multi-select it stops the clip being worked on and everything queued behind it.

`compressionSkipped` is how you tell apart the three ways a file can come back over budget —
`'cancelled'`, `'below_minimum'`, or absent, which means the budget was met.

## When the budget cannot be met

When compression is *attempted* and cannot reach the budget, the call resolves with
`errorCode: 'compress_failed'` rather than quietly handing back an oversized file. In practice that
only happens with budgets far below what the format can represent: for video, anything under roughly
the 120 kbps floor for the clip's own length, so a ten-second clip cannot go much below 150 KB
however hard it is squeezed.

**This is not the same as being skipped.** A file below `minimumFileSizeForCompress` is never
attempted, so it resolves *successfully* while still over budget. The two outcomes look different to
your code:

| Outcome | `errorCode` | `asset.compressionSkipped` |
| --- | --- | --- |
| Compressed to fit | absent | absent |
| Under the 10 MB floor, left alone | absent | `'below_minimum'` |
| Cancelled part-way | absent | `'cancelled'` |
| Attempted and unreachable | `'compress_failed'` | — no asset |

Only the last one shows up in `errorCode`. If an over-budget upload is a problem, check
`compressionSkipped` too.

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
