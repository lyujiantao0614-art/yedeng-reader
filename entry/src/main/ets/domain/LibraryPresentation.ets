export type LibraryViewMode = 'grid' | 'list';
export type BookshelfTheme = 'default' | 'starry' | 'fan-kuan' | 'earthrise';
export type BookshelfDefaultMode = 'system' | 'light' | 'dark';

export function normalizeLibraryViewMode(value?: string): LibraryViewMode {
  return value === 'list' ? 'list' : 'grid';
}

export function normalizeBookshelfTheme(value?: string): BookshelfTheme {
  if (value === 'starry' || value === 'fan-kuan' || value === 'earthrise') return value;
  return 'default';
}

export function normalizeBookshelfDefaultMode(value?: string): BookshelfDefaultMode {
  return value === 'light' || value === 'dark' ? value : 'system';
}
