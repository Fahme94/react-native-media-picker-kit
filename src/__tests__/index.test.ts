import NativeMediaPicker from '../NativeMediaPicker';
import {
  addCompressProgressListener,
  CameraType,
  cancelCompression,
  captureMedia,
  cleanTempFiles,
  compressMedia,
  cropImage,
  MediaType,
  pickMedia,
  VideoQuality,
} from '../index';
import type { PickerOptions } from '../types';

jest.mock('../NativeMediaPicker', () => ({
  __esModule: true,
  default: {
    pickMedia: jest.fn(),
    captureMedia: jest.fn(),
    cropImage: jest.fn(),
    compressMedia: jest.fn(),
    onCompressProgress: jest.fn(),
    cancelCompression: jest.fn(),
    cleanTempFiles: jest.fn(),
  },
}));

const native = NativeMediaPicker as jest.Mocked<typeof NativeMediaPicker>;

const success = { didCancel: false, assets: [{ uri: 'file:///a.jpg' }], deselected: [] };

/** The options object the last call handed to native. */
function sent(fn: { mock: { calls: unknown[][] } }) {
  return fn.mock.calls[fn.mock.calls.length - 1][0];
}

beforeEach(() => {
  jest.clearAllMocks();
  for (const fn of [
    native.pickMedia,
    native.captureMedia,
    native.cropImage,
    native.compressMedia,
  ]) {
    fn.mockResolvedValue(success);
  }
});

describe('pickMedia', () => {
  it('sends every default when called without options', async () => {
    await pickMedia();

    expect(sent(native.pickMedia)).toMatchObject({
      mediaType: 'photo',
      selectionLimit: 1,
      quality: 1,
      forceJpg: true,
      minimumFileSizeForCompress: 10 * 1024 * 1024,
      cropping: false,
      restrictMimeTypes: [],
      preselected: [],
      platform: 'ios',
    });
  });

  it('lets caller options override defaults, but not with undefined', async () => {
    await pickMedia({ mediaType: 'video', selectionLimit: 3, quality: undefined });

    expect(sent(native.pickMedia)).toMatchObject({
      mediaType: 'video',
      selectionLimit: 3,
      quality: 1,
    });
  });

  it('passes the native result through', async () => {
    await expect(pickMedia()).resolves.toEqual(success);
  });

  it('fills in deselected when native leaves it out', async () => {
    native.pickMedia.mockResolvedValue({ didCancel: true, assets: [] });

    await expect(pickMedia()).resolves.toEqual({ didCancel: true, assets: [], deselected: [] });
  });

  it('resolves with an error result when native rejects with an Error', async () => {
    native.pickMedia.mockRejectedValue(new Error('boom'));

    await expect(pickMedia()).resolves.toEqual({
      didCancel: false,
      errorCode: 'others',
      errorMessage: 'boom',
      assets: [],
      deselected: [],
    });
  });

  it('resolves with an error result when native rejects with a non-Error', async () => {
    native.pickMedia.mockRejectedValue('plain string');

    await expect(pickMedia()).resolves.toMatchObject({
      errorCode: 'others',
      errorMessage: 'plain string',
    });
  });

  it.each<[string, PickerOptions, string]>([
    ['quality below 0', { quality: -0.1 }, 'quality must be between 0 and 1'],
    ['quality above 1', { quality: 1.1 }, 'quality must be between 0 and 1'],
    ['negative selectionLimit', { selectionLimit: -1 }, 'selectionLimit must be 0 or greater'],
    ['negative maxImageFileSize', { maxImageFileSize: -1 }, 'maxImageFileSize must be 0 or greater'],
    ['negative maxVideoFileSize', { maxVideoFileSize: -1 }, 'maxVideoFileSize must be 0 or greater'],
    [
      'negative minimumFileSizeForCompress',
      { minimumFileSizeForCompress: -1 },
      'minimumFileSizeForCompress must be 0 or greater',
    ],
    [
      'cropping a video',
      { cropping: true, mediaType: 'video' },
      "cropping requires mediaType 'photo'",
    ],
    [
      'cropping several items',
      { cropping: true, selectionLimit: 2 },
      'cropping requires selectionLimit 1',
    ],
    [
      'preselected in single select',
      { preselected: ['content://a'] },
      'preselected requires selectionLimit 0 or greater than 1',
    ],
    [
      'more preselected than the limit',
      { preselected: ['a', 'b', 'c'], selectionLimit: 2 },
      'preselected has more items than selectionLimit',
    ],
    [
      // Cropping needs a limit of 1 and preselection needs anything but 1, so
      // the cropping rule always fires first.
      'preselected with cropping',
      { preselected: ['a'], selectionLimit: 0, cropping: true },
      'cropping requires selectionLimit 1',
    ],
  ])('rejects %s without calling native', async (_, options, message) => {
    await expect(pickMedia(options)).resolves.toEqual({
      didCancel: false,
      errorCode: 'invalid_options',
      errorMessage: message,
      assets: [],
      deselected: [],
    });
    expect(native.pickMedia).not.toHaveBeenCalled();
  });

  it('accepts preselected with an unlimited selection', async () => {
    await pickMedia({ preselected: ['a', 'b', 'c'], selectionLimit: 0 });

    expect(sent(native.pickMedia)).toMatchObject({ preselected: ['a', 'b', 'c'] });
  });
});

describe('captureMedia', () => {
  it('always asks native for a single asset', async () => {
    await captureMedia({ selectionLimit: 5 });

    expect(sent(native.captureMedia)).toMatchObject({ selectionLimit: 1 });
  });

  it('checks cropping against the forced single selection', async () => {
    await expect(captureMedia({ cropping: true, selectionLimit: 5 })).resolves.toEqual(success);
  });

  it.each<[string, PickerOptions, string]>([
    ['mixed media', { mediaType: 'mixed' }, "captureMedia does not support mediaType 'mixed'"],
    ['preselected', { preselected: ['a'] }, 'captureMedia does not support preselected'],
    ['negative durationLimit', { durationLimit: -1 }, 'durationLimit must be 0 or greater'],
    ['an invalid shared option', { quality: 2 }, 'quality must be between 0 and 1'],
  ])('rejects %s without calling native', async (_, options, message) => {
    await expect(captureMedia(options)).resolves.toMatchObject({
      errorCode: 'invalid_options',
      errorMessage: message,
    });
    expect(native.captureMedia).not.toHaveBeenCalled();
  });

  it('resolves with an error result when native rejects', async () => {
    native.captureMedia.mockRejectedValue(new Error('no camera'));

    await expect(captureMedia()).resolves.toMatchObject({
      errorCode: 'others',
      errorMessage: 'no camera',
    });
  });
});

describe('cropImage', () => {
  it('requires a path', async () => {
    await expect(cropImage('')).resolves.toMatchObject({
      errorCode: 'invalid_options',
      errorMessage: 'path is required',
    });
    expect(native.cropImage).not.toHaveBeenCalled();
  });

  it('sends the path with cropping turned on', async () => {
    await cropImage('file:///a.jpg', { cropWidth: 300, cropHeight: 300 });

    expect(sent(native.cropImage)).toMatchObject({
      path: 'file:///a.jpg',
      cropping: true,
      cropWidth: 300,
      cropHeight: 300,
    });
  });

  it('resolves with an error result when native rejects', async () => {
    native.cropImage.mockRejectedValue(new Error('crop broke'));

    await expect(cropImage('file:///a.jpg')).resolves.toMatchObject({
      errorCode: 'others',
      errorMessage: 'crop broke',
    });
  });
});

describe('compressMedia', () => {
  it('requires a path', async () => {
    await expect(compressMedia('', { maxImageFileSize: 100 })).resolves.toMatchObject({
      errorCode: 'invalid_options',
      errorMessage: 'path is required',
    });
  });

  it('requires a budget', async () => {
    await expect(compressMedia('file:///a.jpg')).resolves.toMatchObject({
      errorCode: 'invalid_options',
      errorMessage: 'maxImageFileSize or maxVideoFileSize is required',
    });
    expect(native.compressMedia).not.toHaveBeenCalled();
  });

  it('checks the shared rules', async () => {
    await expect(
      compressMedia('file:///a.jpg', { maxImageFileSize: 100, minimumFileSizeForCompress: -1 })
    ).resolves.toMatchObject({ errorCode: 'invalid_options' });
    expect(native.compressMedia).not.toHaveBeenCalled();
  });

  it('sends the path and the budget', async () => {
    await compressMedia('file:///a.mp4', { maxVideoFileSize: 5_000_000 });

    expect(sent(native.compressMedia)).toMatchObject({
      path: 'file:///a.mp4',
      maxVideoFileSize: 5_000_000,
      minimumFileSizeForCompress: 10 * 1024 * 1024,
    });
  });

  it('resolves with an error result when native rejects', async () => {
    native.compressMedia.mockRejectedValue(new Error('encoder died'));

    await expect(compressMedia('file:///a.mp4', { maxVideoFileSize: 1 })).resolves.toMatchObject({
      errorCode: 'others',
      errorMessage: 'encoder died',
    });
  });
});

describe('progress, cancel and cleanup', () => {
  it('subscribes the listener and hands back the subscription', () => {
    const subscription = { remove: jest.fn() };
    (native.onCompressProgress as jest.Mock).mockReturnValue(subscription);
    const listener = jest.fn();

    const result = addCompressProgressListener(listener);

    expect(native.onCompressProgress).toHaveBeenCalledWith(listener);
    expect(result).toBe(subscription);
  });

  it('forwards cancelCompression', async () => {
    native.cancelCompression.mockResolvedValue(undefined);

    await cancelCompression();

    expect(native.cancelCompression).toHaveBeenCalledTimes(1);
  });

  it('cleans every temp file when no path is given', async () => {
    native.cleanTempFiles.mockResolvedValue(undefined);

    await cleanTempFiles();
    await cleanTempFiles('file:///a.jpg');

    expect(native.cleanTempFiles.mock.calls).toEqual([[''], ['file:///a.jpg']]);
  });
});

describe('constants', () => {
  it('match the strings native reads', () => {
    expect(MediaType).toEqual({ photo: 'photo', video: 'video', mixed: 'mixed' });
    expect(CameraType).toEqual({ back: 'back', front: 'front' });
    expect(VideoQuality).toEqual({ low: 'low', high: 'high' });
  });
});
