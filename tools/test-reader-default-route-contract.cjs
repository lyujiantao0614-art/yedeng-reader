'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const index = read('entry/src/main/ets/pages/Index.ets');
const library = read('entry/src/main/ets/pages/LibraryPage.ets');
const page = read('entry/src/main/ets/pages/ReaderPage.ets');
const surface = read('entry/src/main/ets/reader/ReaderFourSurfaceView.ets');
const shell = read('entry/src/main/resources/rawfile/web-reader-surfaces/index.html');

const selectionAwareOpen = /onClick\(\(\) => this\.selectionMode \? this\.toggleSelection\(entry\.book\.bookId\) :\s*entry\.book\.sourceState === 'missing' \? this\.onRepair\(entry\.book\) : this\.onOpen\(entry\.book\)\)/g;
assert.ok([...library.matchAll(selectionAwareOpen)].length >= 2,
  'Grid and list taps must open the four-surface Reader outside selection mode');
assert.match(index, /onOpen: \(book: Book\): void => \{ this\.openBook\(book\)/);
assert.match(index, /this\.readerPageController\.openSession\(\{/);
assert.match(page, /import \{ ReaderFourSurfaceView \} from '\.\.\/reader\/ReaderFourSurfaceView';/);
assert.match(page, /ReaderFourSurfaceView\(\{/);
assert.match(surface, /\$rawfile\('web-reader-surfaces\/index\.html'\)/);
assert.match(shell, /\.\.\/web-reader\/vendor\/epubjs-0\.3\.93\/epub\.min\.js/);
assert.doesNotMatch(index + library + page, /onTryNewReader|useFourSurfaces|library_try_new_reader|ReaderEngineHost/);
for (const relative of [
  'entry/src/main/ets/reader/WebReaderEngineView.ets',
  'entry/src/main/ets/reader/ReaderEngineHost.ets',
  'entry/src/main/resources/rawfile/web-reader/index.html',
  'entry/src/main/resources/rawfile/web-reader/bootstrap.js'
]) assert.equal(fs.existsSync(path.join(root, relative)), false, `Legacy runtime remains: ${relative}`);

console.log('Default Reader route uses the four-surface engine; legacy runtime is absent.');
