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

// M4 has one automatic Grid; its current application action still owns selection/repair/Reader routing.
const activateBook = library.match(/private activateBook[\s\S]*?private rememberBookSource/)?.[0] ?? '';
assert.match(activateBook, /this\.selectionMode[\s\S]*this\.toggleSelection\(entry\.book\.bookId\)/);
assert.match(activateBook, /sourceState === 'missing'[\s\S]*this\.onRepair\(entry\.book\).*this\.onOpen\(entry\.book\)/);
assert.match(library, /private activateBookId\(bookId: string\)[\s\S]*?this\.activateBook\(current\)/);
assert.match(library, /\.id\('library-source-grid-' \+ entry\.book\.bookId\)[\s\S]{0,260}\.onClick\(\(\): void => this\.activateBookId\(entry\.book\.bookId\)\)/);
assert.match(library, /onActivate: \(id: string\): void => this\.activateBookId\(id\)/);
assert.match(library, /library-details-repair[\s\S]{0,400}this\.onRepair\(entry\.book\)/);
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
