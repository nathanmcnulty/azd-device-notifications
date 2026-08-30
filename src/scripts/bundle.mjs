import { build } from 'esbuild';
import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const sourceRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const repositoryRoot = path.resolve(sourceRoot, '..');
const packageRoot = path.join(repositoryRoot, 'function-package');
const outputPath = path.join(packageRoot, 'index.cjs');
const licenseOverrideRoot = path.join(sourceRoot, 'third-party-licenses');

const licenseOverrides = new Map([
  ['@nodable/entities@3.0.0', {
    file: '@nodable__entities-LICENSE.txt',
    source: 'https://github.com/nodable/val-parsers/blob/v3.0.0/LICENSE',
  }],
  ['tr46@0.0.3', {
    file: 'tr46-LICENSE.txt',
    source: 'https://github.com/jsdom/tr46/tree/0.0.3',
  }],
]);

const result = await build({
  entryPoints: [path.join(sourceRoot, 'index.ts')],
  bundle: true,
  platform: 'node',
  target: 'node22',
  format: 'cjs',
  outfile: outputPath,
  external: ['@azure/functions-core'],
  legalComments: 'external',
  metafile: true,
});

function packageDirectoryForInput(input) {
  const segments = input.replaceAll('\\', '/').split('/');
  const nodeModulesIndex = segments.lastIndexOf('node_modules');
  if (nodeModulesIndex < 0 || nodeModulesIndex + 1 >= segments.length) return null;
  const packageSegments = segments[nodeModulesIndex + 1].startsWith('@')
    ? segments.slice(nodeModulesIndex + 1, nodeModulesIndex + 3)
    : segments.slice(nodeModulesIndex + 1, nodeModulesIndex + 2);
  return path.join(sourceRoot, ...segments.slice(0, nodeModulesIndex + 1), ...packageSegments);
}

const bundledPackageDirectories = [...new Set(
  Object.keys(result.metafile.inputs)
    .map(packageDirectoryForInput)
    .filter(Boolean),
)].sort((left, right) => left.localeCompare(right));

const packages = [];
const missingLicensePackages = [];
for (const directory of bundledPackageDirectories) {
  const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
  const directoryEntries = await readdir(directory, { withFileTypes: true });
  const legalFiles = directoryEntries
    .filter((entry) => entry.isFile() && /^(licen[cs]e|copying|notice)(?:\.|$)/i.test(entry.name))
    .map((entry) => entry.name)
    .sort((left, right) => left.localeCompare(right));
  const readmeFile = directoryEntries.find((entry) => entry.isFile() && /^readme(?:\.|$)/i.test(entry.name));
  let readmeLicense;
  if (readmeFile) {
    const readme = (await readFile(path.join(directory, readmeFile.name), 'utf8')).replaceAll('\r\n', '\n');
    const match = readme.match(/(?:^|\n)(?:#{1,6}\s+License\s*|License\s*\n[-=]+)\n([\s\S]+)$/i);
    if (match) readmeLicense = { file: readmeFile.name, contents: match[1].trim() };
  }
  const packageKey = `${manifest.name}@${manifest.version}`;
  const licenseOverride = licenseOverrides.get(packageKey);
  if (legalFiles.length === 0 && !readmeLicense && !licenseOverride) {
    missingLicensePackages.push(packageKey);
  }
  packages.push({ directory, manifest, legalFiles, readmeLicense, licenseOverride });
}
if (missingLicensePackages.length > 0) {
  throw new Error(`Bundled dependencies have no license or notice file and no reviewed override:\n${missingLicensePackages.join('\n')}`);
}

const sections = [
  'THIRD-PARTY SOFTWARE NOTICES',
  '',
  'The original code in azd-device-notifications is released under the Unlicense.',
  'The bundled deployment artifact also contains the third-party packages listed below.',
  'Those packages remain subject to their respective license terms and are not relicensed under the Unlicense.',
  '',
];
for (const { directory, manifest, legalFiles, readmeLicense, licenseOverride } of packages) {
  sections.push('='.repeat(80));
  sections.push(`${manifest.name}@${manifest.version}`);
  sections.push(`Declared license: ${manifest.license ?? 'See included license files'}`);
  for (const legalFile of legalFiles) {
    const contents = (await readFile(path.join(directory, legalFile), 'utf8'))
      .replaceAll('\r\n', '\n')
      .trim();
    sections.push('');
    sections.push(`--- ${legalFile} ---`);
    sections.push(contents);
  }
  if (readmeLicense) {
    sections.push('');
    sections.push(`--- license section from ${readmeLicense.file} ---`);
    sections.push(readmeLicense.contents);
  }
  if (licenseOverride) {
    const contents = (await readFile(path.join(licenseOverrideRoot, licenseOverride.file), 'utf8'))
      .replaceAll('\r\n', '\n')
      .trim();
    sections.push('');
    sections.push(`--- reviewed license override (source: ${licenseOverride.source}) ---`);
    sections.push(contents);
  }
  sections.push('');
}

await writeFile(path.join(packageRoot, 'THIRD-PARTY-NOTICES.txt'), `${sections.join('\n')}\n`, 'utf8');
const unlicense = (await readFile(path.join(repositoryRoot, 'LICENSE'), 'utf8')).replaceAll('\r\n', '\n');
await writeFile(path.join(packageRoot, 'UNLICENSE.txt'), unlicense, 'utf8');
