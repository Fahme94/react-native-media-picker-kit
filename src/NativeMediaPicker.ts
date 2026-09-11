import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type { UnsafeObject } from 'react-native/Libraries/Types/CodegenTypes';

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

  /** Delete temp files this module created. Empty string clears all of them. */
  cleanTempFiles(path: string): Promise<void>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('MediaPicker');
