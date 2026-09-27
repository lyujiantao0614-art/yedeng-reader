import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BookmarkPoint, PageBookmarkExcerpt, TextMarkRecord } from '../domain/Models';

const PRODUCTION_DB: string = 'harmony_reading_records.db';

export class EncryptedBookmarkStore {
  private databaseName: string;
  private store?: relationalStore.RdbStore;

  constructor(databaseName: string = PRODUCTION_DB) {
    if (!/^[a-z0-9_-]+\.db$/.test(databaseName)) throw new Error('Invalid record database name');
    this.databaseName = databaseName;
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
      if (opened.version < 1 || opened.version > 3) throw new Error('Unsupported record store version');
      const result = await opened.querySql('SELECT value FROM record_identity WHERE name=?', ['schema']);
      try {
        if (!result.goToNextRow() || result.getString(0) !== 'encrypted-bookmarks-v1') {
          throw new Error('Record store identity invalid');
        }
      } finally { result.close(); }
      if (opened.version === 1) await this.migrateTextMarks(opened);
      if (opened.version === 2) await this.migratePageExcerpts(opened);
      this.store = opened;
    } catch (_) {
      opened?.close();
      throw new Error('Authoritative record store unavailable');
    }
  }

  async createForMigration(context: common.Context): Promise<void> {
    this.close();
    const files = await fs.listFile(`${context.databaseDir}/rdb`);
    if (files.includes(this.databaseName)) {
      await this.openExisting(context);
      return;
    }
    const opened = await relationalStore.getRdbStore(context, {
      name: this.databaseName, securityLevel: relationalStore.SecurityLevel.S1, encrypt: true
    });
    try {
      if (opened.version !== 0) throw new Error('Unexpected record store version');
      opened.beginTransaction();
      try {
        await opened.executeSql('CREATE TABLE record_identity (name TEXT PRIMARY KEY,value TEXT NOT NULL)');
        await opened.executeSql('INSERT INTO record_identity(name,value) VALUES(?,?)',
          ['schema', 'encrypted-bookmarks-v1']);
        await opened.executeSql('CREATE TABLE bookmarks (bookmark_id TEXT PRIMARY KEY,' +
          'book_id TEXT NOT NULL,anchor_version INTEGER NOT NULL,engine TEXT NOT NULL,' +
          'resource_href TEXT NOT NULL,cfi TEXT NOT NULL,label TEXT NOT NULL,created_at INTEGER NOT NULL)');
        await opened.executeSql('CREATE INDEX bookmarks_by_book ON bookmarks(book_id,created_at)');
        opened.version = 1;
        opened.commit();
      } catch (_) { opened.rollBack(); throw new Error('Record store creation failed'); }
      await this.migrateTextMarks(opened);
      await this.migratePageExcerpts(opened);
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
      store.version = 2;
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Text record migration failed'); }
  }

  private async migratePageExcerpts(store: relationalStore.RdbStore): Promise<void> {
    store.beginTransaction();
    try {
      await store.executeSql('CREATE TABLE page_excerpts (bookmark_id TEXT PRIMARY KEY,' +
        'book_id TEXT NOT NULL,excerpt TEXT NOT NULL)');
      await store.executeSql('CREATE INDEX page_excerpts_by_book ON page_excerpts(book_id)');
      store.version = 3;
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Page excerpt migration failed'); }
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
    const store = this.requireStore();
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM bookmarks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM text_marks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM page_excerpts WHERE book_id=?', [bookId]);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Record deletion failed'); }
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
      'resource_href,cfi,exact_text,prefix,suffix,kind,chapter_title,note_text,created_at ' +
      'FROM text_marks WHERE book_id=? ORDER BY created_at,mark_id', [bookId]);
    const marks: TextMarkRecord[] = [];
    try {
      while (result.goToNextRow()) marks.push({ markId: result.getString(0), bookId: result.getString(1),
        anchorVersion: result.getLong(2), engine: result.getString(3), resourceHref: result.getString(4),
        cfi: result.getString(5), exactText: result.getString(6), prefix: result.getString(7),
        suffix: result.getString(8), kind: result.getString(9) === 'note' ? 'note' : 'highlight',
        chapterTitle: result.getString(10), noteText: result.getString(11), createdAt: result.getLong(12) });
    } finally { result.close(); }
    return marks;
  }

  async insertTextMark(mark: TextMarkRecord): Promise<void> {
    await this.requireStore().executeSql('INSERT INTO text_marks ' +
      '(mark_id,book_id,anchor_version,engine,resource_href,cfi,exact_text,prefix,suffix,' +
      'kind,chapter_title,note_text,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [mark.markId, mark.bookId, mark.anchorVersion, mark.engine, mark.resourceHref,
        mark.cfi, mark.exactText, mark.prefix, mark.suffix, mark.kind, mark.chapterTitle,
      mark.noteText, mark.createdAt]);
  }

  async updateTextMarkAnchor(mark: TextMarkRecord, previousCfi: string): Promise<void> {
    const store = this.requireStore();
    await store.executeSql('UPDATE text_marks SET cfi=?,prefix=?,suffix=?,chapter_title=? ' +
      'WHERE book_id=? AND mark_id=? AND cfi=? AND resource_href=? AND exact_text=?',
      [mark.cfi, mark.prefix, mark.suffix, mark.chapterTitle, mark.bookId, mark.markId,
        previousCfi, mark.resourceHref, mark.exactText]);
    const result = await store.querySql('SELECT cfi,prefix,suffix,chapter_title FROM text_marks ' +
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
    const store = this.requireStore();
    await store.executeSql('UPDATE text_marks SET cfi=?,exact_text=?,prefix=?,suffix=?,kind=?,chapter_title=?,note_text=? ' +
      'WHERE book_id=? AND mark_id=? AND cfi=? AND exact_text=? AND kind=?',
      [mark.cfi, mark.exactText, mark.prefix, mark.suffix, mark.kind, mark.chapterTitle, mark.noteText,
        mark.bookId, mark.markId, previous.cfi, previous.exactText, previous.kind]);
    const current = (await this.listTextMarks(mark.bookId)).find((item: TextMarkRecord): boolean =>
      item.markId === mark.markId);
    if (current === undefined || current.cfi !== mark.cfi || current.exactText !== mark.exactText ||
      current.prefix !== mark.prefix || current.suffix !== mark.suffix || current.kind !== mark.kind ||
      current.noteText !== mark.noteText) throw new Error('Text mark revision was not accepted');
  }

  async removeTextMark(bookId: string, markId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM text_marks WHERE book_id=? AND mark_id=?',
      [bookId, markId]);
  }

  close(): void {
    this.store?.close();
    this.store = undefined;
  }
}
