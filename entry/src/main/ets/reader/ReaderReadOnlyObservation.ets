// Optional, on-demand observation of the production Page/ReaderEngine. No UI or document command.
export interface ReaderPageObservation {
  surface: string;
  controlsVisible: boolean;
  busy: boolean;
  noteCommit: string;
  draftCharacters: number;
  focusReturnPending: boolean;
  nativeSheetPresented?: boolean;
  nativeDialogPresented?: boolean;
  nativeDialogReady?: boolean;
  nativePanelMaterial?: boolean;
  noteKeyboardVisible?: boolean;
  noteSheetPreferredDetent?: string;
  noteSheetRequestedDetent?: string;
  safeTopVp: number;
  safeBottomVp: number;
  safeLeftVp: number;
  safeRightVp: number;
  surfaceWidthVp: number;
  surfaceHeightVp: number;
  publicationTopVp: number;
  publicationHeightVp: number;
  headerSlotVp: number;
  footerSlotVp: number;
  userMarginVp: number;
  fontScale: number;
  theme: string;
  settingsCovered: boolean;
  animateMotion: boolean;
}

export interface ReaderDocumentObservation {
  ready: boolean;
  stable: boolean;
  animateMotion: boolean;
  gestureActive: boolean;
  dragging: boolean;
  moving: boolean;
  motionGeneration: number;
  navigationEpoch: number;
  resourceIndex: number;
  unit: number;
  units: number;
  layoutRevision: number;
  slot: number;
  nativeWidthVp: number;
  surfaceScrollX: number;
  contentOffsetX?: number;
  clipPagination?: boolean;
  positionValid?: boolean;
  surfaceIndex?: number;
  surfaceVersion?: number;
  slotVersion?: number;
  preparedIndices?: number[];
  preparedVersions?: number[];
  slotVersions?: number[];
  surfaceOffsetVp: number;
  nativeHeightVp: number;
  cssWidth: number;
  cssHeight: number;
  retained: boolean;
  visibleLines: number;
  clippedLines: number;
  lastBottom: number;
  paddingTop: number;
  paddingBottom: number;
  paddingLeft: number;
  paddingRight: number;
  selected: boolean;
  selectedCharacters: number;
  selectionActionable: boolean;
  selectionRevision: number;
  selectionStartX: number;
  selectionStartY: number;
  selectionEndX: number;
  selectionEndY: number;
}

export interface ReaderMotionFrameObservation {
  progress: number; moving: boolean; animateMotion: boolean; motionGeneration: number;
  layoutRevision: number; resourceIndex: number; unit: number; navigationEpoch: number;
}
export interface ReaderPreparationObservation { slot: number; resourceIndex: number; version: number; }
export interface ReaderNavigationObservation {
  phase: string; resourceIndex: number; slot: number; version: number; requestedIndex: number;
  loadedIndex: number; available: boolean; epoch: number; generation: number; unit: number;
}

export interface ReaderOwnedRangeRequest { blockIndex: number; start: number; end: number; cfi?: string; }
export interface ReaderOwnedRangeGeometry {
  blockIndex?: number;
  heading?: boolean;
  start?: number;
  end?: number;
  left: number;
  top: number;
  right: number;
  bottom: number;
  cssWidth: number;
  cssHeight: number;
}
export interface ReaderCoverageInterval { blockIndex: number; start: number; end: number; }
export interface ReaderOwnedCoverage { notes: ReaderCoverageInterval[]; highlights: ReaderCoverageInterval[]; }
export interface ReaderInputObservation { kind: string; revision: number; actionable: boolean; atMs?: number; }

export class ReaderReadOnlyObservation {
  private pageReader?: () => ReaderPageObservation;
  private documentReader?: () => Promise<ReaderDocumentObservation>;
  private rangeReader?: (request: ReaderOwnedRangeRequest) => Promise<ReaderOwnedRangeGeometry>;
  private coverageReader?: () => Promise<ReaderOwnedCoverage>;
  private inputListener?: (event: ReaderInputObservation) => void;
  private focusListener?: (kind: string) => void;
  private motionFrameListener?: (frame: ReaderMotionFrameObservation) => void;
  private preparationListener?: (state: ReaderPreparationObservation) => void;
  private navigationListener?: (state: ReaderNavigationObservation) => void;

  bindPage(reader: () => ReaderPageObservation): void { this.pageReader = reader; }
  unbindPage(): void { this.pageReader = undefined; }
  bindEngine(documentReader: () => Promise<ReaderDocumentObservation>,
    rangeReader: (request: ReaderOwnedRangeRequest) => Promise<ReaderOwnedRangeGeometry>,
    coverageReader: () => Promise<ReaderOwnedCoverage>): void {
    this.documentReader = documentReader; this.rangeReader = rangeReader; this.coverageReader = coverageReader;
  }
  unbindEngine(): void { this.documentReader = undefined; this.rangeReader = undefined; this.coverageReader = undefined; }
  page(): ReaderPageObservation { if (!this.pageReader) throw new Error('Page observation unavailable'); return this.pageReader(); }
  document(): Promise<ReaderDocumentObservation> {
    if (!this.documentReader) throw new Error('Document observation unavailable'); return this.documentReader();
  }
  ownedRange(request: ReaderOwnedRangeRequest): Promise<ReaderOwnedRangeGeometry> {
    if (!this.rangeReader || !Number.isInteger(request.blockIndex) || request.blockIndex < 0 || request.blockIndex > 512 ||
      !Number.isInteger(request.start) || !Number.isInteger(request.end) || request.start < 0 || request.end <= request.start || request.end > 4096)
      throw new Error('Owned coordinate request out of bounds');
    return this.rangeReader(request);
  }
  ownedCfiGeometry(cfi: string): Promise<ReaderOwnedRangeGeometry> {
    if (!this.rangeReader || !cfi.startsWith('epubcfi(') || cfi.length > 4096) throw new Error('Owned CFI observation invalid');
    return this.rangeReader({ blockIndex: 0, start: 0, end: 1, cfi });
  }
  ownedCoverage(): Promise<ReaderOwnedCoverage> {
    if (!this.coverageReader) throw new Error('Owned coverage observation unavailable'); return this.coverageReader();
  }
  onInput(listener?: (event: ReaderInputObservation) => void): void { this.inputListener = listener; }
  onFocus(listener?: (kind: string) => void): void { this.focusListener = listener; }
  onMotionFrame(listener?: (frame: ReaderMotionFrameObservation) => void): void { this.motionFrameListener = listener; }
  onPreparation(listener?: (state: ReaderPreparationObservation) => void): void { this.preparationListener = listener; }
  onNavigation(listener?: (state: ReaderNavigationObservation) => void): void { this.navigationListener = listener; }
  navigationObserved(state: ReaderNavigationObservation): void { try { this.navigationListener?.(state); } catch (_) {} }
  preparationObserved(state: ReaderPreparationObservation): void { try { this.preparationListener?.(state); } catch (_) {} }
  motionFrameObserved(frame: ReaderMotionFrameObservation): void { try { this.motionFrameListener?.(frame); } catch (_) {} }
  inputObserved(event: ReaderInputObservation): void {
    if (!this.inputListener) return;
    try { this.inputListener({ kind: event.kind, revision: event.revision, actionable: event.actionable, atMs: Date.now() }); } catch (_) {}
  }
  focusObserved(kind: string): void { try { this.focusListener?.(kind); } catch (_) {} }
}
