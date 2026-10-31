'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const reader = fs.readFileSync('entry/src/main/ets/pages/ReaderPage.ets', 'utf8');
const settings = fs.readFileSync('entry/src/main/ets/pages/SettingsPage.ets', 'utf8');
function method(source, first, next) {
  const start = source.indexOf(first), end = source.indexOf(next, start);
  assert.ok(start >= 0 && end > start); return source.slice(start, end);
}
function harness(source, inject = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021
  } }).outputText, { exports, ...inject }); return exports.H;
}
const Reader = harness('export class H {' +
  method(reader, '  private async reloadTextMarks(', '  private async saveExistingNote(') +
  method(reader, '  private async refreshCommittedNote(', '  private async retainNoteStatus(') + '}',
  { copyEditingNote: note => structuredClone(note) });
const Settings = harness('export class H {' +
  method(settings, '  private handleSystemBack(', '  private restoreFocus(') + '}');
function makeReader(entry, stored, options = {}) {
  const h = new Reader(), web = new Set(entry.map(x => x.markId)), removed = [];
  Object.assign(h, { savedTextMarks: structuredClone(entry), currentSessionId: 11,
    currentBook: { bookId: 'owned-book' }, textMarkRefreshRevision: 0, bookmarkBusy: false,
    noteCommitKind: 'none', noteEditorGeneration: 3, selectedMarkId: 'original',
    currentSurface: 'mark-detail', editingNoteSnapshot: { noteId: 'a' },
    markDetailReturnSurface: 'none' });
  h.controller = { removeTextMark(id) { removed.push(id); web.delete(id); }, focusContent() {} };
  h.textMarks = { async removeNote() {
    if (options.rejectDelete) throw Error('owned write failure');
    if (options.changeSession) h.currentSessionId++;
  }, async list() { if (options.rejectRead) throw Error('owned read failure'); return structuredClone(stored); } };
  h.selectedNoteEntries = () => entry.flatMap(x => x.notes ?? []);
  h.selectedTextMark = () => h.savedTextMarks.find(x => x.markId === h.selectedMarkId);
  h.closeMarkDetail = h.finishNoteEditor = () => { h.currentSurface = 'none'; };
  h.traceNoteOverlay = () => {};
  h.previewVisibleTextMarks = () => h.savedTextMarks.forEach(x => web.add(x.markId));
  return { h, web, removed };
}
const note = id => ({ noteId: id });
const mark = (id, notes, highlights = []) => ({ markId: id, kind: 'note', notes, highlightAnchors: highlights });
let passed = 0, failed = 0;
async function check(name, action) {
  try { await action(); passed++; console.log('PASS ' + name); }
  catch (e) { failed++; console.error('FAIL ' + name + ': ' + e.message); }
}
(async () => {
  for (const path of ['detail', 'editor']) {
    const remove = async h => {
      if (path === 'editor') { h.currentSurface = 'note-editor'; await h.deleteEditingNote(); }
      else await h.deleteNoteEntry(note('a'));
    };
    await check(path + ': final note retires Web id without reopening', async () => {
      const { h, web, removed } = makeReader([mark('original', [note('a')])], []);
      await remove(h); assert.equal(web.size, 0); assert.ok(removed.includes('original'));
    });
    await check(path + ': committed delete plus read failure still retires empty Web id', async () => {
      const { h, web } = makeReader([mark('original', [note('a')])], [], { rejectRead: true });
      await remove(h); assert.equal(web.size, 0); assert.ok(h.noteFeedback.includes('已删除'));
    });
    await check(path + ': remaining note/highlight survive regrouping', async () => {
      const remaining = mark('survivor', [note('b')], [{ owned: true }]);
      const { h, web } = makeReader([mark('original', [note('a'), note('b')], [{ owned: true }])], [remaining]);
      await remove(h); assert.equal(web.has('original'), false); assert.equal(web.has('survivor'), true);
      assert.equal(h.savedTextMarks[0].notes[0].noteId, 'b'); assert.equal(h.savedTextMarks[0].highlightAnchors.length, 1);
    });
    await check(path + ': unrelated legacy highlight remains visible on failed refresh', async () => {
      const legacy = { markId: 'unrelated', kind: 'highlight' };
      const { h, web } = makeReader([mark('original', [note('a')]), legacy], [], { rejectRead: true });
      await remove(h); assert.equal(web.has('original'), false); assert.equal(web.has('unrelated'), true);
      assert.equal(h.savedTextMarks.length, 1); assert.equal(h.savedTextMarks[0].markId, 'unrelated');
    });
    for (const option of ['rejectDelete', 'changeSession']) await check(path + ': ' + option + ' cannot mutate current Web/UI', async () => {
      const { h, web, removed } = makeReader([mark('original', [note('a')])], [], { [option]: true });
      await remove(h); assert.equal(web.has('original'), true); assert.equal(removed.length, 0);
    });
  }
  for (const wide of [false, true]) for (const route of ['appearance', 'reading', 'dictionary', 'privacy', 'about']) {
    await check((wide ? 'wide' : 'compact') + ': top-level ' + route + ' back', async () => {
      const h = new Settings(); Object.assign(h, { route, wide: () => wide, legalRequest: 0, focus() {},
        changeRoute(next) { h.route = next; }, onExit() { h.exited = true; }, pageController: { entrySource: () => 'library' } });
      h.backOrExit(); assert.equal(!!h.exited, wide); assert.equal(h.route, wide ? route : 'root');
    });
  }
  for (const wide of [false, true]) await check('legal and reader-entry parents remain width-aware: ' + wide, async () => {
    const h = new Settings(); Object.assign(h, { wide: () => wide, legalRequest: 0,
      changeRoute(next) { h.route = next; }, focus() {}, entrySection: 'reading' });
    for (const [route, parent] of [['privacy-policy', 'privacy'], ['project-license', 'about'], ['third-party-notices', 'about']]) {
      h.route = route; assert.equal(h.handleSystemBack(), true); assert.equal(h.route, parent);
    }
    h.route = 'reading'; assert.equal(h.handleSystemBack(), false);
  });
  console.log(`Tablet directed contracts: ${passed} passed, ${failed} failed; source/controlled boundary, not device evidence.`);
  if (failed) process.exitCode = 1;
})().catch(e => { console.error(e); process.exitCode = 1; });
