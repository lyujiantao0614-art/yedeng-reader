import { BookmarkPoint, ReadingLocation, WEB_READER_ENGINE_ID } from './Models';

interface SavedPointLocation {
  version: number;
  cfi: string;
  href: string;
  page?: number;
}

export function bookmarkPointFromLocation(bookmarkId: string, bookId: string,
  location: ReadingLocation, label: string, createdAt: number): BookmarkPoint | undefined {
  if (!/^[0-9a-fA-F]{64}$/.test(bookId) || bookmarkId.length === 0 || bookmarkId.length > 64 ||
    location.engine !== WEB_READER_ENGINE_ID || label.length > 256 ||
    !Number.isSafeInteger(createdAt) || createdAt < 0) return undefined;
  let saved: SavedPointLocation;
  try { saved = JSON.parse(location.locator) as SavedPointLocation; }
  catch (_) { return undefined; }
  if (saved.version !== 1 || typeof saved.href !== 'string' || saved.href.length === 0 ||
    saved.href.length > 2048 || saved.href !== location.chapterId ||
    typeof saved.cfi !== 'string' || !saved.cfi.startsWith('epubcfi(') ||
    !saved.cfi.endsWith(')') || saved.cfi.length > 4096) return undefined;
  return { bookmarkId: bookmarkId, bookId: bookId, anchorVersion: 1,
    engine: WEB_READER_ENGINE_ID, resourceHref: saved.href, cfi: saved.cfi,
    label: label, createdAt: createdAt };
}
