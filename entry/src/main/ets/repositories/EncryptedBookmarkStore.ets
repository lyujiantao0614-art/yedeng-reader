import { common } from '@kit.AbilityKit';
import { NoteSummary, RecordCursor, RecordPage, recordPageSize } from '../domain/ReadingRecordQuery';
import { relationalStore } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BookmarkPoint, PageBookmarkExcerpt, TextMarkRecord, NoteEntry, RangeAnchorStatus, TextRangeAnchor, NoteAnchorProvenance, copyTextRangeAnchor } from '../domain/Models';

const PRODUCTION_DB: string = 'harmony_reading_records.db';
export interface RecordStoreOptions {
  failMigrationToVersion?: number;
  failAfterVersionTo?: number;
  cancelled?: () => boolean;
  failRangeCommit?: 'after-reparent' | 'before-commit';
}

export class EncryptedBookmarkStore {
  private databaseName: string;
  private store?: relationalStore.RdbStore;
  private options: RecordStoreOptions;
  private writeQueue: Promise<void> = Promise.resolve();

  constructor(databaseName: string = PRODUCTION_DB, options: RecordStoreOptions = {}) {
    if (!/^[a-z0-9_-]+\.db$/.test(databaseName)) throw new Error('Invalid record database name');
    this.databaseName = databaseName;
    this.options = options;
  }

  async openExisting(context: common.Context): Promise<void> {
    this.close();
    // getRdbStore creates an empty database when its file is missing. The
    // catalogue authority marker makes that case a failure, not first use.
    let files: string[];
    try { files = await fs.listFile(`${context.databaseDir}/rdb`); }
    catch (_) { throw new Error('Authoritative record store unavailable'); }
    if (!files.includes(this.databaseName)) throw new Error('Authoritative record store unavailable');
    let opened: relationalStore.RdbStore | undefined;
    try {
      opened = await relationalStore.getRdbStore(context, {
        name: this.databaseName, securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
      });
      if (opened.version < 1 || opened.version > 5) throw new Error('Unsupported record store version');
      const result = await opened.querySql('SELECT value FROM record_identity WHERE name=?', ['schema']);
      try {
        if (!result.goToNextRow() || result.getString(0) !== 'encrypted-bookmarks-v1') {
          throw new Error('Record store identity invalid');
        }
      } finally { result.close(); }
      if (opened.version === 1) await this.migrateTextMarks(opened);
      if (opened.version === 2) await this.migratePageExcerpts(opened);
      if (opened.version === 3) await this.migrateRanges(opened);
      if (opened.version === 4) await this.migrateNoteAnchors(opened);
      await this.verifyRangeCopy(opened);
      this.store = opened;
    } catch (_) {
      opened?.close();
      throw new Error('Authoritative record store unavailable');
    }
  }

  async createForMigration(context: common.Context): Promise<void> {
    this.close();
    const opened = await relationalStore.getRdbStore(context, {
      name: this.databaseName, securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
    });
    try {
      if (opened.version !== 0) {
        opened.close(); await this.openExisting(context); return;
      }
      opened.beginTransaction();
      try {
        await opened.executeSql('CREATE TABLE record_identity (name TEXT PRIMARY KEY,value TEXT NOT NULL)');
        await opened.executeSql('INSERT INTO record_identity(name,value) VALUES(?,?)',
          ['schema', 'encrypted-bookmarks-v1']);
        await opened.executeSql('CREATE TABLE bookmarks (bookmark_id TEXT PRIMARY KEY,' +
          'book_id TEXT NOT NULL,anchor_version INTEGER NOT NULL,engine TEXT NOT NULL,' +
          'resource_href TEXT NOT NULL,cfi TEXT NOT NULL,label TEXT NOT NULL,created_at INTEGER NOT NULL)');
        await opened.executeSql('CREATE INDEX bookmarks_by_book ON bookmarks(book_id,created_at)');
        this.checkMigration(1);
        opened.version = 1;
        this.checkCommit(1);
        opened.commit();
      } catch (_) { opened.rollBack(); throw new Error('Record store creation failed'); }
      await this.migrateTextMarks(opened);
      await this.migratePageExcerpts(opened);
      await this.migrateRanges(opened);
      await this.migrateNoteAnchors(opened);
      await this.verifyRangeCopy(opened);
      this.store = opened;
    } catch (_) { opened.close(); throw new Error('Record store creation failed'); }
  }

  private async migrateTextMarks(store: relationalStore.RdbStore): Promise<void> {
    store.beginTransaction();
    try {
      await store.executeSql('CREATE TABLE text_marks (mark_id TEXT PRIMARY KEY,' +
        'book_id TEXT NOT NULL,anchor_version INTEGER NOT NULL,engine TEXT NOT NULL,' +
        'resource_href TEXT NOT NULL,cfi TEXT NOT NULL,exact_text TEXT NOT NULL,' +
        'prefix TEXT NOT NULL,suffix TEXT NOT NULL,kind TEXT NOT NULL,' +
        'chapter_title TEXT NOT NULL,note_text TEXT NOT NULL,created_at INTEGER NOT NULL)');
      await store.executeSql('CREATE INDEX text_marks_by_book ON text_marks(book_id,created_at)');
      this.checkMigration(2);
      store.version = 2;
      this.checkCommit(2);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Text record migration failed'); }
  }

  private async migratePageExcerpts(store: relationalStore.RdbStore): Promise<void> {
    store.beginTransaction();
    try {
      await store.executeSql('CREATE TABLE page_excerpts (bookmark_id TEXT PRIMARY KEY,' +
        'book_id TEXT NOT NULL,excerpt TEXT NOT NULL)');
      await store.executeSql('CREATE INDEX page_excerpts_by_book ON page_excerpts(book_id)');
      this.checkMigration(3);
      store.version = 3;
      this.checkCommit(3);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Page excerpt migration failed'); }
  }

  private checkMigration(version: number): void {
    if (this.options.failMigrationToVersion === version || this.options.cancelled?.()) throw new Error('Record migration interrupted');
  }

  private checkCommit(version: number): void {
    if (this.options.failAfterVersionTo === version) throw new Error('Injected record commit failure');
  }

  private async migrateRanges(store: relationalStore.RdbStore): Promise<void> {
    store.beginTransaction();
    try {
      await store.executeSql('CREATE TABLE range_records (mark_id TEXT PRIMARY KEY,book_id TEXT NOT NULL,' +
        'anchor_version INTEGER NOT NULL,engine TEXT NOT NULL,resource_href TEXT NOT NULL,cfi TEXT NOT NULL,' +
        'exact_text TEXT NOT NULL,prefix TEXT NOT NULL,suffix TEXT NOT NULL,kind TEXT NOT NULL,chapter_title TEXT NOT NULL,' +
        'created_at INTEGER NOT NULL,revision INTEGER NOT NULL,highlight_active INTEGER NOT NULL,anchor_status TEXT NOT NULL,quote_scope TEXT NOT NULL)');
      await store.executeSql('CREATE INDEX ranges_by_book ON range_records(book_id,created_at)');
      await store.executeSql('CREATE TABLE note_entries (note_id TEXT PRIMARY KEY,book_id TEXT NOT NULL,range_id TEXT NOT NULL,' +
        'body TEXT NOT NULL,created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,revision INTEGER NOT NULL)');
      await store.executeSql('CREATE INDEX notes_by_range ON note_entries(book_id,range_id)');
      await store.executeSql("INSERT INTO range_records SELECT mark_id,book_id,anchor_version,engine,resource_href,cfi," +
        "exact_text,prefix,suffix,kind,chapter_title,created_at,1,1,'unchecked','block' FROM text_marks");
      await store.executeSql("INSERT INTO note_entries SELECT 'legacy-note:'||mark_id,book_id,mark_id,note_text," +
        "created_at,created_at,1 FROM text_marks WHERE note_text<>''");
      // executeSql uses the transaction's writer. ArkData querySql reads the committed snapshot.
      await store.executeSql('CREATE TABLE range_copy_verification (ok INTEGER NOT NULL CHECK(ok=1))');
      await store.executeSql('INSERT INTO range_copy_verification SELECT CASE WHEN ' +
        '(SELECT COUNT(*) FROM range_records)=(SELECT COUNT(*) FROM text_marks) AND ' +
        "(SELECT COUNT(*) FROM note_entries)=(SELECT COUNT(*) FROM text_marks WHERE note_text<>'') AND " +
        'NOT EXISTS(SELECT mark_id,book_id,anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,kind,chapter_title,created_at FROM text_marks ' +
        'EXCEPT SELECT mark_id,book_id,anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,kind,chapter_title,created_at FROM range_records) AND ' +
        "NOT EXISTS(SELECT 'legacy-note:'||mark_id,book_id,mark_id,note_text,created_at FROM text_marks WHERE note_text<>'' " +
        'EXCEPT SELECT note_id,book_id,range_id,body,created_at FROM note_entries) THEN 1 ELSE 0 END');
      this.checkMigration(4);
      await store.executeSql('DROP TABLE range_copy_verification');
      await store.executeSql('CREATE TABLE range_migration (id INTEGER PRIMARY KEY CHECK(id=1),verified INTEGER NOT NULL CHECK(verified=1))');
      await store.executeSql('INSERT INTO range_migration VALUES(1,1)');
      store.version = 4;
      this.checkCommit(4);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Range copy migration failed'); }
  }

  private async migrateNoteAnchors(store: relationalStore.RdbStore): Promise<void> {
    // The committed v4 snapshot is read before the writer transaction. Original
    // highlights are kept independently of a subsequently enlarged note group.
    const result = await store.querySql('SELECT mark_id,book_id,anchor_version,engine,resource_href,cfi,' +
      'exact_text,prefix,suffix,kind,highlight_active,quote_scope FROM range_records');
    const highlights: TextMarkRecord[] = [];
    try {
      while (result.goToNextRow()) {
        if (result.getString(9) !== 'highlight' || result.getLong(10) !== 1) continue;
        highlights.push({ markId: result.getString(0), bookId: result.getString(1),anchorVersion: result.getLong(2),
          engine: result.getString(3),resourceHref: result.getString(4),cfi: result.getString(5),
          exactText: result.getString(6),prefix: result.getString(7),suffix: result.getString(8),
          kind: 'highlight',chapterTitle: '',noteText: '',createdAt: 0,
          quoteScope: result.getString(11) === 'body' ? 'body' : 'block' });
      }
    } finally { result.close(); }
    store.beginTransaction();
    try {
      await store.executeSql('CREATE TABLE range_records_before_v5 AS SELECT * FROM range_records');
      await store.executeSql('CREATE TABLE note_entries_before_v5 AS SELECT * FROM note_entries');
      await store.executeSql("ALTER TABLE range_records ADD COLUMN highlight_anchors TEXT NOT NULL DEFAULT '[]'");
      for (const column of ['original_engine','original_resource_href','original_cfi','original_text','original_prefix','original_suffix']) {
        await store.executeSql(`ALTER TABLE note_entries ADD COLUMN ${column} TEXT NOT NULL DEFAULT ''`);
      }
      await store.executeSql('ALTER TABLE note_entries ADD COLUMN original_anchor_version INTEGER NOT NULL DEFAULT 1');
      await store.executeSql("ALTER TABLE note_entries ADD COLUMN original_scope TEXT NOT NULL DEFAULT 'block'");
      await store.executeSql("ALTER TABLE note_entries ADD COLUMN anchor_provenance TEXT NOT NULL DEFAULT 'legacy-group'");
      await store.executeSql("ALTER TABLE note_entries ADD COLUMN original_status TEXT NOT NULL DEFAULT 'unavailable'");
      const original = 'original_anchor_version,original_engine,original_resource_href,original_cfi,original_text,original_prefix,original_suffix,original_scope';
      await store.executeSql(`UPDATE note_entries SET (${original})=(SELECT anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,quote_scope FROM range_records WHERE book_id=note_entries.book_id AND mark_id=note_entries.range_id)`);
      const reliable = "t.book_id=note_entries.book_id AND note_entries.note_id='legacy-note:'||t.mark_id AND t.created_at=note_entries.created_at";
      await store.executeSql(`UPDATE note_entries SET (${original})=(SELECT anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,'block' FROM text_marks t WHERE ${reliable}),anchor_provenance='legacy-record',original_status='unchecked' WHERE EXISTS(SELECT 1 FROM text_marks t WHERE ${reliable})`);
      for (const mark of highlights) await store.executeSql('UPDATE range_records SET highlight_anchors=? WHERE book_id=? AND mark_id=?',
        [JSON.stringify([copyTextRangeAnchor(mark)]),mark.bookId,mark.markId]);
      await store.executeSql('CREATE TABLE note_anchor_copy_verification (ok INTEGER NOT NULL CHECK(ok=1))');
      await store.executeSql('INSERT INTO note_anchor_copy_verification SELECT CASE WHEN ' +
        'NOT EXISTS(SELECT note_id,book_id,range_id,body,created_at,updated_at,revision FROM note_entries_before_v5 ' +
        'EXCEPT SELECT note_id,book_id,range_id,body,created_at,updated_at,revision FROM note_entries) AND ' +
        '(SELECT COUNT(*) FROM note_entries_before_v5)=(SELECT COUNT(*) FROM note_entries) AND ' +
        "NOT EXISTS(SELECT 1 FROM note_entries WHERE original_cfi IS NULL OR original_cfi='' OR original_text IS NULL OR original_text='' OR original_resource_href IS NULL OR original_resource_href='') AND " +
        "NOT EXISTS(SELECT n.note_id,t.anchor_version,t.engine,t.resource_href,t.cfi,t.exact_text,t.prefix,t.suffix,'block' FROM note_entries n JOIN text_marks t ON n.book_id=t.book_id AND n.note_id='legacy-note:'||t.mark_id AND n.created_at=t.created_at " +
        'EXCEPT SELECT note_id,original_anchor_version,original_engine,original_resource_href,original_cfi,original_text,original_prefix,original_suffix,original_scope FROM note_entries) ' +
        'THEN 1 ELSE 0 END');
      this.checkMigration(5);
      await store.executeSql('DROP TABLE note_anchor_copy_verification');
      await store.executeSql('CREATE TABLE note_anchor_migration (id INTEGER PRIMARY KEY CHECK(id=1),verified INTEGER NOT NULL CHECK(verified=1))');
      await store.executeSql('INSERT INTO note_anchor_migration VALUES(1,1)');
      store.version = 5;
      this.checkCommit(5);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Original note anchor migration failed'); }
  }

  private async verifyRangeCopy(store: relationalStore.RdbStore): Promise<void> {
    if (store.version !== 5) throw new Error('Range schema unavailable');
    const result = await store.querySql('SELECT verified FROM range_migration WHERE id=1');
    try { if (!result.goToNextRow() || result.getLong(0) !== 1) throw new Error('Range copy not verified'); }
    finally { result.close(); }
    // Committed copy receipt is permanent; live records can subsequently be merged/edited/deleted.
    const notes = await store.querySql('SELECT verified FROM note_anchor_migration WHERE id=1');
    try { if (!notes.goToNextRow() || notes.getLong(0) !== 1) throw new Error('Note anchor copy not verified'); }
    finally { notes.close(); }
  }

  databaseVersion(): number { return this.requireStore().version; }

  private serial(action: () => Promise<void>): Promise<void> {
    const task = this.writeQueue.then(action);
    this.writeQueue = task.catch((): void => {});
    return task;
  }

  ensureAvailable(): void {
    if (this.store === undefined) throw new Error('Authoritative record store unavailable');
  }

  private requireStore(): relationalStore.RdbStore {
    this.ensureAvailable();
    return this.store!;
  }

  async copyAndVerify(points: BookmarkPoint[]): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      for (const point of points) {
        await store.executeSql('INSERT OR IGNORE INTO bookmarks ' +
          '(bookmark_id,book_id,anchor_version,engine,resource_href,cfi,label,created_at) ' +
          'VALUES(?,?,?,?,?,?,?,?)', [point.bookmarkId, point.bookId, point.anchorVersion,
            point.engine, point.resourceHref, point.cfi, point.label, point.createdAt]);
      }
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Record copy failed'); }
    // ArkData querySql observes the committed snapshot, so verify after commit.
    // Source rows remain authoritative until the separate source transaction.
    const result = await store.querySql('SELECT bookmark_id,book_id,anchor_version,engine,' +
        'resource_href,cfi,label,created_at FROM bookmarks');
    let count = 0;
    try {
      while (result.goToNextRow()) {
          const point = points.find((item: BookmarkPoint): boolean => item.bookmarkId === result.getString(0));
          if (point === undefined || point.bookId !== result.getString(1) ||
            point.anchorVersion !== result.getLong(2) || point.engine !== result.getString(3) ||
            point.resourceHref !== result.getString(4) || point.cfi !== result.getString(5) ||
            point.label !== result.getString(6) || point.createdAt !== result.getLong(7)) {
            throw new Error('Record copy verification failed');
          }
          count++;
      }
    } finally { result.close(); }
    if (count !== points.length) throw new Error('Record copy count mismatch');
  }

  async list(bookId: string): Promise<BookmarkPoint[]> {
    const result = await this.requireStore().querySql('SELECT bookmark_id,book_id,anchor_version,' +
      'engine,resource_href,cfi,label,created_at FROM bookmarks WHERE book_id=? ' +
      'ORDER BY created_at,bookmark_id', [bookId]);
    const points: BookmarkPoint[] = [];
    try {
      while (result.goToNextRow()) points.push({ bookmarkId: result.getString(0),
        bookId: result.getString(1), anchorVersion: result.getLong(2), engine: result.getString(3),
        resourceHref: result.getString(4), cfi: result.getString(5), label: result.getString(6),
        createdAt: result.getLong(7) });
    } finally { result.close(); }
    return points;
  }

  async bookmarkPage(cursor?: RecordCursor, size: number = 20): Promise<RecordPage<BookmarkPoint>> {
    try {
    const limit = recordPageSize(size);
    const result = await this.requireStore().querySql('SELECT bookmark_id,book_id,anchor_version,' +
      'engine,resource_href,cfi,substr(label,1,256),created_at FROM bookmarks ' +
      (cursor ? 'WHERE created_at<? OR (created_at=? AND bookmark_id<?) ' : '') +
      'ORDER BY created_at DESC,bookmark_id DESC LIMIT ?',
      cursor ? [cursor.time, cursor.time, cursor.id, limit + 1] : [limit + 1]);
    const items: BookmarkPoint[] = [];
    try {
      while (result.goToNextRow()) items.push({ bookmarkId: result.getString(0), bookId: result.getString(1),
        anchorVersion: result.getLong(2), engine: result.getString(3), resourceHref: result.getString(4),
        cfi: result.getString(5), label: result.getString(6), createdAt: result.getLong(7) });
    } finally { result.close(); }
    const more = items.length > limit;
    if (more) items.pop();
    const last = items[items.length - 1];
    return { items, next: more ? { time: last.createdAt, id: last.bookmarkId } : undefined };
    } catch (_) { throw new Error('Bookmark page unavailable'); }
  }

  async notePage(cursor?: RecordCursor, size: number = 20): Promise<RecordPage<NoteSummary>> {
    try {
    const limit = recordPageSize(size);
    const result = await this.requireStore().querySql('SELECT note_id,book_id,substr(original_text,1,160),' +
      'substr(body,1,180),created_at,updated_at FROM note_entries ' +
      (cursor ? 'WHERE updated_at<? OR (updated_at=? AND note_id<?) ' : '') +
      'ORDER BY updated_at DESC,note_id DESC LIMIT ?',
      cursor ? [cursor.time, cursor.time, cursor.id, limit + 1] : [limit + 1]);
    const items: NoteSummary[] = [];
    try {
      while (result.goToNextRow()) items.push({ noteId: result.getString(0), bookId: result.getString(1),
        quote: result.isColumnNull(2) ? '' : result.getString(2), excerpt: result.isColumnNull(3) ? '' : result.getString(3),
        createdAt: result.getLong(4), updatedAt: result.getLong(5) });
    } finally { result.close(); }
    const more = items.length > limit;
    if (more) items.pop();
    const last = items[items.length - 1];
    return { items, next: more ? { time: last.updatedAt, id: last.noteId } : undefined };
    } catch (_) { throw new Error('Note page unavailable'); }
  }

  async noteDetail(bookId: string, noteId: string): Promise<NoteEntry | undefined> {
    try {
    const result = await this.requireStore().querySql('SELECT note_id,book_id,range_id,body,created_at,updated_at,revision,' +
      'original_anchor_version,original_engine,original_resource_href,original_cfi,original_text,original_prefix,original_suffix,' +
      'original_scope,anchor_provenance,original_status FROM note_entries WHERE book_id=? AND note_id=?', [bookId, noteId]);
    try {
      if (!result.goToNextRow()) return undefined;
      return { noteId: result.getString(0), bookId: result.getString(1), rangeId: result.getString(2),
        body: result.getString(3), createdAt: result.getLong(4), updatedAt: result.getLong(5), revision: result.getLong(6),
        originalAnchor: { anchorVersion: result.getLong(7), engine: result.getString(8), resourceHref: result.getString(9),
          cfi: result.getString(10), exactText: result.getString(11), prefix: result.getString(12), suffix: result.getString(13),
          quoteScope: result.getString(14) === 'body' ? 'body' : 'block' },
        anchorProvenance: result.getString(15) as NoteAnchorProvenance, anchorStatus: result.getString(16) as RangeAnchorStatus };
    } finally { result.close(); }
    } catch (_) { throw new Error('Note detail unavailable'); }
  }

  async insert(point: BookmarkPoint): Promise<void> {
    await this.requireStore().executeSql('INSERT INTO bookmarks ' +
      '(bookmark_id,book_id,anchor_version,engine,resource_href,cfi,label,created_at) ' +
      'VALUES(?,?,?,?,?,?,?,?)', [point.bookmarkId, point.bookId, point.anchorVersion,
        point.engine, point.resourceHref, point.cfi, point.label, point.createdAt]);
  }

  async remove(bookId: string, bookmarkId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM bookmarks WHERE book_id=? AND bookmark_id=?',
      [bookId, bookmarkId]);
  }

  async deleteBook(bookId: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM bookmarks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM text_marks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM note_entries WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM range_records WHERE book_id=?', [bookId]);
      // Owner-approved explicit complete-book deletion includes its recovery
      // snapshots. Folder removal and per-note deletion never enter this path.
      await store.executeSql('DELETE FROM range_records_before_v5 WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM note_entries_before_v5 WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM page_excerpts WHERE book_id=?', [bookId]);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Record deletion failed'); }
    });
  }

  async listPageExcerpts(bookId: string): Promise<PageBookmarkExcerpt[]> {
    const result = await this.requireStore().querySql(
      'SELECT bookmark_id,book_id,excerpt FROM page_excerpts WHERE book_id=?', [bookId]);
    const excerpts: PageBookmarkExcerpt[] = [];
    try {
      while (result.goToNextRow()) excerpts.push({ bookmarkId: result.getString(0),
        bookId: result.getString(1), excerpt: result.getString(2) });
    } finally { result.close(); }
    return excerpts;
  }

  async insertPageExcerpt(value: PageBookmarkExcerpt): Promise<void> {
    await this.requireStore().executeSql('INSERT INTO page_excerpts(bookmark_id,book_id,excerpt) ' +
      'VALUES(?,?,?)', [value.bookmarkId, value.bookId, value.excerpt]);
  }

  async removePageExcerpt(bookId: string, bookmarkId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM page_excerpts WHERE book_id=? AND bookmark_id=?',
      [bookId, bookmarkId]);
  }

  async listTextMarks(bookId: string): Promise<TextMarkRecord[]> {
    const result = await this.requireStore().querySql('SELECT mark_id,book_id,anchor_version,engine,' +
      'resource_href,cfi,exact_text,prefix,suffix,kind,chapter_title,created_at,revision,highlight_active,anchor_status,quote_scope ' +
      ',highlight_anchors FROM range_records WHERE book_id=? ORDER BY created_at,mark_id', [bookId]);
    const marks: TextMarkRecord[] = [];
    try {
      while (result.goToNextRow()) marks.push({ markId: result.getString(0), bookId: result.getString(1),
        anchorVersion: result.getLong(2), engine: result.getString(3), resourceHref: result.getString(4),
        cfi: result.getString(5), exactText: result.getString(6), prefix: result.getString(7),
        suffix: result.getString(8), kind: result.getString(9) === 'note' ? 'note' : 'highlight',
        chapterTitle: result.getString(10), noteText: '', createdAt: result.getLong(11),
        revision: result.getLong(12), highlightActive: result.getLong(13) === 1,
        anchorStatus: result.getString(14) as RangeAnchorStatus,quoteScope: result.getString(15) === 'body' ? 'body' : 'block',
        highlightAnchors: JSON.parse(result.getString(16)) as TextRangeAnchor[] });
    } finally { result.close(); }
    const notes = await this.listNotes(bookId);
    for (const mark of marks) {
      mark.notes = notes.filter((note: NoteEntry): boolean => note.rangeId === mark.markId);
      mark.noteText = mark.notes[0]?.body ?? '';
      mark.kind = mark.notes.length > 0 ? 'note' : 'highlight';
    }
    return marks;
  }

  async insertTextMark(mark: TextMarkRecord): Promise<void> {
    const note: NoteEntry | undefined = mark.noteText.length > 0 ? { noteId: `note:${mark.markId}`,
      bookId: mark.bookId, rangeId: mark.markId, body: mark.noteText,
      createdAt: mark.createdAt, updatedAt: mark.createdAt, revision: 1,
      originalAnchor: copyTextRangeAnchor(mark),anchorProvenance: 'range-attachment',anchorStatus: mark.anchorStatus ?? 'unchecked' } : undefined;
    await this.replaceRanges(mark, [], note);
  }

  async updateTextMarkAnchor(mark: TextMarkRecord, previousCfi: string): Promise<void> {
    const store = this.requireStore();
    await store.executeSql('UPDATE range_records SET cfi=?,prefix=?,suffix=?,chapter_title=?,revision=revision+1 ' +
      'WHERE book_id=? AND mark_id=? AND cfi=? AND resource_href=? AND exact_text=?',
      [mark.cfi, mark.prefix, mark.suffix, mark.chapterTitle, mark.bookId, mark.markId,
        previousCfi, mark.resourceHref, mark.exactText]);
    const result = await store.querySql('SELECT cfi,prefix,suffix,chapter_title FROM range_records ' +
      'WHERE book_id=? AND mark_id=?', [mark.bookId, mark.markId]);
    try {
      if (!result.goToNextRow() || result.getString(0) !== mark.cfi ||
        result.getString(1) !== mark.prefix || result.getString(2) !== mark.suffix ||
        result.getString(3) !== mark.chapterTitle) {
        throw new Error('Text mark anchor update was not accepted');
      }
    } finally { result.close(); }
  }

  async updateTextMarkRecord(mark: TextMarkRecord, previous: TextMarkRecord): Promise<void> {
    await this.replaceRanges(mark, [previous]);
  }

  async removeTextMark(bookId: string, markId: string): Promise<void> {
    await this.serial(async (): Promise<void> => {
      const store = this.requireStore();
      store.beginTransaction();
      try {
      await store.executeSql("UPDATE range_records SET highlight_active=0,highlight_anchors='[]',revision=revision+1 WHERE book_id=? AND mark_id=?", [bookId, markId]);
      await store.executeSql('DELETE FROM range_records WHERE book_id=? AND mark_id=? AND NOT EXISTS ' +
        '(SELECT 1 FROM note_entries WHERE book_id=? AND range_id=?)', [bookId,markId,bookId,markId]);
      store.commit();
      } catch (_) { store.rollBack(); throw new Error('Highlight removal failed'); }
    });
  }

  async listNotes(bookId: string): Promise<NoteEntry[]> {
    const result = await this.requireStore().querySql('SELECT note_id,book_id,range_id,body,created_at,updated_at,revision,' +
      'original_anchor_version,original_engine,original_resource_href,original_cfi,original_text,original_prefix,original_suffix,original_scope,anchor_provenance,original_status FROM note_entries WHERE book_id=? ORDER BY created_at,note_id', [bookId]);
    const notes: NoteEntry[] = [];
    try { while (result.goToNextRow()) notes.push({ noteId: result.getString(0), bookId: result.getString(1),
      rangeId: result.getString(2), body: result.getString(3), createdAt: result.getLong(4), updatedAt: result.getLong(5), revision: result.getLong(6),
      originalAnchor: {anchorVersion: result.getLong(7),engine: result.getString(8),resourceHref: result.getString(9),
        cfi: result.getString(10),exactText: result.getString(11),prefix: result.getString(12),suffix: result.getString(13),
        quoteScope: result.getString(14) === 'body' ? 'body' : 'block'},
      anchorProvenance: result.getString(15) as NoteAnchorProvenance,anchorStatus: result.getString(16) as RangeAnchorStatus }); }
    finally { result.close(); }
    return notes;
  }

  private async insertRange(store: relationalStore.RdbStore, mark: TextMarkRecord, revision: number): Promise<void> {
    const highlights = mark.highlightAnchors ?? (mark.kind === 'highlight' && mark.highlightActive !== false ? [copyTextRangeAnchor(mark)] : []);
    await store.executeSql('INSERT INTO range_records(mark_id,book_id,anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,kind,chapter_title,created_at,revision,highlight_active,anchor_status,quote_scope,highlight_anchors) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [mark.markId,mark.bookId,mark.anchorVersion,mark.engine,mark.resourceHref,mark.cfi,mark.exactText,
        mark.prefix,mark.suffix,mark.kind,mark.chapterTitle,mark.createdAt,revision,mark.highlightActive === false ? 0 : 1,mark.anchorStatus ?? 'unchecked',mark.quoteScope ?? 'block',JSON.stringify(highlights)]);
  }

  private async insertNote(store: relationalStore.RdbStore,note: NoteEntry): Promise<void> {
    const anchor = note.originalAnchor;
    if (!anchor || anchor.exactText.length < 1 || anchor.exactText.length > 32768 || anchor.cfi.length > 4096 ||
      anchor.resourceHref.length < 1 || anchor.resourceHref.length > 512 || anchor.prefix.length > 64 || anchor.suffix.length > 64 ||
      !anchor.cfi.startsWith('epubcfi(')) throw new Error('Original note anchor unavailable');
    await store.executeSql('INSERT INTO note_entries(note_id,book_id,range_id,body,created_at,updated_at,revision,' +
      'original_anchor_version,original_engine,original_resource_href,original_cfi,original_text,original_prefix,original_suffix,original_scope,anchor_provenance,original_status) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [note.noteId,note.bookId,note.rangeId,note.body,note.createdAt,note.updatedAt,note.revision,
        anchor.anchorVersion,anchor.engine,anchor.resourceHref,anchor.cfi,anchor.exactText,anchor.prefix,anchor.suffix,anchor.quoteScope,note.anchorProvenance,note.anchorStatus]);
  }

  async replaceRanges(mark: TextMarkRecord, expected: TextMarkRecord[], note?: NoteEntry,
    stillCurrent?: () => Promise<boolean>): Promise<TextMarkRecord> {
    let result: TextMarkRecord | undefined;
    await this.serial(async (): Promise<void> => {
      if (stillCurrent && !await stillCurrent()) throw new Error('Range owner unavailable');
      // ArkData querySql reads the committed snapshot. Capture current entries before the writer transaction,
      // while the existing serial queue excludes add/edit/delete/reparent mutations on this connection.
      const notes = (await this.listNotes(mark.bookId)).filter((entry: NoteEntry): boolean =>
        expected.some((previous: TextMarkRecord): boolean => previous.markId === entry.rangeId));
      const attached = notes.map((entry: NoteEntry): NoteEntry => ({ noteId: entry.noteId, bookId: entry.bookId,
        rangeId: mark.markId, body: entry.body, createdAt: entry.createdAt, updatedAt: entry.updatedAt,
        revision: entry.revision, originalAnchor: entry.originalAnchor, anchorProvenance: entry.anchorProvenance,
        anchorStatus: entry.anchorStatus }));
      if (note) attached.push(note);
      attached.sort((left: NoteEntry, right: NoteEntry): number => left.createdAt - right.createdAt || left.noteId.localeCompare(right.noteId));
      const revision = expected.length ? Math.max(...expected.map((value: TextMarkRecord): number => value.revision ?? 1)) + 1 : 1;
      const highlights = mark.highlightAnchors ?? (mark.kind === 'highlight' && mark.highlightActive !== false ? [copyTextRangeAnchor(mark)] : []);
      const store = this.requireStore();
      store.beginTransaction();
      try {
        await store.executeSql('CREATE TABLE range_write_verification (ok INTEGER NOT NULL CHECK(ok=1))');
        for (const previous of expected) {
          if (previous.bookId !== mark.bookId || previous.resourceHref !== mark.resourceHref) throw new Error('Cross-resource range union');
          await store.executeSql('INSERT INTO range_write_verification SELECT CASE WHEN EXISTS ' +
            '(SELECT 1 FROM range_records WHERE book_id=? AND mark_id=? AND revision=? AND cfi=? AND exact_text=?) THEN 1 ELSE 0 END',
            [previous.bookId,previous.markId,previous.revision ?? 1,previous.cfi,previous.exactText]);
          await store.executeSql('UPDATE note_entries SET range_id=? WHERE book_id=? AND range_id=?', [mark.markId,mark.bookId,previous.markId]);
        }
        if (this.options.failRangeCommit === 'after-reparent') throw new Error('Injected range failure');
        for (const previous of expected) await store.executeSql('DELETE FROM range_records WHERE book_id=? AND mark_id=?', [mark.bookId,previous.markId]);
        await this.insertRange(store,mark,revision);
        if (note) {
          if (note.bookId !== mark.bookId || note.rangeId !== mark.markId || note.originalAnchor.resourceHref !== mark.resourceHref) throw new Error('Note identity mismatch');
          await this.insertNote(store,note);
        }
        if (this.options.failRangeCommit === 'before-commit' || this.options.cancelled?.()) throw new Error('Range change interrupted');
        if (stillCurrent && !await stillCurrent()) throw new Error('Range owner unavailable');
        await store.executeSql('DROP TABLE range_write_verification');
        result = { markId: mark.markId, bookId: mark.bookId, anchorVersion: mark.anchorVersion, engine: mark.engine,
          resourceHref: mark.resourceHref, cfi: mark.cfi, exactText: mark.exactText, prefix: mark.prefix,
          suffix: mark.suffix, kind: attached.length > 0 ? 'note' : 'highlight', chapterTitle: mark.chapterTitle,
          noteText: attached[0]?.body ?? '', createdAt: mark.createdAt, revision: revision,
          highlightActive: mark.highlightActive !== false, anchorStatus: mark.anchorStatus ?? 'unchecked',
          quoteScope: mark.quoteScope ?? 'block', highlightAnchors: highlights, notes: attached };
        store.commit();
      } catch (_) { store.rollBack(); throw new Error('Range change failed; previous records retained'); }
    });
    return result!;
  }

  async addNote(note: NoteEntry): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const ranges = await this.listTextMarks(note.bookId);
      if (!ranges.some((mark: TextMarkRecord): boolean => mark.markId === note.rangeId && mark.resourceHref === note.originalAnchor.resourceHref)) throw new Error('Note range unavailable');
      await this.insertNote(this.requireStore(),note);
    });
  }

  async editNote(previous: NoteEntry, body: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const store = this.requireStore();
      const predicates = new relationalStore.RdbPredicates('note_entries');
      predicates.equalTo('book_id',previous.bookId).equalTo('note_id',previous.noteId)
        .equalTo('range_id',previous.rangeId).equalTo('revision',previous.revision);
      // One public writer update is atomic and returns the actual affected row count.
      // No query of the committed snapshot follows a successful write.
      const affected = await store.update({ body: body, updated_at: Date.now(), revision: previous.revision + 1 }, predicates);
      if (affected !== 1) throw new Error('Note changed; previous entry retained');
    });
  }

  async removeNote(previous: NoteEntry): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const store = this.requireStore();
      const current = (await this.listNotes(previous.bookId)).find((item: NoteEntry): boolean => item.noteId === previous.noteId);
      if (!current || current.revision !== previous.revision || current.rangeId !== previous.rangeId) throw new Error('Note changed');
      store.beginTransaction();
      try {
        await store.executeSql('DELETE FROM note_entries WHERE book_id=? AND note_id=? AND revision=?', [previous.bookId,previous.noteId,previous.revision]);
        await store.executeSql("DELETE FROM range_records WHERE book_id=? AND mark_id=? AND highlight_anchors='[]' AND NOT EXISTS " +
          '(SELECT 1 FROM note_entries WHERE book_id=? AND range_id=?)', [previous.bookId,previous.rangeId,previous.bookId,previous.rangeId]);
        if (this.options.failRangeCommit === 'before-commit' || this.options.cancelled?.()) throw new Error('Note removal interrupted');
        store.commit();
      } catch (_) { store.rollBack(); throw new Error('Note removal failed'); }
    });
  }

  async setAnchorStatus(mark: TextMarkRecord, status: RangeAnchorStatus): Promise<void> {
    await this.requireStore().executeSql('UPDATE range_records SET anchor_status=? WHERE book_id=? AND mark_id=? AND revision=?',
      [status,mark.bookId,mark.markId,mark.revision ?? 1]);
  }

  async setNoteAnchorStatus(note: NoteEntry,status: RangeAnchorStatus): Promise<void> {
    await this.serial(async (): Promise<void> => {
      await this.requireStore().executeSql('UPDATE note_entries SET original_status=? WHERE book_id=? AND note_id=? AND revision=?',
        [note.anchorProvenance === 'legacy-group' ? 'unavailable' : status,note.bookId,note.noteId,note.revision]);
    });
  }

  close(): void {
    this.store?.close();
    this.store = undefined;
  }
}
