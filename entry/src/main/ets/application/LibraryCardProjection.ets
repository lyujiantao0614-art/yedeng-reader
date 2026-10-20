import { LibraryEntry, LibrarySort, filterAndSortLibrary } from '../services/LibraryQueryService';
import { LibraryFolder, BookOrganization } from '../domain/LibraryOrganization';

export interface BookCardProjection {
  bookId: string;
  lastOpenedAt?: number;
  percentage?: number;
  formatLabel: string;
  formatDescription: string;
  readingLabel: string;
}
export interface FolderCoverProjection {
  bookId: string;
  coverRelativePath?: string;
}
export interface FolderCardProjection {
  folderId: string;
  directBooks: number;
  directFolders: number;
  covers: FolderCoverProjection[];
}

// A read-only presentation of known catalogue state. No guessed source format,
// end-of-book protocol, persistence or library backfill belongs to this slice.
export function projectBookCard(entry: LibraryEntry): BookCardProjection {
  const percentage = entry.percentage !== undefined && Number.isFinite(entry.percentage) &&
    entry.percentage >= 0 && entry.percentage <= 1 ? entry.percentage : undefined;
  return { bookId: entry.book.bookId, lastOpenedAt: entry.book.lastOpenedAt, percentage,
    formatLabel: 'EPUB', formatDescription: 'EPUB阅读副本；原始格式未记录',
    readingLabel: entry.book.lastOpenedAt === undefined ? '未读' :
      (percentage === undefined ? '在读' : `${Math.round(percentage * 100)}%`) };
}

// One organization/entry/sort snapshot; direct children only, unaffected by query.
export function projectFolderCards(entries: LibraryEntry[], memberships: BookOrganization[],
  folders: LibraryFolder[], sort: LibrarySort): FolderCardProjection[] {
  const parents = new Map<string, string>();
  memberships.forEach((item: BookOrganization): void => { parents.set(item.bookId, item.folderId); });
  const grouped = new Map<string, LibraryEntry[]>();
  filterAndSortLibrary(entries, '', sort).forEach((entry: LibraryEntry): void => {
    const id = parents.get(entry.book.bookId) ?? '';
    const books = grouped.get(id) ?? [];
    books.push(entry); grouped.set(id, books);
  });
  const counts = new Map<string, number>();
  folders.forEach((folder: LibraryFolder): void => { counts.set(folder.parentId, (counts.get(folder.parentId) ?? 0) + 1); });
  return folders.map((folder: LibraryFolder): FolderCardProjection => {
    const books = grouped.get(folder.folderId) ?? [];
    return { folderId: folder.folderId, directBooks: books.length, directFolders: counts.get(folder.folderId) ?? 0,
      covers: books.slice(0, 4).map((entry: LibraryEntry): FolderCoverProjection =>
        ({ bookId: entry.book.bookId, coverRelativePath: entry.book.coverRelativePath })) };
  });
}
