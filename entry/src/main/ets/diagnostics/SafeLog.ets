import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HarmonyReader';

export type SafeLogEvent = 'ability-created' | 'ability-destroyed' | 'window-created' |
  'window-destroyed' | 'foreground' | 'background' | 'content-loaded' | 'picker-requested';

export type SafeLogErrorCategory = 'color-mode' | 'keyboard-observer' |
  'keyboard-observer-stop' | 'adaptive-window-properties' | 'window-observer' |
  'window-observer-stop' | 'fold-observer' | 'fold-observer-stop' | 'content-load';

export class SafeLog {
  static readerRelayoutPosition(revision: number, visibleSlot: number, committedSlot: number,
    chapterMatches: boolean, loadedChapterMatches: boolean): void {
    hilog.info(DOMAIN, TAG,
      'reader-relayout-position revision=%{public}d visibleSlot=%{public}d committedSlot=%{public}d chapterMatches=%{public}d loadedChapterMatches=%{public}d',
      revision, visibleSlot, committedSlot, chapterMatches ? 1 : 0, loadedChapterMatches ? 1 : 0);
  }

  static readerRelayoutInput(revision: number, active: boolean, offset: number,
    peak: number, motion: number): void {
    hilog.info(DOMAIN, TAG,
      'reader-relayout-input revision=%{public}d active=%{public}d offset=%{public}d peak=%{public}d motion=%{public}d',
      revision, active ? 1 : 0, Math.round(offset), Math.round(peak), motion);
  }

  static readerRelayoutFailureDetail(slot: number, revision: number, phase: number,
    validation: number, webPhase: number): void {
    hilog.info(DOMAIN, TAG,
      'reader-relayout-detail slot=%{public}d revision=%{public}d phase=%{public}d validation=%{public}d webPhase=%{public}d',
      slot, revision, phase, validation, webPhase);
  }

  static readerRelayout(stage: 'ready' | 'failed', slot: number, revision: number,
    expectedWidth: number, expectedHeight: number, actualWidth: number, actualHeight: number,
    elapsedMs: number): void {
    hilog.info(DOMAIN, TAG,
      'reader-relayout=%{public}s slot=%{public}d revision=%{public}d expected=%{public}d,%{public}d actual=%{public}d,%{public}d elapsedMs=%{public}d',
      stage, slot, revision, Math.round(expectedWidth), Math.round(expectedHeight),
      Math.round(actualWidth), Math.round(actualHeight), Math.round(elapsedMs));
  }

  static event(event: SafeLogEvent): void {
    hilog.info(DOMAIN, TAG, 'event=%{public}s', event);
  }

  static error(category: SafeLogErrorCategory): void {
    hilog.error(DOMAIN, TAG, 'error=%{public}s', category);
  }

  static readerCandidateFailure(stage: string): void {
    const safeStage = stage.startsWith('surface-load:') ? 'surface-load' : stage;
    const allowed = ['archive', 'worker', 'source-stats', 'toc', 'first-chapter', 'reserve',
      'packet', 'packet-read', 'surface-load', 'surface-state', 'restore', 'commit'];
    hilog.error(DOMAIN, TAG, 'reader-candidate-failure=%{public}s',
      allowed.includes(safeStage) ? safeStage : 'unknown');
  }
}
