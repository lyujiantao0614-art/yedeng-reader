import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BookshelfDefaultMode, BookshelfTheme, LibraryViewMode, normalizeBookshelfDefaultMode,
  normalizeBookshelfTheme,
  normalizeLibraryViewMode } from '../domain/LibraryPresentation';

const DEFAULT_STORE_NAME: string = 'library_presentation';

export interface LibraryPresentationRepositoryOptions {
  storeName?: string;
}

export class LibraryPresentationRepository {
  private storeName: string;
  private store?: preferences.Preferences;

  constructor(options?: LibraryPresentationRepositoryOptions) {
    this.storeName = options?.storeName ?? DEFAULT_STORE_NAME;
  }

  initialize(context: common.UIAbilityContext): void {
    this.store = preferences.getPreferencesSync(context, { name: this.storeName });
  }

  loadViewMode(): LibraryViewMode {
    if (this.store === undefined) return 'grid';
    const value = this.store.getSync('view_mode', 'grid');
    return normalizeLibraryViewMode(typeof value === 'string' ? value : undefined);
  }

  saveViewMode(mode: LibraryViewMode): void {
    if (this.store === undefined) return;
    this.store.putSync('view_mode', normalizeLibraryViewMode(mode));
    this.store.flushSync();
  }

  loadTheme(): BookshelfTheme {
    if (this.store === undefined) return 'default';
    const value = this.store.getSync('bookshelf_theme', 'default');
    return normalizeBookshelfTheme(typeof value === 'string' ? value : undefined);
  }

  loadDefaultMode(): BookshelfDefaultMode {
    if (this.store === undefined) return 'system';
    const value = this.store.getSync('bookshelf_default_mode', 'system');
    return normalizeBookshelfDefaultMode(typeof value === 'string' ? value : undefined);
  }

  saveAppearance(theme: BookshelfTheme, mode: BookshelfDefaultMode): void {
    if (this.store === undefined) return;
    this.store.putSync('bookshelf_theme', normalizeBookshelfTheme(theme));
    this.store.putSync('bookshelf_default_mode', normalizeBookshelfDefaultMode(mode));
    this.store.flushSync();
  }
}
