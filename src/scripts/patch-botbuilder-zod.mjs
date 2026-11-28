import { readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
// Temporary bridge for BotBuilder 4.23.3 until the Teams SDK migration lands.
// Use only fixed Zod 4 APIs; do not load the bundled Zod 3 compatibility entry point.
const files = [
  ['botbuilder', 'teamsActivityHandler.js', [['.nonstrict()', '.passthrough()', 2]]],
  ['botbuilder', 'setSpeakMiddleware.js', [['.nonstrict()', '.passthrough()', 1]]],
  ['botbuilder', 'cloudAdapter.js', [['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 2]]],
  ['botbuilder-core', 'configurationBotFrameworkAuthentication.js', [
    ['TypedOptions.nonstrict()', 'TypedOptions.passthrough()', 1], ['err.errors', 'err.issues', 1],
  ]],
  ['botbuilder-core', 'configurationServiceClientCredentialFactory.js', [['TypedConfig.nonstrict()', 'TypedConfig.passthrough()', 1]]],
  ['botbuilder-core', 'storage.js', [['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 1]]],
  ['botframework-connector', 'auth/botFrameworkClientImpl.js', [
    ['z.record(z.string())', 'z.record(z.string(), z.string())', 1],
    ['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 1],
  ]],
  ['botframework-connector', 'auth/userTokenClientImpl.js', [['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 1]]],
  ['botframework-connector', 'auth/userTokenClient.js', [['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 1]]],
  ['botframework-schema', 'index.js', [
    ['z.record(z.unknown())', 'z.record(z.string(), z.unknown())', 1],
    ['z.record(entity)', 'z.record(z.string(), entity)', 1],
  ]],
];

const checked = new Set();
const updates = [];
for (const [packageName, relativePath, edits] of files) {
  const path = new URL(`../node_modules/${packageName}/lib/${relativePath}`, import.meta.url);
  if (!checked.has(packageName)) {
    const manifestUrl = new URL(`../node_modules/${packageName}/package.json`, import.meta.url);
    const manifest = JSON.parse(await readFile(manifestUrl, 'utf8'));
    const sdkRequire = createRequire(path);
    if (manifest.name !== packageName || manifest.version !== '4.23.3' || sdkRequire('zod/package.json').version !== '4.6.6') {
      throw new Error(`Unreviewed BotBuilder/Zod combination for ${packageName}`);
    }
    checked.add(packageName);
  }
  let contents = await readFile(path, 'utf8');
  const original = contents;
  for (const [before, after, expected] of edits) {
    const occurrences = contents.split(before).length - 1;
    const patchedOccurrences = contents.split(after).length - 1;
    if (occurrences === 0 && patchedOccurrences === expected) continue;
    if (occurrences !== expected || patchedOccurrences !== 0) {
      throw new Error(`Unexpected compatibility patch context in ${packageName}/${relativePath}: ${before}`);
    }
    contents = contents.replaceAll(before, after);
  }
  if (contents !== original) updates.push([path, contents]);
}
for (const [path, contents] of updates) await writeFile(path, contents);
