import { Book, BookmarkPoint, NoteEntry } from '../domain/Models';
import { RecordCursor } from '../domain/ReadingRecordQuery';
import { BookmarkApplication } from './BookmarkApplication';
import { TextMarkApplication } from './TextMarkApplication';

export type RecordKind = 'notes' | 'bookmarks';
export type RecordPageAction = 'initial' | 'next' | 'previous' | 'refresh';
export interface ReadingRecordRow {
  id: string; bookId: string; book?: Book; quote: string; excerpt: string; time: number; point?: BookmarkPoint;
}
export interface ReadingRecordView {
  rows: ReadingRecordRow[]; hasNext: boolean; hasPrevious: boolean; page: number;
}
interface PageStart { cursor?: RecordCursor; }
class RecordPageCache {
  loaded: boolean = false;
  stale: boolean = false;
  request: number = 0;
  rows: ReadingRecordRow[] = [];
  start?: RecordCursor;
  next?: RecordCursor;
  previous: PageStart[] = [];
  authority?: 'source' | 'target';
  pending?: Promise<ReadingRecordView>;
}

export class ReadingRecordsApplication {
  private bookmarks: BookmarkApplication;
  private notes: TextMarkApplication;
  private books: Map<string, Book> = new Map();
  private noteCache: RecordPageCache = new RecordPageCache();
  private bookmarkCache: RecordPageCache = new RecordPageCache();
  constructor(bookmarks: BookmarkApplication, notes: TextMarkApplication) { this.bookmarks = bookmarks; this.notes = notes; }

  // Called only on a new visit from Mine. Returning from Reader retains both pages.
  begin(books: Book[]): void {
    this.books = new Map(); books.forEach((book: Book): void => { this.books.set(book.bookId, book); });
    this.noteCache = new RecordPageCache(); this.bookmarkCache = new RecordPageCache();
  }
  // A retained records visit resumes after Reader. Keep its keyset windows;
  // only reread each tab when it is next shown, including writes made in Reader.
  resume(): void {
    [this.noteCache, this.bookmarkCache].forEach((cache: RecordPageCache): void => {
      cache.stale = true; cache.request++;
    });
  }
  private cache(kind: RecordKind): RecordPageCache { return kind === 'notes' ? this.noteCache : this.bookmarkCache; }
  private view(cache: RecordPageCache): ReadingRecordView {
    return { rows: cache.rows, hasNext: cache.next !== undefined, hasPrevious: cache.previous.length > 0, page: cache.previous.length + 1 };
  }
  async load(kind: RecordKind, action: RecordPageAction = 'initial'): Promise<ReadingRecordView> {
    const cache = this.cache(kind);
    if (cache.pending && !cache.stale) return cache.pending;
    if (action === 'initial' && cache.loaded && !cache.stale) return this.view(cache);
    if (action === 'next' && !cache.next || action === 'previous' && cache.previous.length === 0) return this.view(cache);
    const pending = this.read(kind, cache, action, ++cache.request);
    cache.pending = pending;
    try { return await pending; } finally { if (cache.pending === pending) cache.pending = undefined; }
  }
  private async read(kind: RecordKind, cache: RecordPageCache, action: RecordPageAction, request: number): Promise<ReadingRecordView> {
    const cursor = action === 'next' ? cache.next : action === 'previous' ? cache.previous[cache.previous.length - 1].cursor :
      action === 'refresh' ? undefined : cache.start;
    const rows: ReadingRecordRow[] = [];
    let next: RecordCursor | undefined = undefined;
    let authority = cache.authority;
    if (kind === 'notes') {
      const page = await this.notes.notePage(cursor); next = page.next;
      page.items.forEach((note): void => { rows.push({ id: note.noteId, bookId: note.bookId, book: this.books.get(note.bookId),
        quote: note.quote, excerpt: note.excerpt, time: note.updatedAt }); });
    } else {
      const page = await this.bookmarks.page(cursor); next = page.next;
      authority = page.authority;
      page.items.forEach((point: BookmarkPoint): void => { rows.push({ id: point.bookmarkId, bookId: point.bookId,
        book: this.books.get(point.bookId), quote: point.label, excerpt: '', time: point.createdAt, point }); });
    }
    if (this.cache(kind) !== cache || cache.request !== request) return this.view(cache);
    if (kind === 'bookmarks' && cache.loaded && action !== 'refresh' && cache.authority !== authority) {
      throw new Error('Bookmark authority changed; refresh required');
    }
    if (action === 'next') cache.previous.push({ cursor: cache.start });
    else if (action === 'previous') cache.previous.pop();
    else if (action === 'refresh') cache.previous = [];
    cache.start = cursor; cache.rows = rows; cache.next = next; cache.loaded = true;
    cache.authority = authority; cache.stale = false;
    return this.view(cache);
  }
  noteDetail(row: ReadingRecordRow): Promise<NoteEntry | undefined> { return this.notes.noteDetail(row.bookId, row.id); }
}

export function recordTime(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return '时间未记录';
  const date = new Date(value);
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')} ` +
    `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}
