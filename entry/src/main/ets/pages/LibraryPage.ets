import { common } from '@kit.AbilityKit';
import deviceInfo from '@ohos.deviceInfo';
import { NativeSelectMenuMaterial, nativeMenuOptions } from '../platform/NativeOverlayMaterial';
import { recordTime } from '../application/ReadingRecordsApplication';
import { ReaderAppearanceApplication } from '../application/ReaderAppearanceApplication';
import { FrameCallback } from '@kit.ArkUI';
import { CustomContentDialog } from '@ohos.arkui.advanced.Dialog';
import { READER_DIAGNOSTICS_ENABLED } from 'BuildProfile';
import { LibraryBrowseSnapshot, libraryBrowseObservation } from '../diagnostics/LibraryBrowseObservation';
import { KeyCode } from '@kit.InputKit';
import { LibraryPresentationApplication } from '../application/LibraryPresentationApplication';
import { BookmarkApplication } from '../application/BookmarkApplication';
import { LibraryOrganizationApplication } from '../application/LibraryOrganizationApplication';
import { projectBookCard, projectFolderCards, FolderCardProjection } from '../application/LibraryCardProjection';
import { LibraryFolder, BookOrganization, folderSubtree } from '../domain/LibraryOrganization';
import { ProductStatePanel } from '../components/ProductStatePanel';
import { LibraryBookGridCard, LibraryFolderGridCard } from '../components/LibraryGridItems';
import { BookshelfBackground } from '../components/BookshelfBackground';
import { BookshelfDefaultMode, BookshelfTheme, LibraryViewMode } from '../domain/LibraryPresentation';
import { bookshelfColor, bookshelfThemeColorMode } from '../layout/BookshelfThemePalette';
import { Book, BookmarkPoint } from '../domain/Models';
import { filterAndSortLibraryLevel, filterLibraryChildFolders, LibraryEntry, LibrarySort } from '../services/LibraryQueryService';
import { LibraryBrowseState, createLibraryBrowseState, copyLibraryBrowseState, enterLibraryFolder, returnLibraryParent, reconcileLibraryFolder } from '../shell/LibraryBrowseState';
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT
 } from '../layout/AdaptiveLayoutPolicy';
import { LibraryGridGeometry, libraryGridGeometry, LIBRARY_COLUMN_GAP_VP, LIBRARY_ROW_GAP_VP,
  LIBRARY_PAGE_INSET_VP, LIBRARY_SYMBOL_SIZE_VP, LIBRARY_ZERO_PADDING_VP } from '../layout/LibraryGridLayout';

interface LibraryMoveTargets {
  folders: LibraryFolder[];
  paths: Map<string, string>;
  options: SelectOption[];
}

class LibrarySourceFocusFrame extends FrameCallback {
  private action: () => void;
  constructor(action: () => void) { super(); this.action = action; }
  onIdle(_timeLeftInNano: number): void { this.action(); }
}

// API 21 List and constraintSize signatures require numeric vp values rather than Resource objects.
const LIBRARY_LIST_GAP_VP: number = 12;
const LIBRARY_SELECTION_LABEL_FP: number = 16;
const LIBRARY_MODAL_MAX_WIDTH_VP: number = 340;

class LibraryGridItem {
  constructor(folder: LibraryFolder | undefined, entry: LibraryEntry | undefined) {
    this.folder = folder; this.entry = entry;
    this.key = folder !== undefined ? 'folder:' + folder.folderId : 'book:' + (entry?.book.bookId ?? '');
  }
  folder?: LibraryFolder;
  entry?: LibraryEntry;
  key: string;
}
class LibraryGridSource implements IDataSource {
  private items: LibraryGridItem[];
  constructor(items: LibraryGridItem[]) { this.items = items; }
  totalCount(): number { return this.items.length; }
  getData(index: number): LibraryGridItem { return this.items[index]; }
  private listeners: DataChangeListener[] = [];
  update(items: LibraryGridItem[]): void {
    this.items = items;
    this.listeners.forEach((listener: DataChangeListener): void => listener.onDataReloaded());
  }
  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) this.listeners.push(listener);
  }
  unregisterDataChangeListener(listener: DataChangeListener): void {
    this.listeners = this.listeners.filter((current: DataChangeListener): boolean => current !== listener);
  }
}

interface LibraryDeleteResult {
  id: string;
  title: string;
  kind: 'book' | 'folder';
  succeeded: boolean;
}
export interface BookDeleteResult {
  bookId: string;
  succeeded: boolean;
}

export interface LibraryPageActions {
  createFolder: () => void;
  enterSelection: () => void;
  setSort: (sort: LibrarySort) => void;
  toggleSearch: () => void;
  parentFolder: () => void;
  enterFolder: (folderId: string) => void;
  handleSystemBack: () => boolean;
}
export class LibraryPageController {
  private actions?: LibraryPageActions = undefined;
  bind(actions: LibraryPageActions): void { this.actions = actions; }
  unbind(): void { this.actions = undefined; }
  createFolder(): void { this.actions?.createFolder(); }
  enterSelection(): void { this.actions?.enterSelection(); }
  setSort(sort: LibrarySort): void { this.actions?.setSort(sort); }
  toggleSearch(): void { this.actions?.toggleSearch(); }
  parentFolder(): void { this.actions?.parentFolder(); }
  enterFolder(folderId: string): void { this.actions?.enterFolder(folderId); }
  handleSystemBack(): boolean { return this.actions?.handleSystemBack() ?? false; }
}

@Component
export struct LibraryPage {
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  @Prop panelMaterial: SystemUiMaterial | undefined = undefined;
  @Prop @Watch('reloadOrganization') entries: LibraryEntry[] = [];
  @Prop @Watch('reloadOrganization') loading: boolean = false;
  @Prop @Watch('activeChanged') active: boolean = true;
  @Prop browse: LibraryBrowseState = createLibraryBrowseState();
  @Prop refreshFailed: boolean = false;
  onBrowseChange: (browse: LibraryBrowseState) => void = (_browse: LibraryBrowseState): void => {};
  onRefresh: () => void = (): void => {};
  @Prop message: string = '';
  @Prop quarantinedOrphanCount: number = 0;
  @Prop @Watch('measureGridTypography') fontSizeScale: number = 1;
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop renderBackground: boolean = true;
  @Prop renderHeader: boolean = true;
  pageController: LibraryPageController = new LibraryPageController();
  presentation?: LibraryPresentationApplication;
  bookmarks?: BookmarkApplication;
  organization?: LibraryOrganizationApplication;
  onImport: () => void = (): void => {};
  onSettings: () => void = (): void => {};
  onSelectionChange: (selected: boolean) => void = (_selected: boolean): void => {};
  onOpen: (book: Book) => void = (_book: Book): void => {};
  onOpenBookmark: (book: Book, point: BookmarkPoint) => void =
    (_book: Book, _point: BookmarkPoint): void => {};
  onDelete: (book: Book) => Promise<boolean> = async (_book: Book): Promise<boolean> => false;
  onDeleteSelected: (books: Book[]) => Promise<BookDeleteResult[]> =
    async (books: Book[]): Promise<BookDeleteResult[]> =>
      books.map((book: Book): BookDeleteResult => ({ bookId: book.bookId, succeeded: false }));
  onRename: (book: Book, title: string, author: string) => Promise<boolean> =
    async (_book: Book, _title: string, _author: string): Promise<boolean> => false;
  onBookSize: (book: Book) => Promise<number | undefined> =
    async (_book: Book): Promise<number | undefined> => undefined;
  onRepair: (book: Book) => void = (_book: Book): void => {};
  onCleanupOrphans: () => void = (): void => {};

  // Saved legacy preference remains readable and unchanged; M4 renders one automatic Grid.
  private legacyViewMode: LibraryViewMode = 'grid';
  private viewMode: LibraryViewMode = 'grid';
  @State private contentWidthVp: number = 1;
  private gridContentMeasured: boolean = false;
  private gridMeasuredWidthVp: number = 0;
  @State private measuredTitleWidthVp: number = 84;
  @State private systemReducedMotion: boolean | undefined = undefined;
  private unsubscribeSystemMotion?: () => void;
  appearanceApplication?: ReaderAppearanceApplication;
  @State private gridGeometry: LibraryGridGeometry = libraryGridGeometry(1, 84);
  @State private organizationFolder?: LibraryFolder = undefined;
  @State private organizationIntent: string = 'create';
  @State private batchMove: boolean = false;
  @State private searchVisible: boolean = false;
  private searchFocusPending: boolean = false;
  @State private detailsEntry?: LibraryEntry = undefined;
  @State private detailsVisible: boolean = false;
  private afterDetailsClose?: () => void;
  @State private bookmarkEntry?: LibraryEntry = undefined;
  @State private bookmarkPoints: BookmarkPoint[] = [];
  @State private bookmarkLoading: boolean = false;
  @State private bookmarkError: string = '';
  @State private bookmarkBusy: boolean = false;
  private bookmarkToastId?: number = undefined;
  private bookmarkToastRequest: number = 0;
  private bookmarkRevision: number = 0;
  private bookmarkReturnFocus: boolean = false;
  private bookmarkDialog: CustomDialogController = this.createBookmarkDialog();
  private createBookmarkDialog(): CustomDialogController {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) {
          return new CustomDialogController({
            systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({ themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.bookmarksContent() }),
          customStyle: false, autoCancel: true,
          onWillDismiss: (action: DismissDialogAction): void => {
            this.bookmarkReturnFocus = true; action.dismiss();
          },
          onDidDisappear: (): void => {
            this.bookmarkEntry = undefined;
            if (this.bookmarkReturnFocus && this.mounted) {
              this.bookmarkReturnFocus = false; this.sourceFocusPending = true; this.returnManagementFocus();
            }
          }
          });
        }
      }
    }
    return new CustomDialogController({
      builder: CustomContentDialog({ themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.bookmarksContent() }),
      customStyle: false, autoCancel: true,
      onWillDismiss: (action: DismissDialogAction): void => {
        this.bookmarkReturnFocus = true; action.dismiss();
      },
      onDidDisappear: (): void => {
        this.bookmarkEntry = undefined;
        if (this.bookmarkReturnFocus && this.mounted) {
          this.bookmarkReturnFocus = false; this.sourceFocusPending = true; this.returnManagementFocus();
        }
      }
    });
  }
  @State private renamingEntry?: LibraryEntry = undefined;
  @State private editTitle: string = '';
  @State private editAuthor: string = '';
  @State private renameSaving: boolean = false;
  @State private renameError: string = '';
  @State private detailSize: string = '';
  private detailRevision: number = 0;
  private renameDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({ primaryTitle: '编辑图书信息', themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.renameForm() }),
    customStyle: false, autoCancel: false,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (this.renameSaving) return;
      action.dismiss();
    },
    onDidDisappear: (): void => { this.renamingEntry = undefined; this.returnManagementFocus(); }
  });

  private openRenameDialog(): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) this.renameDialog = new CustomDialogController({
          systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({ primaryTitle: '编辑图书信息', themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.renameForm() }),
          customStyle: false, autoCancel: false,
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.renameSaving) return;
            action.dismiss();
          },
          onDidDisappear: (): void => { this.renamingEntry = undefined; this.returnManagementFocus(); }
        });
      }
    }
    this.renameDialog.open();
  }
  @State private pendingDelete?: Book = undefined;
  @State @Watch('selectionChanged') private selectionMode: boolean = false;
  @State private selectedBookIds: string[] = [];
  @State private selectedFolderIds: string[] = [];
  @State private batchConfirm: boolean = false;
  @State private batchBusy: boolean = false;
  @State private batchResults: LibraryDeleteResult[] = [];
  private batchBooks: Book[] = [];
  private batchFolders: LibraryFolder[] = [];
  private batchScopeFolders: LibraryFolder[] = [];
  @State private deletionPreparing: boolean = false;
  private mounted: boolean = false;
  private projectionEntries?: LibraryEntry[];
  private projectionContext: string = '';
  private projectedEntries: LibraryEntry[] = [];
  private projectedFolders: LibraryFolder[] = [];
  private moveTargetsCache?: LibraryMoveTargets;
  private gridSource: LibraryGridSource = new LibraryGridSource([]);
  private organizationReadGeneration: number = 0;
  private organizationActionGeneration: number = 0;
  @State private organizationReadFailed: boolean = false;
  @State private folderCards: FolderCardProjection[] = [];
  private gridScroller: Scroller = new Scroller();
  @State private restoredMode: string = '';
  private gridRevealGeneration: number = 0;
  private gridRevealSettled: boolean = false;
  private restoreAnchorContext: string = '';
  private restoreFramePending: boolean = false;
  private sourceFocusPending: boolean = false;
  private sourceFocusScheduled: boolean = false;
  private sourceFocusRejectedAncestor: boolean = false;
  @State private folderEditor: boolean = false;
  @State private organizationBook?: Book = undefined;
  @State private organizationName: string = '';
  @State private organizationTarget: string = '';
  @State private seriesName: string = '';
  @State private volumeOrder: string = '';
  @State private organizationBusy: boolean = false;
  @State private organizationMessage: string = '';
  @State private managementComplete: boolean = false;
  private folderNameDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({
      themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode),
      primaryTitle: this.organizationIntent === 'rename' ? '重命名文件夹' : '新建文件夹',
      contentBuilder: (): void => this.folderNameForm()
    }),
    customStyle: false, autoCancel: false, keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (this.organizationBusy) return;
      action.dismiss();
    },
    onDidDisappear: (): void => this.closeOrganization(true)
  });

  private openFolderNameDialog(): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) this.folderNameDialog = new CustomDialogController({
          systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({
            themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode),
            primaryTitle: this.organizationIntent === 'rename' ? '重命名文件夹' : '新建文件夹',
            contentBuilder: (): void => this.folderNameForm()
          }),
          customStyle: false, autoCancel: false, keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.organizationBusy) return;
            action.dismiss();
          },
          onDidDisappear: (): void => this.closeOrganization(true)
        });
      }
    }
    this.folderNameDialog.open();
  }

  private managementDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({ primaryTitle: this.managementTitle(), themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.managementForm() }),
    customStyle: false, autoCancel: false, keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (this.organizationBusy) return;
      action.dismiss();
    },
    onDidDisappear: (): void => this.closeOrganization(true)
  });

  private openManagementDialog(): void {
    this.managementComplete = false;
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) this.managementDialog = new CustomDialogController({
          systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({ primaryTitle: this.managementTitle(), themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), contentBuilder: (): void => this.managementForm() }),
          customStyle: false, autoCancel: false, keyboardAvoidMode: KeyboardAvoidMode.DEFAULT,
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.organizationBusy) return;
            action.dismiss();
          },
          onDidDisappear: (): void => this.closeOrganization(true)
        });
      }
    }
    this.managementDialog.open();
  }

  @State private deletionKind: string = 'book';
  @State private deletionBookSnapshot?: Book = undefined;
  @State private deletionFolderSnapshot: string = '';
  private deletionDialog: CustomDialogController = new CustomDialogController({
    builder: CustomContentDialog({ themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), primaryTitle: this.deletionKind === 'batch' ? '删除所选内容？' : '删除这本书？',
      contentBuilder: (): void => this.deletionContent() }),
    customStyle: false, autoCancel: false,
    onWillDismiss: (action: DismissDialogAction): void => {
      if (this.batchBusy || this.organizationBusy) return;
      action.dismiss(); this.closeDeletion(true);
    },
    onDidDisappear: (): void => this.clearDeletionSnapshot()
  });

  private openDeletionDialog(): void {
    this.deletionBookSnapshot = this.pendingDelete;
    this.deletionFolderSnapshot = this.organizationFolder?.name ?? '';
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) this.deletionDialog = new CustomDialogController({
          systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({ themeColorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode), primaryTitle: this.deletionKind === 'batch' ? '删除所选内容？' : '删除这本书？',
            contentBuilder: (): void => this.deletionContent() }),
          customStyle: false, autoCancel: false,
          onWillDismiss: (action: DismissDialogAction): void => {
            if (this.batchBusy || this.organizationBusy) return;
            action.dismiss(); this.closeDeletion(true);
          },
          onDidDisappear: (): void => this.clearDeletionSnapshot()
        });
      }
    }
    this.deletionDialog.open();
  }

  private browseObservationReader = (): LibraryBrowseSnapshot => {
    let actualOffset: number = -1;
    try { actualOffset = this.gridScroller.currentOffset().yOffset; } catch (_) {}
    const entries = this.filteredEntries();
    return { mounted: this.mounted, active: this.active, contentMeasured: this.gridContentMeasured, contentWidthVp: this.contentWidthVp,
      gridMeasuredWidthVp: this.gridMeasuredWidthVp, gridWidthVp: this.gridGeometry.gridWidthVp,
      columns: this.gridGeometry.columns, savedOffsetVp: this.browse.gridOffsetY, actualOffsetVp: actualOffset,
      restored: this.restoredMode === this.viewMode, sourcePending: this.sourceFocusPending,
      revealSettled: this.gridRevealSettled,
      focusRejectedAncestor: this.sourceFocusRejectedAncestor,
      sourceInFilteredEntries: entries.some((entry: LibraryEntry): boolean =>
        this.browse.sourceItemId === 'library-source-grid-' + entry.book.bookId),
      entryCount: entries.length, folderCount: this.filteredFolders().length };
  };
  aboutToAppear(): void {
    if (READER_DIAGNOSTICS_ENABLED) libraryBrowseObservation.bind(this.browseObservationReader);
    this.mounted = true;
    this.unsubscribeSystemMotion = this.appearanceApplication?.subscribeSystemMotion((reduced: boolean | undefined): void => { this.systemReducedMotion = reduced; });
    this.legacyViewMode = this.presentation?.loadViewMode() ?? 'grid';
    this.viewMode = 'grid';
    // Normalize only transient old List focus IDs, not saved preferences or list offsets.
    if (this.browse.sourceItemId.startsWith('library-source-list-')) {
      this.browse.sourceItemId = this.browse.sourceItemId.replace('library-source-list-', 'library-source-grid-');
      this.publishBrowse();
    }
    this.pageController.bind({ createFolder: (): void => this.openCreateFolder(),
      enterSelection: (): void => { this.selectionMode = true; this.batchResults = []; },
      setSort: (sort: LibrarySort): void => this.setSort(sort),
      toggleSearch: (): void => this.toggleSearch(),
      parentFolder: (): void => this.parentFolder(), enterFolder: (folderId: string): void => this.enterFolder(folderId),
      handleSystemBack: (): boolean => this.handleSystemBack() });
    this.searchVisible = this.browse.query.trim().length > 0 || this.browse.sourceItemId === 'library-search';
    this.measureGridTypography();
    this.sourceFocusPending = this.browse.sourceItemId.length > 0;
    this.reloadOrganization();
  }
  aboutToDisappear(): void {
    this.closeBookmarkToast();
    // Active scroll callbacks and activation already save the position. Do not
    // overwrite that snapshot by reading a Grid during its removal from the tree.
    this.bookmarkDialog.close();
    this.mounted = false; this.pageController.unbind();
    this.onSelectionChange(false);
    this.unsubscribeSystemMotion?.(); this.unsubscribeSystemMotion = undefined;
    libraryBrowseObservation.unbind(this.browseObservationReader);
    this.organizationReadGeneration++; this.organizationActionGeneration++;
  }
  private publishBrowse(): void { this.onBrowseChange(copyLibraryBrowseState(this.browse)); }
  private concealGrid(): void {
    this.gridRevealGeneration++; this.gridRevealSettled = false; this.restoredMode = '';
  }
  private revealGrid(mode: LibraryViewMode): void {
    const generation = ++this.gridRevealGeneration;
    this.gridRevealSettled = false;
    this.getUIContext().animateTo({ duration: this.systemReducedMotion === true ? 0 : 180, curve: Curve.EaseOut,
      onFinish: (): void => {
        if (generation === this.gridRevealGeneration && this.restoredMode === mode) this.gridRevealSettled = true;
      } }, (): void => { this.restoredMode = mode; });
  }
  private selectionChanged(): void { this.onSelectionChange(this.selectionMode); }
  private activeChanged(): void {
    if (!this.active || !this.mounted || !this.browse.sourceItemId) return;
    this.sourceFocusPending = true;
    this.restoreSourceFocus(this.browse.sourceItemId);
  }
  private reloadOrganization(): void {
    const organization = this.organization;
    // Index finishes repository initialization before its initial load completes.
    // A read attempted earlier is not an actual directory failure.
    if (!organization || this.loading) return;
    this.organizationReadFailed = false;
    const generation = ++this.organizationReadGeneration;
    Promise.all([organization.folders(), organization.memberships()]).then((values): void => {
      if (!this.mounted || generation !== this.organizationReadGeneration) return;
      this.browse = reconcileLibraryFolder(this.browse, values[0] as LibraryFolder[]);
      this.browse.folders = values[0] as LibraryFolder[]; this.browse.memberships = values[1] as BookOrganization[];
      this.browse.organizationKnown = true; this.organizationReadFailed = false;
      this.refreshFolderCards();
      this.publishBrowse();
    }).catch((): void => {
      if (!this.mounted || generation !== this.organizationReadGeneration) return;
      this.organizationReadFailed = true;
    });
  }
  private saveBrowsePosition(): void {
    if (!this.mounted || this.restoredMode !== this.viewMode) return;
    const scroller = this.gridScroller;
    try {
      const y = scroller.currentOffset().yOffset;
      if (!Number.isFinite(y)) return;
      if (Math.abs(this.browse.gridOffsetY - Math.max(0, y)) < 0.5) return;
      this.browse.gridOffsetY = Math.max(0, y);
      this.publishBrowse();
    } catch (_) {}
  }
  private resetBrowsePosition(): void {
    this.browse.gridOffsetY = 0; this.browse.listOffsetY = 0; this.browse.sourceItemId = '';
    this.browse.gridSourceTopVp = undefined; this.restoreAnchorContext = '';
    this.browse.readerReturnBookOrder = undefined;
    this.concealGrid(); this.sourceFocusPending = false;
    // Re-selecting the current sort keeps the same Grid instance, so no area
    // callback is guaranteed. Settle the reset against its next native frame.
    this.continueBrowseRestore(this.viewMode);
  }
  private sourceTopVp(id: string): number | undefined {
    const gridId = id.replace('library-more-folder-', 'library-folder-').replace('library-more-book-', 'library-source-grid-');
    try {
      const ui = this.getUIContext(), grid = ui.getAttachedFrameNodeById('library-auto-grid'), source = ui.getAttachedFrameNodeById(gridId);
      if (grid === null || source === null || !grid.isVisible() || !source.isVisible()) return undefined;
      const top = source.getPositionToWindow().y - grid.getPositionToWindow().y;
      return Number.isFinite(top) ? top : undefined;
    } catch (_) { return undefined; }
  }
  private continueBrowseRestore(mode: LibraryViewMode): void {
    if (this.restoreFramePending) return;
    this.restoreFramePending = true;
    this.getUIContext().postFrameCallback(new LibrarySourceFocusFrame((): void => {
      this.restoreFramePending = false;
      if (this.mounted) this.restoreBrowsePosition(mode);
    }));
  }
  private restoreBrowsePosition(mode: LibraryViewMode, lastVisibleIndex?: number): void {
    if (this.restoredMode === mode || !this.mounted || this.restoreFramePending) return;
    if (!this.gridContentMeasured || Math.abs(this.gridMeasuredWidthVp - this.gridGeometry.gridWidthVp) > 0.5) return;
    const scroller = this.gridScroller;
    try {
      const targetY = mode === 'grid' ? this.browse.gridOffsetY : this.browse.listOffsetY;
      const anchorContext = this.browse.folderId + '|' + this.browse.query + '|' + this.browse.sort + '|' + this.browse.sourceItemId;
      if (targetY > 0 && this.sourceFocusPending && this.restoreAnchorContext !== anchorContext) {
        const folders = this.filteredFolders(), entries = this.filteredEntries();
        const folderIndex = folders.findIndex((folder: LibraryFolder): boolean =>
          'library-folder-' + folder.folderId === this.browse.sourceItemId || 'library-more-folder-' + folder.folderId === this.browse.sourceItemId);
        const bookIndex = entries.findIndex((entry: LibraryEntry): boolean =>
          'library-source-grid-' + entry.book.bookId === this.browse.sourceItemId || 'library-more-book-' + entry.book.bookId === this.browse.sourceItemId);
        const index = folderIndex >= 0 ? folderIndex : bookIndex >= 0 ? folders.length + bookIndex : -1;
        this.restoreAnchorContext = anchorContext;
        if (index >= 0) {
          // Materialize the saved source row before restoring its pixel offset.
          // A virtual Grid's estimated extent is not the previous measured layout.
          scroller.scrollToIndex(index, false, ScrollAlign.START);
          this.continueBrowseRestore(mode);
          return;
        }
      }
      const sourceTarget = this.browse.gridSourceTopVp;
      if (sourceTarget !== undefined && this.sourceFocusPending) {
        const actualTop = this.sourceTopVp(this.browse.sourceItemId);
        if (actualTop === undefined) return;
        if (Math.abs(actualTop - sourceTarget) > 1) {
          scroller.scrollBy(0, actualTop - sourceTarget);
          this.continueBrowseRestore(mode);
          return;
        }
      } else scroller.scrollTo({ xOffset: 0, yOffset: targetY, animation: false });
      const actualY = scroller.currentOffset().yOffset;
      const itemCount = this.filteredFolders().length + this.filteredEntries().length;
      const clampedAtRealEnd = lastVisibleIndex !== undefined && lastVisibleIndex >= itemCount - 1 &&
        scroller.isAtEnd() && actualY <= targetY;
      // scrollTo before Grid layout may return normally without scrolling. Keep the
      // saved target until a real layout/scroll callback confirms it or its true end.
      if (!Number.isFinite(actualY) || (sourceTarget === undefined && Math.abs(actualY - targetY) > 1 && !clampedAtRealEnd)) return;
      this.revealGrid(mode);
      this.saveBrowsePosition();
      if (this.sourceFocusPending && !this.filteredEntries().some((entry: LibraryEntry): boolean =>
        ('library-source-grid-' + entry.book.bookId === this.browse.sourceItemId ||
          'library-more-book-' + entry.book.bookId === this.browse.sourceItemId)) &&
        !this.filteredFolders().some((folder: LibraryFolder): boolean =>
          ('library-folder-' + folder.folderId === this.browse.sourceItemId ||
            'library-more-folder-' + folder.folderId === this.browse.sourceItemId))) {
        this.browse.sourceItemId = this.searchVisible ? 'library-search' : this.renderHeader ? 'library-search-toggle' : 'library-auto-grid'; this.publishBrowse();
      }
      this.restoreSourceFocus(this.browse.sourceItemId);
    } catch (_) {}
  }
  private restoreSourceFocus(id: string): void {
    if (!this.active || !this.sourceFocusPending || !id || id !== this.browse.sourceItemId || this.restoredMode !== this.viewMode) return;
    if (this.hasOverlay()) return;
    // GridItem is a focus scope; restore the book activation leaf, not its More button.
    const focusId = id.startsWith('library-source-grid-') ? id.replace('library-source-grid-', 'library-book-focus-') : id;
    if (this.sourceFocusScheduled) return;
    const ui = this.getUIContext();
    this.sourceFocusScheduled = true;
    ui.postFrameCallback(new LibrarySourceFocusFrame((): void => {
      this.sourceFocusScheduled = false;
      if (!this.active || !this.mounted || !this.sourceFocusPending || id !== this.browse.sourceItemId || this.hasOverlay()) return;
      ui.runScopedTask((): void => {
        try { ui.getFocusController().requestFocus(focusId); }
        catch (error) {
          const message = (error as Error).message;
          this.sourceFocusRejectedAncestor = typeof message === 'string' && /focusable ancestor/i.test(message);
        }
      });
    }));
  }
  private sourceFocused(id: string): void {
    if (this.sourceFocusPending && this.browse.sourceItemId === id) this.sourceFocusPending = false;
  }
  private hasOverlay(): boolean {
    return this.detailsEntry !== undefined || this.bookmarkEntry !== undefined || this.renamingEntry !== undefined ||
      this.folderEditor || this.organizationBook !== undefined || this.pendingDelete !== undefined || this.batchConfirm;
  }
  private rememberManagementSource(id: string): void {
    this.saveBrowsePosition(); this.browse.sourceItemId = id; this.browse.gridSourceTopVp = this.sourceTopVp(id);
    this.sourceFocusPending = true; this.publishBrowse();
  }
  private returnManagementFocus(): void {
    if (this.sourceFocusPending && !this.filteredEntries().some((entry: LibraryEntry): boolean =>
      this.browse.sourceItemId === 'library-source-grid-' + entry.book.bookId ||
        this.browse.sourceItemId === 'library-more-book-' + entry.book.bookId) &&
      !this.filteredFolders().some((folder: LibraryFolder): boolean =>
        this.browse.sourceItemId === 'library-folder-' + folder.folderId ||
          this.browse.sourceItemId === 'library-more-folder-' + folder.folderId)) {
      this.browse.sourceItemId = this.searchVisible ? 'library-search' : this.renderHeader ? 'library-search-toggle' : 'library-auto-grid'; this.publishBrowse();
    }
    this.restoreSourceFocus(this.browse.sourceItemId);
  }
  private activateBook(entry: LibraryEntry): void {
    if (this.selectionMode) { this.toggleSelection(entry.book.bookId); return; }
    this.rememberBookSource(entry);
    if (entry.book.sourceState === 'missing') this.onRepair(entry.book); else this.onOpen(entry.book);
  }
  private rememberBookSource(entry: LibraryEntry): void {
    this.browse.readerReturnBookOrder = this.browse.sort === 'recent' ?
      this.filteredEntries().map((item: LibraryEntry): string => item.book.bookId) : undefined;
    this.saveBrowsePosition(); this.browse.sourceItemId = 'library-source-' + this.viewMode + '-' + entry.book.bookId;
    this.browse.gridSourceTopVp = this.sourceTopVp(this.browse.sourceItemId);
    this.publishBrowse();
  }
  private browseKey(event: KeyEvent, entry: LibraryEntry): boolean {
    if (event.type !== KeyType.Up || (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_SPACE)) return false;
    this.activateBook(entry); return true;
  }
  private enterFolder(folderId: string): void {
    if (this.selectionMode) { this.toggleFolderSelection(folderId); return; }
    if (folderId === this.browse.folderId || (folderId && !this.browse.folders.some((item: LibraryFolder): boolean => item.folderId === folderId))) return;
    this.saveBrowsePosition(); this.browse.gridSourceTopVp = this.sourceTopVp('library-folder-' + folderId);
    this.browse = enterLibraryFolder(this.browse, folderId, 'library-folder-' + folderId);
    this.concealGrid(); this.restoreAnchorContext = ''; this.sourceFocusPending = false; this.selectedBookIds = []; this.selectedFolderIds = []; this.publishBrowse();
  }
  private parentFolder(): void {
    const parentId = this.browse.folders.find((item: LibraryFolder): boolean => item.folderId === this.browse.folderId)?.parentId ?? '';
    this.browse = returnLibraryParent(this.browse, parentId); this.concealGrid(); this.restoreAnchorContext = '';
    this.sourceFocusPending = this.browse.sourceItemId.length > 0; this.selectedBookIds = []; this.selectedFolderIds = []; this.publishBrowse();
  }

  private moveTargets(): LibraryMoveTargets {
    const folders = this.browse.folders, cached = this.moveTargetsCache;
    if (cached !== undefined && cached.folders.length === folders.length &&
      cached.folders.every((folder: LibraryFolder, index: number): boolean => folder === folders[index])) return cached;
    const byId = new Map<string, LibraryFolder>();
    folders.forEach((folder: LibraryFolder): void => { byId.set(folder.folderId, folder); });
    const paths = new Map<string, string>();
    const options: SelectOption[] = [{ value: '书库（根目录）' }];
    folders.forEach((folder: LibraryFolder): void => {
      const names: string[] = [];
      let cursor = folder.folderId;
      while (cursor && names.length < 32) {
        const ancestor = byId.get(cursor);
        if (ancestor === undefined) break;
        names.unshift(ancestor.name); cursor = ancestor.parentId;
      }
      const path = ['书库', ...names].join(' / ');
      paths.set(folder.folderId, path); options.push({ value: path });
    });
    const projection: LibraryMoveTargets = { folders: folders.slice(), paths: paths, options: options };
    this.moveTargetsCache = projection;
    return projection;
  }

  private openOrganizationBook(book: Book, intent: string = 'move-book'): void {
    const membership = this.browse.memberships.find((item: BookOrganization): boolean => item.bookId === book.bookId);
    this.organizationBook = book; this.detailsEntry = undefined;
    this.organizationFolder = undefined; this.organizationIntent = intent; this.batchMove = false;
    this.organizationTarget = membership?.folderId ?? '';
    this.seriesName = membership?.seriesName ?? '';
    this.volumeOrder = membership?.volumeOrder === undefined ? '' : String(membership.volumeOrder);
    this.organizationMessage = '';
    this.openManagementDialog();
  }

  private async organizationAction(action: string): Promise<void> {
    const organization = this.organization;
    if (!organization || this.organizationBusy || this.managementComplete) return;
    const generation = ++this.organizationActionGeneration;
    const folderId = action === 'create' ? this.browse.folderId : this.organizationFolder?.folderId ?? this.browse.folderId;
    const name = this.organizationName, target = this.organizationTarget;
    const selected = this.selectedEntries().map((entry: LibraryEntry): Book => entry.book);
    const bookId = this.organizationBook?.bookId, seriesName = this.seriesName, volume = this.volumeOrder.trim();
    this.organizationBusy = true; this.organizationMessage = '';
    try {
      if (action === 'create') await organization.create(name, folderId);
      else if (action === 'rename') await organization.rename(folderId, name);
      else if (action === 'move-folder') await organization.moveFolder(folderId, target);
      else if (action === 'remove') await organization.remove(folderId);
      else if (action === 'move-book' && bookId) await organization.moveBook(bookId, target);
      else if (action === 'move-selected') {
        const failed: string[] = [];
        for (const book of selected) {
          try { await organization.moveBook(book.bookId, target); } catch (_) { failed.push(book.bookId); }
        }
        if (!this.mounted || generation !== this.organizationActionGeneration) return;
        this.selectedBookIds = failed;
        this.managementComplete = failed.length === 0;
        this.organizationMessage = `已移动 ${selected.length - failed.length} 本；${failed.length} 本未移动。`;
        this.reloadOrganization(); return;
      }
      else if (action === 'series' && bookId) {
        if (volume && !/^\d+(?:\.\d+)?$/.test(volume)) throw new Error('Invalid volume');
        await organization.setSeries(bookId, seriesName, volume ? Number(volume) : undefined);
      }
      if (!this.mounted || generation !== this.organizationActionGeneration) return;
      this.organizationMessage = '已保存'; this.managementComplete = true;
      this.organizationName = ''; this.reloadOrganization();
    } catch (_) {
      if (this.mounted && generation === this.organizationActionGeneration)
        this.organizationMessage = '未保存：请检查名称、卷序或文件夹循环后重试。';
    } finally { if (this.mounted && generation === this.organizationActionGeneration) this.organizationBusy = false; }
  }
  private filteredEntries(): LibraryEntry[] {
    this.ensureGridProjection(); return this.projectedEntries;
  }
  private ensureGridProjection(): void {
    const context = this.browse.folderId + '|' + this.browse.query + '|' + this.browse.sort + '|' +
      (this.browse.readerReturnBookOrder?.join(',') ?? '');
    if (this.projectionEntries === this.entries && this.projectionContext === context) return;
    this.projectionEntries = this.entries; this.projectionContext = context;
    const entries = filterAndSortLibraryLevel(this.entries, this.browse.memberships, this.browse.folderId, this.browse.query, this.browse.sort);
    const order = this.browse.readerReturnBookOrder;
    // Progress comes from fresh entries; preserve only the visual order of this
    // browse context until navigation/query/sort resets it. No catalogue rewrite.
    if (this.browse.sort === 'recent' && order !== undefined) {
      const ranks = new Map<string, number>();
      order.forEach((id: string, index: number): void => { ranks.set(id, index); });
      entries.sort((left: LibraryEntry, right: LibraryEntry): number =>
        (ranks.get(left.book.bookId) ?? order.length) - (ranks.get(right.book.bookId) ?? order.length));
    }
    this.projectedEntries = entries;
    this.projectedFolders = filterLibraryChildFolders(this.browse.folders, this.browse.folderId, this.browse.query);
    const items = this.projectedFolders.map((folder: LibraryFolder): LibraryGridItem => new LibraryGridItem(folder, undefined));
    entries.forEach((entry: LibraryEntry): void => { items.push(new LibraryGridItem(undefined, entry)); });
    this.gridSource.update(items);
  }
  private filteredFolders(): LibraryFolder[] {
    this.ensureGridProjection(); return this.projectedFolders;
  }

  private selectedEntries(): LibraryEntry[] {
    return this.filteredEntries().filter((entry: LibraryEntry): boolean =>
      this.selectedBookIds.includes(entry.book.bookId));
  }

  private toggleSelection(bookId: string): void {
    if (this.batchBusy) return;
    this.batchResults = [];
    this.selectedBookIds = this.selectedBookIds.includes(bookId) ?
      this.selectedBookIds.filter((id: string): boolean => id !== bookId) : [...this.selectedBookIds, bookId];
  }

  private enterSelectionFromLongPress(bookId: string): void {
    if (this.selectionMode || this.batchBusy) return;
    this.setSelectionMode(true);
    this.selectedBookIds = [bookId];
    this.batchResults = [];
  }

  private leaveSelection(): void {
    if (this.batchBusy) return;
    this.setSelectionMode(false);
    this.selectedBookIds = []; this.selectedFolderIds = [];
    this.batchConfirm = false;
    this.batchResults = [];
  }
  private setSelectionMode(value: boolean): void {
    this.getUIContext().animateTo({ duration: this.systemReducedMotion === true ? 0 : 120, curve: Curve.EaseOut },
      (): void => { this.selectionMode = value; });
  }

  private selectedCount(): number { return this.selectedBookIds.length + this.selectedFolderIds.length; }
  private visibleSelected(): boolean {
    return this.filteredEntries().every((entry: LibraryEntry): boolean => this.selectedBookIds.includes(entry.book.bookId)) &&
      this.filteredFolders().every((folder: LibraryFolder): boolean => this.selectedFolderIds.includes(folder.folderId));
  }
  private toggleFolderSelection(folderId: string): void {
    if (this.batchBusy || !folderId || !this.currentFolder(folderId) || !this.organization) return;
    this.batchResults = [];
    this.selectedFolderIds = this.selectedFolderIds.includes(folderId) ?
      this.selectedFolderIds.filter((id: string): boolean => id !== folderId) : [...this.selectedFolderIds, folderId];
  }
  private selectFolderFromLongPress(folderId: string): void {
    if (this.selectionMode || this.batchBusy || !folderId || !this.currentFolder(folderId) || !this.organization) return;
    this.setSelectionMode(true); this.selectedBookIds = []; this.selectedFolderIds = [folderId]; this.batchResults = [];
  }
  private toggleVisibleSelection(): void {
    const books = this.filteredEntries().map((entry: LibraryEntry): string => entry.book.bookId);
    const folders = this.organization ? this.filteredFolders().map((folder: LibraryFolder): string => folder.folderId) : [];
    const clear = this.visibleSelected();
    this.batchResults = []; this.selectedBookIds = clear ? [] : books; this.selectedFolderIds = clear ? [] : folders;
  }
  private async prepareSelectedDeletion(folderIds: string[], bookIds: string[]): Promise<void> {
    if (this.batchBusy || this.deletionPreparing) return;
    this.deletionPreparing = true;
    try {
      if (this.organization) {
        const contents = await this.organization.deletionContents(folderIds, bookIds);
        if (!this.mounted) return;
        this.batchBooks = contents.books; this.batchFolders = contents.scope.roots; this.batchScopeFolders = contents.scope.folders;
      } else {
        this.batchBooks = this.selectedEntries().map((entry: LibraryEntry): Book => entry.book);
        this.batchFolders = []; this.batchScopeFolders = [];
      }
      this.batchConfirm = this.batchBooks.length + this.batchFolders.length > 0;
      if (this.batchConfirm) { this.deletionKind = 'batch'; this.openDeletionDialog(); }
    } catch (_) {
      if (this.mounted) try { this.getUIContext().getPromptAction().showToast({ message: '无法核对删除范围，请刷新后重试。' }); } catch (_) {}
    } finally { this.deletionPreparing = false; }
  }
  private async confirmSelectedDeletion(): Promise<void> {
    if (this.batchBusy || this.batchBooks.length + this.batchFolders.length === 0) return;
    this.batchBusy = true;
    const results: LibraryDeleteResult[] = [];
    try {
      let bookResults: BookDeleteResult[] = [];
      try { bookResults = await this.onDeleteSelected(this.batchBooks); } catch (_) {}
      for (const book of this.batchBooks) results.push({ id: book.bookId, title: book.title, kind: 'book',
        succeeded: bookResults.some((result: BookDeleteResult): boolean => result.bookId === book.bookId && result.succeeded) });
      for (const folder of this.batchFolders) {
        let succeeded = false;
        try {
          if (this.organization) {
            const expected = folderSubtree(this.batchScopeFolders, folder.folderId).map((item: LibraryFolder): string => item.folderId);
            await this.organization.remove(folder.folderId, expected); succeeded = true;
          }
        } catch (_) {}
        results.push({ id: folder.folderId, title: folder.name, kind: 'folder', succeeded });
      }
      if (!this.mounted) return;
      this.selectedBookIds = results.filter((result: LibraryDeleteResult): boolean => !result.succeeded && result.kind === 'book')
        .map((result: LibraryDeleteResult): string => result.id);
      this.selectedFolderIds = results.filter((result: LibraryDeleteResult): boolean => !result.succeeded && result.kind === 'folder')
        .map((result: LibraryDeleteResult): string => result.id);
      this.batchResults = results.filter((result: LibraryDeleteResult): boolean => !result.succeeded);
      if (this.batchFolders.length > 0) this.reloadOrganization();
      if (this.batchResults.length > 0) this.selectionMode = true;
      if (this.batchResults.length === 0) {
        this.selectionMode = false;
        try { this.getUIContext().getPromptAction().showToast({ message: '所选项目已删除' }); } catch (_) {}
      }
    } finally { this.batchBusy = false; this.batchConfirm = false; }
  }

  private keepBatchFocus(event: KeyEvent, nextId: string): void {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_TAB) return;
    try { this.getUIContext().getFocusController().requestFocus(nextId); } catch (_) {}
    event.stopPropagation();
  }

  private currentEntry(bookId: string): LibraryEntry | undefined {
    return this.entries.find((entry: LibraryEntry): boolean => entry.book.bookId === bookId);
  }
  private currentFolder(folderId: string): LibraryFolder | undefined {
    return this.browse.folders.find((folder: LibraryFolder): boolean => folder.folderId === folderId);
  }
  private activateBookId(bookId: string): void {
    const current = this.currentEntry(bookId); if (current !== undefined) this.activateBook(current);
  }
  private browseBookKey(event: KeyEvent, bookId: string): boolean {
    const current = this.currentEntry(bookId); return current !== undefined ? this.browseKey(event, current) : false;
  }
  private currentProgressLabel(bookId: string): string {
    const current = this.currentEntry(bookId); return current !== undefined ? this.progressLabel(current) : '';
  }

  private pageInsetVp(): number {
    return 16 + 16 * Math.max(0, Math.min(1, (this.windowSnapshot.usableWidthVp - 360) / 480));
  }
  private compactLargeText(): boolean { return this.contentWidthVp < 480 || this.fontSizeScale >= 1.3; }
  private setSort(sort: LibrarySort): void {
    this.browse.sort = sort; this.refreshFolderCards(); this.resetBrowsePosition(); this.publishBrowse();
  }
  private toggleSearch(): void {
    this.searchVisible = !this.searchVisible;
    this.searchFocusPending = this.searchVisible;
    if (!this.searchVisible) {
      this.browse.sourceItemId = this.renderHeader ? 'library-search-toggle' : 'library-auto-grid';
      this.sourceFocusPending = true; this.publishBrowse(); this.restoreSourceFocus(this.browse.sourceItemId);
    }
  }
  private requestSearchFocus(): void {
    if (!this.searchVisible || !this.searchFocusPending) return;
    try { this.getUIContext().getFocusController().requestFocus('library-search'); } catch (_) {}
  }
  private measureGridTypography(): void {
    try {
      const ui = this.getUIContext();
      const measured = ui.getMeasureUtils().measureTextSize({ textContent: '书目标题示例',
        fontSize: '14fp', fontWeight: FontWeight.Medium });
      const width = Number(measured.width);
      if (Number.isFinite(width) && width > 0) this.measuredTitleWidthVp = ui.px2vp(width);
    } catch (_) {}
    const geometry = libraryGridGeometry(this.contentWidthVp, this.measuredTitleWidthVp, this.windowSnapshot.usableWidthVp);
    if (this.sourceFocusPending && (geometry.columns !== this.gridGeometry.columns ||
      Math.abs(geometry.gridWidthVp - this.gridGeometry.gridWidthVp) > 0.5)) this.concealGrid();
    this.gridGeometry = geometry;
  }
  private measureGridContent(area: Area): void {
    const width = Number.parseFloat(area.width.toString());
    if (!Number.isFinite(width) || width <= 0) return;
    this.gridContentMeasured = true;
    if (Math.abs(width - this.contentWidthVp) < 0.5) return;
    this.contentWidthVp = width; this.measureGridTypography();
  }
  private directFolderBooks(folderId: string): number {
    return filterAndSortLibraryLevel(this.entries, this.browse.memberships, folderId, '', 'recent').length;
  }
  private refreshFolderCards(): void {
    this.folderCards = projectFolderCards(this.entries, this.browse.memberships, this.browse.folders, this.browse.sort);
    this.projectionContext = '';
  }
  private folderPreview(folderId: string): FolderCardProjection | undefined {
    return this.folderCards.find((card: FolderCardProjection): boolean => card.folderId === folderId);
  }
  private directSubfolders(folderId: string): number {
    return this.browse.folders.filter((folder: LibraryFolder): boolean => folder.parentId === folderId).length;
  }
  private levelIsEmpty(): boolean {
    return this.directFolderBooks(this.browse.folderId) === 0 && this.directSubfolders(this.browse.folderId) === 0;
  }
  private openCreateFolder(): void {
    this.managementComplete = false;
    this.organizationBook = undefined; this.organizationFolder = undefined; this.batchMove = false;
    this.organizationIntent = 'create'; this.folderEditor = true;
    this.organizationName = ''; this.organizationTarget = ''; this.organizationMessage = '';
    this.openFolderNameDialog();
  }
  private openFolderAction(folder: LibraryFolder, intent: string): void {
    this.managementComplete = false;
    this.organizationBook = undefined; this.organizationFolder = folder; this.batchMove = false;
    this.organizationIntent = intent; this.folderEditor = true;
    this.organizationName = folder.name; this.organizationTarget = folder.parentId; this.organizationMessage = '';
    if (intent === 'rename') this.openFolderNameDialog();
    else if (intent === 'move-folder') this.openManagementDialog();
    else if (intent === 'remove') {
      this.folderEditor = false;
      this.prepareSelectedDeletion([folder.folderId], []).catch((): void => {});
    }
  }
  private closeOrganization(dialogDismissed: boolean = false): void {
    if (this.organizationBusy) return;
    if (!dialogDismissed && (this.organizationIntent === 'create' || this.organizationIntent === 'rename')) this.folderNameDialog.close();
    if (!dialogDismissed && ['move-book', 'move-folder', 'move-selected', 'series'].includes(this.organizationIntent)) this.managementDialog.close();
    if (!dialogDismissed && this.organizationIntent === 'remove') this.deletionDialog.close();
    if (!dialogDismissed) return;
    this.folderEditor = false; this.organizationBook = undefined; this.organizationFolder = undefined;
    this.batchMove = false; this.returnManagementFocus();
  }
  private async submitFolderName(): Promise<void> {
    await this.organizationAction(this.organizationIntent);
    if (this.mounted && this.folderEditor && this.organizationMessage === '已保存') this.closeOrganization();
  }
  private handleSystemBack(): boolean {
    if (this.organizationBusy || this.renameSaving || this.batchBusy || this.bookmarkBusy) return this.hasOverlay();
    if (this.pendingDelete !== undefined) { this.closeDeletion(); return true; }
    if (this.batchConfirm) { this.closeDeletion(); return true; }
    if (this.renamingEntry !== undefined) { this.closeRename(); return true; }
    if (this.detailsEntry !== undefined) { this.closeDetails(); return true; }
    if (this.bookmarkEntry !== undefined) { this.closeBookmarks(); return true; }
    if (this.folderEditor || this.organizationBook !== undefined) { this.closeOrganization(); return true; }
    if (this.selectionMode) { this.leaveSelection(); return true; }
    if (this.searchVisible) { this.toggleSearch(); return true; }
    if (this.browse.folderId) { this.parentFolder(); return true; }
    return false;
  }

  private clearSearch(): void {
    this.browse.query = ''; this.resetBrowsePosition(); this.publishBrowse();
    this.selectedBookIds = []; this.selectedFolderIds = [];
    this.batchResults = [];
    if (this.searchVisible) { this.searchFocusPending = true; this.requestSearchFocus(); }
    else {
      this.browse.sourceItemId = this.renderHeader ? 'library-search-toggle' : 'library-auto-grid';
      this.sourceFocusPending = true; this.publishBrowse();
    }
  }

  private sortLabel(): ResourceStr {
    if (this.browse.sort === 'title') return $r('app.string.library_sort_title');
    if (this.browse.sort === 'imported') return $r('app.string.library_sort_imported');
    return $r('app.string.library_sort_recent');
  }

  private changeSearch(value: string): void {
    // Restoring TextInput can replay the current value without changing the filter.
    if (value === this.browse.query) return;
    this.browse.query = value; this.resetBrowsePosition(); this.publishBrowse();
    this.selectedBookIds = []; this.selectedFolderIds = []; this.batchResults = [];
  }

  private progressLabel(entry: LibraryEntry): string {
    return projectBookCard(entry).readingLabel;
  }

  private resourceText(resource: Resource, ...args: Array<string | number>): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync(resource.id, ...args);
    } catch (_) {
      return '';
    }
  }

  private formatDate(value: number): string {
    return recordTime(value);
  }

  private formatBookSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private openDetails(entry: LibraryEntry): void {
    this.detailsEntry = entry;
    this.detailsVisible = true;
    this.detailSize = '正在读取…';
    const revision = ++this.detailRevision;
    this.onBookSize(entry.book).then((bytes: number | undefined): void => {
      if (revision !== this.detailRevision) return;
      this.detailSize = bytes === undefined ? '不可用' : this.formatBookSize(bytes);
    }).catch((): void => {
      if (revision === this.detailRevision) this.detailSize = '不可用';
    });
  }

  private loadBookmarks(entry: LibraryEntry): void {
    if (this.bookmarks === undefined) return;
    const revision = ++this.bookmarkRevision;
    this.bookmarkLoading = true;
    this.bookmarks.list(entry.book.bookId).then((points: BookmarkPoint[]): void => {
      if (revision !== this.bookmarkRevision) return;
      this.bookmarkPoints = points;
      this.bookmarkLoading = false;
    }).catch((): void => {
      if (revision !== this.bookmarkRevision) return;
      this.bookmarkLoading = false;
      this.bookmarkError = '书签读取失败，请重试。';
    });
  }

  private closeBookmarkToast(): void {
    this.bookmarkToastRequest++;
    if (this.bookmarkToastId !== undefined) {
      try { this.getUIContext().getPromptAction().closeToast(this.bookmarkToastId); } catch (_) {}
      this.bookmarkToastId = undefined;
    }
  }
  private bookmarkFeedback(message: string): void {
    this.closeBookmarkToast();
    const request = this.bookmarkToastRequest, prompt = this.getUIContext().getPromptAction();
    prompt.openToast({ message }).then((id: number): void => {
      if (this.mounted && request === this.bookmarkToastRequest) this.bookmarkToastId = id;
      else { try { prompt.closeToast(id); } catch (_) {} }
    }).catch((): void => {});
  }
  private async deleteBookmark(entry: LibraryEntry, point: BookmarkPoint): Promise<void> {
    if (this.bookmarks === undefined || this.bookmarkBusy) return;
    this.bookmarkBusy = true;
    this.bookmarkError = '';
    try {
      const points = await this.bookmarks.remove(entry.book.bookId, point.bookmarkId);
      if (this.mounted && this.bookmarkEntry?.book.bookId === entry.book.bookId) {
        this.bookmarkPoints = points; this.bookmarkFeedback('书签已移除');
      }
    } catch (_) {
      if (this.mounted && this.bookmarkEntry?.book.bookId === entry.book.bookId) {
        this.bookmarkError = '移除书签失败，原书签仍保留。请重新加载后再试。';
        this.bookmarkFeedback('移除书签失败，请重试');
      }
    }
    finally { this.bookmarkBusy = false; }
  }

  private closeDetails(): void {
    this.detailRevision++;
    this.detailsVisible = false;
  }
  private detailsDidClose(): void {
    this.detailRevision++; this.detailsEntry = undefined;
    const next = this.afterDetailsClose; this.afterDetailsClose = undefined;
    if (next !== undefined) next(); else this.returnManagementFocus();
  }
  private closeRename(): void {
    if (this.renameSaving) return;
    this.renameDialog.close();
  }

  private openRename(entry: LibraryEntry): void {
    this.renamingEntry = entry;
    this.editTitle = entry.book.title;
    this.editAuthor = entry.book.author ?? '';
    this.renameError = '';
    this.renameSaving = false;
    this.openRenameDialog();
  }

  private async saveRename(): Promise<void> {
    const entry = this.renamingEntry;
    if (entry === undefined || this.renameSaving) return;
    if (this.editTitle.trim().length === 0) {
      this.renameError = '请输入书名。';
      return;
    }
    this.renameSaving = true;
    try {
      if (await this.onRename(entry.book, this.editTitle, this.editAuthor)) {
        this.renameDialog.close();
      } else {
        this.renameError = '保存失败，请重试。';
      }
    } catch (_) { this.renameError = '保存失败，请重试。'; }
    finally { this.renameSaving = false; }
  }

  @Builder
  private libraryImportButton() {
    Button() {
      SymbolGlyph($r('sys.symbol.plus')).focusable(true).fontSize($r('app.float.product_body_size'))
        .fontColor([bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode)])
    }
      .id('library-page-import').width($r('app.float.product_target_min'))
      .height($r('app.float.product_target_min')).type(ButtonType.Normal)
      .backgroundColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_control'))
      .accessibilityText($r('app.string.library_import'))
      .onClick(() => this.onImport())
  }

  @Builder
  private selectAllButton() {
    Button() {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.checkmark_circle')).fontSize(20)
          .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
        Text(this.visibleSelected() ? '清除选择' : '全选')
          .fontSize(14).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
      }
    }.id('library-select-all').height(56).layoutWeight(1).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL)
      .padding(4).borderRadius(16).backgroundColor(Color.Transparent)
      .enabled(this.filteredEntries().length + this.filteredFolders().length > 0 && !this.batchBusy)
      .accessibilityText(this.visibleSelected() ? '清除当前列表的选择' : '全选当前列表项目')
      .onClick((): void => this.toggleVisibleSelection())
  }

  @Builder
  private deleteSelectedButton() {
    Button() {
      Column({ space: 4 }) {
        SymbolGlyph($r('sys.symbol.trash')).fontSize(20)
          .fontColor([bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)])
        Text('删除').fontSize(14).fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode))
      }
    }.id('library-delete-selected').height(56).layoutWeight(1).type(ButtonType.Normal)
      .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).padding(4).borderRadius(16).backgroundColor(Color.Transparent)
      .enabled(this.selectedCount() > 0 && !this.batchBusy && !this.deletionPreparing)
      .accessibilityText(`删除选中的 ${this.selectedCount()} 个项目`)
      .onClick((): void => {
        this.prepareSelectedDeletion(this.selectedFolderIds, this.selectedBookIds).catch((): void => {});
      })
  }

  @Builder
  private moveSelectedButton() {
    if (this.organization !== undefined) {
      Button() {
        Column({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.folder')).fontSize(20)
            .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          Text('移动').fontSize(14).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
        }
      }.id('library-selected-move').height(56).layoutWeight(1).type(ButtonType.Normal).buttonStyle(ButtonStyleMode.TEXTUAL)
        .padding(4).borderRadius(16).backgroundColor(Color.Transparent)
        .enabled(this.selectedBookIds.length > 0 && this.selectedFolderIds.length === 0 && !this.batchBusy)
        .accessibilityText(`移动选中的 ${this.selectedBookIds.length} 本书`)
        .onClick((): void => {
          this.organizationBook = undefined; this.organizationFolder = undefined; this.batchMove = true;
          this.folderEditor = true; this.organizationIntent = 'move-selected'; this.organizationTarget = ''; this.organizationMessage = '';
          this.openManagementDialog();
        })
    }
  }

  @Builder
  private cancelSelectionButton() {
    Button('取消').id('library-select-cancel')
      .height($r('app.float.product_target_min')).type(ButtonType.Normal)
      .fontSize(15)
      .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
      .backgroundColor(Color.Transparent)
      .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
      .accessibilityText('退出多选').onClick((): void => this.leaveSelection())
  }

  @Builder
  private detailRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: 16 }) {
      Text(label).fontSize('14fp').fontColor($r('sys.color.font_secondary')).width(72)
      Text(value).fontSize('14fp').fontColor($r('sys.color.font_primary'))
        .layoutWeight(1).textAlign(TextAlign.End)
    }.width('100%').alignItems(VerticalAlign.Top).padding({ top: 6, bottom: 6 })
  }

  private closeBookmarks(returnFocus: boolean = true): void {
    this.bookmarkReturnFocus = returnFocus; this.bookmarkDialog.close();
  }
  private bookmarkPosition(point: BookmarkPoint): string {
    const separator = point.label.indexOf(' · ');
    return (separator < 0 ? point.label : point.label.slice(0, separator)) || '未命名位置';
  }
  private bookmarkExcerpt(point: BookmarkPoint): string {
    const separator = point.label.indexOf(' · ');
    return separator < 0 ? '' : point.label.slice(separator + 3);
  }
  @Builder
  private bookmarksContent() {
    if (this.bookmarkEntry !== undefined) { this.bookmarksBody(this.bookmarkEntry) }
  }
  @Builder
  private bookmarksBody(entry: LibraryEntry) {
    Column({ space: 16 }) {
      Row({ space: 8 }) {
        Text('书签').fontSize(18).fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary')).layoutWeight(1)
        Button() {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([$r('sys.color.font_secondary')])
        }.id('library-bookmarks-close').width(48).height(48).type(ButtonType.Circle)
          .buttonStyle(ButtonStyleMode.TEXTUAL).accessibilityText($r('app.string.common_close'))
          .onClick((): void => this.closeBookmarks())
      }.width('100%')
      Text(entry.book.title).fontSize(13).fontColor($r('sys.color.font_secondary'))
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      if (entry.book.sourceState === 'missing') {
        Column({ space: 4 }) {
          Text('书籍来源缺失').fontSize('15fp').fontColor($r('sys.color.font_primary')).width('100%')
          Text('仍可查看和删除书签，修复来源后即可跳转。').fontSize('14fp')
            .fontColor($r('sys.color.font_secondary')).width('100%')
          Button('修复书籍来源').id('library-bookmarks-repair').height(48)
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.closeBookmarks(false); this.onRepair(entry.book); })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }
      if (this.bookmarkError.length > 0) {
        Column({ space: 8 }) {
          Text(this.bookmarkError).fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
          Button(this.bookmarkError.startsWith('移除书签') ? '重新加载' : '重试').id('library-bookmarks-retry').height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
            .onClick((): void => { this.bookmarkError = ''; this.loadBookmarks(entry); })
        }.id('library-bookmarks-error').width('100%').alignItems(HorizontalAlign.Start)
      }
      if (this.bookmarkLoading) {
        Row({ space: 12 }) {
          LoadingProgress().width(24).height(24)
          Text('正在读取书签…').fontSize('14fp').fontColor($r('sys.color.font_secondary'))
        }.id('library-bookmarks-loading').width('100%').justifyContent(FlexAlign.Center).padding({ top: 24, bottom: 24 })
      } else if (this.bookmarkError.length === 0 && this.bookmarkPoints.length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.bookmark')).fontSize(32).fontColor([$r('sys.color.font_secondary')])
          Text('暂无书签').fontSize('16fp').fontColor($r('sys.color.font_primary'))
          Text('阅读时在「更多」中添加书签，方便下次返回。').fontSize('14fp')
            .fontColor($r('sys.color.font_secondary')).textAlign(TextAlign.Center)
        }.id('library-bookmarks-empty').width('100%').padding({ top: 28, bottom: 28, left: 12, right: 12 })
      } else if (this.bookmarkPoints.length > 0) {
        List({ space: 8 }) {
          ForEach(this.bookmarkPoints, (point: BookmarkPoint) => {
            ListItem() {
              Row({ space: 4 }) {
                Button() {
                  Row({ space: 12 }) {
                    SymbolGlyph($r('sys.symbol.bookmark')).fontSize(20).fontColor([$r('sys.color.font_secondary')])
                    Column({ space: 6 }) {
                      Text(this.bookmarkPosition(point)).fontSize('15fp').fontWeight(FontWeight.Medium)
                        .fontColor($r('sys.color.font_primary')).width('100%').textAlign(TextAlign.Start)
                      if (this.bookmarkExcerpt(point).length > 0) {
                        Text(this.bookmarkExcerpt(point)).fontSize('14fp').fontColor($r('sys.color.font_secondary'))
                          .width('100%').lineHeight(22).textAlign(TextAlign.Start)
                      }
                      Text(recordTime(point.createdAt)).fontSize('12fp')
                        .fontColor($r('sys.color.font_secondary')).width('100%').textAlign(TextAlign.Start)
                    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
                  }.width('100%').alignItems(VerticalAlign.Top)
                }.id('library-bookmark-jump').layoutWeight(1).constraintSize({ minHeight: 48 })
                  .type(ButtonType.Normal).backgroundColor(Color.Transparent).padding(12).borderRadius(16)
                  .accessibilityText(point.label || '未命名位置').enabled(entry.book.sourceState === 'available')
                  .onClick((): void => {
                    this.closeBookmarks(false);
                    this.rememberBookSource(entry); this.onOpenBookmark(entry.book, point);
                  })
                Button() {
                  SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)])
                }.id('library-bookmark-delete').width(48).height(48).type(ButtonType.Circle)
                  .buttonStyle(ButtonStyleMode.TEXTUAL).role(ButtonRole.ERROR).accessibilityText('删除书签')
                  .enabled(!this.bookmarkBusy)
                  .onClick((): void => { this.deleteBookmark(entry, point).catch((): void => {}); })
              }.width('100%')
            }
          }, (point: BookmarkPoint): string => point.bookmarkId)
        }.id('library-bookmarks-list').width('100%').constraintSize({ maxHeight: 360 })
          .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.bookshelfTheme === 'starry' || this.bookshelfDefaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
      }
    }.id('library-bookmarks-surface').width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder
  private renameForm() {
    Column({ space: 20 }) {
      Column({ space: 8 }) {
        Text('书名').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 4 })
        TextInput({ text: this.editTitle, placeholder: '书名' }).id('library-rename-title')
          .maxLength(120).height(48).fontSize('16fp').padding({ left: 16, right: 16 }).enabled(!this.renameSaving)
          .onChange((value: string): void => { this.editTitle = value; this.renameError = ''; })
      }.width('100%')
      Column({ space: 8 }) {
        Text('作者（选填）').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 4 })
        TextInput({ text: this.editAuthor, placeholder: '可留空' }).id('library-rename-author')
          .maxLength(120).height(48).fontSize('16fp').padding({ left: 16, right: 16 }).enabled(!this.renameSaving)
          .onChange((value: string): void => { this.editAuthor = value; this.renameError = ''; })
      }.width('100%')
      if (this.renameError.length > 0) {
        Text(this.renameError).id('library-rename-error').fontSize('14fp').fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').id('library-rename-cancel').height(48).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.renameSaving).onClick((): void => this.closeRename())
        Button(this.renameSaving ? '保存中…' : '保存').id('library-rename-save').height(48).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.EMPHASIZED).enabled(!this.renameSaving)
          .onClick((): void => { this.saveRename().catch((): void => {}); })
      }.width('100%').margin({ top: 4 })
    }.id('library-book-rename-surface').width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder
  private detailsTitle() {
    Row() {
      Text('图书信息').fontSize('18fp').fontWeight(FontWeight.Medium)
        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
      Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18)
        .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)]) }
        .id('library-book-details-close').width(48).height(48).type(ButtonType.Circle)
        .backgroundColor(Color.Transparent).accessibilityText('关闭图书信息').onClick((): void => this.closeDetails())
    }.width('100%').padding({ left: 24, right: 12 })
  }

  @Builder
  private detailAction(label: string, id: string, action: () => void) {
      Button() {
        Row() {
          Text(label).fontSize('16fp').fontColor($r('sys.color.font_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([$r('sys.color.font_secondary')])
        }.width('100%').padding({ left: 16, right: 16 })
      }.id(id).height(56).width('100%').type(ButtonType.Normal).backgroundColor(Color.Transparent)
        .onClick(action)
  }

  @Builder
  private detailSectionTitle(title: string) {
    Text(title).fontSize('14fp').fontWeight(FontWeight.Medium)
      .fontColor($r('sys.color.font_secondary')).width('100%').margin({ bottom: 4 })
  }

  @Builder
  private detailsSheet() {
    WithTheme({ colorMode: bookshelfThemeColorMode(this.bookshelfDefaultMode) }) {
    if (this.detailsEntry !== undefined) {
      Scroll() {
        Column({ space: 24 }) {
          Row({ space: 16 }) {
            if (this.detailsEntry.book.coverRelativePath !== undefined) {
              Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${this.detailsEntry.book.coverRelativePath}`)
                .width(64).height(96).objectFit(ImageFit.Contain).draggable(false)
            } else {
              SymbolGlyph($r('sys.symbol.list_book')).fontSize(32).fontColor([$r('sys.color.font_secondary')]).width(40).height(40)
            }
            Column({ space: 6 }) {
              Text(this.detailsEntry.book.title).fontSize('20fp').fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary')).width('100%')
              if (this.detailsEntry.book.author) {
                Text(this.detailsEntry.book.author).fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
              }
            }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          }.width('100%').alignItems(this.detailsEntry.book.coverRelativePath !== undefined ? VerticalAlign.Top : VerticalAlign.Center)
          Column() {
            this.detailSectionTitle('阅读信息')
            this.detailRow('进度', this.progressLabel(this.detailsEntry))
            if (this.detailsEntry.book.lastOpenedAt !== undefined) {
              this.detailRow('最近阅读', this.formatDate(this.detailsEntry.book.lastOpenedAt))
            }
          }.width('100%')
          Column() {
            this.detailSectionTitle('文件信息')
            this.detailRow('格式', projectBookCard(this.detailsEntry).formatDescription)
            this.detailRow('大小', this.detailSize)
            this.detailRow('导入时间', this.formatDate(this.detailsEntry.book.importedAt))
            this.detailRow('文件状态', this.detailsEntry.book.sourceState === 'missing' ? '文件缺失' : '可用')
          }.width('100%')
          Column() {
          this.detailSectionTitle('关联操作')
          Column() {
            if (this.detailsEntry.book.sourceState === 'missing') {
              this.detailAction('重新选择文件', 'library-details-repair', (): void => {
                const entry = this.detailsEntry;
                this.afterDetailsClose = (): void => { if (entry !== undefined) this.onRepair(entry.book); };
                this.closeDetails();
              })
            }
            if (this.bookmarks !== undefined) {
              this.detailAction('书签', 'library-bookmarks-open', (): void => {
                const entry = this.detailsEntry;
                this.afterDetailsClose = (): void => {
                  if (entry !== undefined) {
                    this.bookmarkEntry = entry; this.bookmarkPoints = []; this.bookmarkError = ''; this.loadBookmarks(entry);
                    this.bookmarkReturnFocus = false; this.bookmarkDialog = this.createBookmarkDialog(); this.bookmarkDialog.open();
                  }
                };
                this.closeDetails();
              })
            }
            if (this.organization !== undefined) {
              this.detailAction('系列与卷序', 'library-details-series', (): void => {
                const entry = this.detailsEntry;
                this.afterDetailsClose = (): void => {
                  if (entry !== undefined) { this.openOrganizationBook(entry.book, 'series'); }
                };
                this.closeDetails();
              })
            }
          }.width('100%')
            .backgroundColor($r('sys.color.comp_background_tertiary')).borderRadius(16)
          }.width('100%')
        }.id('library-book-details-surface').width('100%').padding({ left: 24, right: 24, top: 8, bottom: 24 })
      }.id('library-book-details-scroll').width('100%').constraintSize({ maxHeight: Math.max(160, this.windowSnapshot.heightVp * 0.72) })
        .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.bookshelfTheme === 'starry' || this.bookshelfDefaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
    }
    }
  }

  private closeDeletion(dialogDismissed: boolean = false): void {
    if (this.batchBusy || this.organizationBusy) return;
    if (!dialogDismissed) this.deletionDialog.close();
    if (this.deletionKind === 'folder') { this.closeOrganization(true); return; }
    this.pendingDelete = undefined; this.batchConfirm = false; this.returnManagementFocus();
  }
  private clearDeletionSnapshot(): void {
    this.deletionBookSnapshot = undefined; this.deletionFolderSnapshot = '';
  }
  private async submitSingleDeletion(book: Book): Promise<void> {
    this.closeDeletion();
    let succeeded = false;
    try { succeeded = await this.onDelete(book); } catch (_) {}
    if (this.mounted) {
      try { this.getUIContext().getPromptAction().showToast({ message: succeeded ? '图书已删除' : '删除未完成，请重试。' }); } catch (_) {}
    }
  }
  private async submitBatchDeletion(): Promise<void> {
    await this.confirmSelectedDeletion();
    this.deletionDialog.close();
  }
  @Builder
  private deletionContent() {
    if (this.deletionKind === 'batch') { this.batchDeleteOverlay() }
    else if (this.deletionBookSnapshot !== undefined) { this.deleteOverlay(this.deletionBookSnapshot) }
  }

  @Builder
  private deleteOverlay(book: Book) {
    Column({ space: 20 }) {
      Text(book.title).fontSize('16fp').fontWeight(FontWeight.Medium).fontColor($r('sys.color.font_primary'))
        .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
      Text($r('app.string.library_delete_body')).fontSize('14fp')
        .fontColor($r('sys.color.font_secondary')).width('100%')
      Row({ space: 12 }) {
        Button('取消').id('library-delete-cancel').height(48).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL).defaultFocus(true).onClick((): void => this.closeDeletion())
        Button('删除').id('library-delete-confirm').height(48).layoutWeight(1)
          .role(ButtonRole.ERROR).buttonStyle(ButtonStyleMode.NORMAL)
          .onClick((): void => { this.submitSingleDeletion(book).catch((): void => {}); })
      }.width('100%').margin({ top: 4 })
    }.id('library-delete-confirmation').width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder
  private batchDeleteOverlay() {
    Column({ space: 20 }) {
      Text($r('app.string.library_delete_body')).fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
      Text(`将全部删除 ${this.batchBooks.length} 本图书、${this.batchFolders.length} 个选中文件夹及 ${this.batchScopeFolders.length - this.batchFolders.length} 个子文件夹。包括所有层级内部内容及关联笔记、书签、高亮和阅读进度。仅删除页灯内的导入副本，设备其他位置的原始文件不受影响。需要保留的图书请先移出。`)
        .id('library-batch-delete-scope').fontSize(14).fontColor($r('sys.color.font_secondary')).width('100%')
      List({ space: 12 }) {
        ForEach(this.batchFolders, (folder: LibraryFolder) => {
          ListItem() { Text('文件夹：' + folder.name).fontSize(16).fontColor($r('sys.color.font_primary')).width('100%') }
        }, (folder: LibraryFolder): string => folder.folderId)
        ForEach(this.batchBooks, (book: Book) => {
          ListItem() {
            Column({ space: 4 }) {
              Text(book.title).fontSize('16fp').fontColor($r('sys.color.font_primary')).width('100%')
              Text(`${book.author ?? '未知作者'} · ${this.formatDate(book.importedAt)}`)
                .fontSize('12fp').fontColor($r('sys.color.font_secondary')).width('100%')
            }.width('100%')
          }
        }, (book: Book) => book.bookId)
      }.width('100%').constraintSize({ maxHeight: 240 })
      Row({ space: 12 }) {
        Button('取消').id('library-batch-delete-cancel').height(48).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL).focusable(true).defaultFocus(true)
          .onKeyEvent((event: KeyEvent): void => this.keepBatchFocus(event, 'library-batch-delete-confirm'))
          .enabled(!this.batchBusy).onClick((): void => this.closeDeletion())
        Button(this.batchBusy ? '正在删除…' : '全部删除')
          .id('library-batch-delete-confirm').height(48).layoutWeight(1).role(ButtonRole.ERROR).buttonStyle(ButtonStyleMode.NORMAL)
          .focusable(true).onKeyEvent((event: KeyEvent): void => this.keepBatchFocus(event, 'library-batch-delete-cancel'))
          .enabled(!this.batchBusy).onClick((): void => { this.submitBatchDeletion().catch((): void => {}); })
      }.width('100%').margin({ top: 4 })
    }.id('library-batch-delete-confirmation').width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder
  private folderNameForm() {
    Column({ space: 20 }) {
      Column({ space: 8 }) {
        Text('文件夹名称').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%').padding({ left: 4 })
        TextInput({ text: this.organizationName, placeholder: '输入文件夹名称' }).id('library-folder-name')
          .maxLength(120).height(48).fontSize('16fp').padding({ left: 16, right: 16 })
          .enabled(!this.organizationBusy).defaultFocus(true).enterKeyType(EnterKeyType.Done)
          .onChange((value: string): void => { this.organizationName = value; })
      }.width('100%')
      if (this.organizationMessage.length > 0) {
        Text('未保存，请检查文件夹名称后重试。').id('library-folder-name-error')
          .fontSize('14fp').fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
      }
      Row({ space: 12 }) {
        Button('取消').id('library-folder-name-cancel').height(48).layoutWeight(1)
          .buttonStyle(ButtonStyleMode.NORMAL).enabled(!this.organizationBusy)
          .onClick((): void => this.closeOrganization())
        Button(this.organizationBusy ? (this.organizationIntent === 'rename' ? '保存中…' : '新建中…') :
          (this.organizationIntent === 'rename' ? '保存' : '新建'))
          .id(this.organizationIntent === 'rename' ? 'library-folder-rename' : 'library-folder-create')
          .height(48).layoutWeight(1).buttonStyle(ButtonStyleMode.EMPHASIZED).enabled(!this.organizationBusy)
          .onClick((): void => { this.submitFolderName().catch((): void => {}); })
      }.width('100%').margin({ top: 4 })
    }.id('library-folder-name-form').width('100%').padding({ top: 4, bottom: 4 })
  }

  private managementTitle(): string {
    if (this.organizationIntent === 'series') return '系列与卷序';
    if (this.batchMove) return '批量移动';
    return this.organizationBook !== undefined ? '移动图书' : '移动文件夹';
  }

  @Builder
  private managementTargetSelect(targets: LibraryMoveTargets) {
    Select(targets.options).id('library-organization-target')
      .selected(targets.folders.findIndex((item: LibraryFolder): boolean => item.folderId === this.organizationTarget) + 1)
      .value(targets.paths.get(this.organizationTarget) ?? '书库').width('100%')
      .attributeModifier(new NativeSelectMenuMaterial(this.menuMaterial))
      .font({ size: 16, weight: FontWeight.Regular }).enabled(!this.organizationBusy && !this.managementComplete)
      .onSelect((index: number): void => {
        if (index >= 0 && index <= targets.folders.length) this.organizationTarget = index === 0 ? '' : targets.folders[index - 1].folderId;
      })
  }

  @Builder
  private managementForm() {
    Column({ space: 20 }) {
      Text(this.batchMove ? `已选择 ${this.selectedEntries().length} 本图书` :
        this.organizationBook?.title ?? this.organizationFolder?.name ?? '')
        .id('library-management-context').fontSize('14fp')
        .fontColor($r('sys.color.font_secondary')).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      if (this.organizationIntent === 'series') {
        Column({ space: 8 }) {
          Text('系列名称').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
          TextInput({ text: this.seriesName, placeholder: '留空退出系列' }).id('library-series-name')
            .height(48).fontSize('16fp').maxLength(120).padding({ left: 16, right: 16 })
            .enabled(!this.organizationBusy && !this.managementComplete).defaultFocus(true)
            .onChange((value: string): void => { this.seriesName = value; })
        }.width('100%')
        Column({ space: 8 }) {
          Text('卷序').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
          TextInput({ text: this.volumeOrder, placeholder: '填写数值，可留空' }).id('library-volume-order')
            .height(48).fontSize('16fp').type(InputType.NUMBER_DECIMAL).maxLength(16).padding({ left: 16, right: 16 }).enabled(!this.organizationBusy && !this.managementComplete)
            .onChange((value: string): void => { this.volumeOrder = value; })
          Text('同卷序并列；续读时需选择。未指定卷序不自动续读。').fontSize('12fp')
            .fontColor($r('sys.color.font_secondary')).width('100%')
        }.width('100%')
      } else {
        Column({ space: 8 }) {
          Text('移动到').fontSize('14fp').fontColor($r('sys.color.font_secondary')).width('100%')
          this.managementTargetSelect(this.moveTargets())
        }.width('100%')
      }
      if (this.organizationMessage) {
        Text(this.organizationMessage).id('library-management-message').fontSize('14fp').width('100%')
          .fontColor(this.organizationMessage.startsWith('未保存') ? $r('app.color.product_error') : $r('sys.color.font_secondary'))
      }
      Row({ space: 12 }) {
        Button(this.managementComplete ? '完成' : '取消')
          .id('library-management-close').height(48).layoutWeight(1)
          .buttonStyle(this.managementComplete ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
          .enabled(!this.organizationBusy).onClick((): void => this.closeOrganization())
        if (!this.managementComplete) {
        Button(this.organizationBusy ? (this.organizationIntent === 'series' ? '保存中…' : '移动中…') :
          this.organizationIntent === 'series' ? '保存' : this.batchMove && this.organizationMessage.startsWith('已移动') ? '重试未移动项' : '移动')
          .id(this.organizationIntent === 'series' ? 'library-series-save' : this.batchMove ? 'library-selected-move-confirm' :
            this.organizationBook !== undefined ? 'library-book-move' : 'library-folder-move')
          .height(48).layoutWeight(1).buttonStyle(ButtonStyleMode.EMPHASIZED).enabled(!this.organizationBusy)
          .onClick((): void => { this.organizationAction(this.organizationIntent); })
        }
      }.width('100%').margin({ top: 4 })
    }.id('library-management-form').width('100%').padding({ top: 4, bottom: 4 })
  }

  @Builder
  private sortMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.library_sort_recent') }).height(48)
        .onClick((): void => this.setSort('recent'))
      MenuItem({ content: $r('app.string.library_sort_title') }).height(48)
        .onClick((): void => this.setSort('title'))
      MenuItem({ content: $r('app.string.library_sort_imported') }).height(48)
        .onClick((): void => this.setSort('imported'))
    }
  }

  @Builder
  private headerMoreMenu() {
    Menu() {
      if (this.organization !== undefined) {
        MenuItem({ content: '新建文件夹' }).id('library-folder-manage').height(48)
          .onClick((): void => this.openCreateFolder())
      }
      MenuItem({ content: '选择' }).id('library-select-enter').height(48)
        .onClick((): void => { this.setSelectionMode(true); this.batchResults = []; })
      MenuItem({ content: '排序', builder: (): void => this.sortMenu() }).id('library-sort').height(48)
      MenuItemGroup() {
      MenuItem({ content: '设置' }).id('library-settings').height(48).onClick((): void => this.onSettings())
      }
    }
  }

  @Builder
  private compactHeader() {
    Row() {
      if (this.browse.folderId) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left')).focusable(true).fontSize(LIBRARY_SYMBOL_SIZE_VP)
            .fontColor([bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)])
        }.id('library-folder-up').width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
          .backgroundColor(Color.Transparent).accessibilityText('返回上一级')
          .onClick((): void => this.parentFolder())
      }
      Text(this.browse.folders.find((folder: LibraryFolder): boolean => folder.folderId === this.browse.folderId)?.name ?? '书库')
        .fontSize('22fp').fontWeight(FontWeight.Medium).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass')).focusable(true).fontSize(LIBRARY_SYMBOL_SIZE_VP)
          .fontColor([bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)])
      }.id('library-search-toggle').width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
        .backgroundColor(Color.Transparent).accessibilityText('筛选当前目录').onClick((): void => this.toggleSearch())
        .onFocus((): void => this.sourceFocused('library-search-toggle'))
      this.libraryImportButton()
      Button() {
        SymbolGlyph($r('sys.symbol.ellipsis_circle')).focusable(true).fontSize(LIBRARY_SYMBOL_SIZE_VP)
          .fontColor([bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)])
      }.id('library-header-more').width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
        .backgroundColor(Color.Transparent).accessibilityText('书库更多操作').bindMenu(this.headerMoreMenu(), nativeMenuOptions(this.menuMaterial))
    }.width('100%')
  }

  @Builder private libraryBody() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.renderBackground) {
        BookshelfBackground({ theme: this.bookshelfTheme, defaultMode: this.bookshelfDefaultMode })
      }
      Column({ space: $r('app.float.product_space_12') }) {
        if (this.renderHeader) { this.compactHeader() }
        Column({ space: $r('app.float.product_space_12') }) {
        if (this.searchVisible && !this.selectionMode) {
        Row({ space: $r('app.float.product_space_8') }) {
          Row({ space: 4 }) {
            SymbolGlyph($r('sys.symbol.magnifyingglass')).fontSize(20)
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)]).margin({ left: 16 })
              .hitTestBehavior(HitTestMode.None)
          TextInput({ placeholder: $r('app.string.library_search_placeholder'), text: this.browse.query })
            .id('library-search').onFocus((): void => { this.searchFocusPending = false; this.sourceFocused('library-search'); })
            .onAreaChange((): void => { this.requestSearchFocus(); this.restoreSourceFocus('library-search'); }).onChange((value: string) => {
              this.changeSearch(value);
            })
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).placeholderColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
            .fontSize('16fp').backgroundColor(Color.Transparent).padding({ left: 8, right: 12 })
            .height($r('app.float.product_target_min')).layoutWeight(1)
          }.height(48).layoutWeight(1).backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode)).borderRadius(16)
          if (this.browse.query.length > 0) {
            Button($r('app.string.library_clear_search')).id('library-clear-search-inline')
              .height(48).constraintSize({ minWidth: 64 }).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize('14fp')
              .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
              .onClick(() => this.clearSearch())
          }
        }.id('library-filter-bar').width('100%')
        } else if (this.browse.query.trim().length > 0 && !this.selectionMode) {
          Row() {
            Text('当前目录筛选：' + this.browse.query).fontSize('12fp').lineHeight('18fp').layoutWeight(1)
              .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
            Button('清除').id('library-clear-filter-summary').height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontSize('14fp').fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode)).onClick((): void => this.clearSearch())
          }.width('100%')
        }

        if (this.selectionMode) {
          Row() {
            this.cancelSelectionButton()
            Text(this.selectedFolderIds.length > 0 ? `已选 ${this.selectedBookIds.length} 本书、${this.selectedFolderIds.length} 个文件夹` : `已选 ${this.selectedBookIds.length} 本`).id('library-selected-count').fontSize(LIBRARY_SELECTION_LABEL_FP)
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
          }.id('library-selection-toolbar').width('100%').height(56).transition(TransitionEffect.OPACITY)
        }

        if (this.batchResults.length > 0) {
          Column({ space: 8 }) {
            Row() {
              Text(`删除未完成：${this.batchResults.length} 项，可重试。`).id('library-delete-result-summary')
                .fontSize(14).fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).layoutWeight(1)
              Button('关闭').id('library-delete-results-close').height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
                .onClick((): void => { this.batchResults = []; })
            }.width('100%')
            List({ space: 8 }) {
              ForEach(this.batchResults, (result: LibraryDeleteResult) => {
                ListItem() {
                  Text(result.title + '：删除未完成，可重试').id('library-delete-result-status-' + result.id)
                    .fontSize(13).fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
                }
              }, (result: LibraryDeleteResult): string => result.kind + ':' + result.id)
            }.width('100%').constraintSize({ maxHeight: 80 })
          }.id('library-batch-results').width('100%').padding({ left: 16, right: 8, bottom: 8 })
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode)).borderRadius(12)
        }

        if (this.message.length > 0) {
          Row({ space: $r('app.float.product_space_8') }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)])
            Text(this.message).fontSize($r('app.float.product_label_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).layoutWeight(1)
          }
          .id('library-message').width('100%').padding($r('app.float.product_space_12'))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'errorContainer', this.bookshelfDefaultMode)).borderRadius($r('app.float.product_radius_control'))
        }

        if (this.quarantinedOrphanCount > 0) {
          Row({ space: $r('app.float.product_space_8') }) {
            Text(this.resourceText($r('app.string.library_orphan_notice'), this.quarantinedOrphanCount))
              .fontSize($r('app.float.product_caption_size')).fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
              .layoutWeight(1)
            Button($r('app.string.library_cleanup')).id('library-cleanup-orphans')
              .height($r('app.float.product_target_min')).type(ButtonType.Normal)
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
              .borderRadius($r('app.float.product_radius_control')).onClick(() => this.onCleanupOrphans())
          }
          .width('100%').padding($r('app.float.product_space_12'))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode)).borderRadius($r('app.float.product_radius_control'))
        }

        if ((this.organizationReadFailed || this.refreshFailed) && this.browse.organizationKnown) {
          Row() {
            Text('读取失败，原目录、查询和现有内容已保留。').layoutWeight(1)
              .fontSize('14fp').fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            Button('重试').id('library-refresh-retry').height(48).buttonStyle(ButtonStyleMode.TEXTUAL).fontSize('14fp')
              .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
              .onClick((): void => { this.reloadOrganization(); this.onRefresh(); })
          }.id('library-refresh-failure').width('100%').padding({ left: 16, right: 8, top: 8, bottom: 8 })
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode)).borderRadius(16)
        }
        if (this.loading || (this.organization !== undefined && !this.browse.organizationKnown && !this.organizationReadFailed)) {
          ProductStatePanel({ kind: 'loading', title: $r('app.string.library_loading_title'),
            body: $r('app.string.library_loading_body'), bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode }).layoutWeight(1)
        } else if (this.organization !== undefined && !this.browse.organizationKnown) {
          ProductStatePanel({ kind: 'error', title: '目录尚不可读取', body: '原目录和查询已保留，请重试。',
            showAction: true, actionLabel: '重试', actionId: 'library-refresh-retry',
            onAction: (): void => { this.reloadOrganization(); this.onRefresh(); },
            bookshelfTheme: this.bookshelfTheme, bookshelfDefaultMode: this.bookshelfDefaultMode })
            .id('library-organization-unavailable').layoutWeight(1)
        } else if (this.levelIsEmpty() && this.browse.query.trim().length === 0) {
          ProductStatePanel({ kind: 'empty', title: this.browse.folderId ? '空文件夹' : $r('app.string.library_empty_title'),
            body: '可以导入本地图书，或在更多中新建文件夹。', showAction: true, actionLabel: $r('app.string.library_import'),
            actionId: 'library-empty-import', onAction: (): void => this.onImport(),
            bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode }).layoutWeight(1)
        } else if (this.filteredEntries().length === 0 && this.filteredFolders().length === 0) {
          ProductStatePanel({ kind: 'no-results', title: $r('app.string.library_no_results_title'),
            body: $r('app.string.library_no_results_body'), showAction: true,
            actionLabel: $r('app.string.library_clear_search'), actionId: 'library-clear-search',
            bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode,
            onAction: (): void => this.clearSearch() }).layoutWeight(1)
        } else {
          Column() {
            ForEach([this.browse.folderId + '|' + this.browse.query + '|' + this.browse.sort], (contextKey: string) => {
            Grid(this.gridScroller) {
              LazyForEach(this.gridSource, (item: LibraryGridItem) => {
                if (item.folder !== undefined) {
                ForEach([item.folder], (folder: LibraryFolder) => {
                GridItem() {
                  LibraryFolderGridCard({ folder: this.currentFolder(folder.folderId), menuMaterial: this.menuMaterial,
                    selectionMode: this.selectionMode, selectedFolder: this.selectedFolderIds.includes(folder.folderId),
                    onSelect: (id: string): void => this.toggleFolderSelection(id),
                    onLongPress: (id: string): void => this.selectFolderFromLongPress(id),
                    cellWidthVp: this.gridGeometry.cellWidthVp, theme: this.bookshelfTheme, defaultMode: this.bookshelfDefaultMode,
                    directBooks: this.folderPreview(folder.folderId)?.directBooks ?? 0, directFolders: this.folderPreview(folder.folderId)?.directFolders ?? 0,
                    preview: this.folderPreview(folder.folderId),
                    onMoreSource: (id: string): void => this.rememberManagementSource(id),
                    onSourceFocus: (id: string): void => this.sourceFocused(id),
                    onSourceArea: (id: string): void => this.restoreSourceFocus(id),
                    onMoreDismiss: (): void => this.returnManagementFocus(),
                    onFolderAction: (current: LibraryFolder, intent: string): void => this.openFolderAction(current, intent) })
                }
                  .id('library-folder-' + folder.folderId).align(Alignment.TopStart).focusable(true)
                  .accessibilityText(this.currentFolder(folder.folderId)?.name ?? '')
                  .onClick((): void => this.enterFolder(folder.folderId))
                  .onKeyEvent((event: KeyEvent): boolean => {
                    if (event.type !== KeyType.Up || (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_SPACE)) return false;
                    this.enterFolder(folder.folderId); return true;
                  })
                  .onFocus((): void => this.sourceFocused('library-folder-' + folder.folderId))
                  .onAreaChange((): void => this.restoreSourceFocus('library-folder-' + folder.folderId))
              }, (folder: LibraryFolder): string => folder.folderId)
                } else if (item.entry !== undefined) {
                ForEach([item.entry], (entry: LibraryEntry) => {
                GridItem() {
                  LibraryBookGridCard({ entry: this.currentEntry(entry.book.bookId), menuMaterial: this.menuMaterial,
                    cellWidthVp: this.gridGeometry.cellWidthVp, theme: this.bookshelfTheme, defaultMode: this.bookshelfDefaultMode,
                    selectionMode: this.selectionMode, selectedBook: this.selectedBookIds.includes(entry.book.bookId),
                    organizationAvailable: this.organization !== undefined, progressText: this.currentProgressLabel(entry.book.bookId),
                    onActivate: (id: string): void => this.activateBookId(id),
                    onSelect: (id: string): void => this.toggleSelection(id),
                    onLongPress: (id: string): void => this.enterSelectionFromLongPress(id),
                    onMoreSource: (id: string): void => this.rememberManagementSource(id),
                    onSourceFocus: (id: string): void => this.sourceFocused(id),
                    onSourceArea: (id: string): void => this.restoreSourceFocus(id),
                    onMoreDismiss: (): void => this.returnManagementFocus(),
                    onDetails: (current: LibraryEntry): void => this.openDetails(current),
                    onRename: (current: LibraryEntry): void => this.openRename(current),
                    onOrganization: (current: LibraryEntry): void => this.openOrganizationBook(current.book),
                    onDelete: (current: LibraryEntry): void => {
                      this.pendingDelete = current.book; this.deletionKind = 'book'; this.openDeletionDialog();
                    } })
                }
                  .id('library-source-grid-' + entry.book.bookId).align(Alignment.TopStart).focusable(true)
                  .accessibilityText(this.currentEntry(entry.book.bookId)?.book.title ?? '')
                  .onClick((): void => this.activateBookId(entry.book.bookId))
                  .onKeyEvent((event: KeyEvent): boolean => this.browseBookKey(event, entry.book.bookId))
                  .onAreaChange((): void => this.restoreSourceFocus('library-source-grid-' + entry.book.bookId))
              }, (entry: LibraryEntry): string => entry.book.bookId)
                }
              }, (item: LibraryGridItem): string => item.key)
            }.id('library-auto-grid')
              .scrollBar(BarState.Auto).scrollBarWidth(2)
              .scrollBarColor(this.bookshelfTheme === 'starry' || this.bookshelfDefaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
              // Keep native layout measurable while concealing intermediate restore frames.
              .opacity(this.restoredMode === this.viewMode ? 1 : 0)
              .hitTestBehavior(this.restoredMode === this.viewMode ? HitTestMode.Default : HitTestMode.None)
              .focusable(true).onFocus((): void => this.sourceFocused('library-auto-grid'))
              .onAreaChange((_old: Area, area: Area): void => {
                const width = Number.parseFloat(area.width.toString());
                if (Number.isFinite(width) && width > 0) this.gridMeasuredWidthVp = width;
                this.restoreBrowsePosition('grid');
              })
              .onScrollIndex((_first: number, last: number): void => this.restoreBrowsePosition('grid', last))
              .onDidScroll((): void => {
                if (this.restoredMode !== this.viewMode) this.restoreBrowsePosition('grid');
                if (this.sourceFocusPending) this.restoreSourceFocus(this.browse.sourceItemId);
              })
              .onScrollStop((): void => this.saveBrowsePosition())
              .cachedCount(2)
              .columnsTemplate(this.gridGeometry.columnsTemplate)
              .columnsGap(this.gridGeometry.columnGapVp).rowsGap(this.gridGeometry.rowGapVp)
              .layoutWeight(1).width(this.gridGeometry.gridWidthVp)
            }, (contextKey: string): string => contextKey)
          }.width('100%').layoutWeight(1).alignItems(HorizontalAlign.Center)
            .onAreaChange((_old: Area, area: Area): void => this.measureGridContent(area))
        }
        }.id('library-content').layoutWeight(1).width('100%')
        if (this.selectionMode) {
          Row({ space: 4 }) {
            this.selectAllButton()
            this.moveSelectedButton()
            this.deleteSelectedButton()
          }.id('library-selection-management').height(64).width('100%').constraintSize({ maxWidth: 480 })
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode)).borderRadius(24)
            .transition(TransitionEffect.OPACITY)
        }
      }
      .width('100%').height('100%').enabled(!this.batchConfirm)
      .padding({
        left: (this.renderHeader ? this.windowSnapshot.safeInsets.left : 0) + this.pageInsetVp(),
        right: (this.renderHeader ? this.windowSnapshot.safeInsets.right : 0) + this.pageInsetVp(),
        top: this.renderHeader ? this.windowSnapshot.safeInsets.top : 0,
        bottom: this.renderHeader ? this.windowSnapshot.safeInsets.bottom + 12 : 12
      })
      .backgroundColor(Color.Transparent)

    }.width('100%').height('100%')

  }

  // Keep native options literal so ArkUI binds the title Builder correctly.
  @Builder private ordinaryLibrarySheet() {
    Stack() { this.libraryBody() }.width('100%').height('100%')
      .bindSheet($$this.detailsVisible, this.detailsSheet(), {
        height: SheetSize.FIT_CONTENT,
        preferType: this.windowSnapshot.usableWidthVp >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
        title: this.detailsTitle(), showClose: false,
        onDisappear: (): void => this.detailsDidClose()
      })
  }
  build() {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        Stack() { this.libraryBody() }.width('100%').height('100%')
          .bindSheet($$this.detailsVisible, this.detailsSheet(), {
            systemMaterial: this.panelMaterial,
            height: SheetSize.FIT_CONTENT,
            preferType: this.windowSnapshot.usableWidthVp >= 600 ? SheetType.CENTER : SheetType.BOTTOM,
            title: this.detailsTitle(), showClose: false,
            onDisappear: (): void => this.detailsDidClose()
          })
      } else { this.ordinaryLibrarySheet() }
    } else { this.ordinaryLibrarySheet() }
  }
}
