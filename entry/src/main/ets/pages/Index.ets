import { LibraryPathTreeContent, LibraryPathTreeRow } from '../components/LibraryPathTreeContent';
import { common } from '@kit.AbilityKit';
import { nonReadingPageTransition } from '../layout/NonReadingMotion';
import { NativeOverlayMaterials, loadNativeOverlayMaterials, nativeMenuOptions, nativeAlertOptions, nativeSheetOptions } from '../platform/NativeOverlayMaterial';
import { READER_DIAGNOSTICS_ENABLED } from 'BuildProfile';
import { shellMotionObservation } from '../diagnostics/ShellMotionObservation';
import { window, SymbolGlyphModifier } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book, BookmarkPoint, ReaderTheme, ReadingProgress } from '../domain/Models';
import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { SystemColorMode } from '../domain/AppearancePolicy';
import { BookDeleteResult, LibraryPage, LibraryPageController } from './LibraryPage';
import { LibraryFolder } from '../domain/LibraryOrganization';
import { bookshelfColor, bookshelfThemeColorMode } from '../layout/BookshelfThemePalette';
import { ReaderPage, ReaderPageController } from './ReaderPage';
import { ImportResult } from '../services/BookImportService';
import { LibraryEntry } from '../services/LibraryQueryService';
import { SettingsEntrySource, SettingsPage, SettingsPageController } from './SettingsPage';
import { BookshelfBackground } from '../components/BookshelfBackground';
import { PrivacyNotice } from '../components/PrivacyNotice';
import { BookOpeningOverlay } from '../components/BookOpeningOverlay';
import {
  ReaderOpenScenario,
  classifyReaderOpenEpubSize,
  classifyReaderOpenRestoreDepth
} from '../diagnostics/ReaderOpenDiagnosticsContract';
import { readerOpenDiagnostics } from '../diagnostics/ReaderOpenDiagnostics';
import { ReaderLifecycleState, ReaderSessionLifecycle } from '../reader/ReaderSessionLifecycle';
import { ReaderFatalErrorCategory } from '../reader/ReaderEngine';
import {
  ReaderApplicationLifecycleHandler,
  readerApplicationLifecycle
} from '../reader/ReaderApplicationLifecycle';
import { SafeLog } from '../diagnostics/SafeLog';
import { ApplicationRuntime } from '../application/ApplicationRuntime';
import { LibraryApplication } from '../application/LibraryApplication';
import { ProductDestination } from '../shell/ProductShellState';
import { LibraryBrowseState, createLibraryBrowseState } from '../shell/LibraryBrowseState';
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT
} from '../layout/AdaptiveLayoutPolicy';
import { adaptiveWindowLifecycle } from '../layout/AdaptiveWindowLifecycle';
import { BatchImportSnapshot } from '../application/BatchImportCoordinator';
import { BatchImportPage, BatchImportPageController } from './BatchImportPage';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';
import { MinePage } from './MinePage';
import { MineLibrarySummary, projectMineLibrary } from '../application/MineLibraryProjection';
import { RecordKind, ReadingRecordRow } from '../application/ReadingRecordsApplication';
import { ReadingRecordsPage, ReadingRecordsPageController } from './ReadingRecordsPage';

const APP_BUNDLE_NAME: string = 'com.yedeng.reader';

class IndexReaderApplicationLifecycleHandler implements ReaderApplicationLifecycleHandler {
  private background: () => void;
  private foreground: () => void;

  constructor(background: () => void, foreground: () => void) {
    this.background = background;
    this.foreground = foreground;
  }

  onBackground(): void {
    this.background();
  }

  onForeground(): void {
    this.foreground();
  }
}

@Entry
@Component
struct Index {
  @State private overlayMaterials: NativeOverlayMaterials = {};
  @State @Watch('updateMineSummary') private entries: LibraryEntry[] = [];
  @State private mineSummary: MineLibrarySummary = { bookCount: 0, openedBookCount: 0 };
  @State private libraryBrowse: LibraryBrowseState = createLibraryBrowseState();
  @State private libraryRefreshFailed: boolean = false;
  private libraryRequestGeneration: number = 0;
  private mounted: boolean = false;
  @State private loading: boolean = true;
  @State private message: string = '';
  @State private activeBook?: Book = undefined;
  @State private activeProgress?: ReadingProgress = undefined;
  @State private readerHostBook?: Book = undefined;
  @State private readerCanvasTheme?: ReaderTheme = undefined;
  @State private readerControlsVisible: boolean = true;
  @State @Watch('syncShellTab') private destination: ProductDestination = 'library';
  @State private shellTabIndex: number = 0;
  @State private pathTreeVisible: boolean = false;
  private pathTreePresented: boolean = false;
  private pendingPathFolderId?: string;
  @State private expandedFolders: string[] = [];
  @State private librarySelecting: boolean = false;
  @State private systemReducedMotion: boolean | undefined = undefined;
  private unsubscribeSystemMotion?: () => void;
  private settingsReturnDestination: ProductDestination = 'mine';
  private settingsFromReader: boolean = false;
  private readerReturnDestination: ProductDestination = 'library';
  @State private recordsKind: RecordKind = 'notes';
  private recordsController: ReadingRecordsPageController = new ReadingRecordsPageController();
  @State private importing: boolean = false;
  @State private checkingBook: boolean = false;
  @State private batchState: BatchImportSnapshot = { phase: 'idle', items: [], activeIndex: -1, limit: 4 };
  private openCancelled: boolean = false;
  private resumeOpening?: () => void;
  private batchAnnouncementSignature: string = '';
  @State private readerState: ReaderLifecycleState = 'idle';
  @State private quarantinedOrphanCount: number = 0;
  @State private systemFontScale: number = 1;
  @State private windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  @State private bookshelfTheme: BookshelfTheme = 'default';
  @State private bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @State private systemColorMode: SystemColorMode = 'light';
  @State private privacyStatus: 'checking' | 'required' | 'accepted' | 'unavailable' = 'checking';
  @State private privacyPolicyText: string = '';
  @State private showingFullPrivacyPolicy: boolean = false;
  @State private privacyError: string = '';
  private runtime: ApplicationRuntime = new ApplicationRuntime();
  private library?: LibraryApplication;
  private context?: common.UIAbilityContext;
  private readerPageController: ReaderPageController = new ReaderPageController();
  private settingsPageController: SettingsPageController = new SettingsPageController();
  private libraryPageController: LibraryPageController = new LibraryPageController();
  private batchPageController: BatchImportPageController = new BatchImportPageController();
  private readerSessionId: number = 0;
  private readerLifecycle: ReaderSessionLifecycle = new ReaderSessionLifecycle();
  private unsubscribeLifecycle?: () => void;
  private unsubscribeAdaptiveWindow?: () => void;
  private unsubscribeSystemColorMode?: () => void;
  private shellBarUpdate: Promise<void> = Promise.resolve();

  aboutToAppear(): void {
    this.mounted = true;
    loadNativeOverlayMaterials().then((materials: NativeOverlayMaterials): void => {
      if (this.mounted) this.overlayMaterials = materials;
    }).catch((): void => {});
    this.systemColorMode = this.runtime.readerAppearance.currentSystemMode();
    this.unsubscribeAdaptiveWindow = adaptiveWindowLifecycle.subscribe((snapshot: AdaptiveWindowSnapshot): void => {
      this.windowSnapshot = snapshot;
    });
    const lifecycleHandler: ReaderApplicationLifecycleHandler =
      new IndexReaderApplicationLifecycleHandler(
        (): void => { this.readerBackgrounded(); },
        (): void => { this.readerForegrounded(); });
    this.unsubscribeLifecycle = readerApplicationLifecycle.subscribe(lifecycleHandler);
    this.preparePrivacy().catch((): void => { this.privacyStatus = 'unavailable'; });
  }

  private async preparePrivacy(): Promise<void> {
    try {
      this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = await this.context.resourceManager.getRawFileContent('privacy/yedeng-privacy-policy.txt');
      const policy = new util.TextDecoder('utf-8').decodeToString(bytes);
      if (!policy.startsWith('页灯隐私政策') || !policy.includes('更新日期：2026 年 9 月 28 日')) {
        throw new Error('Bundled privacy policy is unavailable');
      }
      this.privacyPolicyText = policy.substring(policy.indexOf('\n') + 1).trimStart();
      this.runtime.privacyConsent.initialize(this.context);
      this.privacyStatus = this.runtime.privacyConsent.hasAcceptedCurrentPolicy() ? 'accepted' : 'required';
      if (this.privacyStatus === 'accepted') this.startRuntime();
    } catch (_) {
      this.privacyStatus = 'unavailable';
    }
  }

  private startRuntime(): void {
    this.initialize().catch((): void => {
      this.loading = false;
      this.message = '打开书库失败，请重启应用。';
    });
  }

  private acceptPrivacy(): void {
    try {
      this.runtime.privacyConsent.acceptCurrentPolicy();
      this.privacyStatus = 'accepted';
      this.startRuntime();
    } catch (_) {
      this.privacyError = '保存选择失败，请重试。';
    }
  }

  private declinePrivacy(): void {
    this.context?.terminateSelf().catch((): void => {});
  }

  private async initialize(): Promise<void> {
    this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.refreshSystemFontScale();
    const initialized = await this.runtime.initialize(this.context);
    // B is the current presentation. The former artistic preference remains in its repository.
    this.bookshelfTheme = 'default';
    this.bookshelfDefaultMode = this.runtime.libraryPresentation.loadDefaultMode();
    this.systemColorMode = this.runtime.readerAppearance.currentSystemMode();
    this.unsubscribeSystemColorMode = this.runtime.readerAppearance.subscribeSystemColorMode((): void => {
      this.systemColorMode = this.runtime.readerAppearance.currentSystemMode();
      if (this.bookshelfTheme === 'default' && this.bookshelfDefaultMode === 'system') this.updateShellBars();
    });
    this.updateShellBars();
    this.library = this.runtime.library();
    this.unsubscribeSystemMotion = this.runtime.readerAppearance.subscribeSystemMotion((reduced: boolean | undefined): void => {
      this.systemReducedMotion = reduced;
    });
    this.quarantinedOrphanCount = initialized.reconciliation.retainedQuarantinedOrphans;
    await this.refreshLibrary();
  }

  aboutToDisappear(): void {
    this.mounted = false; this.libraryRequestGeneration++;
    this.cancelOpeningCheck();
    this.unsubscribeAdaptiveWindow?.();
    this.unsubscribeAdaptiveWindow = undefined;
    this.unsubscribeLifecycle?.();
    this.unsubscribeLifecycle = undefined;
    this.unsubscribeSystemColorMode?.();
    this.unsubscribeSystemColorMode = undefined;
    this.unsubscribeSystemMotion?.(); this.unsubscribeSystemMotion = undefined;
    this.runtime.dispose();
  }

  private readerBackgrounded(): void {
    this.library?.setBatchForeground(false);
    if (!this.readerLifecycle.enterBackground(this.readerSessionId)) return;
    this.readerState = 'background';
    this.runtime.dictionaryService()?.cancelPending();
    this.runtime.readerSessions.flush(this.readerSessionId).catch((): void => {});
  }

  private readerForegrounded(): void {
    this.library?.setBatchForeground(true);
    this.refreshSystemFontScale();
    if (!this.readerLifecycle.enterForeground(this.readerSessionId)) return;
    this.readerState = this.readerLifecycle.state();
    this.resumeOpening?.();
    this.resumeOpening = undefined;
  }

  private refreshSystemFontScale(): void {
    const scale = Number(this.context?.config.fontSizeScale ?? 1);
    if (Number.isFinite(scale) && scale > 0) this.systemFontScale = scale;
  }

  onBackPress(): boolean {
    if (this.privacyStatus !== 'accepted') {
      if (this.showingFullPrivacyPolicy) this.showingFullPrivacyPolicy = false;
      return true;
    }
    if (this.checkingBook || (this.destination === 'reader' && this.readerState === 'opening')) {
      this.cancelReaderOpening();
      return true;
    }
    if (this.batchState.phase === 'review') {
      if (this.batchPageController.handleSystemBack()) return true;
      this.batchState = this.library?.cancelBatchReview() ?? this.batchState;
      return true;
    }
    if (this.batchState.phase === 'results') {
      this.batchState = this.library?.resetBatchResults() ?? this.batchState;
      return true;
    }
    if (this.batchState.phase === 'running') {
      this.getUIContext().showAlertDialog(nativeAlertOptions(this.overlayMaterials.panel, {
      backgroundColor: bookshelfColor('default', 'surface', this.resolvedInterfaceMode()),
        title: '取消剩余导入？',
        message: '已经完成的书籍会保留；当前未提交项和后续项目将停止。',
        primaryButton: { value: '继续等待', action: (): void => {} },
        secondaryButton: { value: '取消剩余导入', action: (): void => { this.library?.cancelBatch(); } }
      }));
      return true;
    }
    if (this.destination === 'settings') {
      if (!this.settingsPageController.handleSystemBack()) {
        this.closeSettings(this.settingsPageController.entrySource());
      }
      return true;
    }
    if (this.destination === 'records') {
      if (!this.recordsController.handleBack()) this.closeReadingRecords();
      return true;
    }
    if (this.pathTreeVisible || this.pathTreePresented) { this.setPathTreeVisible(false); return true; }
    if (this.destination === 'library') return this.libraryPageController.handleSystemBack();
    if (this.destination !== 'reader' || this.activeBook === undefined) return false;
    if (!this.readerPageController.handleSystemBack()) {
      this.closeReader().catch((): void => {});
    }
    return true;
  }

  private async closeReader(): Promise<void> {
    const sessionId = this.readerSessionId;
    if (!this.readerLifecycle.beginClosing(sessionId)) return;
    this.runtime.dictionaryService()?.cancelPending();
    try {
      await this.runtime.readerSessions.flush(sessionId);
      const rollback = await this.library?.rollbackPrepared(sessionId);
      if (rollback === 'cleanup-pending') this.message = '导入未完成，请重试。';
    } finally {
      this.runtime.readerSessions.invalidate(sessionId);
      // Publish current progress/order before revealing the returning Grid.
      // Updating it after reveal exposes a second, visibly different layout.
      await this.refreshLibrary();
      this.activeBook = undefined;
      this.activeProgress = undefined;
      this.readerHostBook = undefined;
      this.readerCanvasTheme = undefined;
      this.destination = this.readerReturnDestination;
      this.readerLifecycle.finishClosing(sessionId);
      this.readerState = 'idle';
    }
  }

  private async refreshLibrary(): Promise<void> {
    const library = this.library;
    if (library === undefined) return;
    const generation = ++this.libraryRequestGeneration;
    this.loading = this.entries.length === 0;
    try {
      const entries = await library.listEntries();
      if (!this.mounted || generation !== this.libraryRequestGeneration) return;
      this.entries = entries; this.libraryRefreshFailed = false;
    } catch (_) {
      if (!this.mounted || generation !== this.libraryRequestGeneration) return;
      this.libraryRefreshFailed = true;
    } finally {
      if (this.mounted && generation === this.libraryRequestGeneration) this.loading = false;
    }
  }

  private updateMineSummary(): void {
    this.mineSummary = projectMineLibrary(this.entries);
  }

  private async chooseImport(): Promise<void> {
    if (this.context === undefined || this.library === undefined || this.checkingBook || this.importing ||
      this.batchState.phase === 'running' || this.batchState.phase === 'results') return;
    this.message = '';
    this.importing = true;
    const targetFolderId = this.batchState.phase === 'review' ?
      (this.batchState.targetFolderId ?? '') : this.libraryBrowse.folderId;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = this.batchState.limit;
      options.fileSuffixFilters = ['EPUB|.epub', 'TXT|.txt'];
      SafeLog.event('picker-requested');
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      if (uris.length > 0) {
        this.batchState = this.library.addBatchSelection(uris, targetFolderId);
        this.batchState = await this.library.checkBatchTextEncoding();
      }
    } catch (_) {
      this.message = '';
    } finally {
      this.importing = false;
    }
  }

  private removeBatchItem(id: number): void {
    this.batchState = this.library?.removeBatchItem(id) ?? this.batchState;
  }

  private batchTargetLabel(): string {
    const target = this.batchState.targetFolderId ?? '';
    if (!target) return '书库';
    const names: string[] = [];
    let cursor = target;
    while (cursor && names.length < 32) {
      const folder = this.libraryBrowse.folders.find((item): boolean => item.folderId === cursor);
      if (folder === undefined) return '原目录已不可用，导入将失败；请取消并重新选择。';
      names.unshift(folder.name); cursor = folder.parentId;
    }
    return ['书库', ...names].join(' / ');
  }


  private batchItemAnnouncement(status: string): string {
    if (status === 'stored') return '已导入';
    if (status === 'restored') return '已恢复';
    if (status === 'duplicate') return '已有同一文件';
    if (status === 'rejected') return '未通过安全检查';
    if (status === 'failed') return '导入失败';
    if (status === 'cancelled') return '已取消';
    if (status === 'not-started') return '未开始';
    return '正在处理';
  }

  private batchAnnouncement(snapshot: BatchImportSnapshot): string | undefined {
    if (snapshot.phase === 'running' && snapshot.activeIndex >= 0) {
      const item = snapshot.items[snapshot.activeIndex];
      if (item === undefined) return undefined;
      return `第 ${snapshot.activeIndex + 1} 本，共 ${snapshot.items.length} 本，${this.batchItemAnnouncement(item.status)}。`;
    }
    if (snapshot.phase !== 'results') return undefined;
    const labels: string[] = [];
    const statuses: string[] = ['stored', 'restored', 'duplicate', 'rejected', 'failed', 'cancelled', 'not-started'];
    for (const status of statuses) {
      const count = snapshot.items.filter((item): boolean => item.status === status).length;
      if (count > 0) labels.push(`${this.batchItemAnnouncement(status)} ${count} 本`);
    }
    return labels.length > 0 ? `导入完成。${labels.join('，')}。` : '导入完成。';
  }

  private applyBatchSnapshot(snapshot: BatchImportSnapshot): void {
    this.batchState = snapshot;
    const announcement = this.batchAnnouncement(snapshot);
    if (announcement === undefined) return;
    const signature = `${snapshot.phase}:${snapshot.activeIndex}:${snapshot.items.map((item): string => item.status).join(',')}`;
    if (signature === this.batchAnnouncementSignature) return;
    this.batchAnnouncementSignature = signature;
    const event = new accessibility.EventInfo('announceForAccessibility', APP_BUNDLE_NAME, 'common');
    event.textAnnouncedForAccessibility = announcement;
    accessibility.sendAccessibilityEvent(event).catch((): void => {});
  }

  private async confirmBatch(): Promise<void> {
    if (this.library === undefined || this.batchState.phase !== 'review') return;
    await this.library.runBatch((snapshot: BatchImportSnapshot): void => { this.applyBatchSnapshot(snapshot); });
    await this.refreshLibrary();
  }

  private finishBatch(): void {
    this.batchState = this.library?.resetBatchResults() ?? this.batchState;
    this.refreshLibrary().catch((): void => {});
  }

  private openBatchBook(book: Book): void {
    this.batchState = this.library?.resetBatchResults() ?? this.batchState;
    this.openBook(book).catch((): void => {});
  }

  private async chooseRepair(book: Book): Promise<void> {
    if (this.context === undefined || this.library === undefined || this.checkingBook || this.importing) return;
    this.message = '';
    this.importing = true;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['EPUB|.epub', 'TXT|.txt'];
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      const result = await this.library.repair(book, uris.length > 0 ? uris[0] : undefined);
      await this.handleImportResult(result);
    } catch (_) {
      this.message = '';
    } finally {
      this.importing = false;
    }
  }

  private async handleImportResult(result: ImportResult): Promise<void> {
    if (result.book !== undefined && result.status === 'duplicate') {
      await this.openBook(result.book);
      return;
    }
    if (result.book !== undefined && result.operationId !== undefined && result.operationKind !== undefined &&
      (result.status === 'prepared-new' || result.status === 'prepared-repair')) {
      await this.openBook(result.book);
      return;
    }
    this.message = result.message ?? '';
  }

  private cancelOpeningCheck(): void {
    if (!this.checkingBook) return;
    this.openCancelled = true;
    this.library?.cancelOpenCheck();
    this.resumeOpening?.();
    this.resumeOpening = undefined;
  }

  private cancelReaderOpening(): void {
    if (this.checkingBook) {
      this.cancelOpeningCheck();
    } else if (this.destination === 'reader' && this.readerState === 'opening') {
      this.closeReader().catch((): void => {});
    }
  }

  private async endOpeningCheck(sessionId: number, message?: string): Promise<void> {
    const rollback = await this.library?.rollbackPrepared(sessionId);
    if (rollback === 'cleanup-pending') message = '导入未完成，请重试。';
    if (this.readerLifecycle.sessionId() !== sessionId) return;
    this.readerLifecycle.beginClosing(sessionId);
    this.readerLifecycle.finishClosing(sessionId);
    this.readerState = 'idle';
    this.message = message ?? '';
    readerOpenDiagnostics.fail(sessionId, 'reader-session');
  }

  private async openBook(book: Book, initialBookmark?: BookmarkPoint): Promise<void> {
    if (this.library === undefined || this.checkingBook) return;
    if (book.sourceState === 'missing' && !this.library.hasPreparedBook(book.bookId)) {
      this.showMissingSourceActions(book);
      return;
    }
    const previousSessionId = this.readerSessionId;
    this.readerReturnDestination = this.destination === 'records' ? 'records' : 'library';
    const sessionId = previousSessionId + 1;
    if (!this.readerLifecycle.beginOpening(sessionId)) return;
    this.readerSessionId = sessionId;
    const settings = this.runtime.readerAppearance.loadSettings(book.bookId);
    this.readerCanvasTheme = this.runtime.readerAppearance.resolveSettings(settings).theme;
    this.checkingBook = true;
    this.openCancelled = false;
    this.readerState = 'opening';
    this.library.bindPreparedSession(book.bookId, sessionId);
    const coldWarm = this.readerHostBook === undefined ? 'cold' : 'warm';
    readerOpenDiagnostics.begin(sessionId, {
      coldWarm: coldWarm,
      epubSize: 'unknown',
      restoreDepth: 'start'
    });
    try {
      await this.runtime.readerSessions.flush(previousSessionId);
      readerOpenDiagnostics.mark(sessionId, 'previous_session_flushed');
      if (this.openCancelled) { await this.endOpeningCheck(sessionId); return; }
      readerOpenDiagnostics.mark(sessionId, 'source_check_started');
      const openState = await this.library.openState(book);
      if (openState.status !== 'ready' || this.openCancelled) {
        await this.endOpeningCheck(sessionId, openState.status === 'rejected' ? openState.message : undefined);
        return;
      }
      if (this.readerLifecycle.state() === 'background') {
        await new Promise<void>((resolve): void => { this.resumeOpening = resolve; });
      }
      if (this.openCancelled || this.readerLifecycle.sessionId() !== sessionId) {
        await this.endOpeningCheck(sessionId); return;
      }
      readerOpenDiagnostics.mark(sessionId, 'source_check_ready');
      const progress = openState.progress;
      const scenario: ReaderOpenScenario = {
        coldWarm: coldWarm,
        epubSize: classifyReaderOpenEpubSize(openState.epubBytes),
        restoreDepth: classifyReaderOpenRestoreDepth(progress?.location.percentage)
      };
      readerOpenDiagnostics.updateScenario(sessionId, scenario);
      if (this.readerHostBook === undefined) {
        this.readerHostBook = book;
      }
      this.activeProgress = progress;
      this.readerPageController.openSession({
        sessionId: sessionId,
        book: book,
        initialProgress: progress,
        initialBookmark: initialBookmark,
        initialSettings: settings,
      });
      readerOpenDiagnostics.mark(sessionId, 'page_session_bound');
      this.activeBook = book;
      // Keep the window canvas stable; the Reader host applies system safe insets.
      readerOpenDiagnostics.mark(sessionId, 'shell_layout_ready');
      this.destination = 'reader';
    } catch (_) {
      readerOpenDiagnostics.fail(sessionId, 'reader-session');
      await this.endOpeningCheck(sessionId, '无法打开这本书，请重试。');
    } finally {
      this.checkingBook = false;
      if (this.destination !== 'reader') this.readerCanvasTheme = undefined;
      this.resumeOpening = undefined;
    }
  }

  private async readerReady(sessionId: number): Promise<void> {
    if (this.activeBook === undefined || !this.readerLifecycle.markReady(sessionId)) return;
    this.readerState = this.readerLifecycle.state();
    if (this.library?.hasPreparedBook(this.activeBook.bookId) === true) {
      try {
        await this.library.commitPrepared(sessionId, this.activeBook);
      } catch (_) {
        const rollback = await this.library.rollbackPrepared(sessionId);
        this.activeBook = undefined;
        this.destination = 'library';
        this.message = rollback === 'cleanup-pending' ? '书籍未能加入书库，请重试。' :
          '书籍未能加入书库，请重新导入。';
        await this.refreshLibrary();
        return;
      }
    }
    await this.library?.markOpened(this.activeBook.bookId, Date.now());
  }

  private async readerFailed(sessionId: number, _category: ReaderFatalErrorCategory): Promise<void> {
    if (!this.readerLifecycle.markError(sessionId)) return;
    this.readerState = 'error';
    if (this.library !== undefined) {
      const rolledBack = await this.library.rollbackPrepared(sessionId);
      if (rolledBack !== 'none') {
        this.activeBook = undefined;
        this.destination = 'library';
        this.message = rolledBack === 'cleanup-pending' ? '无法打开这本书，请重试。' :
          '无法打开这本书，请重新导入。';
        await this.refreshLibrary();
      }
    }
  }

  private showMissingSourceActions(book: Book): void {
    this.getUIContext().showAlertDialog(nativeAlertOptions(this.overlayMaterials.panel, {
      backgroundColor: bookshelfColor('default', 'surface', this.resolvedInterfaceMode()),
      title: '找不到书籍文件',
      message: '请重新选择这本书的文件。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '重新选择文件', action: (): void => {
        this.chooseRepair(book).catch((): void => {});
      }}
    }));
  }

  private async cleanupOrphans(): Promise<void> {
    if (this.checkingBook || this.importing) return;
    if (this.library === undefined) return;
    const removed = await this.library.cleanupQuarantinedOrphans();
    this.quarantinedOrphanCount = Math.max(0, this.quarantinedOrphanCount - removed);
  }

  private async deleteBook(book: Book, reportFailure: boolean = true): Promise<boolean> {
    if (this.checkingBook || this.importing || this.library === undefined) return false;
    try {
      if (this.activeBook?.bookId === book.bookId) {
        await this.runtime.readerSessions.flush(this.readerSessionId);
        await this.closeReader();
      }
      await this.library.delete(book);
    } catch (_) {
      if (reportFailure) this.message = '删除未完成，请重试完成剩余步骤。';
      return false;
    }
    this.entries = this.entries.filter((entry: LibraryEntry): boolean => entry.book.bookId !== book.bookId);
    this.message = '';
    try { await this.refreshLibrary(); }
    catch (_) { this.message = '书籍已删除，书架刷新失败，请重新打开书库。'; }
    return true;
  }

  private async deleteSelectedBooks(books: Book[]): Promise<BookDeleteResult[]> {
    const results: BookDeleteResult[] = [];
    this.message = '';
    for (const book of books) {
      const succeeded = await this.deleteBook(book, false);
      results.push({ bookId: book.bookId, succeeded: succeeded });
    }
    return results;
  }

  private async renameBook(book: Book, title: string, author: string): Promise<boolean> {
    if (this.library === undefined || this.checkingBook || this.importing) return false;
    try {
      const renamed = await this.library.renameBook(book.bookId, title, author);
      this.entries = this.entries.map((entry: LibraryEntry): LibraryEntry =>
        entry.book.bookId === book.bookId ? { book: renamed, percentage: entry.percentage } : entry);
      if (this.activeBook?.bookId === book.bookId) this.activeBook = renamed;
      if (this.readerHostBook?.bookId === book.bookId) this.readerHostBook = renamed;
      this.message = '';
      return true;
    } catch (_) { return false; }
  }

  private openLibrarySettings(): void {
    if (this.checkingBook || this.importing || this.destination === 'settings') return;
    this.settingsFromReader = false;
    this.settingsReturnDestination = 'mine';
    this.settingsPageController.resetToRoot();
    // Animate the page transition, not the initial backgrounds of newly mounted Buttons.
    this.destination = 'settings';
    this.updateShellBars();
  }

  private openReadingSettings(): void {
    if (this.destination !== 'reader' || this.activeBook === undefined || this.readerState !== 'ready') return;
    this.settingsFromReader = true;
    this.settingsPageController.openSection('reading', 'reader');
    const covered = this.readerPageController.setSettingsCovered(true);
    this.destination = 'settings';
    covered.then((): void => {
      if (this.destination === 'settings') this.updateShellBars();
    }).catch((): void => {});
  }

  private closeSettings(source: SettingsEntrySource): void {
    if (this.destination !== 'settings') return;
    const returnReader = source === 'reader' && this.activeBook !== undefined && this.readerHostBook !== undefined;
    if (returnReader) this.settingsPageController.resetToRoot();
    this.animateShell('destination', 160, (): void => { this.destination = returnReader ? 'reader' : this.settingsReturnDestination; });
    if (returnReader) {
      this.readerPageController.syncConfirmedPreferences();
      this.readerPageController.setSettingsCovered(false).catch((): void => {});
    } else {
      this.updateShellBars();
    }
  }

  private syncInterfaceMode(): void {
    // Keep the accepted B presentation without overwriting legacy artwork preferences.
    this.bookshelfTheme = 'default';
    this.bookshelfDefaultMode = this.runtime.libraryPresentation.loadDefaultMode();
    this.updateShellBars();
  }

  private closeReadingRecords(): void {
    if (this.destination !== 'records') return;
    this.animateShell('destination', 160, (): void => { this.destination = 'mine'; });
    this.updateShellBars();
  }

  private resolvedInterfaceMode(): SystemColorMode {
    return this.bookshelfDefaultMode === 'system' ? this.systemColorMode : this.bookshelfDefaultMode;
  }

  private updateShellBars(): Promise<void> {
    if (this.context === undefined || this.destination === 'reader') return Promise.resolve();
    const context = this.context;
    const theme = this.bookshelfTheme;
    const mode = this.bookshelfDefaultMode === 'system' ? this.runtime.readerAppearance.currentSystemMode() :
      this.bookshelfDefaultMode;
    this.shellBarUpdate = this.shellBarUpdate.then(async (): Promise<void> => {
      if (!this.shellBarsApplicable()) return;
      const mainWindow = await window.getLastWindow(context);
      if (!this.shellBarsApplicable()) return;
      const art = theme !== 'default';
      const color = art ? '#00000000' : (mode === 'dark' ? '#131A21' : '#EFF2F5');
      const content = art || mode === 'dark' ? '#EEF3F8' : '#18212B';
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: color, statusBarContentColor: content,
        navigationBarColor: color, navigationBarContentColor: content
      });
    }).catch((): void => {});
    return this.shellBarUpdate;
  }

  private shellBarsApplicable(): boolean { return this.destination !== 'reader'; }

  private readerSafeAreaBackground(): ResourceColor {
    if (this.destination !== 'reader') {
      if (this.bookshelfTheme !== 'default') return Color.Transparent;
      return bookshelfColor('default', 'canvas', this.resolvedInterfaceMode());
    }
    if (this.readerCanvasTheme === 'dark') return this.readerControlsVisible ?
      $r('app.color.reader_surface_dark') : $r('app.color.reader_canvas_dark');
    if (this.readerCanvasTheme === 'eye-comfort') return this.readerControlsVisible ?
      $r('app.color.reader_surface_eye_comfort') : $r('app.color.reader_canvas_eye_comfort');
    if (this.readerCanvasTheme === 'light') return this.readerControlsVisible ?
      $r('app.color.reader_surface_light') : $r('app.color.reader_canvas_light');
    return $r('app.color.product_canvas');
  }

  @Builder
  private librarySortMenu() {
    Menu() {
      MenuItem({ content: '最近阅读' }).height(48)
        .selectIcon(true).selected(this.libraryBrowse.sort === 'recent').id('library-sort-recent')
        .onClick((): void => this.libraryPageController.setSort('recent'))
      MenuItem({ content: '书名' }).height(48)
        .selectIcon(true).selected(this.libraryBrowse.sort === 'title').id('library-sort-title')
        .onClick((): void => this.libraryPageController.setSort('title'))
      MenuItem({ content: '导入时间' }).height(48)
        .selectIcon(true).selected(this.libraryBrowse.sort === 'imported').id('library-sort-imported')
        .onClick((): void => this.libraryPageController.setSort('imported'))
    }
  }

  @Builder
  private libraryHeaderMenu() {
    Menu() {
        MenuItem({ content: '查看目录' }).id('library-shell-path-tree').height(48)
          .onClick((): void => this.openPathTree())
      MenuItem({ content: '新建文件夹' }).id('library-shell-new-folder').height(48)
        .onClick((): void => this.libraryPageController.createFolder())
      MenuItem({ content: '选择' }).id('library-shell-select').height(48)
        .onClick((): void => this.libraryPageController.enterSelection())
      MenuItem({ content: '排序', builder: (): void => this.librarySortMenu() })
        .id('library-shell-sort').height(48)

    }
  }

  private folderTitle(): string {
    return this.libraryBrowse.folders.find((folder: LibraryFolder): boolean =>
      folder.folderId === this.libraryBrowse.folderId)?.name ?? '书库';
  }
  private folderDepth(folder: LibraryFolder): number {
    let depth = 0, parent = folder.parentId;
    while (parent && depth < 32) {
      const ancestor = this.libraryBrowse.folders.find((item: LibraryFolder): boolean => item.folderId === parent);
      if (!ancestor) break;
      depth++; parent = ancestor.parentId;
    }
    return depth;
  }
  private sidebarFolders(): LibraryFolder[] {
    const result: LibraryFolder[] = [];
    const append = (parentId: string, depth: number): void => {
      if (depth > 32) return;
      for (const folder of this.libraryBrowse.folders.filter((item: LibraryFolder): boolean => item.parentId === parentId)
        .sort((left: LibraryFolder, right: LibraryFolder): number => left.name.localeCompare(right.name))) {
        result.push(folder); append(folder.folderId, depth + 1);
      }
    };
    append('', 0); return result;
  }

  @Builder
  private libraryHeaderActions() {
    Row() {
      Button() { SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(20).fontColor([bookshelfColor('default', 'secondary', this.resolvedInterfaceMode())]) }
        .id('library-shell-search').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText('筛选当前目录').onClick((): void => this.libraryPageController.toggleSearch())
      Button() { SymbolGlyph($r('sys.symbol.plus')).fontSize(20).fontColor([bookshelfColor('default', 'secondary', this.resolvedInterfaceMode())]) }
        .id('library-import').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText('导入本地图书').enabled(!this.loading && !this.importing && !this.checkingBook)
        .onClick((): void => { this.chooseImport().catch((): void => {}); })
      Button() {
        Text('⋯').fontSize('22fp').fontWeight(FontWeight.Medium)
          .fontColor(bookshelfColor('default', 'secondary', this.resolvedInterfaceMode())).hitTestBehavior(HitTestMode.None)
      }
        .id('library-shell-more').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText('书库更多操作').bindMenu(this.libraryHeaderMenu(), nativeMenuOptions(this.overlayMaterials.menu))
    }.id('library-compact-header').height(56)
  }


  private syncShellTab(): void {
    if (this.destination === 'library' || this.destination === 'mine') this.shellTabIndex = this.destination === 'mine' ? 1 : 0;
  }
  private switchTop(destination: ProductDestination): void {
    if (this.checkingBook || this.importing || this.batchState.phase !== 'idle') return;
    if (this.destination !== 'library' && this.destination !== 'mine') return;
    this.pathTreeVisible = false;
    this.animateShell('destination', 120, (): void => { this.destination = destination; });
    this.updateShellBars();
  }
  private openPathTree(): void {
    if (this.pathTreeVisible || this.pathTreePresented) return;
    this.pendingPathFolderId = undefined;
    let cursor = this.libraryBrowse.folderId;
    const expanded: string[] = [];
    while (cursor && expanded.length < 32) {
      const folder = this.libraryBrowse.folders.find((item: LibraryFolder): boolean => item.folderId === cursor);
      if (!folder) break;
      expanded.push(folder.folderId); cursor = folder.parentId;
    }
    this.expandedFolders = expanded;
    this.setPathTreeVisible(true);
  }
  private setPathTreeVisible(visible: boolean): void {
    this.pathTreeVisible = visible;
  }
  private animateShell(surface: string, duration: number, action: () => void): void {
    const serial = READER_DIAGNOSTICS_ENABLED ? shellMotionObservation.begin(surface) : 0;
    this.getUIContext().animateTo({ duration: this.systemReducedMotion === true ? 0 : duration, curve: Curve.EaseOut,
      onFinish: (): void => { if (READER_DIAGNOSTICS_ENABLED) shellMotionObservation.finish(surface, serial); } }, action);
  }
  private currentPath(id: string): string {
    const names: string[] = [];
    let cursor = id;
    while (cursor && names.length < 32) {
      const folder = this.libraryBrowse.folders.find((item: LibraryFolder): boolean => item.folderId === cursor);
      if (!folder) break;
      names.unshift(folder.name); cursor = folder.parentId;
    }
    return ['书架', ...names].join(' / ');
  }
  private treeFolders(): LibraryFolder[] {
    return this.sidebarFolders().filter((folder: LibraryFolder): boolean => {
      let parent = folder.parentId, depth = 0;
      while (parent && depth++ < 32) {
        if (!this.expandedFolders.includes(parent)) return false;
        parent = this.libraryBrowse.folders.find((item: LibraryFolder): boolean => item.folderId === parent)?.parentId ?? '';
      }
      return depth < 32;
    });
  }
  private choosePath(id: string): void {
    this.pendingPathFolderId = id;
    this.setPathTreeVisible(false);
  }
  private treeCount(id: string): number {
    return this.entries.filter((entry: LibraryEntry): boolean =>
      (this.libraryBrowse.memberships.find((item): boolean => item.bookId === entry.book.bookId)?.folderId ?? '') === id).length;
  }
  @Builder
  private minePage() {
    MinePage({ summary: this.mineSummary, defaultMode: this.resolvedInterfaceMode(),
      reducedMotion: this.systemReducedMotion,
      loading: this.loading, unavailable: this.libraryRefreshFailed, notice: this.message,
      onOpen: (book: Book): void => { this.message = ''; this.openBook(book).catch((): void => {}); },
      onRepair: (book: Book): void => this.showMissingSourceActions(book),
      onLibrary: (): void => this.switchTop('library'),
      onSettings: (): void => this.openLibrarySettings(),
      onRecords: (kind: RecordKind): void => {
        if (this.destination !== 'mine') return;
        this.runtime.readingRecords.begin(this.entries.map((entry: LibraryEntry): Book => entry.book));
        this.recordsKind = kind; this.message = '';
        this.animateShell('destination', 200, (): void => { this.destination = 'records'; });
        this.updateShellBars();
      },
      onRetry: (): void => { this.refreshLibrary().catch((): void => {}); } })
  }
  private pathTreeRows(): LibraryPathTreeRow[] {
    return this.treeFolders().map((folder: LibraryFolder): LibraryPathTreeRow => ({
      folderId: folder.folderId, name: folder.name, depth: this.folderDepth(folder), path: this.currentPath(folder.folderId),
      count: this.treeCount(folder.folderId),
      hasChildren: this.libraryBrowse.folders.some((item: LibraryFolder): boolean => item.parentId === folder.folderId)
    }));
  }
  @Builder private pathTree() {
    LibraryPathTreeContent({ currentPathLabel: this.currentPath(this.libraryBrowse.folderId),
      currentFolderId: this.libraryBrowse.folderId, rootCount: this.treeCount(''), rows: this.pathTreeRows(),
      expandedFolders: this.expandedFolders,
      defaultMode: this.resolvedInterfaceMode(), maxContentHeight: Math.max(96,
        (this.windowSnapshot.heightVp - this.windowSnapshot.safeInsets.top - this.windowSnapshot.safeInsets.bottom) * 0.78 - 104),
      onClose: (): void => this.setPathTreeVisible(false), onChoose: (id: string): void => this.choosePath(id),
      onToggle: (id: string): void => { this.expandedFolders = this.expandedFolders.includes(id) ?
        this.expandedFolders.filter((value: string): boolean => value !== id) : [...this.expandedFolders, id]; }
    })
  }

  @Builder
  private privacyGate() {
    PrivacyNotice({ status: this.privacyStatus, showingFullPolicy: this.showingFullPrivacyPolicy,
      policyText: this.privacyPolicyText, error: this.privacyError,
      onReadPolicy: (): void => { this.showingFullPrivacyPolicy = true; },
      onBackToNotice: (): void => { this.showingFullPrivacyPolicy = false; },
      onAccept: (): void => this.acceptPrivacy(), onDecline: (): void => this.declinePrivacy() })
  }

  @Builder
  private libraryCurrentTitle() {
    Text(this.libraryBrowse.folderId ? this.folderTitle() : '书架').id('library-path-current-title')
      .fontSize('20fp').fontWeight(FontWeight.Medium).maxLines(this.libraryBrowse.folderId ? 2 : 1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .fontColor(bookshelfColor('default', 'text', this.resolvedInterfaceMode()))
      .layoutWeight(1)
  }

  @Builder
  private nativeLibraryTitle() {
    Row() {
      if (this.libraryBrowse.folderId) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20) }
          .id('library-shell-folder-up').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('返回上一级').onClick((): void => this.libraryPageController.parentFolder())
      } else {
        this.libraryCurrentTitle()
      }
    }.height(56).width('100%').padding({ left: 16, right: 8 })
  }

  @Builder
  private nativeLibraryDestination() {
    Navigation() {
      Column() {
        if (this.libraryBrowse.folderId && !this.librarySelecting) {
          Row() { this.libraryCurrentTitle() }
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 12 })
        }
            Row() {
            LibraryPage({
              active: this.destination === 'library' && this.batchState.phase === 'idle' && !this.checkingBook,
              menuMaterial: this.overlayMaterials.menu, panelMaterial: this.overlayMaterials.panel,
              pageController: this.libraryPageController,
              renderHeader: false,
              browse: this.libraryBrowse,
              onBrowseChange: (browse: LibraryBrowseState): void => { this.libraryBrowse = browse; },
              onSelectionChange: (selected: boolean): void => { this.librarySelecting = selected; },
              refreshFailed: this.libraryRefreshFailed,
              onRefresh: (): void => { this.refreshLibrary().catch((): void => {}); },
              entries: this.entries,
              loading: this.loading,
              message: this.message,
              quarantinedOrphanCount: this.quarantinedOrphanCount,
              fontSizeScale: this.systemFontScale,
              windowSnapshot: this.windowSnapshot,
              bookshelfTheme: this.bookshelfTheme,
              bookshelfDefaultMode: this.resolvedInterfaceMode(),
              renderBackground: false,
              presentation: this.runtime.libraryPresentation,
              appearanceApplication: this.runtime.readerAppearance,
              bookmarks: this.runtime.bookmarks,
              organization: this.runtime.organization,
              onImport: (): void => { this.chooseImport().catch((): void => {}); },
              onSettings: (): void => this.openLibrarySettings(),
              onOpen: (book: Book): void => { this.openBook(book).catch((): void => {}); },
              onOpenBookmark: (book: Book, point: BookmarkPoint): void => {
                this.openBook(book, point).catch((): void => {});
              },
              onDelete: (book: Book): Promise<boolean> => this.deleteBook(book),
              onDeleteSelected: (books: Book[]): Promise<BookDeleteResult[]> => this.deleteSelectedBooks(books),
              onRename: (book: Book, title: string, author: string): Promise<boolean> =>
                this.renameBook(book, title, author),
              onBookSize: (book: Book): Promise<number | undefined> =>
                this.library?.bookSize(book.bookId) ?? Promise.resolve(undefined),
              onRepair: (book: Book): void => { this.showMissingSourceActions(book); },
              onCleanupOrphans: (): void => { this.cleanupOrphans().catch((): void => {}); }
            }).layoutWeight(1).height('100%').visibility(this.checkingBook ? Visibility.Hidden : Visibility.Visible)
            }.width('100%').layoutWeight(1)
      }.width('100%').height('100%')
    }.id('library-native-navigation').mode(NavigationMode.Stack)
      .title(this.nativeLibraryTitle())
      .titleMode(NavigationTitleMode.Mini).hideBackButton(true)
      .hideTitleBar(this.librarySelecting).menus(this.libraryHeaderActions())
      .width('100%').height('100%')
  }

  private readonly libraryTabSymbol: TabBarSymbol = {
    normal: new SymbolGlyphModifier($r('sys.symbol.list_book')),
    selected: new SymbolGlyphModifier($r('sys.symbol.list_book_fill'))
  };
  private readonly mineTabSymbol: TabBarSymbol = {
    normal: new SymbolGlyphModifier($r('sys.symbol.person')),
    selected: new SymbolGlyphModifier($r('sys.symbol.person_fill'))
  };
  build() {
    Navigation() {
      WithTheme({ colorMode: bookshelfThemeColorMode(this.resolvedInterfaceMode()),
        theme: { colors: { brand: bookshelfColor('default', 'accent', this.resolvedInterfaceMode()),
          fontPrimary: bookshelfColor('default', 'text', this.resolvedInterfaceMode()),
          fontSecondary: bookshelfColor('default', 'secondary', this.resolvedInterfaceMode()),
          backgroundPrimary: bookshelfColor('default', 'surface', this.resolvedInterfaceMode()),
          compBackgroundPrimary: bookshelfColor('default', 'surface', this.resolvedInterfaceMode()) } } }) {
      Stack() {
        if (this.privacyStatus !== 'accepted') {
          this.privacyGate()
        } else {
        if (this.destination !== 'reader') {
          BookshelfBackground({ theme: this.bookshelfTheme, defaultMode: this.resolvedInterfaceMode() })
        }
        // Retain the native Grid and its measured viewport across Reader/import routes.
        // Hidden shell content cannot receive touch, focus or accessibility actions.
        Tabs({ barPosition: BarPosition.End, index: this.shellTabIndex }) {
          TabContent() { this.nativeLibraryDestination() }
            .tabBar(BottomTabBarStyle.of(this.libraryTabSymbol, '书架').id('top-tab-library'))
          TabContent() { this.minePage() }
            .tabBar(BottomTabBarStyle.of(this.mineTabSymbol, '我的').id('top-tab-mine'))
        }.id('library-native-tabs').vertical(false).barMode(BarMode.Fixed)
          .barWidth(Math.min(360, this.windowSnapshot.usableWidthVp)).barHeight(this.librarySelecting ? 0 : 'auto', false)
          .scrollable(false).animationDuration(this.systemReducedMotion === true ? 0 : 180)
          .onChange((index: number): void => this.switchTop(index === 0 ? 'library' : 'mine'))
          .width('100%').height('100%').padding({
            left: this.windowSnapshot.safeInsets.left, right: this.windowSnapshot.safeInsets.right,
            top: this.windowSnapshot.safeInsets.top, bottom: this.windowSnapshot.safeInsets.bottom })
          .visibility((this.destination === 'library' || this.destination === 'mine') && this.batchState.phase === 'idle' ? Visibility.Visible : Visibility.Hidden)
          .enabled((this.destination === 'library' || this.destination === 'mine') && this.batchState.phase === 'idle')
          .hitTestBehavior((this.destination === 'library' || this.destination === 'mine') && this.batchState.phase === 'idle' ? HitTestMode.Default : HitTestMode.None)
          .accessibilityLevel((this.destination === 'library' || this.destination === 'mine') && this.batchState.phase === 'idle' ? 'auto' : 'no-hide-descendants')
        if (this.readerHostBook !== undefined) {
          Column() {
          ReaderPage({
            menuMaterial: this.overlayMaterials.menu, panelMaterial: this.overlayMaterials.panel,
            windowSnapshot: this.windowSnapshot,
            book: this.readerHostBook,
            initialProgress: this.activeProgress,
            initialSettings: this.runtime.readerAppearance.loadSettings(),
            sessionId: this.readerSessionId,
            appearanceApplication: this.runtime.readerAppearance,
            bookmarks: this.runtime.bookmarks,
            textMarks: this.runtime.textMarks,
            session: this.runtime.readerSessions,
            dictionaryService: this.runtime.dictionaryService(),
            pageController: this.readerPageController,
            onExit: (): void => { this.closeReader().catch((): void => {}); },
            onOpenReadingSettings: (): void => this.openReadingSettings(),
            onRestoreShellBars: async (): Promise<void> => {
              await this.updateShellBars();
            },
            onThemeChange: (theme: ReaderTheme): void => { this.readerCanvasTheme = theme; },
            onControlsVisibilityChange: (visible: boolean): void => {
              this.readerControlsVisible = visible;
            },
            onReady: (sessionId: number): void => { this.readerReady(sessionId).catch((): void => {}); },
            onFatalError: (sessionId: number, category: ReaderFatalErrorCategory): void => {
              this.readerFailed(sessionId, category).catch((): void => {});
            }
          }).width('100%').height('100%')
          }.width('100%').height('100%').padding({
            left: this.windowSnapshot.safeInsets.left, right: this.windowSnapshot.safeInsets.right,
            top: this.windowSnapshot.safeInsets.top, bottom: this.windowSnapshot.safeInsets.bottom })
            .visibility(this.destination === 'reader' ? Visibility.Visible : Visibility.Hidden)
            .opacity(this.destination === 'reader' ? 1 : 0)
            .animation({ duration: this.systemReducedMotion === true ? 0 : 200, curve: Curve.EaseOut })
            .enabled(this.destination === 'reader')
            .hitTestBehavior(this.destination === 'reader' ? HitTestMode.Default : HitTestMode.None)
            .accessibilityLevel(this.destination === 'reader' ? 'auto' : 'no-hide-descendants')
        }

        if (this.readerState === 'opening') {
          Text('正在打开…').id('reader-opening').fontSize(1).fontColor('#00000000')
        } else if (this.readerState === 'ready') {
          Text('已就绪').id('reader-ready').fontSize(1).fontColor('#00000000')
        } else if (this.readerState === 'error') {
          Text('打开失败').id('reader-error').fontSize(1).fontColor('#00000000')
        }

        if (this.importing) {
          Text('正在导入…').id('library-importing').fontSize(1).fontColor('#00000000')
        }

        if (this.destination !== 'reader') {
          if (this.destination === 'settings') {
            SettingsPage({
              reducedMotion: this.systemReducedMotion,
              menuMaterial: this.overlayMaterials.menu,
              readerAppearance: this.runtime.readerAppearance,
              libraryPresentation: this.runtime.libraryPresentation,
              diagnosticExport: this.runtime.diagnosticExporter(),
              bookshelfTheme: this.bookshelfTheme,
              bookshelfDefaultMode: this.bookshelfDefaultMode,
              systemColorMode: this.systemColorMode,
              renderBackground: false,
              onInterfaceModeSaved: (_mode: BookshelfDefaultMode): void => this.syncInterfaceMode(),
              onReaderPreferenceSaved: (): void => this.readerPageController.syncConfirmedPreferences(),
              windowSnapshot: this.windowSnapshot,
              pageController: this.settingsPageController,
              onExit: (source: SettingsEntrySource): void => this.closeSettings(source)
            }).transition(this.settingsFromReader ? TransitionEffect.OPACITY :
              TransitionEffect.asymmetric(
                nonReadingPageTransition(this.systemReducedMotion).animation({
                  duration: this.systemReducedMotion === true ? 0 : 200, curve: Curve.EaseOut }),
                nonReadingPageTransition(this.systemReducedMotion).animation({
                  duration: this.systemReducedMotion === true ? 0 : 160, curve: Curve.EaseOut })))
          } else if (this.batchState.phase !== 'idle') {
            BatchImportPage({ defaultMode: this.resolvedInterfaceMode(),
              menuMaterial: this.overlayMaterials.menu, panelMaterial: this.overlayMaterials.panel,
              state: this.batchState,
              targetLabel: this.batchTargetLabel(),
              windowSnapshot: this.windowSnapshot,
              pageController: this.batchPageController,
              onContinueAdding: (): void => { this.chooseImport().catch((): void => {}); },
              onRemove: (id: number): void => { this.removeBatchItem(id); },
              onPreviewText: (id: number, encoding: TxtEncodingChoice): Promise<TxtPreview> =>
                this.library === undefined ? Promise.resolve<TxtPreview>({ valid: false, excerpt: '', encoding: encoding,
                  message: '书库尚未就绪。' }) : this.library.previewBatchText(id, encoding),
              onSetTextEncoding: (id: number, encoding: TxtEncodingChoice): void => {
                this.batchState = this.library?.setBatchTextEncoding(id, encoding) ?? this.batchState;
              },
              onConfirm: (): void => { this.confirmBatch().catch((): void => {}); },
              onCancelReview: (): void => {
                this.batchState = this.library?.cancelBatchReview() ?? this.batchState;
              },
              onCancelRunning: (): void => { this.library?.cancelBatch(); },
              onDone: (): void => { this.finishBatch(); },
              onOpen: (book: Book): void => { this.openBatchBook(book); }
            })
          }
        }
        if (this.destination === 'records' || (this.readerReturnDestination === 'records' && this.activeBook !== undefined)) {

            ReadingRecordsPage({ active: this.destination === 'records', application: this.runtime.readingRecords, pageController: this.recordsController,
              reducedMotion: this.systemReducedMotion,
              panelMaterial: this.overlayMaterials.panel, initialKind: this.recordsKind, defaultMode: this.resolvedInterfaceMode(), notice: this.message,
              onKindChange: (kind: RecordKind): void => { this.recordsKind = kind; },
              onExit: (): void => this.closeReadingRecords(),
              onBookmark: (row: ReadingRecordRow): void => {
                const book = this.entries.find((entry: LibraryEntry): boolean => entry.book.bookId === row.bookId)?.book;
                if (!book || !row.point) { this.message = '这条书签的图书暂不可用，记录仍保留。'; return; }
                this.message = ''; this.openBook(book, row.point).catch((): void => {});
              }
            }).padding({ left: this.windowSnapshot.safeInsets.left, right: this.windowSnapshot.safeInsets.right,
              top: this.windowSnapshot.safeInsets.top, bottom: this.windowSnapshot.safeInsets.bottom })
              .visibility(this.destination === 'records' ? Visibility.Visible : Visibility.Hidden)
              .enabled(this.destination === 'records')
              .hitTestBehavior(this.destination === 'records' ? HitTestMode.Default : HitTestMode.None)
              .accessibilityLevel(this.destination === 'records' ? 'auto' : 'no-hide-descendants')
              .transition(nonReadingPageTransition(this.systemReducedMotion))
        }
        if (this.checkingBook || (this.destination === 'reader' && this.readerState === 'opening')) {
          BookOpeningOverlay({ theme: this.readerCanvasTheme ?? 'light', checking: this.checkingBook,
            onCancel: (): void => this.cancelReaderOpening() })
        }
        }
      }.width('100%').height('100%')
        .bindSheet($$this.pathTreeVisible, this.pathTree(), nativeSheetOptions(this.overlayMaterials.panel, {
          height: SheetSize.FIT_CONTENT, detents: [SheetSize.FIT_CONTENT],
          preferType: this.windowSnapshot.usableWidthVp >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
          width: this.windowSnapshot.usableWidthVp >= 600 ? 480 : undefined,
          showClose: false, dragBar: true,
          backgroundColor: this.overlayMaterials.panel === undefined ?
            bookshelfColor('default', 'surface', this.resolvedInterfaceMode()) : Color.Transparent,
          onAppear: (): void => { this.pathTreePresented = true; },
          onDisappear: (): void => {
            this.pathTreePresented = false;
            const target = this.pendingPathFolderId; this.pendingPathFolderId = undefined;
            // Keep the outgoing path/tree intact, then commit the existing browse navigation.
            if (target !== undefined && this.destination === 'library') this.libraryPageController.enterFolder(target);
          },
          onWillDismiss: (action: DismissSheetAction): void => {
            this.setPathTreeVisible(false); action.dismiss();
          }
        }))
      }
    }.hideTitleBar(true).mode(NavigationMode.Stack)
      .backgroundColor(this.readerSafeAreaBackground())
  }
}
