import React, {useEffect, useState} from 'react';
import {
  Platform,
  SafeAreaView,
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import {
  addCompressProgressListener,
  captureMedia,
  cleanTempFiles,
  compressMedia,
  pickMedia,
  type PickerOptions,
  type PickerResult,
} from 'react-native-media-picker-kit';

/** `compress` picks first with no budget, then compresses what came back. */
type Case = {
  label: string;
  options: PickerOptions;
  capture?: boolean;
  compress?: boolean;
};

const MB = 1024 * 1024;

const CASES: Case[] = [
  {label: 'Photo', options: {mediaType: 'photo'}},
  {
    label: 'Photo + crop 1:1',
    options: {mediaType: 'photo', cropping: true, cropWidth: 1000, cropHeight: 1000},
  },
  {label: 'Video', options: {mediaType: 'video'}},
  {label: 'Mixed ×5', options: {mediaType: 'mixed', selectionLimit: 5}},
  {label: 'Shoot photo', options: {mediaType: 'photo'}, capture: true},
  {
    label: 'Shoot + crop 1:1',
    options: {mediaType: 'photo', cropping: true, cropWidth: 800, cropHeight: 800},
    capture: true,
  },
  {label: 'Shoot photo (front)', options: {mediaType: 'photo', cameraType: 'front'}, capture: true},
  {
    label: 'Record video 10s',
    options: {mediaType: 'video', durationLimit: 10},
    capture: true,
  },
  {label: 'Capture mixed (invalid)', options: {mediaType: 'mixed'}, capture: true},
  {
    label: 'Photo +b64 +exif +extra',
    options: {
      mediaType: 'photo',
      includeBase64: true,
      includeExif: true,
      includeExtra: true,
    },
  },
  {
    label: 'Photo max400 q0.5',
    options: {mediaType: 'photo', maxWidth: 400, maxHeight: 400, quality: 0.5},
  },
  {label: 'Photos ×3', options: {mediaType: 'photo', selectionLimit: 3}},
  // minimumFileSizeForCompress defaults to 10 MB, so these would all skip on
  // anything a phone actually produces. Lowering it is what makes a budget an
  // unconditional ceiling, and these buttons exist to show the budgets working.
  {
    label: 'Photo ≤500KB',
    options: {
      mediaType: 'photo',
      maxImageFileSize: 500 * 1024,
      minimumFileSizeForCompress: 0,
    },
  },
  {
    label: 'Video ≤5MB',
    options: {
      mediaType: 'video',
      maxVideoFileSize: 5 * MB,
      minimumFileSizeForCompress: 0,
    },
  },
  {
    label: 'Mixed ≤1MB/≤5MB',
    options: {
      mediaType: 'mixed',
      selectionLimit: 5,
      maxImageFileSize: 1 * MB,
      maxVideoFileSize: 5 * MB,
      minimumFileSizeForCompress: 0,
    },
  },
  {
    label: 'Shoot ≤300KB',
    options: {
      mediaType: 'photo',
      maxImageFileSize: 300 * 1024,
      minimumFileSizeForCompress: 0,
    },
    capture: true,
  },
  {
    label: 'Crop then ≤200KB',
    options: {
      mediaType: 'photo',
      cropping: true,
      cropWidth: 1000,
      cropHeight: 1000,
      maxImageFileSize: 200 * 1024,
      minimumFileSizeForCompress: 0,
    },
  },
  {
    label: 'Pick → compress ≤300KB',
    options: {
      maxImageFileSize: 300 * 1024,
      maxVideoFileSize: 2 * MB,
      minimumFileSizeForCompress: 0,
    },
    compress: true,
  },
  // The default in action: same budget, floor left alone, so anything under
  // 10 MB comes back untouched with compressionSkipped: 'below_minimum'.
  {
    label: 'Photo ≤500KB (default floor)',
    options: {mediaType: 'photo', maxImageFileSize: 500 * 1024},
  },
];

/**
 * base64 payloads are megabytes of noise in a debug log, so report the length
 * instead and leave every other field untouched.
 */
const summarize = (key: string, value: unknown) =>
  key === 'base64' && typeof value === 'string'
    ? `<base64 ${value.length} chars>`
    : value;

export default function App() {
  // getEnforcing throws at import time if the TurboModule is not registered,
  // so reaching this state at all is the registration smoke test.
  const [log, setLog] = useState('module loaded');
  const [progress, setProgress] = useState('');

  // Video compression is the slow part, so this is what a real app would drive
  // a progress bar from.
  useEffect(() => {
    const sub = addCompressProgressListener(({progress: p, index, total}) => {
      setProgress(
        `compressing ${index + 1}/${total}: ${Math.round(p * 100)}%` +
          (p >= 1 ? ' (done)' : ''),
      );
    });
    return () => sub.remove();
  }, []);

  // Round-trips JS -> TurboModule -> native -> resolved promise without any UI,
  // so a failure here is a wiring failure rather than a picker failure.
  useEffect(() => {
    cleanTempFiles()
      .then(() => setLog('module loaded\nnative round trip OK (cleanTempFiles resolved)'))
      .catch(e => setLog(`native round trip FAILED: ${String(e)}`));
  }, []);

  const run = async (
    label: string,
    options: PickerOptions,
    capture?: boolean,
    compress?: boolean,
  ) => {
    setLog(`${label}: running…`);

    if (compress) {
      // Two steps on purpose: pick at full size, then compress the file on
      // disk, so the before/after sizes are both visible.
      const picked = await pickMedia({mediaType: 'mixed'});
      const source = picked.assets[0];
      if (!source?.uri) {
        setLog(`${label}\n${JSON.stringify(picked, summarize, 2)}`);
        return;
      }
      setLog(`${label}: compressing ${source.fileSize} bytes…`);
      const result = await compressMedia(source.uri, options);
      setLog(
        `${label}\nbefore: ${source.fileSize} bytes\n` +
          `${JSON.stringify(result, summarize, 2)}`,
      );
      return;
    }

    const result: PickerResult = capture
      ? await captureMedia(options)
      : await pickMedia(options);
    setLog(`${label}\n${JSON.stringify(result, summarize, 2)}`);
  };

  return (
    <SafeAreaView style={styles.root}>
      <View style={styles.buttons}>
        {CASES.map(({label, options, capture, compress}) => (
          <TouchableOpacity
            key={label}
            style={[styles.button, capture && styles.capture]}
            onPress={() => run(label, options, capture, compress)}>
            <Text style={styles.buttonText}>{label}</Text>
          </TouchableOpacity>
        ))}
        <TouchableOpacity
          style={styles.button}
          onPress={async () => {
            await cleanTempFiles();
            setLog('cleanTempFiles() resolved');
          }}>
          <Text style={styles.buttonText}>Clean temp files</Text>
        </TouchableOpacity>
      </View>
      {progress !== '' && <Text style={styles.progress}>{progress}</Text>}
      <ScrollView style={styles.logBox}>
        <Text style={styles.log}>{log}</Text>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  // SafeAreaView only insets on iOS; without this the buttons sit under the
  // Android status bar, which swallows the taps.
  root: {
    flex: 1,
    backgroundColor: '#fff',
    paddingTop: Platform.OS === 'android' ? StatusBar.currentHeight ?? 0 : 0,
  },
  buttons: {flexDirection: 'row', flexWrap: 'wrap', gap: 8, padding: 12},
  button: {backgroundColor: '#424242', borderRadius: 6, paddingHorizontal: 12, paddingVertical: 10},
  capture: {backgroundColor: '#1b5e20'},
  buttonText: {color: '#fff', fontWeight: '600'},
  progress: {marginHorizontal: 12, fontWeight: '600', color: '#1b5e20'},
  logBox: {flex: 1, margin: 12, backgroundColor: '#f2f2f2', borderRadius: 6},
  log: {fontFamily: 'Courier', fontSize: 11, padding: 10},
});
