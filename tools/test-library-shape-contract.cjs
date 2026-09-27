'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

const library = read('entry/src/main/ets/pages/LibraryPage.ets');
const productStatePanel = read('entry/src/main/ets/components/ProductStatePanel.ets');

for (const id of [
  'library-import', 'library-view-grid', 'library-view-list', 'library-sort',
  'library-book-actions', 'library-book-details-close', 'library-delete-cancel',
  'library-delete-confirm', 'missing-source-recovery-grid', 'missing-source-recovery-list',
  'library-cleanup-orphans'
]) {
  assert.match(library, new RegExp(`\\.id\\('${id}'\\)[\\s\\S]{0,500}?` +
    `\\.borderRadius\\(\\$r\\('app\\.float\\.product_radius_control'\\)\\)`),
  `Library control ${id} does not use the shared control radius`);
}

assert.match(library, /private gridCover[\s\S]*?product_radius_cover[\s\S]*?\.clip\(true\)/,
  'Grid covers do not use the square cover shape');
assert.match(library, /private compactCover[\s\S]*?product_radius_cover/,
  'List covers do not use the square cover shape');
assert.match(productStatePanel,
  /Button\(this\.actionLabel\)[\s\S]*?\.borderRadius\(\$r\('app\.float\.product_radius_control'\)\)/,
  'Library state actions do not use the shared control radius');

console.log('Library control and cover shape contract passed.');
