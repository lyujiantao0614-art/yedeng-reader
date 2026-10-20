import { BUILD_MODE_NAME } from 'BuildProfile';

// Temporary development diagnostic fallback only: set true, rebuild debug and
// restart the app. Never switch live surfaces or persist a pagination preference.
const DEBUG_LEGACY_PAGINATION: boolean = false;

export function useClipPagination(debugOverride?: boolean): boolean {
  // All normal product builds default to B. Only debug may compare with legacy;
  // Release/benchmark cannot select legacy via a diagnostic override.
  return (BUILD_MODE_NAME as string) === 'debug' ? (debugOverride ?? !DEBUG_LEGACY_PAGINATION) : true;
}
