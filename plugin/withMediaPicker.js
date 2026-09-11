const {withInfoPlist} = require('expo/config-plugins');

/**
 * iOS terminates an app that opens the camera without NSCameraUsageDescription,
 * and there is no way for a native module to supply it at runtime. Android needs
 * nothing: the library declares no permissions and the photo picker, the SAF
 * fallback and the capture intents all work without one.
 */
const DEFAULTS = {
  cameraPermission: 'Allow $(PRODUCT_NAME) to use the camera to take photos and videos.',
  microphonePermission: 'Allow $(PRODUCT_NAME) to use the microphone to record audio with videos.',
  photoLibraryPermission: 'Allow $(PRODUCT_NAME) to access your photos.',
};

/**
 * Passing `false` for any entry removes that key, for apps that deliberately do
 * not use the corresponding feature and do not want the App Store prompt.
 */
const withMediaPicker = (config, props = {}) =>
  withInfoPlist(config, cfg => {
    const apply = (key, option, fallback) => {
      const value = props[option];
      if (value === false) {
        delete cfg.modResults[key];
      } else {
        cfg.modResults[key] = value ?? cfg.modResults[key] ?? fallback;
      }
    };

    apply('NSCameraUsageDescription', 'cameraPermission', DEFAULTS.cameraPermission);
    apply('NSMicrophoneUsageDescription', 'microphonePermission', DEFAULTS.microphonePermission);
    apply('NSPhotoLibraryUsageDescription', 'photoLibraryPermission', DEFAULTS.photoLibraryPermission);

    return cfg;
  });

module.exports = withMediaPicker;
