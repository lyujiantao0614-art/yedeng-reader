import { Book, BookmarkPoint, PageBookmarkExcerpt, ReadingLocation } from '../domain/Models';
import { bookmarkPointFromLocation } from '../domain/BookmarkPointPolicy';
import { LibraryRepository } from '../repositories/LibraryRepository';
import { EncryptedBookmarkStore } from '../repositories/EncryptedBookmarkStore';
import { common } from '@kit.AbilityKit';
import { createSecureUuid } from '../services/ManagedBookStore';
import { TextMarkApplication } from './TextMarkApplication';
import { BookmarkRecordPage, RecordCursor } from '../domain/ReadingRecordQuery';

export interface BookmarkToggleResult {
  added: boolean;
  points: BookmarkPoint[];
}

export class BookmarkApplication {
  private repository: LibraryRepository;
  private encrypted: EncryptedBookmarkStore;
  private textMarks?: TextMarkApplication;

  constructor(repository: LibraryRepository, encrypted: EncryptedBookmarkStore = new EncryptedBookmarkStore(),
    textMarks?: TextMarkApplication) {
    this.repository = repository;
    this.encrypted = encrypted;
    this.textMarks = textMarks;
  }

  async migrateToEncrypted(context: common.Context): Promise<void> {
    if (await this.repository.bookmarkAuthority() !== 'source') throw new Error('Bookmarks already migrated');
    const points = await this.repository.listAllBookmarksForMigration();
    await this.encrypted.createForMigration(context);
    await this.encrypted.copyAndVerify(points);
    await this.repository.commitBookmarkAuthorityTarget(points);
  }

  async list(bookId: string): Promise<BookmarkPoint[]> {
    const points = await this.repository.bookmarkAuthority() === 'target' ?
      await this.encrypted.list(bookId) : await this.repository.listBookmarks(bookId);
    if (this.textMarks === undefined) return points;
    let excerpts: PageBookmarkExcerpt[];
    try { excerpts = await this.textMarks.listPageExcerpts(bookId); }
    catch (_) { return points; }
    return points.map((point: BookmarkPoint): BookmarkPoint => {
      const excerpt = excerpts.find((item: PageBookmarkExcerpt): boolean =>
        item.bookmarkId === point.bookmarkId)?.excerpt;
      if (excerpt === undefined) return point;
      return { bookmarkId: point.bookmarkId, bookId: point.bookId,
        anchorVersion: point.anchorVersion, engine: point.engine,
        resourceHref: point.resourceHref, cfi: point.cfi,
        label: `${point.label} · ${excerpt}`, createdAt: point.createdAt };
    });
  }

  async page(cursor?: RecordCursor): Promise<BookmarkRecordPage> {
    const authority = await this.repository.bookmarkAuthority();
    const page = authority === 'target' ? await this.encrypted.bookmarkPage(cursor) : await this.repository.bookmarkPage(cursor);
    if (await this.repository.bookmarkAuthority() !== authority) throw new Error('Bookmark authority changed; reload');
    return { items: page.items, next: page.next, authority };
  }

  private async bookCanReceiveBookmark(bookId: string): Promise<boolean> {
    if (await this.repository.getBook(bookId) === undefined) return false;
    return !(await this.repository.listOperations()).some((operation): boolean =>
      operation.kind === 'delete' && operation.bookId === bookId);
  }

  async toggle(book: Book, location: ReadingLocation,
    label: string, excerpt: string = ''): Promise<BookmarkToggleResult> {
    if (book.sourceState !== 'available') throw new Error('Book source unavailable');
    const point = bookmarkPointFromLocation(createSecureUuid(), book.bookId,
      location, label.slice(0, 256), Date.now());
    if (point === undefined) throw new Error('Current bookmark location unavailable');
    const existing = await this.list(book.bookId);
    const same = existing.find((item: BookmarkPoint): boolean =>
      item.engine === point.engine && item.resourceHref === point.resourceHref && item.cfi === point.cfi);
    if (same !== undefined) {
      await this.remove(book.bookId, same.bookmarkId);
      return { added: false, points: existing.filter((item: BookmarkPoint): boolean =>
        item.bookmarkId !== same.bookmarkId) };
    }
    if (await this.repository.bookmarkAuthority() === 'target') {
      this.encrypted.ensureAvailable();
      if (!await this.bookCanReceiveBookmark(book.bookId)) {
        throw new Error('Bookmark book unavailable or deletion pending');
      }
      await this.encrypted.insert(point);
      if (!await this.bookCanReceiveBookmark(book.bookId)) {
        await this.encrypted.remove(book.bookId, point.bookmarkId);
        throw new Error('Bookmark book unavailable or deletion pending');
      }
    } else { await this.repository.insertBookmark(point); }
    try {
      if (excerpt.length > 0 && this.textMarks !== undefined) {
        await this.textMarks.savePageExcerpt(book.bookId, point.bookmarkId, excerpt);
      }
    } catch (_) {
      if (await this.repository.bookmarkAuthority() === 'target') {
        await this.encrypted.remove(book.bookId, point.bookmarkId);
      } else { await this.repository.deleteBookmark(book.bookId, point.bookmarkId); }
      throw new Error('Encrypted page excerpt unavailable');
    }
    // All writes above have committed. A display refresh must not turn a saved
    // bookmark into a reported failure; return the committed point and snapshot.
    if (excerpt.length > 0 && this.textMarks !== undefined) point.label += ` · ${excerpt}`;
    return { added: true, points: [...existing, point].sort((left: BookmarkPoint, right: BookmarkPoint): number =>
      left.createdAt - right.createdAt || left.bookmarkId.localeCompare(right.bookmarkId)) };
  }

  async remove(bookId: string, bookmarkId: string): Promise<BookmarkPoint[]> {
    const existing = await this.list(bookId);
    await this.textMarks?.removePageExcerpt(bookId, bookmarkId);
    if (await this.repository.bookmarkAuthority() === 'target') {
      await this.encrypted.remove(bookId, bookmarkId);
    } else { await this.repository.deleteBookmark(bookId, bookmarkId); }
    return existing.filter((item: BookmarkPoint): boolean => item.bookmarkId !== bookmarkId);
  }
}
