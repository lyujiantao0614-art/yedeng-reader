import { ReaderColumnMode, ReaderSettings, ReaderTheme } from './Models';

export type SystemColorMode = 'light' | 'dark';
export type ReaderThemePreference = 'system' | ReaderTheme;
export type ReaderMotionPreference = 'system' | 'enabled' | 'reduced';

export function normalizeReaderMotionPreference(value?: string): ReaderMotionPreference {
  return value === 'enabled' || value === 'reduced' ? value : 'system';
}

// Only an observed system signal controls this policy. API21 cannot query the
// public API23 signal; undefined retains ordinary animation without claiming
// that system reduction is disabled. Legacy preferences are storage only.
export function animateReaderMotion(systemReduced?: boolean): boolean {
  return systemReduced !== true;
}

export interface ReaderDefaultSettings {
  fontScale: number;
  lineSpacing: number;
  pageMarginVp: number;
  columnMode: ReaderColumnMode;
  themePreference: ReaderThemePreference;
}

export type ReaderLayoutParameter = 'fontScale' | 'lineSpacing' | 'pageMarginVp';

export interface BookLayoutOverrides {
  fontScale?: number;
  lineSpacing?: number;
  pageMarginVp?: number;
}

export function normalizeBookLayoutOverrides(value?: BookLayoutOverrides): BookLayoutOverrides {
  const result: BookLayoutOverrides = {};
  if (typeof value?.fontScale === 'number' && Number.isFinite(value.fontScale) &&
    value.fontScale >= 0.8 && value.fontScale <= 1.6) result.fontScale = value.fontScale;
  if (typeof value?.lineSpacing === 'number' && Number.isFinite(value.lineSpacing) &&
    value.lineSpacing >= 1.2 && value.lineSpacing <= 2) result.lineSpacing = value.lineSpacing;
  if (typeof value?.pageMarginVp === 'number' && Number.isFinite(value.pageMarginVp) &&
    value.pageMarginVp >= 8 && value.pageMarginVp <= 40) result.pageMarginVp = value.pageMarginVp;
  return result;
}

export function resolveBookLayout(settings: ReaderSettings, overrides: BookLayoutOverrides): ReaderSettings {
  return { fontScale: overrides.fontScale ?? settings.fontScale,
    lineSpacing: overrides.lineSpacing ?? settings.lineSpacing,
    pageMarginVp: overrides.pageMarginVp ?? settings.pageMarginVp,
    columnMode: settings.columnMode, theme: settings.theme };
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
