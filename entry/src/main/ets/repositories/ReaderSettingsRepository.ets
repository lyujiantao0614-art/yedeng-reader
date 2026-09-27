import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  ReaderDefaultSettings,
  ReaderMotionPreference,
  ReaderThemePreference,
  normalizeReaderMotionPreference,
  normalizeReaderThemePreference
} from '../domain/AppearancePolicy';
import { DEFAULT_READER_SETTINGS, normalizeReaderSettings, ReaderSettings } from '../domain/Models';

const DEFAULT_STORE_NAME: string = 'reader_settings';

export interface ReaderSettingsRepositoryOptions {
  storeName?: string;
}

export class ReaderSettingsRepository {
  private storeName: string;
  private store?: preferences.Preferences;

  constructor(options?: ReaderSettingsRepositoryOptions) {
    this.storeName = options?.storeName ?? DEFAULT_STORE_NAME;
  }

  initialize(context: common.UIAbilityContext): void {
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
      fontScale: Number(this.store.getSync('font_scale', DEFAULT_READER_SETTINGS.fontScale)),
      lineSpacing: Number(this.store.getSync('line_spacing', DEFAULT_READER_SETTINGS.lineSpacing)),
      pageMarginVp: Number(this.store.getSync('page_margin_vp', DEFAULT_READER_SETTINGS.pageMarginVp)),
      columnMode: this.store.getSync('column_mode', DEFAULT_READER_SETTINGS.columnMode) === 'single' ?
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
    const value = this.store.getSync('theme', 'system');
    return normalizeReaderThemePreference(typeof value === 'string' ? value : undefined);
  }

  loadMotionPreference(): ReaderMotionPreference {
    if (this.store === undefined) return 'system';
    try {
      const value = this.store.getSync('motion', 'system');
      return normalizeReaderMotionPreference(typeof value === 'string' ? value : undefined);
    } catch (_) { return 'system'; }
  }

  saveMotionPreference(preference: ReaderMotionPreference): void {
    if (this.store === undefined) return;
    try {
      this.store.putSync('motion', normalizeReaderMotionPreference(preference));
      this.store.flushSync();
    } catch (_) { throw new Error('Reader motion setting could not be saved'); }
  }

  saveLayoutDefaults(settings: ReaderSettings): void {
    if (this.store === undefined) {
      return;
    }
    this.store.putSync('font_scale', settings.fontScale);
    this.store.putSync('line_spacing', settings.lineSpacing);
    this.store.putSync('page_margin_vp', settings.pageMarginVp);
    this.store.putSync('column_mode', settings.columnMode);
    this.store.flushSync();
  }

  saveThemePreference(preference: ReaderThemePreference): void {
    if (this.store === undefined) return;
    this.store.putSync('theme', normalizeReaderThemePreference(preference));
    this.store.flushSync();
  }
}
