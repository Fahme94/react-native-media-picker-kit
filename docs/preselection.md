# Keeping earlier picks selected

A screen that lets the user add photos in several rounds wants the gallery to open with what they
already picked still ticked. Without that, the system picker opens blank every time, so the user
cannot see what they have, and picking the same photo again adds it twice.

<img src="media/preselected-ios.gif" width="240" alt="Reopening the picker with earlier picks still ticked on iOS" />

Pass the `originalPath` of every asset you already hold as `preselected`:

```ts
const MAX_PHOTOS = 10

const result = await pickMedia({
  mediaType: MediaType.photo,
  selectionLimit: MAX_PHOTOS, // the total, including what you already hold
  preselected: photos.map((p) => p.originalPath!),
})

if (result.didCancel || result.errorCode) return

setPhotos((current) => [
  ...current.filter((p) => !result.deselected.includes(p.originalPath!)),
  ...result.assets,
])
```

`result.assets` holds only the new items and `result.deselected` the ones the user unticked. Remove
the deselected ones (and `cleanTempFiles` their copies), then append the new ones.

## What each platform can show

| Platform | Ticked in the picker |
| --- | --- |
| iOS 15+ | Yes |
| Android photo picker with SDK extension R-15 or later (every Android 16 device, and Android 11-15 devices brought up to date by Google Play system updates) | Yes |
| Older Android photo pickers, and the document picker fallback | No |

Where the picker cannot show them, the call still behaves sensibly. The limit handed to the picker
is lowered by the number of preselected items, a photo the user picks again is dropped instead of
returned twice, and `deselected` stays empty, because the user never had a chance to untick
anything. Code written for the first two rows works unchanged on the third.

## The rules

- **`assets` is only what is new.** A preselected item is never copied, compressed or returned
  again.
- **`selectionLimit` is the total.** Preselected items take slots in it on every platform. When all
  of them are taken and the picker cannot show them, `pickMedia` resolves straight away with empty
  `assets` without opening anything, so disable your add button at the cap.
- **`deselected` is only reported where the items were shown.** Treat it as the list to remove, and
  never infer removals from what is missing in `assets`.
- **Unticking some items without adding any is a success**, not a cancel: `{ didCancel: false,
  assets: [], deselected: [...] }`. Unticking all of them is the exception, below.
- **On Android, an item whose read grant has expired** (for example after the device restarted) is
  not shown ticked and is not reported as deselected. It keeps its slot, and the user can still
  remove it from your own UI.

Requires `selectionLimit` of `0` or greater than `1`: neither platform can pre-select in
single-select mode, and replacing a single photo needs no pre-selection anyway. Cannot be combined
with `cropping`, or used with `captureMedia`. Breaking these rules returns `invalid_options`.

## Known limits

- **Unticking everything removes nothing.** With no item ticked, the Android photo picker hides its
  Done button, so the user can only back out, and iOS returns an empty list that is
  indistinguishable from Cancel. Either way the result is `didCancel: true` with an empty
  `deselected`. The user can still remove items from your own UI.
- **Camera shots have no gallery identity**, so they cannot be preselected. Lower `selectionLimit`
  by the number of camera shots you hold and preselect only the gallery picks.
- **Android matches items by `content://` URI.** The photo picker returns the same URI for the same
  item across picks, which is what both the ticks and the duplicate check rely on.
