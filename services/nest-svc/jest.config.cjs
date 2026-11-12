// Nest 12 is ESM-only. Jest loads it from the compiled CommonJS specs through
// require(esm), which needs Node >= 24.9 and --experimental-vm-modules (set in
// the npm `test` script).
module.exports = {
  testEnvironment: 'node',
  testMatch: ['<rootDir>/dist/**/*.spec.js'],
};
