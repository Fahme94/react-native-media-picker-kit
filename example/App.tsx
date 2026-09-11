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
  captureMedia,
  cleanTempFiles,
  pickMedia,
  type PickerOptions,
  type PickerResult,
} from 'react-native-media-picker';

type Case = {label: string; options: PickerOptions; capture?: boolean};

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
];

export default function App() {
  // getEnforcing throws at import time if the TurboModule is not registered,
  // so reaching this state at all is the registration smoke test.
  const [log, setLog] = useState('module loaded');

  // Round-trips JS -> TurboModule -> native -> resolved promise without any UI,
  // so a failure here is a wiring failure rather than a picker failure.
  useEffect(() => {
    cleanTempFiles()
      .then(() => setLog('module loaded\nnative round trip OK (cleanTempFiles resolved)'))
      .catch(e => setLog(`native round trip FAILED: ${String(e)}`));
  }, []);

  const run = async (label: string, options: PickerOptions, capture?: boolean) => {
    setLog(`${label}: running…`);
    const result: PickerResult = capture
      ? await captureMedia(options)
      : await pickMedia(options);
    setLog(`${label}\n${JSON.stringify(result, null, 2)}`);
  };

  return (
    <SafeAreaView style={styles.root}>
      <View style={styles.buttons}>
        {CASES.map(({label, options, capture}) => (
          <TouchableOpacity
            key={label}
            style={[styles.button, capture && styles.capture]}
            onPress={() => run(label, options, capture)}>
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
  logBox: {flex: 1, margin: 12, backgroundColor: '#f2f2f2', borderRadius: 6},
  log: {fontFamily: 'Courier', fontSize: 11, padding: 10},
});
