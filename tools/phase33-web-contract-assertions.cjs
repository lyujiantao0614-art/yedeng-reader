'use strict';

const assert = require('node:assert/strict');

const layoutContract = require('../entry/src/main/resources/rawfile/web-reader/reader-layout-contract.js');
const navigationContract = require('../entry/src/main/resources/rawfile/web-reader/reader-navigation-contract.js');

assert.equal(layoutContract.normalizeColumnMode('single'), 'single');
assert.equal(layoutContract.normalizeColumnMode('auto'), 'auto');
assert.equal(layoutContract.normalizeColumnMode('unsupported'), 'auto');
assert.equal(layoutContract.minimumSpreadWidth({ fontScale: 1, pageMarginVp: 20 }), 710);
assert.equal(layoutContract.minimumSpreadWidth({ fontScale: 1, pageMarginVp: 8 }), 662);
assert.equal(layoutContract.minimumSpreadWidth({ fontScale: 1.3, pageMarginVp: 20 }), 860);
assert.equal(layoutContract.minimumSpreadWidth({ fontScale: 1.6, pageMarginVp: 40 }), 1120);
assert.ok(layoutContract.minimumSpreadWidth({ fontScale: 1, pageMarginVp: 20 }) <= 711.68,
  'The natural unfolded Reader must be eligible for an automatic spread at default settings');
assert.ok(layoutContract.minimumSpreadWidth({ fontScale: 1, pageMarginVp: 20 }) > 600,
  'Compact folded windows must remain below the automatic spread threshold');
assert.ok(711.68 / 2 - 40 >= 315,
  'The natural unfolded Reader must retain the calibrated minimum column width');

const serializedLocator = layoutContract.readingLocator({
  start: {
    cfi: 'epubcfi(/6/2!/4/2/1:0)',
    href: 'chapter-2.xhtml',
    displayed: { page: 3, total: 5 }
  }
});
assert.deepEqual(layoutContract.parseReadingLocator(serializedLocator), {
  cfi: 'epubcfi(/6/2!/4/2/1:0)', href: 'chapter-2.xhtml', page: 3
});
assert.deepEqual(layoutContract.restoreTargetOrder(serializedLocator), [
  { kind: 'cfi', value: 'epubcfi(/6/2!/4/2/1:0)', page: 1 },
  { kind: 'href-page', value: 'chapter-2.xhtml', page: 3 }
]);
assert.deepEqual(layoutContract.restoreTargetOrder(''), [
  { kind: 'start', value: '', page: 1 }
]);
const maximumCfi = 'x'.repeat(layoutContract.MAX_LOCATOR_FIELD_LENGTH);
const maximumHref = 'h'.repeat(2047);
const maximumEnvelope = layoutContract.readingLocator({
  start: { cfi: maximumCfi, href: maximumHref, displayed: { page: 1, total: 1 } }
});
assert.ok(maximumEnvelope.length <= layoutContract.MAX_LOCATOR_ENVELOPE_LENGTH);
assert.deepEqual(layoutContract.parseReadingLocator(maximumEnvelope), {
  cfi: maximumCfi, href: maximumHref, page: 1
});
assert.equal(layoutContract.parseReadingLocator('x'.repeat(
  layoutContract.MAX_LOCATOR_FIELD_LENGTH + 1)).cfi, '');
assert.equal(layoutContract.parseReadingLocator(JSON.stringify({
  version: 1, cfi: 'x'.repeat(layoutContract.MAX_LOCATOR_FIELD_LENGTH + 1), href: '', page: 1
})).cfi, '');

assert.deepEqual(navigationContract.classifyLink('#same-target', 'OEBPS/chapter-1.xhtml', '', ''), {
  type: 'internal', href: 'OEBPS/chapter-1.xhtml#same-target', kind: 'internal'
});
assert.deepEqual(navigationContract.classifyLink(
  'chapter-2.xhtml#cross-target', 'OEBPS/chapter-1.xhtml', '', ''), {
  type: 'internal', href: 'OEBPS/chapter-2.xhtml#cross-target', kind: 'internal'
});
assert.deepEqual(navigationContract.classifyLink(
  'notes.xhtml#note-1', 'OEBPS/chapter-1.xhtml', 'noteref', 'doc-noteref'), {
  type: 'internal', href: 'OEBPS/notes.xhtml#note-1', kind: 'footnote'
});
assert.deepEqual(navigationContract.classifyLink(
  'https://example.invalid/phase33', 'OEBPS/chapter-1.xhtml', '', ''), {
  type: 'external', href: 'https://example.invalid/phase33'
});
for (const unsafe of [
  'javascript:alert(1)',
  'file:///private/book.epub',
  '/absolute/path',
  '//external.invalid/path',
  '../../outside.xhtml',
  'chapter.xhtml%2foutside'
]) {
  assert.equal(navigationContract.classifyLink(
    unsafe, 'OEBPS/chapter-1.xhtml', '', '').type, 'invalid', `Unsafe link accepted: ${unsafe}`);
}

const returnStack = navigationContract.createReturnStack(16);
assert.equal(returnStack.pop(), undefined);
assert.equal(returnStack.push({ locator: '', kind: 'internal' }), false);
assert.equal(returnStack.push({ locator: maximumEnvelope, kind: 'internal' }), true);
assert.equal(returnStack.pop().locator, maximumEnvelope);
for (let index = 1; index <= 17; index += 1) {
  assert.equal(returnStack.push({ locator: `epubcfi(/6/${index * 2})`, kind: 'internal' }), true);
}
assert.equal(returnStack.size(), navigationContract.MAX_RETURN_DEPTH);
assert.equal(returnStack.pop().locator, 'epubcfi(/6/34)');
while (returnStack.canReturn()) returnStack.pop();
assert.equal(returnStack.size(), 0);

assert.equal(navigationContract.keyboardAction('ArrowLeft', false, false, false, false, false, false),
  'previous-page');
assert.equal(navigationContract.keyboardAction('PageDown', false, false, false, false, false, false),
  'next-page');
assert.equal(navigationContract.keyboardAction('Escape', false, false, false, false, false, false), 'back');
assert.equal(navigationContract.keyboardAction('Tab', false, false, false, false, false, false), 'none');
assert.equal(navigationContract.keyboardAction('Enter', false, false, false, false, false, false), 'none');
assert.equal(navigationContract.keyboardAction('ArrowRight', true, false, false, false, false, false), 'none');
assert.equal(navigationContract.keyboardAction('ArrowRight', false, true, false, false, false, false), 'none');
assert.equal(navigationContract.keyboardAction('ArrowRight', false, false, false, true, false, false), 'none');
assert.equal(navigationContract.readerClickAction(0.1, 0, false, false), 'previous-page');
assert.equal(navigationContract.readerClickAction(0.5, 0, false, false), 'toggle-controls');
assert.equal(navigationContract.readerClickAction(0.9, 0, false, false), 'next-page');
assert.equal(navigationContract.readerClickAction(0.9, 0, false, true), 'none');
assert.equal(navigationContract.suppressClickAfterTouch(1000, 1700), true);
assert.equal(navigationContract.suppressClickAfterTouch(1000, 1701), false);

const geometry = navigationContract.normalizeSelectionGeometry([
  { left: 10, top: 10, width: 20, height: 12 },
  { left: 10, top: 30, width: 30, height: 12 }
], { left: 10, top: 30, width: 30, height: 12 }, 100, 100);
assert.equal(geometry.fragments.length, 2);
assert.equal(geometry.anchor.top, 30);
assert.equal(navigationContract.normalizeSelectionGeometry([], undefined, 100, 100), undefined);

assert.equal(navigationContract.exactSelectionMatches('chapter', 7, ' chapter '), true);
assert.equal(navigationContract.exactSelectionMatches('chapter', 7, 'chaptex'), false);
assert.equal(navigationContract.exactSelectionMatches('chapter', 6, 'chapter'), false);
assert.equal(navigationContract.exactSelectionMatches('', 0, ''), false);
assert.equal(navigationContract.exactSelectionMatches('x'.repeat(4001), 4001, 'x'.repeat(4001)), false);
assert.equal(navigationContract.relocationSelectionAction('layout', true, true), 'preserve');
assert.equal(navigationContract.relocationSelectionAction('layout', true, false), 'clear');
assert.equal(navigationContract.relocationSelectionAction('layout', false, false), 'preserve');
assert.equal(navigationContract.relocationSelectionAction('navigation', true, true), 'clear');
assert.equal(navigationContract.relocationSelectionAction('unknown', true, true), 'clear');

const relocatedGeometry = navigationContract.normalizeSelectionGeometry(
  Array.from({ length: 65 }, (_, index) => ({ left: index, top: 10, width: 1, height: 12 })),
  { left: 64, top: 10, width: 1, height: 12 },
  200,
  300
);
assert.equal(relocatedGeometry.fragments.length, navigationContract.MAX_SELECTION_FRAGMENTS);
assert.equal(relocatedGeometry.fragments.at(-1).left, 64);
assert.equal(relocatedGeometry.anchor.left, 64);
assert.equal(relocatedGeometry.anchor.viewportWidth, 200);
assert.equal(relocatedGeometry.anchor.viewportHeight, 300);

module.exports = Object.freeze({ passed: true });
