'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync('entry/src/main/ets/reader/ReaderFourSurfaceView.ets', 'utf8');
const code = 'exports.Subject=class Subject {' + source.slice(source.indexOf('  private async openSource('), source.indexOf('  private parseLocator(')) + '};';
const context = { exports: {},
  ReaderSurfaceResources: class { archive = { open: async () => {} }; base = 'owned/'; },
  DerivedSectionTextCache: class {},
  createProductionImportPolicy: () => ({ zip: {}, resources: {} }),
  runSurfaceScript: async (_, script) => script.includes('sourceStats') ? JSON.stringify(JSON.stringify({
    chapterHrefs: ['zero','first','second','third'], chapterSizes: [1,1,1,1], chapterCfiBases: ['a','b','c','d']
  })) : script.includes('Source.toc') ? JSON.stringify('[]') : ''
};
vm.runInNewContext(ts.transpileModule(code, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
async function ready(clip, action) {
  const subject = new context.exports.Subject(), preloads = [];
  Object.assign(subject, { clipPagination: clip, alive: true, sourceShellLoaded: true, loadedShells: [true],
    generation: 1, navigationEpoch: 0, activeSession: 1, book: { epubRelativePath: 'owned.epub', bookId: 'owned' },
    getUIContext: () => ({ getHostContext: () => ({ filesDir: 'owned', cacheDir: 'owned' }) }),
    awaitSignal: () => ({ token: 1, done: Promise.resolve() }), sourceController: {}, controllers: [{}],
    publication: { bind() {} }, parseLocator: () => ({ href: 'second', cfi: '', page: 1 }),
    available: [true], units: [2], load: async () => {}, settleSurface() {}, seek: async () => {},
    commit: async () => {}, traceSelection() {}, prepareAround: direction => preloads.push(direction),
    callbacks: { onTableOfContents() {}, onReady: () => action(subject) } });
  await subject.openSource(); return preloads;
}
(async () => {
  for (const clip of [false, true]) {
    assert.deepEqual(await ready(clip, () => {}), [1], 'idle startup keeps normal neighbour preparation');
    assert.deepEqual(await ready(clip, subject => { subject.navigationEpoch++; subject.navigating = true; }), [],
      'initial bookmark owns its slot before the ready callback returns');
    assert.deepEqual(await ready(clip, subject => { subject.navigationEpoch++; subject.navigating = false; }), [],
      'a newer navigation epoch supersedes startup even if it already completed');
    assert.deepEqual(await ready(clip, subject => { subject.alive = false; subject.generation++; }), [],
      'closed/replaced sessions cannot schedule startup work');
  }
  console.log('Bookmark startup ownership PASS: actual openSource keeps idle preload; ready callback navigation/replacement fences obsolete startup in legacy and B. No native pixel claim.');
})().catch(error => { console.error(error); process.exitCode = 1; });
