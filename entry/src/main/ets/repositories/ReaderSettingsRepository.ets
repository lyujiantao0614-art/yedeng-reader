import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  ReaderDefaultSettings,
  BookLayoutOverrides,
  ReaderLayoutParameter,
  normalizeBookLayoutOverrides,
  ReaderMotionPreference,
  ReaderThemePreference,
  normalizeReaderMotionPreference,
  normalizeReaderThemePreference
} from '../domain/AppearancePolicy';
import { DEFAULT_READER_SETTINGS, normalizeReaderSettings, ReaderSettings } from '../domain/Models';


interface PreferenceChange { key: string; value?: preferences.ValueType; }
interface ConfirmedPreference { key: string; value: preferences.ValueType; existed: boolean; }

const DEFAULT_STORE_NAME: string = 'reader_settings';

export interface ReaderSettingsRepositoryOptions {
  storeName?: string;
}

export class ReaderSettingsRepository {
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
    } catch (_) { throw new Error('Settings could not be read'); }
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
    } catch (_) { throw new Error('Settings recovery is still pending'); }
  }

  private saveConfirmed(changes: PreferenceChange[]): void {
    const store = this.store;
    if (store === undefined) throw new Error('Settings store is not initialized');
    this.restoreConfirmed();
    const previous = changes.map((change: PreferenceChange): ConfirmedPreference => this.capture(change.key, change.value ?? ''));
    try {
      for (const change of changes) {
        if (change.value === undefined) store.deleteSync(change.key);
        else store.putSync(change.key, change.value);
      }
      store.flushSync();
    } catch (_) {
      this.pendingRestore = previous;
      try { this.restoreConfirmed(); } catch (_) {}
      throw new Error('Settings could not be saved; last confirmed value retained');
    }
    for (const change of changes) {
      const index = this.confirmed.findIndex((item: ConfirmedPreference): boolean => item.key === change.key);
      const item: ConfirmedPreference = { key: change.key, value: change.value ?? '', existed: change.value !== undefined };
      if (index >= 0) this.confirmed[index] = item;
      else this.confirmed.push(item);
    }
  }


  constructor(options?: ReaderSettingsRepositoryOptions) {
    this.storeName = options?.storeName ?? DEFAULT_STORE_NAME;
  }

  initialize(context: common.UIAbilityContext): void {
    if (this.pendingRestore.length > 0) this.restoreConfirmed();
    this.store = undefined; this.confirmed = []; this.pendingRestore = [];
    this.store = preferences.getPreferencesSync(context, { name: this.storeName });
  }

  loadDefaults(): ReaderDefaultSettings {
    if (this.store === undefined) {
      return {
        fontScale: DEFAULT_READER_SETTINGS.fontScale,
        lineSpacing: DEFAULT_READER_SETTINGS.lineSpacing,
        pageMarginVp: DEFAULT_READER_SETTINGS.pageMarginVp,
        columnMode: DEFAULT_READER_SETTINGS.columnMode,
        themePreference: 'system'
      };
    }
    const normalized = normalizeReaderSettings({
      fontScale: Number(this.readConfirmed('font_scale', DEFAULT_READER_SETTINGS.fontScale)),
      lineSpacing: Number(this.readConfirmed('line_spacing', DEFAULT_READER_SETTINGS.lineSpacing)),
      pageMarginVp: Number(this.readConfirmed('page_margin_vp', DEFAULT_READER_SETTINGS.pageMarginVp)),
      columnMode: this.readConfirmed('column_mode', DEFAULT_READER_SETTINGS.columnMode) === 'single' ?
        'single' : 'auto'
    });
    return {
      fontScale: normalized.fontScale,
      lineSpacing: normalized.lineSpacing,
      pageMarginVp: normalized.pageMarginVp,
      columnMode: normalized.columnMode,
      themePreference: this.loadThemePreference()
    };
  }

  loadThemePreference(): ReaderThemePreference {
    if (this.store === undefined) return 'system';
    const value = this.readConfirmed('theme', 'system');
    return normalizeReaderThemePreference(typeof value === 'string' ? value : undefined);
  }

  loadMotionPreference(): ReaderMotionPreference {
    if (this.store === undefined) return 'system';
    try {
      const value = this.readConfirmed('motion', 'system');
      return normalizeReaderMotionPreference(typeof value === 'string' ? value : undefined);
    } catch (_) { return 'system'; }
  }

  saveMotionPreference(preference: ReaderMotionPreference): void {
    this.saveConfirmed([{ key: 'motion', value: normalizeReaderMotionPreference(preference) }]);
  }

  loadShowControlsButton(): boolean {
    if (this.store === undefined) return false;
    try { return this.readConfirmed('show_controls_button', false) === true; }
    catch (_) { return false; }
  }

  saveShowControlsButton(enabled: boolean): void {
    this.saveConfirmed([{ key: 'show_controls_button', value: enabled }]);
  }

  loadHideControlsButton(): boolean {
    if (this.store === undefined) return false;
    try { return this.readConfirmed('hide_controls_button', false) === true; }
    catch (_) { return false; }
  }

  saveHideControlsButton(enabled: boolean): void {
    this.saveConfirmed([{ key: 'hide_controls_button', value: enabled }]);
  }

  saveLayoutDefaults(settings: ReaderSettings): void {
    const normalized = normalizeReaderSettings(settings);
    this.saveConfirmed([
      { key: 'font_scale', value: normalized.fontScale },
      { key: 'line_spacing', value: normalized.lineSpacing },
      { key: 'page_margin_vp', value: normalized.pageMarginVp },
      { key: 'column_mode', value: normalized.columnMode }
    ]);
  }

  private bookLayoutKey(bookId: string): string {
    if (!/^[a-fA-F0-9]{64}$/.test(bookId)) throw new Error('Invalid book identity');
    return 'book_layout_v1_' + bookId;
  }

  loadBookLayoutOverrides(bookId: string): BookLayoutOverrides {
    const raw = this.readConfirmed(this.bookLayoutKey(bookId), '');
    if (typeof raw !== 'string' || raw.length === 0 || raw.length > 512) return {};
    try { return normalizeBookLayoutOverrides(JSON.parse(raw) as BookLayoutOverrides); }
    catch (_) { return {}; }
  }

  saveBookLayoutParameter(bookId: string, parameter: ReaderLayoutParameter, value: number): void {
    const next = this.loadBookLayoutOverrides(bookId);
    if (parameter === 'fontScale') next.fontScale = value;
    else if (parameter === 'lineSpacing') next.lineSpacing = value;
    else if (parameter === 'pageMarginVp') next.pageMarginVp = value;
    else throw new Error('Invalid layout parameter');
    const normalized = normalizeBookLayoutOverrides(next);
    const checked = parameter === 'fontScale' ? normalized.fontScale :
      parameter === 'lineSpacing' ? normalized.lineSpacing : normalized.pageMarginVp;
    if (checked !== value) throw new Error('Invalid layout value');
    this.saveConfirmed([{ key: this.bookLayoutKey(bookId), value: JSON.stringify(normalized) }]);
  }

  clearBookLayoutOverrides(bookId: string): void {
    const key = this.bookLayoutKey(bookId);
    this.restoreConfirmed();
    if (!this.capture(key, '').existed) return;
    this.saveConfirmed([{ key: key }]);
  }

  saveThemePreference(preference: ReaderThemePreference): void {
    this.saveConfirmed([{ key: 'theme', value: normalizeReaderThemePreference(preference) }]);
  }
}
