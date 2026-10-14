/**
 * @format
 */

import React from 'react';
import ReactTestRenderer from 'react-test-renderer';
import App from '../App';

// The TurboModule only exists in a native build, so Jest gets stand-ins that
// resolve the way the real calls do when the user backs out.
jest.mock('react-native-media-picker-kit', () => {
  const cancelled = Promise.resolve({didCancel: true, assets: [], deselected: []});
  return {
    MediaType: {photo: 'photo', video: 'video', mixed: 'mixed'},
    CameraType: {back: 'back', front: 'front'},
    pickMedia: jest.fn(() => cancelled),
    captureMedia: jest.fn(() => cancelled),
    compressMedia: jest.fn(() => cancelled),
    cleanTempFiles: jest.fn(() => Promise.resolve()),
    addCompressProgressListener: jest.fn(() => ({remove: jest.fn()})),
  };
});

test('renders correctly', async () => {
  await ReactTestRenderer.act(() => {
    ReactTestRenderer.create(<App />);
  });
});
