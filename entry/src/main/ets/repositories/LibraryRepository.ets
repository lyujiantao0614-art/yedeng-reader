import { common } from '@kit.AbilityKit';
import { RecordCursor, RecordPage, recordPageSize } from '../domain/ReadingRecordQuery';
import { relationalStore } from '@kit.ArkData';
import { LibraryFolder, BookOrganization, ROOT_FOLDER } from '../domain/LibraryOrganization';
import {
  Book,
  BookmarkPoint,
  BookSourceState,
  LibraryOperation,
  LibraryOperationKind,
  LibraryOperationState,
  ReadingLocation,
  ReadingProgress,
  WEB_READER_ENGINE_ID
} from '../domain/Models';

const DB_NAME: string = 'harmony_ai_reader.db';
export const LIBRARY_DB_VERSION: number = 7;

export interface LibraryRepositoryOptions {
  databaseName?: string;
  failMigrationToVersion?: number;
  failAfterVersionTo?: number;
  migrationCancelled?: () => boolean;
}

export function isValidLibraryOperationTransition(kind: LibraryOperationKind,
  state: LibraryOperationState): boolean {
  if (kind === 'delete') return state === 'requested' || state === 'files_removed';
  return state === 'preparing' || state === 'prepared';
}

export class LibraryRepository {
  private store?: relationalStore.RdbStore;
  private options: LibraryRepositoryOptions;

  constructor(options: LibraryRepositoryOptions = {}) {
    this.options = options;
  }

  async initialize(context: common.Context): Promise<void> {
    this.store = await relationalStore.getRdbStore(context, {
      name: this.options.databaseName ?? DB_NAME,
      securityLevel: relationalStore.SecurityLevel.S1
    });
    if (this.store.version > LIBRARY_DB_VERSION) {
      throw new Error('Library database was created by a newer application version');
    }
    while (this.store.version < LIBRARY_DB_VERSION) {
      await this.migrateStep(this.store.version, this.store.version + 1);
    }
  }

  private async migrateStep(fromVersion: number, toVersion: number): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      if (fromVersion === 0 && toVersion === 1) {
        await store.executeSql(`CREATE TABLE IF NOT EXISTS books (
        book_id TEXT PRIMARY KEY,
        file_hash TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        author TEXT,
        epub_relative_path TEXT NOT NULL,
        cover_relative_path TEXT,
        imported_at INTEGER NOT NULL,
        last_opened_at INTEGER
      )`);
      await store.executeSql(`CREATE TABLE IF NOT EXISTS reading_progress (
        book_id TEXT PRIMARY KEY,
        engine TEXT NOT NULL,
        locator TEXT NOT NULL,
        percentage REAL,
        chapter_id TEXT,
        updated_at INTEGER NOT NULL,
        FOREIGN KEY(book_id) REFERENCES books(book_id) ON DELETE CASCADE
      )`);
      } else if (fromVersion === 1 && toVersion === 2) {
        await store.executeSql("ALTER TABLE books ADD COLUMN source_state TEXT NOT NULL DEFAULT 'available' " +
          "CHECK(source_state IN ('available','missing'))");
        await store.executeSql(`CREATE TABLE library_operations (
          operation_id TEXT PRIMARY KEY,
          kind TEXT NOT NULL CHECK(kind IN ('import','repair','delete')),
          state TEXT NOT NULL CHECK(state IN ('preparing','prepared','requested','files_removed')),
          book_id TEXT NOT NULL UNIQUE,
          staging_token TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          CHECK((kind IN ('import','repair') AND state IN ('preparing','prepared')) OR
            (kind='delete' AND state IN ('requested','files_removed')))
        )`);
      } else if (fromVersion === 2 && toVersion === 3) {
        await store.executeSql(`CREATE TABLE bookmarks (
          bookmark_id TEXT PRIMARY KEY,
          book_id TEXT NOT NULL,
          anchor_version INTEGER NOT NULL,
          engine TEXT NOT NULL,
          resource_href TEXT NOT NULL,
          cfi TEXT NOT NULL,
          label TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          FOREIGN KEY(book_id) REFERENCES books(book_id) ON DELETE CASCADE
        )`);
        await store.executeSql('CREATE INDEX bookmarks_by_book ON bookmarks(book_id,created_at)');
      } else if (fromVersion === 3 && toVersion === 4) {
        await store.executeSql("CREATE TABLE reading_record_authority (id INTEGER PRIMARY KEY CHECK(id=1), " +
          "owner TEXT NOT NULL CHECK(owner IN ('source','target')))");
        await store.executeSql("INSERT INTO reading_record_authority(id,owner) VALUES(1,'source')");
      } else if (fromVersion === 4 && toVersion === 5) {
        await store.executeSql('ALTER TABLE reading_record_authority ADD COLUMN text_records_enabled INTEGER NOT NULL DEFAULT 0 CHECK(text_records_enabled IN (0,1))');
      } else if (fromVersion === 5 && toVersion === 6) {
        await store.executeSql("ALTER TABLE books ADD COLUMN reading_format TEXT NOT NULL DEFAULT 'epub' CHECK(reading_format IN ('epub','pdf','cbz'))");
        await store.executeSql("ALTER TABLE books ADD COLUMN source_relative_path TEXT NOT NULL DEFAULT ''");
        await store.executeSql('UPDATE books SET source_relative_path=epub_relative_path');
      } else if (fromVersion === 6 && toVersion === 7) {
        await store.executeSql('CREATE TABLE library_folders (folder_id TEXT PRIMARY KEY,parent_id TEXT NOT NULL,name TEXT NOT NULL)');
        await store.executeSql("ALTER TABLE books ADD COLUMN folder_id TEXT NOT NULL DEFAULT ''");
        await store.executeSql("ALTER TABLE books ADD COLUMN series_name TEXT NOT NULL DEFAULT ''");
        await store.executeSql('ALTER TABLE books ADD COLUMN volume_order REAL');
        await store.executeSql('ALTER TABLE reading_record_authority ADD COLUMN range_records_version INTEGER NOT NULL DEFAULT 0 CHECK(range_records_version IN (0,4))');
      } else {
        throw new Error('Unsupported library database migration');
      }
      if (this.options.failMigrationToVersion === toVersion) {
        await store.executeSql('THIS IS AN INJECTED MIGRATION FAILURE');
      }
      if (this.options.migrationCancelled?.()) throw new Error('Migration cancelled');
      store.version = toVersion;
      if (this.options.failAfterVersionTo === toVersion) throw new Error('Injected commit failure');
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Library database migration failed');
    }
  }

  private requireStore(): relationalStore.RdbStore {
    if (this.store === undefined) {
      throw new Error('Library repository is not initialized');
    }
    return this.store;
  }

  databaseVersion(): number {
    return this.requireStore().version;
  }

  async rangeRecordsVersion(): Promise<number> {
    const result = await this.requireStore().querySql('SELECT range_records_version FROM reading_record_authority WHERE id=1');
    try { if (!result.goToNextRow()) throw new Error('Record marker missing'); return result.getLong(0); }
    finally { result.close(); }
  }

  async activateRangeRecords(): Promise<void> {
    await this.requireStore().executeSql('UPDATE reading_record_authority SET range_records_version=4 WHERE id=1');
  }

  async listFolders(): Promise<LibraryFolder[]> {
    const result = await this.requireStore().querySql('SELECT folder_id,parent_id,name FROM library_folders ORDER BY name,folder_id');
    const folders: LibraryFolder[] = [];
    try { while (result.goToNextRow()) folders.push({ folderId: result.getString(0), parentId: result.getString(1), name: result.getString(2) }); }
    finally { result.close(); }
    return folders;
  }

  async listOrganizations(): Promise<BookOrganization[]> {
    const result = await this.requireStore().querySql('SELECT book_id,folder_id,series_name,volume_order FROM books');
    const values: BookOrganization[] = [];
    try { while (result.goToNextRow()) values.push({ bookId: result.getString(0), folderId: result.getString(1),
      seriesName: result.getString(2), volumeOrder: result.isColumnNull(3) ? undefined : result.getDouble(3) }); }
    finally { result.close(); }
    return values;
  }

  private async checkParent(parentId: string, movingId: string = ''): Promise<void> {
    const folders = await this.listFolders();
    if (parentId && !folders.some((item: LibraryFolder): boolean => item.folderId === parentId)) throw new Error('Parent unavailable');
    let cursor = parentId, depth = 0;
    while (cursor) {
      if (cursor === movingId || ++depth > 32) throw new Error('Folder cycle or depth limit');
      const node = folders.find((item: LibraryFolder): boolean => item.folderId === cursor);
      if (!node) throw new Error('Broken folder tree');
      cursor = node.parentId;
    }
    let descendants = [movingId], height = 0;
    if (movingId) {
      while (descendants.length) {
        descendants = folders.filter((item: LibraryFolder): boolean => descendants.includes(item.parentId))
          .map((item: LibraryFolder): string => item.folderId);
        if (descendants.length && depth + ++height >= 32) throw new Error('Folder depth limit');
      }
    }
  }

  async createFolder(folder: LibraryFolder): Promise<void> {
    await this.checkParent(folder.parentId);
    if ((await this.listFolders()).length >= 2000) throw new Error('Folder limit');
    await this.requireStore().executeSql('INSERT INTO library_folders(folder_id,parent_id,name) VALUES(?,?,?)',
      [folder.folderId, folder.parentId, folder.name]);
  }

  async renameFolder(folderId: string, name: string): Promise<void> {
    if (!(await this.listFolders()).some((item: LibraryFolder): boolean => item.folderId === folderId)) throw new Error('Folder unavailable');
    await this.requireStore().executeSql('UPDATE library_folders SET name=? WHERE folder_id=?', [name, folderId]);
  }

  async moveFolder(folderId: string, parentId: string): Promise<void> {
    if (!folderId || !(await this.listFolders()).some((item: LibraryFolder): boolean => item.folderId === folderId)) throw new Error('Folder unavailable');
    await this.checkParent(parentId, folderId);
    await this.requireStore().executeSql('UPDATE library_folders SET parent_id=? WHERE folder_id=?', [parentId, folderId]);
  }

  async deleteFolder(folderId: string, expectedIds?: string[]): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      const folders = await this.listFolders();
      if (!folderId || !folders.some((item: LibraryFolder): boolean => item.folderId === folderId)) throw new Error('Folder unavailable');
      const removed: string[] = [folderId];
      for (let index = 0; index < removed.length; index++) {
        for (const item of folders) if (item.parentId === removed[index] && !removed.includes(item.folderId)) removed.push(item.folderId);
      }
      if (expectedIds !== undefined && (expectedIds.length !== removed.length || removed.some((id: string): boolean => !expectedIds.includes(id))))
        throw new Error('Folder contents changed');
      for (const id of removed) {
        const rows = await store.querySql('SELECT COUNT(*) AS total FROM books WHERE folder_id=?', [id]);
        try { if (rows.goToFirstRow() && rows.getLong(0) > 0) throw new Error('Folder still contains books'); }
        finally { rows.close(); }
      }
      for (const id of removed) await store.executeSql('DELETE FROM library_folders WHERE folder_id=?', [id]);
      store.commit();
    } catch (_) { store.rollBack(); throw new Error('Folder removal failed'); }
  }

  async moveBook(bookId: string, folderId: string): Promise<void> {
    await this.checkParent(folderId);
    if (!await this.getBook(bookId)) throw new Error('Book unavailable');
    await this.requireStore().executeSql('UPDATE books SET folder_id=? WHERE book_id=?', [folderId, bookId]);
  }

  async setSeries(bookId: string, seriesName: string, volumeOrder?: number): Promise<void> {
    if (!await this.getBook(bookId)) throw new Error('Book unavailable');
    await this.requireStore().executeSql('UPDATE books SET series_name=?,volume_order=? WHERE book_id=?',
      [seriesName, volumeOrder ?? null, bookId]);
  }

  async bookmarkAuthority(): Promise<'source' | 'target'> {
    const result = await this.requireStore().querySql('SELECT owner FROM reading_record_authority WHERE id=1');
    try {
      if (!result.goToNextRow()) throw new Error('Bookmark authority marker missing');
      const owner = result.getString(0);
      if (owner !== 'source' && owner !== 'target') throw new Error('Bookmark authority marker invalid');
      return owner;
    } finally { result.close(); }
  }

  async textRecordsEnabled(): Promise<boolean> {
    const result = await this.requireStore().querySql(
      'SELECT text_records_enabled FROM reading_record_authority WHERE id=1');
    try {
      if (!result.goToNextRow()) throw new Error('Record authority marker missing');
      const value = result.getLong(0);
      if (value !== 0 && value !== 1) throw new Error('Record authority marker invalid');
      return value === 1;
    } finally { result.close(); }
  }

  async enableTextRecords(): Promise<void> {
    await this.requireStore().executeSql(
      'UPDATE reading_record_authority SET text_records_enabled=1 WHERE id=1');
  }

  async listAllBookmarksForMigration(): Promise<BookmarkPoint[]> {
    if (await this.bookmarkAuthority() !== 'source') throw new Error('Source bookmarks are no longer authoritative');
    const books = await this.listBooks();
    const points: BookmarkPoint[] = [];
    for (const book of books) points.push(...await this.listBookmarks(book.bookId));
    return points;
  }

  async commitBookmarkAuthorityTarget(expected: BookmarkPoint[]): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      if (await this.bookmarkAuthority() !== 'source') throw new Error('Bookmark authority already changed');
      const result = await store.querySql('SELECT bookmark_id,book_id,anchor_version,engine,' +
        'resource_href,cfi,label,created_at FROM bookmarks');
      let count = 0;
      try {
        while (result.goToNextRow()) {
          const point = expected.find((item: BookmarkPoint): boolean => item.bookmarkId === result.getString(0));
          if (point === undefined || point.bookId !== result.getString(1) ||
            point.anchorVersion !== result.getLong(2) || point.engine !== result.getString(3) ||
            point.resourceHref !== result.getString(4) || point.cfi !== result.getString(5) ||
            point.label !== result.getString(6) || point.createdAt !== result.getLong(7)) {
            throw new Error('Source bookmarks changed during migration');
          }
          count++;
        }
      }
      finally { result.close(); }
      if (count !== expected.length) throw new Error('Bookmarks changed during migration');
      await store.executeSql("UPDATE reading_record_authority SET owner='target' WHERE id=1");
      await store.executeSql('DELETE FROM bookmarks');
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Bookmark authority switch failed');
    }
  }

  close(): void {
    this.store?.close();
    this.store = undefined;
  }

  async listBooks(): Promise<Book[]> {
    const result = await this.requireStore().querySql(
      'SELECT book_id,file_hash,title,COALESCE(author,\'\'),epub_relative_path,' +
      'COALESCE(cover_relative_path,\'\'),imported_at,COALESCE(last_opened_at,0),source_state FROM books');
    const books: Book[] = [];
    try {
      while (result.goToNextRow()) {
        const author = result.getString(3);
        const cover = result.getString(5);
        const lastOpened = result.getLong(7);
        books.push({
          bookId: result.getString(0),
          fileHash: result.getString(1),
          title: result.getString(2),
          author: author.length > 0 ? author : undefined,
          epubRelativePath: result.getString(4),
          coverRelativePath: cover.length > 0 ? cover : undefined,
          importedAt: result.getLong(6),
          lastOpenedAt: lastOpened > 0 ? lastOpened : undefined,
          sourceState: result.getString(8) as BookSourceState
        });
      }
    } finally {
      result.close();
    }
    return books;
  }

  async getBook(bookId: string): Promise<Book | undefined> {
    const result = await this.requireStore().querySql(
      'SELECT book_id,file_hash,title,COALESCE(author,\'\'),epub_relative_path,' +
      'COALESCE(cover_relative_path,\'\'),imported_at,COALESCE(last_opened_at,0),source_state ' +
      'FROM books WHERE book_id=?',
      [bookId]);
    try {
      if (!result.goToNextRow()) {
        return undefined;
      }
      const author = result.getString(3);
      const cover = result.getString(5);
      const lastOpened = result.getLong(7);
      return {
        bookId: result.getString(0), fileHash: result.getString(1), title: result.getString(2),
        author: author.length > 0 ? author : undefined, epubRelativePath: result.getString(4),
        coverRelativePath: cover.length > 0 ? cover : undefined, importedAt: result.getLong(6),
        lastOpenedAt: lastOpened > 0 ? lastOpened : undefined,
        sourceState: result.getString(8) as BookSourceState
      };
    } finally {
      result.close();
    }
  }

  async insertBook(book: Book): Promise<void> {
    await this.requireStore().insert('books', {
      book_id: book.bookId,
      file_hash: book.fileHash,
      title: book.title,
      author: book.author ?? '',
      epub_relative_path: book.epubRelativePath,
      source_relative_path: book.epubRelativePath,
      cover_relative_path: book.coverRelativePath ?? '',
      imported_at: book.importedAt,
      last_opened_at: book.lastOpenedAt ?? 0,
      source_state: book.sourceState
    });
  }

  async markSourceState(bookId: string, state: BookSourceState): Promise<void> {
    await this.requireStore().executeSql('UPDATE books SET source_state=? WHERE book_id=?', [state, bookId]);
  }

  async clearCoverRelativePath(bookId: string): Promise<void> {
    await this.requireStore().executeSql("UPDATE books SET cover_relative_path='' WHERE book_id=?", [bookId]);
  }

  async markOpened(bookId: string, openedAt: number): Promise<void> {
    await this.requireStore().executeSql('UPDATE books SET last_opened_at=? WHERE book_id=?', [openedAt, bookId]);
  }

  async updateBookMetadata(bookId: string, title: string, author?: string): Promise<void> {
    await this.requireStore().executeSql('UPDATE books SET title=?,author=? WHERE book_id=?',
      [title, author ?? '', bookId]);
  }

  async getProgress(bookId: string): Promise<ReadingProgress | undefined> {
    const result = await this.requireStore().querySql(
      'SELECT engine,locator,COALESCE(percentage,-1),COALESCE(chapter_id,\'\'),updated_at ' +
      'FROM reading_progress WHERE book_id=?', [bookId]);
    try {
      if (!result.goToNextRow()) {
        return undefined;
      }
      const percentage = result.getDouble(2);
      const chapter = result.getString(3);
      const location: ReadingLocation = {
        engine: result.getString(0), locator: result.getString(1),
        percentage: percentage >= 0 ? percentage : undefined,
        chapterId: chapter.length > 0 ? chapter : undefined
      };
      return { bookId: bookId, location: location, updatedAt: result.getLong(4) };
    } finally {
      result.close();
    }
  }

  async saveProgress(progress: ReadingProgress): Promise<void> {
    await this.requireStore().executeSql(
      'INSERT OR REPLACE INTO reading_progress ' +
      '(book_id,engine,locator,percentage,chapter_id,updated_at) VALUES (?,?,?,?,?,?)',
      [progress.bookId, progress.location.engine, progress.location.locator,
        progress.location.percentage ?? -1, progress.location.chapterId ?? '', progress.updatedAt]);
  }

  async deleteBookRecords(bookId: string): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      await store.executeSql('DELETE FROM bookmarks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM reading_progress WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM books WHERE book_id=?', [bookId]);
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Book records could not be deleted');
    }
  }

  async insertBookmark(point: BookmarkPoint): Promise<void> {
    if (!/^[0-9a-f]{64}$/.test(point.bookId) || point.bookmarkId.length === 0 ||
      point.bookmarkId.length > 64 || point.engine !== WEB_READER_ENGINE_ID ||
      point.anchorVersion !== 1 ||
      point.resourceHref.length === 0 || point.resourceHref.length > 2048 ||
      !point.cfi.startsWith('epubcfi(') || !point.cfi.endsWith(')') ||
      point.cfi.length > 4096 || point.label.length > 256 ||
      !Number.isSafeInteger(point.createdAt) || point.createdAt < 0) {
      throw new Error('Invalid bookmark point');
    }
    const store = this.requireStore();
    await store.executeSql(
      'INSERT INTO bookmarks(bookmark_id,book_id,anchor_version,engine,resource_href,cfi,label,created_at) ' +
      'SELECT ?,book_id,?,?,?,?,?,? FROM books WHERE book_id=? AND EXISTS ' +
      "(SELECT 1 FROM reading_record_authority WHERE id=1 AND owner='source') AND NOT EXISTS " +
      "(SELECT 1 FROM library_operations WHERE kind='delete' AND book_id=?)",
      [point.bookmarkId, point.anchorVersion, point.engine, point.resourceHref, point.cfi,
        point.label, point.createdAt, point.bookId, point.bookId]);
    const check = await store.querySql(
      'SELECT 1 FROM bookmarks WHERE book_id=? AND bookmark_id=?', [point.bookId, point.bookmarkId]);
    try {
      if (!check.goToNextRow()) throw new Error('Bookmark book unavailable or deletion pending');
    } finally { check.close(); }
  }

  async listBookmarks(bookId: string): Promise<BookmarkPoint[]> {
    if (await this.bookmarkAuthority() !== 'source') throw new Error('Source bookmarks are no longer authoritative');
    const result = await this.requireStore().querySql(
      'SELECT bookmark_id,book_id,anchor_version,engine,resource_href,cfi,label,created_at ' +
      'FROM bookmarks WHERE book_id=? ORDER BY created_at,bookmark_id', [bookId]);
    const points: BookmarkPoint[] = [];
    try {
      while (result.goToNextRow()) points.push({
        bookmarkId: result.getString(0), bookId: result.getString(1),
        anchorVersion: result.getLong(2), engine: result.getString(3),
        resourceHref: result.getString(4), cfi: result.getString(5),
        label: result.getString(6), createdAt: result.getLong(7)
      });
    } finally { result.close(); }
    return points;
  }

  async bookmarkPage(cursor?: RecordCursor, size: number = 20): Promise<RecordPage<BookmarkPoint>> {
    try {
    if (await this.bookmarkAuthority() !== 'source') throw new Error('Source bookmarks are no longer authoritative');
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

  async deleteBookmark(bookId: string, bookmarkId: string): Promise<void> {
    if (await this.bookmarkAuthority() !== 'source') throw new Error('Source bookmarks are no longer authoritative');
    await this.requireStore().executeSql("DELETE FROM bookmarks WHERE book_id=? AND bookmark_id=? AND EXISTS " +
      "(SELECT 1 FROM reading_record_authority WHERE id=1 AND owner='source')",
      [bookId, bookmarkId]);
  }

  async createOperation(operation: LibraryOperation): Promise<void> {
    if (!isValidLibraryOperationTransition(operation.kind, operation.state)) {
      throw new Error('Invalid library operation state');
    }
    await this.requireStore().insert('library_operations', {
      operation_id: operation.operationId,
      kind: operation.kind,
      state: operation.state,
      book_id: operation.bookId,
      staging_token: operation.stagingToken ?? '',
      created_at: operation.createdAt,
      updated_at: operation.updatedAt
    });
  }

  async getOperation(operationId: string): Promise<LibraryOperation | undefined> {
    const result = await this.requireStore().querySql(
      "SELECT operation_id,kind,state,book_id,COALESCE(staging_token,''),created_at,updated_at " +
      'FROM library_operations WHERE operation_id=?', [operationId]);
    try {
      if (!result.goToNextRow()) return undefined;
      const token = result.getString(4);
      return {
        operationId: result.getString(0),
        kind: result.getString(1) as LibraryOperationKind,
        state: result.getString(2) as LibraryOperationState,
        bookId: result.getString(3),
        stagingToken: token.length > 0 ? token : undefined,
        createdAt: result.getLong(5),
        updatedAt: result.getLong(6)
      };
    } finally {
      result.close();
    }
  }

  async listOperations(): Promise<LibraryOperation[]> {
    const result = await this.requireStore().querySql(
      "SELECT operation_id,kind,state,book_id,COALESCE(staging_token,''),created_at,updated_at " +
      'FROM library_operations ORDER BY created_at,operation_id');
    const operations: LibraryOperation[] = [];
    try {
      while (result.goToNextRow()) {
        const token = result.getString(4);
        operations.push({
          operationId: result.getString(0),
          kind: result.getString(1) as LibraryOperationKind,
          state: result.getString(2) as LibraryOperationState,
          bookId: result.getString(3),
          stagingToken: token.length > 0 ? token : undefined,
          createdAt: result.getLong(5),
          updatedAt: result.getLong(6)
        });
      }
    } finally {
      result.close();
    }
    return operations;
  }

  async updateOperationState(operationId: string, state: LibraryOperationState,
    updatedAt: number): Promise<void> {
    const operation = await this.getOperation(operationId);
    if (operation === undefined || !isValidLibraryOperationTransition(operation.kind, state)) {
      throw new Error('Invalid library operation transition');
    }
    await this.requireStore().executeSql(
      'UPDATE library_operations SET state=?,updated_at=? WHERE operation_id=?',
      [state, updatedAt, operationId]);
  }

  async deleteOperation(operationId: string): Promise<void> {
    await this.requireStore().executeSql('DELETE FROM library_operations WHERE operation_id=?', [operationId]);
  }

  async commitPreparedImport(operationId: string, book: Book, targetFolderId: string = ROOT_FOLDER): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      const operation = await this.getOperation(operationId);
      if (operation?.kind !== 'import' || operation.state !== 'prepared' || operation.bookId !== book.bookId) {
        throw new Error('Prepared import does not match');
      }
      await this.checkParent(targetFolderId);
      // Membership and book publication share this transaction. Never fall back
      // to root when a captured target disappears while files are prepared.
      await store.executeSql(
        'INSERT INTO books(book_id,file_hash,title,author,epub_relative_path,source_relative_path,' +
        'cover_relative_path,imported_at,last_opened_at,source_state,folder_id) ' +
        "SELECT ?,?,?,?,?,?,?,?,?, 'available',? WHERE ?='' OR EXISTS " +
        '(SELECT 1 FROM library_folders WHERE folder_id=?)',
        [book.bookId, book.fileHash, book.title, book.author ?? '', book.epubRelativePath,
          book.epubRelativePath, book.coverRelativePath ?? '', book.importedAt, book.lastOpenedAt ?? 0,
          targetFolderId, targetFolderId, targetFolderId]);
      // querySql reads the committed snapshot, so verify through the writer's
      // affected-row count before publishing this transaction.
      const published = await store.update({ folder_id: targetFolderId },
        new relationalStore.RdbPredicates('books').equalTo('book_id', book.bookId).equalTo('folder_id', targetFolderId));
      if (published !== 1) throw new Error('Import target folder unavailable');
      await store.executeSql('DELETE FROM library_operations WHERE operation_id=?', [operationId]);
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Prepared import could not be committed');
    }
  }

  async commitPreparedRepair(operationId: string, bookId: string): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      const operation = await this.getOperation(operationId);
      if (operation?.kind !== 'repair' || operation.state !== 'prepared' || operation.bookId !== bookId) {
        throw new Error('Prepared repair does not match');
      }
      await store.executeSql("UPDATE books SET source_state='available' WHERE book_id=?", [bookId]);
      await store.executeSql('DELETE FROM library_operations WHERE operation_id=?', [operationId]);
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Prepared repair could not be committed');
    }
  }

  async completeDelete(operationId: string, bookId: string): Promise<void> {
    const store = this.requireStore();
    store.beginTransaction();
    try {
      const operation = await this.getOperation(operationId);
      if (operation?.kind !== 'delete' || operation.state !== 'files_removed' || operation.bookId !== bookId) {
        throw new Error('Prepared delete does not match');
      }
      await store.executeSql('DELETE FROM bookmarks WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM reading_progress WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM books WHERE book_id=?', [bookId]);
      await store.executeSql('DELETE FROM library_operations WHERE operation_id=?', [operationId]);
      store.commit();
    } catch (_) {
      store.rollBack();
      throw new Error('Prepared delete could not be committed');
    }
  }
}
