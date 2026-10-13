module.exports = {
  root: true,
  extends: '@react-native',
  ignorePatterns: ['lib/', 'example/', 'node_modules/'],
  rules: {
    // One-line guards (`if (!path) return fail(...)`) are the house style.
    curly: 'off',
  },
  overrides: [
    {
      // The Expo config plugin is plain Node, loaded without Babel.
      files: ['app.plugin.js', 'plugin/**/*.js'],
      parserOptions: { requireConfigFile: false },
      env: { node: true },
    },
  ],
};
