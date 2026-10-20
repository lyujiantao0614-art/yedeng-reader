import { common } from '@kit.AbilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { SelectionGestureTrace, NoteOverlayTraceEvent } from '../diagnostics/SelectionGestureTrace';
import { nativeMenuOptions, nativeAlertOptions, nativeSheetOptions, nativePromptDialogOptions } from '../platform/NativeOverlayMaterial';
import { CustomContentDialog, AlertDialog as NativeAlertDialog } from '@ohos.arkui.advanced.Dialog';
import { ReaderReadOnlyObservation, ReaderPageObservation } from '../reader/ReaderReadOnlyObservation';
import { KeyCode } from '@kit.InputKit';
import { window, FrameCallback, curves } from '@kit.ArkUI';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { uri } from '@kit.ArkTS';
import { ReaderErrorNotice } from '../components/ReaderErrorNotice';
import { DictionarySheet } from '../components/DictionarySheet';
import { PassageActionSheet, PassageActionSheetStatus } from '../components/PassageActionSheet';
import { DictionaryLookupResult } from '../dictionary/DictionaryModels';
import { DictionaryService } from '../dictionary/DictionaryService';
import { Book, BookmarkPoint, Chapter, DEFAULT_READER_SETTINGS, ReaderSettings, ReaderTheme, ReadingLocation, ReadingProgress, TextMarkRecord, NoteEntry, RangeAnchorStatus, WEB_READER_ENGINE_ID } from '../domain/Models';
import { BookmarkApplication } from '../application/BookmarkApplication';
import { TextMarkApplication } from '../application/TextMarkApplication';
import { bookmarkPointFromLocation } from '../domain/BookmarkPointPolicy';
import { ReaderThemePreference, BookLayoutOverrides, ReaderLayoutParameter, animateReaderMotion } from '../domain/AppearancePolicy';
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
  ReaderNoteAnchor,
  ReaderWordSelection
} from '../reader/ReaderEngine';
import { ReaderFourSurfaceView } from '../reader/ReaderFourSurfaceView';
import { validatedExternalLinkHost } from '../reader/ReaderNetworkPolicy';
import {
  ReaderPopupViewport,
  SelectionPopupPlacement,
  placeSelectionPopup
} from '../reader/SelectionPopupPlacementPolicy';
import { PassageSelectionCandidate, ReadingSelectionContext, VerifiedRangeMember } from '../reader/ReadingSelectionModels';
import {
  PassageRequestKind,
  ReaderSurface,
  shouldDismissTransientSurfaceForLocation
} from '../reader/ReaderSurfaceState';
import { ReaderAppearanceApplication } from '../application/ReaderAppearanceApplication';
import { ReaderSessionService } from '../services/ReaderSessionService';
import { SafeLog } from '../diagnostics/SafeLog';
import { readerOpenDiagnostics } from '../diagnostics/ReaderOpenDiagnostics';
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

interface NativeAdjustRequest {
  markId: string;
  revision: number;
  cfi: string;
  exactText: string;
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
    exactText: record.exactText, prefix: record.prefix, suffix: record.suffix,
    quoteScope: record.quoteScope, revision: record.revision, highlightActive: record.highlightActive,
    noteAnchors: (record.notes ?? []).map((note: NoteEntry): ReaderNoteAnchor => ({noteId: note.noteId,revision: note.revision,provenance: note.anchorProvenance,
      resourceHref: note.originalAnchor.resourceHref,cfi: note.originalAnchor.cfi,exactText: note.originalAnchor.exactText,
      prefix: note.originalAnchor.prefix,suffix: note.originalAnchor.suffix,quoteScope: note.originalAnchor.quoteScope})),
    highlightAnchors: record.highlightAnchors ?? [] };
}

function noteTimestamp(value: number): string {
  const date = new Date(value);
  return date.getFullYear() + '-' + String(date.getMonth() + 1).padStart(2, '0') + '-' +
    String(date.getDate()).padStart(2, '0') + ' ' + String(date.getHours()).padStart(2, '0') + ':' +
    String(date.getMinutes()).padStart(2, '0');
}

function noteTime(note: NoteEntry): string {
  return note.updatedAt === note.createdAt ? '创建于 ' + noteTimestamp(note.createdAt) : '编辑于 ' + noteTimestamp(note.updatedAt);
}

function copyEditingNote(note: NoteEntry): NoteEntry {
  const anchor = note.originalAnchor;
  return { noteId: note.noteId, bookId: note.bookId, rangeId: note.rangeId, body: note.body,
    createdAt: note.createdAt, updatedAt: note.updatedAt, revision: note.revision,
    anchorProvenance: note.anchorProvenance, anchorStatus: note.anchorStatus,
    originalAnchor: { anchorVersion: anchor.anchorVersion, engine: anchor.engine,
      resourceHref: anchor.resourceHref, cfi: anchor.cfi, exactText: anchor.exactText,
      prefix: anchor.prefix, suffix: anchor.suffix, quoteScope: anchor.quoteScope } };
}

export interface ReaderPageSession {
  sessionId: number;
  book: Book;
  initialProgress?: ReadingProgress;
  initialBookmark?: BookmarkPoint;
  initialSettings: ReaderSettings;
}

export class ReaderPageController {
  readonly readOnlyObservation?: ReaderReadOnlyObservation;
  constructor(observation?: ReaderReadOnlyObservation) { this.readOnlyObservation = observation; }
  private systemBackHandler?: () => void;
  private sessionHandler?: (session: ReaderPageSession) => void;
  private pendingSession?: ReaderPageSession;
  private preferenceHandler?: () => void;
  private settingsCoverHandler?: (covered: boolean) => Promise<void>;

  bindConfirmedPreferences(handler: () => void): void { this.preferenceHandler = handler; }
  unbindConfirmedPreferences(): void { this.preferenceHandler = undefined; }
  syncConfirmedPreferences(): void { this.preferenceHandler?.(); }
  bindSettingsCover(handler: (covered: boolean) => Promise<void>): void { this.settingsCoverHandler = handler; }
  unbindSettingsCover(): void { this.settingsCoverHandler = undefined; }
  setSettingsCovered(covered: boolean): Promise<void> {
    return this.settingsCoverHandler?.(covered) ?? Promise.resolve();
  }

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

// Focus the newly returned row after native layout, not while its tree is being built.
class ReaderRowFocusFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_timeLeftInNano: number): void { this.action(); }
}

@Component
export struct ReaderPage {
  @Prop panelMaterial: SystemUiMaterial | undefined = undefined;
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  @Prop @Watch('syncReaderOverlays') windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  book: Book = EMPTY_BOOK;
  initialProgress?: ReadingProgress;
  initialSettings: ReaderSettings = DEFAULT_READER_SETTINGS;
  sessionId: number = 0;
  debugClipPaginationOverride?: boolean;
  appearanceApplication?: ReaderAppearanceApplication;
  bookmarks?: BookmarkApplication;
  textMarks?: TextMarkApplication;
  session: ReaderSessionService = new ReaderSessionService();
  dictionaryService?: DictionaryService;
  pageController: ReaderPageController = new ReaderPageController();
  onExit: () => void = (): void => {};
  onOpenReadingSettings: () => void = (): void => {};
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
  @State @Watch('syncReaderOverlays') private currentSurface: ReaderSurface = 'none';
  @State private chapters: Chapter[] = [];
  @State private location?: ReadingLocation = undefined;
  @State private bookmarkPoints: BookmarkPoint[] = [];
  @State private savedTextMarks: TextMarkRecord[] = [];
  @State private orphanMarkIds: string[] = [];
  @State private selectedMarkId: string = '';
  @State private selectedMarkRect?: ReaderSelectionRect = undefined;
  @State private adjustingMarkId: string = '';
  private wordMarkRequest: 'none' | 'highlight' | 'note' | 'adjust' = 'none';
  private nativeNoteToken: string = '';
  private nativeAdjustRequest?: NativeAdjustRequest;
  private nativeTranslationResult: boolean = false;
  private nativeCopyPending: boolean = false;
  private editingNoteMarkId: string = '';
  private editingNoteEntryId: string = '';
  @State private readerSheetVisible: boolean = false;
  @State private readerSheetSurface: ReaderSurface = 'none';
  @State private readerSheetPresented: boolean = false;
  private tocInitialOffset: number = 0;
  private notesInitialOffset: number = 0;
  private notesScroller: Scroller = new Scroller();
  @State private noteKeyboardVisible: boolean = false;
  @State private noteSheetDetent: SheetSize = SheetSize.MEDIUM;
  private noteSheetAutoExpanded: boolean = false;
  private noteKeyboardWindow?: window.Window;
  private noteKeyboardDisposed: boolean = false;
  private noteKeyboardChanged = (height: number): void => {
    const visible = height > 0;
    if (visible && !this.noteKeyboardVisible && this.readerSheetSurface === 'note-editor') {
      this.noteSheetAutoExpanded = this.noteSheetDetent === SheetSize.MEDIUM;
    }
    this.noteKeyboardVisible = visible;
  };
  @State private noteQuoteExpanded: boolean = false;
  @State private noteDraft: string = '';
  @State private noteFeedback: string = '';
  @State private noteCommitKind: 'none' | 'saved' | 'deleted' = 'none';
  private editingNoteSnapshot?: NoteEntry;
  private editingRangeSnapshot?: TextMarkRecord;
  private noteDraftBaseline: string = '';
  private noteOriginalQuote: string = '';
  private noteEditorGeneration: number = 0;
  private confirmingNoteDiscard: boolean = false;
  private noteDiscardResult?: (index: number) => void;
  private noteReturnSurface: ReaderSurface = 'none';
  private noteReturnRowId: string = '';
  private markDetailReturnSurface: ReaderSurface = 'none';
  private markDetailReturnRowId: string = '';
  private pendingNoteFocusKey: string = '';
  private noteFocusRequested: boolean = false;
  private textMarkRefreshRevision: number = 0;
  private pendingNoteContext?: ReadingSelectionContext;
  private pendingMarkId: string = '';
  private currentPageExcerpt: string = '';
  @State private bookmarkReady: boolean = false;
  @State private bookmarkBusy: boolean = false;
  @State private bookmarkMessage: string = '';
  private bookmarkToastId?: number = undefined;
  private bookmarkToastRequest: number = 0;
  @State private bookmarkTab: 'contents' | 'bookmarks' = 'contents';
  private pendingInitialBookmark?: BookmarkPoint;
  private pendingBookmarkId: string = '';
  @State private settings: ReaderSettings = DEFAULT_READER_SETTINGS;
  private noteDiscardDialog: CustomDialogController = new CustomDialogController({
    builder: NativeAlertDialog({ primaryTitle: '放弃未保存的修改？',
      content: '该条笔记已保存内容和原始引用不会改变。',
      themeColorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
      theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
        fontSecondary: this.shellColor('secondary'), backgroundPrimary: this.shellColor('surface') } },
      primaryButton: { value: '继续编辑', fontColor: this.shellColor('accent'), action: (): void => this.resolveNoteDiscard(0) },
      secondaryButton: { value: '放弃修改', role: ButtonRole.ERROR,
        fontColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
          this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') : $r('app.color.reader_error_light'),
        action: (): void => this.resolveNoteDiscard(1) }
    }),
    autoCancel: true, customStyle: false, backgroundBlurStyle: BlurStyle.NONE,
    onWillDismiss: (action: DismissDialogAction): void => { action.dismiss(); this.resolveNoteDiscard(0); }
  });
  private ordinaryNoteDiscardDialog: CustomDialogController = this.noteDiscardDialog;

  private openNoteDiscardDialog(): void {
    this.noteDiscardDialog = this.ordinaryNoteDiscardDialog;
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined && this.settings.theme !== 'eye-comfort') {
          this.noteDiscardDialog = new CustomDialogController({
            systemMaterial: this.panelMaterial,
            builder: NativeAlertDialog({ primaryTitle: '放弃未保存的修改？',
              content: '该条笔记已保存内容和原始引用不会改变。',
              themeColorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
              theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
                fontSecondary: this.shellColor('secondary'), backgroundPrimary: this.shellColor('surface') } },
              primaryButton: { value: '继续编辑', fontColor: this.shellColor('accent'), action: (): void => this.resolveNoteDiscard(0) },
              secondaryButton: { value: '放弃修改', role: ButtonRole.ERROR,
                fontColor: this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') : $r('app.color.reader_error_light'),
                action: (): void => this.resolveNoteDiscard(1) }
            }),
            autoCancel: true, customStyle: false, backgroundBlurStyle: BlurStyle.NONE,
            onWillDismiss: (action: DismissDialogAction): void => { action.dismiss(); this.resolveNoteDiscard(0); }
          });
        }
      }
    }
    this.noteDiscardDialog.open();
  }
  private markDetailDialogVisible: boolean = false;
  @State private markDetailPresented: boolean = false;
  private markDetailReady: boolean = false;
  private markDetailDidAppear(): void {
    this.markDetailReady = true;
    this.traceNoteOverlay('detail-open');
    if (this.pendingNoteFocusKey) this.restoreNoteRowFocus(this.pendingNoteFocusKey);
  }
  private markDetailDidDisappear(): void {
    this.markDetailPresented = false; this.markDetailReady = false;
    this.traceNoteOverlay('detail-closed');
    if (this.currentSurface !== 'mark-detail' && this.currentSurface !== 'note-editor') {
      this.selectedMarkId = ''; this.selectedMarkRect = undefined;
    }
    this.syncReaderOverlays();
    if (this.pendingNoteFocusKey) this.restoreNoteRowFocus(this.pendingNoteFocusKey);
    else if (this.currentSurface === 'none' && !this.exiting) this.controller.focusContent();
  }
  private markDetailDialog: CustomDialogController = this.createMarkDetailDialog();
  // ArkUI requires literal Dialog options to transform its component builder.
  private createMarkDetailDialog(): CustomDialogController {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined && this.settings.theme !== 'eye-comfort') {
          return new CustomDialogController({
            systemMaterial: this.panelMaterial,
            builder: CustomContentDialog({
              contentBuilder: (): void => this.markDetailContent(),
              themeColorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
              theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
                fontSecondary: this.shellColor('secondary'), backgroundPrimary: Color.Transparent,
                compBackgroundPrimary: Color.Transparent } }
            }),
            customStyle: false, autoCancel: true,
            onDidAppear: (): void => this.markDetailDidAppear(),
            onDidDisappear: (): void => this.markDetailDidDisappear(),
            onWillDismiss: (action: DismissDialogAction): void => {
              if (this.bookmarkBusy) return;
              this.markDetailDialogVisible = false;
              action.dismiss();
              if (this.currentSurface === 'mark-detail') this.closeMarkDetail();
            }
          });
        }
      }
    }
    return new CustomDialogController({
      builder: CustomContentDialog({
        contentBuilder: (): void => this.markDetailContent(),
        themeColorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
        theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
          fontSecondary: this.shellColor('secondary'), backgroundPrimary: this.shellColor('surface') } }
      }),
      customStyle: false, autoCancel: true,
      onDidAppear: (): void => this.markDetailDidAppear(),
      onDidDisappear: (): void => this.markDetailDidDisappear(),
      onWillDismiss: (action: DismissDialogAction): void => {
        if (this.bookmarkBusy) return;
        this.markDetailDialogVisible = false;
        action.dismiss();
        if (this.currentSurface === 'mark-detail') this.closeMarkDetail();
      }
    });
  }
  @State private selectedThemePreference: ReaderThemePreference = 'system';
  @State private animateCustomMotion: boolean = true;
  @State private showControlsButton: boolean = false;
  @State private hideControlsButton: boolean = false;
  @State private settingsCovered: boolean = false;
  private settingsFocusPending: boolean = false;
  @State private errorText: string = '';
  @State private navigationError: boolean = false;
  @State private appearanceMessage: string = '';
  @State private bookLayoutOverrides: BookLayoutOverrides = {};
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
  private unsubscribeSystemMotion?: () => void;
  private systemReducedMotion: boolean | undefined = undefined;
  private unsubscribeApplicationLifecycle?: () => void;
  private systemBarUpdate: Promise<void> = Promise.resolve();
  private panelFocusReturn: string = '';
  private panelTrigger: string = '';
  private panelFocusSession: number = 0;
  aboutToAppear(): void {
    this.noteKeyboardDisposed = false;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(context).then((mainWindow: window.Window): void => {
      if (this.noteKeyboardDisposed) return;
      this.noteKeyboardWindow = mainWindow;
      mainWindow.on('keyboardHeightChange', this.noteKeyboardChanged);
    }).catch((): void => {});
    readerOpenDiagnostics.mark(this.sessionId, 'host_created');
    this.pageController.readOnlyObservation?.bindPage((): ReaderPageObservation => this.readOnlyPageObservation());
    const lifecycleHandler: ReaderApplicationLifecycleHandler =
      new ReaderPageLifecycleHandler((): void => this.handleApplicationBackground());
    this.unsubscribeApplicationLifecycle = readerApplicationLifecycle.subscribe(lifecycleHandler);
    this.pageController.bindSystemBack((): void => this.handleSystemBack());
    this.pageController.bindConfirmedPreferences((): void => this.syncConfirmedPreferences());
    this.pageController.bindSettingsCover((covered: boolean): Promise<void> => this.setSettingsCovered(covered));
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
    this.noteKeyboardDisposed = true;
    this.noteKeyboardWindow?.off('keyboardHeightChange', this.noteKeyboardChanged);
    this.noteKeyboardWindow = undefined;
    this.resolveNoteDiscard(0);
    this.pageController.readOnlyObservation?.unbindPage();
    this.unsubscribeApplicationLifecycle?.();
    this.unsubscribeApplicationLifecycle = undefined;
    const restore = this.onRestoreShellBars;
    if (restore === undefined) this.updateSystemBars();
    else this.systemBarUpdate = this.systemBarUpdate.then(restore).catch((): void => {});
    this.invalidateTransientState(false);
    this.pageController.unbindSystemBack();
    this.pageController.unbindSession();
    this.pageController.unbindConfirmedPreferences();
    this.pageController.unbindSettingsCover();
    this.unsubscribeSystemColorMode?.();
    this.unsubscribeSystemColorMode = undefined;
    this.unsubscribeSystemMotion?.(); this.unsubscribeSystemMotion = undefined;
    this.dictionaryService?.cancelPending();
    this.exitLocationResolver?.();
  }

  private activateSession(session: ReaderPageSession): void {
    const reloadWebPage = this.hasReaderSession;
    if (this.hasReaderSession) this.invalidateTransientState(false);
    this.hasReaderSession = true;
    this.currentSessionId = session.sessionId;
    readerOpenDiagnostics.mark(session.sessionId, 'controller_attached');
    this.nativeCopyPending = false; this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined; this.nativeTranslationResult = false;
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
    this.editingNoteEntryId = '';
    this.editingNoteSnapshot = undefined;
    this.editingRangeSnapshot = undefined;
    this.noteFeedback = '';
    this.noteCommitKind = 'none';
    this.noteDraftBaseline = '';
    this.noteOriginalQuote = '';
    this.noteQuoteExpanded = false;
    this.noteEditorGeneration += 1;
    this.confirmingNoteDiscard = false;
    this.noteReturnSurface = 'none';
    this.noteReturnRowId = '';
    this.pendingNoteFocusKey = '';
    this.noteFocusRequested = false;
    this.textMarkRefreshRevision += 1;
    this.markDetailReturnSurface = 'none'; this.markDetailReturnRowId = '';
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
    if (this.unsubscribeSystemMotion === undefined) {
      this.unsubscribeSystemMotion = this.appearanceApplication?.subscribeSystemMotion((reduced: boolean | undefined): void => {
        this.systemReducedMotion = reduced; this.animateCustomMotion = animateReaderMotion(reduced);
      });
    }
    this.animateCustomMotion = animateReaderMotion(this.systemReducedMotion);
    this.showControlsButton = this.appearanceApplication?.showControlsButton() ?? false;
    this.hideControlsButton = this.appearanceApplication?.hideControlsButton() ?? false;
    this.settingsCovered = false; this.settingsFocusPending = false;
    this.settings = this.appearanceApplication?.loadSettings(session.book.bookId) ?? session.initialSettings;
    this.bookLayoutOverrides = this.appearanceApplication?.bookLayoutOverrides(session.book.bookId) ?? {};
    this.controlsVisible = true;
    this.panelFocusReturn = ''; this.panelTrigger = ''; this.panelFocusSession = 0;
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
    // A submitted adjustment cannot be cancelled by hiding its UI while the real transaction resolves.
    if (this.adjustingMarkId.length > 0 && this.bookmarkBusy) return;
    if (this.currentSurface === 'mark-detail') {
      this.closeMarkDetail();
      return;
    }
    if (this.currentSurface === 'note-editor') {
      this.requestCloseNoteEditor();
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
    if (this.isAuxiliaryPanel()) {
      this.dismissReaderPanel(true);
      return;
    }
    if (this.hasUncommittedSelection) {
      this.clearUncommittedSelection();
      return;
    }
    if (this.adjustingMarkId.length > 0) {
      this.cancelAdjustMark(); return;
    }
    if (this.linkState.canReturn) {
      this.controller.returnFromInternalLink();
      return;
    }
    this.exitReader();
  }

  private async copyNativeSelection(text: string, complete?: () => void): Promise<void> {
    if (this.nativeCopyPending) return;
    const sessionId = this.currentSessionId;
    this.nativeCopyPending = true;
    try {
      await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text));
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.nativeCopyPending = false;
        try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '复制失败，请保留选区后重试。' }); } catch (_) {}
      }
      return;
    }
    if (sessionId !== this.currentSessionId) return;
    this.nativeCopyPending = false;
    // The clipboard write succeeded. A presentation/focus/toast failure cannot reclassify it.
    try { complete?.(); } catch (_) {}
    try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '已复制所选文字。' }); } catch (_) {}
  }

  private nativeSelectionAction(action: 'copy' | 'note' | 'translate', token: string,
    selectedText: string, locator: string, complete?: () => void): void {
    if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
    if (action === 'copy') { this.copyNativeSelection(selectedText, complete).catch((): void => {}); return; }
    if (action === 'note') {
      if (this.bookmarkBusy) return;
      this.nativeNoteToken = token;
      const adjusting = this.savedTextMarks.find((mark: TextMarkRecord): boolean => mark.markId === this.adjustingMarkId);
      this.nativeAdjustRequest = undefined;
      if (this.adjustingMarkId.length > 0) {
        if (!adjusting) {
          this.nativeNoteToken = '';
          try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '原标记已变化，请点按原标记重新调整。' }); } catch (_) {}
          return;
        }
        this.nativeAdjustRequest = { markId: adjusting.markId, revision: adjusting.revision ?? 1,
          cfi: adjusting.cfi, exactText: adjusting.exactText };
      }
      this.controller.requestSelectionContext(token, this.currentSessionId,
        this.savedTextMarks.filter((mark: TextMarkRecord): boolean =>
          this.nativeAdjustRequest !== undefined ? mark.kind === adjusting?.kind : mark.kind === 'note')
          .map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)),
        this.nativeAdjustRequest?.markId);
      return;
    }
    this.nativeTranslationResult = true;
    this.lookupSelection({ engine: WEB_READER_ENGINE_ID, selectionToken: token,
      characterCount: selectedText.length, surfaceForm: selectedText, locator: locator }).catch((): void => {
        if (this.currentSurface === 'dictionary') {
          this.dictionaryLoading = false;
          this.dictionaryResult = { status: 'unavailable', selectedForm: selectedText, entries: [] };
        }
      });
    // The dictionary result owns its native layer after lookup starts; it is not a live-selection toolbar.
    this.controller.clearSelection();
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

  private usesAuxiliaryPanelMotion(): boolean {
    return (this.currentSurface === 'toc' || this.currentSurface === 'notes' || this.currentSurface === 'appearance') &&
      !this.isSideReaderPanel() && this.animateCustomMotion;
  }

  private auxiliaryPanelTransition(): TransitionEffect {
    if (!this.usesAuxiliaryPanelMotion()) {
      return this.readerSurfaceTransition();
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.move(TransitionEdge.BOTTOM).animation({ curve: curves.springMotion(0.32, 1) }),
      TransitionEffect.move(TransitionEdge.BOTTOM).animation({ duration: 200, curve: Curve.EaseIn })
    );
  }

  private auxiliaryScrimTransition(): TransitionEffect {
    if (!this.usesAuxiliaryPanelMotion()) {
      return TransitionEffect.IDENTITY;
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ curve: curves.springMotion(0.32, 1) }),
      TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseIn })
    );
  }

  private async systemBarColor(resource: Resource, context: common.UIAbilityContext): Promise<string> {
    try {
      const rgb = await context.resourceManager.getColor(resource.id) & 0xFFFFFF;
      return '#' + ('000000' + rgb.toString(16)).slice(-6).toUpperCase();
    } catch (error) { throw error instanceof Error ? error : new Error('Reader system bar color unavailable'); }
  }

  private updateSystemBars(theme?: ReaderTheme): void {
    if (this.settingsCovered) return;
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
      if (this.settingsCovered) return;
      const barColor = theme === undefined ? (productDark ? '#1C2933' : '#E0E5E5') :
        await this.systemBarColor(background, context);
      const contentColor = theme === undefined ? (productDark ? '#EAE9E3' : '#243139') :
        await this.systemBarColor(foreground, context);
      const mainWindow = await window.getLastWindow(context);
      if (this.settingsCovered) return;
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
    if (!visible) this.controller.focusContent();
    this.onControlsVisibilityChange(visible);
    this.updateSystemBars(this.settings.theme);
  }

  private isAuxiliaryPanel(): boolean {
    return this.currentSurface === 'toc' || this.currentSurface === 'appearance' ||
      this.currentSurface === 'notes' || this.currentSurface === 'bookmarks' || this.currentSurface === 'progress';
  }
  private isNativeReaderSheet(surface: ReaderSurface): boolean {
    return surface === 'note-editor' || surface === 'dictionary' || surface === 'bookmarks' ||
      surface === 'progress' || ((surface === 'toc' || surface === 'notes' || surface === 'appearance') && !this.isSideReaderPanel());
  }
  private openAuxiliaryPanel(surface: ReaderSurface, trigger: string): void {
    this.dismissSelectionSurfaces(true);
    this.panelTrigger = trigger; this.panelFocusSession = this.currentSessionId;
    if (surface === 'toc' && !this.isSideReaderPanel()) this.prepareTocInitialOffset();
    if (surface === 'notes') this.notesInitialOffset = 0;
    this.currentSurface = surface;
    if (surface === 'notes' && !this.bookmarkBusy) {
      const sessionId = this.currentSessionId;
      this.bookmarkBusy = true;
      this.reloadTextMarks(sessionId).catch((): void => {
        if (sessionId === this.currentSessionId) this.bookmarkMessage = '标记读取失败，现有记录已保留，请重新打开列表。';
      }).finally((): void => { if (sessionId === this.currentSessionId) this.bookmarkBusy = false; });
    }
  }
  private dismissReaderPanel(returnFocus: boolean = false): void {
    if (!this.isAuxiliaryPanel()) return;
    this.currentSurface = 'none';
    if (returnFocus && this.panelFocusSession === this.currentSessionId) {
      if (this.controlsVisible) this.panelFocusReturn = this.panelTrigger;
      else this.controller.focusContent();
    }
  }
  private restorePanelFocus(id: string): void {
    if (this.panelFocusReturn !== id || this.panelFocusSession !== this.currentSessionId) return;
    try { this.getUIContext().getFocusController().requestFocus(id); } catch (_) {}
  }
  private panelTitle(): string {
    if (this.currentSurface === 'toc') return '目录';
    if (this.currentSurface === 'appearance') return '外观';
    if (this.currentSurface === 'notes') return '笔记与独立高亮';
    if (this.currentSurface === 'bookmarks') return '书签';
    return '阅读进度';
  }
  private panelWidth(): number { return Math.min(this.isSideReaderPanel() ? 440 : 640, Math.max(0, this.readerViewportWidthVp())); }
  private panelHeight(): number { return Math.max(0, this.readerViewportHeightVp() * (this.isSideReaderPanel() ? 1 : 0.84)); }
  private shellColor(role: 'text' | 'secondary' | 'surface' | 'accent'): Resource {
    if (role === 'text') return this.settings.theme === 'dark' ? $r('app.color.reader_text_primary_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_primary_eye_comfort') : $r('app.color.reader_text_primary_light');
    if (role === 'secondary') return this.settings.theme === 'dark' ? $r('app.color.reader_text_secondary_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_text_secondary_eye_comfort') : $r('app.color.reader_text_secondary_light');
    if (role === 'accent') return this.settings.theme === 'dark' ? $r('app.color.reader_accent_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_accent_eye_comfort') : $r('app.color.reader_accent_light');
    return this.settings.theme === 'dark' ? $r('app.color.reader_surface_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_eye_comfort') : $r('app.color.reader_surface_light');
  }

  private dismissDictionary(clearSelection: boolean): void {
    this.selectionUiGeneration += 1;
    this.dictionaryService?.cancelPending();
    if (this.currentSurface === 'dictionary') this.currentSurface = 'none';
    // Native content remains intact until onDisappear, just like the accepted editor/detail handoff.
    if (this.readerSheetSurface !== 'dictionary') this.clearDictionaryPresentation();
    this.nativeTranslationResult = false;
    this.pendingWordContextToken = '';
    this.wordMarkRequest = 'none';
    if (clearSelection) {
      this.adjustingMarkId = '';
      this.clearUncommittedSelection();
    }
  }

  private clearDictionaryPresentation(): void {
    this.dictionaryLoading = false;
    this.dictionaryExpanded = false;
    this.dictionarySelectedForm = '';
    this.dictionaryResult = undefined;
    this.dictionarySelection = undefined;
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
    this.noteQuoteExpanded = false;
    this.noteEditorGeneration += 1;
    this.confirmingNoteDiscard = false;
    this.pendingNoteContext = undefined;
    this.noteDraft = '';
    this.noteDraftBaseline = '';
    this.noteOriginalQuote = '';
    this.noteFeedback = '';
    this.noteCommitKind = 'none';
    this.editingNoteMarkId = '';
    this.editingNoteEntryId = '';
    this.editingNoteSnapshot = undefined;
    this.editingRangeSnapshot = undefined;
    this.noteReturnSurface = 'none';
    this.noteReturnRowId = '';
    if (clearSelection) this.clearUncommittedSelection();
  }

  private finishNoteEditor(): void {
    const surface = this.noteReturnSurface;
    const rowId = this.noteReturnRowId;
    const noteId = this.editingNoteEntryId;
    const refreshFailed = this.noteCommitKind !== 'none' && this.noteFeedback.length > 0;
    const committedFeedback = this.noteFeedback;
    const mark = this.savedTextMarks.find((item: TextMarkRecord): boolean =>
      (item.notes ?? []).some((note: NoteEntry): boolean => note.noteId === noteId));
    this.dismissNoteEditor(true);
    if (refreshFailed) {
      this.currentSurface = 'none'; this.selectedMarkId = ''; this.pendingNoteFocusKey = '';
      this.controller.focusContent();
      try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: committedFeedback }); } catch (_) {}
      return;
    }
    if (surface !== 'none' && (surface !== 'mark-detail' || mark !== undefined || this.selectedTextMark() !== undefined)) {
      if (surface === 'mark-detail' && mark !== undefined) this.selectedMarkId = mark.markId;
      this.currentSurface = surface;
      this.pendingNoteFocusKey = rowId;
      this.noteFocusRequested = false;
      if (!rowId) this.controller.focusContent();
    } else {
      this.pendingNoteFocusKey = '';
      this.controller.focusContent();
    }
  }

  private traceNoteOverlay(event: NoteOverlayTraceEvent, count: number = this.savedTextMarks.length,
    found: boolean = this.selectedTextMark() !== undefined): void {
    SelectionGestureTrace.noteOverlay(event, ['none', 'notes', 'mark-detail', 'note-editor'].indexOf(this.currentSurface), count, found);
  }

  private requestNoteFocus(key: string): void {
    if (key === 'reader-note-input') {
      if (!this.readerSheetPresented || this.currentSurface !== 'note-editor') return;
    } else if (!this.noteReturnFocusReady()) {
      this.noteFocusRequested = false;
      return;
    }
    try { this.getUIContext().getFocusController().requestFocus(key); }
    catch (error) {
      this.traceNoteOverlay('focus-reject', key === 'reader-note-input' ? 1 : key.startsWith('reader-record-') ? 2 : 3);
      const code = (error as BusinessError).code;
      const name = (error as Error).name;
      const message = typeof error === 'string' ? error : (error as Error).message;
      this.pageController.readOnlyObservation?.focusObserved(typeof error === 'string' ? 'request-string' : 'request-object');
      this.pageController.readOnlyObservation?.focusObserved(typeof message === 'string' && /focusable ancestor/i.test(message) ? 'request-message-ancestor' :
        typeof message === 'string' && /not on tree|does not exist|not found/i.test(message) ? 'request-message-missing' :
        typeof message === 'string' && /cannot be focused|not focusable/i.test(message) ? 'request-message-self' : 'request-message-other');
      this.pageController.readOnlyObservation?.focusObserved(name === 'TypeError' ? 'request-type-error' :
        name === 'BusinessError' ? 'request-business-error' : name === 'Error' ? 'request-error' : 'request-name-other');
      if (Number.isSafeInteger(code) && Math.abs(code) <= 2147483647)
        this.pageController.readOnlyObservation?.focusObserved('request-code-' + code.toString());
      this.pageController.readOnlyObservation?.focusObserved(code === 150001 ? 'request-rejected-self' :
        code === 150002 ? 'request-rejected-ancestor' : code === 150003 ? 'request-rejected-missing' : 'request-rejected-other');
      this.noteFocusRequested = false;
      // Focus delivery is not a storage/list refresh error. Keep its diagnostic separate.
    }
  }

  private noteReturnFocusReady(): boolean {
    if (this.currentSurface === 'notes' && this.isNativeReaderSheet('notes')) {
      return this.readerSheetPresented && this.readerSheetVisible && this.readerSheetSurface === 'notes' && !this.markDetailPresented;
    }
    return !this.readerSheetPresented && (this.currentSurface === 'mark-detail' ? this.markDetailReady : !this.markDetailPresented);
  }

  private restoreNoteRowFocus(rowId: string, areaReady: boolean = false): void {
    if (this.pendingNoteFocusKey !== rowId || this.currentSurface === 'note-editor' || this.noteFocusRequested) return;
    if (!this.noteReturnFocusReady()) return;
    const sessionId = this.currentSessionId;
    const ui = this.getUIContext();
    this.noteFocusRequested = true;
    ui.postFrameCallback(new ReaderRowFocusFrame((): void => {
      if (sessionId !== this.currentSessionId || this.pendingNoteFocusKey !== rowId || this.currentSurface === 'note-editor') return;
      ui.runScopedTask((): void => this.requestNoteFocus(rowId));
    }));
  }

  private resolveNoteDiscard(index: number): void {
    const resolve = this.noteDiscardResult;
    if (resolve === undefined) return;
    this.noteDiscardResult = undefined;
    this.noteDiscardDialog.close(); resolve(index);
  }

  private requestCloseNoteEditor(afterClose?: () => void): void {
    if (this.currentSurface !== 'note-editor' || this.bookmarkBusy || this.confirmingNoteDiscard) return;
    if (this.noteCommitKind !== 'none' || this.noteDraft === this.noteDraftBaseline) {
      this.finishNoteEditor(); afterClose?.(); return;
    }
    const sessionId = this.currentSessionId;
    const generation = this.noteEditorGeneration;
    this.confirmingNoteDiscard = true;
    new Promise<number>((resolve): void => { this.noteDiscardResult = resolve; this.openNoteDiscardDialog(); })
      .then((index: number): void => {
        if (sessionId !== this.currentSessionId || generation !== this.noteEditorGeneration || this.currentSurface !== 'note-editor') return;
        this.confirmingNoteDiscard = false;
        if (index === 1) { this.finishNoteEditor(); afterClose?.(); }
        else this.requestNoteFocus('reader-note-input');
      }).catch((): void => {
        this.noteDiscardResult = undefined;
        if (sessionId !== this.currentSessionId || generation !== this.noteEditorGeneration || this.currentSurface !== 'note-editor') return;
        this.confirmingNoteDiscard = false;
        this.requestNoteFocus('reader-note-input');
      });
  }

  private handleApplicationBackground(): void {
    if (this.currentSurface === 'note-editor') {
      this.dictionaryService?.cancelPending();
      this.clearUncommittedSelection();
      return;
    }
    this.invalidateTransientState(true);
  }

  private invalidateTransientState(clearSelection: boolean): void {
    this.closeBookmarkToast();
    this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined; this.nativeTranslationResult = false;
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
      this.savedTextMarks.filter((mark: TextMarkRecord): boolean => mark.kind === kind).map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)));
  }

  private requestWordTextMark(action: 'highlight' | 'note' | 'adjust'): void {
    const selection = this.dictionarySelection;
    if (this.currentSurface !== 'dictionary' || selection === undefined || this.bookmarkBusy) return;
    this.wordMarkRequest = action;
    this.pendingWordContextToken = selection.selectionToken;
    this.controller.requestSelectionContext(selection.selectionToken, this.currentSessionId,
      this.savedTextMarks.filter((mark: TextMarkRecord): boolean => mark.kind === (action === 'adjust' ? this.selectedTextMark()?.kind ?? 'highlight' : action)).map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)),
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
        this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: message });
      }
      return;
    }
    if (context.rangeAnchor === undefined || context.rangeAnchor.exactText.trim() !== context.selectedText) {
      this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '当前选区无法保存，请缩短选区。' });
      return;
    }
    context.chapterTitle = this.chapterTitleForHref(context.rangeAnchor.resourceHref);
    if (action === 'adjust') {
      this.reviseSelectedMark(context).catch((): void => {});
    } else if (action === 'highlight') {
      this.saveTextMark(context, 'highlight').catch((): void => {});
    } else {
      if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
      this.pendingNoteContext = context;
      this.noteDraft = '';
      this.noteDraftBaseline = '';
      this.noteOriginalQuote = context.rangeAnchor.exactText;
      this.noteFeedback = '';
      this.noteCommitKind = 'none';
      this.noteQuoteExpanded = false;
    this.noteEditorGeneration += 1;
      this.editingNoteMarkId = '';
      this.editingNoteEntryId = '';
      this.editingNoteSnapshot = undefined;
      this.editingRangeSnapshot = undefined;
      this.noteReturnSurface = 'none';
      this.noteReturnRowId = '';
      this.pendingNoteFocusKey = '';
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
    let revised: TextMarkRecord;
    try {
      revised = await this.textMarks.revise(mark, context, kind, noteText);
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkBusy = false;
        try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '修改失败，原标记已保留。请重新选文后点“保存范围”重试。' }); } catch (_) {}
      }
      return;
    }
    if (sessionId !== this.currentSessionId) return;
    this.savedTextMarks = this.savedTextMarks.filter((item: TextMarkRecord): boolean =>
      item.markId !== revised.markId && !(context?.rangeUnion?.members ?? []).some((member: VerifiedRangeMember): boolean => member.markId === item.markId));
    this.savedTextMarks = [...this.savedTextMarks, revised];
    this.adjustingMarkId = '';
    this.editingNoteMarkId = '';
    this.currentSurface = 'none';
    this.clearUncommittedSelection();
    this.bookmarkMessage = '标记已更新';
    try {
      await this.reloadTextMarks(sessionId);
    } catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkMessage = '标记已更新，列表刷新失败，请关闭后重新打开。';
    } finally {
      if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
    }
  }

  private async saveTextMark(context: ReadingSelectionContext,
    kind: 'highlight' | 'note', noteText: string = ''): Promise<void> {
    if (!this.textMarks || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    const book = this.currentBook;
    this.bookmarkBusy = true;
    try { await this.textMarks.save(book, context, kind, noteText); }
    catch (_) {
      if (sessionId === this.currentSessionId && book.bookId === this.currentBook.bookId) {
        this.bookmarkBusy = false;
        this.bookmarkMessage = '标记保存失败，原记录已保留，请重新选文后重试。';
        this.passageStatus = 'unavailable'; this.passageDetail = this.bookmarkMessage;
        this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: this.bookmarkMessage });
      }
      return;
    }
    if (sessionId !== this.currentSessionId || book.bookId !== this.currentBook.bookId) return;
    this.bookmarkMessage = kind === 'note' ? '已保存笔记' : '已添加高亮';
    this.currentSurface = 'none'; this.clearUncommittedSelection();
    try { await this.reloadTextMarks(sessionId); }
    catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkMessage = '标记已保存，列表刷新失败，请重新打开记录列表。';
        this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: this.bookmarkMessage });
      }
    }
    if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
  }

  private savePendingNote(): void {
    this.saveExistingNote().catch((): void => {});
  }

  private acceptSelectionContext(context: ReadingSelectionContext): void {
    if (this.nativeNoteToken === context.selectionToken) {
      const request = this.nativeAdjustRequest;
      this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined;
      if (request) {
        const current = this.savedTextMarks.find((mark: TextMarkRecord): boolean => mark.markId === request.markId);
        if (this.adjustingMarkId !== request.markId || !current || (current.revision ?? 1) !== request.revision ||
          current.cfi !== request.cfi || current.exactText !== request.exactText) {
          try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '原标记已变化，请点按原标记重新调整。' }); } catch (_) {}
          return;
        }
        this.acceptMarkContext(context, 'adjust');
      } else {
        this.acceptMarkContext(context, 'note');
      }
      return;
    }
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

  private handleSelectionCleared(cause: 'cancel' | 'presentation' = 'cancel'): void {
    this.hasUncommittedSelection = false;
    this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined;
    if (!this.nativeTranslationResult) this.dismissDictionary(false);
    this.dismissPassage(false);
  }

  private rejectSelectionContext(selectionToken: string): void {
    if (this.nativeNoteToken === selectionToken) {
      this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined;
      try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '选区已经变化或无法保存，请重新选择。' }); } catch (_) {}
      return;
    }
    if (this.currentSurface === 'dictionary' && this.pendingWordContextToken === selectionToken) {
      this.pendingWordContextToken = '';
      this.wordMarkRequest = 'none';
      this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '选区已经变化，请重新选择单词。' });
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
      this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '已复制所选单词。' });
    } catch (_) {
      this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '复制失败，请重试。' });
    }
  }

  private async copySelectedPassageText(selectedText: string): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, selectedText);
      await pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '已复制所选段落。' });
    } catch (_) {
      try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '复制失败，请重试。' }); }
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

  private readOnlyPageObservation(): ReaderPageObservation {
    const width = this.readerViewportWidthVp(), height = this.readerViewportHeightVp();
    const top = this.readerPublicationTopVp(), publication = this.readerPublicationHeightVp();
    return { surface: this.currentSurface, controlsVisible: this.controlsVisible, busy: this.bookmarkBusy,
      noteCommit: this.noteCommitKind, draftCharacters: this.noteDraft.length, focusReturnPending: this.pendingNoteFocusKey.length > 0,
      nativeSheetPresented: this.readerSheetPresented,
      nativeDialogPresented: this.markDetailPresented,
      nativeDialogReady: this.markDetailReady,
      nativePanelMaterial: this.panelMaterial !== undefined && this.settings.theme !== 'eye-comfort',
      noteKeyboardVisible: this.noteKeyboardVisible,
      noteSheetPreferredDetent: this.noteSheetDetent === SheetSize.LARGE ? 'large' : 'medium',
      noteSheetRequestedDetent: this.noteKeyboardVisible || this.noteSheetDetent === SheetSize.LARGE ? 'large' : 'medium',
      safeTopVp: this.windowSnapshot.safeInsets.top, safeBottomVp: this.windowSnapshot.safeInsets.bottom,
      safeLeftVp: this.windowSnapshot.safeInsets.left, safeRightVp: this.windowSnapshot.safeInsets.right,
      surfaceWidthVp: width, surfaceHeightVp: height, publicationTopVp: top, publicationHeightVp: publication,
      headerSlotVp: top, footerSlotVp: Math.max(0, height - top - publication), userMarginVp: this.settings.pageMarginVp,
      fontScale: this.settings.fontScale, theme: this.settings.theme, settingsCovered: this.settingsCovered, animateMotion: this.animateCustomMotion };
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
    return readerPublicationContentHeightVp(this.readerViewportHeightVp(), this.settings.pageMarginVp);
  }

  private readerPublicationTopVp(): number {
    return readerHeaderReserveVp(this.readerViewportHeightVp(), this.settings.pageMarginVp);
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
      this.scaledPopupHeight((this.selectedTextMark()?.notes?.length ?? 0) > 0 ? 380 : 282));
  }

  private beginAdjustMark(mark: TextMarkRecord): void {
    this.adjustingMarkId = mark.markId;
    this.selectedMarkId = '';
    this.currentSurface = 'none';
    this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined;
    try { this.getUIContext().getPromptAction().showToast({ backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text'), message: '长按选出新范围，再点“保存范围”。按返回取消调整。' }); } catch (_) {}
  }

  private cancelAdjustMark(): void {
    if (this.bookmarkBusy) return;
    this.adjustingMarkId = '';
    this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined;
    this.clearUncommittedSelection();
    this.controller.focusContent();
  }

  private beginEditMark(mark: TextMarkRecord, note?: NoteEntry, sourceRowId?: string): void {
    if (this.bookmarkBusy) return;
    if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
    this.noteReturnSurface = this.currentSurface;
    this.noteReturnRowId = sourceRowId ?? (note ? 'reader-note-entry-' + note.noteId : 'reader-mark-detail-edit');
    this.editingNoteMarkId = mark.markId;
    this.editingNoteEntryId = note?.noteId ?? '';
    this.editingNoteSnapshot = note === undefined ? undefined : copyEditingNote(note);
    this.editingRangeSnapshot = mark;
    this.noteDraft = note?.body ?? '';
    this.noteDraftBaseline = this.noteDraft;
    this.noteOriginalQuote = note?.originalAnchor.exactText ?? mark.exactText;
    this.noteFeedback = '';
    this.noteCommitKind = 'none';
    this.noteQuoteExpanded = false;
    this.noteEditorGeneration += 1;
    this.confirmingNoteDiscard = false;
    this.pendingNoteFocusKey = '';
    this.pendingNoteContext = undefined;
    this.currentSurface = 'note-editor';
    this.clearUncommittedSelection();
  }

  private selectedNoteEntries(): NoteEntry[] {
    return (this.selectedTextMark()?.notes ?? []).slice().sort((left: NoteEntry, right: NoteEntry): number =>
      left.createdAt - right.createdAt || left.noteId.localeCompare(right.noteId));
  }

  private syncReaderOverlays(): void {
    const sheet = this.isNativeReaderSheet(this.currentSurface);
    // Retain the native content root and detents until the actual dismissal completes.
    // Destroying them with the logical surface left the modal input layer alive.
    const visible = this.currentSurface === 'mark-detail';
    if (!sheet || (this.readerSheetSurface !== 'none' && this.readerSheetSurface !== this.currentSurface)) this.readerSheetVisible = false;
    if (!visible && this.markDetailDialogVisible) {
      this.markDetailDialogVisible = false; this.markDetailReady = false;
      this.markDetailDialog.close();
    }
    // Native modal ownership transfers after actual exit, not the logical surface change.
    if (sheet && !this.markDetailPresented && (this.readerSheetSurface === 'none' ||
      (this.readerSheetSurface === this.currentSurface && this.readerSheetVisible))) {
      this.readerSheetSurface = this.currentSurface;
      this.readerSheetVisible = true;
    }
    if (visible && !this.readerSheetPresented && this.readerSheetSurface === 'none' && !this.markDetailPresented) {
      this.markDetailDialogVisible = true; this.markDetailPresented = true; this.markDetailReady = false;
      this.markDetailDialog = this.createMarkDetailDialog();
      this.markDetailDialog.open();
    }
  }

  private confirmNoteDeletion(note: NoteEntry, fromEditor: boolean = false): void {
    if (this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.getUIContext().getPromptAction().showDialog(nativePromptDialogOptions(this.settings.theme === 'eye-comfort' ? undefined : this.panelMaterial, { title: '删除这条笔记？',
      message: '只删除这条笔记，其他笔记和独立高亮会保留。',
      buttons: [{ text: '取消', color: this.shellColor('secondary') },
        { text: '删除笔记', color: this.readerDangerColor() }] }))
      .then((result): void => {
        if (result.index !== 1 || sessionId !== this.currentSessionId || this.bookmarkBusy) return;
        if (fromEditor && this.currentSurface === 'note-editor' && this.editingNoteEntryId === note.noteId) {
          this.deleteEditingNote().catch((): void => {});
        } else if (!fromEditor && this.currentSurface === 'mark-detail') {
          this.deleteNoteEntry(note).catch((): void => {});
        }
      }).catch((): void => {});
  }

  private confirmHighlightRemoval(mark: TextMarkRecord): void {
    if (this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.getUIContext().getPromptAction().showDialog(nativePromptDialogOptions(this.settings.theme === 'eye-comfort' ? undefined : this.panelMaterial, { title: '移除独立高亮？',
      message: '只移除这处独立高亮，已写的笔记会保留。',
      buttons: [{ text: '取消', color: this.shellColor('secondary') },
        { text: '移除高亮', color: this.readerDangerColor() }] }))
      .then((result): void => {
        if (result.index === 1 && sessionId === this.currentSessionId) this.removeTextMark(mark).catch((): void => {});
      }).catch((): void => {});
  }

  private closeMarkDetail(): void {
    const surface = this.markDetailReturnSurface;
    const rowId = this.markDetailReturnRowId;
    this.markDetailReturnSurface = 'none'; this.markDetailReturnRowId = '';
    this.pendingNoteFocusKey = rowId; this.noteFocusRequested = false;
    if (this.currentSurface === 'mark-detail') this.currentSurface = surface;
    // Content and focus remain owned by the outgoing native Dialog until onDidDisappear.
  }

  private async reloadTextMarks(sessionId: number): Promise<void> {
    const bookId = this.currentBook.bookId;
    const request = ++this.textMarkRefreshRevision;
    const marks = await this.textMarks?.list(bookId) ?? [];
    if (sessionId !== this.currentSessionId || bookId !== this.currentBook.bookId || request !== this.textMarkRefreshRevision) return;
    for (const old of this.savedTextMarks) this.controller.removeTextMark(old.markId, sessionId);
    this.savedTextMarks = marks;
    this.traceNoteOverlay('notes-reloaded');
    this.previewVisibleTextMarks();
  }

  private async saveExistingNote(): Promise<void> {
    if (!this.textMarks || this.bookmarkBusy || this.currentSurface !== 'note-editor' || this.noteCommitKind !== 'none') return;
    const note = this.editingNoteSnapshot;
    const mark = this.editingRangeSnapshot;
    const context = this.pendingNoteContext;
    if (!note && !mark && !context) return;
    const sessionId = this.currentSessionId;
    const generation = this.noteEditorGeneration;
    const book = this.currentBook;
    const draft = this.noteDraft;
    this.bookmarkBusy = true;
    this.noteFeedback = '';
    try {
      // Preserve the entry revision captured when editing began; a refresh must not erase CAS conflicts.
      if (note) await this.textMarks.editNote(note, draft);
      else if (mark) await this.textMarks.addNote(mark, draft);
      else await this.textMarks.save(book, context!, 'note', draft);
    } catch (_) {
      if (sessionId === this.currentSessionId && generation === this.noteEditorGeneration) {
        this.noteFeedback = '笔记保存失败，草稿与原始引用已保留，请重试。';
        this.bookmarkBusy = false;
      }
      return;
    }
    if (sessionId !== this.currentSessionId || generation !== this.noteEditorGeneration) return;
    // Write success is final. A list or focus failure must never authorize the same write again.
    this.noteCommitKind = 'saved';
    this.traceNoteOverlay('note-save');
    this.noteDraftBaseline = draft;
    this.bookmarkBusy = false;
    await this.refreshCommittedNote(sessionId, generation);
  }

  private async refreshCommittedNote(sessionId: number = this.currentSessionId,
    generation: number = this.noteEditorGeneration): Promise<void> {
    if (this.noteCommitKind === 'none' || this.bookmarkBusy || this.currentSurface !== 'note-editor') return;
    this.bookmarkBusy = true;
    try {
      await this.reloadTextMarks(sessionId);
    } catch (_) {
      if (sessionId === this.currentSessionId && generation === this.noteEditorGeneration) {
        this.noteFeedback = this.noteCommitKind === 'deleted' ?
          '该条笔记已删除，列表刷新失败；请重试刷新。' : '笔记已保存，列表刷新失败；请重试刷新。';
        this.bookmarkBusy = false;
      }
      return;
    }
    if (sessionId !== this.currentSessionId || generation !== this.noteEditorGeneration) return;
    this.bookmarkBusy = false;
    this.noteFeedback = '';
    this.finishNoteEditor();
  }

  private async deleteEditingNote(): Promise<void> {
    const note = this.editingNoteSnapshot;
    if (!note || !this.textMarks || this.bookmarkBusy || this.noteCommitKind !== 'none') return;
    const sessionId = this.currentSessionId;
    const generation = this.noteEditorGeneration;
    this.bookmarkBusy = true;
    this.noteFeedback = '';
    try { await this.textMarks.removeNote(note); }
    catch (_) {
      if (sessionId === this.currentSessionId && generation === this.noteEditorGeneration) {
        this.noteFeedback = '删除笔记失败，原记录与当前草稿已保留，请重试。';
        this.bookmarkBusy = false;
      }
      return;
    }
    if (sessionId !== this.currentSessionId || generation !== this.noteEditorGeneration) return;
    this.noteCommitKind = 'deleted';
    this.savedTextMarks = this.savedTextMarks.map((item: TextMarkRecord): TextMarkRecord => {
      item.notes = (item.notes ?? []).filter((entry: NoteEntry): boolean => entry.noteId !== note.noteId);
      return item;
    }).filter((item: TextMarkRecord): boolean => (item.notes?.length ?? 0) > 0 || (item.highlightAnchors?.length ?? 0) > 0);
    this.noteReturnRowId = 'reader-mark-detail-close';
    this.bookmarkBusy = false;
    await this.refreshCommittedNote(sessionId, generation);
  }

  private async deleteNoteEntry(note: NoteEntry): Promise<void> {
    if (!this.textMarks || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    const survivors = this.selectedNoteEntries().filter((entry: NoteEntry): boolean => entry.noteId !== note.noteId);
    this.bookmarkBusy = true;
    this.noteFeedback = '';
    try { await this.textMarks.removeNote(copyEditingNote(note)); }
    catch (_) {
      if (sessionId === this.currentSessionId) {
        this.noteFeedback = '删除笔记失败，原记录已保留，请重试。';
        this.bookmarkBusy = false;
      }
      return;
    }
    if (sessionId !== this.currentSessionId) return;
    // Remove the committed entry from the UI immediately, so refresh failure cannot expose another delete attempt.
    this.savedTextMarks = this.savedTextMarks.map((mark: TextMarkRecord): TextMarkRecord => {
      mark.notes = (mark.notes ?? []).filter((entry: NoteEntry): boolean => entry.noteId !== note.noteId);
      return mark;
    }).filter((mark: TextMarkRecord): boolean => (mark.notes?.length ?? 0) > 0 || (mark.highlightAnchors?.length ?? 0) > 0);
    try { await this.reloadTextMarks(sessionId); }
    catch (_) {
      if (sessionId === this.currentSessionId) this.noteFeedback = '该条笔记已删除，列表刷新失败；请重试刷新。';
    }
    if (sessionId !== this.currentSessionId) return;
    this.bookmarkBusy = false;
    const survivor = this.savedTextMarks.find((mark: TextMarkRecord): boolean =>
      (mark.notes ?? []).some((entry: NoteEntry): boolean => survivors.some((previous: NoteEntry): boolean => previous.noteId === entry.noteId)));
    if (survivor) {
      this.selectedMarkId = survivor.markId;
      if (this.markDetailReturnSurface === 'notes') this.markDetailReturnRowId = 'reader-record-mark-' + survivor.markId;
    }
    else if (!this.selectedTextMark() || ((this.selectedTextMark()?.notes?.length ?? 0) === 0 &&
      !(this.selectedTextMark()?.highlightAnchors?.length))) this.closeMarkDetail();
    this.pendingNoteFocusKey = this.currentSurface === 'mark-detail' ? 'reader-mark-detail-close' : '';
    this.noteFocusRequested = false;
    if (!this.pendingNoteFocusKey) this.controller.focusContent();
  }

  private async retainNoteStatus(noteId: string,revision: number,status: RangeAnchorStatus,sessionId: number): Promise<void> {
    const note = this.savedTextMarks.flatMap((mark: TextMarkRecord): NoteEntry[] => mark.notes ?? [])
      .find((entry: NoteEntry): boolean => entry.noteId === noteId && entry.revision === revision);
    if (!note || !this.textMarks || sessionId !== this.currentSessionId) return;
    await this.textMarks.setNoteAnchorStatus(note,status);
    if (sessionId !== this.currentSessionId) return;
    this.savedTextMarks = this.savedTextMarks.map((mark: TextMarkRecord): TextMarkRecord => {
      for (const entry of mark.notes ?? []) if (entry.noteId === noteId && entry.revision === revision) {
        entry.anchorStatus = entry.anchorProvenance === 'legacy-group' ? 'unavailable' : status;
      }
      return mark;
    });
  }

  private jumpNote(note: NoteEntry): void {
    if (note.anchorProvenance === 'legacy-group') return;
    const anchor = note.originalAnchor;
    this.pendingMarkId = note.noteId;
    this.controller.goToTextMark({markId:note.noteId,bookId:note.bookId,anchorVersion:anchor.anchorVersion,engine:anchor.engine,
      resourceHref:anchor.resourceHref,cfi:anchor.cfi,exactText:anchor.exactText,prefix:anchor.prefix,suffix:anchor.suffix,
      quoteScope:anchor.quoteScope,kind:'note',revision:note.revision,highlightActive:false},this.currentSessionId);
  }

  private openRecordDetail(mark: TextMarkRecord, sourceRowId?: string): void {
    if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
    if (this.currentSurface === 'notes' && this.readerSheetSurface === 'notes') {
      this.notesInitialOffset = this.notesScroller.currentOffset().yOffset;
    }
    this.noteFeedback = '';
    this.markDetailReturnSurface = sourceRowId === undefined ? 'none' : this.currentSurface;
    this.markDetailReturnRowId = sourceRowId ?? '';
    this.selectedMarkId = mark.markId;
    this.selectedMarkRect = undefined;
    this.currentSurface = 'mark-detail';
  }

  private async retainAnchorStatus(markId: string, status: RangeAnchorStatus, sessionId: number): Promise<void> {
    const mark = this.savedTextMarks.find((item: TextMarkRecord): boolean => item.markId === markId);
    if (!mark || !this.textMarks || mark.anchorStatus === status) return;
    await this.textMarks.setAnchorStatus(mark, status);
    if (sessionId === this.currentSessionId) this.savedTextMarks = this.savedTextMarks.map((item: TextMarkRecord): TextMarkRecord => {
      if (item.markId === markId && item.revision === mark.revision) item.anchorStatus = status;
      return item;
    });
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

  private setSettingsCovered(covered: boolean): Promise<void> {
    this.settingsCovered = covered;
    if (!covered) {
      this.settingsFocusPending = true;
      this.updateSystemBars(this.settings.theme);
    }
    return this.systemBarUpdate;
  }

  private restoreSettingsFocus(): void {
    if (this.settingsCovered || !this.settingsFocusPending || !this.hasReaderSession || this.exiting) return;
    if (this.controlsVisible && this.currentSurface === 'none') {
      try {
        this.getUIContext().getFocusController().requestFocus('reader-more');
      } catch (_) {}
    } else {
      this.controller.focusContent(); this.settingsFocusPending = false;
    }
  }

  private syncConfirmedPreferences(): void {
    const application = this.appearanceApplication;
    if (application === undefined || !this.hasReaderSession || this.exiting) return;
    try {
      const next = application.loadSettings(this.currentBook.bookId);
      const overrides = application.bookLayoutOverrides(this.currentBook.bookId);
      const themePreference = application.persistentPreference();
      const animate = animateReaderMotion(this.systemReducedMotion);
      const show = application.showControlsButton();
      const hide = application.hideControlsButton();
      const beforeEffective = this.effectiveReaderSettings(this.settings);
      const nextEffective = this.effectiveReaderSettings(next);
      const geometryChanged = beforeEffective.fontScale !== nextEffective.fontScale ||
        beforeEffective.lineSpacing !== nextEffective.lineSpacing ||
        beforeEffective.pageMarginVp !== nextEffective.pageMarginVp ||
        beforeEffective.columnMode !== nextEffective.columnMode;
      const themeChanged = this.settings.theme !== next.theme;
      this.selectedThemePreference = themePreference;
      this.showControlsButton = show; this.hideControlsButton = hide;
      this.animateCustomMotion = animate;
      this.settings = next;
      this.bookLayoutOverrides = overrides;
      if (themeChanged) {
        this.onThemeChange(next.theme); this.updateSystemBars(next.theme);
      }
      if (geometryChanged || themeChanged) this.controller.applySettings(nextEffective);
    } catch (_) {
      this.appearanceMessage = '偏好读取失败，已保留当前阅读设置。';
    }
  }

  private updateLayoutSettings(parameter: ReaderLayoutParameter, value: number): void {
    const application = this.appearanceApplication;
    if (application === undefined) { this.appearanceMessage = '排版尚未就绪，请重试。'; return; }
    try { application.saveBookLayoutParameter(this.currentBook.bookId, parameter, value); }
    catch (_) { this.appearanceMessage = '排版未保存，请重试。'; return; }
    this.appearanceMessage = '';
    this.syncConfirmedPreferences();
  }

  private resetBookLayout(): void {
    const application = this.appearanceApplication;
    if (application === undefined) { this.appearanceMessage = '排版尚未就绪，请重试。'; return; }
    try { application.clearBookLayoutOverrides(this.currentBook.bookId); }
    catch (_) { this.appearanceMessage = '默认排版未恢复，请重试。'; return; }
    this.appearanceMessage = '';
    this.syncConfirmedPreferences();
  }

  private selectReaderTheme(preference: ReaderThemePreference): void {
    try { this.appearanceApplication?.saveThemePreference(preference); }
    catch (_) { this.appearanceMessage = '配色未保存，请重试。'; return; }
    this.appearanceMessage = '';
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
      Row({ space: 12 }) {
        Text(preference === 'system' ? $r('app.string.reader_theme_system') :
          preference === 'light' ? $r('app.string.reader_theme_light') :
            preference === 'dark' ? $r('app.string.reader_theme_dark') : $r('app.string.reader_theme_eye_comfort'))
          .fontSize(16).fontColor(this.shellColor('text')).layoutWeight(1)
        Radio({ value: preference, group: 'reader-theme-options' })
          .checked(this.selectedThemePreference === preference).width(20).height(20)
          .hitTestBehavior(HitTestMode.None).focusable(false)
      }.width('100%')
    }.id(id).width('100%').constraintSize({ minHeight: 48 }).padding({ left: 12, right: 12 })
      .type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(12)
      .accessibilitySelected(this.selectedThemePreference === preference)
      .onClick((): void => this.selectReaderTheme(preference))
  }

  private exitReader(): void {
    if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor((): void => this.exitReader()); return; }
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
      this.orphanMarkIds = marks.filter((mark: TextMarkRecord): boolean =>
        mark.anchorStatus === 'missing' || mark.anchorStatus === 'ambiguous' || mark.anchorStatus === 'unavailable')
        .map((mark: TextMarkRecord): string => mark.markId);
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
          ((mark.notes?.length ?? 0) > 0 ? `${mark.notes!.length} 条笔记 · ${mark.notes![0].body}` : mark.exactText),
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
    if (!this.textMarks || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    this.bookmarkBusy = true;
    try { await this.textMarks.remove(mark.bookId, mark.markId); }
    catch (_) {
      if (sessionId === this.currentSessionId) {
        this.noteFeedback = '撤销高亮失败，原记录已保留，请重试。';
        this.bookmarkBusy = false;
      }
      return;
    }
    if (sessionId !== this.currentSessionId) return;
    this.controller.removeTextMark(mark.markId, sessionId);
    this.orphanMarkIds = this.orphanMarkIds.filter((id: string): boolean => id !== mark.markId);
    this.savedTextMarks = this.savedTextMarks.filter((entry: TextMarkRecord): boolean =>
      entry.markId !== mark.markId || (entry.notes?.length ?? 0) > 0).map((entry: TextMarkRecord): TextMarkRecord => {
      if (entry.markId === mark.markId) { entry.highlightAnchors = []; entry.highlightActive = false; entry.revision = (entry.revision ?? 1) + 1; }
      return entry;
    });
    if (this.selectedMarkId === mark.markId) this.closeMarkDetail();
    try { await this.reloadTextMarks(sessionId); }
    catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkMessage = '高亮已撤销，列表刷新失败，请重新打开记录列表。';
    }
    if (sessionId === this.currentSessionId) this.bookmarkBusy = false;
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
        item.markId === markId && (item.revision ?? 1) === (mark.revision ?? 1) &&
          item.cfi === mark.cfi && item.exactText === mark.exactText ? {
            markId: item.markId, bookId: item.bookId, anchorVersion: item.anchorVersion, engine: item.engine,
            resourceHref: item.resourceHref, cfi: recovered.cfi, exactText: item.exactText, prefix: item.prefix,
            suffix: item.suffix, kind: item.kind, chapterTitle: item.chapterTitle, noteText: item.noteText,
            createdAt: item.createdAt, revision: recovered.revision, highlightActive: item.highlightActive,
            anchorStatus: recovered.anchorStatus, quoteScope: item.quoteScope, notes: item.notes,
            highlightAnchors: item.highlightAnchors } : item);
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

  private closeBookmarkToast(): void {
    this.bookmarkToastRequest++;
    if (this.bookmarkToastId !== undefined) {
      try { this.getUIContext().getPromptAction().closeToast(this.bookmarkToastId); } catch (_) {}
      this.bookmarkToastId = undefined;
    }
  }
  private bookmarkFeedback(message: string): void {
    if (this.noteKeyboardDisposed) return;
    this.closeBookmarkToast();
    const request = this.bookmarkToastRequest, prompt = this.getUIContext().getPromptAction();
    prompt.openToast({ message, backgroundColor: this.shellColor('surface'), textColor: this.shellColor('text') })
      .then((id: number): void => {
        if (request === this.bookmarkToastRequest) this.bookmarkToastId = id;
        else { try { prompt.closeToast(id); } catch (_) {} }
      }).catch((): void => {});
  }
  private async toggleBookmark(): Promise<void> {
    if (this.bookmarks === undefined || this.location === undefined || !this.bookmarkReady || this.bookmarkBusy) return;
    const sessionId = this.currentSessionId;
    const removing = this.currentBookmark() !== undefined;
    this.bookmarkBusy = true;
    this.bookmarkMessage = '';
    try {
      const result = await this.bookmarks.toggle(this.currentBook, this.location,
        this.chapterTitle(), this.currentPageExcerpt.slice(0, 200));
      if (sessionId !== this.currentSessionId) return;
      this.bookmarkPoints = result.points;
      this.bookmarkFeedback(result.added ? '书签已添加' : '书签已移除');
    } catch (_) {
      if (sessionId === this.currentSessionId) {
        this.bookmarkFeedback(removing ? '移除书签失败，请重试' : '添加书签失败，请重试');
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
      if (sessionId === this.currentSessionId) {
        this.bookmarkPoints = points;
        this.bookmarkFeedback('书签已移除');
      }
    } catch (_) {
      if (sessionId === this.currentSessionId) this.bookmarkFeedback('移除书签失败，请重试');
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
    this.getUIContext().showAlertDialog(nativeAlertOptions(this.settings.theme === 'eye-comfort' ? undefined : this.panelMaterial, {
      backgroundColor: this.shellColor('surface'),
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
    }));
  }

  @Builder
  private readerMoreMenu() {
    Menu() {
      MenuItem({ content: this.currentBookmark() === undefined ? '添加书签' : '移除当前书签' })
        .id('reader-bookmark-toggle').height(48)
        .enabled(this.bookmarkReady && this.location !== undefined && !this.bookmarkBusy && this.pendingBookmarkId.length === 0)
        .onClick((): void => { this.toggleBookmark().catch((): void => {}); })
      MenuItem({ content: '书签列表' }).id('reader-open-bookmarks').height(48)
        .onClick((): void => this.openAuxiliaryPanel('bookmarks', 'reader-more'))
      MenuItem({ content: '阅读进度' }).id('reader-open-progress').height(48)
        .onClick((): void => this.openAuxiliaryPanel('progress', 'reader-more'))
      MenuItem({ content: '阅读偏好' }).id('reader-open-reading-settings').height(48)
        .onClick((): void => this.onOpenReadingSettings())
      if (this.hideControlsButton && this.readerViewportWidthVp() < 840) {
        MenuItem({ content: '隐藏工具栏' }).id('reader-hide-controls-menu').height(48)
          .onClick((): void => this.setControlsVisible(false))
      }
      MenuItem({ content: '聚焦正文' }).id('reader-focus-publication').height(48)
        .onClick((): void => this.focusPublicationForSelection())
    }.fontColor(this.shellColor('text'))
  }
  @Builder
  private readerTopBar() {
    Row({ space: 4 }) {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).focusable(true).fontSize(20).fontColor([this.shellColor('secondary')]) }
        .id('reader-library-back').width(48).height(48).type(ButtonType.Circle)
        .backgroundColor(Color.Transparent).accessibilityText('返回')
        .onClick((): void => this.handleSystemBack())
      Text(this.currentBook.title).id('reader-book-title').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.shellColor('text')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).focusable(true).fontSize(20).fontColor([this.shellColor('secondary')]) }
        .id('reader-more').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText('更多阅读操作').bindMenu(this.readerMoreMenu(), nativeMenuOptions(this.settings.theme === 'eye-comfort' ? undefined : this.menuMaterial))
        .onAppear((): void => this.restorePanelFocus('reader-more'))
        .onFocus((): void => {
          if (this.panelFocusReturn === 'reader-more') this.panelFocusReturn = '';
          if (!this.settingsCovered) this.settingsFocusPending = false;
        })
    }.id('reader-chrome-top').width('100%').height(48).padding({ left: 8, right: 8 }).backgroundColor(this.shellColor('surface'))
      .transition(this.readerSurfaceTransition()).layoutGravity(LocalizedAlignment.TOP)
  }
  @Builder
  private readerBottomBar() {
    Row({ space: 4 }) {
      this.readerCoreAction('目录', 'reader-open-toc', 'toc', $r('sys.symbol.list_bullet'))
      this.readerCoreAction('笔记', 'reader-open-notes', 'notes', $r('sys.symbol.square_and_pencil'))
      this.readerCoreAction('外观', 'reader-open-appearance', 'appearance', $r('sys.symbol.textformat'))
      if (this.hideControlsButton && this.readerViewportWidthVp() >= 840) {
        Button() {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.chevron_down')).fontSize(20).fontColor([this.shellColor('text')])
            Text('隐藏').focusable(true).fontSize(12).fontColor(this.shellColor('text'))
          }
        }.id('reader-hide-controls').height(48).constraintSize({ minWidth: 48 }).layoutWeight(1)
          .type(ButtonType.Normal).backgroundColor(Color.Transparent).accessibilityText('隐藏工具栏')
          .onClick((): void => this.setControlsVisible(false))
      }
    }.id('reader-chrome-bottom').width('100%').height(48).padding({ left: 8, right: 8 }).backgroundColor(this.shellColor('surface'))
      .transition(this.readerSurfaceTransition()).layoutGravity(LocalizedAlignment.BOTTOM)
  }
  @Builder
  private readerCoreAction(label: string, id: string, surface: ReaderSurface, icon: Resource) {
    Button() {
      Column({ space: 2 }) {
        SymbolGlyph(icon).fontSize(20).fontColor([this.shellColor('secondary')])
        Text(label).focusable(true).fontSize(11).fontColor(this.shellColor('secondary'))
      }.width('100%').height('100%').justifyContent(FlexAlign.Center)
    }.id(id).height(48).constraintSize({ minWidth: 48 }).layoutWeight(1)
      .type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(16).accessibilityText(label)
      .onClick((): void => this.openAuxiliaryPanel(surface, id))
      .onAppear((): void => this.restorePanelFocus(id))
      .onFocus((): void => { if (this.panelFocusReturn === id) this.panelFocusReturn = ''; })
  }
  private readerMutedColor(): Resource {
    return this.settings.theme === 'dark' ? $r('app.color.reader_surface_muted_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_surface_muted_eye_comfort') :
        $r('app.color.reader_surface_muted_light');
  }

  private readerDangerColor(): Resource {
    return this.settings.theme === 'dark' ? $r('app.color.reader_error_dark') :
      this.settings.theme === 'eye-comfort' ? $r('app.color.reader_error_eye_comfort') : $r('app.color.reader_error_light');
  }

  private appearanceParameterValue(id: string): string {
    if (id === 'reader-font-scale') return `${Math.round(this.settings.fontScale * 100)}%`;
    if (id === 'reader-line-spacing') return this.settings.lineSpacing.toFixed(1);
    return `${this.settings.pageMarginVp} vp`;
  }

  private canAdjustAppearanceParameter(id: string, increase: boolean): boolean {
    if (id === 'reader-font-scale') return increase ? this.settings.fontScale < 1.6 : this.settings.fontScale > 0.8;
    if (id === 'reader-line-spacing') return increase ? this.settings.lineSpacing < 2.0 : this.settings.lineSpacing > 1.2;
    return increase ? this.settings.pageMarginVp < 40 : this.settings.pageMarginVp > 8;
  }

  private adjustAppearanceParameter(id: string, increase: boolean): void {
    if (id === 'reader-font-scale') {
      this.updateLayoutSettings('fontScale', increase ? Math.min(1.6, this.settings.fontScale + 0.1) :
        Math.max(0.8, this.settings.fontScale - 0.1));
    } else if (id === 'reader-line-spacing') {
      this.updateLayoutSettings('lineSpacing', increase ?
        Math.min(2.0, this.settings.lineSpacing + 0.1) : Math.max(1.2, this.settings.lineSpacing - 0.1));
    } else if (id === 'reader-page-margin') {
      this.updateLayoutSettings('pageMarginVp', increase ?
        Math.min(40, this.settings.pageMarginVp + 4) : Math.max(8, this.settings.pageMarginVp - 4));
    }
  }

  @Builder
  private appearanceParameter(label: Resource, id: string) {
    Row({ space: 4 }) {
      Column({ space: 2 }) {
        Text(label).fontSize(16).fontColor(this.shellColor('text'))
        Text((id === 'reader-font-scale' ? this.bookLayoutOverrides.fontScale !== undefined :
          id === 'reader-line-spacing' ? this.bookLayoutOverrides.lineSpacing !== undefined :
          this.bookLayoutOverrides.pageMarginVp !== undefined) ? '本书自定义' : '跟随默认')
          .fontSize(12).fontColor(this.shellColor('secondary'))
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.minus')).fontSize(16).fontColor([this.shellColor('accent')]) }
        .id(id + '-decrease').width(48).height(48).type(ButtonType.Circle)
        .backgroundColor(this.readerMutedColor()).accessibilityText('减小' + this.resourceText(label))
        .enabled(this.canAdjustAppearanceParameter(id, false)).onClick((): void => this.adjustAppearanceParameter(id, false))
      Text(this.appearanceParameterValue(id)).id(id + '-current').fontSize(16).fontWeight(FontWeight.Medium)
        .fontColor(this.shellColor('text')).width(64).textAlign(TextAlign.Center)
      Button() { SymbolGlyph($r('sys.symbol.plus')).fontSize(16).fontColor([this.shellColor('accent')]) }
        .id(id + '-increase').width(48).height(48).type(ButtonType.Circle)
        .backgroundColor(this.readerMutedColor()).accessibilityText('增大' + this.resourceText(label))
        .enabled(this.canAdjustAppearanceParameter(id, true)).onClick((): void => this.adjustAppearanceParameter(id, true))
    }.width('100%').constraintSize({ minHeight: 56 }).padding({ left: 12 })
  }

  @Builder
  private appearanceContent() {
    Scroll() {
      Column({ space: 8 }) {
        Text('当前图书 · 排版调整仅对本书生效').fontSize(13).fontColor(this.shellColor('secondary')).width('100%')
        Column() {
          this.appearanceParameter($r('app.string.reader_font_scale'), 'reader-font-scale')
          this.appearanceParameter($r('app.string.reader_line_spacing'), 'reader-line-spacing')
          this.appearanceParameter($r('app.string.reader_page_margin'), 'reader-page-margin')
        }.width('100%')
        Button('恢复默认排版').id('reader-layout-reset').constraintSize({ minHeight: 48 }).buttonStyle(ButtonStyleMode.TEXTUAL)
          .enabled(this.bookLayoutOverrides.fontScale !== undefined || this.bookLayoutOverrides.lineSpacing !== undefined ||
            this.bookLayoutOverrides.pageMarginVp !== undefined).onClick((): void => this.resetBookLayout())
        Column({ space: 4 }) {
          Text('阅读主题').fontSize(14).fontWeight(FontWeight.Medium).fontColor(this.shellColor('secondary')).width('100%')
          Text(this.readerThemeStatus()).id('reader-theme-current').fontSize(12)
            .fontColor(this.shellColor('secondary')).width('100%')
          this.readerThemeOption('system', 'reader-theme-system')
          this.readerThemeOption('light', 'reader-theme-light')
          this.readerThemeOption('dark', 'reader-theme-dark')
          this.readerThemeOption('eye-comfort', 'reader-theme-eye-comfort')
        }.width('100%')
      }.width('100%').padding({ bottom: 4 }).alignItems(HorizontalAlign.Start)
    }.id('reader-appearance-scroll').width('100%')
      .constraintSize({ maxHeight: this.isSideReaderPanel() ? Math.max(96, this.panelHeight() - 100) : this.appearanceContentMaxHeight() })
      .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
      .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
  }

  private appearanceContentMaxHeight(): number { return Math.max(96, this.readerViewportHeightVp() * 0.94 - 112); }

  @Builder private nativeAppearanceContent() {
    Column({ space: 8 }) {
      Row() {
        Text('本书外观').id('reader-appearance-title').fontSize(18).fontWeight(FontWeight.Medium)
          .fontColor(this.shellColor('text')).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.shellColor('secondary')]) }
          .id('reader-appearance-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('关闭本书外观').onClick((): void => this.dismissReaderPanel(true))
      }.width('100%')
      if (this.appearanceMessage) {
        Text(this.appearanceMessage).id('reader-native-appearance-message').fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
      }
      this.appearanceContent()
    }.id('reader-native-appearance-panel').width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }

  @Builder
  private bookmarkContent() {
    Scroll() {
      Column({ space: 4 }) {
        if (this.panelRecords('bookmarks').length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.bookmark')).fontSize(32).fontColor([this.shellColor('secondary')])
            Text('暂无书签').fontSize(16).fontColor(this.shellColor('text'))
            Text('阅读时在「更多」中添加书签，方便下次返回。').fontSize(14)
              .fontColor(this.shellColor('secondary')).textAlign(TextAlign.Center)
          }.id('reader-bookmarks-empty').width('100%').padding({ top: 16, bottom: 24, left: 12, right: 12 })
        }
        ForEach(this.panelRecords('bookmarks'), (entry: ReadingListEntry) => {
          Row({ space: 4 }) {
            Button() {
              Row({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.bookmark')).fontSize(18).fontColor([this.shellColor('secondary')])
                Column({ space: 6 }) {
                  Text(entry.detail !== '页面书签' && entry.detail.trim() !== entry.title.trim() ? entry.detail : entry.title)
                    .fontSize(16).lineHeight(24).fontColor(this.shellColor('text')).width('100%').textAlign(TextAlign.Start)
                  if (entry.detail !== '页面书签' && entry.detail.trim() !== entry.title.trim()) {
                    Text(entry.title).fontSize(13).fontColor(this.shellColor('secondary'))
                      .width('100%').textAlign(TextAlign.Start)
                  }
                  Text(new Date(entry.createdAt).toLocaleDateString()).fontSize(12).fontColor(this.shellColor('secondary'))
                    .width('100%').textAlign(TextAlign.Start)
                }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              }.width('100%').alignItems(VerticalAlign.Top)
            }.id('reader-record-' + entry.id).focusable(true).layoutWeight(1).constraintSize({ minHeight: 48 })
              .type(ButtonType.Normal).backgroundColor(Color.Transparent).padding(12).borderRadius(16)
              .onAppear((): void => this.restoreNoteRowFocus('reader-record-' + entry.id))
              .onAreaChange((_old: Area, area: Area): void => {
                if (this.areaLength(area.width) > 0 && this.areaLength(area.height) > 0) this.restoreNoteRowFocus('reader-record-' + entry.id, true);
              })
              .onFocus((): void => {
                this.pageController.readOnlyObservation?.focusObserved('record-group');
                if (this.pendingNoteFocusKey === 'reader-record-' + entry.id) {
                  this.pendingNoteFocusKey = ''; this.noteFocusRequested = false;
                }
              })
              .onClick((): void => { if (entry.point) this.jumpBookmark(entry.point); })
            Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([this.shellColor('secondary')]) }
              .id('reader-bookmark-more').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
              .accessibilityText('书签更多操作').enabled(!this.bookmarkBusy)
              .bindMenu(this.bookmarkEntryMenu(entry), nativeMenuOptions(this.settings.theme === 'eye-comfort' ? undefined : this.menuMaterial))
          }.width('100%').alignItems(VerticalAlign.Top)
        }, (entry: ReadingListEntry): string => entry.id)
      }.width('100%').alignItems(HorizontalAlign.Start)
    }.id('reader-bookmark-list').width('100%').constraintSize({ maxHeight: this.browseContentMaxHeight() })
      .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
      .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
  }

  @Builder
  private auxiliaryContent() {
    if (this.currentSurface === 'bookmarks') { this.bookmarkContent() }
    else if (this.currentSurface === 'appearance') { this.appearanceContent() }
    else if (this.currentSurface === 'toc') {
      if (this.chapters.length === 0) { Text('本书没有可用目录').fontSize(14).fontColor(this.shellColor('secondary')) }
      List({ space: 2 }) {
        ForEach(this.chapters, (chapter: Chapter) => {
          ListItem() {
            Button() {
              Text(chapter.label).fontSize(15).textAlign(TextAlign.Start).width('100%')
                .fontWeight(this.isCurrentChapter(chapter) ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.isCurrentChapter(chapter) ? this.shellColor('accent') : this.shellColor('text'))
            }.id(this.isCurrentChapter(chapter) ? 'reader-toc-current-chapter' : 'reader-toc-chapter')
              .width('100%').constraintSize({ minHeight: 48 }).type(ButtonType.Normal)
              .padding({ left: 12 + Math.min(4, Math.max(0, chapter.depth ?? 0)) * 16, right: 12, top: 12, bottom: 12 })
              .borderRadius(12).backgroundColor(this.isCurrentChapter(chapter) ? this.readerMutedColor() : Color.Transparent)
              .accessibilityText(chapter.label)
              .onClick((): void => { this.controller.goToChapter(chapter.href); this.currentSurface = 'none'; })
          }
        }, (chapter: Chapter): string => chapter.id)
      }.id('reader-toc-sidebar-list').layoutWeight(1).width('100%')
    } else {
      this.notesContent(false)
    }
  }

  @Builder private noteRecordEntry(entry: ReadingListEntry) {
    Button() {
      Column({ space: 8 }) {
        if (entry.mark) {
          Text(entry.mark.exactText).id('reader-record-quote').fontSize(16).lineHeight(24).fontColor(this.shellColor('text'))
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          ForEach((entry.mark.notes ?? []).slice(0, 2), (note: NoteEntry) => {
            Text(note.body).id('reader-record-note').fontSize(14).lineHeight(22).fontColor(this.shellColor('text'))
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }, (note: NoteEntry): string => note.noteId)
          Text(((entry.mark.notes?.length ?? 0) > 0 ?
            ((entry.mark.notes!.length > 1) ? entry.mark.notes!.length + '条笔记' : '笔记') : '独立高亮') +
            ' · ' + entry.title + ' · ' + new Date(entry.createdAt).toLocaleDateString()).fontSize(12)
            .fontColor(this.shellColor('secondary')).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          if (this.orphanMarkIds.includes(entry.mark.markId)) {
            Text('暂时无法定位原文').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
          }
        } else {
          Text(entry.title).focusable(true).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.shellColor('text')).width('100%')
          Text(entry.detail).fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
          Text(new Date(entry.createdAt).toLocaleString()).fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
        }
      }.alignItems(HorizontalAlign.Start).width('100%')
    }.id('reader-record-' + entry.id).focusable(true).width('100%').constraintSize({ minHeight: 48 })
      .type(ButtonType.Normal).backgroundColor(Color.Transparent)
      .padding(12).borderRadius(12)
      .onAppear((): void => this.restoreNoteRowFocus('reader-record-' + entry.id))
      .onAreaChange((_old: Area, area: Area): void => {
        if (this.areaLength(area.width) > 0 && this.areaLength(area.height) > 0) this.restoreNoteRowFocus('reader-record-' + entry.id, true);
      })
      .onFocus((): void => {
        this.pageController.readOnlyObservation?.focusObserved('record-group');
        if (this.pendingNoteFocusKey === 'reader-record-' + entry.id) {
          this.pendingNoteFocusKey = ''; this.noteFocusRequested = false;
        }
      })
      .onClick((): void => { if (entry.point) this.jumpBookmark(entry.point); else if (entry.mark) this.openRecordDetail(entry.mark, 'reader-record-' + entry.id); })
  }

  @Builder private notesEmpty() {
    Column({ space: 12 }) {
      SymbolGlyph($r('sys.symbol.square_and_pencil')).fontSize(32).fontColor([this.shellColor('secondary')])
      Text('还没有笔记或高亮').fontSize(16).fontColor(this.shellColor('text'))
      Text('阅读时选择文字，即可写笔记或添加高亮。').fontSize(14).fontColor(this.shellColor('secondary'))
        .textAlign(TextAlign.Center)
    }.id('reader-notes-empty').width('100%').padding({ top: 16, bottom: 24, left: 12, right: 12 })
  }

  @Builder private notesContent(native: boolean) {
    if (native) {
      Scroll(this.notesScroller) {
        Column({ space: 4 }) {
          if (this.panelRecords('notes').length === 0) { this.notesEmpty() }
          ForEach(this.panelRecords('notes'), (entry: ReadingListEntry) => {
            this.noteRecordEntry(entry)
          }, (entry: ReadingListEntry): string => entry.id)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.id('reader-record-list').width('100%').constraintSize({ maxHeight: this.browseContentMaxHeight() })
        .initialOffset({ xOffset: 0, yOffset: this.notesInitialOffset })
        .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
        .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
    } else {
      if (this.panelRecords('notes').length === 0) { this.notesEmpty() }
      List({ space: 4 }) {
        ForEach(this.panelRecords('notes'), (entry: ReadingListEntry) => {
          ListItem() { this.noteRecordEntry(entry) }
        }, (entry: ReadingListEntry): string => entry.id)
      }.id('reader-record-sidebar-list').width('100%').layoutWeight(1).scrollBar(BarState.Auto).scrollBarWidth(2)
        .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
    }
  }

  private browseContentMaxHeight(): number { return Math.max(96, this.readerViewportHeightVp() * 0.78 - 120); }

  private prepareTocInitialOffset(): void {
    const ui = this.getUIContext(), measure = ui.getMeasureUtils();
    const sheetWidth = this.readerViewportWidthVp() >= 600 ? 480 : this.readerViewportWidthVp();
    const singleLine = Number(measure.measureTextSize({ textContent: '目录', fontSize: '16fp' }).height);
    let total = 0, currentTop = 0, currentHeight = 48;
    this.chapters.forEach((chapter: Chapter, index: number): void => {
      const current = this.isCurrentChapter(chapter);
      const indent = Math.min(4, Math.max(0, chapter.depth ?? 0)) * 16;
      const text = measure.measureTextSize({ textContent: chapter.label, fontSize: '16fp',
        fontWeight: current ? FontWeight.Medium : FontWeight.Regular,
        constraintWidth: Math.max(1, sheetWidth - 40 - 24 - indent) + 'vp' });
      const lines = Math.max(1, Math.round(Number(text.height) / singleLine));
      const height = Math.max(48, lines * 24 + 24);
      if (current) { currentTop = total; currentHeight = height; }
      total += height + (index < this.chapters.length - 1 ? 2 : 0);
    });
    const viewport = this.browseContentMaxHeight();
    // Seed the native Scroll's first layout; never move an already visible sheet.
    this.tocInitialOffset = Math.max(0, Math.min(total - viewport, currentTop - (viewport - currentHeight) / 2));
  }

  @Builder private nativeBrowseContent() {
    Column({ space: 16 }) {
      Row() {
        Text(this.readerSheetSurface === 'toc' ? '目录' : '阅读进度').id('reader-browse-title')
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.shellColor('text')).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.shellColor('secondary')]) }
          .id('reader-browse-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText(this.readerSheetSurface === 'toc' ? '关闭目录' : '关闭阅读进度')
          .onClick((): void => this.dismissReaderPanel(true))
      }.width('100%')
      if (this.readerSheetSurface === 'toc') {
        Scroll() {
          Column({ space: 2 }) {
            if (this.chapters.length === 0) {
              Text('本书没有可用目录').fontSize(14).fontColor(this.shellColor('secondary')).width('100%').padding(12)
            }
            ForEach(this.chapters, (chapter: Chapter) => {
              Button() {
                Text(chapter.label).fontSize(16).lineHeight(24).textAlign(TextAlign.Start).width('100%')
                  .fontWeight(this.isCurrentChapter(chapter) ? FontWeight.Medium : FontWeight.Regular)
                  .fontColor(this.isCurrentChapter(chapter) ? this.shellColor('accent') : this.shellColor('text'))
              }.id(this.isCurrentChapter(chapter) ? 'reader-toc-current-chapter' : 'reader-toc-chapter')
                .width('100%').constraintSize({ minHeight: 48 }).type(ButtonType.Normal)
                .padding({ left: 12 + Math.min(4, Math.max(0, chapter.depth ?? 0)) * 16, right: 12, top: 12, bottom: 12 })
                .borderRadius(12).backgroundColor(this.isCurrentChapter(chapter) ? this.readerMutedColor() : Color.Transparent)
                .accessibilityText(chapter.label)
                .onClick((): void => { this.controller.goToChapter(chapter.href); this.dismissReaderPanel(true); })
            }, (chapter: Chapter): string => chapter.id)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.id('reader-toc-list').width('100%').constraintSize({ maxHeight: this.browseContentMaxHeight() })
          .initialOffset({ xOffset: 0, yOffset: this.tocInitialOffset })
          .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
          .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
      } else {
        Scroll() {
          Column({ space: 12 }) {
            Text(this.chapterTitle()).id('reader-progress-chapter').fontSize(17).lineHeight(26)
              .fontColor(this.shellColor('text')).width('100%')
            Text(this.location?.percentage === undefined ? '进度正在计算' : '近似进度 ' + this.approximateProgressPercentage())
              .id('reader-progress-revealed').fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
            if (this.linkState.canReturn) {
              Button('返回原阅读位置').id('reader-return-from-link').height(48).fontSize(14)
                .type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL).backgroundColor(Color.Transparent)
                .fontColor(this.shellColor('accent')).padding({ left: 0, right: 12 })
                .onClick((): void => { this.controller.returnFromInternalLink(); this.dismissReaderPanel(true); })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').constraintSize({ maxHeight: this.browseContentMaxHeight() }).align(Alignment.TopStart)
          .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
      }
    }.id('reader-native-browse-panel').width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }
  private panelRecords(surface: ReaderSurface): ReadingListEntry[] {
    return this.readingListEntries().filter((entry: ReadingListEntry): boolean =>
      surface === 'bookmarks' ? entry.kind === 'page' : entry.kind !== 'page');
  }
  @Builder
  private auxiliaryPanel() {
    Column({ space: 12 }) {
      Row() {
        Text(this.panelTitle()).id('reader-panel-title').fontSize(20).fontWeight(FontWeight.Medium)
          .fontColor(this.shellColor('text')).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).focusable(true).fontSize(22).fontColor([this.shellColor('text')]) }
          .id('reader-panel-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('关闭' + this.panelTitle()).onClick((): void => this.dismissReaderPanel(true))
          .onAppear((): void => {
            if (this.pendingNoteFocusKey.length === 0) {
              try { this.getUIContext().getFocusController().requestFocus('reader-panel-close'); } catch (_) {}
            }
          })
      }.width('100%')
      if (this.bookmarkMessage.length > 0 && this.currentSurface !== 'appearance') {
        Text(this.bookmarkMessage).id('reader-bookmark-message').fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
      }
      if (this.currentSurface === 'appearance' && this.appearanceMessage) {
        Text(this.appearanceMessage).id('reader-appearance-message').fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
      }
      this.auxiliaryContent()
    }.id('reader-auxiliary-panel').width(this.panelWidth()).height(this.panelHeight()).padding(16)
      .backgroundColor(this.shellColor('surface')).borderRadius({ topLeft: 16, topRight: 16 })
      .hitTestBehavior(HitTestMode.Default).transition(this.auxiliaryPanelTransition(), (transitionIn: boolean): void => {
        // Return focus after the native entering transition has completed.
        // The completion callback concerns focus only, never reader-ready.
        if (!transitionIn || !this.isAuxiliaryPanel() || !this.pendingNoteFocusKey) return;
        this.noteFocusRequested = false;
        this.restoreNoteRowFocus(this.pendingNoteFocusKey);
      })
      .layoutGravity(this.isSideReaderPanel() ? LocalizedAlignment.TOP_END : LocalizedAlignment.BOTTOM)
  }

  @Builder private dictionaryContent() {
        DictionarySheet({
          nativeContainer: true,
          maxContentHeight: this.browseContentMaxHeight(),
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
          selectionActionsAvailable: false,
          onCopy: (): void => { this.copySelectedWord().catch((): void => {}); },
          onHighlight: (): void => { this.requestWordTextMark('highlight'); },
          onNote: (): void => { this.requestWordTextMark('note'); },
          onSaveRange: (): void => { this.requestWordTextMark('adjust'); },
          onToggleExpanded: (): void => { this.dictionaryExpanded = !this.dictionaryExpanded; },
          onDismiss: (): void => { this.dismissDictionary(true); }
        }).width('100%')
  }

  @Builder private readerSheetContent() {
    WithTheme({ colorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
      theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
        fontSecondary: this.shellColor('secondary') } } }) {
      if (this.readerSheetSurface === 'note-editor') {
        this.noteEditorContent()
      } else if (this.readerSheetSurface === 'dictionary') {
        Column() { this.dictionaryContent() }.width('100%').padding(20)
      } else if (this.readerSheetSurface === 'toc' || this.readerSheetSurface === 'progress') {
        this.nativeBrowseContent()
      } else if (this.readerSheetSurface === 'appearance') {
        this.nativeAppearanceContent()
      } else if (this.readerSheetSurface === 'bookmarks' || this.readerSheetSurface === 'notes') {
        this.nativeRecordListContent()
      }
    }
  }

  @Builder private nativeRecordListContent() {
    Column({ space: 16 }) {
      Row() {
        Text(this.readerSheetSurface === 'bookmarks' ? '书签' : '笔记与独立高亮')
          .id(this.readerSheetSurface === 'bookmarks' ? 'reader-bookmarks-title' : 'reader-panel-title')
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.shellColor('text')).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.shellColor('secondary')]) }
          .id(this.readerSheetSurface === 'bookmarks' ? 'reader-bookmarks-close' : 'reader-panel-close')
          .width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText(this.readerSheetSurface === 'bookmarks' ? '关闭书签' : '关闭笔记与独立高亮')
          .onClick((): void => this.dismissReaderPanel(true))
      }.width('100%')
      if (this.bookmarkMessage.length > 0) {
        Text(this.bookmarkMessage).id('reader-bookmarks-message').fontSize(14).fontColor(this.shellColor('secondary')).width('100%')
      }
      if (this.readerSheetSurface === 'bookmarks') { this.bookmarkContent() }
      else { this.notesContent(true) }
    }.id('reader-native-record-panel').width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }

  @Builder private bookmarkEntryMenu(entry: ReadingListEntry) {
    Menu() {
      MenuItem({ content: '删除书签' }).id('reader-bookmark-delete').enabled(!this.bookmarkBusy)
        .contentFontColor(this.readerDangerColor()).onClick((): void => {
          if (entry.point) this.removeBookmark(entry.point).catch((): void => {});
        })
    }
  }

  @Builder private noteEntryMenu(note: NoteEntry) {
    Menu() {
      if (note.updatedAt !== note.createdAt) {
        MenuItem({ content: '创建于 ' + noteTimestamp(note.createdAt) }).enabled(false)
      }
      MenuItem({ content: '删除笔记' }).id('reader-note-entry-delete').enabled(!this.bookmarkBusy)
        .contentFontColor(this.readerDangerColor()).onClick((): void => this.confirmNoteDeletion(note))
    }
  }

  @Builder private markDetailMoreMenu() {
    Menu() {
      if ((this.selectedTextMark()?.notes?.length ?? 0) === 0) {
        MenuItemGroup() {
          MenuItem({ content: '调整高亮范围' }).id('reader-mark-detail-adjust').enabled(!this.bookmarkBusy)
            .onClick((): void => { const mark = this.selectedTextMark(); if (mark) this.beginAdjustMark(mark); })
        }
      }
      MenuItemGroup() {
        MenuItem({ content: '移除独立高亮' }).id('reader-mark-detail-delete').enabled(!this.bookmarkBusy)
          .contentFontColor(this.readerDangerColor()).onClick((): void => {
            const mark = this.selectedTextMark(); if (mark) this.confirmHighlightRemoval(mark);
          })
      }
    }
  }

  @Builder
  private noteEditorContent() {
    Column({ space: 12 }) {
      Text(this.editingNoteEntryId.length > 0 ? '编辑笔记' : '写笔记')
        .fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.shellColor('text')).width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 6 }) {
            Text('原文').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
            Text(this.noteOriginalQuote).id('reader-note-editor-original-quote')
              .fontSize(14).fontColor(this.shellColor('text')).width('100%')
              .maxLines(this.noteQuoteExpanded ? 10000 : 3).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.noteOriginalQuote.length > 80 || this.noteOriginalQuote.includes('\n')) {
              Button(this.noteQuoteExpanded ? '收起原文' : '展开原文').id('reader-note-quote-expand')
                .height(40).buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.shellColor('accent'))
                .onClick((): void => { this.noteQuoteExpanded = !this.noteQuoteExpanded; })
            }
            if (this.editingNoteSnapshot?.anchorProvenance === 'legacy-group') {
              Text('这条历史笔记的原文位置无法恢复，引用和笔记已保留。')
                .id('reader-note-editor-origin-unavailable').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
            }
          }.width('100%').padding({ top: 4, bottom: 4 })
          Column({ space: 8 }) {
            TextArea({ placeholder: '写下你的想法', text: this.noteDraft })
              .id('reader-note-input').width('100%').height(200).constraintSize({ minHeight: 144 })
              .fontSize(16).fontColor(this.shellColor('text')).placeholderColor(this.shellColor('secondary'))
              .backgroundColor(this.readerMutedColor()).borderRadius(12).padding(12)
              .enabled(!this.bookmarkBusy && this.noteCommitKind === 'none').maxLength(2000)
              .onFocus((): void => this.pageController.readOnlyObservation?.focusObserved('note-input'))
              .onChange((value: string): void => { this.noteDraft = value; })
          }.width('100%')
          if (this.noteFeedback.length > 0) {
            Text(this.noteFeedback).id('reader-note-editor-feedback').fontSize(13)
              .fontColor(this.shellColor('secondary')).width('100%')
          }
          if (this.noteCommitKind !== 'none') {
            Button('重试刷新列表').id('reader-note-refresh').height(48).width('100%')
              .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.shellColor('accent'))
              .enabled(!this.bookmarkBusy).onClick((): void => { this.refreshCommittedNote().catch((): void => {}); })
          }
        }.width('100%')
      }.id('reader-note-editor-scroll').layoutWeight(1).width('100%').align(Alignment.TopStart).scrollBar(BarState.Auto)
      Row({ space: 8 }) {
        Button('取消').id('reader-note-cancel').layoutWeight(1).height(48)
          .buttonStyle(ButtonStyleMode.NORMAL).fontColor(this.shellColor('text')).backgroundColor(this.readerMutedColor())
          .enabled(!this.bookmarkBusy).onClick((): void => this.requestCloseNoteEditor())
        Button('保存笔记').id('reader-note-save').layoutWeight(1).height(48)
          .buttonStyle(ButtonStyleMode.EMPHASIZED).backgroundColor(this.shellColor('accent'))
          .fontColor(this.settings.theme === 'dark' ? $r('app.color.reader_on_accent_dark') :
            this.settings.theme === 'eye-comfort' ? $r('app.color.reader_on_accent_eye_comfort') : $r('app.color.reader_on_accent_light'))
          .enabled(this.noteDraft.trim().length > 0 && !this.bookmarkBusy && this.noteCommitKind === 'none')
          .onClick((): void => this.savePendingNote())
      }.width('100%')
    }.id('reader-note-editor').width('100%').height('100%').padding({ left: 20, right: 20, top: 8, bottom: 16 })
  }

  private detailQuoteBackground(): ResourceColor {
    if (this.settings.theme === 'eye-comfort') return this.readerMutedColor();
    return this.settings.theme === 'dark' ? '#12FFFFFF' : '#07182431';
  }

  @Builder private detailQuote(text: string, id: string, prominent: boolean = false) {
    Column({ space: 6 }) {
      Text('原文').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
      Text(text).id(id).fontSize(prominent ? 17 : 14).lineHeight(prominent ? 27 : 22)
        .fontColor(prominent ? this.shellColor('text') : this.shellColor('secondary')).width('100%')
    }.width('100%').alignItems(HorizontalAlign.Start).padding(12)
      .backgroundColor(this.detailQuoteBackground()).borderRadius(12)
  }

  @Builder private detailAddNote() {
    Button() {
      Row({ space: 6 }) {
        SymbolGlyph($r('sys.symbol.plus')).fontSize(14).fontColor([this.shellColor('accent')])
        Text((this.selectedTextMark()?.notes?.length ?? 0) > 0 ? '另写一条笔记' : '添加笔记')
          .fontSize(14).fontColor(this.shellColor('accent'))
      }
    }.id('reader-mark-detail-edit').height(48).type(ButtonType.Normal)
      .buttonStyle(ButtonStyleMode.TEXTUAL).backgroundColor(Color.Transparent)
      .padding({ left: 4, right: 12 }).borderRadius(12).enabled(!this.bookmarkBusy)
      .onAppear((): void => this.restoreNoteRowFocus('reader-mark-detail-edit'))
      .onAreaChange((_old: Area, area: Area): void => {
        if (this.areaLength(area.width) > 0 && this.areaLength(area.height) > 0)
          this.restoreNoteRowFocus('reader-mark-detail-edit', true);
      })
      .onFocus((): void => {
        this.pageController.readOnlyObservation?.focusObserved('mark-detail');
        if (this.pendingNoteFocusKey === 'reader-mark-detail-edit') {
          this.pendingNoteFocusKey = ''; this.noteFocusRequested = false;
        }
      })
      .onClick((): void => { const mark = this.selectedTextMark(); if (mark) this.beginEditMark(mark); })
  }

  @Builder
  private markDetailContent() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        Text((this.selectedTextMark()?.notes?.length ?? 0) > 0 ? '笔记详情' : '高亮详情')
          .fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.shellColor('text')).layoutWeight(1)
        if ((this.selectedTextMark()?.highlightAnchors?.length ?? 0) > 0) {
          Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([this.shellColor('secondary')]) }
            .id('reader-mark-detail-more').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
            .accessibilityText('高亮更多操作').enabled(!this.bookmarkBusy)
            .bindMenu(this.markDetailMoreMenu(), nativeMenuOptions(this.settings.theme === 'eye-comfort' ? undefined : this.menuMaterial,
              { placement: Placement.BottomRight }))
        }
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.shellColor('secondary')]) }
          .id('reader-mark-detail-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('关闭详情')
          .onAppear((): void => this.restoreNoteRowFocus('reader-mark-detail-close'))
          .onAreaChange((_old: Area, area: Area): void => {
            if (this.areaLength(area.width) > 0 && this.areaLength(area.height) > 0)
              this.restoreNoteRowFocus('reader-mark-detail-close', true);
          })
          .onFocus((): void => {
            this.pageController.readOnlyObservation?.focusObserved('mark-detail');
            if (this.pendingNoteFocusKey === 'reader-mark-detail-close') {
              this.pendingNoteFocusKey = ''; this.noteFocusRequested = false;
            }
          })
          .onClick((): void => this.closeMarkDetail())
      }.width('100%')
      Scroll() {
        Column({ space: 20 }) {
          Column({ space: 4 }) {
            Text(this.currentBook.title).fontSize(13).fontColor(this.shellColor('secondary')).width('100%')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            if (this.selectedTextMark()?.chapterTitle && this.selectedTextMark()?.chapterTitle !== this.currentBook.title) {
              Text(this.selectedTextMark()?.chapterTitle ?? '').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
          if (this.orphanMarkIds.includes(this.selectedMarkId)) {
            Text('暂时无法定位原文，原文引用和笔记仍保留。').fontSize(13)
              .fontColor(this.readerDangerColor()).width('100%')
          }
          if ((this.selectedTextMark()?.notes?.length ?? 0) > 0) {
            ForEach(this.selectedNoteEntries(), (note: NoteEntry) => {
              Column({ space: 12 }) {
                this.detailQuote(note.originalAnchor.exactText, 'reader-note-original-quote')
                Text(note.body).id('reader-note-body').fontSize(17).lineHeight(27)
                  .fontColor(this.shellColor('text')).width('100%')
                Text(noteTime(note)).id('reader-note-time').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
                if (note.anchorProvenance === 'legacy-group') {
                  Text('这条历史笔记的原文位置无法恢复，引用和笔记已保留。')
                    .id('reader-note-origin-unavailable').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
                } else if (note.anchorStatus !== 'verified') {
                  Text(note.anchorStatus === 'unchecked' ? '原文位置将在跳转时核对' : '暂时无法定位原文，引用和笔记已保留。')
                    .id('reader-note-anchor-state').fontSize(12).fontColor(this.shellColor('secondary')).width('100%')
                }
                Row({ space: 4 }) {
                  Button('返回原文').id('reader-note-entry-jump').height(48)
                    .buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).fontColor(this.shellColor('accent'))
                    .type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(12).padding({ left: 4, right: 12 })
                    .enabled(!this.bookmarkBusy && note.anchorProvenance !== 'legacy-group')
                    .onClick((): void => this.jumpNote(note))
                  Button('编辑笔记').id('reader-note-entry-edit').height(48)
                    .buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).fontColor(this.shellColor('accent')).enabled(!this.bookmarkBusy)
                    .type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(12).padding({ left: 12, right: 12 })
                    .onClick((): void => { const mark = this.selectedTextMark(); if (mark) this.beginEditMark(mark, note); })
                  Blank().layoutWeight(1)
                  Button() { SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize(20).fontColor([this.shellColor('secondary')]) }
                    .id('reader-note-entry-more').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
                    .accessibilityText('笔记更多操作').enabled(!this.bookmarkBusy)
                    .bindMenu(this.noteEntryMenu(note), nativeMenuOptions(this.settings.theme === 'eye-comfort' ? undefined : this.menuMaterial,
                      { placement: Placement.TopRight }))
                }.width('100%')
                Divider().color(this.readerMutedColor()).strokeWidth(0.5).margin({ top: 4 })
              }.id(`reader-note-entry-${note.noteId}`).width('100%').focusable(true)
                .onAppear((): void => this.restoreNoteRowFocus('reader-note-entry-' + note.noteId))
                .onAreaChange((_old: Area, area: Area): void => {
                  if (this.areaLength(area.width) > 0 && this.areaLength(area.height) > 0)
                    this.restoreNoteRowFocus('reader-note-entry-' + note.noteId, true);
                })
                .onFocus((): void => {
                  this.pageController.readOnlyObservation?.focusObserved('note-entry');
                  if (this.pendingNoteFocusKey === 'reader-note-entry-' + note.noteId) {
                    this.pendingNoteFocusKey = ''; this.noteFocusRequested = false;
                  }
                })
            }, (note: NoteEntry): string => note.noteId)
          } else {
            this.detailQuote(this.selectedTextMark()?.exactText ?? '', 'reader-highlight-original-quote', true)
            Row({ space: 8 }) {
            Button('返回原文').id('reader-mark-detail-jump').height(48)
              .buttonStyle(ButtonStyleMode.TEXTUAL).fontSize(14).fontColor(this.shellColor('accent'))
              .type(ButtonType.Normal).backgroundColor(Color.Transparent).borderRadius(12).padding({ left: 4, right: 12 })
              .enabled(!this.bookmarkBusy)
              .onClick((): void => {
                const mark = this.selectedTextMark();
                if (mark) {
                  this.orphanMarkIds = this.orphanMarkIds.filter((id: string): boolean => id !== mark.markId);
                  this.jumpTextMark(mark);
                }
              })
              this.detailAddNote()
            }.width('100%')
          }
          if (this.noteFeedback.length > 0) {
            Text(this.noteFeedback).id('reader-mark-detail-feedback').fontSize(13).fontColor(this.readerDangerColor()).width('100%')
            Button('刷新列表').id('reader-mark-detail-refresh').height(48).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(!this.bookmarkBusy).onClick((): void => { this.reloadTextMarks(this.currentSessionId).then((): void => {
                this.noteFeedback = '';
              }).catch((): void => { this.noteFeedback = '列表刷新失败，现有记录已保留，请重试。'; }); })
          }
          if ((this.selectedTextMark()?.notes?.length ?? 0) > 0) { this.detailAddNote() }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.id('reader-note-entries').width('100%')
        .constraintSize({ maxHeight: Math.max(96, this.readerViewportHeightVp() * 0.78 - 156) })
        .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
        .scrollBarColor(this.settings.theme === 'dark' ? '#40FFFFFF' : '#33182431')
    }.id('reader-mark-detail').width('100%').constraintSize({ maxHeight: this.readerViewportHeightVp() * 0.78 })
  }

  build() {
    WithTheme({ colorMode: this.settings.theme === 'dark' ? ThemeColorMode.DARK : ThemeColorMode.LIGHT,
      theme: { colors: { brand: this.shellColor('accent'), fontPrimary: this.shellColor('text'),
        fontSecondary: this.shellColor('secondary'), backgroundPrimary: this.shellColor('surface'),
        compBackgroundPrimary: this.shellColor('surface') } } }) {
    Stack({ alignContent: Alignment.Center }) {
      ReaderFourSurfaceView({
        menuMaterial: this.menuMaterial,
        publication: this.session.publication,
        book: this.currentBook,
        animateCustomMotion: this.animateCustomMotion,
        initialLocation: this.hostInitialLocation,
        settings: this.effectiveReaderSettings(this.settings),
        sessionId: this.currentSessionId,
        debugClipPaginationOverride: this.debugClipPaginationOverride,
        controller: this.controller,
        readOnlyObservation: this.pageController.readOnlyObservation,
        selectionMenuMarks: this.savedTextMarks.map((mark: TextMarkRecord): ReaderTextMark => readerTextMark(mark)),
        selectionMenuAdjusting: this.adjustingMarkId.length > 0,
        onCandidateStage: (stage: string): void => { SafeLog.readerCandidateFailure(stage); },
        callbacks: {
          onReady: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId) return;
            const firstReady = !this.bookmarkReady;
            this.bookmarkReady = true;
            this.refreshBookmarks(eventSessionId).catch((): void => {});
            const initialBookmark = this.pendingInitialBookmark;
            this.pendingInitialBookmark = undefined;
            if (initialBookmark !== undefined) this.jumpBookmark(initialBookmark);
            else this.controller.requestLocation();
            this.onReady(eventSessionId);
            if (firstReady) this.controller.focusContent();
          },
          onBookmarkJumpResult: (eventSessionId: number, bookmarkId: string, success: boolean): void => {
            if (eventSessionId !== this.currentSessionId || this.pendingBookmarkId !== bookmarkId) return;
            this.pendingBookmarkId = '';
            if (success) {
              this.currentSurface = 'none';
              this.bookmarkMessage = '';
            } else {
              this.bookmarkMessage = '无法定位此书签，请检查书籍内容。';
              this.currentSurface = 'bookmarks';
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
              this.currentSurface = 'notes';
            }
          },
          onTextMarkResolution: (eventSessionId: number, markId: string, resolution): void => {
            if (eventSessionId !== this.currentSessionId) return;
            const note = this.savedTextMarks.flatMap((mark: TextMarkRecord): NoteEntry[] => mark.notes ?? [])
              .find((entry: NoteEntry): boolean => entry.noteId === markId);
            if (note) {
              if (resolution.revision !== undefined && note.revision !== resolution.revision) return;
              this.retainNoteStatus(note.noteId,note.revision,resolution.status === 'orphaned' ? resolution.reason ?? 'unavailable' : 'verified',eventSessionId).catch((): void => {});
              return;
            }
            const record = this.savedTextMarks.find((mark: TextMarkRecord): boolean => mark.markId === markId);
            if (!record || (resolution.revision !== undefined && (record.revision ?? 1) !== resolution.revision)) return;
            this.retainAnchorStatus(markId, resolution.status === 'orphaned' ? resolution.reason ?? 'unavailable' : 'verified',
              eventSessionId).catch((): void => {});
            if (resolution.status === 'orphaned') {
              if (resolution.reason === 'missing' || resolution.reason === 'ambiguous' || resolution.reason === 'unavailable') {
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
          onNoteAnchorResolution: (eventSessionId: number,noteId: string,revision: number,resolution): void => {
            this.retainNoteStatus(noteId,revision,resolution.status === 'orphaned' ? resolution.reason ?? 'unavailable' : 'verified',eventSessionId).catch((): void => {});
          },
          onTextMarkTap: (eventSessionId: number, markId: string, rect: ReaderSelectionRect): void => {
            this.traceNoteOverlay('page-mark-tap', this.savedTextMarks.length, eventSessionId === this.currentSessionId &&
              this.savedTextMarks.some((mark: TextMarkRecord): boolean => mark.markId === markId));
            if (eventSessionId !== this.currentSessionId ||
              !this.savedTextMarks.some((mark: TextMarkRecord): boolean => mark.markId === markId)) return;
            if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
            this.noteFeedback = '';
            this.markDetailReturnSurface = 'none'; this.markDetailReturnRowId = '';
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
          onSelectionAction: (eventSessionId: number, action: 'copy' | 'note' | 'translate',
            token: string, selectedText: string, locator: string, complete?: () => void): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.nativeSelectionAction(action, token, selectedText, locator, complete);
          },
          onSelectionMarkContext: (eventSessionId: number, context: ReadingSelectionContext): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
            this.acceptMarkContext(context, 'highlight');
          },
          onWordSelection: (eventSessionId: number, selection: ReaderWordSelection): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
            this.hasUncommittedSelection = true;
            this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined; this.nativeTranslationResult = false;
            this.dismissReaderPanel(); this.dismissDictionary(false); this.dismissPassage(false);
            this.dictionarySelection = selection;
            this.onWordSelection(selection);
          },
          onPassageSelection: (eventSessionId: number, selection: PassageSelectionCandidate): void => {
            if (eventSessionId !== this.currentSessionId) return;
            if (this.currentSurface === 'note-editor') { this.requestCloseNoteEditor(); return; }
            this.hasUncommittedSelection = true;
            this.nativeNoteToken = ''; this.nativeAdjustRequest = undefined; this.nativeTranslationResult = false;
            this.dismissReaderPanel(); this.dismissDictionary(false); this.dismissPassage(false);
            this.passageCandidate = selection;
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
          onSelectionCleared: (eventSessionId: number, cause?: 'cancel' | 'presentation'): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.handleSelectionCleared(cause);
          },
          onSelectionGeometryChanged: (eventSessionId: number, selectionToken: string,
            geometry: ReaderSelectionGeometry): void => {
            if (eventSessionId !== this.currentSessionId) return;
            this.updateSelectionGeometry(selectionToken, geometry);
          },
          onControlsToggle: (eventSessionId: number): void => {
            if (eventSessionId !== this.currentSessionId || this.settingsCovered || this.currentSurface === 'note-editor') return;
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
            if (eventSessionId !== this.currentSessionId || this.settingsCovered) return;
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

        if (this.showControlsButton) {
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
      }

      if (this.controlsVisible && this.currentSurface === 'none') {
        this.readerTopBar()
        this.readerBottomBar()
      }
      if (this.isAuxiliaryPanel() && !this.isNativeReaderSheet(this.currentSurface) && !this.markDetailPresented && !this.readerSheetPresented) {
        Column() {}.id('reader-panel-scrim').width('100%').height('100%')
          .backgroundColor(this.isSideReaderPanel() ? Color.Transparent : $r('app.color.product_scrim'))
          .transition(this.auxiliaryScrimTransition())
          .hitTestBehavior(HitTestMode.Block).onClick((): void => this.dismissReaderPanel(true))
        this.auxiliaryPanel()
      }

      if (this.errorText.length > 0) {
        ReaderErrorNotice({ message: this.errorText, theme: this.settings.theme, dismissible: this.navigationError,
          onDismiss: (): void => {
            if (this.navigationError) {
              this.navigationError = false;
              this.errorText = '';
            }
          } })
          .id(this.navigationError ? 'reader-navigation-error' : 'reader-fatal-error')
          .transition(this.readerSurfaceTransition())
          .align(Alignment.Center)
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


    }.id('reader-content-root').width('100%').height('100%')
        .bindSheet($$this.readerSheetVisible, this.readerSheetContent(), nativeSheetOptions(
          this.settings.theme === 'eye-comfort' ? undefined : this.panelMaterial, {
            height: this.readerSheetSurface === 'note-editor' ? SheetSize.MEDIUM : SheetSize.FIT_CONTENT,
            detents: this.readerSheetSurface === 'note-editor' ? [SheetSize.MEDIUM, SheetSize.LARGE] : [SheetSize.FIT_CONTENT],
            detentSelection: this.readerSheetSurface === 'note-editor' ?
              (this.noteKeyboardVisible ? SheetSize.LARGE : this.noteSheetDetent) : undefined,
            onDetentsDidChange: (height: number): void => {
              if (this.readerSheetSurface !== 'note-editor' || this.noteKeyboardVisible) return;
              // Native detents use the window height in physical px, not the reader content viewport.
              const heightVp = this.getUIContext().px2vp(height);
              const detent = heightVp > this.windowSnapshot.heightVp * 0.7 ? SheetSize.LARGE : SheetSize.MEDIUM;
              // Ignore the keyboard's automatic large detent until native restoration completes.
              if (this.noteSheetAutoExpanded) {
                if (detent === SheetSize.MEDIUM) this.noteSheetAutoExpanded = false;
                return;
              }
              this.noteSheetDetent = detent;
            },
            preferType: this.readerViewportWidthVp() >= 600 ? SheetType.CENTER : SheetType.BOTTOM, showClose: false, dragBar: true,
            width: this.readerSheetSurface === 'toc' && this.readerViewportWidthVp() >= 600 ? 480 : undefined,
            backgroundColor: this.panelMaterial !== undefined && this.settings.theme !== 'eye-comfort' ? Color.Transparent : this.shellColor('surface'),
            keyboardAvoidMode: SheetKeyboardAvoidMode.RESIZE_ONLY,
            onAppear: (): void => {
              this.traceNoteOverlay('sheet-open');
              this.readerSheetPresented = true;
              if (this.currentSurface === 'note-editor') this.requestNoteFocus('reader-note-input');
              else if (this.currentSurface === 'notes' && this.pendingNoteFocusKey) this.restoreNoteRowFocus(this.pendingNoteFocusKey);
            },
            onDisappear: (): void => {
              this.traceNoteOverlay('sheet-closed');
              const dismissedSurface = this.readerSheetSurface;
              this.readerSheetPresented = false;
              this.readerSheetSurface = 'none';
              if (dismissedSurface === 'dictionary' && this.currentSurface !== 'dictionary') this.clearDictionaryPresentation();
              this.noteSheetDetent = SheetSize.MEDIUM;
              this.noteSheetAutoExpanded = false;
              this.syncReaderOverlays();
              if (this.pendingNoteFocusKey) this.restoreNoteRowFocus(this.pendingNoteFocusKey);
              // A programmatic close (including the dictionary's X) also releases native focus.
              if (this.currentSurface === 'none' && !this.exiting) {
                if (this.panelFocusReturn) this.restorePanelFocus(this.panelFocusReturn);
                else this.controller.focusContent();
              }
            },
            onWillDismiss: (action: DismissSheetAction): void => {
              if (this.bookmarkBusy) return;
              if (this.currentSurface === 'note-editor') this.requestCloseNoteEditor((): void => action.dismiss());
              else {
                if (this.currentSurface === 'dictionary') this.dismissDictionary(true);
                else if (this.isAuxiliaryPanel()) this.dismissReaderPanel(true);
                action.dismiss();
              }
            }
          }))
      .visibility(this.settingsCovered ? Visibility.Hidden : Visibility.Visible)
      .enabled(!this.settingsCovered)
      .hitTestBehavior(this.settingsCovered ? HitTestMode.None : HitTestMode.Default)
      .onVisibleAreaChange([0.01], (visible: boolean, _ratio: number): void => {
        if (visible) this.restoreSettingsFocus();
      })
      .onKeyEvent((event: KeyEvent): boolean => {
        if (this.settingsCovered) return false;
        if (event.type !== KeyType.Up || event.keyCode !== KeyCode.KEYCODE_F8 || this.currentSurface === 'note-editor') return false;
        this.setControlsVisible(!this.controlsVisible); return true;
      })
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
}
