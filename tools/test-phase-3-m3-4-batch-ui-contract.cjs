'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const page = read('entry/src/main/ets/pages/BatchImportPage.ets');
const index = read('entry/src/main/ets/pages/Index.ets');

for (const id of ['batch-confirm', 'batch-cancel-running', 'batch-done']) {
  const start = page.indexOf(`.id('${id}')`);
  assert.ok(start >= 0, `${id} is missing`);
  const control = page.slice(start, start + 600);
  assert.match(control, /\.width\('100%'\)/, `${id} must retain large-text width`);
  assert.match(control, /\.focusable\(true\)/, `${id} must be explicitly focusable`);
  assert.match(control, /\.defaultFocus\(true\)/, `${id} must own phase-entry focus`);
  assert.match(control, new RegExp(`\\.onAppear\\(\\(\\): void => \\{ this\\.requestPhaseFocus\\('${id}'\\); \\}\\)`),
    `${id} must request focus when its phase control enters the tree`);
}

assert.match(page, /this\.getUIContext\(\)\.getFocusController\(\)\.requestFocus\(id\)/,
  'Phase-entry focus must use the UIContext-bound FocusController');

assert.match(index, /new accessibility\.EventInfo\('announceForAccessibility', APP_BUNDLE_NAME, 'common'\)/,
  'Batch progress must use the public native accessibility announcement event');
assert.match(index, /event\.textAnnouncedForAccessibility = announcement/,
  'Batch progress announcement text is not attached to the event');
assert.match(index, /snapshot\.phase === 'running' && snapshot\.activeIndex >= 0/,
  'Active-item progress is not announced');
assert.match(index, /snapshot\.phase !== 'results'/,
  'Final batch outcomes are not announced');
assert.doesNotMatch(index, /textAnnouncedForAccessibility\s*=\s*.*(?:uri|label|title|bookId)/,
  'Accessibility announcements must not expose transient paths or stable book identity');

console.log('Phase 3 Milestone 3.4 batch UI contract passed.');
