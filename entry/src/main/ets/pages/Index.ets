import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { accessibility } from '@kit.AccessibilityKit';
import { picker } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Book, BookmarkPoint, ReaderTheme, ReadingProgress } from '../domain/Models';
import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { BookDeleteResult, LibraryPage } from './LibraryPage';
import { ReaderPage, ReaderPageController } from './ReaderPage';
import { ImportResult } from '../services/BookImportService';
import { LibraryEntry } from '../services/LibraryQueryService';
import { SettingsPage, SettingsPageController } from './SettingsPage';
import { BookshelfBackground } from '../components/BookshelfBackground';
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
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT
} from '../layout/AdaptiveLayoutPolicy';
import { adaptiveWindowLifecycle } from '../layout/AdaptiveWindowLifecycle';
import { BatchImportSnapshot } from '../application/BatchImportCoordinator';
import { BatchImportPage, BatchImportPageController } from './BatchImportPage';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

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
  @State private entries: LibraryEntry[] = [];
  @State private loading: boolean = true;
  @State private message: string = '';
  @State private activeBook?: Book = undefined;
  @State private activeProgress?: ReadingProgress = undefined;
  @State private readerHostBook?: Book = undefined;
  @State private readerCanvasTheme?: ReaderTheme = undefined;
  @State private readerControlsVisible: boolean = true;
  @State private destination: ProductDestination = 'library';
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
  @State private privacyStatus: 'checking' | 'required' | 'accepted' | 'unavailable' = 'checking';
  @State private privacyPolicyText: string = '';
  @State private showingFullPrivacyPolicy: boolean = false;
  @State private privacyError: string = '';
  private runtime: ApplicationRuntime = new ApplicationRuntime();
  private library?: LibraryApplication;
  private context?: common.UIAbilityContext;
  private readerPageController: ReaderPageController = new ReaderPageController();
  private settingsPageController: SettingsPageController = new SettingsPageController();
  private batchPageController: BatchImportPageController = new BatchImportPageController();
  private readerSessionId: number = 0;
  private readerLifecycle: ReaderSessionLifecycle = new ReaderSessionLifecycle();
  private unsubscribeLifecycle?: () => void;
  private unsubscribeAdaptiveWindow?: () => void;
  private unsubscribeSystemColorMode?: () => void;
  private shellBarUpdate: Promise<void> = Promise.resolve();

  aboutToAppear(): void {
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
    this.bookshelfTheme = this.runtime.libraryPresentation.loadTheme();
    this.bookshelfDefaultMode = this.runtime.libraryPresentation.loadDefaultMode();
    this.unsubscribeSystemColorMode = this.runtime.readerAppearance.subscribeSystemColorMode((): void => {
      if (this.bookshelfTheme === 'default' && this.bookshelfDefaultMode === 'system') this.updateShellBars();
    });
    this.updateShellBars();
    this.library = this.runtime.library();
    this.quarantinedOrphanCount = initialized.reconciliation.retainedQuarantinedOrphans;
    await this.refreshLibrary();
    if (initialized.sampleSeed === 'failed') this.message = '示例书未能加入书库，你仍可导入自己的书籍。';
  }

  aboutToDisappear(): void {
    this.cancelOpeningCheck();
    this.unsubscribeAdaptiveWindow?.();
    this.unsubscribeAdaptiveWindow = undefined;
    this.unsubscribeLifecycle?.();
    this.unsubscribeLifecycle = undefined;
    this.unsubscribeSystemColorMode?.();
    this.unsubscribeSystemColorMode = undefined;
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
      this.getUIContext().showAlertDialog({
        title: '取消剩余导入？',
        message: '已经完成的书籍会保留；当前未提交项和后续项目将停止。',
        primaryButton: { value: '继续等待', action: (): void => {} },
        secondaryButton: { value: '取消剩余导入', action: (): void => { this.library?.cancelBatch(); } }
      });
      return true;
    }
    if (this.destination === 'settings') {
      if (!this.settingsPageController.handleSystemBack()) {
        this.settingsPageController.resetToRoot();
        this.destination = 'library';
      }
      return true;
    }
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
      this.activeBook = undefined;
      this.activeProgress = undefined;
      this.readerHostBook = undefined;
      this.readerCanvasTheme = undefined;
      this.destination = 'library';
      this.readerLifecycle.finishClosing(sessionId);
      this.readerState = 'idle';
      this.refreshLibrary().catch((): void => {});
    }
  }

  private async refreshLibrary(): Promise<void> {
    if (this.library === undefined) return;
    this.loading = true;
    this.entries = await this.library.listEntries();
    this.loading = false;
  }

  private async chooseImport(): Promise<void> {
    if (this.context === undefined || this.library === undefined || this.checkingBook || this.importing ||
      this.batchState.phase === 'running' || this.batchState.phase === 'results') return;
    this.message = '';
    this.importing = true;
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = this.batchState.limit;
      options.fileSuffixFilters = ['EPUB|.epub', 'TXT|.txt'];
      SafeLog.event('picker-requested');
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      if (uris.length > 0) {
        this.batchState = this.library.addBatchSelection(uris);
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
    const sessionId = previousSessionId + 1;
    if (!this.readerLifecycle.beginOpening(sessionId)) return;
    this.readerSessionId = sessionId;
    const settings = this.runtime.readerAppearance.loadSettings();
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
      if (this.openCancelled) { await this.endOpeningCheck(sessionId); return; }
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
      this.activeBook = book;
      await this.setShellLayout(false);
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
    this.getUIContext().showAlertDialog({
      title: '找不到书籍文件',
      message: '请重新选择这本书的文件。',
      primaryButton: { value: '取消', action: (): void => {} },
      secondaryButton: { value: '重新选择文件', action: (): void => {
        this.chooseRepair(book).catch((): void => {});
      }}
    });
  }

  private async cleanupOrphans(): Promise<void> {
    if (this.checkingBook || this.importing) return;
    if (this.library === undefined) return;
    const removed = await this.library.cleanupQuarantinedOrphans();
    this.quarantinedOrphanCount = Math.max(0, this.quarantinedOrphanCount - removed);
  }

  private async deleteBook(book: Book): Promise<boolean> {
    if (this.checkingBook || this.importing || this.library === undefined) return false;
    try {
      if (this.activeBook?.bookId === book.bookId) {
        await this.runtime.readerSessions.flush(this.readerSessionId);
        await this.closeReader();
      }
      await this.library.delete(book);
    } catch (_) {
      this.message = '删除失败，书籍记录已保留。';
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
    for (const book of books) {
      const succeeded = await this.deleteBook(book);
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

  private async setShellLayout(full: boolean): Promise<void> {
    if (this.context === undefined) return;
    try {
      const mainWindow = await window.getLastWindow(this.context);
      await mainWindow.setWindowLayoutFullScreen(full);
    } catch (_) {}
  }

  private updateShellBars(): Promise<void> {
    if (this.context === undefined || this.destination === 'reader') return Promise.resolve();
    const context = this.context;
    const theme = this.bookshelfTheme;
    const mode = this.bookshelfDefaultMode === 'system' ? this.runtime.readerAppearance.currentSystemMode() :
      this.bookshelfDefaultMode;
    this.shellBarUpdate = this.shellBarUpdate.then(async (): Promise<void> => {
      const mainWindow = await window.getLastWindow(context);
      const art = theme !== 'default';
      const color = art ? '#00000000' : (mode === 'dark' ? '#1C2933' : '#E0E5E5');
      const content = art || mode === 'dark' ? '#F6F3E9' : '#243139';
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: color, statusBarContentColor: content,
        navigationBarColor: color, navigationBarContentColor: content
      });
    }).catch((): void => {});
    return this.shellBarUpdate;
  }

  private readerSafeAreaBackground(): ResourceColor {
    if (this.destination !== 'reader') {
      if (this.bookshelfTheme !== 'default') return Color.Transparent;
      if (this.bookshelfDefaultMode === 'dark') return '#1C2933';
      if (this.bookshelfDefaultMode === 'light') return '#E0E5E5';
      return $r('app.color.product_canvas');
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
  private privacyGate() {
    Column() {
      if (this.showingFullPrivacyPolicy) {
        Column({ space: 16 }) {
          Text('页灯隐私政策').fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.product_text_primary')).width('100%')
          Scroll() {
            Text(this.privacyPolicyText).fontSize(16).lineHeight(25)
              .fontColor($r('app.color.product_text_primary')).width('100%')
          }.id('privacy-full-policy').layoutWeight(1).width('100%')
          Button('返回隐私提示').id('privacy-policy-back').height($r('app.float.product_target_min'))
            .width('100%').type(ButtonType.Normal)
            .fontColor($r('app.color.product_text_primary'))
            .backgroundColor($r('app.color.product_surface_muted'))
            .onClick((): void => { this.showingFullPrivacyPolicy = false; })
        }.id('privacy-policy-dialog').width('90%').height('84%').constraintSize({ maxWidth: 600 })
          .padding(24).backgroundColor($r('app.color.product_surface')).borderRadius(20)
      } else {
        Column({ space: 16 }) {
          Text('隐私与本地阅读').fontSize(24).fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.product_text_primary')).width('100%')
          if (this.privacyStatus === 'checking') {
            LoadingProgress().width(36).height(36).color($r('app.color.product_accent'))
            Text('正在准备隐私政策…').fontSize(16)
              .fontColor($r('app.color.product_text_secondary')).width('100%')
          } else if (this.privacyStatus === 'unavailable') {
            Text('无法读取随应用提供的隐私政策，请退出后重试。').fontSize(16)
              .fontColor($r('app.color.product_error')).width('100%')
            Button('退出应用').id('privacy-exit').height($r('app.float.product_target_min'))
              .width('100%').type(ButtonType.Normal)
              .onClick((): void => this.declinePrivacy())
          } else {
            Text('页灯会在本机保存你导入的 EPUB 与 TXT、阅读进度、书签、划线和笔记；基础英汉查词在设备上完成。当前版本不申请互联网权限，不会自动上传书籍或阅读记录。')
              .fontSize(16).lineHeight(25).fontColor($r('app.color.product_text_primary')).width('100%')
            Text('你可以删除应用内书籍，原始文件仍保留在你选择的位置。请先阅读完整政策，再决定是否继续使用。')
              .fontSize(16).lineHeight(25).fontColor($r('app.color.product_text_secondary')).width('100%')
            Button('阅读完整隐私政策（离线）').id('privacy-read-policy')
              .height($r('app.float.product_target_min')).width('100%').type(ButtonType.Normal)
              .fontColor($r('app.color.product_accent'))
              .backgroundColor($r('app.color.product_surface_muted'))
              .onClick((): void => { this.showingFullPrivacyPolicy = true; })
            if (this.privacyError.length > 0) {
              Text(this.privacyError).fontSize(14).fontColor($r('app.color.product_error')).width('100%')
            }
            Button('同意并开始使用').id('privacy-accept').height($r('app.float.product_target_min'))
              .width('100%').type(ButtonType.Normal)
              .fontColor($r('app.color.product_on_accent'))
              .backgroundColor($r('app.color.product_accent'))
              .onClick((): void => this.acceptPrivacy())
            Button('不同意并退出').id('privacy-decline').height($r('app.float.product_target_min'))
              .width('100%').type(ButtonType.Normal)
              .fontColor($r('app.color.product_text_primary'))
              .backgroundColor($r('app.color.product_surface_muted'))
              .onClick((): void => this.declinePrivacy())
          }
        }.id('privacy-consent-dialog').width('90%').constraintSize({ maxWidth: 520, maxHeight: '90%' })
          .padding(24).backgroundColor($r('app.color.product_surface')).borderRadius(20)
      }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.product_canvas'))
  }

  build() {
    Navigation() {
      Stack() {
        if (this.privacyStatus !== 'accepted') {
          this.privacyGate()
        } else {
        if (this.destination !== 'reader') {
          BookshelfBackground({ theme: this.bookshelfTheme, defaultMode: this.bookshelfDefaultMode })
        }
        if (this.readerHostBook !== undefined) {
          ReaderPage({
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
            onRestoreShellBars: async (): Promise<void> => {
              await this.setShellLayout(true);
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
          })
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
              readerAppearance: this.runtime.readerAppearance,
              diagnosticExport: this.runtime.diagnosticExporter(),
              bookshelfTheme: this.bookshelfTheme,
              bookshelfDefaultMode: this.bookshelfDefaultMode,
              renderBackground: false,
              onThemeApplied: (theme: BookshelfTheme, mode: BookshelfDefaultMode): boolean => {
                try {
                  this.runtime.libraryPresentation.saveAppearance(theme, mode);
                  this.bookshelfTheme = theme;
                  this.bookshelfDefaultMode = mode;
                  this.updateShellBars();
                  return true;
                } catch (_) { return false; }
              },
              windowSnapshot: this.windowSnapshot,
              pageController: this.settingsPageController,
              onExit: (): void => {
                this.settingsPageController.resetToRoot();
                this.destination = 'library';
              }
            })
          } else if (this.batchState.phase !== 'idle') {
            BatchImportPage({
              state: this.batchState,
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
          } else {
            LibraryPage({
              entries: this.entries,
              loading: this.loading,
              message: this.message,
              quarantinedOrphanCount: this.quarantinedOrphanCount,
              fontSizeScale: this.systemFontScale,
              windowSnapshot: this.windowSnapshot,
              bookshelfTheme: this.bookshelfTheme,
              bookshelfDefaultMode: this.bookshelfDefaultMode,
              renderBackground: false,
              presentation: this.runtime.libraryPresentation,
              bookmarks: this.runtime.bookmarks,
              onImport: (): void => { this.chooseImport().catch((): void => {}); },
              onSettings: (): void => { if (!this.checkingBook && !this.importing) this.destination = 'settings'; },
              onOpen: (book: Book): void => { this.openBook(book).catch((): void => {}); },
              onOpenBookmark: (book: Book, point: BookmarkPoint): void => {
                this.openBook(book, point).catch((): void => {});
              },
              onDelete: (book: Book): void => { this.deleteBook(book).catch((): void => {}); },
              onDeleteSelected: (books: Book[]): Promise<BookDeleteResult[]> => this.deleteSelectedBooks(books),
              onRename: (book: Book, title: string, author: string): Promise<boolean> =>
                this.renameBook(book, title, author),
              onBookSize: (book: Book): Promise<number | undefined> =>
                this.library?.bookSize(book.bookId) ?? Promise.resolve(undefined),
              onRepair: (book: Book): void => { this.showMissingSourceActions(book); },
              onCleanupOrphans: (): void => { this.cleanupOrphans().catch((): void => {}); }
            }).visibility(this.checkingBook ? Visibility.Hidden : Visibility.Visible)
          }
        }
        if (this.checkingBook || (this.destination === 'reader' && this.readerState === 'opening')) {
          Column({ space: 16 }) {
            LoadingProgress().width(40).height(40)
              .color(this.readerCanvasTheme === 'dark' ? $r('app.color.reader_accent_dark') :
                (this.readerCanvasTheme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                  $r('app.color.reader_accent_light')))
            Text(this.checkingBook ? $r('app.string.library_checking_book') :
              $r('app.string.reader_preparing_text')).fontSize($r('app.float.product_body_size'))
              .fontColor(this.readerCanvasTheme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.readerCanvasTheme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
            Button($r('app.string.library_cancel_open')).id('library-cancel-open-check')
              .height($r('app.float.product_target_min')).type(ButtonType.Normal).defaultFocus(true)
              .borderRadius($r('app.float.product_radius_control'))
              .fontColor(this.readerCanvasTheme === 'dark' ? $r('app.color.reader_on_accent_dark') :
                (this.readerCanvasTheme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') :
                  $r('app.color.reader_on_accent_light')))
              .backgroundColor(this.readerCanvasTheme === 'dark' ? $r('app.color.reader_accent_dark') :
                (this.readerCanvasTheme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                  $r('app.color.reader_accent_light')))
              .onClick(() => this.cancelReaderOpening())
          }.id('library-open-check').width('100%').height('100%').justifyContent(FlexAlign.Center)
            .backgroundColor(this.readerCanvasTheme === 'dark' ? $r('app.color.reader_canvas_dark') :
              (this.readerCanvasTheme === 'eye-comfort' ? $r('app.color.reader_canvas_eye_comfort') :
                $r('app.color.reader_canvas_light')))
        }
        }
      }.width('100%').height('100%')
    }.hideTitleBar(true).mode(NavigationMode.Stack)
      .backgroundColor(this.readerSafeAreaBackground())
  }
}
