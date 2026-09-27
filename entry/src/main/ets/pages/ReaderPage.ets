import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { uri } from '@kit.ArkTS';
import { DictionarySheet } from '../components/DictionarySheet';
import { PassageActionSheet, PassageActionSheetStatus } from '../components/PassageActionSheet';
import { DictionaryLookupResult } from '../dictionary/DictionaryModels';
import { DictionaryService } from '../dictionary/DictionaryService';
import { Book, BookmarkPoint, Chapter, DEFAULT_READER_SETTINGS, ReaderSettings, ReaderTheme, ReadingLocation, ReadingProgress, TextMarkRecord } from '../domain/Models';
import { BookmarkApplication } from '../application/BookmarkApplication';
import { TextMarkApplication } from '../application/TextMarkApplication';
import { bookmarkPointFromLocation } from '../domain/BookmarkPointPolicy';
import { ReaderThemePreference, animateReaderMotion } from '../domain/AppearancePolicy';
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT,
  adaptiveReaderColumnMode,
  readerHeaderReserveVp,
  readerPublicationContentHeightVp,
  readerUsesSidePanel
} from '../layout/AdaptiveLayoutPolicy';
import {
  ReaderEngineController,
  ReaderExternalLinkRequest,
  ReaderFatalErrorCategory,
  ReaderLinkState,
  ReaderLocationCause,
  ReaderSelectionGeometry,
  ReaderSelectionRect,
  ReaderTextMark,
  ReaderWordSelection
} from '../reader/ReaderEngine';
import { ReaderFourSurfaceView } from '../reader/ReaderFourSurfaceView';
import { validatedExternalLinkHost } from '../reader/ReaderNetworkPolicy';
import {
  ReaderPopupViewport,
  SelectionPopupPlacement,
  placeSelectionPopup
} from '../reader/SelectionPopupPlacementPolicy';
import { PassageSelectionCandidate, ReadingSelectionContext } from '../reader/ReadingSelectionModels';
import {
  PassageRequestKind,
  ReaderSurface,
  shouldDismissTransientSurfaceForLocation
} from '../reader/ReaderSurfaceState';
import { ReaderAppearanceApplication } from '../application/ReaderAppearanceApplication';
import { ReaderSessionService } from '../services/ReaderSessionService';
import { SafeLog } from '../diagnostics/SafeLog';
import { readerApplicationLifecycle, ReaderApplicationLifecycleHandler } from '../reader/ReaderApplicationLifecycle';

const EMPTY_BOOK: Book = {
  bookId: '', fileHash: '', title: '', epubRelativePath: '', importedAt: 0, sourceState: 'available'
};
const POPUP_MARGIN: number = 12;
const POPUP_GAP: number = 10;
const READER_TOC_LIST_SPACE_VP: number = 4;
const READER_SURFACE_TRANSITION_DURATION_MS: number = 160;

class ReaderPageLifecycleHandler implements ReaderApplicationLifecycleHandler {
  private background: () => void;

  constructor(background: () => void) {
    this.background = background;
  }

  onBackground(): void { this.background(); }
  onForeground(): void {}
}

interface ReadingListEntry {
  id: string;
  kind: 'page' | 'highlight' | 'note';
  title: string;
  detail: string;
  createdAt: number;
  point?: BookmarkPoint;
  mark?: TextMarkRecord;
}

function readerTextMark(record: TextMarkRecord): ReaderTextMark {
  return { markId: record.markId, bookId: record.bookId, anchorVersion: record.anchorVersion,
    engine: record.engine, kind: record.kind, resourceHref: record.resourceHref, cfi: record.cfi,
    exactText: record.exactText, prefix: record.prefix, suffix: record.suffix };
}

export interface ReaderPageSession {
  sessionId: number;
  book: Book;
  initialProgress?: ReadingProgress;
  initialBookmark?: BookmarkPoint;
  initialSettings: ReaderSettings;
}

export class ReaderPageController {
  private systemBackHandler?: () => void;
  private sessionHandler?: (session: ReaderPageSession) => void;
  private pendingSession?: ReaderPageSession;

  bindSystemBack(handler: () => void): void {
    this.systemBackHandler = handler;
  }

  unbindSystemBack(): void {
    this.systemBackHandler = undefined;
  }

  bindSession(handler: (session: ReaderPageSession) => void): boolean {
    this.sessionHandler = handler;
    const pending = this.pendingSession;
    this.pendingSession = undefined;
    if (pending === undefined) return false;
    handler(pending);
    return true;
  }

  unbindSession(): void {
    this.sessionHandler = undefined;
  }

  openSession(session: ReaderPageSession): void {
    if (this.sessionHandler === undefined) {
      this.pendingSession = session;
      return;
    }
    this.sessionHandler(session);
  }

  handleSystemBack(): boolean {
    if (this.systemBackHandler === undefined) return false;
    this.systemBackHandler();
    return true;
  }
}

@Component
export struct ReaderPage {
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  book: Book = EMPTY_BOOK;
  initialProgress?: ReadingProgress;
  initialSettings: ReaderSettings = DEFAULT_READER_SETTINGS;
  sessionId: number = 0;
  appearanceApplication?: ReaderAppearanceApplication;
  bookmarks?: BookmarkApplication;
  textMarks?: TextMarkApplication;
  session: ReaderSessionService = new ReaderSessionService();
  dictionaryService?: DictionaryService;
  pageController: ReaderPageController = new ReaderPageController();
  onExit: () => void = (): void => {};
  onRestoreShellBars?: () => Promise<void>;
  onThemeChange: (theme: ReaderTheme) => void = (_theme: ReaderTheme): void => {};
  onControlsVisibilityChange: (visible: boolean) => void = (_visible: boolean): void => {};
  onReady: (sessionId: number) => void = (_sessionId: number): void => {};
  onWordSelection: (selection: ReaderWordSelection) => void = (_selection: ReaderWordSelection): void => {};
  onSelectionRejected: (reason: string) => void = (_reason: string): void => {};
  onFatalError: (sessionId: number, category: ReaderFatalErrorCategory) => void =
    (_sessionId: number, _category: ReaderFatalErrorCategory): void => {};

  @State private controlsVisible: boolean = true;
  @State private linkState: ReaderLinkState = { canReturn: false };
  @State private currentSurface: ReaderSurface = 'none';
  @State private chapters: Chapter[] = [];
  @State private location?: ReadingLocation = undefined;
  @State private bookmarkPoints: BookmarkPoint[] = [];
  @State private savedTextMarks: TextMarkRecord[] = [];
  @State private orphanMarkIds: string[] = [];
  @State private selectedMarkId: string = '';
  @State private selectedMarkRect?: ReaderSelectionRect = undefined;
  @State private adjustingMarkId: string = '';
  private wordMarkRequest: 'none' | 'highlight' | 'note' | 'adjust' = 'none';
  private editingNoteMarkId: string = '';
  @State private noteDraft: string = '';
  private pendingNoteContext?: ReadingSelectionContext;
  private pendingMarkId: string = '';
  private currentPageExcerpt: string = '';
  @State private bookmarkReady: boolean = false;
  @State private bookmarkBusy: boolean = false;
  @State private bookmarkMessage: string = '';
  @State private bookmarkTab: 'contents' | 'bookmarks' = 'contents';
  private pendingInitialBookmark?: BookmarkPoint;
  private pendingBookmarkId: string = '';
  @State private settings: ReaderSettings = DEFAULT_READER_SETTINGS;
  @State private selectedThemePreference: ReaderThemePreference = 'system';
  @State private animateCustomMotion: boolean = true;
  @State private errorText: string = '';
  @State private navigationError: boolean = false;
  @State private dictionaryLoading: boolean = false;
  @State private dictionaryExpanded: boolean = false;
  @State private dictionarySelectedForm: string = '';
  @State private dictionaryResult?: DictionaryLookupResult = undefined;
  @State private dictionarySelection?: ReaderWordSelection = undefined;
  @State private passageCandidate?: PassageSelectionCandidate = undefined;
  @State private passageStatus: PassageActionSheetStatus = 'candidate';
  @State private passageRejectedCharacterCount: number = 0;
  @State private passageDetail: string = '';
  @State private readerSurfaceWidth: number = 0;
  @State private readerSurfaceHeight: number = 0;
  @State private currentBook: Book = EMPTY_BOOK;
  @State private hostInitialLocation?: ReadingLocation = undefined;
  private controller: ReaderEngineController = new ReaderEngineController();
  private cachedPopupGeometry?: ReaderSelectionGeometry;
  private cachedPopupLegacyRect?: ReaderSelectionRect;
  private cachedPopupViewport?: ReaderPopupViewport;
  private cachedPopupDesiredHeight: number = -1;
  private cachedPopupPlacement?: SelectionPopupPlacement;
  private passageRequest: PassageRequestKind = 'none';
  private pendingWordContextToken: string = '';
  private selectionUiGeneration: number = 0;
  private hasUncommittedSelection: boolean = false;
  private exiting: boolean = false;
  private hasReaderSession: boolean = false;
  private currentSessionId: number = 0;
  private exitLocationResolver?: () => void;
  private unsubscribeSystemColorMode?: () => void;
  private unsubscribeApplicationLifecycle?: () => void;
  private systemBarUpdate: Promise<void> = Promise.resolve();
  private panelFocusReturn: 'toc' | 'appearance' | 'none' = 'none';

  aboutToAppear(): void {
    const lifecycleHandler: ReaderApplicationLifecycleHandler =
      new ReaderPageLifecycleHandler((): void => this.handleApplicationBackground());
    this.unsubscribeApplicationLifecycle = readerApplicationLifecycle.subscribe(lifecycleHandler);
    this.pageController.bindSystemBack((): void => this.handleSystemBack());
    this.unsubscribeSystemColorMode = this.appearanceApplication?.subscribeSystemColorMode((): void => {
      this.applySystemColorModeChange();
    });
    const handledPendingSession = this.pageController.bindSession((session: ReaderPageSession): void => {
      this.activateSession(session);
    });
    if (!handledPendingSession) {
      this.activateSession({
        sessionId: this.sessionId,
        book: this.book,
        initialProgress: this.initialProgress,
        initialSettings: this.initialSettings
      });
    }
  }

  aboutToDisappear(): void {
    this.unsubscribeApplicationLifecycle?.();
    this.unsubscribeApplicationLifecycle = undefined;
    const restore = this.onRestoreShellBars;
    if (restore === undefined) this.updateSystemBars();
    else this.systemBarUpdate = this.systemBarUpdate.then(restore).catch((): void => {});
    this.invalidateTransientState(false);
    this.pageController.unbindSystemBack();
    this.pageController.unbindSession();
    this.unsubscribeSystemColorMode?.();
    this.unsubscribeSystemColorMode = undefined;
    this.dictionaryService?.cancelPending();
    this.exitLocationResolver?.();
  }

  private activateSession(session: ReaderPageSession): void {
    const reloadWebPage = this.hasReaderSession;
    if (this.hasReaderSession) this.invalidateTransientState(false);
    this.hasReaderSession = true;
    this.currentSessionId = session.sessionId;
    this.session.begin(session.sessionId, session.book.bookId);
    this.exiting = false;
    this.selectionUiGeneration += 1;
    this.dictionaryService?.cancelPending();
    this.currentBook = session.book;
    this.pendingInitialBookmark = session.initialBookmark;
    this.pendingBookmarkId = '';
    this.bookmarkPoints = [];
    this.savedTextMarks = [];
    this.orphanMarkIds = [];
    this.selectedMarkId = '';
    this.selectedMarkRect = undefined;
    this.adjustingMarkId = '';
    this.wordMarkRequest = 'none';
    this.editingNoteMarkId = '';
    this.pendingNoteContext = undefined;
    this.noteDraft = '';
    this.pendingMarkId = '';
    this.currentPageExcerpt = '';
    this.bookmarkReady = false;
    this.bookmarkBusy = false;
    this.bookmarkMessage = '';
    this.bookmarkTab = 'contents';
    this.hostInitialLocation = session.initialProgress?.location;
    this.chapters = [];
    this.location = undefined;
    this.selectedThemePreference = this.appearanceApplication?.persistentPreference() ?? 'system';
    this.animateCustomMotion = animateReaderMotion(this.appearanceApplication?.motionPreference() ?? 'system');
    this.settings = this.appearanceApplication?.resolveSettings(session.initialSettings) ??
      session.initialSettings;
    this.controlsVisible = true;
    this.panelFocusReturn = 'none';
    this.onThemeChange(this.settings.theme);
    this.onControlsVisibilityChange(true);
    this.updateSystemBars(this.settings.theme);
    this.errorText = '';
    this.navigationError = false;
    this.linkState = { canReturn: false };
    this.currentSurface = 'none';
    this.dictionaryLoading = false;
    this.dictionaryExpanded = false;
    this.dictionarySelectedForm = '';
    this.dictionaryResult = undefined;
    this.dictionarySelection = undefined;
    this.passageCandidate = undefined;
    this.passageStatus = 'candidate';
    this.passageRejectedCharacterCount = 0;
    this.passageDetail = '';
    this.passageRequest = 'none';
    this.pendingWordContextToken = '';
    this.hasUncommittedSelection = false;
    if (reloadWebPage) {
      this.controller.openBook(session.book, session.initialProgress?.location,
        this.settings, session.sessionId);
    }
  }

  private handleSystemBack(): void {
    if (this.currentSurface === 'mark-detail') {
      this.currentSurface = 'none';
      this.selectedMarkId = '';
      return;
    }
    if (this.currentSurface === 'note-editor') {
      this.dismissNoteEditor(true);
      return;
    }
    if (this.currentSurface === 'passage') {
      this.dismissPassage(true);
      return;
    }
    if (this.currentSurface === 'dictionary') {
      this.dismissDictionary(true);
      return;
    }
    if (this.currentSurface === 'toc') {
      this.dismissReaderPanel(true);
      return;
    }
    if (this.currentSurface === 'appearance') {
      this.dismissReaderPanel(true);
      return;
    }
    if (this.hasUncommittedSelection) {
      this.clearUncommittedSelection();
      return;
    }
    if (this.linkState.canReturn) {
      this.controller.returnFromInternalLink();
      return;
    }
    this.exitReader();
  }

  private clearUncommittedSelection(): void {
    this.hasUncommittedSelection = false;
    this.controller.clearSelection();
  }

  private readerSurfaceTransition(): TransitionEffect {
    return TransitionEffect.OPACITY.animation({
      duration: this.animateCustomMotion ? READER_SURFACE_TRANSITION_DURATION_MS : 0,
      curve: Curve.EaseOut
    });
  }

  private async systemBarColor(resource: Resource, context: common.UIAbilityContext): Promise<string> {
    try {
      const rgb = await context.resourceManager.getColor(resource.id) & 0xFFFFFF;
      return '#' + ('000000' + rgb.toString(16)).slice(-6).toUpperCase();
    } catch (error) { throw error instanceof Error ? error : new Error('Reader system bar color unavailable'); }
  }

  private updateSystemBars(theme?: ReaderTheme): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const background = theme === 'dark' ?
      (this.controlsVisible ? $r('app.color.reader_surface_dark') : $r('app.color.reader_canvas_dark')) :
      (theme === 'eye-comfort' ?
        (this.controlsVisible ? $r('app.color.reader_surface_eye_comfort') :
          $r('app.color.reader_canvas_eye_comfort')) :
        (theme === 'light' ?
          (this.controlsVisible ? $r('app.color.reader_surface_light') : $r('app.color.reader_canvas_light')) :
          $r('app.color.product_canvas')));
    const foreground = theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
      (theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
        (theme === 'light' ? $r('app.color.reader_text_primary_light') :
          $r('app.color.product_text_primary')));
    // ResourceManager resolves the base product color on the tablet even
    // when ArkUI paints the dark Library resource. Window bars need explicit RGB values.
    const productDark = this.appearanceApplication?.currentSystemMode() === 'dark';
    this.systemBarUpdate = this.systemBarUpdate.then(async (): Promise<void> => {
      const barColor = theme === undefined ? (productDark ? '#1C2933' : '#E0E5E5') :
        await this.systemBarColor(background, context);
      const contentColor = theme === undefined ? (productDark ? '#EAE9E3' : '#243139') :
        await this.systemBarColor(foreground, context);
      const mainWindow = await window.getLastWindow(context);
      await mainWindow.setWindowSystemBarProperties({
        statusBarColor: barColor,
        statusBarContentColor: contentColor,
        navigationBarColor: barColor,
        navigationBarContentColor: contentColor
      });
    }).catch((): void => {});
  }

  private setControlsVisible(visible: boolean): void {
    if (this.controlsVisible === visible) return;
    this.controlsVisible = visible;
    this.onControlsVisibilityChange(visible);
    this.updateSystemBars(this.settings.theme);
  }

  private dismissReaderPanel(returnFocus: boolean = false): void {
    if (this.currentSurface === 'toc' || this.currentSurface === 'appearance') {
      if (returnFocus) this.panelFocusReturn = this.currentSurface;
      this.currentSurface = 'none';
    }
  }

  private dismissDictionary(clearSelection: boolean): void {
    this.selectionUiGeneration += 1;
    this.dictionaryService?.cancelPending();
    if (this.currentSurface === 'dictionary') this.currentSurface = 'none';
    this.dictionaryLoading = false;
    this.dictionaryExpanded = false;
    this.dictionarySelectedForm = '';
    this.dictionaryResult = undefined;
    this.dictionarySelection = undefined;
    this.pendingWordContextToken = '';
    this.wordMarkRequest = 'none';
    if (clearSelection) {
      this.adjustingMarkId = '';
      this.clearUncommittedSelection();
    }
  }

  private dismissPassage(clearSelection: boolean): void {
    if (this.currentSurface === 'passage') this.currentSurface = 'none';
    this.passageCandidate = undefined;
    this.passageStatus = 'candidate';
    this.passageRejectedCharacterCount = 0;
    this.passageDetail = '';
    this.passageRequest = 'none';
    if (clearSelection) {
      this.adjustingMarkId = '';
      this.clearUncommittedSelection();
    }
  }

  private dismissNoteEditor(clearSelection: boolean): void {
    if (this.currentSurface === 'note-editor') this.currentSurface = 'none';
    this.pendingNoteContext = undefined;
    this.noteDraft = '';
    this.editingNoteMarkId = '';
    if (clearSelection) this.clearUncommittedSelection();
  }

  private handleApplicationBackground(): void {
    this.invalidateTransientState(true);
  }

  private invalidateTransientState(clearSelection: boolean): void {
    this.selectionUiGeneration += 1;
    this.dictionaryService?.cancelPending();
    this.dismissSelectionSurfaces(false);
    this.currentSurface = 'none';
    this.selectedMarkId = '';
    this.adjustingMarkId = '';
    if (clearSelection) this.clearUncommittedSelection();
  }

  private dismissSelectionSurfaces(clearSelection: boolean): void {
    this.dismissNoteEditor(false);
    this.dismissDictionary(false);
    this.dismissPassage(false);
    if (clearSelection) this.clearUncommittedSelection();
  }

  private hideSelectionSurfacesForAdjustment(): void {
    this.selectionUiGeneration += 1;
    this.dictionaryService?.cancelPending();
    this.dismissDictionary(false);
    this.dismissPassage(false);
  }

  private showPassageCandidate(candidate: PassageSelectionCandidate): void {
    this.dismissDictionary(false);
    this.hasUncommittedSelection = true;
    this.passageCandidate = candidate;
    this.passageStatus = 'candidate';
    this.passageRejectedCharacterCount = 0;
    this.passageDetail = '';
    this.passageRequest = 'none';
    this.currentSurface = 'passage';
  }

  private showPassageTooLong(characterCount?: number): void {
    this.dismissDictionary(false);
    this.hasUncommittedSelection = true;
    this.passageCandidate = undefined;
    this.passageStatus = 'too-long';
    this.passageRejectedCharacterCount = characterCount ?? 0;
    this.passageDetail = '';
    this.passageRequest = 'none';
    this.currentSurface = 'passage';
  }

  private requestPassageCopy(): void {
    const candidate = this.passageCandidate;
    if (this.currentSurface !== 'passage' || candidate === undefined) return;
    this.passageRequest = 'copy';
    this.passageStatus = 'loading';
    this.passageDetail = '';
    this.controller.requestSelectionContext(candidate.selectionToken, this.currentSessionId);
  }

  private requestTextMark(kind: 'highlight' | 'note'): void {
    const candidate = this.passageCandidate;
    if (this.currentSurface !== 'passage' || candidate === undefined || this.bookmarkBusy) return;
    this.passageRequest = kind;
    this.passageStatus = 'loading';
    this.passageDetail = '';
    this.controller.requestSelectionContext(candidate.selectionToken, this.currentSessionId,
      this.savedTextMarks.map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)));
  }

  private requestWordTextMark(action: 'highlight' | 'note' | 'adjust'): void {
    const selection = this.dictionarySelection;
    if (this.currentSurface !== 'dictionary' || selection === undefined || this.bookmarkBusy) return;
    this.wordMarkRequest = action;
    this.pendingWordContextToken = selection.selectionToken;
    this.controller.requestSelectionContext(selection.selectionToken, this.currentSessionId,
      this.savedTextMarks.map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)),
      action === 'adjust' ? this.adjustingMarkId : undefined);
  }

  private requestAdjustedMark(): void {
    const candidate = this.passageCandidate;
    if (this.currentSurface !== 'passage' || candidate === undefined ||
      this.adjustingMarkId.length === 0 || this.bookmarkBusy) return;
    this.passageRequest = 'adjust';
    this.passageStatus = 'loading';
    this.controller.requestSelectionContext(candidate.selectionToken, this.currentSessionId,
      this.savedTextMarks.map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)),
      this.adjustingMarkId);
  }

  private acceptMarkContext(context: ReadingSelectionContext,
    action: 'highlight' | 'note' | 'adjust'): void {
    if (context.markConflict !== undefined) {
      const overlap = context.markConflict === 'overlap';
      const message = overlap ? '这段文字已有高亮或笔记。点按原标记可查看或修改。' :
        '暂时无法检查已有标记，请稍后重试。';
      if (this.currentSurface === 'passage') {
        this.passageStatus = overlap ? 'mark-conflict' : 'mark-unavailable';
        this.passageDetail = message;
      } else {
        this.getUIContext().getPromptAction().showToast({ message: message });
      }
      return;
    }
    if (context.rangeAnchor === undefined || context.rangeAnchor.exactText.trim() !== context.selectedText) {
      this.getUIContext().getPromptAction().showToast({ message: '当前选区无法保存，请缩短选区。' });
      return;
    }
    context.chapterTitle = this.chapterTitleForHref(context.rangeAnchor.resourceHref);
    if (action === 'adjust') {
      this.reviseSelectedMark(context).catch((): void => {});
    } else if (action === 'highlight') {
      this.saveTextMark(context, 'highlight').catch((): void => {});
    } else {
      this.pendingNoteContext = context;
      this.noteDraft = '';
      this.editingNoteMarkId = '';
      this.currentSurface = 'note-editor';
      this.clearUncommittedSelection();
    }
  }

  private async reviseSelectedMark(context?: ReadingSelectionContext,
    kind?: 'highlight' | 'note', noteText?: string): Promise<void> {
    const markId = context === undefined ? this.editingNoteMarkId : this.adjustingMarkId;
    const mark = this.savedTextMarks.find((item: TextMarkRecord): boolean => item.markId === markId);
    if (mark === undefined || this.textMarks === undefined || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.bookmarkBusy = true;
    try {
      const revised = await this.textMarks.revise(mark, context, kind, noteText);
      if (sessionId !== this.currentSessionId) return;
      this.savedTextMarks = this.savedTextMarks.map((item: TextMarkRecord): TextMarkRecord =>
        item.markId === markId ? revised : item);
      this.controller.removeTextMark(markId, sessionId);
      this.controller.previewTextMark(readerTextMark(revised), sessionId);
      this.adjustingMarkId = '';
      this.editingNoteMarkId = '';
      this.currentSurface = 'none';
      this.clearUncommittedSelection();
      this.bookmarkMessage = '标记已更新';
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.getUIContext().getPromptAction().showToast({ message: '修改失败，原标记已保留。' });
      }
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private async saveTextMark(context: ReadingSelectionContext,
    kind: 'highlight' | 'note', noteText: string = ''): Promise<void> {
    if (this.textMarks === undefined || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    const book = this.currentBook;
    this.bookmarkBusy = true;
    try {
      const mark = await this.textMarks.save(book, context, kind, noteText);
      if (sessionId !== this.currentSessionId || book.bookId !== this.currentBook.bookId) return;
      this.savedTextMarks = [...this.savedTextMarks, mark];
      this.bookmarkMessage = kind === 'note' ? '已保存笔记' : '已添加高亮';
      this.currentSurface = 'none';
      this.pendingNoteContext = undefined;
      this.noteDraft = '';
      this.clearUncommittedSelection();
      this.controller.previewTextMark(readerTextMark(mark), sessionId);
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkMessage = '标记保存失败，请重试。';
        this.passageStatus = 'unavailable';
        this.passageDetail = '这条标记暂时无法保存，请保留选区后重试。';
        this.getUIContext().getPromptAction().showToast({ message: this.bookmarkMessage });
      }
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private savePendingNote(): void {
    if (this.editingNoteMarkId.length > 0) {
      this.reviseSelectedMark(undefined, 'note', this.noteDraft).catch((): void => {});
      return;
    }
    const context = this.pendingNoteContext;
    if (context === undefined || this.noteDraft.trim().length === 0) return;
    this.saveTextMark(context, 'note', this.noteDraft).catch((): void => {});
  }

  private acceptSelectionContext(context: ReadingSelectionContext): void {
    const wordSelection = this.dictionarySelection;
    if (context.kind === 'word' && this.currentSurface === 'dictionary' && wordSelection !== undefined &&
      this.pendingWordContextToken === context.selectionToken &&
      wordSelection.selectionToken === context.selectionToken &&
      context.selectedText === wordSelection.surfaceForm) {
      if (this.wordMarkRequest !== 'none') {
        const action = this.wordMarkRequest;
        this.wordMarkRequest = 'none';
        this.pendingWordContextToken = '';
        this.acceptMarkContext(context, action);
        return;
      }
      this.pendingWordContextToken = '';
      return;
    }

    const candidate = this.passageCandidate;
    if (context.kind !== 'passage' || this.currentSurface !== 'passage' || candidate === undefined ||
      this.passageRequest === 'none' ||
      context.selectionToken !== candidate.selectionToken ||
      context.selectedText.length !== candidate.characterCount) return;
    if (this.passageRequest === 'copy') {
      this.passageRequest = 'none';
      this.passageStatus = 'candidate';
      this.copySelectedPassageText(context.selectedText).catch((): void => {});
      return;
    }
    if (this.passageRequest === 'highlight' || this.passageRequest === 'note' ||
      this.passageRequest === 'adjust') {
      const request = this.passageRequest;
      this.passageRequest = 'none';
      this.acceptMarkContext(context, request);
      return;
    }
  }

  private handleSelectionCleared(): void {
    this.hasUncommittedSelection = false;
    this.dismissDictionary(false);
    this.dismissPassage(false);
  }

  private rejectSelectionContext(selectionToken: string): void {
    if (this.currentSurface === 'dictionary' && this.pendingWordContextToken === selectionToken) {
      this.pendingWordContextToken = '';
      this.wordMarkRequest = 'none';
      this.getUIContext().getPromptAction().showToast({ message: '选区已经变化，请重新选择单词。' });
      return;
    }
    if (this.currentSurface !== 'passage' || this.passageCandidate?.selectionToken !== selectionToken) return;
    this.passageStatus = 'unavailable';
    this.passageDetail = '选区已经变化或失效，请重新选择段落。';
    this.passageRequest = 'none';
  }

  private async lookupSelection(selection: ReaderWordSelection): Promise<void> {
    this.hasUncommittedSelection = true;
    const generation = ++this.selectionUiGeneration;
    this.dictionarySelection = selection;
    this.dictionarySelectedForm = selection.surfaceForm;
    this.dictionaryResult = undefined;
    this.dictionaryExpanded = false;
    this.dictionaryLoading = true;
    this.currentSurface = 'dictionary';
    this.pendingWordContextToken = '';
    this.wordMarkRequest = 'none';
    const service = this.dictionaryService;
    if (service === undefined) {
      if (generation !== this.selectionUiGeneration) return;
      this.dictionaryLoading = false;
      this.dictionaryResult = {
        status: 'unavailable', selectedForm: selection.surfaceForm, entries: []
      };
      return;
    }
    const result = await service.lookup(selection.surfaceForm);
    if (generation !== this.selectionUiGeneration || result === undefined) return;
    this.dictionaryLoading = false;
    this.dictionaryResult = result;
    this.dictionarySelectedForm = result.selectedForm;
  }

  private async copySelectedWord(): Promise<void> {
    if (this.currentSurface !== 'dictionary' || this.dictionarySelectedForm.length === 0) return;
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.dictionarySelectedForm);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制所选单词。' });
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ message: '复制失败，请重试。' });
    }
  }

  private async copySelectedPassageText(selectedText: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, selectedText);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ message: '已复制所选段落。' });
    } catch (_) {
      try { this.getUIContext().getPromptAction().showToast({ message: '复制失败，请重试。' }); }
      catch (_) {}
    }
  }

  private areaLength(value: Length): number {
    if (typeof value === 'number') return value;
    const parsed = Number.parseFloat(String(value));
    return Number.isFinite(parsed) && parsed > 0 ? parsed : 0;
  }

  private systemFontSizeScale(): number {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const scale = Number(context?.config.fontSizeScale ?? 1);
    return Number.isFinite(scale) && scale > 1 ? Math.min(scale, 1.75) : 1;
  }

  private scaledPopupHeight(baseHeight: number): number {
    return Math.ceil(baseHeight * this.systemFontSizeScale());
  }

  private dictionaryPopupHeight(): number {
    if (this.dictionaryExpanded) return this.scaledPopupHeight(320);
    return this.scaledPopupHeight(228);
  }

  private passagePopupHeight(): number {
    if (this.passageStatus === 'mark-conflict' || this.passageStatus === 'mark-unavailable') {
      return this.scaledPopupHeight(148);
    }
    if (this.passageStatus === 'too-long' || this.passageStatus === 'unavailable') {
      return this.scaledPopupHeight(210);
    }
    return this.scaledPopupHeight(154);
  }

  private readerViewportWidthVp(): number {
    if (this.readerSurfaceWidth > 0) return this.readerSurfaceWidth;
    return Math.max(0, this.windowSnapshot.usableWidthVp);
  }

  private readerViewportHeightVp(): number {
    if (this.readerSurfaceHeight > 0) return this.readerSurfaceHeight;
    return Math.max(0, this.windowSnapshot.usableHeightVp);
  }

  private readerPublicationHeightVp(): number {
    return readerPublicationContentHeightVp(this.readerViewportHeightVp());
  }

  private readerPublicationTopVp(): number {
    return readerHeaderReserveVp(this.readerViewportHeightVp());
  }

  private popupViewport(): ReaderPopupViewport {
    return {
      left: 0,
      top: this.readerPublicationTopVp(),
      width: this.readerViewportWidthVp(),
      height: this.readerPublicationHeightVp()
    };
  }

  private popupPlacement(geometry: ReaderSelectionGeometry | undefined,
    legacyRect: ReaderSelectionRect | undefined, desiredHeight: number): SelectionPopupPlacement {
    const viewport = this.popupViewport();
    const cachedViewport = this.cachedPopupViewport;
    if (this.cachedPopupPlacement !== undefined && this.cachedPopupGeometry === geometry &&
      this.cachedPopupLegacyRect === legacyRect && this.cachedPopupDesiredHeight === desiredHeight &&
      cachedViewport !== undefined && cachedViewport.left === viewport.left && cachedViewport.top === viewport.top &&
      cachedViewport.width === viewport.width && cachedViewport.height === viewport.height) {
      return this.cachedPopupPlacement;
    }
    const placement = placeSelectionPopup(geometry, legacyRect, viewport, desiredHeight, POPUP_MARGIN, POPUP_GAP);
    this.cachedPopupGeometry = geometry;
    this.cachedPopupLegacyRect = legacyRect;
    this.cachedPopupViewport = viewport;
    this.cachedPopupDesiredHeight = desiredHeight;
    this.cachedPopupPlacement = placement;
    return placement;
  }

  private dictionaryPlacement(): SelectionPopupPlacement {
    return this.popupPlacement(this.dictionarySelection?.geometry,
      this.dictionarySelection?.rect, this.dictionaryPopupHeight());
  }

  private passagePlacement(): SelectionPopupPlacement {
    return this.popupPlacement(this.passageCandidate?.geometry,
      this.passageCandidate?.rect, this.passagePopupHeight());
  }

  private selectedTextMark(): TextMarkRecord | undefined {
    return this.savedTextMarks.find((item: TextMarkRecord): boolean => item.markId === this.selectedMarkId);
  }

  private markDetailPlacement(): SelectionPopupPlacement {
    return this.popupPlacement(undefined, this.selectedMarkRect,
      this.scaledPopupHeight(this.selectedTextMark()?.kind === 'note' ? 280 : 236));
  }

  private beginAdjustMark(mark: TextMarkRecord): void {
    this.adjustingMarkId = mark.markId;
    this.selectedMarkId = '';
    this.currentSurface = 'none';
    this.getUIContext().getPromptAction().showToast({ message: '长按选出新范围，再点 ✓ 保存。' });
  }

  private beginEditMark(mark: TextMarkRecord): void {
    this.editingNoteMarkId = mark.markId;
    this.noteDraft = mark.noteText;
    this.pendingNoteContext = undefined;
    this.selectedMarkId = '';
    this.currentSurface = 'note-editor';
  }

  private closeMarkDetail(): void {
    this.selectedMarkId = '';
    this.selectedMarkRect = undefined;
    if (this.currentSurface === 'mark-detail') this.currentSurface = 'none';
  }

  private changedSettings(fontScale: number, lineSpacing: number, pageMarginVp: number,
    theme: ReaderTheme): ReaderSettings {
    return {
      fontScale: fontScale,
      lineSpacing: lineSpacing,
      pageMarginVp: pageMarginVp,
      theme: theme,
      columnMode: this.settings.columnMode
    };
  }

  private updateLayoutSettings(next: ReaderSettings): void {
    this.dismissSelectionSurfaces(true);
    this.settings = next;
    this.appearanceApplication?.saveLayoutDefaults(next);
    this.controller.applySettings(this.effectiveReaderSettings(next));
  }

  private selectReaderTheme(preference: ReaderThemePreference): void {
    this.appearanceApplication?.saveThemePreference(preference);
    this.selectedThemePreference = preference;
    const next = this.appearanceApplication?.resolveSettings(this.settings);
    if (next === undefined || next.theme === this.settings.theme) return;
    this.settings = next;
    this.onThemeChange(next.theme);
    this.updateSystemBars(next.theme);
    this.controller.applySettings(this.effectiveReaderSettings(next));
  }

  private applySystemColorModeChange(): void {
    if (!this.hasReaderSession || this.exiting) return;
    const next = this.appearanceApplication?.resolveSettings(this.settings);
    if (next === undefined || next.theme === this.settings.theme) return;
    this.settings = next;
    this.onThemeChange(next.theme);
    this.updateSystemBars(next.theme);
    this.controller.applySettings(this.effectiveReaderSettings(next));
  }

  private isCurrentChapter(chapter: Chapter): boolean {
    const href = this.location?.chapterId;
    return href !== undefined && (href === chapter.href || href.endsWith(chapter.href));
  }

  private readerThemeStatus(): string {
    const preference = this.selectedThemePreference === 'system' ?
      this.resourceText($r('app.string.reader_theme_system')) :
      (this.selectedThemePreference === 'dark' ? this.resourceText($r('app.string.reader_theme_dark')) :
        (this.selectedThemePreference === 'eye-comfort' ?
          this.resourceText($r('app.string.reader_theme_eye_comfort')) :
          this.resourceText($r('app.string.reader_theme_light'))));
    if (this.selectedThemePreference !== 'system') {
      return this.resourceText($r('app.string.reader_theme_default_prefix')) + preference;
    }
    const effective = this.settings.theme === 'dark' ? this.resourceText($r('app.string.reader_theme_dark')) :
      (this.settings.theme === 'eye-comfort' ?
        this.resourceText($r('app.string.reader_theme_eye_comfort')) :
        this.resourceText($r('app.string.reader_theme_light')));
    return this.resourceText($r('app.string.reader_theme_default_prefix')) + preference +
      this.resourceText($r('app.string.reader_theme_effective_prefix')) + effective +
      this.resourceText($r('app.string.reader_theme_effective_suffix'));
  }

  @Builder
  private readerThemeOption(preference: ReaderThemePreference, id: string) {
    Button() {
      Row({ space: $r('app.float.product_space_4') }) {
        if (preference === 'system') {
          Text($r('app.string.reader_theme_system'))
            .fontSize($r('app.float.product_body_small_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
        } else if (preference === 'light') {
          Text($r('app.string.reader_theme_light'))
            .fontSize($r('app.float.product_body_small_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
        } else if (preference === 'dark') {
          Text($r('app.string.reader_theme_dark'))
            .fontSize($r('app.float.product_body_small_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
        } else {
          Text($r('app.string.reader_theme_eye_comfort'))
            .fontSize($r('app.float.product_body_small_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
        }
        if (this.selectedThemePreference === preference) {
          Text($r('app.string.reader_theme_selected_marker'))
            .fontSize($r('app.float.product_caption_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                $r('app.color.reader_accent_light')))
        }
      }
      .justifyContent(FlexAlign.Center)
    }
    .id(id)
    .height($r('app.float.product_target_min'))
    .layoutWeight(1)
    .type(ButtonType.Normal)
    .backgroundColor(this.selectedThemePreference === preference ?
      (this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
        (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
          $r('app.color.reader_selected_light'))) :
      (this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
        (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
          $r('app.color.reader_surface_muted_light'))))
    .border({
      width: 1,
      color: this.selectedThemePreference === preference ?
        (this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
            $r('app.color.reader_accent_light'))) :
        (this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
            $r('app.color.reader_divider_light')))
    })
    .borderRadius($r('app.float.product_radius_control'))
    .onClick((): void => this.selectReaderTheme(preference))
  }

  private exitReader(): void {
    if (this.exiting) return;
    this.exiting = true;
    this.invalidateTransientState(true);
    this.persistLatestLocation().finally((): void => this.onExit());
  }

  private async persistLatestLocation(): Promise<void> {
    await new Promise<void>((resolve): void => {
      const timeout = setTimeout((): void => {
        this.exitLocationResolver = undefined;
        resolve();
      }, 400);
      this.exitLocationResolver = (): void => {
        clearTimeout(timeout);
        this.exitLocationResolver = undefined;
        resolve();
      };
      this.controller.requestLocation();
    });
    await this.session.flush();
  }

  private navigateChapter(direction: number): void {
    this.dismissSelectionSurfaces(true);
    if (direction < 0) this.controller.previousChapter();
    else this.controller.nextChapter();
  }

  private chapterTitle(): string {
    const href = this.location?.chapterId;
    return this.chapterTitleForHref(href);
  }

  private chapterTitleForHref(href: string | undefined): string {
    if (href === undefined) return this.currentBook.title;
    const chapter = this.chapters.find((item) => item.href === href || href.endsWith(item.href));
    return chapter?.label ?? this.currentBook.title;
  }

  private async refreshBookmarks(sessionId: number): Promise<void> {
    if (this.bookmarks === undefined) return;
    try {
      const points = await this.bookmarks.list(this.currentBook.bookId);
      if (sessionId === this.currentSessionId) this.bookmarkPoints = points;
    } catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkMessage = '书签读取失败，请重试。';
    }
    if (this.textMarks === undefined) return;
    try {
      const marks = await this.textMarks.list(this.currentBook.bookId);
      if (sessionId !== this.currentSessionId) return;
      this.savedTextMarks = marks;
      this.previewVisibleTextMarks();
    } catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkMessage = '标记读取失败，请重试。';
    }
  }

  private readingListEntries(): ReadingListEntry[] {
    const entries: ReadingListEntry[] = [];
    for (const point of this.bookmarkPoints) {
      const separator = point.label.indexOf(' · ');
      entries.push({ id: `page-${point.bookmarkId}`, kind: 'page',
        title: separator < 0 ? point.label || this.currentBook.title : point.label.slice(0, separator),
        detail: separator < 0 ? '页面书签' : point.label.slice(separator + 3),
        createdAt: point.createdAt, point });
    }
    for (const mark of this.savedTextMarks) {
      entries.push({ id: `mark-${mark.markId}`, kind: mark.kind,
        title: mark.chapterTitle || this.currentBook.title,
        detail: (this.orphanMarkIds.includes(mark.markId) ? '暂时无法跳转 · ' : '') +
          (mark.kind === 'note' ? mark.noteText : mark.exactText),
        createdAt: mark.createdAt, mark });
    }
    return entries.sort((a: ReadingListEntry, b: ReadingListEntry): number =>
      b.createdAt - a.createdAt || a.id.localeCompare(b.id));
  }

  private previewVisibleTextMarks(): void {
    const chapter = this.location?.chapterId;
    if (!this.bookmarkReady || chapter === undefined) return;
    for (const mark of this.savedTextMarks.filter((item: TextMarkRecord): boolean =>
      item.resourceHref === chapter || chapter.endsWith(item.resourceHref)).slice(0, 100)) {
      this.controller.previewTextMark(readerTextMark(mark), this.currentSessionId);
    }
  }

  private async removeTextMark(mark: TextMarkRecord): Promise<void> {
    if (this.textMarks === undefined || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.bookmarkBusy = true;
    try {
      await this.textMarks.remove(this.currentBook.bookId, mark.markId);
      if (sessionId !== this.currentSessionId) return;
      this.savedTextMarks = this.savedTextMarks.filter((item: TextMarkRecord): boolean =>
        item.markId !== mark.markId);
      this.orphanMarkIds = this.orphanMarkIds.filter((id: string): boolean => id !== mark.markId);
      this.controller.removeTextMark(mark.markId, sessionId);
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkMessage = '删除标记失败，请重试。';
        this.getUIContext().getPromptAction().showToast({ message: this.bookmarkMessage });
      }
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private jumpTextMark(mark: TextMarkRecord): void {
    if (!this.bookmarkReady || this.pendingMarkId.length > 0) return;
    if (this.orphanMarkIds.includes(mark.markId)) {
      this.selectedMarkId = mark.markId;
      this.selectedMarkRect = undefined;
      this.currentSurface = 'mark-detail';
      return;
    }
    this.pendingMarkId = mark.markId;
    this.bookmarkMessage = '';
    this.controller.goToTextMark(readerTextMark(mark), this.currentSessionId);
  }

  private async retainRecoveredTextMark(markId: string, cfi: string,
    sessionId: number): Promise<void> {
    const mark = this.savedTextMarks.find((item: TextMarkRecord): boolean => item.markId === markId);
    if (mark === undefined || this.textMarks === undefined || mark.cfi === cfi) return;
    try {
      const recovered = await this.textMarks.retainRecoveredCfi(mark, cfi);
      if (sessionId !== this.currentSessionId || mark.bookId !== this.currentBook.bookId) return;
      this.savedTextMarks = this.savedTextMarks.map((item: TextMarkRecord): TextMarkRecord =>
        item.markId === markId ? recovered : item);
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkMessage = '标记已定位，但新位置保存失败，请稍后重试。';
      }
    }
  }

  private currentBookmark(): BookmarkPoint | undefined {
    const location = this.location;
    if (location === undefined) return undefined;
    const point = bookmarkPointFromLocation('current', this.currentBook.bookId, location, '', 0);
    if (point === undefined) return undefined;
    return this.bookmarkPoints.find((item: BookmarkPoint): boolean =>
      item.engine === point.engine && item.resourceHref === point.resourceHref && item.cfi === point.cfi);
  }

  private async toggleBookmark(): Promise<void> {
    if (this.bookmarks === undefined || this.location === undefined || !this.bookmarkReady || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.bookmarkBusy = true;
    this.bookmarkMessage = '';
    try {
      const result = await this.bookmarks.toggle(this.currentBook, this.location,
        this.chapterTitle(), this.currentPageExcerpt.slice(0, 200));
      if (sessionId !== this.currentSessionId) return;
      this.bookmarkPoints = result.points;
      this.bookmarkMessage = result.added ? '已添加书签' : '已移除书签';
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkMessage = '书签保存失败，请重试。';
      }
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private async removeBookmark(point: BookmarkPoint): Promise<void> {
    if (this.bookmarks === undefined || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.bookmarkBusy = true;
    this.bookmarkMessage = '';
    try {
      const points = await this.bookmarks.remove(this.currentBook.bookId, point.bookmarkId);
      if (sessionId === this.currentSessionId) this.bookmarkPoints = points;
    } catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkMessage = '删除书签失败，请重试。';
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private jumpBookmark(point: BookmarkPoint): void {
    if (!this.bookmarkReady || this.pendingBookmarkId.length > 0) return;
    this.pendingBookmarkId = point.bookmarkId;
    this.bookmarkMessage = '';
    this.controller.goToBookmark(point, this.currentSessionId);
  }

  private approximateProgressPercentage(): string {
    if (this.location?.percentage === undefined) return '';
    const percentage = Math.max(0, Math.min(100, Math.round(this.location.percentage * 100)));
    return `${percentage}%`;
  }

  private isSideReaderPanel(): boolean {
    return readerUsesSidePanel(this.windowSnapshot);
  }

  private effectiveReaderSettings(settings: ReaderSettings): ReaderSettings {
    const columnMode = adaptiveReaderColumnMode(this.windowSnapshot, settings.columnMode);
    if (columnMode === settings.columnMode) return settings;
    return {
      fontScale: settings.fontScale,
      lineSpacing: settings.lineSpacing,
      pageMarginVp: settings.pageMarginVp,
      theme: settings.theme,
      columnMode: columnMode
    };
  }

  private resourceText(resource: Resource, ...args: Array<string | number>): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync(resource.id, ...args);
    } catch (_) {
      return '';
    }
  }

  private externalLinkHost(url: string): string {
    try {
      const parsed = new uri.URI(url);
      return validatedExternalLinkHost(parsed.userInfo, parsed.host);
    } catch (_) {
      return '';
    }
  }
  private updateSelectionGeometry(selectionToken: string, geometry: ReaderSelectionGeometry): void {
    const word = this.dictionarySelection;
    if (word !== undefined && word.selectionToken === selectionToken) {
      this.dictionarySelection = {
        engine: word.engine,
        selectionToken: word.selectionToken,
        characterCount: word.characterCount,
        surfaceForm: word.surfaceForm,
        locator: word.locator,
        geometry: geometry,
        rect: geometry.anchor
      };
    }
    const passage = this.passageCandidate;
    if (passage !== undefined && passage.selectionToken === selectionToken) {
      this.passageCandidate = {
        engine: passage.engine,
        selectionToken: passage.selectionToken,
        characterCount: passage.characterCount,
        locator: passage.locator,
        geometry: geometry,
        rect: geometry.anchor
      };
    }
  }

  private focusPublicationForSelection(): void {
    this.dismissReaderPanel();
    this.setControlsVisible(false);
    this.controller.focusContent();
  }

  private confirmExternalLink(request: ReaderExternalLinkRequest): void {
    const host = this.externalLinkHost(request.url);
    if (host.length === 0) return;
    const requestedSessionId = this.currentSessionId;
    this.getUIContext().showAlertDialog({
      title: $r('app.string.reader_external_link_title'),
      message: this.resourceText($r('app.string.reader_external_link_body'), host),
      primaryButton: {
        value: $r('app.string.common_cancel'),
        action: (): void => {}
      },
      secondaryButton: {
        value: $r('app.string.reader_external_link_open'),
        action: (): void => {
          if (requestedSessionId !== this.currentSessionId) return;
          const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          context.openLink(request.url).catch((): void => {
            if (requestedSessionId === this.currentSessionId) {
              this.errorText = '无法使用系统浏览器打开此链接。';
            }
          });
        }
      }
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      ReaderFourSurfaceView({
        book: this.currentBook,
        animateCustomMotion: this.animateCustomMotion,
        initialLocation: this.hostInitialLocation,
        settings: this.effectiveReaderSettings(this.settings),
        sessionId: this.currentSessionId,
        controller: this.controller,
        onCandidateStage: (stage: string): void => { SafeLog.readerCandidateFailure(stage); },
        callbacks: {
          onReady: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.bookmarkReady = true;
            this.refreshBookmarks(eventSessionId).catch((): void => {});
            const initialBookmark = this.pendingInitialBookmark;
            this.pendingInitialBookmark = undefined;
            if (initialBookmark !== undefined) this.jumpBookmark(initialBookmark);
            else this.controller.requestLocation();
            this.onReady(eventSessionId);
          },
          onBookmarkJumpResult: (eventSessionId: number, bookmarkId: string, success: boolean): void => {
            if (eventSessionId !== this.currentSessionId || this.pendingBookmarkId !== bookmarkId) return;
            this.pendingBookmarkId = '';
            if (success) {
              this.currentSurface = 'none';
              this.bookmarkMessage = '';
            } else {
              this.bookmarkMessage = '无法定位此书签，请检查书籍内容。';
              this.bookmarkTab = 'bookmarks';
              this.currentSurface = 'toc';
              this.controller.requestLocation();
            }
          },
          onTextMarkResult: (eventSessionId: number, markId: string,
            action: 'preview' | 'jump', success: boolean): void => {
            if (eventSessionId !== this.currentSessionId || action !== 'jump' ||
              this.pendingMarkId !== markId) return;
            this.pendingMarkId = '';
            if (success) {
              this.currentSurface = 'none';
              this.bookmarkMessage = '';
            } else {
              this.bookmarkMessage = '无法定位这条标记，请检查书籍内容。';
              this.bookmarkTab = 'bookmarks';
              this.currentSurface = 'toc';
            }
          },
          onTextMarkResolution: (eventSessionId: number, markId: string, resolution): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (resolution.status === 'orphaned') {
              if (resolution.reason === 'missing' || resolution.reason === 'ambiguous') {
                if (!this.orphanMarkIds.includes(markId)) this.orphanMarkIds = [...this.orphanMarkIds, markId];
                if (this.pendingMarkId === markId) {
                  this.bookmarkMessage = '暂时无法跳转；原句和笔记仍保留。';
                }
              }
              return;
            }
            this.orphanMarkIds = this.orphanMarkIds.filter((id: string): boolean => id !== markId);
            if (resolution.status === 'recovered' && resolution.cfi !== undefined) {
              this.retainRecoveredTextMark(markId, resolution.cfi, eventSessionId).catch((): void => {});
            }
          },
          onTextMarkTap: (eventSessionId: number, markId: string, rect: ReaderSelectionRect): void => {
            if (eventSessionId !== this.currentSessionId ||
              !this.savedTextMarks.some((mark: TextMarkRecord): boolean => mark.markId === markId)) return;
            this.adjustingMarkId = '';
            this.selectedMarkId = markId;
            this.selectedMarkRect = rect;
            this.currentSurface = 'mark-detail';
          },
          onTableOfContents: (eventSessionId: number, chapters: Chapter[]): void => {
            if (eventSessionId === this.currentSessionId) this.chapters = chapters;
          },
          onPageExcerpt: (eventSessionId: number, excerpt: string): void => {
            if (eventSessionId === this.currentSessionId) this.currentPageExcerpt = excerpt.trim();
          },
          onLocation: (eventSessionId: number, location: ReadingLocation, cause: ReaderLocationCause): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (this.navigationError) {
              this.navigationError = false;
              this.errorText = '';
            }
            if (shouldDismissTransientSurfaceForLocation(cause)) this.adjustingMarkId = '';
            if (shouldDismissTransientSurfaceForLocation(cause) && (this.currentSurface === 'dictionary' ||
              this.currentSurface === 'passage' ||
              this.currentSurface === 'mark-detail')) {
              this.hasUncommittedSelection = false;
              this.dismissSelectionSurfaces(false);
              this.closeMarkDetail();
              this.adjustingMarkId = '';
            }
            this.location = location;
            this.currentPageExcerpt = '';
            this.controller.requestPageExcerpt(eventSessionId);
            this.previewVisibleTextMarks();
            this.session.update(eventSessionId, this.currentBook.bookId, location);
            this.exitLocationResolver?.();
          },
          onWordSelection: (eventSessionId: number, selection: ReaderWordSelection): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.hasUncommittedSelection = true;
            this.dismissReaderPanel();
            this.dismissPassage(false);
            this.lookupSelection(selection).catch((): void => {
              if (this.currentSurface === 'dictionary') {
                this.dictionaryLoading = false;
                this.dictionaryResult = {
                  status: 'unavailable', selectedForm: selection.surfaceForm, entries: []
                };
              }
            });
            this.onWordSelection(selection);
          },
          onPassageSelection: (eventSessionId: number, selection: PassageSelectionCandidate): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.hasUncommittedSelection = true;
            this.dismissReaderPanel();
            this.showPassageCandidate(selection);
          },
          onSelectionAdjusting: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.hideSelectionSurfacesForAdjustment();
          },
          onSelectionContext: (eventSessionId: number, context: ReadingSelectionContext): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.acceptSelectionContext(context);
          },
          onSelectionContextRejected: (eventSessionId: number, selectionToken: string, _reason: string): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.rejectSelectionContext(selectionToken);
          },
          onSelectionRejected: (eventSessionId: number, reason: string, characterCount?: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (reason === 'passage-too-long') this.showPassageTooLong(characterCount);
            this.onSelectionRejected(reason);
          },
          onSelectionCleared: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.handleSelectionCleared();
          },
          onSelectionGeometryChanged: (eventSessionId: number, selectionToken: string,
            geometry: ReaderSelectionGeometry): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.updateSelectionGeometry(selectionToken, geometry);
          },
          onControlsToggle: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.setControlsVisible(!this.controlsVisible);
            if (!this.controlsVisible) this.dismissReaderPanel();
          },
          onLinkState: (eventSessionId: number, state: ReaderLinkState): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.linkState = state;
          },
          onExternalLinkRequest: (eventSessionId: number, _request: ReaderExternalLinkRequest): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.confirmExternalLink(_request);
          },
          onBackRequested: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.handleSystemBack();
          },
          onError: (eventSessionId: number, category: ReaderFatalErrorCategory): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (category === 'navigation') {
              this.navigationError = true;
              this.errorText = '翻页未完成，请重试。轻点关闭';
              return;
            }
            this.invalidateTransientState(true);
            this.navigationError = false;
            this.errorText = '阅读器无法完成当前打开操作。';
            this.onFatalError(eventSessionId, category);
          }
        }
      }).width(this.readerViewportWidthVp()).height(this.readerPublicationHeightVp())
        .position({ x: 0, y: this.readerPublicationTopVp() })

      if (!this.controlsVisible) {
        Row() {
          if (this.location?.percentage === undefined) {
            Text($r('app.string.reader_progress_calculating'))
              .fontSize($r('app.float.product_caption_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_progress_text_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_progress_text_eye_comfort') :
                  $r('app.color.reader_progress_text_light')))
          } else {
            Text($r('app.string.reader_progress_approximate'))
              .fontSize($r('app.float.product_caption_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_progress_text_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_progress_text_eye_comfort') :
                  $r('app.color.reader_progress_text_light')))
            Text(this.approximateProgressPercentage())
              .fontSize($r('app.float.product_caption_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_progress_text_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_progress_text_eye_comfort') :
                  $r('app.color.reader_progress_text_light')))
          }
        }
          .id('reader-progress-quiet')
          .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_12'),
            top: $r('app.float.product_space_4'), bottom: $r('app.float.product_space_4') })
          .margin({ bottom: $r('app.float.product_space_8') })
          .layoutGravity(LocalizedAlignment.BOTTOM)
          .transition(this.readerSurfaceTransition())
          .hitTestBehavior(HitTestMode.None)

        Button($r('app.string.reader_show_controls'))
          .id('reader-show-controls')
          .constraintSize({
            minWidth: $r('app.float.product_target_min'),
            minHeight: $r('app.float.product_target_min')
          })
          .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_12') })
          .margin({ right: $r('app.float.product_space_8'), bottom: $r('app.float.product_space_8') })
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') : $r('app.color.reader_text_secondary_light'))))
          .fontSize($r('app.float.product_caption_size'))
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_show_controls'))
          .layoutGravity(LocalizedAlignment.BOTTOM_END)
          .onClick((): void => { this.setControlsVisible(true); })
      }

      if (this.controlsVisible && this.currentSurface === 'none') {
        Row({ space: $r('app.float.product_space_4') }) {
          Button() {
            Row({ space: $r('app.float.product_space_4') }) {
              SymbolGlyph($r('sys.symbol.chevron_left'))
                .fontSize($r('app.float.product_body_size'))
                .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))])
              Text($r('app.string.reader_library_short'))
                .fontSize($r('app.float.product_body_small_size'))
                .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light'))))
                .maxLines(1)
            }
          }
          .id('reader-library-back')
          .constraintSize({ minWidth: $r('app.float.product_target_min'),
            minHeight: $r('app.float.product_target_min') })
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_back_to_library'))
          .onClick(() => this.exitReader())

          if (this.linkState.canReturn) {
            Button(this.linkState.kind === 'footnote' ?
              $r('app.string.reader_return_from_footnote') :
              $r('app.string.reader_return_from_link'))
              .id('reader-return-from-link')
              .constraintSize({
                minWidth: $r('app.float.product_target_min'),
                minHeight: $r('app.float.product_target_min')
              })
              .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
              .type(ButtonType.Normal)
              .backgroundColor(Color.Transparent)
              .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light'))))
              .borderRadius($r('app.float.product_radius_control'))
              .accessibilityText(this.linkState.kind === 'footnote' ?
                $r('app.string.reader_return_from_footnote') :
                $r('app.string.reader_return_from_link'))
              .onClick((): void => { this.controller.returnFromInternalLink(); })
          }

          Text(this.chapterTitle())
            .id('reader-chapter-title')
            .fontSize($r('app.float.product_body_small_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light'))))
            .textAlign(TextAlign.Center)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Button() {
            Text(this.currentBookmark() === undefined ? '☆' : '★')
              .fontSize($r('app.float.product_section_title_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                  $r('app.color.reader_accent_light')))
          }
          .id('reader-bookmark-toggle')
          .width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min'))
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText(this.currentBookmark() === undefined ? '添加书签' : '移除当前书签')
          .enabled(this.bookmarkReady && this.location !== undefined && !this.bookmarkBusy &&
            this.pendingBookmarkId.length === 0)
          .onClick((): void => { this.toggleBookmark().catch((): void => {}); })
        }
        .id('reader-chrome-top')
        .width('100%')
        .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_12'),
          top: $r('app.float.product_space_8'), bottom: $r('app.float.product_space_8') })
        .backgroundColor((this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') : $r('app.color.reader_surface_light'))))
        .transition(this.readerSurfaceTransition())
        .layoutGravity(LocalizedAlignment.TOP)

        Row({ space: $r('app.float.product_space_4') }) {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize($r('app.float.product_body_size'))
              .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))])
          }
          .id('reader-previous-chapter')
          .width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_previous_chapter'))
          .onClick(() => this.navigateChapter(-1))

          Row() {
            if (this.location?.percentage === undefined) {
              Text($r('app.string.reader_progress_calculating'))
                .fontSize($r('app.float.product_caption_size'))
                .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') : $r('app.color.reader_text_secondary_light'))))
                .maxLines(1)
            } else {
              Text($r('app.string.reader_progress_approximate'))
                .fontSize($r('app.float.product_caption_size'))
                .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') : $r('app.color.reader_text_secondary_light'))))
                .maxLines(1)
              Text(this.approximateProgressPercentage())
                .fontSize($r('app.float.product_caption_size'))
                .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') : $r('app.color.reader_text_secondary_light'))))
                .maxLines(1)
            }
          }
          .id('reader-progress-revealed')
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)

          Button() {
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize($r('app.float.product_body_size'))
              .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))])
          }
          .id('reader-next-chapter')
          .width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_next_chapter'))
          .onClick(() => this.navigateChapter(1))

          Button() {
            SymbolGlyph($r('sys.symbol.list_bullet'))
              .fontSize($r('app.float.product_body_size'))
              .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light')))])
          }
          .id('reader-open-toc')
          .width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_open_toc'))
          .onClick(() => {
            this.dismissSelectionSurfaces(true);
            this.currentSurface = this.currentSurface === 'toc' ? 'none' : 'toc';
          })

          Button() {
            Text($r('app.string.reader_appearance_glyph'))
              .fontSize($r('app.float.product_body_size'))
              .fontWeight(FontWeight.Medium)
              .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light'))))
          }
          .id('reader-open-appearance')
          .width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min'))
          .type(ButtonType.Normal)
          .backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.reader_open_appearance'))
          .onClick(() => {
            this.dismissSelectionSurfaces(true);
            this.currentSurface = this.currentSurface === 'appearance' ? 'none' : 'appearance';
          })

          Button($r('app.string.reader_select_text_short'))
            .id('reader-focus-publication')
            .width($r('app.float.product_target_min'))
            .height($r('app.float.product_target_min'))
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .fontColor((this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light'))))
            .borderRadius($r('app.float.product_radius_control'))
            .accessibilityText($r('app.string.reader_select_text'))
            .onClick((): void => { this.focusPublicationForSelection(); })
        }
        .id('reader-chrome-bottom')
        .width('100%')
        .padding($r('app.float.product_space_8'))
        .backgroundColor((this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') : (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') : $r('app.color.reader_surface_light'))))
        .transition(this.readerSurfaceTransition())
        .layoutGravity(LocalizedAlignment.BOTTOM)
        .onAppear((): void => {
          const target = this.panelFocusReturn;
          this.panelFocusReturn = 'none';
          if (target === 'toc') focusControl.requestFocus('reader-open-toc');
          if (target === 'appearance') focusControl.requestFocus('reader-open-appearance');
        })
      }

      if (this.currentSurface === 'toc' || this.currentSurface === 'appearance') {
        Column() {}
          .id('reader-panel-scrim')
          .width('100%')
          .height('100%')
          .backgroundColor(this.isSideReaderPanel() ? Color.Transparent :
            (this.settings.theme === 'dark' ? $r('app.color.reader_scrim_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_scrim_eye_comfort') :
                $r('app.color.reader_scrim_light'))))
          .hitTestBehavior(HitTestMode.Block)
          .transition(this.readerSurfaceTransition())
          .onClick((): void => { this.dismissReaderPanel(true); })
      }

      if (this.currentSurface === 'toc') {
        Column({ space: $r('app.float.product_space_8') }) {
          Row() {
            Text($r('app.string.reader_toc_title'))
              .id('reader-toc-title')
              .fontSize($r('app.float.product_surface_title_size'))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
              .layoutWeight(1)
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize($r('app.float.product_body_size'))
                .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light')))])
            }
            .id('reader-toc-close')
            .width($r('app.float.product_target_min'))
            .height($r('app.float.product_target_min'))
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.reader_toc_close'))
            .onClick((): void => { this.dismissReaderPanel(true); })
          }
          .width('100%')
          Divider().color(this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')))
          Row({ space: $r('app.float.product_space_8') }) {
            Button($r('app.string.reader_toc_title')).id('reader-toc-tab-contents')
              .height($r('app.float.product_target_min')).layoutWeight(1)
              .type(ButtonType.Normal)
              .fontColor(this.bookmarkTab === 'contents' ?
                (this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                    $r('app.color.reader_accent_light'))) :
                (this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light'))))
              .backgroundColor(this.bookmarkTab === 'contents' ?
                (this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
                    $r('app.color.reader_selected_light'))) : Color.Transparent)
              .onClick((): void => { this.bookmarkTab = 'contents'; })
            Button('书签与笔记').id('reader-toc-tab-bookmarks')
              .height($r('app.float.product_target_min')).layoutWeight(1)
              .type(ButtonType.Normal)
              .fontColor(this.bookmarkTab === 'bookmarks' ?
                (this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                    $r('app.color.reader_accent_light'))) :
                (this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light'))))
              .backgroundColor(this.bookmarkTab === 'bookmarks' ?
                (this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
                    $r('app.color.reader_selected_light'))) : Color.Transparent)
              .onClick((): void => {
                this.bookmarkTab = 'bookmarks';
                this.refreshBookmarks(this.currentSessionId).catch((): void => {});
              })
          }.width('100%')
          if (this.bookmarkMessage.length > 0) {
            Text(this.bookmarkMessage).id('reader-bookmark-message')
              .fontSize($r('app.float.product_caption_size'))
              .fontColor(this.bookmarkMessage.startsWith('已') ?
                (this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                    $r('app.color.reader_text_secondary_light'))) :
                (this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
                    $r('app.color.reader_error_light')))).width('100%')
          }
          if (this.bookmarkTab === 'bookmarks' && this.bookmarkPoints.length + this.savedTextMarks.length === 0) {
            Text('还没有书签或笔记。点顶部星标，或选中句子后添加。')
              .fontSize($r('app.float.product_body_small_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                  $r('app.color.reader_text_secondary_light')))
              .textAlign(TextAlign.Center).width('100%')
              .layoutWeight(this.isSideReaderPanel() ? 0 : 1)
          } else if (this.bookmarkTab === 'bookmarks') {
            List({ space: READER_TOC_LIST_SPACE_VP }) {
              ForEach(this.readingListEntries(), (entry: ReadingListEntry) => {
                ListItem() {
                  Row({ space: $r('app.float.product_space_8') }) {
                    Image(entry.kind === 'page' ?
                      (this.settings.theme === 'dark' ? $r('app.media.reader_mark_page_dark') :
                        $r('app.media.reader_mark_page')) :
                      (entry.kind === 'note' ?
                        (this.settings.theme === 'dark' ? $r('app.media.reader_mark_note_dark') :
                          $r('app.media.reader_mark_note')) :
                        (this.settings.theme === 'dark' ? $r('app.media.reader_mark_highlight_dark') :
                          $r('app.media.reader_mark_highlight'))))
                      .width(32).height(32).padding(5)
                      .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                        (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                          $r('app.color.reader_accent_light')))
                      .borderRadius($r('app.float.product_radius_control'))
                      .accessibilityText(entry.kind === 'page' ? '页面书签' :
                        (entry.kind === 'note' ? '句子笔记' : '句子高亮'))
                    Button() {
                      Column({ space: $r('app.float.product_space_4') }) {
                        Text(entry.title)
                          .fontSize($r('app.float.product_body_small_size'))
                          .fontWeight(FontWeight.Medium)
                          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(entry.detail)
                          .fontSize($r('app.float.product_caption_size'))
                          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                      }.alignItems(HorizontalAlign.Start).width('100%')
                    }.id('reader-bookmark-jump').layoutWeight(1)
                      .constraintSize({ minHeight: $r('app.float.product_target_min') })
                      .type(ButtonType.Normal).backgroundColor(Color.Transparent)
                      .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                        (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                          $r('app.color.reader_text_primary_light')))
                      .enabled(this.bookmarkReady && this.pendingBookmarkId.length === 0)
                      .onClick((): void => {
                        if (entry.point !== undefined) this.jumpBookmark(entry.point);
                        else if (entry.mark !== undefined) this.jumpTextMark(entry.mark);
                      })
                    Button() {
                      SymbolGlyph($r('sys.symbol.xmark'))
                        .fontSize($r('app.float.product_body_size'))
                        .fontColor([this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
                          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
                            $r('app.color.reader_error_light'))])
                    }.id('reader-bookmark-delete')
                      .height($r('app.float.product_target_min'))
                      .width($r('app.float.product_target_min'))
                      .type(ButtonType.Normal).backgroundColor(Color.Transparent)
                      .accessibilityText('删除这条' + (entry.kind === 'page' ? '书签' :
                        (entry.kind === 'note' ? '笔记' : '高亮')))
                      .enabled(!this.bookmarkBusy)
                      .onClick((): void => {
                        if (entry.point !== undefined) this.removeBookmark(entry.point).catch((): void => {});
                        else if (entry.mark !== undefined) this.removeTextMark(entry.mark).catch((): void => {});
                      })
                  }.width('100%')
                }
              }, (entry: ReadingListEntry) => entry.id)
            }.id('reader-bookmark-list')
              .layoutWeight(this.isSideReaderPanel() ? 0 : 1).width('100%')
              .constraintSize({ maxHeight: this.isSideReaderPanel() ?
                Math.max(120, this.readerViewportHeightVp() - 160) :
                $r('app.float.reader_transient_panel_height') })
          } else if (this.chapters.length === 0) {
            Text($r('app.string.reader_toc_empty'))
              .fontSize($r('app.float.product_body_small_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                  $r('app.color.reader_text_secondary_light')))
              .textAlign(TextAlign.Center)
              .width('100%')
              .layoutWeight(this.isSideReaderPanel() ? 0 : 1)
          } else {
            List({ space: READER_TOC_LIST_SPACE_VP }) {
              ForEach(this.chapters, (chapter: Chapter) => {
                ListItem() {
                  Row({ space: $r('app.float.product_space_8') }) {
                    Text(chapter.label)
                      .fontSize($r('app.float.product_body_small_size'))
                      .fontWeight(this.isCurrentChapter(chapter) ? FontWeight.Medium : FontWeight.Regular)
                      .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                        (this.settings.theme === 'eye-comfort' ?
                          $r('app.color.reader_text_primary_eye_comfort') :
                          $r('app.color.reader_text_primary_light')))
                      .maxLines(2)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .layoutWeight(1)
                    if (this.isCurrentChapter(chapter)) {
                      Text($r('app.string.reader_toc_current'))
                        .fontSize($r('app.float.product_caption_size'))
                        .fontWeight(FontWeight.Medium)
                        .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                            $r('app.color.reader_accent_light')))
                    }
                  }
                  .id(this.isCurrentChapter(chapter) ? 'reader-toc-current-chapter' : 'reader-toc-chapter')
                  .constraintSize({ minHeight: $r('app.float.product_target_min') })
                  .width('100%')
                  .alignItems(VerticalAlign.Center)
                  .focusable(true)
                  .accessibilityText(chapter.label)
                  .padding({
                    left: $r('app.float.product_space_12'),
                    right: $r('app.float.product_space_12'),
                    top: $r('app.float.product_space_8'),
                    bottom: $r('app.float.product_space_8')
                  })
                  .backgroundColor(this.isCurrentChapter(chapter) ?
                    (this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
                        $r('app.color.reader_selected_light'))) : Color.Transparent)
                  .borderRadius($r('app.float.product_radius_control'))
                  .onClick((): void => {
                    this.dismissSelectionSurfaces(true);
                    this.controller.goToChapter(chapter.href);
                    this.currentSurface = 'none';
                  })
                }
              }, (chapter: Chapter) => chapter.id)
            }
            .id('reader-toc-list')
            .layoutWeight(this.isSideReaderPanel() ? 0 : 1)
            .width('100%')
            .constraintSize({
              maxHeight: this.isSideReaderPanel() ?
                Math.max(120, this.readerViewportHeightVp() - 112) :
                $r('app.float.reader_transient_panel_height')
            })
          }
        }
        .id('reader-toc-panel')
        .width(this.isSideReaderPanel() ? 336 : '92%')
        .height(this.isSideReaderPanel() ?
          'auto' :
          $r('app.float.reader_transient_panel_height'))
        .constraintSize({
          maxWidth: $r('app.float.product_modal_max_width'),
          maxHeight: this.isSideReaderPanel() ?
            Math.max(240, this.readerViewportHeightVp() - 32) :
            $r('app.float.reader_transient_panel_height')
        })
        .padding($r('app.float.product_space_16'))
        .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
            $r('app.color.reader_surface_light')))
        .border({
          width: 1,
          color: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light'))
        })
        .borderRadius($r('app.float.product_radius_modal'))
        .transition(this.readerSurfaceTransition())
        .hitTestBehavior(HitTestMode.Default)
        .layoutGravity(this.isSideReaderPanel() ? LocalizedAlignment.TOP_END : LocalizedAlignment.CENTER)
        .margin({
          top: this.isSideReaderPanel() ? 16 : 0,
          right: this.isSideReaderPanel() ? 16 : 0
        })
      }

      if (this.currentSurface === 'appearance') {
        Column({ space: $r('app.float.product_space_8') }) {
          Row() {
            Text($r('app.string.reader_appearance_title'))
              .id('reader-appearance-title')
              .fontSize($r('app.float.product_surface_title_size'))
              .fontWeight(FontWeight.Medium)
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
              .layoutWeight(1)
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize($r('app.float.product_body_size'))
                .fontColor([(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light')))])
            }
            .id('reader-appearance-close')
            .width($r('app.float.product_target_min'))
            .height($r('app.float.product_target_min'))
            .type(ButtonType.Normal)
            .backgroundColor(Color.Transparent)
            .accessibilityText($r('app.string.reader_appearance_close'))
            .onClick((): void => { this.dismissReaderPanel(true); })
          }
          .width('100%')
          Text($r('app.string.reader_appearance_subtitle'))
            .fontSize($r('app.float.product_caption_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                $r('app.color.reader_text_secondary_light')))
            .width('100%')
          Divider().color(this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')))
          Scroll() {
            Column({ space: $r('app.float.product_space_12') }) {
              Row({ space: $r('app.float.product_space_4') }) {
                Text($r('app.string.reader_font_scale'))
                  .fontSize($r('app.float.product_body_small_size'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                      $r('app.color.reader_text_primary_light')))
                  .layoutWeight(1)
                Button($r('app.string.reader_font_scale_decrease_glyph'))
                  .id('reader-font-scale-decrease')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_font_scale_decrease'))
                  .enabled(this.settings.fontScale > 0.8)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    Math.max(0.8, this.settings.fontScale - 0.1), this.settings.lineSpacing,
                    this.settings.pageMarginVp, this.settings.theme)))
                Row() {
                  Text(`${Math.round(this.settings.fontScale * 100)}`)
                    .fontSize($r('app.float.product_body_small_size'))
                    .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                      (this.settings.theme === 'eye-comfort' ?
                        $r('app.color.reader_text_primary_eye_comfort') :
                        $r('app.color.reader_text_primary_light')))
                  Text($r('app.string.reader_percent_unit'))
                    .fontSize($r('app.float.product_body_small_size'))
                    .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                      (this.settings.theme === 'eye-comfort' ?
                        $r('app.color.reader_text_primary_eye_comfort') :
                        $r('app.color.reader_text_primary_light')))
                }
                .id('reader-font-scale-current')
                .width($r('app.float.product_target_min'))
                .justifyContent(FlexAlign.Center)
                Button($r('app.string.reader_font_scale_increase_glyph'))
                  .id('reader-font-scale-increase')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_font_scale_increase'))
                  .enabled(this.settings.fontScale < 1.6)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    Math.min(1.6, this.settings.fontScale + 0.1), this.settings.lineSpacing,
                    this.settings.pageMarginVp, this.settings.theme)))
              }
              .width('100%')
              .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_4') })
              .backgroundColor(Color.Transparent)
              .borderRadius($r('app.float.product_radius_control'))

              Row({ space: $r('app.float.product_space_4') }) {
                Text($r('app.string.reader_line_spacing'))
                  .fontSize($r('app.float.product_body_small_size'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                      $r('app.color.reader_text_primary_light')))
                  .layoutWeight(1)
                Button($r('app.string.reader_decrease_glyph'))
                  .id('reader-line-spacing-decrease')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_line_spacing_decrease'))
                  .enabled(this.settings.lineSpacing > 1.2)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    this.settings.fontScale, Math.max(1.2, this.settings.lineSpacing - 0.1),
                    this.settings.pageMarginVp, this.settings.theme)))
                Text(this.settings.lineSpacing.toFixed(1))
                  .id('reader-line-spacing-current')
                  .width($r('app.float.product_target_min'))
                  .fontSize($r('app.float.product_body_small_size'))
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                      $r('app.color.reader_text_primary_light')))
                  .textAlign(TextAlign.Center)
                Button($r('app.string.reader_increase_glyph'))
                  .id('reader-line-spacing-increase')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_line_spacing_increase'))
                  .enabled(this.settings.lineSpacing < 2.0)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    this.settings.fontScale, Math.min(2.0, this.settings.lineSpacing + 0.1),
                    this.settings.pageMarginVp, this.settings.theme)))
              }
              .width('100%')
              .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_4') })
              .backgroundColor(Color.Transparent)
              .borderRadius($r('app.float.product_radius_control'))

              Row({ space: $r('app.float.product_space_4') }) {
                Text($r('app.string.reader_page_margin'))
                  .fontSize($r('app.float.product_body_small_size'))
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                      $r('app.color.reader_text_primary_light')))
                  .layoutWeight(1)
                Button($r('app.string.reader_decrease_glyph'))
                  .id('reader-page-margin-decrease')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_page_margin_decrease'))
                  .enabled(this.settings.pageMarginVp > 8)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    this.settings.fontScale, this.settings.lineSpacing,
                    Math.max(8, this.settings.pageMarginVp - 4), this.settings.theme)))
                Row() {
                  Text(`${this.settings.pageMarginVp}`)
                    .fontSize($r('app.float.product_body_small_size'))
                    .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                      (this.settings.theme === 'eye-comfort' ?
                        $r('app.color.reader_text_primary_eye_comfort') :
                        $r('app.color.reader_text_primary_light')))
                  Text($r('app.string.reader_vp_unit'))
                    .fontSize($r('app.float.product_caption_size'))
                    .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ?
                        $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light')))
                }
                .id('reader-page-margin-current')
                .width($r('app.float.product_target_min'))
                .justifyContent(FlexAlign.Center)
                Button($r('app.string.reader_increase_glyph'))
                  .id('reader-page-margin-increase')
                  .width($r('app.float.product_target_min'))
                  .height($r('app.float.product_target_min'))
                  .type(ButtonType.Normal)
                  .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                      $r('app.color.reader_accent_light')))
                  .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
                    (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
                      $r('app.color.reader_surface_light')))
                  .border({
                    width: 1,
                    color: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                      (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                        $r('app.color.reader_text_secondary_light'))
                  })
                  .borderRadius($r('app.float.product_radius_control'))
                  .accessibilityText($r('app.string.reader_page_margin_increase'))
                  .enabled(this.settings.pageMarginVp < 40)
                  .onClick((): void => this.updateLayoutSettings(this.changedSettings(
                    this.settings.fontScale, this.settings.lineSpacing,
                    Math.min(40, this.settings.pageMarginVp + 4), this.settings.theme)))
              }
              .width('100%')
              .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_4') })
              .backgroundColor(Color.Transparent)
              .borderRadius($r('app.float.product_radius_control'))

              Divider().color(this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
                  $r('app.color.reader_divider_light')))
              Text($r('app.string.reader_theme_section'))
                .fontSize($r('app.float.product_body_small_size'))
                .fontWeight(FontWeight.Medium)
                .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light')))
                .width('100%')
              Text(this.readerThemeStatus())
                .id('reader-theme-current')
                .fontSize($r('app.float.product_caption_size'))
                .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                    $r('app.color.reader_text_secondary_light')))
                .width('100%')
              Row({ space: $r('app.float.product_space_8') }) {
                this.readerThemeOption('system', 'reader-theme-system')
                this.readerThemeOption('light', 'reader-theme-light')
              }
              .width('100%')
              Row({ space: $r('app.float.product_space_8') }) {
                this.readerThemeOption('dark', 'reader-theme-dark')
                this.readerThemeOption('eye-comfort', 'reader-theme-eye-comfort')
              }
              .width('100%')
            }
            .width('100%')
            .padding({ bottom: $r('app.float.product_space_4') })
          }
          .layoutWeight(this.isSideReaderPanel() ? 0 : 1)
          .width('100%')
          .constraintSize({
            maxHeight: this.isSideReaderPanel() ?
              Math.max(120, this.readerViewportHeightVp() - 144) :
              $r('app.float.reader_transient_panel_height')
          })
        }
        .id('reader-appearance-panel')
        .width(this.isSideReaderPanel() ? 336 : '92%')
        .height(this.isSideReaderPanel() ?
          'auto' :
          $r('app.float.reader_transient_panel_height'))
        .constraintSize({
          maxWidth: $r('app.float.product_modal_max_width'),
          maxHeight: this.isSideReaderPanel() ?
            Math.max(240, this.readerViewportHeightVp() - 32) :
            $r('app.float.reader_transient_panel_height')
        })
        .padding($r('app.float.product_space_16'))
        .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
          (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
            $r('app.color.reader_surface_light')))
        .border({
          width: 1,
          color: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light'))
        })
        .borderRadius($r('app.float.product_radius_modal'))
        .transition(this.readerSurfaceTransition())
        .hitTestBehavior(HitTestMode.Default)
        .layoutGravity(this.isSideReaderPanel() ? LocalizedAlignment.TOP_END : LocalizedAlignment.CENTER)
        .margin({
          top: this.isSideReaderPanel() ? 16 : 0,
          right: this.isSideReaderPanel() ? 16 : 0
        })
      }

      if (this.currentSurface === 'none' && this.bookmarkMessage === '书签保存失败，请重试。') {
        Text(this.bookmarkMessage).id('reader-bookmark-error')
          .fontSize($r('app.float.product_label_size'))
          .fontColor($r('app.color.product_error'))
          .padding($r('app.float.product_space_12'))
          .backgroundColor($r('app.color.product_surface'))
          .borderRadius($r('app.float.product_radius_control'))
          .layoutGravity(LocalizedAlignment.TOP)
          .margin({ top: 72 })
          .onClick((): void => { this.bookmarkMessage = ''; })
      }

      if (this.currentSurface === 'none' && this.adjustingMarkId.length > 0) {
        Row({ space: $r('app.float.product_space_8') }) {
          Text('长按选出新范围，再点 ✓ 保存')
            .fontSize($r('app.float.product_label_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              $r('app.color.reader_text_primary_light'))
            .layoutWeight(1)
          Button('取消').id('reader-mark-adjust-cancel')
            .height($r('app.float.product_target_min'))
            .backgroundColor(Color.Transparent)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
              $r('app.color.reader_accent_light'))
            .onClick((): void => { this.adjustingMarkId = ''; })
        }.id('reader-mark-adjust-hint')
          .padding({ left: $r('app.float.product_space_12'), right: $r('app.float.product_space_8') })
          .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            $r('app.color.reader_surface_light'))
          .borderRadius($r('app.float.product_radius_control'))
          .layoutGravity(LocalizedAlignment.BOTTOM)
          .margin({ bottom: 80 })
      }

      if (this.errorText.length > 0) {
        Text(this.errorText)
          .id(this.navigationError ? 'reader-navigation-error' : 'reader-fatal-error')
          .fontSize($r('app.float.product_label_size'))
          .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
              $r('app.color.reader_error_light')))
          .padding($r('app.float.product_space_12'))
          .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_error_container_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_container_eye_comfort') :
              $r('app.color.reader_error_container_light')))
          .borderRadius($r('app.float.product_radius_control'))
          .transition(this.readerSurfaceTransition())
          .align(Alignment.Center)
          .onClick((): void => {
            if (this.navigationError) {
              this.navigationError = false;
              this.errorText = '';
            }
          })
      }

      if (this.currentSurface === 'dictionary') {
        DictionarySheet({
          surfaceColor: this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
              $r('app.color.reader_surface_light')),
          surfaceMutedColor: this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
              $r('app.color.reader_surface_muted_light')),
          textPrimaryColor: this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
              $r('app.color.reader_text_primary_light')),
          textSecondaryColor: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
              $r('app.color.reader_text_secondary_light')),
          dividerColor: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')),
          accentColor: this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
              $r('app.color.reader_accent_light')),
          onAccentColor: this.settings.theme === 'dark' ? $r('app.color.reader_on_accent_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') :
              $r('app.color.reader_on_accent_light')),
          selectedColor: this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
              $r('app.color.reader_selected_light')),
          errorColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
              $r('app.color.reader_error_light')),
          errorContainerColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_container_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_container_eye_comfort') :
              $r('app.color.reader_error_container_light')),
          selectedForm: this.dictionarySelectedForm,
          loading: this.dictionaryLoading,
          result: this.dictionaryResult,
          expanded: this.dictionaryExpanded,
          adjusting: this.adjustingMarkId.length > 0,
          darkTheme: this.settings.theme === 'dark',
          onCopy: (): void => { this.copySelectedWord().catch((): void => {}); },
          onHighlight: (): void => { this.requestWordTextMark('highlight'); },
          onNote: (): void => { this.requestWordTextMark('note'); },
          onSaveRange: (): void => { this.requestWordTextMark('adjust'); },
          onToggleExpanded: (): void => { this.dictionaryExpanded = !this.dictionaryExpanded; },
          onDismiss: (): void => { this.dismissDictionary(true); }
        }).width(this.dictionaryPlacement().width).height(this.dictionaryPlacement().height)
          .transition(this.readerSurfaceTransition())
          .position({ x: this.dictionaryPlacement().x, y: this.dictionaryPlacement().y })
      }

      if (this.currentSurface === 'passage') {
        PassageActionSheet({
          surfaceColor: this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
              $r('app.color.reader_surface_light')),
          textPrimaryColor: this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
              $r('app.color.reader_text_primary_light')),
          textSecondaryColor: this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
              $r('app.color.reader_text_secondary_light')),
          dividerColor: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')),
          accentColor: this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
              $r('app.color.reader_accent_light')),
          onAccentColor: this.settings.theme === 'dark' ? $r('app.color.reader_on_accent_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') :
              $r('app.color.reader_on_accent_light')),
          selectedColor: this.settings.theme === 'dark' ? $r('app.color.reader_selected_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_selected_eye_comfort') :
              $r('app.color.reader_selected_light')),
          errorColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
              $r('app.color.reader_error_light')),
          errorContainerColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_container_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_container_eye_comfort') :
              $r('app.color.reader_error_container_light')),
          candidate: this.passageCandidate,
          status: this.passageStatus,
          rejectedCharacterCount: this.passageRejectedCharacterCount,
          detail: this.passageDetail,
          adjusting: this.adjustingMarkId.length > 0,
          darkTheme: this.settings.theme === 'dark',
          onCopy: (): void => { this.requestPassageCopy(); },
          onHighlight: (): void => { this.requestTextMark('highlight'); },
          onNote: (): void => { this.requestTextMark('note'); },
          onSaveRange: (): void => { this.requestAdjustedMark(); },
          onDismiss: (): void => { this.dismissPassage(true); }
        }).width(this.passagePlacement().width).height(this.passagePlacement().height)
          .transition(this.readerSurfaceTransition())
          .position({ x: this.passagePlacement().x, y: this.passagePlacement().y })
      }

      if (this.currentSurface === 'mark-detail' || this.currentSurface === 'note-editor') {
        Column() {}
          .id('reader-mark-scrim')
          .width('100%').height('100%')
          .backgroundColor($r('app.color.product_scrim'))
          .hitTestBehavior(HitTestMode.Block)
          .onClick((): void => {
            if (this.currentSurface === 'mark-detail') this.closeMarkDetail();
            else if (this.currentSurface === 'note-editor') this.dismissNoteEditor(true);
          })
      }

      if (this.currentSurface === 'mark-detail' && this.selectedTextMark() !== undefined) {
        Column({ space: $r('app.float.product_space_8') }) {
          Row() {
            Text(this.selectedTextMark()?.kind === 'note' ? '笔记' : '高亮')
              .fontSize($r('app.float.product_surface_title_size')).fontWeight(FontWeight.Medium)
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
              .layoutWeight(1)
            Button() {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize($r('app.float.product_body_size'))
                .fontColor([this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                    $r('app.color.reader_text_secondary_light'))])
            }.id('reader-mark-detail-close')
              .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
              .type(ButtonType.Normal).backgroundColor(Color.Transparent)
              .borderRadius($r('app.float.product_radius_control'))
              .accessibilityText('关闭标记详情')
              .onClick((): void => this.closeMarkDetail())
          }.width('100%')
          Text(this.selectedTextMark()?.exactText ?? '')
            .fontSize($r('app.float.product_body_small_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                $r('app.color.reader_text_secondary_light')))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          if (this.orphanMarkIds.includes(this.selectedMarkId)) {
            Text('暂时无法跳转；原句和笔记仍保留。')
              .fontSize($r('app.float.product_caption_size'))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
                  $r('app.color.reader_error_light')))
          }
          if (this.selectedTextMark()?.kind === 'note') {
            Scroll() {
              Text(this.selectedTextMark()?.noteText ?? '')
                .fontSize($r('app.float.product_body_size'))
                .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                  (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                    $r('app.color.reader_text_primary_light')))
                .width('100%')
            }.height(82).width('100%').scrollBar(BarState.Auto)
          }
          Row({ space: $r('app.float.product_space_8') }) {
            Button(this.selectedTextMark()?.kind === 'note' ? '编辑笔记' : '改为笔记')
              .id('reader-mark-detail-edit').layoutWeight(1)
              .height($r('app.float.product_target_min'))
              .type(ButtonType.Normal)
              .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                  $r('app.color.reader_accent_light')))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_on_accent_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') :
                  $r('app.color.reader_on_accent_light')))
              .borderRadius($r('app.float.product_radius_control'))
              .onClick((): void => {
                const mark = this.selectedTextMark();
                if (mark !== undefined) this.beginEditMark(mark);
              })
            Button('调整范围').id('reader-mark-detail-adjust').layoutWeight(1)
              .height($r('app.float.product_target_min'))
              .type(ButtonType.Normal)
              .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
                  $r('app.color.reader_surface_muted_light')))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
              .borderRadius($r('app.float.product_radius_control'))
              .enabled(!this.orphanMarkIds.includes(this.selectedMarkId))
              .onClick((): void => {
                const mark = this.selectedTextMark();
                if (mark !== undefined) this.beginAdjustMark(mark);
              })
          }.width('100%')
          Button(this.selectedTextMark()?.kind === 'note' ? '删除笔记' : '取消高亮')
            .id('reader-mark-detail-delete').width('100%')
            .height($r('app.float.product_target_min'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') :
                $r('app.color.reader_error_light')))
            .type(ButtonType.Normal).borderRadius($r('app.float.product_radius_control'))
            .backgroundColor(Color.Transparent).enabled(!this.bookmarkBusy)
            .onClick((): void => {
              const mark = this.selectedTextMark();
              if (mark !== undefined) {
                this.removeTextMark(mark).catch((): void => {});
                this.closeMarkDetail();
              }
            })
        }.id('reader-mark-detail').width(this.markDetailPlacement().width)
          .padding($r('app.float.product_space_12'))
          .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
              $r('app.color.reader_surface_light')))
          .border({ width: 1, color: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')) })
          .borderRadius($r('app.float.product_radius_modal'))
          .position({ x: this.markDetailPlacement().x, y: this.markDetailPlacement().y })
      }

      if (this.currentSurface === 'note-editor') {
        Column({ space: $r('app.float.product_space_12') }) {
          Text(this.editingNoteMarkId.length > 0 ? '编辑笔记' : '写笔记')
            .fontSize($r('app.float.product_surface_title_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
          Text(this.editingNoteMarkId.length > 0 ?
            (this.savedTextMarks.find((mark: TextMarkRecord): boolean =>
              mark.markId === this.editingNoteMarkId)?.exactText ?? '') :
            (this.pendingNoteContext?.selectedText ?? ''))
            .fontSize($r('app.float.product_body_small_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                $r('app.color.reader_text_secondary_light')))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          TextArea({ placeholder: '写下你的想法', text: this.noteDraft })
            .id('reader-note-input').width('100%').height(140)
            .fontSize($r('app.float.product_body_size'))
            .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                $r('app.color.reader_text_primary_light')))
            .placeholderColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                $r('app.color.reader_text_secondary_light')))
            .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
                $r('app.color.reader_surface_muted_light')))
            .border({ width: 1, color: this.settings.theme === 'dark' ?
              $r('app.color.reader_text_secondary_dark') :
              (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') :
                $r('app.color.reader_text_secondary_light')) })
            .borderRadius($r('app.float.product_radius_control'))
            .onChange((value: string): void => { this.noteDraft = value.slice(0, 2000); })
          if (this.bookmarkMessage === '标记保存失败，请重试。') {
            Text(this.bookmarkMessage).fontSize($r('app.float.product_caption_size'))
          }
          Row({ space: $r('app.float.product_space_8') }) {
            Button('取消').id('reader-note-cancel').layoutWeight(1)
              .height($r('app.float.product_target_min'))
              .type(ButtonType.Normal)
              .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
                  $r('app.color.reader_surface_muted_light')))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') :
                  $r('app.color.reader_text_primary_light')))
              .borderRadius($r('app.float.product_radius_control'))
              .onClick((): void => this.dismissNoteEditor(true))
            Button('保存笔记').id('reader-note-save').layoutWeight(1)
              .height($r('app.float.product_target_min'))
              .type(ButtonType.Normal)
              .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') :
                  $r('app.color.reader_accent_light')))
              .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_on_accent_dark') :
                (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') :
                  $r('app.color.reader_on_accent_light')))
              .borderRadius($r('app.float.product_radius_control'))
              .enabled(this.noteDraft.trim().length > 0 && !this.bookmarkBusy)
              .onClick((): void => this.savePendingNote())
          }.width('100%')
        }.id('reader-note-editor').width(Math.min(340, Math.max(240, this.readerViewportWidthVp() - 24)))
          .padding($r('app.float.product_space_12'))
          .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') :
              $r('app.color.reader_surface_light')))
          .border({ width: 1, color: this.settings.theme === 'dark' ? $r('app.color.reader_divider_dark') :
            (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_divider_eye_comfort') :
              $r('app.color.reader_divider_light')) })
          .borderRadius($r('app.float.product_radius_modal'))
          .layoutGravity(LocalizedAlignment.CENTER)
      }

    }.width('100%').height('100%')
      .backgroundColor(this.settings.theme === 'dark' ? $r('app.color.reader_canvas_dark') :
        (this.settings.theme === 'eye-comfort' ? $r('app.color.reader_canvas_eye_comfort') :
          $r('app.color.reader_canvas_light')))
      .onAreaChange((_oldValue: Area, newValue: Area): void => {
        const width = this.areaLength(newValue.width);
        const height = this.areaLength(newValue.height);
        const viewportChanged = (width > 0 && width !== this.readerSurfaceWidth) ||
          (height > 0 && height !== this.readerSurfaceHeight);
        if (width > 0) this.readerSurfaceWidth = width;
        if (height > 0) this.readerSurfaceHeight = height;
        if (viewportChanged) {
          this.controller.applyColumnMode(adaptiveReaderColumnMode(this.windowSnapshot, this.settings.columnMode));
        }
      })

  }
}
