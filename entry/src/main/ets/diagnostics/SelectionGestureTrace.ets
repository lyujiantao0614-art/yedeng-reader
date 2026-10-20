import { systemDateTime } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { READER_DIAGNOSTICS_ENABLED } from 'BuildProfile';

// Temporary manual diagnosis: no book identity, text, range, locator or path.
// Event-driven only; capped for the whole process, absent from release logging.
export type SelectionTraceEvent = 'ready' | 'selected' | 'empty' | 'adjusting' | 'menu-show' | 'menu-hide' |
  'down' | 'up' | 'cancel' | 'blur-clear' | 'clear-selection' | 'tap' | 'page-request' | 'page-start' |
  'pan-start' | 'pan-release' | 'pan-cancel' | 'judge-reject' | 'judge-continue' | 'turn-start' |
  'motion-settled' | 'commit-layout' | 'commit-navigation' | 'web-scroll' | 'web-position' | 'web-stale' | 'web-unavailable' | 'mark-tap' | 'mark-accepted';
export interface SelectionTraceDom {
  outerX: number; outerY: number; innerX: number; innerY: number;
  viewport: number; selected: boolean;
}
export interface SelectionTraceState {
  session: number; chapter: number; unit: number; slot: number; layerSlot: number;
  committedChapter: number; committedUnit: number; committedSlot: number;
  epoch: number; layout: number; appX: number; dragX: number; expectedWebX: number; widthCss: number;
  selected: boolean; token: boolean; blocked: boolean; pan: boolean; dragging: boolean;
  moving: boolean; navigating: boolean; relayout: boolean; intra: boolean;
  direction: number; nativeX?: number; nativeY?: number; webEventX?: number; webEventY?: number;
  forEvent?: number; dom?: SelectionTraceDom;
}
export type NoteOverlayTraceEvent = 'note-save' | 'notes-reloaded' | 'page-mark-tap' | 'focus-reject' |
  'sheet-open' | 'sheet-closed' | 'detail-open' | 'detail-closed';
export class SelectionGestureTrace {
  private static count: number = 0;
  static enabled(): boolean { return READER_DIAGNOSTICS_ENABLED && SelectionGestureTrace.count < 1200; }
  static now(): number { return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP); }
  static noteOverlay(event: NoteOverlayTraceEvent, surface: number, count: number, found: boolean): void {
    if (!SelectionGestureTrace.enabled()) return;
    const sequence = ++SelectionGestureTrace.count;
    hilog.info(0xA11E, 'ReaderSelection', 'seq=%{public}d t_ms=%{public}d overlay=%{public}s surface=%{public}d count=%{public}d found=%{public}d',
      sequence, Math.round(SelectionGestureTrace.now()), event, surface, count, found ? 1 : 0);
  }
  static record(event: SelectionTraceEvent, state: SelectionTraceState): number {
    if (!SelectionGestureTrace.enabled()) return 0;
    const sequence = ++SelectionGestureTrace.count;
    hilog.info(0xA11E, 'ReaderSelection', 'seq=%{public}d t_ms=%{public}d event=%{public}s state=%{public}s',
      sequence, Math.round(SelectionGestureTrace.now()), event, JSON.stringify(state));
    if (sequence === 1200) hilog.info(0xA11E, 'ReaderSelection', 'trace-cap reached; restart app for another bounded capture');
    return sequence;
  }
}
