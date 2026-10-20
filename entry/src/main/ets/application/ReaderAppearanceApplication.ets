import {
  ReaderMotionPreference,
  BookLayoutOverrides,
  ReaderLayoutParameter,
  resolveBookLayout,
  ReaderThemePreference,
  SystemColorMode,
  resolveReaderSettings,
  resolveReaderTheme
} from '../domain/AppearancePolicy';
import { ReaderSettings, ReaderTheme } from '../domain/Models';
import { SystemColorModeHandler, SystemColorModeLifecycle } from '../reader/SystemColorModeLifecycle';
import { ReaderSettingsRepository } from '../repositories/ReaderSettingsRepository';
import { observeSystemMotion } from '../platform/SystemMotionSignal';

export class ReaderAppearanceApplication {
  private repository: ReaderSettingsRepository;
  private systemColorMode: SystemColorModeLifecycle;

  constructor(repository: ReaderSettingsRepository, systemColorMode: SystemColorModeLifecycle) {
    this.repository = repository;
    this.systemColorMode = systemColorMode;
  }

  loadSettings(bookId?: string): ReaderSettings {
    const defaults = resolveReaderSettings(this.repository.loadDefaults(), this.systemColorMode.mode());
    return bookId === undefined ? defaults : resolveBookLayout(defaults, this.bookLayoutOverrides(bookId));
  }

  bookLayoutOverrides(bookId: string): BookLayoutOverrides { return this.repository.loadBookLayoutOverrides(bookId); }
  saveBookLayoutParameter(bookId: string, parameter: ReaderLayoutParameter, value: number): void {
    this.repository.saveBookLayoutParameter(bookId, parameter, value);
  }
  clearBookLayoutOverrides(bookId: string): void { this.repository.clearBookLayoutOverrides(bookId); }

  persistentPreference(): ReaderThemePreference {
    return this.repository.loadThemePreference();
  }

  // Historical storage access for compatibility fixtures. Production motion
  // no longer reads or writes this preference; preserve the original value.
  motionPreference(): ReaderMotionPreference {
    return this.repository.loadMotionPreference();
  }

  saveMotionPreference(preference: ReaderMotionPreference): void {
    this.repository.saveMotionPreference(preference);
  }

  showControlsButton(): boolean {
    return this.repository.loadShowControlsButton();
  }

  saveShowControlsButton(enabled: boolean): void {
    this.repository.saveShowControlsButton(enabled);
  }

  hideControlsButton(): boolean {
    return this.repository.loadHideControlsButton();
  }

  saveHideControlsButton(enabled: boolean): void {
    this.repository.saveHideControlsButton(enabled);
  }

  resolveTheme(): ReaderTheme {
    return resolveReaderTheme(this.persistentPreference(), this.systemColorMode.mode());
  }

  currentSystemMode(): SystemColorMode {
    return this.systemColorMode.mode();
  }

  resolveSettings(settings: ReaderSettings): ReaderSettings {
    return {
      fontScale: settings.fontScale,
      lineSpacing: settings.lineSpacing,
      pageMarginVp: settings.pageMarginVp,
      columnMode: settings.columnMode,
      theme: this.resolveTheme()
    };
  }

  saveLayoutDefaults(settings: ReaderSettings): void {
    this.repository.saveLayoutDefaults(settings);
  }

  saveThemePreference(preference: ReaderThemePreference): void {
    this.repository.saveThemePreference(preference);
  }

  subscribeSystemColorMode(handler: SystemColorModeHandler): () => void {
    return this.systemColorMode.subscribe(handler);
  }
  subscribeSystemMotion(handler: (reduced: boolean | undefined) => void): () => void {
    return observeSystemMotion(handler);
  }
}
