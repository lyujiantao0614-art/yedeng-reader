'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('typescript');
const read = file => fs.readFileSync(file, 'utf8');
const policy = read('entry/src/main/ets/reader/ReaderPaginationPolicy.ets');
function select(mode, source = policy) {
  const context = { exports: {}, require: name => {
    assert.equal(name, 'BuildProfile'); return { BUILD_MODE_NAME: mode };
  } };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
  return context.exports.useClipPagination;
}
const debug = select('debug');
assert.equal(debug(), true, 'normal Development entry defaults to B without an experiment');
assert.equal(debug(false), false, 'comparison host can explicitly use legacy');
assert.equal(debug(true), true);
for (const mode of ['release', 'benchmark', 'unknown']) {
  for (const override of [undefined, false, true]) assert.equal(select(mode)(override), true, mode);
}
const rollback = policy.replace('DEBUG_LEGACY_PAGINATION: boolean = false', 'DEBUG_LEGACY_PAGINATION: boolean = true');
assert.notEqual(rollback, policy);
assert.equal(select('debug', rollback)(), false, 'documented source rollback selects legacy');
for (const mode of ['release', 'benchmark']) {
  assert.equal(select(mode, rollback)(false), true, 'development fallback cannot change ' + mode);
}
const view = read('entry/src/main/ets/reader/ReaderFourSurfaceView.ets');
assert.equal((view.match(/this\.clipPagination\s*=/g) ?? []).length, 1, 'one frozen policy for all surfaces, reopen and background recovery');
assert.match(view, /aboutToAppear\(\): void \{\s*this\.clipPagination = useClipPagination\(this\.debugClipPaginationOverride\)/);
assert.match(view, /JSON\.stringify\(this\.clipPagination \? 'clip' : 'scroll'\)/);
const page = read('entry/src/main/ets/pages/ReaderPage.ets');
assert.match(page, /debugClipPaginationOverride\?: boolean;/);
assert.match(page, /debugClipPaginationOverride: this\.debugClipPaginationOverride/);
assert.doesNotMatch(view + page + policy, /experimentalClipPagination/);
assert.doesNotMatch(policy, /READER_DIAGNOSTICS_ENABLED|READER_BENCHMARK_ENABLED/);
const index = read('entry/src/main/ets/pages/Index.ets');
assert.equal((index.match(/ReaderPage\(\{/g) ?? []).length, 1, 'ordinary entries share one reader');
assert.doesNotMatch(index, /debugClipPaginationOverride|experimentalClipPagination/);
// Existing bookshelf, Mine, library bookmark and aggregate bookmark callbacks.
assert.match(index, /onOpen: \(book: Book\): void => \{ this\.message = ''; this\.openBook\(book\)/);
assert.match(index, /onOpen: \(book: Book\): void => \{ this\.openBook\(book\)/);
assert.match(index, /onOpenBookmark:[\s\S]*?this\.openBook\(book, point\)/);
assert.match(index, /this\.openBook\(book, row\.point\)/);
assert.match(index, /initialProgress: progress,[\s\S]*?initialBookmark: initialBookmark/);
console.log('Reader entry policy PASS: Development/Release/benchmark default B; legacy fallback is debug-only; shared entry and frozen four-surface selection. No device acceptance claim.');
