import { deviceInfo, systemDateTime } from '@kit.BasicServicesKit';
import { hilog, hiTraceMeter } from '@kit.PerformanceAnalysisKit';
import {
  READER_BENCHMARK_ENABLED,
  READER_DIAGNOSTICS_ENABLED
} from 'BuildProfile';
import {
  ReaderOpenErrorCategory,
  ReaderOpenScenario,
  ReaderOpenStage,
  isWebReaderOpenStage
} from './ReaderOpenDiagnosticsContract';
import {
  DIAGNOSTIC_MAX_SUMMARIES,
  DiagnosticErrorCount,
  DiagnosticSessionSnapshot,
  DiagnosticSnapshotSource,
  DiagnosticTimingSummary
} from './DiagnosticExportContract';

const DOMAIN: number = 0xA11E;
const TAG: string = 'ReaderOpen';
const TRACE_NAME: string = 'ReaderOpen';
const ERROR_CATEGORIES: ReaderOpenErrorCategory[] = [
  'book-response', 'bridge-initialization', 'bridge-page', 'bridge-protocol',
  'reader-command', 'reader-engine', 'reader-session', 'shell-page'
];

interface ActiveReaderOpenRun {
  sessionId: number;
  runId: string;
  startedAt: number;
  lastEventAt: number;
  scenario: ReaderOpenScenario;
  seenStages: ReaderOpenStage[];
}

function monotonicMilliseconds(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP);
}

function coarseDeviceClass(value: string): string {
  if (value === 'default' || value === 'phone') return 'phone';
  if (value === 'tablet' || value === 'wearable' || value === 'liteWearable' ||
    value === 'tv' || value === 'car' || value === 'smartVision') {
    return value;
  }
  return 'unknown';
}

export class ReaderOpenDiagnostics implements DiagnosticSnapshotSource {
  private active?: ActiveReaderOpenRun;
  private runSequence: number = 0;
  private summaries: DiagnosticTimingSummary[] = [];
  private errorCounts: Map<ReaderOpenErrorCategory, number> = new Map();
  private summariesTruncated: boolean = false;

  begin(sessionId: number, scenario: ReaderOpenScenario): void {
    if (!Number.isSafeInteger(sessionId) || sessionId <= 0) return;
    if (READER_DIAGNOSTICS_ENABLED && this.active !== undefined) {
      hiTraceMeter.finishTrace(TRACE_NAME, this.active.sessionId);
    }
    this.runSequence += 1;
    const now = monotonicMilliseconds();
    this.active = {
      sessionId: sessionId,
      runId: `run-${this.runSequence}`,
      startedAt: now,
      lastEventAt: now,
      scenario: scenario,
      seenStages: []
    };
    if (READER_DIAGNOSTICS_ENABLED) hiTraceMeter.startTrace(TRACE_NAME, sessionId);
    this.mark(sessionId, 'open_requested');
  }

  updateScenario(sessionId: number, scenario: ReaderOpenScenario): void {
    if (this.active?.sessionId !== sessionId) return;
    this.active.scenario = scenario;
  }

  markWebStage(sessionId: number, stage: string): void {
    if (!isWebReaderOpenStage(stage)) return;
    this.mark(sessionId, stage as ReaderOpenStage);
  }

  mark(sessionId: number, stage: ReaderOpenStage, category?: ReaderOpenErrorCategory): void {
    const run = this.active;
    if (run === undefined || run.sessionId !== sessionId) return;
    for (const seen of run.seenStages) {
      if (seen === stage) return;
    }
    run.seenStages.push(stage);
    const now = monotonicMilliseconds();
    const elapsed = Math.max(0, Math.round(now - run.startedAt));
    const delta = Math.max(0, Math.round(now - run.lastEventAt));
    run.lastEventAt = now;
    if (READER_DIAGNOSTICS_ENABLED) {
      hilog.info(DOMAIN, TAG,
        'event=%{public}s run=%{public}s session=%{public}d elapsed_ms=%{public}d delta_ms=%{public}d mode=%{public}s cold_warm=%{public}s epub_size=%{public}s restore_depth=%{public}s api=%{public}d device=%{public}s',
        stage, run.runId, sessionId, elapsed, delta,
        READER_BENCHMARK_ENABLED ? 'benchmark' : 'debug',
        run.scenario.coldWarm, run.scenario.epubSize, run.scenario.restoreDepth,
        deviceInfo.sdkApiVersion, coarseDeviceClass(deviceInfo.deviceType));
    }
    if (stage === 'reader_ready' || stage === 'open_failed') {
      const errorCategory = stage === 'open_failed' ? category ?? 'reader-engine' : undefined;
      this.summaries.push({
        coldWarm: run.scenario.coldWarm,
        epubSize: run.scenario.epubSize,
        restoreDepth: run.scenario.restoreDepth,
        outcome: stage === 'reader_ready' ? 'ready' : 'failed',
        errorCategory: errorCategory,
        totalMilliseconds: elapsed
      });
      if (this.summaries.length > DIAGNOSTIC_MAX_SUMMARIES) {
        this.summaries.shift();
        this.summariesTruncated = true;
      }
      if (errorCategory !== undefined) {
        this.errorCounts.set(errorCategory, (this.errorCounts.get(errorCategory) ?? 0) + 1);
      }
      if (READER_DIAGNOSTICS_ENABLED) hiTraceMeter.finishTrace(TRACE_NAME, sessionId);
      this.active = undefined;
    }
  }

  fail(sessionId: number, category: ReaderOpenErrorCategory): void {
    this.mark(sessionId, 'open_failed', category);
    if (READER_DIAGNOSTICS_ENABLED) {
      hilog.error(DOMAIN, TAG,
        'reader_open_error category=%{public}s api=%{public}d device=%{public}s',
        category, deviceInfo.sdkApiVersion, coarseDeviceClass(deviceInfo.deviceType));
    }
  }

  exportSnapshot(): DiagnosticSessionSnapshot {
    const errors: DiagnosticErrorCount[] = ERROR_CATEGORIES.map(
      (category: ReaderOpenErrorCategory): DiagnosticErrorCount =>
        ({ category: category, count: this.errorCounts.get(category) ?? 0 }));
    return { summaries: this.summaries.slice(), errors: errors, truncated: this.summariesTruncated };
  }

  clearExportSnapshot(): void {
    this.summaries = [];
    this.errorCounts.clear();
    this.summariesTruncated = false;
  }
}

export const readerOpenDiagnostics: ReaderOpenDiagnostics = new ReaderOpenDiagnostics();
