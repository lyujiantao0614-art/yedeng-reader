'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');
const reader = read('entry/src/main/ets/pages/ReaderPage.ets');
const index = read('entry/src/main/ets/pages/Index.ets');

assert.doesNotMatch(reader, /import\s*\{\s*promptAction\s*\}\s*from\s*'@kit\.ArkUI'/,
  'ReaderPage imports the deprecated global promptAction API');
assert.doesNotMatch(reader, /\bpromptAction\.showToast\s*\(/,
  'ReaderPage calls the deprecated global promptAction.showToast API');
const readerToastCalls = (reader.match(/\.showToast\s*\(/g) ?? []).length;
const currentUIContextToastCalls =
  (reader.match(/this\.getUIContext\(\)\.getPromptAction\(\)\.showToast\s*\(/g) ?? []).length;
assert.ok(readerToastCalls > 0, 'ReaderPage no longer exercises the toast routing contract');
assert.equal(currentUIContextToastCalls, readerToastCalls,
  'ReaderPage toast calls are not routed through its current UIContext');

assert.doesNotMatch(index, /\bAlertDialog\.show\s*\(/,
  'Index calls the deprecated global AlertDialog.show API');
const indexAlertCalls = (index.match(/\.showAlertDialog\s*\(/g) ?? []).length;
const currentUIContextAlertCalls =
  (index.match(/this\.getUIContext\(\)\.showAlertDialog\s*\(/g) ?? []).length;
assert.ok(indexAlertCalls > 0, 'Index no longer exercises the alert routing contract');
assert.equal(currentUIContextAlertCalls, indexAlertCalls,
  'Index alerts are not routed through the current UIContext');

console.log('Current ArkUI API contract passed.');
