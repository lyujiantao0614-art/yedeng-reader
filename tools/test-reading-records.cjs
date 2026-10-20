'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
function load(file) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }
  }).outputText, { exports, require: () => ({}), Promise, Map, Number, Math, Date, String, Error });
  return exports;
}
async function main() {
  const { ReadingRecordsApplication } = load('entry/src/main/ets/application/ReadingRecordsApplication.ets');
  let noteReads = 0, bookmarkReads = 0, detailReads = 0, fail = false, authority = 'source';
  const notes = {
    notePage: async cursor => {
      noteReads++; if (fail) throw Error('Owned failure');
      return cursor ? { items: [{ noteId: 'last', bookId: 'missing', quote: 'Original', excerpt: 'Last', updatedAt: 1 }] } :
        { items: [{ noteId: 'first', bookId: 'a', quote: 'Original', excerpt: 'First', updatedAt: 2 }], next: { time: 2, id: 'first' } };
    },
    noteDetail: async (bookId, noteId) => { detailReads++; return { bookId, noteId, body: 'Full body' }; }
  };
  const bookmarks = { page: async () => { bookmarkReads++; return { items: [], authority }; } };
  const app = new ReadingRecordsApplication(bookmarks, notes);
  app.begin([{ bookId: 'a', title: 'Book A' }]);
  assert.equal(noteReads + bookmarkReads, 0, 'Entering Mine must not query records');
  const first = await app.load('notes');
  assert.equal(first.rows[0].book.title, 'Book A'); assert.equal(first.hasNext, true);
  await app.load('notes'); assert.equal(noteReads, 1);
  await app.load('bookmarks'); await app.load('notes'); await app.load('bookmarks');
  assert.equal(noteReads, 1); assert.equal(bookmarkReads, 1); assert.equal(detailReads, 0);
  fail = true; await assert.rejects(app.load('notes', 'next'));
  assert.equal((await app.load('notes')).rows[0].id, 'first', 'A failed next page retains the current page');
  fail = false; const last = await app.load('notes', 'next');
  assert.equal(last.rows[0].book, undefined, 'Unassociated records stay visible');
  assert.equal(last.hasPrevious, true); assert.equal(last.page, 2);
  assert.equal((await app.load('notes', 'previous')).rows[0].id, 'first');
  assert.equal((await app.noteDetail(first.rows[0])).body, 'Full body'); assert.equal(detailReads, 1);
  app.begin([]); await app.load('bookmarks'); authority = 'target';
  // An explicit refresh accepts a newly committed authority; cached tab switching does not reread it.
  await app.load('bookmarks', 'refresh');
  assert.equal(bookmarkReads, 3);
  // Reader return rereads the current keyset window, not the first page, and
  // cannot promote an older pending read over a newer visit/return.
  let points = ['a', 'b', 'c', 'd'].map((id, i) => ({ bookmarkId: id, bookId: 'a', label: id, createdAt: 4 - i }));
  let rejectRead = false, heldRead;
  const seen = [];
  const mutable = { page: async cursor => {
    seen.push(cursor?.id ?? 'TOP');
    if (rejectRead) throw Error('Owned read failure');
    if (heldRead) return heldRead;
    const start = cursor ? points.findIndex(p => p.bookmarkId === cursor.id) + 1 : 0;
    const items = points.slice(start, start + 2);
    return { items, authority: 'source', next: start + 2 < points.length ? { id: items.at(-1).bookmarkId, time: items.at(-1).createdAt } : undefined };
  } };
  const resumed = new ReadingRecordsApplication(mutable, notes); resumed.begin([{ bookId: 'a' }]);
  await resumed.load('bookmarks'); const second = await resumed.load('bookmarks', 'next');
  assert.equal(second.page, 2); assert.equal(second.rows[0].id, 'c');
  points = points.filter(p => p.bookmarkId !== 'c');
  resumed.resume(); const removed = await resumed.load('bookmarks');
  assert.equal(removed.page, 2); assert.equal(removed.rows[0].id, 'd'); assert.equal(seen.at(-1), 'b');
  points.unshift({ bookmarkId: 'new', bookId: 'a', label: 'new', createdAt: 5 });
  resumed.resume(); assert.equal((await resumed.load('bookmarks')).page, 2);
  assert.equal((await resumed.load('bookmarks', 'previous')).rows[0].id, 'new');
  rejectRead = true; resumed.resume(); await assert.rejects(resumed.load('bookmarks'));
  rejectRead = false; assert.equal((await resumed.load('bookmarks')).rows[0].id, 'new');
  let release;
  heldRead = new Promise(resolve => { release = resolve; });
  resumed.resume(); const older = resumed.load('bookmarks');
  heldRead = undefined; resumed.resume(); await resumed.load('bookmarks');
  release({ items: [], authority: 'source' }); await older;
  assert.equal((await resumed.load('bookmarks')).rows[0].id, 'new', 'late read cannot clear newer returned data');
  heldRead = new Promise(resolve => { release = resolve; });
  resumed.resume(); const priorVisit = resumed.load('bookmarks');
  heldRead = undefined; resumed.begin([{ bookId: 'a' }]); await resumed.load('bookmarks');
  release({ items: [], authority: 'source' }); await priorVisit;
  assert.equal((await resumed.load('bookmarks')).rows[0].id, 'new', 'previous visit cannot replace current cache');
  const store = fs.readFileSync('entry/src/main/ets/repositories/EncryptedBookmarkStore.ets', 'utf8');
  const notePage = store.slice(store.indexOf('  async notePage('), store.indexOf('  async noteDetail('));
  assert.match(notePage, /FROM note_entries/); assert.match(notePage, /substr\(body,1,180\)/);
  assert.match(notePage, /ORDER BY updated_at DESC,note_id DESC LIMIT/);
  assert.doesNotMatch(notePage, /JOIN|listTextMarks|range_records/);
  console.log('Reading records cache, page navigation, failure retention, orphan visibility and on-demand detail passed.');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
