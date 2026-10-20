'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { DatabaseSync } = require('node:sqlite');
const ts = require('typescript');
const root = path.resolve(__dirname, '..');
const candidate = root;
const cache = new Map();
let currentStore;
let token = 0;
class ControlledInputError extends Error {}
class ControlledInflateError extends Error {}
class ControlledInspectionError extends Error {}
class Predicates {
 constructor(table) { this.table=table; this.fields=[]; this.values=[]; }
 equalTo(field,value) { this.fields.push(field); this.values.push(value); return this; }
}
class SqlStore {
  constructor() { this.db = new DatabaseSync(':memory:'); this.beforeSql = undefined; }
  get version() { return this.db.prepare('PRAGMA user_version').get().user_version; }
  set version(value) { this.db.exec(`PRAGMA user_version=${value}`); }
  beginTransaction() { this.wroteInTransaction = false; this.transaction = true; this.db.exec('BEGIN'); }
  commit() { this.db.exec('COMMIT'); this.transaction = false; }
  rollBack() { this.db.exec('ROLLBACK'); this.transaction = false; }
  async executeSql(sql, values = []) {
    this.beforeSql?.(sql, values);
    if (this.transaction && /^(INSERT INTO books|UPDATE books)/.test(sql)) this.wroteInTransaction = true;
    this.db.prepare(sql).run(...values);
  }
  async querySql(sql, values = []) {
    if (this.transaction && this.wroteInTransaction) throw Error('Native committed snapshot cannot verify own writer');
    const statement = this.db.prepare(sql);
    statement.setReturnArrays(true);
    const rows = statement.all(...values);
    let index = -1;
    return {
      goToFirstRow() { index=0; return index < rows.length; },
      goToNextRow() { index++; return index < rows.length; },
      getString(column) { return String(rows[index][column]); },
      getLong(column) { return Number(rows[index][column]); },
      getDouble(column) { return Number(rows[index][column]); },
      isColumnNull(column) { return rows[index][column] === null; },
      close() {}
    };
  }
  async update(values, predicates) {
    const keys=Object.keys(values);
    const sql='UPDATE '+predicates.table+' SET '+keys.map(k=>k+'=?').join(',')+' WHERE '+predicates.fields.map(k=>k+'=?').join(' AND ');
    const parameters=[...keys.map(k=>values[k]),...predicates.values];
    this.beforeSql?.(sql,parameters);
    return Number(this.db.prepare(sql).run(...parameters).changes);
  }
  async insert(table, values) {
    const keys = Object.keys(values);
    return Number(this.db.prepare(`INSERT INTO ${table}(${keys.join(',')}) VALUES(${keys.map(() => '?').join(',')})`)
      .run(...keys.map((key) => values[key])).lastInsertRowid);
  }
  close() { this.db.close(); }
}
const special = {
  '@kit.AbilityKit': {},
  '@kit.ArkData': { relationalStore: { RdbPredicates: Predicates, SecurityLevel: { S1: 1 }, getRdbStore: async () => currentStore } },
  '@kit.BasicServicesKit': { zlib: {} },
  EpubInspectionWorkerClient: { inspectEpubInWorker() { throw new Error('Unentered bounded extraction boundary'); } },
  ImportStorageBudget: { ImportStorageBudget: class {} },
  EpubResourceInspector: { validateResourceLimits() {} },
  EpubInputPolicy: { EpubInputError: ControlledInputError },
  BoundedInflater: { BoundedInflateError: ControlledInflateError },
  BoundedZipExtractor: { FileZipSource: {}, extractBoundedZip() { throw new Error('Unentered ZIP boundary'); } },
  EpubZipIndex: { validateZipLimits() {} },
  FileUtils: { ensureDirectory: async () => {} },
  EpubInspector: { EpubInspector: class {}, EpubInspectionError: ControlledInspectionError },
  ManagedBookStore: { ManagedBookStore: class {}, createSecureUuid: () => `owned-operation-${++token}` },
  TxtToEpub: { convertTxtToEpub() { throw new Error('Unentered TXT boundary'); }, previewTxt() { throw new Error('Unentered TXT boundary'); } },
  ProductionImportPolicy: { VISIBLE_IMPORT_BATCH_LIMIT: 4 },
  ImportMeasurement: { measureImportStage: async (_observer, _stage, action) => action() }
};
function load(relative) {
  if (cache.has(relative)) return cache.get(relative);
  const sourcePath = fs.existsSync(path.join(candidate, relative)) ? path.join(candidate, relative) : path.join(root, relative);
  const source = fs.readFileSync(sourcePath, 'utf8');
  const result = ts.transpileModule(source, { fileName: relative + '.ts',
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
  const errors = (result.diagnostics ?? []).filter((item) => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0, `TypeScript syntax conversion: ${relative}`);
  const module = { exports: {} };
  cache.set(relative, module.exports);
  function requireControlled(request) {
    if (special[request]) return special[request];
    if (special[path.posix.basename(request)]) return special[path.posix.basename(request)];
    if (!request.startsWith('.')) throw new Error(`Uncontrolled module: ${request}`);
    return load(path.posix.normalize(path.posix.join(path.posix.dirname(relative), request + '.ets')));
  }
  vm.runInNewContext(result.outputText, { require: requireControlled, module, exports: module.exports,
    console, Date, Promise, Uint8Array, ArrayBuffer, Number, Error, Set, Map }, { filename: relative });
  cache.set(relative, module.exports);
  return module.exports;
}
const { LibraryRepository } = load('entry/src/main/ets/repositories/LibraryRepository.ets');
const { BookImportService } = load('entry/src/main/ets/services/BookImportService.ets');
const { BatchImportCoordinator } = load('entry/src/main/ets/application/BatchImportCoordinator.ets');
const { LibraryApplication } = load('entry/src/main/ets/application/LibraryApplication.ets');
function book(id) { return { bookId: id, fileHash: id, title: 'Owned fixture', epubRelativePath: `books/${id}/book.epub`, importedAt: 10, sourceState: 'available' }; }
async function prepared(repository, value, kind = 'import') {
  const operationId = `owned-operation-${++token}`;
  await repository.createOperation({ operationId, kind, state: 'prepared', bookId: value.bookId, createdAt: 10, updatedAt: 10 });
  return { status: kind === 'repair' ? 'prepared-repair' : 'prepared-new', book: value, operationId, operationKind: kind };
}
async function fixture() {
  currentStore = new SqlStore();
  const sql = currentStore;
  const repository = new LibraryRepository();
  await repository.initialize({}); // Actual v0->v7 migrations on controlled SQLite; no platform security claim.
  await repository.createFolder({ folderId: 'folder-a', parentId: '', name: 'A' });
  await repository.createFolder({ folderId: 'folder-b', parentId: 'folder-a', name: 'B' });
  const final = new Set();
  const deleted = [];
  const managed = { createToken: () => `owned-stage-${++token}`, createStage: async () => {},
    stageAndHash: async () => 'e'.repeat(64), hasBookFile: async () => true, deleteStage: async () => {},
    deleteFinal: async (id) => { final.delete(id); deleted.push(id); } };
  const service = new BookImportService({}, repository, managed);
  const application = new LibraryApplication(repository, service, {}, {}, managed);
  return { sql, repository, managed, service, application, final, deleted };
}
async function existing(fixture) {
  const value = book('e'.repeat(64));
  await fixture.repository.insertBook(value);
  await fixture.repository.moveBook(value.bookId, 'folder-a');
  await fixture.repository.setSeries(value.bookId, 'Owned series', 2.5);
  await fixture.repository.saveProgress({ bookId: value.bookId, location: { engine: 'web-epubjs-0.3.93', locator: 'owned-locator', percentage: 0.4 }, updatedAt: 30 });
  return value;
}
function durableRows(fixture) {
  return JSON.stringify({ book: fixture.sql.db.prepare('SELECT * FROM books ORDER BY book_id').all(),
    progress: fixture.sql.db.prepare('SELECT * FROM reading_progress ORDER BY book_id').all() });
}
const cases = [
  ['directoryFinalizeRejectsNonemptyRootAndChangedScope', async (f) => {
    const value=await existing(f), before=durableRows(f);
    await assert.rejects(f.repository.deleteFolder(''));
    await assert.rejects(f.repository.deleteFolder('folder-a',['folder-a','folder-b']));
    assert.equal(durableRows(f),before);assert.equal((await f.repository.listFolders()).length,2);
    await assert.rejects(f.repository.deleteFolder('folder-b',['not-confirmed']));
    assert.equal((await f.repository.listFolders()).length,2);
    await f.repository.deleteFolder('folder-b',['folder-b']);
    assert.equal((await f.repository.listFolders()).length,1);assert.ok(await f.repository.getBook(value.bookId));
  }],
  ['directoryFinalizeRollbackRetainsWholeEmptyTree', async (f) => {
    f.sql.beforeSql=(sql,values)=>{if(sql.startsWith('DELETE FROM library_folders') && values[0]==='folder-b')throw Error('owned directory failure');};
    await assert.rejects(f.repository.deleteFolder('folder-a',['folder-a','folder-b']));
    assert.equal((await f.repository.listFolders()).length,2);
    f.sql.beforeSql=undefined;await f.repository.deleteFolder('folder-a',['folder-a','folder-b']);
    assert.equal((await f.repository.listFolders()).length,0);
  }],

  ['newRootAndNestedMembershipShareCommit', async (f) => {
    for (const [id, folder] of [['1'.repeat(64), ''], ['2'.repeat(64), 'folder-b']]) {
      const result = await prepared(f.repository, book(id));
      await f.service.commitPrepared(result.operationId, result.operationKind, result.book, folder);
      assert.equal((await f.repository.listOrganizations()).find((item) => item.bookId === id).folderId, folder);
      assert.equal((await f.repository.getBook(id)).fileHash, id);
    }
    assert.equal((await f.repository.listOperations()).length, 0);
    assert.equal(f.repository.databaseVersion(), 7);
  }],
  ['deletedTargetRejectsAndRetainsJournalUntilCleanup', async (f) => {
    const value = book('3'.repeat(64));
    const result = await prepared(f.repository, value); f.final.add(value.bookId);
    await f.repository.deleteFolder('folder-b');
    await assert.rejects(f.service.commitPrepared(result.operationId, 'import', value, 'folder-b'));
    assert.equal(await f.repository.getBook(value.bookId), undefined);
    assert.equal((await f.repository.listOperations()).length, 1);
    assert.equal(await f.service.rollbackPrepared(result.operationId, value.bookId), true);
    assert.equal(f.final.size, 0); assert.equal((await f.repository.listOperations()).length, 0);
  }],
  ['statementTimeTargetCheckPreventsOrphan', async (f) => {
    const value = book('4'.repeat(64)); const result = await prepared(f.repository, value);
    f.sql.beforeSql = (sql) => { if (sql.startsWith('INSERT INTO books(')) f.sql.db.prepare('DELETE FROM library_folders WHERE folder_id=?').run('folder-b'); };
    await assert.rejects(f.service.commitPrepared(result.operationId, 'import', value, 'folder-b'));
    assert.equal(await f.repository.getBook(value.bookId), undefined);
    assert.equal((await f.repository.listOperations()).length, 1);
    // The injected removal belongs to this SQLite transaction. This is a SQL
    // boundary check, not proof of native same-handle concurrent transactions.
  }],
  ['failureAfterInsertRollsBackBookMembershipAndPreservesExistingData', async (f) => {
    await existing(f); const before = durableRows(f);
    const value = book('5'.repeat(64)); const result = await prepared(f.repository, value);
    f.sql.beforeSql = (sql) => { if (sql.startsWith('DELETE FROM library_operations')) throw new Error('Owned SQL fault'); };
    await assert.rejects(f.service.commitPrepared(result.operationId, 'import', value, 'folder-b'));
    assert.equal(durableRows(f), before); assert.equal((await f.repository.listOperations()).length, 1);
  }],
  ['realDuplicateImportAndBatchPreserveMembershipSeriesAndProgress', async (f) => {
    await existing(f); const before = durableRows(f);
    const batch = new BatchImportCoordinator(f.service);
    assert.equal(batch.addSelection(['owned.epub'], 'folder-b').targetFolderId, 'folder-b');
    const result = await batch.confirm(() => {});
    assert.equal(result.items[0].status, 'duplicate');
    assert.equal(durableRows(f), before); assert.equal((await f.repository.listOperations()).length, 0);
  }],
  ['repairIgnoresCapturedMissingTargetAndRetainsOldOrganization', async (f) => {
    const value = await existing(f); await f.repository.markSourceState(value.bookId, 'missing');
    const priorOrganization = JSON.stringify(await f.repository.listOrganizations());
    const priorProgress = JSON.stringify(await f.repository.getProgress(value.bookId));
    const result = await prepared(f.repository, value, 'repair');
    await f.service.commitPrepared(result.operationId, 'repair', value, 'already-deleted-target');
    assert.equal(JSON.stringify(await f.repository.listOrganizations()), priorOrganization);
    assert.equal(JSON.stringify(await f.repository.getProgress(value.bookId)), priorProgress);
    assert.equal((await f.repository.getBook(value.bookId)).sourceState, 'available');
  }],
  ['batchTargetIsFixedAndRejectedAdditionsDoNotReplaceIt', async (f) => {
    const batch = new BatchImportCoordinator(f.service);
    batch.addSelection(['owned-one.epub'], 'folder-a');
    const rejected = batch.addSelection(['owned-two.epub'], 'folder-b');
    assert.equal(rejected.items.length, 1); assert.equal(rejected.targetFolderId, 'folder-a'); assert.ok(rejected.message);
    const accepted = batch.addSelection(['owned-two.epub'], 'folder-a');
    assert.equal(accepted.items.length, 2); assert.equal(accepted.targetFolderId, 'folder-a');
    let next = 6;
    f.service.import = async () => prepared(f.repository, book(String(next++).repeat(64)));
    const result = await batch.confirm(() => {});
    assert.deepEqual(Array.from(result.items, (item) => item.status), ['stored', 'stored']);
    assert.ok((await f.repository.listOrganizations()).every((item) => item.folderId === 'folder-a'));
  }],
  ['batchDeletedTargetFailsNewAndCleansPreparedCopy', async (f) => {
    const batch = new BatchImportCoordinator(f.service);
    batch.addSelection(['owned-new.epub'], 'folder-b');
    f.service.import = async () => { const value = book('8'.repeat(64)); f.final.add(value.bookId); return prepared(f.repository, value); };
    await f.repository.deleteFolder('folder-b');
    const result = await batch.confirm(() => {});
    assert.equal(result.items[0].status, 'failed'); assert.equal(f.final.size, 0);
    assert.equal((await f.repository.listBooks()).length, 0); assert.equal((await f.repository.listOperations()).length, 0);
  }],
  ['deletedTargetCleanupFailureRetainsJournalAndStopsLaterItems', async (f) => {
    const batch = new BatchImportCoordinator(f.service);
    batch.addSelection(['owned-new.epub', 'owned-later.epub'], 'folder-b');
    f.service.import = async () => { const value = book('b'.repeat(64)); f.final.add(value.bookId); return prepared(f.repository, value); };
    f.managed.deleteFinal = async () => { throw new Error('Owned cleanup fault'); };
    await f.repository.deleteFolder('folder-b');
    const result = await batch.confirm(() => {});
    assert.equal(result.items[0].status, 'failed'); assert.equal(result.items[1].status, 'not-started');
    assert.equal((await f.repository.listBooks()).length, 0); assert.equal((await f.repository.listOperations()).length, 1);
    assert.equal(f.final.size, 1);
  }],
  ['batchCancelAndReviewResetNeverCommitMembership', async (f) => {
    const batch = new BatchImportCoordinator(f.service);
    batch.addSelection(['owned-new.epub'], 'folder-b');
    f.service.import = async () => { const value = book('9'.repeat(64)); f.final.add(value.bookId); return prepared(f.repository, value); };
    const result = await batch.confirm((snapshot) => { if (snapshot.items[0].status === 'active') batch.cancel(); });
    assert.equal(result.items[0].status, 'cancelled'); assert.equal(f.final.size, 0);
    assert.equal((await f.repository.listBooks()).length, 0); assert.equal((await f.repository.listOperations()).length, 0);
    assert.equal(batch.resetResults().targetFolderId, undefined);
    assert.equal(batch.addSelection(['owned-next.epub'], 'folder-a').targetFolderId, 'folder-a');
    assert.equal(batch.cancelReview().targetFolderId, undefined);
  }],
  ['singleImportRetainsTargetThroughPreparedReaderSession', async (f) => {
    const value = book('a'.repeat(64));
    f.service.import = async () => prepared(f.repository, value);
    await f.application.import('owned-new.epub', 'folder-b');
    f.application.bindPreparedSession(value.bookId, 777);
    assert.equal(await f.application.commitPrepared(776, value), false);
    assert.equal(await f.application.commitPrepared(777, value), true);
    assert.equal((await f.repository.listOrganizations())[0].folderId, 'folder-b');
    assert.equal(f.application.hasPreparedBook(value.bookId), false);
  }],
  ['singleDeletedTargetKeepsPendingUntilExplicitReaderRollback', async (f) => {
    const value = book('c'.repeat(64)); f.final.add(value.bookId);
    f.service.import = async () => prepared(f.repository, value);
    await f.application.import('owned-new.epub', 'folder-b');
    f.application.bindPreparedSession(value.bookId, 778);
    await f.repository.deleteFolder('folder-b');
    await assert.rejects(f.application.commitPrepared(778, value));
    assert.equal(f.application.hasPreparedBook(value.bookId), true);
    assert.equal(await f.application.rollbackPrepared(778), 'rolled-back');
    assert.equal(f.application.hasPreparedBook(value.bookId), false);
    assert.equal(f.final.size, 0); assert.equal((await f.repository.listOperations()).length, 0);
  }]
];
(async () => {
  for (const [name, run] of cases) {
    const f = await fixture();
    try { await run(f); console.log(`PASS ${name}`); }
    finally { f.sql.close(); }
  }
  console.log(`Passed ${cases.length}/${cases.length}: actual current methods, controlled Kit boundaries and Node SQLite writer oracle; SDK/device separate.`);
})().catch((error) => { console.error(error.stack); process.exitCode = 1; });
