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
  /** includeExtra only. */
  id?: string;
  timestamp?: string;
  /** Android: the original content:// uri. iOS: PHAsset localIdentifier. */
  originalPath?: string;
  cropRect?: { x: number; y: number; width: number; height: number };
}

export interface PickerResult {
  didCancel: boolean;
  errorCode?: ErrorCode;
  errorMessage?: string;
  assets: Asset[];
}
