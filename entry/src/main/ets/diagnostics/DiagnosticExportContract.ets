import { util } from '@kit.ArkTS';
import {
  ReaderOpenColdWarm,
  ReaderOpenEpubSizeBucket,
  ReaderOpenErrorCategory,
  ReaderOpenRestoreDepthBucket
} from './ReaderOpenDiagnosticsContract';

export const DIAGNOSTIC_SCHEMA_VERSION: number = 1;
export const DIAGNOSTIC_MAX_BYTES: number = 64 * 1024;
export const DIAGNOSTIC_MAX_SUMMARIES: number = 128;

export type DiagnosticBuildMode = 'debug' | 'benchmark' | 'release';
export type DiagnosticDeviceClass = 'phone' | 'tablet' | 'wearable' | 'liteWearable' |
  'tv' | 'car' | 'smartVision' | 'unknown';
export type DiagnosticOpenOutcome = 'ready' | 'failed';

export interface DiagnosticMetadata {
  appVersion: string;
  api: number;
  deviceClass: DiagnosticDeviceClass;
  buildMode: DiagnosticBuildMode;
}

export interface DiagnosticTimingSummary {
  coldWarm: ReaderOpenColdWarm;
  epubSize: ReaderOpenEpubSizeBucket;
  restoreDepth: ReaderOpenRestoreDepthBucket;
  outcome: DiagnosticOpenOutcome;
  errorCategory?: ReaderOpenErrorCategory;
  totalMilliseconds: number;
}

export interface DiagnosticErrorCount {
  category: ReaderOpenErrorCategory;
  count: number;
}

export interface DiagnosticSessionSnapshot {
  summaries: DiagnosticTimingSummary[];
  errors: DiagnosticErrorCount[];
  truncated: boolean;
}

export interface DiagnosticSnapshotSource {
  exportSnapshot(): DiagnosticSessionSnapshot;
  clearExportSnapshot(): void;
}

const ERROR_CATEGORIES: ReaderOpenErrorCategory[] = [
  'book-response', 'bridge-initialization', 'bridge-page', 'bridge-protocol',
  'reader-command', 'reader-engine', 'reader-session', 'shell-page'
];
const COLD_WARM: ReaderOpenColdWarm[] = ['cold', 'warm'];
const EPUB_SIZES: ReaderOpenEpubSizeBucket[] = ['small', 'medium', 'large', 'unknown'];
const RESTORE_DEPTHS: ReaderOpenRestoreDepthBucket[] = ['start', 'shallow', 'deep', 'unknown'];
const DEVICE_CLASSES: DiagnosticDeviceClass[] = [
  'phone', 'tablet', 'wearable', 'liteWearable', 'tv', 'car', 'smartVision', 'unknown'
];
const BUILD_MODES: DiagnosticBuildMode[] = ['debug', 'benchmark', 'release'];

function boundedInteger(value: number): number {
  if (!Number.isFinite(value) || value < 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.round(value));
}

function fixedValue<T>(value: T, allowed: T[], fallback: T): T {
  for (const candidate of allowed) if (candidate === value) return candidate;
  return fallback;
}

function safeVersion(value: string): string {
  return /^[0-9][0-9A-Za-z._+-]{0,31}$/.test(value) ? value : 'unknown';
}

function sanitizedSummary(value: DiagnosticTimingSummary): DiagnosticTimingSummary {
  const outcome: DiagnosticOpenOutcome = value.outcome === 'ready' ? 'ready' : 'failed';
  const error = outcome === 'failed' ? fixedValue(value.errorCategory, ERROR_CATEGORIES,
    'reader-engine' as ReaderOpenErrorCategory) : undefined;
  return {
    coldWarm: fixedValue(value.coldWarm, COLD_WARM, 'cold' as ReaderOpenColdWarm),
    epubSize: fixedValue(value.epubSize, EPUB_SIZES, 'unknown' as ReaderOpenEpubSizeBucket),
    restoreDepth: fixedValue(value.restoreDepth, RESTORE_DEPTHS, 'unknown' as ReaderOpenRestoreDepthBucket),
    outcome: outcome,
    errorCategory: error,
    totalMilliseconds: boundedInteger(value.totalMilliseconds)
  };
}

function sanitizedErrors(values: DiagnosticErrorCount[]): DiagnosticErrorCount[] {
  return ERROR_CATEGORIES.map((category: ReaderOpenErrorCategory): DiagnosticErrorCount => {
    let count = 0;
    for (const value of values) if (value.category === category) count += boundedInteger(value.count);
    return { category: category, count: boundedInteger(count) };
  });
}

export function encodeDiagnosticSnapshot(metadata: DiagnosticMetadata,
  snapshot: DiagnosticSessionSnapshot): Uint8Array {
  const summaries = snapshot.summaries.slice(-DIAGNOSTIC_MAX_SUMMARIES).map(sanitizedSummary);
  let truncated = snapshot.truncated || snapshot.summaries.length > DIAGNOSTIC_MAX_SUMMARIES;
  const encoder = new util.TextEncoder();
  const build = (): Uint8Array => encoder.encodeInto(JSON.stringify({
    schemaVersion: DIAGNOSTIC_SCHEMA_VERSION,
    appVersion: safeVersion(metadata.appVersion),
    api: boundedInteger(metadata.api),
    deviceClass: fixedValue(metadata.deviceClass, DEVICE_CLASSES, 'unknown' as DiagnosticDeviceClass),
    buildMode: fixedValue(metadata.buildMode, BUILD_MODES, 'release' as DiagnosticBuildMode),
    truncated: truncated,
    errorCounts: sanitizedErrors(snapshot.errors),
    timingSummaries: summaries
  }));
  let bytes = build();
  while (bytes.length > DIAGNOSTIC_MAX_BYTES && summaries.length > 0) {
    summaries.shift();
    truncated = true;
    bytes = build();
  }
  if (bytes.length > DIAGNOSTIC_MAX_BYTES) throw new Error('Diagnostic snapshot exceeds fixed envelope');
  return bytes;
}
