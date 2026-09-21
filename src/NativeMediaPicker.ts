import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type { EventEmitter, UnsafeObject } from 'react-native/Libraries/Types/CodegenTypes';

/**
 * Codegen spec.
 *
 * Options and results cross the bridge as UnsafeObject (ReadableMap on Android,
 * NSDictionary on iOS) rather than generated structs. Generated structs for a
 * 20+ field options bag are painful to consume in Obj-C++ and force a native
 * change for every new option. All validation and defaulting happens in
 * src/index.ts, so native always receives a fully populated object.
 */
export interface Spec extends TurboModule {
  /** Resolves with a result object. Never rejects on user cancel. */
  pickMedia(options: UnsafeObject): Promise<UnsafeObject>;

  /** Resolves with a result object. Never rejects on user cancel. */
  captureMedia(options: UnsafeObject): Promise<UnsafeObject>;

  /** Crop an image that is already on disk. `options.path` is required. */
  cropImage(options: UnsafeObject): Promise<UnsafeObject>;

  /**
   * Shrink a file already on disk below a byte budget. `options.path` is
   * required, as is one of maxImageFileSize / maxVideoFileSize.
   */
  compressMedia(options: UnsafeObject): Promise<UnsafeObject>;

  /**
   * Fires while a video is being transcoded. Images are not reported: they
   * finish too quickly for progress to be meaningful.
   */
  readonly onCompressProgress: EventEmitter<{
    progress: number;
    index: number;
    total: number;
  }>;

  /**
   * Stop the video compression that is currently running, if any. The call it
   * belongs to still resolves, with the asset uncompressed.
   */
  cancelCompression(): Promise<void>;

  /** Delete temp files this module created. Empty string clears all of them. */
  cleanTempFiles(path: string): Promise<void>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('MediaPicker');
