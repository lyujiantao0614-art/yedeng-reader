import { ReaderColumnMode, ReaderSettings, ReaderTheme } from './Models';

export type SystemColorMode = 'light' | 'dark';
export type ReaderThemePreference = 'system' | ReaderTheme;
export type ReaderMotionPreference = 'system' | 'enabled' | 'reduced';

export function normalizeReaderMotionPreference(value?: string): ReaderMotionPreference {
  return value === 'enabled' || value === 'reduced' ? value : 'system';
}

export function animateReaderMotion(preference: ReaderMotionPreference,
  systemReduced?: boolean): boolean {
  if (preference === 'reduced') return false;
  if (preference === 'enabled') return true;
  return systemReduced !== true;
}

export interface ReaderDefaultSettings {
  fontScale: number;
  lineSpacing: number;
  pageMarginVp: number;
  columnMode: ReaderColumnMode;
  themePreference: ReaderThemePreference;
}

export function normalizeReaderThemePreference(value?: string): ReaderThemePreference {
  if (value === 'light' || value === 'dark' || value === 'eye-comfort') return value;
  return 'system';
}

export function resolveReaderTheme(preference: ReaderThemePreference,
  systemMode: SystemColorMode): ReaderTheme {
  return preference === 'system' ? systemMode : preference;
}

export function resolveReaderSettings(defaults: ReaderDefaultSettings,
  systemMode: SystemColorMode): ReaderSettings {
  return {
    fontScale: defaults.fontScale,
    lineSpacing: defaults.lineSpacing,
    pageMarginVp: defaults.pageMarginVp,
    columnMode: defaults.columnMode,
    theme: resolveReaderTheme(defaults.themePreference, systemMode)
  };
}
