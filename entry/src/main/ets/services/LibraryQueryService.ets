import { Book } from '../domain/Models';

export type LibrarySort = 'recent' | 'title' | 'imported';

export interface LibraryEntry {
  book: Book;
  percentage: number;
}

export function filterAndSortLibrary(entries: LibraryEntry[], query: string, sort: LibrarySort): LibraryEntry[] {
  const needle = query.trim().toLocaleLowerCase();
  const filtered = entries.filter((entry) => needle.length === 0 ||
    entry.book.title.toLocaleLowerCase().includes(needle) ||
    (entry.book.author ?? '').toLocaleLowerCase().includes(needle));
  return filtered.sort((left, right) => {
    let comparison = 0;
    if (sort === 'title') {
      comparison = left.book.title.localeCompare(right.book.title);
    } else if (sort === 'imported') {
      comparison = right.book.importedAt - left.book.importedAt;
    } else {
      const leftOpened = left.book.lastOpenedAt;
      const rightOpened = right.book.lastOpenedAt;
      if (leftOpened !== undefined && rightOpened !== undefined) {
        comparison = rightOpened - leftOpened;
      } else if (leftOpened !== undefined) {
        comparison = -1;
      } else if (rightOpened !== undefined) {
        comparison = 1;
      } else {
        comparison = right.book.importedAt - left.book.importedAt;
      }
    }
    return comparison !== 0 ? comparison : left.book.bookId.localeCompare(right.book.bookId);
  });
}
