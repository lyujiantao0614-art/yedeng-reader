import { NativeSelectionMenuMaterial } from '../platform/NativeOverlayMaterial';
import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { ReaderReadOnlyObservation, ReaderDocumentObservation, ReaderOwnedRangeRequest, ReaderOwnedRangeGeometry, ReaderOwnedCoverage } from './ReaderReadOnlyObservation';
import { webview } from '@kit.ArkWeb';
import { AnimatorResult } from '@ohos.animator';
import { SafeLog } from '../diagnostics/SafeLog';
import { SelectionGestureTrace, SelectionTraceDom, SelectionTraceEvent, SelectionTraceState } from '../diagnostics/SelectionGestureTrace';
import { Book, BookmarkPoint, Chapter, ReaderSettings, ReadingLocation, WEB_READER_ENGINE_ID } from '../domain/Models';
import { createProductionImportPolicy } from '../services/ProductionImportPolicy';
import { ReaderCommand, ReaderEngineCallbacks, ReaderEngineController, ReaderInternalLinkKind,
  ReaderTextMark, ReaderTextMarkResolution } from './ReaderEngine';
import { ReadingSelectionContext, VerifiedRangeUnion } from './ReadingSelectionModels';
import { SelectionContactGate } from './SelectionContactGate';
import { ReaderSelectionRect } from './ReaderSelectionModels';
import { ReaderPreparationJob, ReaderSurfaceBridge, ReaderSurfaceState } from './ReaderSurfaceBridge';
import { ReaderSurfaceResources } from './ReaderSurfaceResources';
import { PublicationTextSession } from '../application/PublicationTextSession';
import { SectionText, SectionTextProvider } from '../domain/SectionText';
import { DerivedSectionTextCache } from './DerivedSectionTextCache';
import { readerApplicationLifecycle, ReaderApplicationLifecycleHandler } from './ReaderApplicationLifecycle';
import { useClipPagination } from './ReaderPaginationPolicy';

class PublicationLifecycleHandler implements ReaderApplicationLifecycleHandler {
  private background: () => void;
  private foreground: () => void;
  constructor(background: () => void, foreground: () => void) { this.background = background; this.foreground = foreground; }
  onBackground(): void { this.background(); }
  onForeground(): void { this.foreground(); }
}

interface ReaderSourceBounds {
  archiveBytes: number;
  entryCount: number;
  entryBytes: number;
  expandedBytes: number;
  sectionBytes: number;
}

interface ReaderSignal {
  session: number;
  resolve: () => void;
  reject: (error: Error) => void;
  timer: number;
}

interface SourceInfo {
  chapterHrefs: string[];
  chapterCfiBases: string[];
  chapterSizes: number[];
}

interface SignalWait {
  token: number;
  done: Promise<void>;
}

interface SurfaceConfigureResult {
  token: number;
  state: ReaderSurfaceState;
}

interface SavedLocator {
  cfi: string;
  href: string;
  page: number;
}

interface CommittedPosition { slot: number; index: number; unit: number; }
interface SurfaceLayoutPosition { slot: number; offset: number; }

interface SurfaceSelectionMessage {
  text: string;
  cfi: string;
  left: number;
  top: number;
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
}

interface SurfaceContextMessage {
  text: string;
  cfi: string;
  currentText: string;
  rangeText?: string;
  prefix?: string;
  suffix?: string;
  quoteScope?: 'block' | 'body';
  rangeUnion?: VerifiedRangeUnion;
  markConflict?: 'overlap' | 'unavailable';
}
interface SurfaceMarkTapMessage extends ReaderSelectionRect { markId: string; }
interface SurfaceLinkMessage { type: string; href: string; kind?: ReaderInternalLinkKind; }
interface ReaderReturnEntry { location: ReadingLocation; kind?: ReaderInternalLinkKind; }

const SOURCE_LIMIT: number = 6 * 1024 * 1024;
const SIGNAL_TIMEOUT_MS: number = 20000;
const RELAYOUT_TIMEOUT_MS: number = 3000;

async function runSurfaceScript(controller: webview.WebviewController, script: string): Promise<string> {
  try { return await controller.runJavaScript(script); }
  catch (error) { throw error instanceof Error ? error : new Error('Reader surface script failed'); }
}

function textMarkWithCfi(mark: ReaderTextMark, cfi: string): ReaderTextMark {
  return { markId: mark.markId, bookId: mark.bookId, anchorVersion: mark.anchorVersion,
    engine: mark.engine, kind: mark.kind, resourceHref: mark.resourceHref, cfi: cfi,
    exactText: mark.exactText, prefix: mark.prefix, suffix: mark.suffix,
    quoteScope: mark.quoteScope, revision: mark.revision, highlightActive: mark.highlightActive,
    noteAnchors: mark.noteAnchors,highlightAnchors: mark.highlightAnchors };
}

interface NoteResolutionReply extends ReaderTextMarkResolution {
  noteId: string;
  revision: number;
}

function scrollSurface(controller: webview.WebviewController, x: number, y: number): void {
  try { controller.scrollTo(x, y); }
  catch (error) { throw error instanceof Error ? error : new Error('Reader surface scroll failed'); }
}

// The production ReaderEngine view. The single-Web predecessor is archived locally.
@Component
export struct ReaderFourSurfaceView {
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  book: Book = { bookId: '', fileHash: '', title: '', epubRelativePath: '', importedAt: 0,
    sourceState: 'available' };
  initialLocation?: ReadingLocation;
  settings: ReaderSettings = { fontScale: 1, lineSpacing: 1.5, pageMarginVp: 20,
    theme: 'light', columnMode: 'auto' };
  sessionId: number = 0;
  // Optional development comparison only. Normal entries use the build policy.
  debugClipPaginationOverride?: boolean;
  private clipPagination: boolean = false;
  private presentationUpdate: Promise<string> = Promise.resolve('');
  @Prop @Watch('onMotionPreferenceChanged') animateCustomMotion: boolean = true;
  controller: ReaderEngineController = new ReaderEngineController();
  callbacks: ReaderEngineCallbacks = {
    onReady: (): void => {}, onTableOfContents: (): void => {}, onLocation: (): void => {},
    onWordSelection: (): void => {}, onPassageSelection: (): void => {},
    onSelectionAdjusting: (): void => {}, onSelectionContext: (): void => {},
    onSelectionContextRejected: (): void => {}, onSelectionRejected: (): void => {},
    onSelectionCleared: (): void => {}, onSelectionGeometryChanged: (): void => {},
    onControlsToggle: (): void => {}, onLinkState: (): void => {},
    onExternalLinkRequest: (): void => {}, onBackRequested: (): void => {},
    onError: (): void => {}
  };
  onCandidateStage: (stage: string) => void = (): void => {};
  selectionMenuMarks: ReaderTextMark[] = [];
  readOnlyObservation?: ReaderReadOnlyObservation;
  @Prop selectionMenuAdjusting: boolean = false;
  private selectionGate: SelectionContactGate = new SelectionContactGate();
  private nativeSelectionRevision: number = 0;
  private nativeSelectionCancelled: boolean = false;
  private pendingNativeSelection: string = '';
  @State private nativeSelectionEnglish: boolean = false;
  @State private nativeSelectionNarrow: boolean = false;
  private highlightRevision: number = -1;
  private highlightSession: number = -1;
  private highlightGeneration: number = -1;
  private highlightNavigationEpoch: number = -1;
  private highlightSlot: number = -1;
  private highlightSlotVersion: number = -1;
  private highlightLayoutRevision: number = -1;
  private highlightPresentationClear: boolean = false;
  private highlightPresentationPending: boolean = false;
  private highlightRequested: boolean = false;
  private highlightContextPending: boolean = false;
  private highlightContext?: ReadingSelectionContext;
  private highlightText: string = '';
  private highlightToken: string = '';
  publication: PublicationTextSession = new PublicationTextSession();
  private textReadToken: number = 0;
  private textCache?: DerivedSectionTextCache;
  private unsubscribeLifecycle?: () => void;

  private controllers: webview.WebviewController[] = [new webview.WebviewController(),
    new webview.WebviewController(), new webview.WebviewController(), new webview.WebviewController()];
  private sourceController: webview.WebviewController = new webview.WebviewController();
  private sourceShellLoaded: boolean = false;
  private openingSource: boolean = false;
  private shellWaiters: Map<number, Array<() => void>> = new Map();
  private bridge: ReaderSurfaceBridge = new ReaderSurfaceBridge();
  private resources?: ReaderSurfaceResources;
  private loadedShells: boolean[] = [false, false, false, false];
  private loadedCount: number = 0;
  private sourceInfo?: SourceInfo;
  private signals: Map<number, ReaderSignal> = new Map();
  private nextSignal: number = 0;
  private generation: number = 0;
  private activeSession: number = 0;
  private alive: boolean = true;
  private chapterIndices: number[] = [-1, -1, -1, -1];
  private requestedIndices: number[] = [-1, -1, -1, -1];
  private slotVersions: number[] = [0, 0, 0, 0];
  private sourceSizes: number[] = [0, 0, 0, 0];
  private units: number[] = [1, 1, 1, 1];
  private layoutWidths: number[] = [1, 1, 1, 1];
  private layoutHeights: number[] = [1, 1, 1, 1];
  private webViewportWidths: number[] = [0, 0, 0, 0];
  private webViewportHeights: number[] = [0, 0, 0, 0];
  private slotLayoutRevisions: number[] = [0, 0, 0, 0];
  private configureTokens: Array<number | undefined> = [undefined, undefined, undefined, undefined];
  private positions: number[] = [0, 0, 0, 0];
  private positionVersions: number[] = [-1, -1, -1, -1];
  private available: boolean[] = [false, false, false, false];
  private loadTasks: Array<Promise<void> | undefined> = [undefined, undefined, undefined, undefined];
  private jobs: ReaderPreparationJob[] = [];
  private preparing: boolean = false;
  private activePreparation?: ReaderPreparationJob;
  private preparationSignals: Set<number> = new Set();
  private pendingNavigation: number = 0;
  private navigating: boolean = false;
  private navigationEpoch: number = 0;
  private initialLocator: string = '';
  private committed?: ReadingLocation;
  private committedPosition?: CommittedPosition;
  private openStage: string = 'shell';
  private selectedSlots: boolean[] = [false, false, false, false];
  private selectionTracePending: boolean = false;
  private selectionTraceQueued: number = 0;
  private selectionTraceScrollAt: number = -1;
  private selectionTraceAdjusting: boolean = false;
  private blockedSlots: boolean[] = [false, false, false, false];
  private selectionRevision: number = 0;
  private selectionToken: string = '';
  private selectionText: string = '';
  private selectionCfi: string = '';
  private returnStack: ReaderReturnEntry[] = [];
  private linkNavigationInFlight: boolean = false;
  private activeLinkKind?: ReaderInternalLinkKind;
  private externalLinkRequestId: number = 0;
  private motion?: AnimatorResult;
  private motionGeneration: number = 0;
  private motionDirection: number = 0;
  private moving: boolean = false;
  private dragging: boolean = false;
  private intraChapterMotion: boolean = false;
  private gestureBaseOffset: number = 0;
  private gestureDx: number = 0;
  private gesturePeak: number = 0;
  private gestureStartRevision: number = 0;
  private gestureActive: boolean = false;
  private gestureDuringRelayout: boolean = false;
  private layoutRevision: number = 0;
  @State private relayouting: boolean = false;
  @State private relayoutFailed: boolean = false;
  private relayoutPassRunning: boolean = false;
  private pendingRelayout: boolean = false;
  private queuedRelayoutTurn: string = '';
  private relayoutSignals: Set<number> = new Set();
  @State private stagingSlots: boolean[] = [false, false, false, false];
  @State private currentSlot: number = 0;
  @State private chapterIndex: number = 0;
  @State private pageUnit: number = 0;
  @State private viewportWidth: number = 0;
  @State private viewportHeight: number = 0;
  private dragOffset: number = 0;
  @State private surfaceLayout: SurfaceLayoutPosition = { slot: 0, offset: 0 };
  @State private ready: boolean = false;
  @State private readable: boolean = false;
  @State private readerBackground: string = '#fafbfc';

  aboutToAppear(): void {
    this.clipPagination = useClipPagination(this.debugClipPaginationOverride);
    this.readOnlyObservation?.bindEngine((): Promise<ReaderDocumentObservation> => this.readOnlyDocumentObservation(),
      (request: ReaderOwnedRangeRequest): Promise<ReaderOwnedRangeGeometry> => this.readOnlyRangeGeometry(request),
      (): Promise<ReaderOwnedCoverage> => this.readOnlyOwnedCoverage());
    this.unsubscribeLifecycle = readerApplicationLifecycle.subscribe(new PublicationLifecycleHandler(
      (): void => this.pausePreparation(), (): void => { if (this.ready) this.prepareAround(1); }));
    this.bridge.onCatalog = (raw: string): boolean => this.alive &&
      (this.resources?.archive.register(raw) ?? false);
    this.bridge.onSourceDone = (token: number, ready: boolean): void => this.finishSignal(token, ready);
    this.bridge.onPacketDone = (token: number, ready: boolean): void => this.finishSignal(token, ready);
    this.bridge.onLoadDone = (_slot: number, token: number, ready: boolean): void =>
      this.finishSignal(token, ready);
    this.bridge.onLayoutDone = (_slot: number, token: number, ready: boolean): void =>
      this.finishSignal(token, ready);
    this.bridge.onViewportChanged = (slot: number, width: number, height: number): void => {
      if (slot < 0 || slot >= 4 || !Number.isFinite(width) || !Number.isFinite(height)) return;
      this.webViewportWidths[slot] = width;
      this.webViewportHeights[slot] = height;
      if (!this.ready || this.relayoutPassRunning || slot !== this.currentSlot ||
        Math.abs(width - this.viewportWidth) > 2 || Math.abs(height - this.viewportHeight) > 2) return;
      if (!this.slotLayoutCurrent(slot)) this.requestRelayout();
    };
    this.bridge.onSelection = (slot: number, selected: boolean): void => {
      if (slot < 0 || slot >= 4) return;
      const wasSelected = this.selectedSlots[slot];
      this.selectedSlots[slot] = selected;
      if (slot === this.currentSlot && wasSelected !== selected) this.traceSelection(selected ? 'selected' : 'empty', true);
      if (slot === this.currentSlot) this.observeActualSelectionInput(selected ? 'selection-present' : 'selection-empty');
      if (slot === this.currentSlot && wasSelected && !selected && this.selectionToken.length > 0) {
        this.highlightPresentationClear = this.highlightPresentationPending && this.selectionHighlightValid(this.activeSession);
        try { this.dispatch({ type: 'clearSelection' }); }
        finally { this.highlightPresentationClear = false; }
      }
    };
    this.bridge.onBlock = (slot: number, blocked: boolean): void => {
      if (slot >= 0 && slot < 4) this.blockedSlots[slot] = blocked;
    };
    this.bridge.onTap = (slot: number, region: number): void => {
      if (!this.ready || slot !== this.currentSlot || this.blockedSlots[slot]) return;
      this.traceSelection('tap', true, region);
      if (this.selectionToken.length > 0) {
        this.dispatch({ type: 'clearSelection' });
        return;
      }
      if (this.selectedSlots[slot]) return;
      if (region < 0) this.page(-1);
      else if (region > 0) this.page(1);
      else this.callbacks.onControlsToggle(this.activeSession);
    };
    this.bridge.onMarkTap = (slot: number, raw: string): void => {
      this.traceSelection('mark-tap', false);
      this.readOnlyObservation?.focusObserved('body-mark-bridge');
      if (!this.ready || slot !== this.currentSlot || this.blockedSlots[slot] || raw.length > 500) return;
      let tap: SurfaceMarkTapMessage;
      try { tap = JSON.parse(raw) as SurfaceMarkTapMessage; } catch (_) { return; }
      if (!tap || typeof tap.markId !== 'string' || tap.markId.length > 160 ||
        !Number.isFinite(tap.left) || !Number.isFinite(tap.top) ||
        !Number.isFinite(tap.width) || !Number.isFinite(tap.height)) return;
      this.traceSelection('mark-accepted', false);
      this.callbacks.onTextMarkTap?.(this.activeSession, tap.markId, tap);
    };
    this.bridge.onSelectionEvent = (slot: number, raw: string): void => this.selectionEvent(slot, raw);
    this.bridge.onSelectionAdjusting = (slot: number): void => {
      if (this.ready && slot === this.currentSlot && this.selectionToken.length > 0) {
        if (!this.selectionTraceAdjusting) { this.selectionTraceAdjusting = true; this.traceSelection('adjusting', true); }
        this.callbacks.onSelectionAdjusting(this.activeSession);
      }
    };
    this.bridge.onLink = (slot: number, raw: string): void => this.linkEvent(slot, raw);
    this.activeSession = this.sessionId;
    this.selectionGate.reset(this.activeSession, true);
    this.initialLocator = this.initialLocation?.engine === WEB_READER_ENGINE_ID ?
      this.initialLocation.locator : '';
    this.updateBackground(this.settings);
    this.controller.bind((command: ReaderCommand): void => this.dispatch(command));
  }

  aboutToDisappear(): void {
    this.readOnlyObservation?.unbindEngine();
    this.revokeSelectionHighlight();
    this.selectionGate.cancel(this.activeSession);
    this.alive = false;
    this.unsubscribeLifecycle?.();
    this.controller.unbind();
    this.invalidate();
    this.resources?.close();
    this.bridge.clearPacket();
    runSurfaceScript(this.sourceController, 'Source.close()').catch((): void => {});
  }

  private updateBackground(settings: ReaderSettings): void {
    this.readerBackground = settings.theme === 'dark' ? '#172029' :
      (settings.theme === 'eye-comfort' ? '#e8dfc9' : '#fafbfc');
  }

  private applyReaderSettings(settings: ReaderSettings): void {
    const geometryChanged = this.settings.fontScale !== settings.fontScale ||
      this.settings.lineSpacing !== settings.lineSpacing ||
      this.settings.pageMarginVp !== settings.pageMarginVp || this.settings.columnMode !== settings.columnMode;
    const themeChanged = this.settings.theme !== settings.theme;
    this.settings = settings;
    this.updateBackground(settings);
    if (geometryChanged) {
      this.requestRelayout();
    } else if (themeChanged) {
      const generation = this.generation;
      const script = `Surface.applyTheme(${JSON.stringify(settings.theme)})`;
      this.controllers.forEach((controller: webview.WebviewController, slot: number): void => {
        if (!this.loadedShells[slot]) return;
        runSurfaceScript(controller, script).catch((): void => {
          if (this.alive && generation === this.generation && slot === this.currentSlot) {
            this.callbacks.onError(this.activeSession, 'reader-command');
          }
        });
      });
    }
  }

  private invalidate(): void {
    this.revokeSelectionHighlight();
    this.selectionGate.cancel(this.activeSession);
    this.generation++;
    this.publication.close(this.activeSession);
    this.textReadToken = 0;
    this.textCache = undefined;
    this.shellWaiters.forEach((waiters: Array<() => void>): void =>
      waiters.forEach((resolve: () => void): void => resolve()));
    this.shellWaiters.clear();
    this.navigationEpoch++;
    this.motionGeneration++;
    this.motion?.cancel();
    this.motion = undefined;
    this.moving = false;
    this.dragging = false;
    this.gestureActive = false;
    this.gestureDuringRelayout = false;
    this.queuedRelayoutTurn = '';
    this.stagingSlots = [false, false, false, false];
    this.configureTokens = [undefined, undefined, undefined, undefined];
    this.relayoutSignals.clear();
    this.relayouting = false;
    this.relayoutFailed = false;
    this.intraChapterMotion = false;
    this.settleSurface(this.currentSlot);
    this.pendingNavigation = 0;
    this.linkNavigationInFlight = false;
    for (const signal of this.signals.values()) {
      clearTimeout(signal.timer);
      signal.reject(new Error('Obsolete reader session'));
    }
    this.signals.clear();
    this.jobs.forEach((job: ReaderPreparationJob): void => job.resolve());
    this.jobs = [];
    this.loadTasks = [undefined, undefined, undefined, undefined];
    for (let slot = 0; slot < 4; slot++) {
      this.slotVersions[slot]++;
      this.resources?.setVersion(slot, this.slotVersions[slot]);
    }
  }

  private awaitSignal(session: number, timeoutMs: number = SIGNAL_TIMEOUT_MS): SignalWait {
    const token = ++this.nextSignal;
    const done = new Promise<void>((resolve, reject): void => {
      const timer = setTimeout((): void => {
        this.signals.delete(token);
        reject(new Error('Reader readiness timeout'));
      }, timeoutMs);
      this.signals.set(token, { session, resolve, reject, timer });
    });
    return { token, done };
  }

  private finishSignal(token: number, ready: boolean): void {
    const signal = this.signals.get(token);
    if (signal === undefined) return;
    this.signals.delete(token);
    clearTimeout(signal.timer);
    if (!this.alive || signal.session !== this.generation || !ready) {
      signal.reject(new Error('Reader operation failed'));
    } else {
      signal.resolve();
    }
  }

  private shellLoaded(slot: number): void {
    if (!this.alive || this.loadedShells[slot]) return;
    this.loadedShells[slot] = true;
    this.loadedCount++;
    this.shellWaiters.get(slot)?.forEach((resolve: () => void): void => resolve());
    this.shellWaiters.delete(slot);
    this.beginSource();
  }

  private beginSource(): void {
    if (this.sourceShellLoaded && this.loadedShells[0] && !this.openingSource) {
      this.openingSource = true;
      const generation = this.generation;
      this.openSource().catch((): void => {
        if (!this.alive || generation !== this.generation) return;
        this.onCandidateStage(this.openStage);
        this.callbacks.onError(this.activeSession, 'reader-engine');
      });
    }
  }

  private async openSource(): Promise<void> {
    if (!this.alive || !this.sourceShellLoaded || !this.loadedShells[0]) return;
    const session = this.generation;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const resource = new ReaderSurfaceResources(`${context.filesDir}/${this.book.epubRelativePath}`,
      this.activeSession);
    this.resources?.close();
    this.resources = resource;
    this.ready = false;
    this.readable = false;
    this.openStage = 'archive';
    await resource.archive.open();
    if (!this.alive || session !== this.generation) return;
    const policy = createProductionImportPolicy();
    const bounds: ReaderSourceBounds = {
      archiveBytes: policy.zip.archiveBytes,
      entryCount: policy.zip.entryCount,
      entryBytes: policy.zip.entryBytes,
      expandedBytes: policy.zip.expandedBytes,
      sectionBytes: policy.resources.sectionBytes
    };
    const signal = this.awaitSignal(session);
    this.openStage = 'worker';
    await runSurfaceScript(this.sourceController, `void Source.open(${JSON.stringify(resource.base + 'book.epub')},${JSON.stringify(bounds)},${signal.token})`);
    await signal.done;
    if (!this.alive || session !== this.generation) return;
    this.openStage = 'source-stats';
    const stats = JSON.parse(JSON.parse(await runSurfaceScript(this.sourceController, 'JSON.stringify(Source.sourceStats())')) as string) as SourceInfo;
    if (!Array.isArray(stats.chapterHrefs) || stats.chapterHrefs.length === 0 ||
      stats.chapterHrefs.length !== stats.chapterSizes.length ||
      stats.chapterHrefs.length !== stats.chapterCfiBases.length) throw new Error('Invalid source chapters');
    this.sourceInfo = stats;
    this.textCache = new DerivedSectionTextCache(context.cacheDir,
      `${context.filesDir}/${this.book.epubRelativePath}`, this.book.bookId);
    const provider: SectionTextProvider = { read: (index: number): Promise<SectionText> => this.readSectionText(index) };
    this.publication.bind(this.activeSession, provider);
    this.openStage = 'toc';
    const toc = JSON.parse(JSON.parse(await runSurfaceScript(this.sourceController, 'JSON.stringify(Source.toc)')) as string) as Chapter[];
    if (Array.isArray(toc) && toc.length <= 2000) {
      const chapters = toc.map((chapter: Chapter): Chapter => ({
        id: chapter.id, href: chapter.href,
        label: chapter.label.replace(/\s+/g, ' ').trim(),
        depth: chapter.depth
      }));
      this.callbacks.onTableOfContents(this.activeSession, chapters);
    }
    const saved = this.parseLocator(this.initialLocator);
    let initialIndex = saved.href.length > 0 ? stats.chapterHrefs.findIndex((href: string): boolean =>
      href === saved.href || href.endsWith(saved.href)) : -1;
    if (initialIndex < 0 && saved.cfi.length > 0) {
      initialIndex = stats.chapterCfiBases.findIndex((base: string): boolean =>
        base.length > 0 && saved.cfi.includes(`${base}!`));
    }
    initialIndex = Math.max(0, initialIndex);
    this.openStage = 'first-chapter';
    await this.load(0, initialIndex, 0);
    if (!this.alive || session !== this.generation || !this.available[0]) return;
    this.currentSlot = 0;
    this.settleSurface(0);
    this.chapterIndex = initialIndex;
    let unit = saved.page - 1;
    if (saved.cfi.length > 0) {
      const value = Number(await runSurfaceScript(this.controllers[0], `Surface.unitForCfi(${JSON.stringify(saved.cfi)})`));
      if (Number.isInteger(value) && value >= 0) unit = value;
    }
    this.pageUnit = Math.min(this.units[0] - 1, Math.max(0, unit));
    this.openStage = 'restore';
    await this.seek(0, this.pageUnit, session);
    if (!this.alive || session !== this.generation) return;
    await runSurfaceScript(this.controllers[0], `Surface.revealRestored(${this.pageUnit})`);
    if (!this.alive || session !== this.generation) return;
    this.readable = true;
    this.callbacks.onFirstReadable?.(this.activeSession);
    this.openStage = 'commit';
    await this.commit('layout');
    if (!this.alive || session !== this.generation) return;
    this.ready = true;
    this.traceSelection('ready', true);
    const readyEpoch = this.navigationEpoch;
    this.callbacks.onReady(this.activeSession);
    // onReady may synchronously start an initial-bookmark navigation. Its target
    // owns preparation now; startup must not replace that slot with a neighbour.
    if (!this.alive || session !== this.generation || readyEpoch !== this.navigationEpoch) return;
    this.prepareAround(1);
  }

  private parseLocator(value: string): SavedLocator {
    if (value.startsWith('epubcfi(') && value.length <= 4096) {
      return { cfi: value, href: '', page: 1 };
    }
    try {
      const saved = JSON.parse(value) as SavedLocator;
      return { cfi: typeof saved.cfi === 'string' && saved.cfi.length <= 4096 ? saved.cfi : '',
        href: typeof saved.href === 'string' && saved.href.length <= 2048 ? saved.href : '',
        page: Number.isInteger(saved.page) && (saved.page ?? 0) > 0 ? saved.page! : 1 };
    } catch (_) { return { cfi: '', href: '', page: 1 }; }
  }

  private async readSectionText(index: number): Promise<SectionText> {
    if (!this.sourceInfo || index >= this.sourceInfo.chapterHrefs.length || this.textReadToken !== 0) {
      throw new Error('Section text unavailable or busy');
    }
    const generation = this.generation;
    const cache = this.textCache;
    const cached = await cache?.read(index, this.sourceInfo.chapterHrefs[index]);
    if (generation !== this.generation) throw new Error('Obsolete section cache');
    if (cached !== undefined) return cached;
    const signal = this.awaitSignal(generation);
    this.textReadToken = signal.token;
    try {
      await runSurfaceScript(this.sourceController, `Source.startText(${index},${signal.token})`);
      await signal.done;
      const raw = JSON.parse(await runSurfaceScript(this.sourceController, 'JSON.stringify(Source.textResult)')) as string;
      if (generation !== this.generation || raw.length > SOURCE_LIMIT) throw new Error('Obsolete or oversized section');
      const section = JSON.parse(raw) as SectionText;
      if (section.version !== 1 || section.extractor !== 'body-text-1' || section.index !== index ||
        section.href !== this.sourceInfo.chapterHrefs[index] || !Array.isArray(section.runs) ||
        section.runs.length > 20000 || typeof section.text !== 'string' || section.text.length > 2 * 1024 * 1024) {
        throw new Error('Invalid section text');
      }
      await cache?.write(section, (): boolean => this.alive && generation === this.generation);
      return section;
    } finally {
      if (this.textReadToken === signal.token) this.textReadToken = 0;
      if (generation === this.generation) runSurfaceScript(this.sourceController, 'Source.textResult=null').catch((): void => {});
    }
  }

  private async releaseSlot(slot: number, replacing: boolean = false): Promise<void> {
    if (this.ready && (slot === this.currentSlot ||
      (this.clipPagination && slot === this.committedPosition?.slot))) throw new Error('Current chapter is protected');
    this.available[slot] = false;
    this.positionVersions[slot] = -1;
    this.chapterIndices[slot] = -1;
    this.sourceSizes[slot] = 0;
    if (!replacing) {
      this.slotVersions[slot]++;
      this.resources?.setVersion(slot, this.slotVersions[slot]);
    }
    await runSurfaceScript(this.controllers[slot], 'Surface.releaseChapter()');
  }

  private async reserve(slot: number, size: number, version: number): Promise<boolean> {
    if (!Number.isSafeInteger(size) || size <= 0 || size > SOURCE_LIMIT) throw new Error('Chapter source bound');
    if (this.sourceSizes[slot] > 0) await this.releaseSlot(slot, true);
    if (slot !== this.currentSlot && this.sourceSizes[this.currentSlot] + size > SOURCE_LIMIT) {
      throw new Error('Current and target source bound');
    }
    let total = this.sourceSizes.reduce((sum: number, value: number): number => sum + value, 0);
    while (total + size > SOURCE_LIMIT) {
      let victim = -1;
      let distance = -1;
      for (let index = 0; index < 4; index++) {
        if (index === slot || index === this.currentSlot || this.sourceSizes[index] === 0 ||
          (this.clipPagination && index === this.committedPosition?.slot)) continue;
        const difference = Math.abs(this.chapterIndices[index] - this.chapterIndex);
        if (difference > distance) { victim = index; distance = difference; }
      }
      if (victim < 0) throw new Error('Protected chapter source bound');
      await this.releaseSlot(victim);
      total = this.sourceSizes.reduce((sum: number, value: number): number => sum + value, 0);
    }
    if (!this.alive || version !== this.slotVersions[slot]) return false;
    this.sourceSizes[slot] = size;
    return true;
  }

  private async load(slot: number, index: number, priority: number,
    initialAtEnd: boolean = false): Promise<void> {
    if (this.relayouting) throw new Error('Reader relayout in progress');
    if (!this.sourceInfo || index < 0 || index >= this.sourceInfo.chapterHrefs.length) return;
    if (priority === 0) this.yieldPreparation(slot, index);
    if (this.available[slot] && this.chapterIndices[slot] === index) {
      if (this.slotLayoutCurrent(slot)) return;
      // A background resize may be waiting on an offscreen Web viewport. A turn
      // takes ownership of this slot instead of inheriting that wait.
      await this.configureSlot(slot, this.layoutRevision, this.viewportWidth, this.viewportHeight, '');
      if (this.slotLayoutCurrent(slot)) return;
      throw new Error('Reader surface has stale viewport');
    }
    if (this.requestedIndices[slot] === index && this.loadTasks[slot]) {
      this.jobs.forEach((job: ReaderPreparationJob): void => {
        if (job.slot === slot && job.index === index) job.priority = Math.min(job.priority, priority);
      });
      return this.loadTasks[slot];
    }
    const version = ++this.slotVersions[slot];
    const generation = this.generation;
    this.available[slot] = false;
    this.positionVersions[slot] = -1;
    this.requestedIndices[slot] = index;
    this.resources?.setVersion(slot, version);
    await runSurfaceScript(this.controllers[slot], 'Surface.cancelLoad()');
    if (this.clipPagination && (!this.alive || generation !== this.generation || version !== this.slotVersions[slot])) return;
    this.jobs = this.jobs.filter((job: ReaderPreparationJob): boolean => {
      if (job.slot !== slot) return true;
      job.resolve();
      return false;
    });
    const task = new Promise<void>((resolve, reject): void => {
      this.jobs.push({ slot, index, version, priority, initialAtEnd, resolve, reject });
      this.callbacks.onPreparationState?.(this.activeSession, this.jobs.length, this.preparing ? 1 : 0);
    });
    this.loadTasks[slot] = task;
    task.then((): void => {
      if (this.loadTasks[slot] === task) this.loadTasks[slot] = undefined;
    }, (): void => {
      if (this.loadTasks[slot] === task) this.loadTasks[slot] = undefined;
    });
    if (!this.preparing) this.pump().catch((): void => {});
    await task;
  }

  private async pump(): Promise<void> {
    this.preparing = true;
    try {
      while (this.jobs.length > 0 && this.alive) {
        this.jobs.sort((a: ReaderPreparationJob, b: ReaderPreparationJob): number => a.priority - b.priority);
        const job = this.jobs.shift();
        if (job === undefined) break;
        this.activePreparation = job;
        this.readOnlyObservation?.preparationObserved({ slot: job.slot, resourceIndex: job.index, version: job.version });
        this.callbacks.onPreparationState?.(this.activeSession, this.jobs.length, 1);
        try {
          await this.prepare(job);
          job.resolve();
        } catch (error) {
          job.reject(error as Error);
        } finally {
          this.activePreparation = undefined;
          this.preparationSignals.clear();
          this.callbacks.onPreparationState?.(this.activeSession, this.jobs.length, 0);
        }
      }
    } finally {
      this.preparing = false;
    }
  }

  private onMotionPreferenceChanged(): void {
    const contact = this.gestureActive;
    if (!contact && !this.dragging && !this.moving) return;
    this.motionGeneration++;
    this.motion?.cancel(); this.motion = undefined;
    this.moving = false; this.dragging = false; this.gestureActive = false;
    this.gestureDuringRelayout = false; this.intraChapterMotion = false; this.motionDirection = 0;
    this.gestureBaseOffset = 0; this.gestureDx = 0; this.gesturePeak = 0;
    this.restoreCommitted();
    if (contact) this.callbacks.onContactState?.(this.activeSession, 'cancelled');
  }

  private pausePreparation(): void {
    this.dispatch({ type: 'clearSelection' });
    if (!this.ready) return;
    const contact = this.gestureActive;
    this.navigationEpoch++;
    this.motionGeneration++;
    this.motion?.cancel(); this.motion = undefined;
    this.moving = false; this.dragging = false; this.gestureActive = false;
    this.gestureDuringRelayout = false; this.intraChapterMotion = false;
    this.navigating = false; this.pendingNavigation = 0;
    this.yieldPreparation(); this.restoreCommitted();
    if (contact) this.callbacks.onContactState?.(this.activeSession, 'cancelled');
  }

  private yieldPreparation(targetSlot: number = -1, targetIndex: number = -1): void {
    const active = this.activePreparation;
    if (active && (active.slot !== targetSlot || active.index !== targetIndex)) {
      this.slotVersions[active.slot]++;
      this.resources?.setVersion(active.slot, this.slotVersions[active.slot]);
      this.requestedIndices[active.slot] = -1;
      runSurfaceScript(this.controllers[active.slot], 'Surface.cancelLoad()').catch((): void => {});
      runSurfaceScript(this.sourceController, 'Source.cancelPacket()').catch((): void => {});
      for (const token of this.preparationSignals) this.finishSignal(token, false);
    }
    this.jobs = this.jobs.filter((job: ReaderPreparationJob): boolean => {
      if (job.slot === targetSlot && job.index === targetIndex) return true;
      this.slotVersions[job.slot]++;
      this.resources?.setVersion(job.slot, this.slotVersions[job.slot]);
      this.requestedIndices[job.slot] = -1;
      job.resolve();
      return false;
    });
  }

  private async prepare(job: ReaderPreparationJob): Promise<void> {
    const slot = job.slot;
    const version = job.version;
    const session = this.generation;
    if (!this.alive || version !== this.slotVersions[slot] || this.sourceInfo === undefined) return;
    if (!this.loadedShells[slot]) {
      await new Promise<void>((resolve): void => {
        const waiters = this.shellWaiters.get(slot) ?? [];
        waiters.push(resolve);
        this.shellWaiters.set(slot, waiters);
      });
      if (!this.alive || session !== this.generation || version !== this.slotVersions[slot]) return;
    }
    this.openStage = 'reserve';
    const size = this.sourceInfo.chapterSizes[job.index];
    if (!await this.reserve(slot, size, version)) return;
    const owner = this.sourceController;
    this.openStage = 'packet';
    const packetSignal = this.awaitSignal(session);
    this.preparationSignals.add(packetSignal.token);
    await runSurfaceScript(owner, `Source.startPacket(${job.index},${packetSignal.token})`);
    await packetSignal.done;
    if (!this.alive || session !== this.generation || version !== this.slotVersions[slot]) return;
    this.openStage = 'packet-read';
    const sourceBytes = Number(await runSurfaceScript(owner, 'Source.packetResult.sourceBytes'));
    if (!Number.isSafeInteger(sourceBytes) || sourceBytes <= 0 || sourceBytes > size) {
      throw new Error('Chapter source exceeds reservation');
    }
    const packet = JSON.parse(await runSurfaceScript(owner, 'JSON.stringify(Source.packetResult)')) as string;
    if (packet.length > SOURCE_LIMIT) throw new Error('Chapter packet bound');
    const loadSignal = this.awaitSignal(session);
    this.preparationSignals.add(loadSignal.token);
    this.bridge.stagePacket(slot, loadSignal.token, packet);
    try {
      this.openStage = 'surface-load';
      try {
        await runSurfaceScript(this.controllers[slot], `Surface.startLoad(JSON.parse(ChapterBridge.takePacket(${slot},${loadSignal.token})),${slot},true,${JSON.stringify(this.resources?.prefix(slot))},${loadSignal.token},${JSON.stringify(this.settings)},${slot === 0 && !this.ready},${job.initialAtEnd},${session},${JSON.stringify(this.clipPagination ? 'clip' : 'scroll')},${this.motionGeneration},${version})`);
        await loadSignal.done;
      } catch (error) {
        const stage = await runSurfaceScript(this.controllers[slot], 'Surface.stage');
        this.openStage = `surface-load:${stage}`;
        throw error as Error;
      }
    } finally {
      this.bridge.clearPacket(loadSignal.token);
      runSurfaceScript(owner, 'Source.packetResult=null').catch((): void => {});
    }
    if (!this.alive || session !== this.generation || version !== this.slotVersions[slot]) return;
    this.openStage = 'surface-state';
    await runSurfaceScript(this.controllers[slot],
      `Surface.applyTheme(${JSON.stringify(this.settings.theme)})`);
    if (!this.alive || session !== this.generation || version !== this.slotVersions[slot]) return;
    const state = JSON.parse(JSON.parse(await runSurfaceScript(this.controllers[slot], 'JSON.stringify(Surface.loadResult)')) as string) as ReaderSurfaceState;
    if (!state.complete || state.index !== job.index || !state.cfiRoundTrip ||
      !state.originalCfiMatches || !state.baseMatches || !Number.isInteger(state.units) || state.units < 1 ||
      (this.clipPagination && state.surfaceVersion !== version)) {
      throw new Error('Chapter layout or original CFI failed');
    }
    this.units[slot] = state.units;
    this.layoutWidths[slot] = state.viewport;
    this.layoutHeights[slot] = state.height;
    this.slotLayoutRevisions[slot] = this.layoutRevision;
    this.chapterIndices[slot] = job.index;
    this.positions[slot] = state.unit;
    this.available[slot] = true;
  }

  private neighborSlot(direction: number): number {
    return (this.currentSlot + direction + 4) % 4;
  }

  private prepareAround(direction: number): void {
    const generation = this.generation;
    const navigationEpoch = this.navigationEpoch;
    const chapterIndex = this.chapterIndex;
    const currentSlot = this.currentSlot;
    this.prepareNeighbor(direction, generation, navigationEpoch, chapterIndex, currentSlot)
      .catch((): void => {}).finally((): void => {
        if (generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
          chapterIndex !== this.chapterIndex || currentSlot !== this.currentSlot) return;
        this.prepareNeighbor(-direction, generation, navigationEpoch, chapterIndex, currentSlot)
          .catch((): void => {});
      });
  }

  private async prepareNeighbor(direction: number, generation: number, navigationEpoch: number,
    chapterIndex: number, currentSlot: number): Promise<void> {
    if (generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
      chapterIndex !== this.chapterIndex || currentSlot !== this.currentSlot) return;
    const index = chapterIndex + direction;
    if (!this.sourceInfo || index < 0 || index >= this.sourceInfo.chapterHrefs.length) return;
    const slot = (currentSlot + direction + 4) % 4;
    this.observeNavigation('preload-request', index, slot);
    await this.load(slot, index, 1, direction < 0);
    const version = this.slotVersions[slot];
    if (generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
      chapterIndex !== this.chapterIndex || currentSlot !== this.currentSlot ||
      !this.available[slot] || this.chapterIndices[slot] !== index) return;
    const edge = direction < 0 ? this.units[slot] - 1 : 0;
    await this.seek(slot, edge, generation, version, true);
  }

  private async seek(slot: number, unit: number, session: number, version?: number,
    syncNative: boolean = false): Promise<void> {
    const expectedVersion = version ?? this.slotVersions[slot];
    const state = JSON.parse(JSON.parse(await runSurfaceScript(this.controllers[slot],
      `JSON.stringify(Surface.seek(${unit},${this.motionGeneration},${expectedVersion}))`)) as string) as ReaderSurfaceState;
    if (!this.alive || session !== this.generation ||
      ((this.clipPagination || version !== undefined) && expectedVersion !== this.slotVersions[slot])) return;
    if (state.index !== this.chapterIndices[slot] || state.unit !== unit ||
      !state.complete || (this.clipPagination && (!state.positionValid || state.surfaceVersion !== expectedVersion ||
        state.paginationMode !== 'clip'))) throw new Error('Chapter position failed');
    if (!this.clipPagination && syncNative && unit > 0) {
      scrollSurface(this.controllers[slot], unit * this.layoutWidths[slot], 0);
    }
    this.positions[slot] = unit;
    if (this.clipPagination) this.positionVersions[slot] = expectedVersion;
  }

  private async commit(cause: 'layout' | 'navigation'): Promise<void> {
    const slot = this.currentSlot;
    const index = this.chapterIndex;
    const unit = this.pageUnit;
    const generation = this.generation;
    const navigationEpoch = this.navigationEpoch;
    if (this.clipPagination) {
      await this.presentationUpdate;
      if (!this.alive || generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
        slot !== this.currentSlot || index !== this.chapterIndex || unit !== this.pageUnit) return;
    }
    if (!this.sourceInfo || !this.available[slot] || this.chapterIndices[slot] !== index) {
      throw new Error('No verified chapter to commit');
    }
    const visible = JSON.parse(JSON.parse(await runSurfaceScript(this.controllers[slot],
      'JSON.stringify(Surface.inspect())')) as string) as ReaderSurfaceState;
    if (!visible.complete || visible.index !== index || visible.unit !== unit ||
      (this.clipPagination && (!visible.positionValid || visible.surfaceVersion !== this.slotVersions[slot] ||
        visible.paginationMode !== 'clip'))) {
      throw new Error('Visible page and committed position differ');
    }
    const href = this.sourceInfo.chapterHrefs[index];
    const retainedCfi = cause === 'layout' && this.committed?.chapterId === href ?
      this.parseLocator(this.committed.locator).cfi : '';
    const cfi = retainedCfi.length > 0 ? retainedCfi :
      JSON.parse(await runSurfaceScript(this.controllers[slot], `Surface.pageLocator(${unit})`)) as string;
    if (!this.alive || generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
      slot !== this.currentSlot || index !== this.chapterIndex || unit !== this.pageUnit) return;
    if (typeof cfi !== 'string' || !cfi.startsWith('epubcfi(') || cfi.length > 4096) {
      throw new Error('No verified page locator');
    }
    const mappedUnit = Number(await runSurfaceScript(this.controllers[slot],
      `Surface.unitForCfi(${JSON.stringify(cfi)})`));
    if (mappedUnit !== unit) throw new Error('Page locator resolves to another page');
    if (!this.alive || generation !== this.generation || navigationEpoch !== this.navigationEpoch ||
      slot !== this.currentSlot || index !== this.chapterIndex || unit !== this.pageUnit) return;
    const location: ReadingLocation = {
      engine: WEB_READER_ENGINE_ID,
      locator: JSON.stringify({ version: 1, cfi, href, page: unit + 1 }),
      chapterId: href,
      percentage: this.estimatePercentage(index, unit)
    };
    this.committed = location;
    this.committedPosition = { slot, index, unit };
    this.traceSelection(cause === 'layout' ? 'commit-layout' : 'commit-navigation', true);
    this.callbacks.onLocation(this.activeSession, location, cause);
  }

  private estimatePercentage(index: number, unit: number): number | undefined {
    if (this.sourceInfo === undefined || this.units[this.currentSlot] < 1) return undefined;
    const sizes = this.sourceInfo.chapterSizes;
    if (sizes.some((size: number): boolean => !Number.isSafeInteger(size) || size <= 0)) return undefined;
    const total = sizes.reduce((sum: number, size: number): number => sum + size, 0);
    if (!Number.isSafeInteger(total) || total <= 0) return undefined;
    const before = sizes.slice(0, index).reduce((sum: number, size: number): number => sum + size, 0);
    return Math.min(1, Math.max(0, (before + sizes[index] * unit / this.units[this.currentSlot]) / total));
  }

  private restoreCommitted(): void {
    const position = this.committedPosition;
    if (position === undefined) return;
    if (this.clipPagination && (!this.available[position.slot] || this.chapterIndices[position.slot] !== position.index)) {
      this.ready = false; this.readable = false; this.invalidate();
      this.callbacks.onError(this.activeSession, 'reader-engine');
      return;
    }
    this.currentSlot = position.slot;
    this.settleSurface(position.slot);
    this.chapterIndex = position.index;
    this.pageUnit = position.unit;
    if (this.clipPagination) {
      const generation = this.generation, epoch = this.navigationEpoch;
      this.presentationUpdate = this.seek(position.slot, position.unit, generation, this.slotVersions[position.slot])
        .then((): string => '').catch((): string => {
          if (this.alive && generation === this.generation && epoch === this.navigationEpoch) {
            this.ready = false; this.readable = false; this.invalidate();
            this.callbacks.onError(this.activeSession, 'reader-engine');
          }
          return '';
        });
    } else {
      this.controllers[position.slot].runJavaScript(`Surface.seek(${position.unit},${this.motionGeneration})`).catch((): void => {});
    }
  }

  private slotLayoutCurrent(slot: number): boolean {
    return this.slotLayoutRevisions[slot] === this.layoutRevision &&
      Math.abs(this.layoutWidths[slot] - this.viewportWidth) <= 2 &&
      Math.abs(this.layoutHeights[slot] - this.viewportHeight) <= 2;
  }

  private requestRelayout(): void {
    this.dispatch({ type: 'clearSelection' });
    if (!this.ready) return;
    this.yieldPreparation();
    this.relayouting = true;
    this.relayoutFailed = false;
    for (const token of this.relayoutSignals) this.finishSignal(token, false);
    if (this.relayoutPassRunning) {
      this.pendingRelayout = true;
      return;
    }
    this.relayoutPassRunning = true;
    const generation = this.generation;
    this.performRelayout().catch((): void => {
      if (this.alive && generation === this.generation && !this.pendingRelayout) {
        this.relayoutFailed = true;
      }
    }).finally((): void => {
      this.relayoutPassRunning = false;
      if (this.pendingRelayout) {
        this.pendingRelayout = false;
        this.requestRelayout();
      } else if (this.alive) {
        this.relayouting = false;
        const queued = generation === this.generation ? this.queuedRelayoutTurn : '';
        this.queuedRelayoutTurn = '';
        if (!this.relayoutFailed) {
          if (queued === 'nextPage') this.page(1);
          else if (queued === 'previousPage') this.page(-1);
          else if (queued === 'nextChapter') this.jump(this.chapterIndex + 1);
          else if (queued === 'previousChapter') this.jump(this.chapterIndex - 1);
        }
      }
    });
  }

  private async configureSlot(slot: number, revision: number, width: number, height: number,
    anchor: string): Promise<void> {
    const generation = this.generation;
    const version = this.slotVersions[slot];
    const startedAt = Date.now();
    let phase = 0;
    let validation = 0;
    const previous = this.configureTokens[slot];
    if (previous !== undefined) this.finishSignal(previous, false);
    const signal = this.awaitSignal(generation, RELAYOUT_TIMEOUT_MS);
    this.configureTokens[slot] = signal.token;
    if (slot !== this.currentSlot) {
      this.stagingSlots = this.stagingSlots.map((staged: boolean, index: number): boolean =>
        index === slot ? true : staged);
    }
    // A superseding fold can reject this signal before the script call settles.
    signal.done.catch((): void => {});
    this.relayoutSignals.add(signal.token);
    try {
      await runSurfaceScript(this.controllers[slot],
        `Surface.beginConfigure(${JSON.stringify(this.settings)},${JSON.stringify(anchor)},${revision},` +
        `${width},${height},${signal.token},${this.motionGeneration},${version})`);
      phase = 1;
      await signal.done;
      phase = 2;
      if (this.clipPagination && version !== this.slotVersions[slot]) return;
      if (!this.alive || generation !== this.generation || revision !== this.layoutRevision ||
        this.pendingRelayout || this.configureTokens[slot] !== signal.token) return;
      // A theme can change while an older layout/load settings snapshot is pending.
      await runSurfaceScript(this.controllers[slot],
        `Surface.applyTheme(${JSON.stringify(this.settings.theme)})`);
      if (!this.alive || generation !== this.generation || revision !== this.layoutRevision ||
        this.pendingRelayout || this.configureTokens[slot] !== signal.token) return;
      const raw = await runSurfaceScript(this.controllers[slot],
        'JSON.stringify({token:Surface.configureResultToken,state:Surface.configureResult})');
      phase = 3;
      const result = JSON.parse(JSON.parse(raw) as string) as SurfaceConfigureResult;
      const state = result.state;
      phase = 4;
      if (result.token !== signal.token || this.configureTokens[slot] !== signal.token) validation = 1;
      else if (!state) validation = 2;
      else if (!state.complete) validation = 3;
      else if (state.index !== this.chapterIndices[slot]) validation = 4;
      else if (!Number.isInteger(state.units) || state.units < 1) validation = 5;
      else if (!Number.isInteger(state.unit) || state.unit < 0 || state.unit >= state.units) validation = 6;
      else if (Math.abs(state.viewport - width) > 2) validation = 7;
      else if (Math.abs(state.height - height) > 2) validation = 8;
      else if (this.clipPagination && (!state.positionValid || state.surfaceVersion !== this.slotVersions[slot])) validation = 9;
      if (validation !== 0) {
        throw new Error('Reader relayout failed');
      }
      this.units[slot] = state.units;
      this.layoutWidths[slot] = state.viewport;
      this.layoutHeights[slot] = state.height;
      this.webViewportWidths[slot] = state.viewport;
      this.webViewportHeights[slot] = state.height;
      this.slotLayoutRevisions[slot] = revision;
      this.positions[slot] = state.unit;
      if (this.clipPagination) this.positionVersions[slot] = this.slotVersions[slot];
      if (slot === this.currentSlot) this.pageUnit = state.unit;
      SafeLog.readerRelayout('ready', slot, revision, width, height, state.viewport,
        state.height, Date.now() - startedAt);
    } catch (error) {
      this.finishSignal(signal.token, false);
      if (this.alive && generation === this.generation && revision === this.layoutRevision &&
        !this.pendingRelayout && this.configureTokens[slot] === signal.token) {
        let webPhase = 0;
        try {
          webPhase = Number(await runSurfaceScript(this.controllers[slot],
            'Surface.configureFailureCode || 0'));
        } catch (_) {}
        SafeLog.readerRelayoutFailureDetail(slot, revision, phase, validation, webPhase);
        SafeLog.readerRelayout('failed', slot, revision, width, height,
          this.webViewportWidths[slot], this.webViewportHeights[slot], Date.now() - startedAt);
      }
      throw error as Error;
    } finally {
      this.relayoutSignals.delete(signal.token);
      if (this.configureTokens[slot] === signal.token) {
        this.configureTokens[slot] = undefined;
        if (this.stagingSlots[slot]) {
          this.stagingSlots = this.stagingSlots.map((staged: boolean, index: number): boolean =>
            index === slot ? false : staged);
        }
      }
    }
  }

  private async performRelayout(): Promise<void> {
    const committed = this.committed;
    if (!committed || !this.sourceInfo) return;
    const generation = this.generation;
    const revision = ++this.layoutRevision;
    const expectedWidth = this.viewportWidth;
    const expectedHeight = this.viewportHeight;
    if (expectedWidth <= 0 || expectedHeight <= 0) return;
    const committedPosition = this.committedPosition;
    SafeLog.readerRelayoutPosition(revision, this.currentSlot, committedPosition?.slot ?? -1,
      committed.chapterId === this.sourceInfo.chapterHrefs[this.chapterIndex],
      this.chapterIndices[this.currentSlot] === this.chapterIndex);
    this.navigationEpoch++;
    if (this.clipPagination) this.navigating = false;
    if (this.gestureActive || this.moving) {
      SafeLog.readerRelayoutInput(revision, this.gestureActive, this.gestureDx,
        this.gesturePeak, this.moving ? this.motionDirection : 0);
    }
    if (this.gestureActive) {
      const interruptedTurn = this.interruptedGestureDirection();
      if (interruptedTurn !== 0) {
        this.queuedRelayoutTurn = interruptedTurn > 0 ? 'nextPage' : 'previousPage';
      }
      this.gestureActive = false;
      this.gestureDuringRelayout = false;
    }
    // Reflow cancels the old-width animation; finish its accepted turn on the new layout.
    if (this.moving && this.motionDirection !== 0 && this.queuedRelayoutTurn.length === 0) {
      this.queuedRelayoutTurn = this.motionDirection > 0 ? 'nextPage' : 'previousPage';
    }
    this.motionGeneration++;
    this.motion?.cancel();
    this.motion = undefined;
    this.moving = false;
    this.dragging = false;
    this.intraChapterMotion = false;
    this.settleSurface(this.currentSlot);
    this.pendingNavigation = 0;
    if (this.selectionToken.length > 0) this.dispatch({ type: 'clearSelection' });
    // A turn can finish visually while its locator commit is still waiting for Web.
    // Reflow from the last verified chapter, then replay that accepted turn.
    const verified = this.committedPosition;
    if (verified && (this.currentSlot !== verified.slot || this.chapterIndex !== verified.index ||
      this.pageUnit !== verified.unit)) {
      const delta = this.chapterIndex !== verified.index ?
        this.chapterIndex - verified.index : this.pageUnit - verified.unit;
      if (Math.abs(delta) === 1 && this.queuedRelayoutTurn.length === 0) {
        this.queuedRelayoutTurn = delta > 0 ? 'nextPage' : 'previousPage';
      }
      this.currentSlot = verified.slot;
      this.chapterIndex = verified.index;
      this.pageUnit = verified.unit;
      this.settleSurface(verified.slot);
    }
    const activeSlot = this.currentSlot;
    const cfi = this.parseLocator(committed.locator).cfi;
    await this.configureSlot(activeSlot, revision, expectedWidth, expectedHeight, cfi);
    if (!this.alive || generation !== this.generation || this.pendingRelayout ||
      revision !== this.layoutRevision) return;
    await this.commit('layout');
    if (!this.alive || generation !== this.generation || this.pendingRelayout ||
      revision !== this.layoutRevision) return;
    const background: Promise<void>[] = [];
    for (let slot = 0; slot < 4; slot++) {
      if (slot === activeSlot || !this.available[slot]) continue;
      const task = this.configureSlot(slot, revision, expectedWidth, expectedHeight, '').catch((): void => {
        if (revision === this.layoutRevision && !this.slotLayoutCurrent(slot)) {
          this.slotLayoutRevisions[slot] = -1;
        }
      });
      background.push(task);
    }
    this.relayouting = false;
    this.relayoutFailed = false;
    this.dispatch({ type: 'requestPageExcerpt', sessionId: this.activeSession });
    Promise.all(background).then((): void => {
      if (this.alive && generation === this.generation && !this.pendingRelayout &&
        revision === this.layoutRevision) this.prepareAround(1);
    });
  }

  private selectionEvent(slot: number, raw: string): void {
    if (!this.ready || slot !== this.currentSlot || raw.length > 512 * 1024) return;
    this.observeActualSelectionInput('selection-payload');
    let value: SurfaceSelectionMessage;
    try { value = JSON.parse(raw) as SurfaceSelectionMessage; } catch (_) { return; }
    if (typeof value.text !== 'string' || value.text.length === 0 || value.text.length > 32768 ||
      typeof value.cfi !== 'string' || !value.cfi.startsWith('epubcfi(') || value.cfi.length > 4096) return;
    if (value.text === this.selectionText && value.cfi === this.selectionCfi) return;
    const numbers = [value.left, value.top, value.width, value.height,
      value.viewportWidth, value.viewportHeight];
    if (!numbers.every((item: number): boolean => Number.isFinite(item)) ||
      value.width <= 0 || value.height <= 0 || value.viewportWidth <= 0 || value.viewportHeight <= 0 ||
      value.width > value.viewportWidth || value.height > value.viewportHeight) return;
    if (this.nativeSelectionCancelled) return;
    this.revokeSelectionHighlight();
    this.pendingNativeSelection = raw;
    this.nativeSelectionEnglish = /^[A-Za-z]+(?:['’\-][A-Za-z]+)*$/.test(value.text) && value.text.length <= 96;
    this.nativeSelectionNarrow = this.viewportWidth < 280;
    this.selectionGate.changed(this.activeSession, ++this.nativeSelectionRevision);
    if (!this.selectionGate.canPublish(this.activeSession, this.nativeSelectionRevision)) return;
    const rect: ReaderSelectionRect = { left: value.left, top: value.top, width: value.width,
      height: value.height, viewportWidth: value.viewportWidth, viewportHeight: value.viewportHeight };
    this.selectionText = value.text;
    this.selectionCfi = value.cfi;
    this.selectionToken = `s${this.activeSession}-${++this.selectionRevision}`;
    const word = /^[A-Za-z]+(?:['’\-][A-Za-z]+)*$/.test(value.text) && value.text.length <= 96;
    if (word) {
      this.callbacks.onWordSelection(this.activeSession, { engine: WEB_READER_ENGINE_ID,
        selectionToken: this.selectionToken, characterCount: value.text.length,
        surfaceForm: value.text, locator: value.cfi, rect: rect,
        geometry: { anchor: rect, fragments: [rect] } });
    } else {
      this.callbacks.onPassageSelection(this.activeSession, { engine: WEB_READER_ENGINE_ID,
        selectionToken: this.selectionToken, characterCount: value.text.length,
        locator: value.cfi, rect: rect, geometry: { anchor: rect, fragments: [rect] } });
    }
    this.observeActualSelectionInput('selection-published');
  }

  private requestSelectionContext(token: string, sessionId: number,
    marks?: ReaderTextMark[], excludeMarkId?: string,
    completion?: (context?: ReadingSelectionContext) => void): void {
    const selectedText = this.selectionText;
    const selectedCfi = this.selectionCfi;
    const revision = this.nativeSelectionRevision;
    const reject = (reason: string): void => {
      if (completion) completion(undefined);
      else this.callbacks.onSelectionContextRejected(sessionId, token, reason);
    };
    if (sessionId !== this.activeSession || token.length === 0 || token !== this.selectionToken ||
      this.selectionText.length === 0) {
      reject('stale-selection');
      return;
    }
    const slot = this.currentSlot;
    const resourceHref = this.sourceInfo?.chapterHrefs[this.chapterIndex] ?? '';
    const sameResource = marks?.filter((mark: ReaderTextMark): boolean => mark.resourceHref === resourceHref);
    if (sameResource !== undefined && sameResource.length > 150) {
      reject('mark-limit');
      return;
    }
    const payload = JSON.stringify(sameResource ?? []);
    if (payload.length > 1024 * 1024 || marks?.some((mark: ReaderTextMark): boolean => mark.bookId !== this.book.bookId)) {
      reject('mark-limit');
      return;
    }
    const script = marks === undefined ? 'JSON.stringify(Surface.selectionContext())' :
      `JSON.stringify(Surface.selectionContext(${payload},${JSON.stringify(excludeMarkId ?? '')},${JSON.stringify(this.book.bookId)}))`;
    this.controllers[slot].runJavaScript(script).then((raw: string): void => {
      if (!this.alive || sessionId !== this.activeSession || slot !== this.currentSlot ||
        revision !== this.nativeSelectionRevision ||
        (token !== this.selectionToken && !(completion && token === this.highlightToken && this.selectionHighlightValid(sessionId)))) return;
      if (raw.length > 512 * 1024) {
        reject('invalid-selection');
        return;
      }
      let value: SurfaceContextMessage;
      try { value = JSON.parse(JSON.parse(raw) as string) as SurfaceContextMessage; }
      catch (_) { reject('invalid-selection'); return; }
      if (!value || value.text !== selectedText || value.cfi !== selectedCfi ||
        typeof value.currentText !== 'string' || value.currentText.length > 2000) {
        reject('invalid-selection');
        return;
      }
      const context: ReadingSelectionContext = { selectionToken: token,
        kind: /^[A-Za-z]+(?:['’\-][A-Za-z]+)*$/.test(value.text) && value.text.length <= 96 ? 'word' : 'passage',
        selectedText: value.text, bookTitle: this.book.title, currentText: value.currentText };
      if (value.markConflict === 'overlap' || value.markConflict === 'unavailable') {
        context.markConflict = value.markConflict;
      }
      if (typeof value.rangeText === 'string' && value.rangeText.length > 0 &&
        value.rangeText.length <= 32768 && typeof value.prefix === 'string' &&
        value.prefix.length <= 64 && typeof value.suffix === 'string' && value.suffix.length <= 64 &&
        this.sourceInfo && this.chapterIndex >= 0 && this.chapterIndex < this.sourceInfo.chapterHrefs.length) {
        context.rangeAnchor = { resourceHref: this.sourceInfo.chapterHrefs[this.chapterIndex],
          cfi: value.cfi, exactText: value.rangeText, prefix: value.prefix, suffix: value.suffix,
          quoteScope: value.quoteScope };
        const combined = value.rangeUnion;
        if (marks !== undefined && combined && combined.resourceHref === context.rangeAnchor.resourceHref &&
          typeof combined.cfi === 'string' && combined.cfi.startsWith('epubcfi(') && combined.cfi.length <= 4096 &&
          typeof combined.exactText === 'string' && combined.exactText.length > 0 && combined.exactText.length <= 32768 &&
          typeof combined.prefix === 'string' && combined.prefix.length <= 64 &&
          typeof combined.suffix === 'string' && combined.suffix.length <= 64 && combined.quoteScope === 'body' &&
          Array.isArray(combined.members) && combined.members.length <= 150 &&
          new Set(combined.members.map((member): string => member.markId)).size === combined.members.length &&
          combined.members.every((member): boolean => typeof member.markId === 'string' && member.markId !== excludeMarkId &&
            marks.some((mark: ReaderTextMark): boolean => mark.markId === member.markId &&
              mark.resourceHref === combined.resourceHref && mark.revision === member.revision && Number.isSafeInteger(member.revision)))) {
          context.rangeUnion = combined;
        } else if (marks !== undefined) {
          context.markConflict = 'unavailable';
        }
      }
      if (completion) completion(context);
      else this.callbacks.onSelectionContext(sessionId, context);
    }).catch((): void => reject('invalid-selection'));
  }

  private linkEvent(slot: number, raw: string): void {
    if (!this.ready || slot !== this.currentSlot || raw.length > 2300 || !this.sourceInfo ||
      this.linkNavigationInFlight) return;
    let target: SurfaceLinkMessage;
    try { target = JSON.parse(raw) as SurfaceLinkMessage; } catch (_) { return; }
    if (typeof target.href !== 'string' || target.href.length === 0 || target.href.length > 2048) return;
    if (target.type === 'external') {
      if (!/^https?:\/\/[^\s@/]+(?:\/|$)/i.test(target.href)) return;
      this.callbacks.onExternalLinkRequest(this.activeSession,
        { requestId: ++this.externalLinkRequestId, url: target.href });
      return;
    }
    if (target.type !== 'internal' || !this.committed ||
      /[\u0000-\u001f\\]/.test(target.href) || /%(?:2e|2f|5c)/i.test(target.href)) return;
    const path = target.href.split('#')[0];
    const index = this.sourceInfo.chapterHrefs.findIndex((href: string): boolean => href === path);
    if (index < 0) return;
    const previous = this.committed;
    const kind: ReaderInternalLinkKind = target.kind === 'footnote' ? 'footnote' : 'internal';
    const fragment = target.href.includes('#') ? target.href.slice(target.href.indexOf('#') + 1) : '';
    const session = this.generation;
    this.linkNavigationInFlight = true;
    const started = this.jump(index, fragment, '', (): void => {
      const next = this.committed;
      if (!next || this.sameReadingPage(previous, next)) return;
      const top = this.returnStack[this.returnStack.length - 1];
      if (top && this.sameReadingPage(top.location, next)) {
        this.returnStack.pop();
        this.activeLinkKind = top.kind;
      } else {
        if (this.returnStack.length >= 16) this.returnStack.shift();
        this.returnStack.push({ location: previous, kind: this.activeLinkKind });
        this.activeLinkKind = kind;
      }
      this.callbacks.onLinkState(this.activeSession,
        { canReturn: this.returnStack.length > 0, kind: this.activeLinkKind });
    }, (): void => { if (session === this.generation) this.linkNavigationInFlight = false; });
    if (!started) this.linkNavigationInFlight = false;
  }

  private sameReadingPage(left: ReadingLocation, right: ReadingLocation): boolean {
    if (left.locator === right.locator) return true;
    const first = this.parseLocator(left.locator);
    const second = this.parseLocator(right.locator);
    return (first.cfi.length > 0 && first.cfi === second.cfi) ||
      (first.href.length > 0 && first.href === second.href && first.page === second.page);
  }

  private dispatch(command: ReaderCommand): void {
    if (!this.alive) return;
    if (command.type === 'openBook') {
      this.invalidate();
      this.resources?.close();
      this.resources = undefined;
      this.sourceInfo = undefined;
      this.ready = false;
      this.readable = false;
      this.book = command.book;
      this.activeSession = command.sessionId;
      this.nativeSelectionRevision = 0;
      this.nativeSelectionCancelled = false;
      this.selectionGate.reset(this.activeSession, true);
      this.initialLocator = command.location?.engine === WEB_READER_ENGINE_ID ? command.location.locator : '';
      this.settings = command.settings;
      this.updateBackground(command.settings);
      this.committed = undefined;
      this.committedPosition = undefined;
      this.selectionText = '';
      this.selectionCfi = '';
      this.selectionToken = '';
      this.selectedSlots = [false, false, false, false];
      this.blockedSlots = [false, false, false, false];
      this.returnStack = [];
      this.activeLinkKind = undefined;
      this.callbacks.onLinkState(this.activeSession, { canReturn: false });
      this.chapterIndices = [-1, -1, -1, -1];
      this.requestedIndices = [-1, -1, -1, -1];
      this.sourceSizes = [0, 0, 0, 0];
      this.available = [false, false, false, false];
      this.controllers.forEach((controller: webview.WebviewController): void => {
        runSurfaceScript(controller, 'Surface.releaseChapter()').catch((): void => {});
      });
      const generation = this.generation;
      runSurfaceScript(this.sourceController, 'Source.close()').then((): void => {
        if (!this.alive || generation !== this.generation) return;
        this.openSource().catch((): void => {
          if (!this.alive || generation !== this.generation) return;
          this.onCandidateStage(this.openStage);
          this.callbacks.onError(this.activeSession, 'reader-engine');
        });
      }).catch((): void => {
        if (this.alive && generation === this.generation) this.callbacks.onError(this.activeSession, 'reader-engine');
      });
      return;
    }
    if (command.type === 'requestLocation') {
      if (this.committed) this.callbacks.onLocation(this.activeSession, this.committed, 'layout');
      return;
    }
    if (command.type === 'requestPageExcerpt') {
      if (!this.ready || command.sessionId !== this.activeSession || this.relayouting || this.navigating) return;
      const slot = this.currentSlot;
      const unit = this.pageUnit;
      const index = this.chapterIndex;
      const generation = this.generation;
      const epoch = this.navigationEpoch;
      const layoutRevision = this.layoutRevision;
      this.controllers[slot].runJavaScript(`Surface.pageExcerpt(${unit})`).then((raw: string): void => {
        if (!this.alive || !this.ready || generation !== this.generation ||
          epoch !== this.navigationEpoch || layoutRevision !== this.layoutRevision ||
          slot !== this.currentSlot ||
          index !== this.chapterIndex || unit !== this.pageUnit) return;
        let excerpt: string = '';
        try { excerpt = JSON.parse(raw) as string; } catch (_) { return; }
        if (typeof excerpt === 'string' && excerpt.length <= 240) {
          this.callbacks.onPageExcerpt?.(this.activeSession, excerpt);
        }
      }).catch((): void => {});
      return;
    }
    if (command.type === 'goToBookmark') {
      this.jumpToBookmark(command.point, command.sessionId);
      return;
    }
    if (command.type === 'previewTextMark') {
      this.previewTextMark(command.mark, command.sessionId);
      return;
    }
    if (command.type === 'goToTextMark') {
      this.jumpToTextMark(command.mark, command.sessionId);
      return;
    }
    if (command.type === 'removeTextMark') {
      if (command.sessionId === this.activeSession && command.markId.length <= 96) {
        const id = JSON.stringify(command.markId);
        this.controllers.forEach((controller: webview.WebviewController): void => {
          runSurfaceScript(controller, `Surface.removeTextMark(${id})`).catch((): void => {});
        });
      }
      return;
    }
    if (command.type === 'focusContent') {
      if (this.alive && this.ready) {
        try {
          this.getUIContext().getFocusController().requestFocus(`reader-chapter-surface-${this.currentSlot}`);
        } catch (_) {}
      }
      return;
    }
    if (command.type === 'clearSelection') {
      this.traceSelection('clear-selection', true);
      const preserveHighlight = this.highlightPresentationClear && this.selectionHighlightValid(this.activeSession);
      this.nativeSelectionCancelled = true;
      this.nativeSelectionEnglish = false;
      this.selectionGate.cancel(this.activeSession);
      this.pendingNativeSelection = '';
      if (!preserveHighlight) this.revokeSelectionHighlight();
      this.selectionText = '';
      this.selectionCfi = '';
      this.selectionToken = '';
      this.selectedSlots = [false, false, false, false];
      this.blockedSlots = [false, false, false, false];
      this.controllers.forEach((controller: webview.WebviewController): void => {
        runSurfaceScript(controller, 'Surface.clearSelection()').catch((): void => {});
      });
      this.callbacks.onSelectionCleared(this.activeSession, preserveHighlight ? 'presentation' : 'cancel');
      return;
    }
    if (command.type === 'requestSelectionContext') {
      this.requestSelectionContext(command.selectionToken, command.sessionId,
        command.marks, command.excludeMarkId);
      return;
    }
    if (command.type === 'applyColumnMode') {
      if (this.settings.columnMode === command.mode) return;
      this.settings = { fontScale: this.settings.fontScale, lineSpacing: this.settings.lineSpacing,
        pageMarginVp: this.settings.pageMarginVp, theme: this.settings.theme, columnMode: command.mode };
      this.requestRelayout();
      return;
    }
    if (command.type === 'applySettings') {
      this.applyReaderSettings(command.settings);
      return;
    }
    if (command.type === 'nextPage' || command.type === 'previousPage') {
      this.page(command.type === 'nextPage' ? 1 : -1);
      return;
    }
    if (command.type === 'nextChapter' || command.type === 'previousChapter') {
      if (this.relayouting) {
        this.queuedRelayoutTurn = command.type;
        return;
      }
      this.jump(this.chapterIndex + (command.type === 'nextChapter' ? 1 : -1));
      return;
    }
    if (command.type === 'goToChapter') {
      const path = command.href.split('#')[0];
      const index = this.sourceInfo?.chapterHrefs.findIndex((href: string): boolean =>
        href === path || href.endsWith(`/${path}`)) ?? -1;
      this.jump(index, command.href.includes('#') ? command.href.slice(command.href.indexOf('#') + 1) : '');
      return;
    }
    if (command.type === 'returnFromInternalLink') {
      if (this.linkNavigationInFlight) return;
      const entry = this.returnStack[this.returnStack.length - 1];
      if (!entry || !this.sourceInfo) return;
      const saved = this.parseLocator(entry.location.locator);
      const index = this.sourceInfo.chapterHrefs.findIndex((href: string): boolean => href === saved.href);
      if (index < 0) return;
      const session = this.generation;
      this.linkNavigationInFlight = true;
      const started = this.jump(index, '', saved.cfi, (): void => {
        this.returnStack.pop();
        this.activeLinkKind = entry.kind;
        this.callbacks.onLinkState(this.activeSession,
          { canReturn: this.returnStack.length > 0, kind: this.activeLinkKind });
      }, (): void => { if (session === this.generation) this.linkNavigationInFlight = false; });
      if (!started) this.linkNavigationInFlight = false;
      return;
    }
    // The candidate is not used by the ordinary Reader until these commands
    // have real implementations; do not silently claim parity.
    this.callbacks.onError(this.activeSession, 'reader-command');
  }

  private page(direction: number): void {
    this.traceSelection('page-request', true, direction);
    this.revokeSelectionHighlight();
    if (this.ready && this.relayouting && (direction === -1 || direction === 1)) {
      this.queuedRelayoutTurn = direction > 0 ? 'nextPage' : 'previousPage';
      return;
    }
    if (!this.ready || this.relayoutFailed || this.dragging || this.moving ||
      (direction !== -1 && direction !== 1)) return;
    if (this.selectionToken.length > 0) this.dispatch({ type: 'clearSelection' });
    if (this.navigating) {
      this.navigationEpoch++;
      if (this.clipPagination) this.motionGeneration++;
      this.yieldPreparation();
      this.restoreCommitted();
    }
    if (this.clipPagination && !this.ready) return;
    this.navigating = true;
    this.traceSelection('page-start', false, direction);
    const epoch = this.navigationEpoch;
    this.navigatePage(direction).finally((): void => {
      if (epoch !== this.navigationEpoch) return;
      this.navigating = false;
      const pending = this.pendingNavigation;
      this.pendingNavigation = 0;
      if (pending !== 0) this.page(pending);
    });
  }

  private async navigatePage(direction: number): Promise<void> {
    const epoch = this.navigationEpoch;
    const session = this.generation;
    try {
      if (this.clipPagination) {
        await this.presentationUpdate;
        if (!this.ready || epoch !== this.navigationEpoch || session !== this.generation) return;
      }
      const within = this.pageUnit + direction;
      if (within >= 0 && within < this.units[this.currentSlot]) {
        await this.seek(this.currentSlot, within, session);
        if (epoch !== this.navigationEpoch || session !== this.generation) return;
        this.pageUnit = within;
      } else {
        const index = this.chapterIndex + direction;
        if (!this.sourceInfo || index < 0 || index >= this.sourceInfo.chapterHrefs.length) return;
        const target = this.neighborSlot(direction);
        await this.load(target, index, 0, direction < 0);
        if (epoch !== this.navigationEpoch || session !== this.generation || !this.available[target]) return;
        const unit = direction < 0 ? this.units[target] - 1 : 0;
        await this.seek(target, unit, session, undefined, true);
        if (epoch !== this.navigationEpoch || session !== this.generation) return;
        this.currentSlot = target;
        this.settleSurface(target);
        this.chapterIndex = index;
        this.pageUnit = unit;
      }
      await this.commit('navigation');
      if (epoch !== this.navigationEpoch || session !== this.generation) return;
      this.prepareAround(direction);
    } catch (_) {
      if (epoch === this.navigationEpoch) {
        this.restoreCommitted();
        if (!this.clipPagination || this.ready) this.callbacks.onError(this.activeSession, 'navigation');
      }
    }
  }

  private textMarkIndex(mark: ReaderTextMark, sessionId: number): number {
    if (mark === undefined || mark === null) return -1;
    const source = this.sourceInfo;
    const index = source?.chapterHrefs.indexOf(mark.resourceHref) ?? -1;
    const base = index >= 0 ? source?.chapterCfiBases[index] ?? '' : '';
    if (!this.ready || this.relayouting || sessionId !== this.activeSession ||
      mark.bookId !== this.book.bookId || mark.anchorVersion !== 1 ||
      mark.engine !== WEB_READER_ENGINE_ID || typeof mark.markId !== 'string' ||
      mark.markId.length === 0 || mark.markId.length > 160 || index < 0 || base.length === 0 ||
      typeof mark.cfi !== 'string' || !mark.cfi.startsWith('epubcfi(') || mark.cfi.length > 4096 ||
      !mark.cfi.includes(`${base}!`) || typeof mark.exactText !== 'string' ||
      mark.exactText.length === 0 || mark.exactText.length > 32768 ||
      typeof mark.prefix !== 'string' || mark.prefix.length > 64 ||
      typeof mark.suffix !== 'string' || mark.suffix.length > 64 ||
      (mark.noteAnchors?.length ?? 0) > 150 || (mark.highlightAnchors?.length ?? 0) > 150 || JSON.stringify(mark).length > 1048576) return -1;
    return index;
  }

  private async resolveTextMark(slot: number, mark: ReaderTextMark,
    generation: number): Promise<ReaderTextMarkResolution> {
    const raw = await runSurfaceScript(this.controllers[slot],
      `JSON.stringify(Surface.resolveTextRange(${JSON.stringify(mark)},${generation}))`);
    const result = JSON.parse(JSON.parse(raw) as string) as ReaderTextMarkResolution;
    if ((result.status === 'verified' || result.status === 'recovered') &&
      typeof result.cfi === 'string' && result.cfi.startsWith('epubcfi(') && result.cfi.length <= 4096) {
      return result;
    }
    if (result.status === 'orphaned' && (result.reason === 'missing' ||
      result.reason === 'ambiguous' || result.reason === 'unavailable')) return result;
    return { status: 'orphaned', reason: 'unavailable' };
  }

  private previewTextMark(mark: ReaderTextMark, sessionId: number): void {
    const index = this.textMarkIndex(mark, sessionId);
    if (index < 0 || index !== this.chapterIndex) {
      this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'preview', false);
      return;
    }
    const slot = this.currentSlot;
    const unit = this.pageUnit;
    const generation = this.generation;
    const epoch = this.navigationEpoch;
    const version = this.slotVersions[slot];
    this.resolveTextMark(slot, mark, generation).then(async (resolution): Promise<void> => {
      const current = this.alive && this.ready && generation === this.generation &&
        epoch === this.navigationEpoch && version === this.slotVersions[slot] &&
        slot === this.currentSlot && unit === this.pageUnit && index === this.chapterIndex;
      if (!current) return;
      resolution.revision = mark.revision ?? 1;
      this.callbacks.onTextMarkResolution?.(sessionId, mark.markId, resolution);
      if (resolution.status === 'orphaned' && mark.noteAnchors === undefined && mark.highlightAnchors === undefined) {
        this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'preview', false);
        return;
      }
      const resolved = textMarkWithCfi(mark, resolution.cfi ?? mark.cfi);
      if (mark.noteAnchors !== undefined) {
        const rawNotes = await runSurfaceScript(this.controllers[slot],
          `JSON.stringify(Surface.noteAnchorResolutions(${JSON.stringify(mark)},${generation}))`);
        if (rawNotes.length > 524288) throw new Error('Note resolution reply bound');
        const notes = JSON.parse(JSON.parse(rawNotes) as string) as NoteResolutionReply[];
        if (notes.length > 150 || new Set(notes.map((item: NoteResolutionReply): string => item.noteId)).size !== notes.length) throw new Error('Note resolution batch invalid');
        if (generation !== this.generation || epoch !== this.navigationEpoch || version !== this.slotVersions[slot]) return;
        for (const item of notes) {
          if (!mark.noteAnchors.some((note): boolean => note.noteId === item.noteId && note.revision === item.revision) ||
            !['verified','recovered','orphaned'].includes(item.status) ||
            (item.status === 'orphaned' && !['missing','ambiguous','unavailable'].includes(item.reason ?? ''))) throw new Error('Note resolution invalid');
          this.callbacks.onNoteAnchorResolution?.(sessionId,item.noteId,item.revision,item);
        }
      }
      const raw = await runSurfaceScript(this.controllers[slot],
        `Surface.drawVerifiedTextMark(${JSON.stringify(resolved)},${generation})`);
      const stillCurrent = this.alive && this.ready && generation === this.generation &&
        epoch === this.navigationEpoch && version === this.slotVersions[slot] &&
        slot === this.currentSlot && unit === this.pageUnit && index === this.chapterIndex;
      this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'preview', stillCurrent && raw === 'true');
    }).catch((): void => {
      if (!this.alive || !this.ready || generation !== this.generation || epoch !== this.navigationEpoch ||
        version !== this.slotVersions[slot] || slot !== this.currentSlot || unit !== this.pageUnit || index !== this.chapterIndex) return;
      this.callbacks.onTextMarkResolution?.(sessionId, mark.markId,
        { status: 'orphaned', reason: 'unavailable', revision: mark.revision ?? 1 });
      this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'preview', false);
    });
  }

  private jumpToTextMark(mark: ReaderTextMark, sessionId: number): void {
    const index = this.textMarkIndex(mark, sessionId);
    if (index < 0) {
      this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'jump', false);
      return;
    }
    let committed = false;
    const started = this.jump(index, '', mark.cfi, (): void => {
      committed = true;
      this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'jump', true);
    }, (): void => {
      if (!committed) this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'jump', false);
    }, mark);
    if (!started) this.callbacks.onTextMarkResult?.(sessionId, mark.markId, 'jump', false);
  }

  private jumpToBookmark(point: BookmarkPoint, sessionId: number): void {
    const source = this.sourceInfo;
    const index = source?.chapterHrefs.indexOf(point.resourceHref) ?? -1;
    const base = index >= 0 ? source?.chapterCfiBases[index] ?? '' : '';
    if (!this.ready || sessionId !== this.activeSession ||
      point.bookId !== this.book.bookId || point.anchorVersion !== 1 ||
      point.engine !== WEB_READER_ENGINE_ID || index < 0 || base.length === 0 ||
      !point.cfi.startsWith('epubcfi(') || point.cfi.length > 4096 ||
      !point.cfi.includes(`${base}!`)) {
      this.observeNavigation('bookmark-rejected', index, this.currentSlot);
      this.callbacks.onBookmarkJumpResult?.(sessionId, point.bookmarkId, false);
      return;
    }
    this.observeNavigation('bookmark-accepted', index, this.currentSlot);
    let committed = false;
    const started = this.jump(index, '', point.cfi, (): void => {
      committed = true;
      this.callbacks.onBookmarkJumpResult?.(sessionId, point.bookmarkId, true);
    }, (): void => {
      if (!committed) this.callbacks.onBookmarkJumpResult?.(sessionId, point.bookmarkId, false);
    });
    if (!started) this.callbacks.onBookmarkJumpResult?.(sessionId, point.bookmarkId, false);
  }

  private observeNavigation(phase: string, index: number, slot: number, unit: number = -1): void {
    if (!this.readOnlyObservation) return;
    this.readOnlyObservation.navigationObserved({ phase, resourceIndex: index, slot,
      version: this.slotVersions[slot] ?? -1, requestedIndex: this.requestedIndices[slot] ?? -1,
      loadedIndex: this.chapterIndices[slot] ?? -1, available: this.available[slot] === true,
      epoch: this.navigationEpoch, generation: this.generation, unit });
  }

  private jump(index: number, fragment: string = '', cfi: string = '', afterCommit?: () => void,
    afterSettled?: () => void, mark?: ReaderTextMark): boolean {
    this.revokeSelectionHighlight();
    if (!this.ready || this.relayouting || this.relayoutFailed || !this.sourceInfo ||
      index < 0 || index >= this.sourceInfo.chapterHrefs.length) return false;
    this.motionGeneration++;
    this.motion?.cancel();
    this.motion = undefined;
    this.moving = false;
    this.dragging = false;
    this.motionDirection = 0;
    this.intraChapterMotion = false;
    this.settleSurface(this.currentSlot);
    this.navigationEpoch++;
    this.pendingNavigation = 0;
    this.restoreCommitted();
    if (this.clipPagination && !this.ready) return false;
    this.yieldPreparation();
    this.navigating = true;
    const epoch = this.navigationEpoch;
    const session = this.generation;
    // A retained text anchor can fail verification. Prepare it offscreen so failure
    // cannot reset the currently committed Web page to unit zero.
    const target = mark !== undefined ? this.neighborSlot(1) : index === this.chapterIndex ? this.currentSlot : this.neighborSlot(1);
    this.observeNavigation('jump-request', index, target);
    const prepared = this.clipPagination ? this.presentationUpdate.then((): Promise<void> => {
      if (!this.ready || epoch !== this.navigationEpoch || session !== this.generation) return Promise.resolve();
      return this.load(target, index, 0);
    }) : this.load(target, index, 0);
    prepared.then(async (): Promise<void> => {
      this.observeNavigation('target-result', index, target);
      if (epoch !== this.navigationEpoch || session !== this.generation || !this.available[target]) {
        this.observeNavigation('target-rejected', index, target); return;
      }
      let resolvedCfi = cfi;
      if (mark !== undefined) {
        const resolution = await this.resolveTextMark(target, mark, session);
        if (epoch !== this.navigationEpoch || session !== this.generation) return;
        resolution.revision = mark.revision ?? 1;
        this.callbacks.onTextMarkResolution?.(this.activeSession, mark.markId, resolution);
        if (resolution.status === 'orphaned') return;
        resolvedCfi = resolution.cfi!;
        const resolved = textMarkWithCfi(mark, resolvedCfi);
        const drawn = await runSurfaceScript(this.controllers[target],
          `Surface.drawVerifiedTextMark(${JSON.stringify(resolved)},${session})`);
        if (drawn !== 'true' || epoch !== this.navigationEpoch || session !== this.generation) return;
      }
      let unit = 0;
      if (fragment.length > 0) unit = Number(await runSurfaceScript(this.controllers[target],
        `Surface.unitForFragment(${JSON.stringify(fragment)})`));
      else if (resolvedCfi.length > 0) unit = Number(await runSurfaceScript(this.controllers[target],
        `Surface.unitForCfi(${JSON.stringify(resolvedCfi)})`));
      this.observeNavigation('locator-result', index, target, unit);
      if (!Number.isInteger(unit) || unit < 0 || unit >= this.units[target]) return;
      await this.seek(target, unit, session, undefined, target !== this.currentSlot);
      if (epoch !== this.navigationEpoch || session !== this.generation) return;
      this.currentSlot = target;
      this.settleSurface(target);
      this.chapterIndex = index;
      this.pageUnit = unit;
      await this.commit('navigation');
      if (epoch !== this.navigationEpoch || session !== this.generation) return;
      this.observeNavigation('jump-committed', index, target, unit);
      afterCommit?.();
      this.prepareAround(-1);
    }).catch((): void => {
      this.observeNavigation('jump-error', index, target);
      if (epoch === this.navigationEpoch) {
        this.restoreCommitted();
        if (!this.clipPagination || this.ready) this.callbacks.onError(this.activeSession, 'navigation');
      }
    }).finally((): void => {
      if (epoch === this.navigationEpoch) this.navigating = false;
      this.observeNavigation('jump-settled', index, target);
      if (session === this.generation) afterSettled?.();
    });
    return true;
  }

  private surfacePosition(slot: number): number {
    const relative = (slot - this.surfaceLayout.slot + 4) % 4;
    return (relative === 3 ? -1 : relative) * this.viewportWidth + this.surfaceLayout.offset;
  }

  private settleSurface(slot: number): void {
    this.dragOffset = 0;
    this.surfaceLayout = { slot, offset: 0 };
  }

  private canMoveWithin(direction: number): boolean {
    return direction !== 0 && this.pageUnit + direction >= 0 &&
      this.pageUnit + direction < this.units[this.currentSlot];
  }

  private neighborReady(direction: number): boolean {
    const index = this.chapterIndex + direction;
    if (!this.sourceInfo || index < 0 || index >= this.sourceInfo.chapterHrefs.length) return false;
    const target = this.neighborSlot(direction);
    return this.available[target] &&
      (!this.clipPagination || this.positionVersions[target] === this.slotVersions[target]) &&
      this.chapterIndices[target] === index &&
      this.slotLayoutCurrent(target) &&
      this.positions[target] === (direction < 0 ? this.units[target] - 1 : 0);
  }

  private setDragOffset(value: number): void {
    this.dragOffset = value;
    if (this.intraChapterMotion && this.viewportWidth > 0) {
      const width = this.layoutWidths[this.currentSlot];
      if (this.clipPagination) {
        const settled = !this.moving && !this.dragging && !this.gestureActive;
        this.presentationUpdate = runSurfaceScript(this.controllers[this.currentSlot],
          `Surface.presentPage(${this.pageUnit},${value * width / this.viewportWidth},${this.motionGeneration},${settled},${this.slotVersions[this.currentSlot]})`)
          .then((raw: string): string => {
            if (raw !== 'true') throw new Error('Page presentation rejected');
            return raw;
          });
        this.presentationUpdate.catch((): void => {});
      } else {
        scrollSurface(this.controllers[this.currentSlot], this.pageUnit * width - value * width / this.viewportWidth, 0);
      }
    } else {
      this.surfaceLayout = { slot: this.surfaceLayout.slot, offset: value };
    }
  }

  private grab(): void {
    if (!this.ready || this.relayoutFailed || this.viewportWidth <= 0) return;
    if (this.clipPagination && this.navigating) {
      this.navigationEpoch++;
      this.motionGeneration++;
      this.yieldPreparation(); this.restoreCommitted();
      this.navigating = false; this.pendingNavigation = 0;
      if (!this.ready) return;
    }
    this.traceSelection('pan-start', true);
    this.observeActualSelectionInput('page-pan-start');
    this.gestureActive = true;
    this.gestureStartRevision = this.layoutRevision;
    this.gestureDuringRelayout = this.relayouting;
    if (this.gestureDuringRelayout) {
      this.gestureBaseOffset = 0;
      this.gestureDx = 0;
      this.gesturePeak = 0;
      this.dragging = true;
      return;
    }
    if (this.moving) {
      this.motionGeneration++;
      this.motion?.cancel();
      this.motion = undefined;
      this.moving = false;
    } else {
      this.motionDirection = 0;
      if (this.clipPagination) this.motionGeneration++;
    }
    this.gestureBaseOffset = this.dragOffset;
    this.gestureDx = 0;
    this.gesturePeak = 0;
    this.dragging = true;
  }

  private drag(event: GestureEvent): void {
    if (!this.dragging) return;
    this.gestureDx = event.offsetX;
    this.gesturePeak = Math.max(this.gesturePeak, Math.abs(event.offsetX));
    if (this.gestureDuringRelayout) return;
    if (!this.animateCustomMotion) return;
    const proposed = Math.max(-this.viewportWidth, Math.min(this.viewportWidth,
      this.gestureBaseOffset + event.offsetX));
    const direction = -Math.sign(proposed);
    if (this.motionDirection === 0 && direction !== 0) this.intraChapterMotion = this.canMoveWithin(direction);
    if (direction === 0 || this.intraChapterMotion || this.neighborReady(direction)) {
      this.setDragOffset(proposed);
    }
  }

  private release(velocity: number): void {
    if (!this.gestureActive) return;
    this.gestureActive = false;
    const interruptedByLayout = this.layoutRevision !== this.gestureStartRevision;
    const wasDragging = this.dragging;
    this.dragging = false;
    const distance = Math.abs(this.gestureDx);
    let direction = distance >= Math.min(80, Math.max(48, this.viewportWidth * 0.14)) ||
      (distance >= 28 && Math.abs(velocity) >= 350) ? -Math.sign(this.gestureDx) : 0;
    if (this.gesturePeak - distance >= Math.max(12, this.gesturePeak * 0.15)) direction = 0;
    this.traceSelection('pan-release', true, direction);
    if (interruptedByLayout) {
      if (direction === 0) direction = this.interruptedGestureDirection();
      if (direction !== 0) this.page(direction);
      this.gestureDuringRelayout = false;
      return;
    }
    if (!wasDragging) return;
    if (this.gestureDuringRelayout) {
      this.gestureDuringRelayout = false;
      if (direction !== 0) this.page(direction);
      return;
    }
    if (!this.animateCustomMotion) {
      if (direction !== 0) this.page(direction);
      return;
    }
    if (direction !== 0 && !this.canMoveWithin(direction) && !this.neighborReady(direction)) {
      this.settleSurface(this.currentSlot);
      this.intraChapterMotion = false;
      this.page(direction);
      return;
    }
    this.turn(direction, Math.abs(velocity) / 1000);
  }

  private interruptedGestureDirection(): number {
    const distance = Math.abs(this.gestureDx);
    return distance >= 28 &&
      this.gesturePeak - distance < Math.max(12, this.gesturePeak * 0.15) ?
      -Math.sign(this.gestureDx) : 0;
  }

  private turn(direction: number, speed: number): void {
    if (!this.ready || this.relayouting) return;
    this.traceSelection('turn-start', true, direction);
    if (direction !== 0) this.intraChapterMotion = this.canMoveWithin(direction);
    if (direction !== 0 && !this.intraChapterMotion && !this.neighborReady(direction)) direction = 0;
    const version = ++this.motionGeneration;
    const navigationEpoch = this.navigationEpoch;
    const session = this.generation;
    this.motion?.cancel();
    this.moving = true;
    this.motionDirection = direction;
    const start = this.dragOffset;
    const target = -direction * this.viewportWidth;
    const distance = Math.abs(target - start);
    const duration = direction === 0 ? 240 + 80 * Math.min(1, distance / Math.min(this.viewportWidth, 320)) :
      Math.max(80, 240 * Math.min(1, distance / this.viewportWidth));
    const slope = distance > 0 ? Math.min(2, Math.max(1.5, speed * duration / distance)) : 1.5;
    const motion = this.getUIContext().createAnimator({ duration: distance <= 2 ? 0 : duration,
      easing: 'linear', delay: 0, fill: 'forwards', iterations: 1, direction: 'normal', begin: 0, end: 1 });
    this.motion = motion;
    motion.onFrame = (value: number): void => {
      if (version !== this.motionGeneration) return;
      const progress = (slope - 2) * value * value * value + (3 - 2 * slope) * value * value + slope * value;
      this.setDragOffset(start + (target - start) * progress);
      // Optional actual native Animator frame observation; no timing or motion change.
      this.readOnlyObservation?.motionFrameObserved({ progress: value, moving: this.moving,
        animateMotion: this.animateCustomMotion, motionGeneration: version, layoutRevision: this.layoutRevision,
        resourceIndex: this.chapterIndex, unit: this.pageUnit, navigationEpoch: this.navigationEpoch });
    };
    motion.onFinish = (): void => {
      if (version !== this.motionGeneration) return;
      this.moving = false;
      this.motionDirection = 0;
      if (this.clipPagination && direction !== 0 && !this.intraChapterMotion && !this.neighborReady(direction)) {
        this.restoreCommitted();
        if (!this.clipPagination || this.ready) this.callbacks.onError(this.activeSession, 'navigation');
        return;
      }
      if (direction !== 0 && this.intraChapterMotion) {
        this.pageUnit += direction;
        this.positions[this.currentSlot] = this.pageUnit;
        this.setDragOffset(0);
      } else if (direction !== 0) {
        const targetSlot = this.neighborSlot(direction);
        const targetUnit = this.positions[targetSlot];
        if (!this.clipPagination) scrollSurface(this.controllers[targetSlot], targetUnit * this.layoutWidths[targetSlot], 0);
        this.currentSlot = targetSlot;
        this.chapterIndex += direction;
        this.pageUnit = targetUnit;
        this.settleSurface(targetSlot);
      } else {
        this.setDragOffset(0);
      }
      this.intraChapterMotion = false;
      this.traceSelection('motion-settled', true, direction);
      if (direction !== 0) {
        this.commit('navigation').then((): void => {
          if (navigationEpoch === this.navigationEpoch && session === this.generation) {
            this.prepareAround(direction);
          }
        }).catch((): void => {
          if (navigationEpoch !== this.navigationEpoch || session !== this.generation) return;
          this.restoreCommitted();
          if (!this.clipPagination || this.ready) this.callbacks.onError(this.activeSession, 'navigation');
        });
      }
    };
    motion.play();
  }

  private async readOnlyDocumentObservation(): Promise<ReaderDocumentObservation> {
    if (!this.alive || !this.ready) throw new Error('Reader observation not ready');
    const generation = this.generation, slot = this.currentSlot, version = this.slotVersions[slot], revision = this.layoutRevision;
    const index = this.chapterIndex, unit = this.pageUnit;
    const raw = await runSurfaceScript(this.controllers[slot], "JSON.stringify((function(){\n  var state=Surface.inspect(),frame=document.querySelector('iframe'),box=frame.getBoundingClientRect(),doc=frame.contentDocument;\n  var walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT),node,runs=0,rects=0,visible=0,clipped=0,last=0;\n  while((node=walker.nextNode())&&runs++<20000){\n    if(!node.data.trim()||node.parentElement.closest('script,style'))continue;\n    var range=doc.createRange();range.selectNodeContents(node);\n    for(var rect of range.getClientRects()){\n      if(++rects>40000)throw Error('Observation geometry bound');\n      var left=rect.left+box.left,right=rect.right+box.left,top=rect.top+box.top,bottom=rect.bottom+box.top;\n      if(right<=0||left>=innerWidth||bottom<=0||top>=innerHeight)continue;\n      visible++;last=Math.max(last,bottom);if(top < -1||bottom>innerHeight+1)clipped++;\n    }\n  }\n  if(runs>=20000)throw Error('Observation text-node bound');\n  var css=doc.defaultView.getComputedStyle(doc.body),selection=doc.defaultView.getSelection(),first,lastRect,chars=0;\n  if(selection&&!selection.isCollapsed&&selection.rangeCount){\n    var selected=selection.getRangeAt(0),selectedRects=selected.getClientRects();\n    if(selectedRects.length>512)throw Error('Observation selection bound');\n    first=selectedRects[0];lastRect=selectedRects[selectedRects.length-1];chars=selection.toString().length;\n  }\n  return {ready:false,stable:false,resourceIndex:0,unit:state.unit,units:state.units,layoutRevision:state.layoutRevision||0,slot:0,\n    surfaceIndex:state.index,surfaceVersion:state.surfaceVersion,surfaceScrollX:state.scrollX,contentOffsetX:state.contentOffsetX,clipPagination:state.paginationMode===\'clip\',positionValid:state.positionValid,surfaceOffsetVp:0,nativeWidthVp:0,nativeHeightVp:0,cssWidth:innerWidth,cssHeight:innerHeight,retained:state.retained,\n    visibleLines:visible,clippedLines:clipped,lastBottom:last,paddingTop:parseFloat(css.paddingTop)||0,\n    paddingBottom:parseFloat(css.paddingBottom)||0,paddingLeft:parseFloat(css.paddingLeft)||0,paddingRight:parseFloat(css.paddingRight)||0,\n    selected:!!first,selectedCharacters:chars,selectionActionable:false,selectionRevision:0,\n    selectionStartX:first?first.left+box.left:0,selectionStartY:first?first.top+box.top:0,\n    selectionEndX:lastRect?lastRect.right+box.left:0,selectionEndY:lastRect?lastRect.bottom+box.top:0};\n})())");
    const value = JSON.parse(JSON.parse(raw) as string) as ReaderDocumentObservation;
    value.ready = this.alive && this.ready;
    value.stable = value.ready && generation === this.generation && slot === this.currentSlot && version === this.slotVersions[slot] &&
      revision === this.layoutRevision && index === this.chapterIndex && unit === this.pageUnit && !this.relayouting && !this.navigating && !this.moving && !this.dragging && !this.gestureActive &&
      this.committedPosition?.index === index && this.committedPosition?.unit === unit && this.committedPosition?.slot === slot;
    if (this.clipPagination) value.stable = value.stable && value.surfaceIndex === index && value.surfaceVersion === version && value.positionValid === true;
    value.animateMotion = this.animateCustomMotion; value.gestureActive = this.gestureActive; value.dragging = this.dragging;
    value.surfaceOffsetVp = this.dragOffset;
    value.moving = this.moving; value.motionGeneration = this.motionGeneration; value.navigationEpoch = this.navigationEpoch;
    value.slotVersion = this.slotVersions[slot]; value.preparedIndices = this.chapterIndices.slice();
    value.preparedVersions = this.positionVersions.slice(); value.slotVersions = this.slotVersions.slice();
    value.resourceIndex = index; value.slot = slot; value.nativeWidthVp = this.viewportWidth; value.nativeHeightVp = this.viewportHeight;
    value.selectionRevision = this.nativeSelectionRevision;
    value.selectionActionable = this.selectionGate.canPublish(this.activeSession, this.nativeSelectionRevision);
    return value;
  }

  private async readOnlyRangeGeometry(request: ReaderOwnedRangeRequest): Promise<ReaderOwnedRangeGeometry> {
    if (!this.alive || !this.ready) throw new Error('Reader observation not ready');
    const generation = this.generation, slot = this.currentSlot, version = this.slotVersions[slot];
    const script = "JSON.stringify((function(blockIndex,start,end){\n  var frame=document.querySelector('iframe'),doc=frame.contentDocument,blocks=doc.querySelectorAll('p'),element=blocks[blockIndex];\n  if(!element||element.childNodes.length!==1||element.firstChild.nodeType!==3||element.firstChild.length<end)throw Error('Owned range not a plain text block');\n  var range=doc.createRange();range.setStart(element.firstChild,start);range.setEnd(element.firstChild,end);\n  if(OBS_CFI){range=new ePub.CFI(OBS_CFI).toRange(doc);if(!range||range.startContainer!==range.endContainer||range.startContainer.nodeType!==3)throw Error('Owned CFI shape');if(range.collapsed)range.setEnd(range.startContainer,range.startOffset+1);element=range.startContainer.parentElement;blockIndex=Array.from(blocks).indexOf(element);start=range.startOffset;end=range.endOffset;if((blockIndex<0&&!/^H[1-6]$/.test(element.tagName))||end>4096)throw Error('Owned CFI block');}\n  var rects=range.getClientRects();if(rects.length!==1)throw Error('Owned range rect count');\n  var rect=rects[0],outer=frame.getBoundingClientRect(),left=rect.left+outer.left,top=rect.top+outer.top;\n  if(left<0||top<0||left+rect.width>innerWidth||top+rect.height>innerHeight||rect.width<=0||rect.height<=0)throw Error('Owned range not visible');\n  return {blockIndex:blockIndex,heading:/^H[1-6]$/.test(element.tagName),start:start,end:end,left:left,top:top,right:left+rect.width,bottom:top+rect.height,cssWidth:innerWidth,cssHeight:innerHeight};\n})(OBS_BLOCK,OBS_START,OBS_END))".replace('OBS_BLOCK', String(request.blockIndex))
      .replace('OBS_START', String(request.start)).replace('OBS_END', String(request.end)).replaceAll('OBS_CFI', JSON.stringify(request.cfi ?? ''));
    const raw = await runSurfaceScript(this.controllers[slot], script);
    if (!this.alive || generation !== this.generation || slot !== this.currentSlot || version !== this.slotVersions[slot])
      throw new Error('Owned coordinate observation stale');
    return JSON.parse(JSON.parse(raw) as string) as ReaderOwnedRangeGeometry;
  }

  private async readOnlyOwnedCoverage(): Promise<ReaderOwnedCoverage> {
    if (!this.alive || !this.ready) throw new Error('Reader observation not ready');
    const generation = this.generation, slot = this.currentSlot, version = this.slotVersions[slot];
    const raw = await runSurfaceScript(this.controllers[slot], "JSON.stringify((function(){\n  var doc=document.querySelector('iframe').contentDocument,css=doc.defaultView.CSS,blocks=Array.from(doc.querySelectorAll('p'));\n  if(!css||!css.highlights)throw Error('Owned highlight observation unavailable');\n  function intervals(name){return Array.from(css.highlights.get(name)||[]).map(function(range){\n    var start=range.startContainer,end=range.endContainer,block=blocks.indexOf(start.parentElement);\n    if(block<0||start!==end||start.nodeType!==3||range.startOffset<0||range.endOffset>4096)throw Error('Owned coverage shape');\n    return {blockIndex:block,start:range.startOffset,end:range.endOffset};\n  });}\n  var notes=intervals('harmony-reader-note'),highlights=intervals('harmony-reader-highlight');\n  if(notes.length>200||highlights.length>200)throw Error('Owned coverage count');return {notes:notes,highlights:highlights};\n})())");
    if (!this.alive || generation !== this.generation || slot !== this.currentSlot || version !== this.slotVersions[slot])
      throw new Error('Owned coverage observation stale');
    return JSON.parse(JSON.parse(raw) as string) as ReaderOwnedCoverage;
  }

  private observeActualSelectionInput(kind: string): void {
    if (!this.readOnlyObservation) return;
    this.readOnlyObservation.inputObserved({ kind: kind, revision: this.nativeSelectionRevision,
      actionable: this.selectionGate.canPublish(this.activeSession, this.nativeSelectionRevision) });
  }

  private selectionTraceState(direction: number = 0): SelectionTraceState {
    const width = this.layoutWidths[this.currentSlot] || this.viewportWidth;
    const state: SelectionTraceState = {
      session: this.activeSession, chapter: this.chapterIndex, unit: this.pageUnit, slot: this.currentSlot,
      layerSlot: this.surfaceLayout.slot, committedChapter: this.committedPosition?.index ?? -1,
      committedUnit: this.committedPosition?.unit ?? -1, committedSlot: this.committedPosition?.slot ?? -1,
      epoch: this.navigationEpoch, layout: this.layoutRevision, appX: this.surfacePosition(this.currentSlot), dragX: this.dragOffset,
      widthCss: width, expectedWebX: this.clipPagination ? 0 : this.pageUnit * width -
        (this.intraChapterMotion && this.viewportWidth > 0 ? this.dragOffset * width / this.viewportWidth : 0),
      selected: this.selectedSlots[this.currentSlot], token: this.selectionToken.length > 0,
      blocked: this.blockedSlots[this.currentSlot], pan: this.gestureActive, dragging: this.dragging,
      moving: this.moving, navigating: this.navigating, relayout: this.relayouting, intra: this.intraChapterMotion,
      direction: direction
    };
    try {
      const ui = this.getUIContext(), host = ui.getAttachedFrameNodeById('reader-four-surface-host'),
        node = ui.getAttachedFrameNodeById('reader-chapter-surface-' + this.currentSlot);
      if (host !== null && node !== null) {
        const origin = host.getPositionToWindowWithTransform(), position = node.getPositionToWindowWithTransform();
        state.nativeX = position.x - origin.x; state.nativeY = position.y - origin.y;
      }
    } catch (_) {}
    return state;
  }

  private traceSelection(event: SelectionTraceEvent, sampleWeb: boolean = false, direction: number = 0,
    webX?: number, webY?: number): void {
    if (!SelectionGestureTrace.enabled()) return;
    const state = this.selectionTraceState(direction); state.webEventX = webX; state.webEventY = webY;
    const sequence = SelectionGestureTrace.record(event, state);
    if (sampleWeb && sequence > 0) this.traceSelectionWeb(sequence);
  }

  private traceSelectionWeb(sequence: number): void {
    if (!this.alive || !this.ready || !SelectionGestureTrace.enabled()) return;
    if (this.selectionTracePending) { this.selectionTraceQueued = sequence; return; }
    this.selectionTracePending = true;
    const generation = this.generation, slot = this.currentSlot, revision = this.layoutRevision, epoch = this.navigationEpoch,
      unit = this.pageUnit, motion = this.motionGeneration, offset = this.dragOffset, layer = this.surfaceLayout.slot;
    // Only numeric viewport/scroll state and a selection-present boolean. No range/text/locator query.
    runSurfaceScript(this.controllers[slot], "JSON.stringify((function(){var f=document.querySelector('iframe'),d=f&&f.contentDocument,w=d&&d.defaultView,s=d&&d.getSelection();return {outerX:scrollX,outerY:scrollY,innerX:w?w.scrollX:0,innerY:w?w.scrollY:0,viewport:innerWidth,selected:!!s&&!s.isCollapsed};})())")
      .then((raw: string): void => {
        if (!this.alive || generation !== this.generation) return;
        const state = this.selectionTraceState(); state.forEvent = sequence;
        if (slot !== this.currentSlot || revision !== this.layoutRevision || epoch !== this.navigationEpoch ||
          unit !== this.pageUnit || motion !== this.motionGeneration || offset !== this.dragOffset || layer !== this.surfaceLayout.slot) {
          SelectionGestureTrace.record('web-stale', state); return;
        }
        const dom = JSON.parse(JSON.parse(raw) as string) as SelectionTraceDom;
        if (![dom.outerX, dom.outerY, dom.innerX, dom.innerY, dom.viewport].every((value: number): boolean => Number.isFinite(value)) ||
          typeof dom.selected !== 'boolean') return;
        state.dom = dom; SelectionGestureTrace.record('web-position', state);
      }).catch((): void => {
        if (this.alive && generation === this.generation) SelectionGestureTrace.record('web-unavailable', this.selectionTraceState());
      }).finally((): void => {
        this.selectionTracePending = false;
        const queued = this.selectionTraceQueued; this.selectionTraceQueued = 0;
        if (queued > 0 && this.alive && generation === this.generation) this.traceSelectionWeb(queued);
      });
  }

  private nativeSelectionMenuChanged(slot: number, visible: boolean): void {
    if (!this.alive || !this.ready || slot !== this.currentSlot || this.nativeSelectionCancelled) return;
    this.selectionTraceAdjusting = !visible;
    this.traceSelection(visible ? 'menu-show' : 'menu-hide', true);
    this.selectionGate.nativeMenuChanged(this.activeSession, visible);
    this.observeActualSelectionInput(visible ? 'menu-show' : 'menu-hide');
    if (!visible) this.callbacks.onSelectionAdjusting(this.activeSession);
    else if (this.pendingNativeSelection) this.selectionEvent(slot, this.pendingNativeSelection);
  }

  private nativeSelectionTouch(event: TouchEvent, slot: number): void {
    if (event.type === TouchType.Down) this.readOnlyObservation?.focusObserved('body-touch');
    if (slot !== this.currentSlot) return;
    if (event.type === TouchType.Down || event.type === TouchType.Up || event.type === TouchType.Cancel)
      this.traceSelection(event.type === TouchType.Down ? 'down' : event.type === TouchType.Up ? 'up' : 'cancel', true);
    if (event.type === TouchType.Down) {
      this.revokeSelectionHighlight(); this.nativeSelectionCancelled = false;
      for (const touch of event.changedTouches) this.selectionGate.down(this.activeSession, touch.id);
    } else if (event.type === TouchType.Up) {
      for (const touch of event.changedTouches) this.selectionGate.up(this.activeSession, touch.id);
    } else if (event.type === TouchType.Cancel) {
      this.dispatch({ type: 'clearSelection' });
    }
    this.observeActualSelectionInput(event.type === TouchType.Down ? 'touch-down' :
      event.type === TouchType.Up ? 'touch-up' : event.type === TouchType.Cancel ? 'touch-cancel' : 'touch-move');
  }

  private nativeSelectionAction(action: 'copy' | 'note' | 'translate'): void {
    if (!this.selectionGate.canPublish(this.activeSession, this.nativeSelectionRevision) || !this.selectionText) return;
    if (action === 'translate' && !this.nativeSelectionEnglish) return;
    const session = this.activeSession, revision = this.nativeSelectionRevision, generation = this.generation;
    this.callbacks.onSelectionAction?.(session, action, this.selectionToken, this.selectionText, this.selectionCfi, (): void => {
      if (session !== this.activeSession || revision !== this.nativeSelectionRevision || generation !== this.generation) return;
      this.dispatch({ type: 'clearSelection' }); this.dispatch({ type: 'focusContent' });
    });
  }

  private revokeSelectionHighlight(): void {
    this.highlightRevision = -1; this.highlightSession = -1; this.highlightText = ''; this.highlightToken = '';
    this.highlightPresentationPending = false; this.highlightRequested = false; this.highlightContextPending = false; this.highlightContext = undefined;
  }

  private selectionHighlightTouch(event: TouchEvent): void {
    if (event.type === TouchType.Cancel) { this.revokeSelectionHighlight(); return; }
    if (event.type !== TouchType.Down) return;
    this.revokeSelectionHighlight();
    if (!this.selectionGate.canPublish(this.activeSession, this.nativeSelectionRevision)) return;
    this.highlightRevision = this.nativeSelectionRevision; this.highlightText = this.selectionText; this.highlightToken = this.selectionToken;
    this.highlightSession = this.activeSession; this.highlightGeneration = this.generation; this.highlightNavigationEpoch = this.navigationEpoch;
    this.highlightSlot = this.currentSlot; this.highlightSlotVersion = this.slotVersions[this.currentSlot]; this.highlightLayoutRevision = this.layoutRevision;
    this.highlightPresentationPending = true;
    this.highlightContextPending = true;
    const session = this.activeSession, revision = this.highlightRevision;
    this.requestSelectionContext(this.highlightToken, session,
      this.selectionMenuMarks.filter((mark: ReaderTextMark): boolean => mark.kind === 'highlight'), undefined,
      (context?: ReadingSelectionContext): void => {
        if (!this.selectionHighlightValid(session) || revision !== this.highlightRevision) return;
        this.highlightContext = context; this.highlightContextPending = false;
        if (this.highlightRequested) this.saveSelectionHighlight();
      });
  }

  private selectionHighlightValid(session: number): boolean {
    return this.alive && this.ready && session === this.activeSession && session === this.highlightSession &&
      this.highlightRevision === this.nativeSelectionRevision && this.highlightText.length > 0 &&
      !this.relayouting && !this.navigating && !this.moving && this.generation === this.highlightGeneration &&
      this.navigationEpoch === this.highlightNavigationEpoch && this.currentSlot === this.highlightSlot &&
      this.slotVersions[this.currentSlot] === this.highlightSlotVersion && this.layoutRevision === this.highlightLayoutRevision;
  }

  private saveSelectionHighlight(): void {
    const session = this.activeSession;
    if (!this.selectionHighlightValid(session)) return;
    this.highlightRequested = true;
    if (this.highlightContextPending) return;
    const context: ReadingSelectionContext = this.highlightContext ?? {
      selectionToken: this.highlightToken, selectedText: this.highlightText, kind: 'passage', markConflict: 'unavailable'
    };
    this.revokeSelectionHighlight();
    this.callbacks.onSelectionMarkContext?.(session, context);
  }

  private adjustActionWidthVp(): number {
    try {
      const ui = this.getUIContext();
      const measured = ui.getMeasureUtils().measureTextSize({ textContent: '保存范围', fontSize: '14fp' });
      return Math.max(64, ui.px2vp(Number(measured.width)) + 16);
    } catch (_) { return 104; }
  }

  @Builder private nativeSelectionMarkAndLookup() {
    if (!this.selectionMenuAdjusting) {
      Button('高亮').id('reader-selection-highlight').height(48).width(this.nativeSelectionNarrow ? 48 : 64).padding(0).fontSize(14)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))
        .onTouch((event: TouchEvent): void => this.selectionHighlightTouch(event))
        .onClick((): void => this.saveSelectionHighlight())
    }
    if (this.nativeSelectionEnglish) {
      Button('查词').id('reader-selection-lookup').height(48).width(this.nativeSelectionNarrow ? 48 : 64).padding(0).fontSize(14)
        .type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))
        .onClick((): void => this.nativeSelectionAction('translate'))
    }
  }

  @Builder private nativeSelectionMenu() {
    WithTheme({ colorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT }) {
      Row() {
          Button('复制').id('reader-selection-copy').height(48).width(this.nativeSelectionNarrow ? 48 : 64).padding(0).fontSize(14)
            .type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))
            .onClick((): void => this.nativeSelectionAction('copy'))
          Button(this.selectionMenuAdjusting ? '保存范围' : '笔记').id('reader-selection-note').height(48)
            .width(this.selectionMenuAdjusting ? this.adjustActionWidthVp() : (this.nativeSelectionNarrow ? 48 : 64)).padding(0).fontSize(14)
            .type(ButtonType.Normal).backgroundColor(Color.Transparent).fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))
            .onClick((): void => this.nativeSelectionAction('note'))
        this.nativeSelectionMarkAndLookup()
      }.padding({ left: 4, right: 4 }).borderRadius(24)
        .onAppear((): void => this.observeActualSelectionInput('menu-content-created'))
        .attributeModifier(new NativeSelectionMenuMaterial(this.settings.theme === 'eye-comfort' ? undefined : this.menuMaterial,
          this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') : $r('app.color.reader_surface_light'))))
    }
  }

  @Builder private surface(slot: number) {
    Web({ src: $rawfile('web-reader-surfaces/index.html'), controller: this.controllers[slot] })
      .id(`reader-chapter-surface-${slot}`)
      .focusable(true)
      .onKeyPreIme((event: KeyEvent): boolean => {
        if (slot !== this.currentSlot || !this.ready || this.relayouting || event.keyCode !== KeyCode.KEYCODE_F8) return false;
        if (event.type === KeyType.Up) this.callbacks.onControlsToggle(this.activeSession);
        return true;
      })
      .onBlur((): void => {
        if (slot === this.currentSlot && !this.highlightPresentationPending && this.selectionToken.length > 0) {
          this.traceSelection('blur-clear', true);
          this.dispatch({ type: 'clearSelection' });
        }
      })
      .width(this.viewportWidth > 0 ? this.viewportWidth : '100%')
      .height(this.viewportHeight > 0 ? this.viewportHeight : '100%')
      .backgroundColor(this.readerBackground)
      .javaScriptAccess(true)
      .fileAccess(false)
      .onlineImageAccess(true)
      .blockNetwork(true)
      .domStorageAccess(false)
      .databaseAccess(false)
      .geolocationAccess(false)
      .zoomAccess(false)
      .bindSelectionMenu(WebElementType.TEXT, this.nativeSelectionMenu(), WebResponseType.LONG_PRESS, {
        onMenuShow: (): void => this.nativeSelectionMenuChanged(slot, true),
        onMenuHide: (): void => this.nativeSelectionMenuChanged(slot, false)
      })
      .javaScriptProxy({ object: this.bridge, name: 'ChapterBridge',
        methodList: ['catalog', 'selection', 'block', 'tap', 'markTap', 'selectionEvent', 'adjusting', 'link', 'takePacket',
        'sourceDone', 'packetDone', 'loadDone', 'layoutDone', 'viewportChanged'],
        controller: this.controllers[slot] })
      .onInterceptRequest((event) => {
        const url = event.request.getRequestUrl();
        if (url.startsWith('resource:') || url.startsWith('data:') || url === 'about:blank' ||
          url.startsWith('resource://RAWFILE/')) return null;
        return this.resources?.intercept(slot, event.request) ?? null;
      })
      .onPageEnd((): void => this.shellLoaded(slot))
      .onTouch((event: TouchEvent): void => {
        this.nativeSelectionTouch(event, slot);
        if (event.type === TouchType.Up && this.ready && slot === this.currentSlot) {
          runSurfaceScript(this.controllers[slot], 'Surface.selectionSettled()').catch((): void => {});
        }
      })
      .onScroll((event): void => {
        if (!SelectionGestureTrace.enabled() || !this.ready || slot !== this.currentSlot) return;
        const now = SelectionGestureTrace.now();
        if (now - this.selectionTraceScrollAt < 40) return;
        this.selectionTraceScrollAt = now;
        this.traceSelection('web-scroll', false, 0, event.xOffset, event.yOffset);
      })
      .translate({ x: this.stagingSlots[slot] ? 0 : this.surfacePosition(slot) })
      .zIndex(this.stagingSlots[slot] ? -1 : 0)
      .opacity(this.readable ? 1 : 0)
  }

  build() {
    Stack() {
      Web({ src: $rawfile('web-reader-surfaces/source-host.html'), controller: this.sourceController })
        .id('reader-publication-source')
        .width(1).height(1).opacity(0).focusable(false).zIndex(-2)
        .javaScriptAccess(true).fileAccess(false).blockNetwork(true)
        .onlineImageAccess(false).domStorageAccess(false).databaseAccess(false)
        .geolocationAccess(false)
        .javaScriptProxy({ object: this.bridge, name: 'ChapterBridge',
          methodList: ['catalog', 'sourceDone', 'packetDone'], controller: this.sourceController })
        .onInterceptRequest((event) => {
          const url = event.request.getRequestUrl();
          if (url.startsWith('resource:')) return null;
          return this.resources?.intercept(0, event.request) ?? null;
        })
        .onPageEnd((): void => { this.sourceShellLoaded = true; this.beginSource(); })
      ForEach([0, 1, 2, 3], (slot: number) => {
        this.surface(slot)
      }, (slot: number) => slot.toString())
      if (this.ready && (this.relayouting || this.relayoutFailed)) {
        Row().width('100%').height('100%').backgroundColor(this.readerBackground)
      }
      if (this.relayoutFailed) {
        Button('页面排版未完成，点此重试')
          .backgroundColor(this.readerBackground)
          .fontColor('#29343b')
          .onClick((): void => this.requestRelayout())
      }
    }
    .id('reader-four-surface-host').width('100%')
    .height('100%')
    .clip(true)
    .backgroundColor(this.readerBackground)
    .onAreaChange((_before: Area, area: Area): void => {
      const width = Number(area.width);
      const height = Number(area.height);
      let changed = false;
      if (Number.isFinite(width) && width > 0 && width !== this.viewportWidth) {
        this.viewportWidth = width;
        changed = true;
      }
      if (Number.isFinite(height) && height > 0 && height !== this.viewportHeight) {
        this.viewportHeight = height;
        changed = true;
      }
      if (changed) this.requestRelayout();
    })
    .parallelGesture(PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
      .onActionStart((): void => {
        this.grab();
        if (this.gestureActive) this.callbacks.onContactState?.(this.activeSession, 'active');
      })
      .onActionUpdate((event: GestureEvent): void => { this.drag(event); })
      .onActionEnd((event: GestureEvent): void => { this.release(event.velocityX); })
      .onActionCancel((): void => {
        this.traceSelection('pan-cancel', true);
        const hadGesture = this.gestureActive;
        // A fold can cancel PanGesture before its normal release threshold is reached.
        const interruptedTurn = hadGesture &&
          this.layoutRevision !== this.gestureStartRevision ?
          this.interruptedGestureDirection() : 0;
        this.gestureActive = false;
        this.dragging = false;
        this.gestureDuringRelayout = false;
        if (!hadGesture) return;
        if (interruptedTurn !== 0) {
          this.page(interruptedTurn);
          return;
        }
        if (this.animateCustomMotion) this.turn(0, 0);
      }))
    .onGestureJudgeBegin((): GestureJudgeResult => {
      const reject = this.selectedSlots[this.currentSlot] || this.blockedSlots[this.currentSlot] || this.relayoutFailed;
      this.traceSelection(reject ? 'judge-reject' : 'judge-continue');
      this.observeActualSelectionInput(reject ? 'page-judge-reject' : 'page-judge-continue');
      return reject ? GestureJudgeResult.REJECT : GestureJudgeResult.CONTINUE;
    })
  }
}
