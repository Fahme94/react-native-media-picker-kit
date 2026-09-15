import { Platform } from 'react-native';
import NativeMediaPicker from './NativeMediaPicker';
import type { Asset, CompressOptions, PickerOptions, PickerResult } from './types';

export * from './types';

const DEFAULTS: Required<
  Pick<
    PickerOptions,
    | 'mediaType'
    | 'selectionLimit'
    | 'maxWidth'
    | 'maxHeight'
    | 'quality'
    | 'forceJpg'
    | 'maxImageFileSize'
    | 'maxVideoFileSize'
    | 'includeBase64'
    | 'includeExif'
    | 'includeExtra'
    | 'writeTempFile'
    | 'presentationStyle'
    | 'cameraType'
    | 'durationLimit'
    | 'videoQuality'
    | 'cropping'
    | 'cropWidth'
    | 'cropHeight'
    | 'freeStyleCropEnabled'
    | 'cropperCircleOverlay'
    | 'cropperToolbarTitle'
    | 'cropperToolbarColor'
    | 'cropperActiveWidgetColor'
    | 'cropperChooseText'
    | 'cropperCancelText'
  >
> = {
  mediaType: 'photo',
  selectionLimit: 1,
  maxWidth: 0,
  maxHeight: 0,
  quality: 1,
  forceJpg: true,
  maxImageFileSize: 0,
  maxVideoFileSize: 0,
  includeBase64: false,
  includeExif: false,
  includeExtra: false,
  writeTempFile: true,
  presentationStyle: 'currentContext',
  cameraType: 'back',
  durationLimit: 0,
  videoQuality: 'high',
  cropping: false,
  cropWidth: 0,
  cropHeight: 0,
  freeStyleCropEnabled: false,
  cropperCircleOverlay: false,
  cropperToolbarTitle: 'Edit Photo',
  cropperToolbarColor: '#424242',
  cropperActiveWidgetColor: '#424242',
  cropperChooseText: 'Choose',
  cropperCancelText: 'Cancel',
};

function fail(errorMessage: string, errorCode: PickerResult['errorCode'] = 'others'): PickerResult {
  return { didCancel: false, errorCode, errorMessage, assets: [] };
}

function normalize(options: PickerOptions) {
  return {
    ...DEFAULTS,
    ...stripUndefined(options),
    restrictMimeTypes: options.restrictMimeTypes ?? [],
    platform: Platform.OS,
  };
}

function stripUndefined<T extends object>(obj: T): Partial<T> {
  const out: Partial<T> = {};
  for (const key of Object.keys(obj) as (keyof T)[]) {
    if (obj[key] !== undefined) out[key] = obj[key];
  }
  return out;
}

function validate(o: PickerOptions): string | null {
  if (o.quality !== undefined && (o.quality < 0 || o.quality > 1)) {
    return 'quality must be between 0 and 1';
  }
  if (o.selectionLimit !== undefined && o.selectionLimit < 0) {
    return 'selectionLimit must be 0 or greater';
  }
  if (o.maxImageFileSize !== undefined && o.maxImageFileSize < 0) {
    return 'maxImageFileSize must be 0 or greater';
  }
  if (o.maxVideoFileSize !== undefined && o.maxVideoFileSize < 0) {
    return 'maxVideoFileSize must be 0 or greater';
  }
  if (o.cropping) {
    // uCrop/CanHub and TOCropViewController both operate on a single still image.
    // Rejecting loudly beats silently cropping only the first asset.
    if (o.mediaType && o.mediaType !== 'photo') {
      return "cropping requires mediaType 'photo'";
    }
    if (o.selectionLimit !== undefined && o.selectionLimit !== 1) {
      return 'cropping requires selectionLimit 1';
    }
  }
  return null;
}

function validateCapture(o: PickerOptions): string | null {
  // Android has two distinct capture intents (IMAGE_CAPTURE and VIDEO_CAPTURE)
  // and no "either" intent, so 'mixed' cannot be honoured the same way on both
  // platforms. Rejecting beats silently picking one of the two.
  if (o.mediaType === 'mixed') {
    return "captureMedia does not support mediaType 'mixed'";
  }
  if (o.durationLimit !== undefined && o.durationLimit < 0) {
    return 'durationLimit must be 0 or greater';
  }
  // The camera returns exactly one asset, so selectionLimit is forced below and
  // the shared rules are checked against that value rather than the caller's.
  return validate({...o, selectionLimit: 1});
}

/**
 * Open the system gallery picker. Resolves with a result object; a user cancel
 * is `{ didCancel: true, assets: [] }` and is not an error.
 */
export async function pickMedia(options: PickerOptions = {}): Promise<PickerResult> {
  const invalid = validate(options);
  if (invalid) return fail(invalid, 'invalid_options');

  try {
    const raw = await NativeMediaPicker.pickMedia(normalize(options));
    return raw as PickerResult;
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
}

/**
 * Open the system camera. Resolves with the same result shape as `pickMedia`;
 * a user cancel is `{ didCancel: true, assets: [] }` and is not an error.
 * Always returns at most one asset.
 */
export async function captureMedia(options: PickerOptions = {}): Promise<PickerResult> {
  const invalid = validateCapture(options);
  if (invalid) return fail(invalid, 'invalid_options');

  try {
    const raw = await NativeMediaPicker.captureMedia(
      normalize({...options, selectionLimit: 1})
    );
    return raw as PickerResult;
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
}

/** Crop an image already on disk (e.g. one returned by a previous pick). */
export async function cropImage(
  path: string,
  options: Omit<PickerOptions, 'mediaType' | 'selectionLimit' | 'cropping'> = {}
): Promise<PickerResult> {
  if (!path) return fail('path is required', 'invalid_options');

  try {
    const raw = await NativeMediaPicker.cropImage({
      ...normalize({ ...options, cropping: true }),
      path,
    });
    return raw as PickerResult;
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
}

/**
 * Shrink a file already on disk below a byte budget, without showing any UI.
 * Pass `maxImageFileSize` for images, `maxVideoFileSize` for video, or both
 * when the path could be either. Resolves with a single re-measured asset
 * pointing at the new file; a file already under budget is returned untouched.
 */
export async function compressMedia(
  path: string,
  options: CompressOptions = {}
): Promise<PickerResult> {
  if (!path) return fail('path is required', 'invalid_options');
  if (!options.maxImageFileSize && !options.maxVideoFileSize) {
    return fail(
      'maxImageFileSize or maxVideoFileSize is required',
      'invalid_options'
    );
  }
  const invalid = validate(options);
  if (invalid) return fail(invalid, 'invalid_options');

  try {
    const raw = await NativeMediaPicker.compressMedia({
      ...normalize(options),
      path,
    });
    return raw as PickerResult;
  } catch (e) {
    return fail(e instanceof Error ? e.message : String(e));
  }
}

/**
 * Remove temp files created by this module. Call it when you are done with the
 * picked assets — the cache is not cleared automatically.
 */
export function cleanTempFiles(path?: string): Promise<void> {
  return NativeMediaPicker.cleanTempFiles(path ?? '');
}

export type { Asset, CompressOptions, PickerOptions, PickerResult };
