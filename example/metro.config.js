const path = require('path');
const {getDefaultConfig, mergeConfig} = require('@react-native/metro-config');
const exclusionList = require('metro-config/src/defaults/exclusionList');

const root = path.resolve(__dirname, '..');

// The library is symlinked to the repo root, which carries its own copy of
// react and react-native as devDependencies. Metro has to watch the root for
// the library source but must never resolve those duplicates, or the app ends
// up with two Reacts.
const peers = ['react', 'react-native'];
const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const config = {
  watchFolders: [root],
  resolver: {
    blockList: exclusionList(
      peers.map(
        name =>
          new RegExp(`^${escape(path.join(root, 'node_modules', name))}\\/.*$`),
      ),
    ),
    extraNodeModules: Object.fromEntries(
      peers.map(name => [name, path.join(__dirname, 'node_modules', name)]),
    ),
  },
};

module.exports = mergeConfig(getDefaultConfig(__dirname), config);
