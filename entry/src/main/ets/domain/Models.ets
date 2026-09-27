export const WEB_READER_ENGINE_ID: string = 'web-epubjs-0.3.93';

export type BookSourceState = 'available' | 'missing';

export type LibraryOperationKind = 'import' | 'repair' | 'delete';

export type LibraryOperationState = 'preparing' | 'prepared' | 'requested' | 'files_removed';

export interface LibraryOperation {
  operationId: string;
  kind: LibraryOperationKind;
  state: LibraryOperationState;
  bookId: string;
  stagingToken?: string;
  createdAt: number;
  updatedAt: number;
}

export interface ReconciliationReport {
  resumedDeletes: number;
  rolledBackImports: number;
  rolledBackRepairs: number;
  removedStagingEntries: number;
  markedMissingSources: number;
  restoredAvailableSources: number;
  clearedMissingCovers: number;
  quarantinedOrphans: number;
  retainedQuarantinedOrphans: number;
}

export interface Book {
  bookId: string;
  fileHash: string;
  title: string;
  author?: string;
  epubRelativePath: string;
  coverRelativePath?: string;
  importedAt: number;
  lastOpenedAt?: number;
  sourceState: BookSourceState;
}

export interface ReadingLocation {
  engine: string;
  locator: string;
  percentage?: number;
  chapterId?: string;
}

export interface ReadingProgress {
  bookId: string;
  location: ReadingLocation;
  updatedAt: number;
}

export interface BookmarkPoint {
  bookmarkId: string;
  bookId: string;
  anchorVersion: number;
  engine: string;
  resourceHref: string;
  cfi: string;
  label: string;
  createdAt: number;
}

export type TextMarkKind = 'highlight' | 'note';

export interface PageBookmarkExcerpt {
  bookmarkId: string;
  bookId: string;
  excerpt: string;
}

export interface TextMarkRecord {
  markId: string;
  bookId: string;
  anchorVersion: number;
  engine: string;
  resourceHref: string;
  cfi: string;
  exactText: string;
  prefix: string;
  suffix: string;
  kind: TextMarkKind;
  chapterTitle: string;
  noteText: string;
  createdAt: number;
}

export type ReaderTheme = 'light' | 'dark' | 'eye-comfort';
export type ReaderColumnMode = 'auto' | 'single';

export interface ReaderSettings {
  fontScale: number;
  lineSpacing: number;
  pageMarginVp: number;
  theme: ReaderTheme;
  columnMode: ReaderColumnMode;
}

export const DEFAULT_READER_SETTINGS: ReaderSettings = {
  fontScale: 1.0,
  lineSpacing: 1.5,
  pageMarginVp: 20,
  theme: 'light',
  columnMode: 'auto'
};

export function normalizeReaderSettings(value?: Partial<ReaderSettings>): ReaderSettings {
  const fontScale = Number(value?.fontScale);
  const lineSpacing = Number(value?.lineSpacing);
  const pageMarginVp = Number(value?.pageMarginVp);
  const theme = value?.theme === 'dark' || value?.theme === 'eye-comfort' ? value.theme : 'light';
  const columnMode: ReaderColumnMode = value?.columnMode === 'single' ? 'single' : 'auto';
  return {
    fontScale: Number.isFinite(fontScale) ? Math.max(0.8, Math.min(1.6, fontScale)) : 1.0,
    lineSpacing: Number.isFinite(lineSpacing) ? Math.max(1.2, Math.min(2.0, lineSpacing)) : 1.5,
    pageMarginVp: Number.isFinite(pageMarginVp) ? Math.max(8, Math.min(40, pageMarginVp)) : 20,
    theme: theme,
    columnMode: columnMode
  };
}

export interface Chapter {
  id: string;
  href: string;
  label: string;
}
