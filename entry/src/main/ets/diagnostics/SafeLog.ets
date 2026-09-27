import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'HarmonyReader';

export type SafeLogEvent = 'ability-created' | 'ability-destroyed' | 'window-created' |
  'window-destroyed' | 'foreground' | 'background' | 'content-loaded' | 'picker-requested';

export type SafeLogErrorCategory = 'color-mode' | 'keyboard-observer' |
  'keyboard-observer-stop' | 'adaptive-window-properties' | 'window-observer' |
  'window-observer-stop' | 'fold-observer' | 'fold-observer-stop' | 'content-load';

export class SafeLog {
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
