import { Book, ReadingLocation, WEB_READER_ENGINE_ID } from './Models';

// Reading format: TXT remains an EPUB reading copy (ADR 0024).
export type PublicationFormat = 'epub' | 'pdf' | 'cbz';
export interface PublicationSource {
  version: 1;
  bookId: string;
  format: PublicationFormat;
  relativePath: string;
  identity: 'managed-sha256';
}
export interface EpubLocator {
  version: 1;
  kind: 'epub';
  // Preserve the entire public engine envelope, including bare legacy CFI.
  location: ReadingLocation;
}
export interface FixedPageLocator {
  version: 1;
  kind: 'pdf' | 'cbz';
  pageIndex: number; // zero-based logical source page, never a spread number
  zoom: number; // 1 = current fit; user magnification is relative to fit
  centerX: number; // normalized page coordinate
  centerY: number;
}
export type PublicationLocator = EpubLocator | FixedPageLocator;
export interface PublicationCapabilities {
  reflow: boolean;
  fixedPage: boolean;
  outline: boolean;
  textSearch: boolean;
  textSelection: boolean;
}
export interface OpenPublicationIntent {
  sessionId: number;
  source: PublicationSource;
  locator?: PublicationLocator;
}
export type PublicationAdapter = 'epub' | 'pdf-page' | 'cbz-image';

export function legacyPublicationSource(book: Book): PublicationSource {
  return { version: 1, bookId: book.bookId, format: 'epub',
    relativePath: book.epubRelativePath, identity: 'managed-sha256' };
}
export function legacyPublicationLocator(location: ReadingLocation): EpubLocator {
  return { version: 1, kind: 'epub', location: location };
}
export function isValidFixedPageLocator(locator: FixedPageLocator): boolean {
  return locator.version === 1 && (locator.kind === 'pdf' || locator.kind === 'cbz') &&
    Number.isSafeInteger(locator.pageIndex) && locator.pageIndex >= 0 &&
    Number.isFinite(locator.zoom) && locator.zoom >= 1 && locator.zoom <= 16 &&
    Number.isFinite(locator.centerX) && locator.centerX >= 0 && locator.centerX <= 1 &&
    Number.isFinite(locator.centerY) && locator.centerY >= 0 && locator.centerY <= 1;
}
export function routePublication(intent: OpenPublicationIntent): PublicationAdapter {
  if (!Number.isSafeInteger(intent.sessionId) || intent.sessionId <= 0) {
    throw new Error('Invalid publication session');
  }
  const locator = intent.locator;
  if (locator !== undefined) {
    if (locator.kind !== intent.source.format) throw new Error('Locator format mismatch');
    if (locator.kind === 'epub') {
      if (locator.version !== 1 || locator.location.engine !== WEB_READER_ENGINE_ID) {
        throw new Error('Unsupported EPUB locator engine');
      }
    } else if (!isValidFixedPageLocator(locator)) throw new Error('Invalid page locator');
  }
  if (intent.source.format === 'epub') return 'epub';
  if (intent.source.format === 'pdf') return 'pdf-page';
  if (intent.source.format === 'cbz') return 'cbz-image';
  throw new Error('Unsupported publication format');
}

// This is a route contract, not a claim that a product adapter is installed.
// Content-dependent PDF text/outline capabilities come from the opened source.
export function publicationCapabilities(format: PublicationFormat,
  hasText: boolean, hasOutline: boolean): PublicationCapabilities {
  return { reflow: format === 'epub', fixedPage: format !== 'epub',
    outline: format !== 'cbz' && hasOutline, textSearch: format !== 'cbz' && hasText,
    textSelection: format === 'epub' && hasText };
}
