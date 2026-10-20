import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { BookshelfDefaultMode, BookshelfTheme, LibraryViewMode, normalizeBookshelfDefaultMode,
  normalizeBookshelfTheme,
  normalizeLibraryViewMode } from '../domain/LibraryPresentation';


interface PreferenceChange { key: string; value: preferences.ValueType; }
interface ConfirmedPreference { key: string; value: preferences.ValueType; existed: boolean; }

const DEFAULT_STORE_NAME: string = 'library_presentation';

export interface LibraryPresentationRepositoryOptions {
  storeName?: string;
}

export class LibraryPresentationRepository {
  private storeName: string;
  private store?: preferences.Preferences;

  // The Preferences cache changes before flush. Publish only confirmed values;
  // if rollback cannot flush, retry must restore it before any further write.
  private confirmed: ConfirmedPreference[] = [];
  private pendingRestore: ConfirmedPreference[] = [];

  private capture(key: string, fallback: preferences.ValueType): ConfirmedPreference {
    const confirmed = this.confirmed.find((item: ConfirmedPreference): boolean => item.key === key);
    if (confirmed !== undefined) return confirmed;
    const store = this.store;
    if (store === undefined) throw new Error('Settings store is not initialized');
    try {
      const item: ConfirmedPreference = { key: key, value: store.getSync(key, fallback), existed: store.hasSync(key) };
      this.confirmed.push(item);
      return item;
    } catch (_) { throw new Error('Library preferences could not be read'); }
  }

  private readConfirmed(key: string, fallback: preferences.ValueType): preferences.ValueType {
    if (this.store === undefined) return fallback;
    const item = this.capture(key, fallback);
    return item.existed ? item.value : fallback;
  }

  private restoreConfirmed(): void {
    const store = this.store;
    if (store === undefined) throw new Error('Settings store is not initialized');
    try {
      for (const item of this.pendingRestore) {
        if (item.existed) store.putSync(item.key, item.value);
        else store.deleteSync(item.key);
      }
      if (this.pendingRestore.length > 0) store.flushSync();
      this.pendingRestore = [];
    } catch (_) { throw new Error('Library preference recovery is still pending'); }
  }

  private saveConfirmed(changes: PreferenceChange[]): void {
    const store = this.store;
    if (store === undefined) throw new Error('Settings store is not initialized');
    this.restoreConfirmed();
    const previous = changes.map((change: PreferenceChange): ConfirmedPreference => this.capture(change.key, change.value));
    try {
      for (const change of changes) store.putSync(change.key, change.value);
      store.flushSync();
    } catch (_) {
      this.pendingRestore = previous;
      try { this.restoreConfirmed(); } catch (_) {}
      throw new Error('Settings could not be saved; last confirmed value retained');
    }
    for (const change of changes) {
      const index = this.confirmed.findIndex((item: ConfirmedPreference): boolean => item.key === change.key);
      const item: ConfirmedPreference = { key: change.key, value: change.value, existed: true };
      if (index >= 0) this.confirmed[index] = item;
      else this.confirmed.push(item);
    }
  }


  constructor(options?: LibraryPresentationRepositoryOptions) {
    this.storeName = options?.storeName ?? DEFAULT_STORE_NAME;
  }

  initialize(context: common.UIAbilityContext): void {
    if (this.pendingRestore.length > 0) this.restoreConfirmed();
    this.store = undefined; this.confirmed = []; this.pendingRestore = [];
    this.store = preferences.getPreferencesSync(context, { name: this.storeName });
  }

  loadViewMode(): LibraryViewMode {
    if (this.store === undefined) return 'grid';
    const value = this.readConfirmed('view_mode', 'grid');
    return normalizeLibraryViewMode(typeof value === 'string' ? value : undefined);
  }

  saveViewMode(mode: LibraryViewMode): void {
    this.saveConfirmed([{ key: 'view_mode', value: normalizeLibraryViewMode(mode) }]);
  }

  loadTheme(): BookshelfTheme {
    if (this.store === undefined) return 'default';
    const value = this.readConfirmed('bookshelf_theme', 'default');
    return normalizeBookshelfTheme(typeof value === 'string' ? value : undefined);
  }

  loadDefaultMode(): BookshelfDefaultMode {
    if (this.store === undefined) return 'system';
    const value = this.readConfirmed('bookshelf_default_mode', 'system');
    return normalizeBookshelfDefaultMode(typeof value === 'string' ? value : undefined);
  }

  // M4 display settings change only mode; legacy art preference remains stored.
  saveDefaultMode(mode: BookshelfDefaultMode): void {
    this.saveConfirmed([{ key: 'bookshelf_default_mode', value: normalizeBookshelfDefaultMode(mode) }]);
  }

  saveAppearance(theme: BookshelfTheme, mode: BookshelfDefaultMode): void {
    this.saveConfirmed([
      { key: 'bookshelf_theme', value: normalizeBookshelfTheme(theme) },
      { key: 'bookshelf_default_mode', value: normalizeBookshelfDefaultMode(mode) }
    ]);
  }
}
