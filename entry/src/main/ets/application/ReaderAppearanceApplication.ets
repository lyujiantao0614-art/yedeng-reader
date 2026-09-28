import {
  ReaderMotionPreference,
  ReaderThemePreference,
  SystemColorMode,
  resolveReaderSettings,
  resolveReaderTheme
} from '../domain/AppearancePolicy';
import { ReaderSettings, ReaderTheme } from '../domain/Models';
import { SystemColorModeHandler, SystemColorModeLifecycle } from '../reader/SystemColorModeLifecycle';
import { ReaderSettingsRepository } from '../repositories/ReaderSettingsRepository';

export class ReaderAppearanceApplication {
  private repository: ReaderSettingsRepository;
  private systemColorMode: SystemColorModeLifecycle;

  constructor(repository: ReaderSettingsRepository, systemColorMode: SystemColorModeLifecycle) {
    this.repository = repository;
    this.systemColorMode = systemColorMode;
  }

  loadSettings(): ReaderSettings {
    return resolveReaderSettings(this.repository.loadDefaults(), this.systemColorMode.mode());
  }

  persistentPreference(): ReaderThemePreference {
    return this.repository.loadThemePreference();
  }

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
}
