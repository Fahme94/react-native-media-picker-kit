export type MediaType = 'photo' | 'video' | 'mixed';

export type CameraType = 'back' | 'front';

export type VideoQuality = 'low' | 'high';

export type PresentationStyle =
  | 'currentContext'
  | 'pageSheet'
  | 'fullScreen'
  | 'formSheet'
  | 'overFullScreen';

export type ErrorCode =
  | 'permission'
  | 'no_library_permission'
  | 'cannot_process_asset'
  | 'crop_failed'
  | 'compress_failed'
  | 'camera_unavailable'
  | 'invalid_options'
  | 'picker_busy'
  | 'others';

export interface PickerOptions {
  /** Default 'photo'. */
  mediaType?: MediaType;
  /** Default 1. Use 0 for unlimited (iOS 14+ / Android 13+). */
  selectionLimit?: number;
  /** Android only. Restrict the SAF fallback picker, e.g. ['image/jpeg']. */
  restrictMimeTypes?: string[];

  /** Downscale the longest edge of picked images. */
  maxWidth?: number;
  maxHeight?: number;
  /** JPEG quality 0..1. Default 1 (no re-encode unless resizing). */
  quality?: number;
  /** Convert HEIC/HEIF/PNG output to JPEG. Default true. */
  forceJpg?: boolean;

  /**
   * Compress the output until the file is at most this many bytes. 0 disables
   * it. Runs last, after maxWidth/maxHeight/quality and after any crop, so it
   * is the size the caller actually uploads.
   *
   * A ceiling only for files above `minimumFileSizeForCompress`, which defaults
   * to 10 MB. Set that to 0 to make this an unconditional ceiling.
   */
  maxImageFileSize?: number;
  /**
   * Same, for video: re-encodes to H.264/AAC at a bitrate derived from the
   * clip's duration. 0 disables it, which is the default -- video is never
   * touched unless this is set. Also subject to
   * `minimumFileSizeForCompress`.
   */
  maxVideoFileSize?: number;

  /**
   * Skip compression entirely for files below this many bytes, even when they
   * are over their budget. **Defaults to 10 MB**, so out of the box nothing
   * smaller than that is ever compressed, whatever budget you set.
   *
   * It applies to images as well as video, and to every call including
   * `compressMedia`, so a budget is a ceiling only above this size. A file that
   * is skipped comes back with `compressionSkipped: 'below_minimum'` rather
   * than an error -- code that only checks `errorCode` will not notice, so
   * check the field if an over-budget upload matters.
   *
   * Set it to 0 to compress whatever is over budget, however small.
   */
  minimumFileSizeForCompress?: number;

  includeBase64?: boolean;
  includeExif?: boolean;
  /** Include `id` and `timestamp`. May require library permission. */
  includeExtra?: boolean;
  /** iOS only. Skip writing a temp file when you only need base64. */
  writeTempFile?: boolean;
  /** iOS only. */
  presentationStyle?: PresentationStyle;

  /**
   * captureMedia only. Which camera to open. Honoured exactly on iOS; on
   * Android it is a hint the camera app is free to ignore, because the capture
   * intents have no standard lens-selection extra.
   */
  cameraType?: CameraType;
  /** captureMedia only, video. Maximum recording length in seconds. */
  durationLimit?: number;
  /** captureMedia only, video. Default 'high'. */
  videoQuality?: VideoQuality;

  /**
   * Cropping is only valid with mediaType 'photo' and selectionLimit 1.
   * Any other combination rejects with `invalid_options`.
   */
  cropping?: boolean;
  /** Target crop size. Omit both for a free-form crop. */
  cropWidth?: number;
  cropHeight?: number;
  freeStyleCropEnabled?: boolean;
  cropperCircleOverlay?: boolean;
  cropperToolbarTitle?: string;
  /** Hex, e.g. '#424242'. Android toolbar / iOS accent. */
  cropperToolbarColor?: string;
  cropperActiveWidgetColor?: string;
  cropperChooseText?: string;
  cropperCancelText?: string;
}

/** Reported while a video is being compressed. */
export interface CompressProgress {
  /** 0..1 for the asset currently being compressed. Never goes backwards. */
  progress: number;
  /** Which asset of the batch this is, from 0. */
  index: number;
  /** How many assets are being compressed in this call. */
  total: number;
}

/**
 * What `compressMedia` accepts. Deliberately narrower than PickerOptions: only
 * the byte budgets apply, so a file already under budget always comes back
 * untouched. The image-output options belong to picking.
 */
export type CompressOptions = Pick<
  PickerOptions,
  | 'maxImageFileSize'
  | 'maxVideoFileSize'
  | 'minimumFileSizeForCompress'
  | 'includeBase64'
  | 'includeExif'
>;

/**
 * Why an asset came back without being compressed. Present only when the file
 * is over its budget, so `compressionSkipped == null` means the budget was met
 * (or none was set).
 */
export type CompressionSkipped = 'below_minimum' | 'cancelled';

export interface Asset {
  /** file:// path in app cache. Null when writeTempFile is false (iOS). */
  uri: string | null;
  fileName: string;
  /** Bytes. */
  fileSize: number;
  /** MIME type. */
  type: string;
  width: number;
  height: number;
  /** Video only. Milliseconds. */
  duration?: number;
  /** Video only. Bits per second. */
  bitrate?: number;
  base64?: string;
  exif?: Record<string, unknown>;
  /**
   * includeExtra only. Platform-specific by necessity: iOS reports the PHAsset
   * localIdentifier, Android the gallery display name, because the Android
   * pickers hand back no stable asset id.
   */
  id?: string;
  /** includeExtra only. Android only — epoch milliseconds as a string. */
  timestamp?: string;
  /** Android: the original content:// uri. iOS: PHAsset localIdentifier. */
  originalPath?: string;
  cropRect?: { x: number; y: number; width: number; height: number };
  /**
   * Set only when the file is over its budget because compression was skipped
   * or stopped. Absent means the budget was met, or none was asked for.
   */
  compressionSkipped?: CompressionSkipped;
}

export interface PickerResult {
  didCancel: boolean;
  errorCode?: ErrorCode;
  errorMessage?: string;
  assets: Asset[];
}
