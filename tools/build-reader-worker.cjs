'use strict';

// The rawfile origin cannot import scripts from a Blob Worker. Bundle only the
// pinned local EPUB dependencies and the production source owner into one Blob.
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const vendor = path.join(root, 'entry/src/main/resources/rawfile/web-reader/vendor');
const surface = path.join(root, 'entry/src/main/resources/rawfile/web-reader-surfaces');
const entry = fs.readFileSync(path.join(surface, 'source-worker.js'), 'utf8');
const imports = "importScripts('jszip.min.js','epub.min.js');";
if (!entry.includes(imports)) throw new Error('Source Worker import boundary changed');
const parts = [
  path.join(vendor, 'jszip-3.10.1/jszip.min.js'),
  path.join(vendor, 'epubjs-0.3.93/epub.min.js')
].map(file => fs.readFileSync(file, 'utf8'));
const source = 'self.window=self;\n' + parts.join('\n;\n') + '\n;\n' + entry.replace(imports, '');
const output = 'window.sourceWorkerCode=' + JSON.stringify(source) + ';\n';
const target = path.join(surface, 'source-worker-bundle.js');
if (process.argv.includes('--check')) {
  // Git Windows checkout may change source LF to CRLF. Compare the actual
  // embedded program, not JSON escape spelling or transport line endings.
  const packaged = fs.readFileSync(target, 'utf8').trim();
  const prefix = 'window.sourceWorkerCode=';
  if (!packaged.startsWith(prefix) || !packaged.endsWith(';')) throw new Error('Invalid Worker bundle envelope');
  const program = JSON.parse(packaged.slice(prefix.length, -1));
  if (typeof program !== 'string' || program.replace(/\r\n/g, '\n') !== source.replace(/\r\n/g, '\n')) {
    throw new Error('Production Worker bundle is stale');
  }
} else {
  fs.writeFileSync(target, output);
}
