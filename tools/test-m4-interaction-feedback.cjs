'use strict';
const assert = require('node:assert/strict'), fs = require('node:fs'), vm = require('node:vm');
const ts = require('typescript');
function evaluate(source, context) {
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText, context);
  return context.exports;
}
const point = (id, bookId, location, label, createdAt) => ({ bookmarkId: id, bookId, engine: 'web',
  anchorVersion: 1, resourceHref: 'owned.xhtml', cfi: location.cfi, label, createdAt });
const book = { bookId: 'owned', sourceState: 'available' }, location = { cfi: 'owned-location' };
let ids = 0;
const application = evaluate(fs.readFileSync('entry/src/main/ets/application/BookmarkApplication.ets', 'utf8'), {
  exports: {}, require: name => name.includes('BookmarkPointPolicy') ? { bookmarkPointFromLocation: point } :
    name.includes('ManagedBookStore') ? { createSecureUuid: () => 'point-' + (++ids) } :
    { EncryptedBookmarkStore: class {} }
}).BookmarkApplication;
const reader = fs.readFileSync('entry/src/main/ets/pages/ReaderPage.ets', 'utf8');
const Subject = evaluate('exports.Subject=class Subject {' + reader.slice(reader.indexOf('  private currentBookmark('),
  reader.indexOf('  private jumpBookmark(')) + '};', { exports: {}, bookmarkPointFromLocation: point }).Subject;
(async () => {
  const stored = [], excerpts = new Map(); let writes = 0, readsAfterWrite = 0;
  const repository = { bookmarkAuthority: async () => 'source', getBook: async () => book, listOperations: async () => [],
    listBookmarks: async () => { if (writes) { readsAfterWrite++; throw Error('owned postcommit read failure'); } return [...stored]; },
    insertBookmark: async value => { stored.push({ ...value }); writes++; },
    deleteBookmark: async (_, id) => { stored.splice(stored.findIndex(v => v.bookmarkId === id), 1); } };
  const marks = { listPageExcerpts: async () => [...excerpts].map(([bookmarkId, excerpt]) => ({ bookmarkId, excerpt })),
    savePageExcerpt: async (_, id, excerpt) => excerpts.set(id, excerpt), removePageExcerpt: async (_, id) => excerpts.delete(id) };
  const service = new application(repository, {}, marks);
  const committed = await service.toggle(book, location, 'chapter', 'owned excerpt');
  assert.equal(committed.added, true); assert.equal(stored.length, 1);
  assert.equal(committed.points[0].label, 'chapter · owned excerpt'); assert.equal(stored[0].label, 'chapter');
  assert.equal(readsAfterWrite, 0, 'no failing display reread after confirmed writes');
  writes = 0;
  const removed = await service.toggle(book, location, 'chapter');
  assert.equal(removed.added, false); assert.equal(stored.length, 0);
  const toastMessages = [], closed = []; let toastId = 0, calls = 0, release;
  const subject = new Subject();
  Object.assign(subject, { currentBook: book, location, currentSessionId: 1, bookmarkReady: true, bookmarkBusy: false,
    bookmarkPoints: [], bookmarkToastRequest: 0, currentPageExcerpt: '', noteKeyboardDisposed: false,
    chapterTitle: () => 'chapter', shellColor: () => 'paired',
    getUIContext: () => ({ getPromptAction: () => ({ closeToast: id => closed.push(id),
      openToast: async options => { toastMessages.push(options.message); return ++toastId; } }) }),
    bookmarks: { toggle: async () => { calls++; await new Promise(resolve => { release = resolve; });
      return { added: true, points: [point('saved', 'owned', location, 'chapter', 1)] }; } } });
  const pending = subject.toggleBookmark(); await subject.toggleBookmark(); assert.equal(calls, 1);
  assert.equal(toastMessages.length, 0, 'click/busy never reports uncommitted success');
  release(); await pending; assert.equal(subject.bookmarkPoints.length, 1);
  assert.equal(toastMessages.at(-1), '书签已添加');
  subject.bookmarks.toggle = async () => { throw Error('owned prewrite failure'); };
  await subject.toggleBookmark(); assert.equal(subject.bookmarkPoints.length, 1);
  assert.equal(toastMessages.at(-1), '移除书签失败，请重试'); assert.ok(closed.length > 0);
  subject.bookmarks.remove = async () => { throw Error('owned prewrite failure'); };
  await subject.removeBookmark(subject.bookmarkPoints[0]); assert.equal(subject.bookmarkPoints.length, 1);
  subject.bookmarks.remove = async () => [];
  await subject.removeBookmark(subject.bookmarkPoints[0]); assert.equal(subject.bookmarkPoints.length, 0);
  assert.equal(toastMessages.at(-1), '书签已移除');
  subject.bookmarks.toggle = async () => { await new Promise(resolve => { release = resolve; }); return committed; };
  const stale = subject.toggleBookmark(), before = toastMessages.length; subject.currentSessionId++;
  release(); await stale; assert.equal(toastMessages.length, before, 'replaced session receives no feedback');
  console.log('D4-3B feedback PASS: committed snapshot, no postcommit read ambiguity, busy fencing, failed state retention, native toast replacement and stale-session fencing. No device claim.');
})().catch(error => { console.error(error); process.exitCode = 1; });
