import { Book } from '../domain/Models';
import { LibraryEntry } from '../services/LibraryQueryService';

export interface MineLibrarySummary {
  bookCount: number;
  openedBookCount: number;
  recentBook?: Book;
}

// Derived from the shell's existing snapshot, once when that snapshot changes.
export function projectMineLibrary(entries: LibraryEntry[]): MineLibrarySummary {
  let openedBookCount = 0;
  let recentBook: Book | undefined = undefined;
  for (const entry of entries) {
    const openedAt = entry.book.lastOpenedAt;
    if (openedAt === undefined || !Number.isFinite(openedAt) || openedAt <= 0) continue;
    openedBookCount++;
    if (recentBook === undefined || openedAt > (recentBook.lastOpenedAt ?? 0) ||
      (openedAt === recentBook.lastOpenedAt && entry.book.bookId < recentBook.bookId)) {
      recentBook = entry.book;
    }
  }
  return { bookCount: entries.length, openedBookCount, recentBook };
}
