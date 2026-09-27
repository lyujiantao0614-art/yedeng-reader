import { common } from '@kit.AbilityKit';
import { KeyCode } from '@kit.InputKit';
import { LibraryPresentationApplication } from '../application/LibraryPresentationApplication';
import { BookmarkApplication } from '../application/BookmarkApplication';
import { ProductStatePanel } from '../components/ProductStatePanel';
import { ProductTopBar } from '../components/ProductTopBar';
import { BookshelfBackground } from '../components/BookshelfBackground';
import { BookshelfDefaultMode, BookshelfTheme, LibraryViewMode } from '../domain/LibraryPresentation';
import { bookshelfColor, bookshelfOuterText } from '../layout/BookshelfThemePalette';
import { Book, BookmarkPoint } from '../domain/Models';
import { filterAndSortLibrary, LibraryEntry, LibrarySort } from '../services/LibraryQueryService';
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT,
  adaptivePageInsetVp,
  libraryGridColumnsTemplate
} from '../layout/AdaptiveLayoutPolicy';

// API 21 List and constraintSize signatures require numeric vp values rather than Resource objects.
const LIBRARY_LIST_GAP_VP: number = 12;
const LIBRARY_MODAL_MAX_WIDTH_VP: number = 340;

export interface BookDeleteResult {
  bookId: string;
  succeeded: boolean;
}

@Component
export struct LibraryPage {
  @Prop entries: LibraryEntry[] = [];
  @Prop loading: boolean = false;
  @Prop message: string = '';
  @Prop quarantinedOrphanCount: number = 0;
  @Prop fontSizeScale: number = 1;
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop renderBackground: boolean = true;
  presentation?: LibraryPresentationApplication;
  bookmarks?: BookmarkApplication;
  onImport: () => void = (): void => {};
  onSettings: () => void = (): void => {};
  onOpen: (book: Book) => void = (_book: Book): void => {};
  onOpenBookmark: (book: Book, point: BookmarkPoint) => void =
    (_book: Book, _point: BookmarkPoint): void => {};
  onDelete: (book: Book) => void = (_book: Book): void => {};
  onDeleteSelected: (books: Book[]) => Promise<BookDeleteResult[]> =
    async (books: Book[]): Promise<BookDeleteResult[]> =>
      books.map((book: Book): BookDeleteResult => ({ bookId: book.bookId, succeeded: false }));
  onRename: (book: Book, title: string, author: string) => Promise<boolean> =
    async (_book: Book, _title: string, _author: string): Promise<boolean> => false;
  onBookSize: (book: Book) => Promise<number | undefined> =
    async (_book: Book): Promise<number | undefined> => undefined;
  onRepair: (book: Book) => void = (_book: Book): void => {};
  onCleanupOrphans: () => void = (): void => {};

  @State private query: string = '';
  @State private sort: LibrarySort = 'recent';
  @State private viewMode: LibraryViewMode = 'grid';
  @State private detailsEntry?: LibraryEntry = undefined;
  @State private actionsEntry?: LibraryEntry = undefined;
  @State private bookmarkEntry?: LibraryEntry = undefined;
  @State private bookmarkPoints: BookmarkPoint[] = [];
  @State private bookmarkLoading: boolean = false;
  @State private bookmarkError: string = '';
  @State private bookmarkBusy: boolean = false;
  private bookmarkRevision: number = 0;
  @State private renamingEntry?: LibraryEntry = undefined;
  @State private editTitle: string = '';
  @State private editAuthor: string = '';
  @State private renameSaving: boolean = false;
  @State private renameError: string = '';
  @State private detailSize: string = '';
  private detailRevision: number = 0;
  @State private pendingDelete?: Book = undefined;
  @State private selectionMode: boolean = false;
  @State private selectedBookIds: string[] = [];
  @State private batchConfirm: boolean = false;
  @State private batchBusy: boolean = false;
  @State private batchResults: BookDeleteResult[] = [];
  private batchBooks: Book[] = [];

  aboutToAppear(): void {
    this.viewMode = this.presentation?.loadViewMode() ?? 'grid';
  }

  private filteredEntries(): LibraryEntry[] {
    return filterAndSortLibrary(this.entries, this.query, this.sort);
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
    this.selectionMode = true;
    this.selectedBookIds = [bookId];
    this.batchResults = [];
  }

  private leaveSelection(): void {
    if (this.batchBusy) return;
    this.selectionMode = false;
    this.selectedBookIds = [];
    this.batchConfirm = false;
    this.batchResults = [];
  }

  private toggleVisibleSelection(): void {
    const visible = this.filteredEntries().map((entry: LibraryEntry): string => entry.book.bookId);
    const allSelected = visible.every((id: string): boolean => this.selectedBookIds.includes(id));
    this.batchResults = [];
    this.selectedBookIds = allSelected ? this.selectedBookIds.filter((id: string): boolean => !visible.includes(id)) :
      [...this.selectedBookIds, ...visible.filter((id: string): boolean => !this.selectedBookIds.includes(id))];
  }

  private async confirmSelectedDeletion(): Promise<void> {
    if (this.batchBusy || this.batchBooks.length === 0) return;
    this.batchBusy = true;
    const books = this.batchBooks;
    try {
      this.batchResults = await this.onDeleteSelected(books);
    } catch (_) {
      this.batchResults = books.map((book: Book): BookDeleteResult => ({ bookId: book.bookId, succeeded: false }));
    } finally {
      this.batchBusy = false;
      this.batchConfirm = false;
      this.selectedBookIds = this.batchResults.filter((result: BookDeleteResult): boolean => !result.succeeded)
        .map((result: BookDeleteResult): string => result.bookId);
      if (this.selectedBookIds.length === 0) this.selectionMode = false;
    }
  }

  private keepBatchFocus(event: KeyEvent, nextId: string): void {
    if (event.type !== KeyType.Down || event.keyCode !== KeyCode.KEYCODE_TAB) return;
    try { this.getUIContext().getFocusController().requestFocus(nextId); } catch (_) {}
    event.stopPropagation();
  }

  private entryRenderKey(entry: LibraryEntry): string {
    return `${entry.book.bookId}:${entry.book.title}:${entry.book.author ?? ''}:${entry.book.sourceState}`;
  }

  private pageInsetVp(): number {
    return adaptivePageInsetVp(this.windowSnapshot.sizeClass);
  }

  private compactLargeText(): boolean {
    return this.windowSnapshot.sizeClass === 'compact' && this.fontSizeScale >= 1.3;
  }

  private setViewMode(mode: LibraryViewMode): void {
    this.viewMode = mode;
    this.presentation?.saveViewMode(mode);
  }

  private clearSearch(): void {
    this.query = '';
    this.selectedBookIds = [];
    this.batchResults = [];
    try { this.getUIContext().getFocusController().requestFocus('library-search'); } catch (_) {}
  }

  private sortLabel(): ResourceStr {
    if (this.sort === 'title') return $r('app.string.library_sort_title');
    if (this.sort === 'imported') return $r('app.string.library_sort_imported');
    return $r('app.string.library_sort_recent');
  }

  private progressLabel(entry: LibraryEntry): string {
    const percentage = Math.max(0, Math.min(100, Math.round(entry.percentage * 100)));
    return this.resourceText($r('app.string.library_progress_approx'), percentage);
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
    return new Intl.DateTimeFormat('zh-CN', {
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit'
    }).format(new Date(value));
  }

  private formatBookSize(bytes: number): string {
    if (bytes < 1024) return `${bytes} B`;
    if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private openDetails(entry: LibraryEntry): void {
    this.actionsEntry = undefined;
    this.detailsEntry = entry;
    this.detailSize = '正在读取…';
    const revision = ++this.detailRevision;
    this.onBookSize(entry.book).then((bytes: number | undefined): void => {
      if (revision !== this.detailRevision) return;
      this.detailSize = bytes === undefined ? '不可用' : this.formatBookSize(bytes);
    }).catch((): void => {
      if (revision === this.detailRevision) this.detailSize = '不可用';
    });
  }

  private openActions(entry: LibraryEntry): void {
    this.actionsEntry = entry;
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

  private async deleteBookmark(entry: LibraryEntry, point: BookmarkPoint): Promise<void> {
    if (this.bookmarks === undefined || this.bookmarkBusy) return;
    this.bookmarkBusy = true;
    this.bookmarkError = '';
    try {
      const points = await this.bookmarks.remove(entry.book.bookId, point.bookmarkId);
      if (this.bookmarkEntry?.book.bookId === entry.book.bookId) this.bookmarkPoints = points;
    } catch (_) { this.bookmarkError = '删除书签失败，请重试。'; }
    finally { this.bookmarkBusy = false; }
  }

  private closeDetails(): void {
    this.detailRevision++;
    this.detailsEntry = undefined;
  }

  private openRename(entry: LibraryEntry): void {
    this.actionsEntry = undefined;
    this.renamingEntry = entry;
    this.editTitle = entry.book.title;
    this.editAuthor = entry.book.author ?? '';
    this.renameError = '';
    this.renameSaving = false;
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
        this.renamingEntry = undefined;
      } else {
        this.renameError = '保存失败，请重试。';
      }
    } catch (_) { this.renameError = '保存失败，请重试。'; }
    finally { this.renameSaving = false; }
  }

  @Builder
  private gridCover(entry: LibraryEntry) {
    Stack() {
      if (entry.book.coverRelativePath !== undefined) {
        Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${entry.book.coverRelativePath}`)
          .width('100%').height($r('app.float.library_grid_cover_height')).objectFit(ImageFit.Contain)
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
          .borderRadius($r('app.float.product_radius_cover')).draggable(false)
      } else {
        Column({ space: $r('app.float.product_space_8') }) {
          SymbolGlyph($r('sys.symbol.list_book')).fontSize($r('app.float.product_space_32'))
            .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          Text(entry.book.title).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).textAlign(TextAlign.Center)
            .maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          Text(entry.book.author ?? $r('app.string.library_unknown_author'))
            .fontSize($r('app.float.product_caption_size')).fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
        }
        .width('100%').height($r('app.float.library_grid_cover_height'))
        .padding($r('app.float.product_space_12')).justifyContent(FlexAlign.Center)
        .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
        .border({ width: 1, color: bookshelfColor(this.bookshelfTheme, 'divider', this.bookshelfDefaultMode) })
      }
    }
    .id('library-book-open-grid').width('100%').height($r('app.float.library_grid_cover_height'))
    .borderRadius($r('app.float.product_radius_cover')).clip(true)
    .onClick(() => this.selectionMode ? this.toggleSelection(entry.book.bookId) :
      entry.book.sourceState === 'missing' ? this.onRepair(entry.book) : this.onOpen(entry.book))
  }

  @Builder
  private compactCover(entry: LibraryEntry) {
    if (entry.book.coverRelativePath !== undefined) {
      Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${entry.book.coverRelativePath}`)
        .width($r('app.float.library_list_cover_width')).height($r('app.float.library_list_cover_height'))
        .objectFit(ImageFit.Contain).backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
        .borderRadius($r('app.float.product_radius_cover')).draggable(false)
        .onClick(() => this.selectionMode ? this.toggleSelection(entry.book.bookId) :
          entry.book.sourceState === 'missing' ? this.onRepair(entry.book) : this.onOpen(entry.book))
    } else {
      Column() {
        SymbolGlyph($r('sys.symbol.list_book')).fontSize($r('app.float.product_section_title_size'))
          .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
      }
      .width($r('app.float.library_list_cover_width')).height($r('app.float.library_list_cover_height'))
      .justifyContent(FlexAlign.Center).backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .border({ width: 1, color: bookshelfColor(this.bookshelfTheme, 'divider', this.bookshelfDefaultMode) })
      .borderRadius($r('app.float.product_radius_cover'))
      .onClick(() => this.selectionMode ? this.toggleSelection(entry.book.bookId) :
        entry.book.sourceState === 'missing' ? this.onRepair(entry.book) : this.onOpen(entry.book))
    }
  }

  @Builder
  private bookActionButton(entry: LibraryEntry) {
    if (this.selectionMode) {
      Button() {
        SymbolGlyph(this.selectedBookIds.includes(entry.book.bookId) ?
          $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .fontSize($r('app.float.product_body_size'))
          .fontColor([this.selectedBookIds.includes(entry.book.bookId) ?
            bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode) : bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
      }
      .id('library-book-select').width($r('app.float.product_target_min'))
      .height($r('app.float.product_target_min')).type(ButtonType.Normal)
      .backgroundColor(Color.Transparent).borderRadius($r('app.float.product_radius_control'))
      .accessibilityText(`${this.selectedBookIds.includes(entry.book.bookId) ? '取消选择' : '选择'}${entry.book.title}`)
      .onClick((): void => this.toggleSelection(entry.book.bookId))
    } else {
      Button() {
        SymbolGlyph($r('sys.symbol.ellipsis_circle')).fontSize($r('app.float.product_body_size'))
          .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
      }
      .id('library-book-actions').width($r('app.float.product_target_min'))
      .height($r('app.float.product_target_min')).type(ButtonType.Normal).backgroundColor(Color.Transparent)
      .borderRadius($r('app.float.product_radius_control'))
      .accessibilityText(this.resourceText($r('app.string.library_more_actions_for_book'), entry.book.title))
      .onClick((): void => { this.openActions(entry); })
    }
  }

  @Builder
  private libraryImportButton(fullWidth: boolean) {
    Button($r('app.string.library_import')).id('library-import')
      .height($r('app.float.product_target_min')).fontSize($r('app.float.product_label_size'))
      .fontColor(bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode))
      .backgroundColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_control'))
      .width(fullWidth ? '100%' : 'auto').onClick(() => this.onImport())
  }

  @Builder
  private selectAllButton() {
    Button(this.filteredEntries().every((entry: LibraryEntry): boolean =>
      this.selectedBookIds.includes(entry.book.bookId)) ? '清空' : '全选')
      .id('library-select-all').height($r('app.float.product_target_min'))
      .type(ButtonType.Normal).fontSize($r('app.float.product_label_size'))
      .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode)).backgroundColor(Color.Transparent)
      .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
      .enabled(this.filteredEntries().length > 0)
      .accessibilityText(this.filteredEntries().every((entry: LibraryEntry): boolean =>
        this.selectedBookIds.includes(entry.book.bookId)) ? '清空本页' : '全选本页')
      .onClick((): void => this.toggleVisibleSelection())
  }

  @Builder
  private deleteSelectedButton() {
    if (this.selectedBookIds.length > 0) {
      Button(`删除 ${this.selectedBookIds.length}`).id('library-delete-selected')
        .height($r('app.float.product_target_min')).type(ButtonType.Normal)
        .fontSize($r('app.float.product_label_size'))
        .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode))
        .backgroundColor(bookshelfColor(this.bookshelfTheme, 'errorContainer', this.bookshelfDefaultMode))
        .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
        .accessibilityText(`删除选中的 ${this.selectedBookIds.length} 本书`)
        .onClick((): void => {
          this.batchBooks = this.selectedEntries().map((entry: LibraryEntry): Book => entry.book);
          this.batchConfirm = this.batchBooks.length > 0;
        })
    }
  }

  @Builder
  private cancelSelectionButton() {
    Button('取消').id('library-select-cancel')
      .height($r('app.float.product_target_min')).type(ButtonType.Normal)
      .fontSize($r('app.float.product_label_size'))
      .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
      .backgroundColor(Color.Transparent)
      .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
      .onClick((): void => this.leaveSelection())
  }

  @Builder
  private gridCard(entry: LibraryEntry) {
    Column({ space: $r('app.float.product_space_8') }) {
      this.gridCover(entry)
      Text(entry.book.title).fontSize($r('app.float.product_body_small_size')).fontWeight(FontWeight.Medium)
        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).maxLines(this.fontSizeScale >= 1.3 ? 3 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
      Row() {
        Text(entry.book.author ?? $r('app.string.library_unknown_author'))
          .fontSize($r('app.float.product_caption_size')).fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        this.bookActionButton(entry)
      }.width('100%')
      Text(this.progressLabel(entry)).fontSize($r('app.float.product_caption_size'))
        .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
      if (entry.book.sourceState === 'missing' && !this.selectionMode) {
        Text($r('app.string.library_missing_source')).fontSize($r('app.float.product_caption_size'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
        Button($r('app.string.library_repair')).id('missing-source-recovery-grid')
          .height($r('app.float.product_target_min')).fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode)).width('100%')
          .borderRadius($r('app.float.product_radius_control'))
          .onClick(() => this.onRepair(entry.book))
      }
    }.id('library-book-card').width('100%').alignItems(HorizontalAlign.Start)
      .priorityGesture(LongPressGesture({ duration: 500 })
        .onAction((): void => this.enterSelectionFromLongPress(entry.book.bookId)))
  }

  @Builder
  private listRow(entry: LibraryEntry) {
    Row({ space: $r('app.float.product_space_12') }) {
      this.compactCover(entry)
      Column({ space: $r('app.float.product_space_4') }) {
        Text(entry.book.title).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium)
          .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).maxLines(2).width('100%')
        Text(entry.book.author ?? $r('app.string.library_unknown_author'))
          .fontSize($r('app.float.product_body_small_size')).fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
          .maxLines(1).width('100%')
        Text(this.resourceText($r('app.string.library_list_status'), this.progressLabel(entry),
          this.resourceText(entry.book.sourceState === 'missing' ? $r('app.string.library_source_missing_short') :
            $r('app.string.library_source_available_short'))))
          .fontSize($r('app.float.product_caption_size'))
          .fontColor(entry.book.sourceState === 'missing' ? bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode) :
            bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
        if (entry.book.sourceState === 'missing' && !this.selectionMode) {
          Button($r('app.string.library_repair')).id('missing-source-recovery-list')
            .height($r('app.float.product_target_min')).fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
            .borderRadius($r('app.float.product_radius_control')).onClick(() => this.onRepair(entry.book))
        }
      }
      .id('library-book-open-list').layoutWeight(1).alignItems(HorizontalAlign.Start)
      .onClick(() => this.selectionMode ? this.toggleSelection(entry.book.bookId) :
        entry.book.sourceState === 'missing' ? this.onRepair(entry.book) : this.onOpen(entry.book))
      this.bookActionButton(entry)
    }
    .id('library-book-row').width('100%').padding($r('app.float.product_space_12'))
    .backgroundColor(this.selectionMode && this.selectedBookIds.includes(entry.book.bookId) ?
      bookshelfColor(this.bookshelfTheme, 'accentContainer', this.bookshelfDefaultMode) : bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
    .borderRadius($r('app.float.product_radius_card'))
    .priorityGesture(LongPressGesture({ duration: 500 })
      .onAction((): void => this.enterSelectionFromLongPress(entry.book.bookId)))
  }

  @Builder
  private detailRow(label: ResourceStr, value: ResourceStr) {
    Row({ space: $r('app.float.product_space_12') }) {
      Text(label).fontSize($r('app.float.product_body_small_size'))
        .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('32%')
      Text(value).fontSize($r('app.float.product_body_small_size'))
        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
    }.width('100%').alignItems(VerticalAlign.Top)
  }

  @Builder
  private actionsOverlay(entry: LibraryEntry) {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
        .onClick((): void => { this.actionsEntry = undefined; })
      Column() {
        Row({ space: $r('app.float.product_space_8') }) {
          Column({ space: $r('app.float.product_space_4') }) {
            Text('图书操作').fontSize($r('app.float.product_surface_title_size'))
              .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            Text(entry.book.title).fontSize($r('app.float.product_body_small_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          }
          .id('library-actions-close').width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min')).type(ButtonType.Normal)
          .backgroundColor(Color.Transparent).borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.common_close'))
          .onClick((): void => { this.actionsEntry = undefined; })
        }.width('100%').padding({ bottom: $r('app.float.product_space_8') })
        Button() {
          Row() {
            Text($r('app.string.library_details')).fontSize($r('app.float.product_body_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          }.width('100%')
        }
          .id('library-book-details').width('100%').height($r('app.float.product_target_min'))
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
          .onClick((): void => this.openDetails(entry))
        Button() {
          Row() {
            Text('书签').fontSize($r('app.float.product_body_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          }.width('100%')
        }
          .id('library-bookmarks-open').width('100%').height($r('app.float.product_target_min'))
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
          .onClick((): void => {
            this.actionsEntry = undefined;
            this.bookmarkEntry = entry;
            this.bookmarkPoints = [];
            this.bookmarkError = '';
            this.loadBookmarks(entry);
          })
        Button() {
          Row() {
            Text($r('app.string.library_rename')).fontSize($r('app.float.product_body_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          }.width('100%')
        }
          .id('library-book-rename').width('100%').height($r('app.float.product_target_min'))
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
          .onClick((): void => this.openRename(entry))
        Divider().color(bookshelfColor(this.bookshelfTheme, 'divider', this.bookshelfDefaultMode))
        Button() {
          Text($r('app.string.library_delete')).fontSize($r('app.float.product_body_size'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%').textAlign(TextAlign.Start)
        }
          .id('library-book-delete').width('100%').height($r('app.float.product_target_min'))
          .type(ButtonType.Normal).backgroundColor(Color.Transparent)
          .borderRadius($r('app.float.product_radius_control'))
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
          .onClick((): void => { this.actionsEntry = undefined; this.pendingDelete = entry.book; })
      }
      .id('library-book-actions-surface').width('92%')
      .constraintSize({ maxWidth: 420 })
      .padding({ left: $r('app.float.product_space_16'), right: $r('app.float.product_space_16'),
        top: $r('app.float.product_space_16'), bottom: $r('app.float.product_space_8') })
      .margin({ bottom: this.windowSnapshot.safeInsets.bottom + 12 })
      .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
    }.width('100%').height('100%')
  }

  @Builder
  private bookmarksOverlay(entry: LibraryEntry) {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
        .onClick((): void => { this.bookmarkEntry = undefined; })
      Column({ space: $r('app.float.product_space_12') }) {
        Row({ space: $r('app.float.product_space_8') }) {
          Column({ space: $r('app.float.product_space_4') }) {
            Text('书签').fontSize($r('app.float.product_surface_title_size'))
              .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            Text(entry.book.title).fontSize($r('app.float.product_body_small_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Button() {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize($r('app.float.product_body_small_size'))
              .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
          }
          .id('library-bookmarks-close').width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min')).type(ButtonType.Normal)
          .backgroundColor(Color.Transparent).borderRadius($r('app.float.product_radius_control'))
          .accessibilityText($r('app.string.common_close'))
          .onClick((): void => { this.bookmarkEntry = undefined; })
        }.width('100%')
        if (entry.book.sourceState === 'missing') {
          Text('书籍来源缺失。可查看和删除书签；修复后才能跳转。')
            .fontSize($r('app.float.product_body_small_size'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
          Button('修复书籍来源').id('library-bookmarks-repair')
            .height($r('app.float.product_target_min')).width('100%')
            .onClick((): void => { this.bookmarkEntry = undefined; this.onRepair(entry.book); })
        }
        if (this.bookmarkError.length > 0) {
          Button(this.bookmarkError).id('library-bookmarks-retry')
            .height($r('app.float.product_target_min')).width('100%')
            .type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode))
            .onClick((): void => { this.bookmarkError = ''; this.loadBookmarks(entry); })
        }
        if (this.bookmarkLoading) {
          Text('正在读取书签…').fontSize($r('app.float.product_body_small_size'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
            .padding({ top: $r('app.float.product_space_20'), bottom: $r('app.float.product_space_20') })
        } else if (this.bookmarkError.length === 0 && this.bookmarkPoints.length === 0) {
          Column({ space: $r('app.float.product_space_8') }) {
            Text('☆').fontSize($r('app.float.product_section_title_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
            Text('暂无书签').fontSize($r('app.float.product_body_size'))
              .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            Text('阅读时点按顶部星标，就能从这里返回。')
              .fontSize($r('app.float.product_body_small_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).textAlign(TextAlign.Center)
          }
          .id('library-bookmarks-empty').width('100%')
          .padding({ top: $r('app.float.product_space_20'), bottom: $r('app.float.product_space_20') })
          .alignItems(HorizontalAlign.Center)
        } else if (this.bookmarkError.length === 0) {
          List({ space: LIBRARY_LIST_GAP_VP }) {
            ForEach(this.bookmarkPoints, (point: BookmarkPoint) => {
              ListItem() {
                Row({ space: $r('app.float.product_space_8') }) {
                  Button() {
                    Row({ space: $r('app.float.product_space_8') }) {
                      Text('☆').fontSize($r('app.float.product_body_size'))
                        .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
                      Text(point.label || '未命名位置').fontSize($r('app.float.product_body_small_size'))
                        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
                        .textAlign(TextAlign.Start)
                      SymbolGlyph($r('sys.symbol.chevron_right'))
                        .fontSize($r('app.float.product_body_small_size'))
                        .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
                    }.width('100%')
                  }
                    .id('library-bookmark-jump').height($r('app.float.product_target_min')).layoutWeight(1)
                    .type(ButtonType.Normal).backgroundColor(Color.Transparent)
                    .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
                    .accessibilityText(point.label || '未命名位置')
                    .enabled(entry.book.sourceState === 'available')
                    .onClick((): void => {
                      this.bookmarkEntry = undefined;
                      this.onOpenBookmark(entry.book, point);
                    })
                  Button('删除').id('library-bookmark-delete')
                    .height($r('app.float.product_target_min'))
                    .type(ButtonType.Normal).backgroundColor(Color.Transparent)
                    .fontSize($r('app.float.product_label_size'))
                    .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).enabled(!this.bookmarkBusy)
                    .onClick((): void => { this.deleteBookmark(entry, point).catch((): void => {}); })
                }.width('100%').backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
                  .borderRadius($r('app.float.product_radius_control'))
              }
            }, (point: BookmarkPoint) => point.bookmarkId)
          }.width('100%').constraintSize({ maxHeight: 360 })
        }
      }
      .id('library-bookmarks-surface').width('92%')
      .constraintSize({ maxWidth: 420 })
      .padding($r('app.float.product_space_16'))
      .margin({ bottom: this.windowSnapshot.safeInsets.bottom + 12 })
      .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
    }.width('100%').height('100%')
  }

  @Builder
  private renameOverlay(entry: LibraryEntry) {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
      Column({ space: $r('app.float.product_space_12') }) {
        Text($r('app.string.library_rename')).fontSize($r('app.float.product_surface_title_size'))
          .fontWeight(FontWeight.Bold).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
        Text($r('app.string.library_details_original_title'))
          .fontSize($r('app.float.product_label_size'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
        TextInput({ text: this.editTitle, placeholder: $r('app.string.library_details_original_title') })
          .id('library-rename-title').maxLength(120).height($r('app.float.product_target_min'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
          .borderRadius($r('app.float.product_radius_control'))
          .enabled(!this.renameSaving)
          .onChange((value: string): void => { this.editTitle = value; this.renameError = ''; })
        Text($r('app.string.library_details_author'))
          .fontSize($r('app.float.product_label_size'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
        TextInput({ text: this.editAuthor, placeholder: $r('app.string.library_unknown_author') })
          .id('library-rename-author').maxLength(120).height($r('app.float.product_target_min'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
          .borderRadius($r('app.float.product_radius_control'))
          .enabled(!this.renameSaving)
          .onChange((value: string): void => { this.editAuthor = value; this.renameError = ''; })
        if (this.renameError.length > 0) {
          Text(this.renameError).id('library-rename-error')
            .fontSize($r('app.float.product_label_size'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
        }
        Row({ space: $r('app.float.product_space_12') }) {
          Button($r('app.string.common_cancel')).id('library-rename-cancel')
            .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
            .borderRadius($r('app.float.product_radius_control'))
            .enabled(!this.renameSaving)
            .onClick((): void => { this.renamingEntry = undefined; })
          Button($r('app.string.library_rename_save')).id('library-rename-save')
            .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode))
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
            .borderRadius($r('app.float.product_radius_control'))
            .enabled(!this.renameSaving)
            .onClick((): void => { this.saveRename().catch((): void => {}); })
        }.width('100%')
      }
      .id('library-book-rename-surface').width('88%')
      .constraintSize({ maxWidth: LIBRARY_MODAL_MAX_WIDTH_VP })
      .padding($r('app.float.product_space_20')).backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
    }.width('100%').height('100%')
  }

  @Builder
  private detailsOverlay(entry: LibraryEntry) {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
        .onClick((): void => this.closeDetails())
      Column({ space: $r('app.float.product_space_12') }) {
        Text($r('app.string.library_details_title')).fontSize($r('app.float.product_surface_title_size'))
          .fontWeight(FontWeight.Bold).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
        this.detailRow($r('app.string.library_details_original_title'), entry.book.title)
        this.detailRow($r('app.string.library_details_author'),
          entry.book.author ?? $r('app.string.library_unknown_author'))
        this.detailRow($r('app.string.library_details_size'), this.detailSize)
        this.detailRow($r('app.string.library_details_imported'), this.formatDate(entry.book.importedAt))
        if (entry.book.lastOpenedAt !== undefined) {
          this.detailRow($r('app.string.library_details_last_opened'), this.formatDate(entry.book.lastOpenedAt))
        }
        this.detailRow($r('app.string.library_details_progress'), this.progressLabel(entry))
        this.detailRow($r('app.string.library_details_source'), entry.book.sourceState === 'missing' ?
          $r('app.string.library_source_missing') : $r('app.string.library_source_available'))
        Button($r('app.string.common_close')).id('library-book-details-close')
          .height($r('app.float.product_target_min')).type(ButtonType.Normal)
          .fontColor(bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode)).width('100%')
          .borderRadius($r('app.float.product_radius_control'))
          .onClick((): void => this.closeDetails())
      }
      .id('library-book-details-surface').width('88%')
      .constraintSize({ maxWidth: LIBRARY_MODAL_MAX_WIDTH_VP })
      .padding($r('app.float.product_space_20')).backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
    }.width('100%').height('100%')
  }

  @Builder
  private deleteOverlay(book: Book) {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
      Column({ space: $r('app.float.product_space_12') }) {
        Text($r('app.string.library_delete_title')).fontSize($r('app.float.product_surface_title_size'))
          .fontWeight(FontWeight.Bold).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
        Text($r('app.string.library_delete_body')).fontSize($r('app.float.product_body_small_size'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
        Row({ space: $r('app.float.product_space_12') }) {
          Button($r('app.string.common_cancel')).id('library-delete-cancel')
            .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => { this.pendingDelete = undefined; })
          Button($r('app.string.library_delete')).id('library-delete-confirm')
            .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode)).backgroundColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => { this.pendingDelete = undefined; this.onDelete(book); })
        }.width('100%')
      }
      .id('library-delete-confirmation').width('88%')
      .constraintSize({ maxWidth: LIBRARY_MODAL_MAX_WIDTH_VP })
      .padding($r('app.float.product_space_20')).backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
    }.width('100%').height('100%')
  }

  @Builder
  private batchDeleteOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {}.width('100%').height('100%').backgroundColor($r('app.color.product_scrim'))
      Column({ space: $r('app.float.product_space_12') }) {
        Text(`删除选中的 ${this.batchBooks.length} 本书？`)
          .fontSize($r('app.float.product_surface_title_size')).fontWeight(FontWeight.Bold)
          .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
        Text($r('app.string.library_delete_body')).fontSize($r('app.float.product_body_small_size'))
          .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
        List({ space: LIBRARY_LIST_GAP_VP }) {
          ForEach(this.batchBooks, (book: Book) => {
            ListItem() {
              Column({ space: $r('app.float.product_space_4') }) {
                Text(book.title).fontSize($r('app.float.product_body_size'))
                  .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
                Text(`${book.author ?? '未知作者'} · ${this.formatDate(book.importedAt)}`)
                  .fontSize($r('app.float.product_caption_size'))
                  .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).width('100%')
              }.width('100%')
            }
          }, (book: Book) => book.bookId)
        }.width('100%').constraintSize({ maxHeight: 280 })
        Row({ space: $r('app.float.product_space_12') }) {
          Button('取消').id('library-batch-delete-cancel')
            .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
            .focusable(true).defaultFocus(true)
            .onKeyEvent((event: KeyEvent): void =>
              this.keepBatchFocus(event, 'library-batch-delete-confirm'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
            .enabled(!this.batchBusy)
            .onClick((): void => { this.batchConfirm = false; })
          Button(this.batchBusy ? '正在删除…' : `删除 ${this.batchBooks.length} 本`)
            .id('library-batch-delete-confirm').height($r('app.float.product_target_min'))
            .focusable(true)
            .onKeyEvent((event: KeyEvent): void =>
              this.keepBatchFocus(event, 'library-batch-delete-cancel'))
            .layoutWeight(1).type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode)).backgroundColor(bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode))
            .enabled(!this.batchBusy)
            .onClick((): void => { this.confirmSelectedDeletion().catch((): void => {}); })
        }.width('100%')
      }
      .id('library-batch-delete-confirmation').width('88%')
      .constraintSize({ maxWidth: 420 })
      .padding($r('app.float.product_space_20')).backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
      .borderRadius($r('app.float.product_radius_modal'))
      .onAppear((): void => {
        try { this.getUIContext().getFocusController().requestFocus('library-batch-delete-cancel'); } catch (_) {}
      })
    }.width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.renderBackground) {
        BookshelfBackground({ theme: this.bookshelfTheme, defaultMode: this.bookshelfDefaultMode })
      }
      Column({ space: $r('app.float.product_space_12') }) {
        Row({ space: $r('app.float.product_space_12') }) {
          Row({ space: $r('app.float.product_space_8') }) {
            Image($r('app.media.startIcon')).width(28).height(28).objectFit(ImageFit.Contain)
              .accessibilityLevel('no')
            Text($r('app.string.brand_name')).fontSize($r('app.float.product_section_title_size'))
              .fontWeight(FontWeight.Bold).fontColor(bookshelfOuterText(this.bookshelfTheme, false,
                this.bookshelfDefaultMode))
          }.layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.gearshape')).fontSize($r('app.float.product_section_title_size'))
              .fontColor([bookshelfOuterText(this.bookshelfTheme, false, this.bookshelfDefaultMode)])
          }
          .id('library-settings').width($r('app.float.product_target_min'))
          .height($r('app.float.product_target_min')).type(ButtonType.Normal)
          .backgroundColor(Color.Transparent).accessibilityText($r('app.string.library_settings'))
          .onClick(() => this.onSettings())
        }.width('100%').alignItems(VerticalAlign.Center)
        ProductTopBar({ title: $r('app.string.library_title'), subtitle: $r('app.string.library_subtitle'),
          bookshelfTheme: this.bookshelfTheme, bookshelfDefaultMode: this.bookshelfDefaultMode })
        Column({ space: $r('app.float.product_space_12') }) {
        Row({ space: $r('app.float.product_space_8') }) {
          TextInput({ placeholder: $r('app.string.library_search_placeholder'), text: this.query })
            .id('library-search').onChange((value: string) => {
              this.query = value;
              this.selectedBookIds = [];
              this.batchResults = [];
            })
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).placeholderColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
            .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode)).borderRadius($r('app.float.product_radius_control'))
            .height($r('app.float.product_target_min')).layoutWeight(1)
            .border({ width: 1, color: bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode) })
          if (this.query.length > 0) {
            Button($r('app.string.library_clear_search')).id('library-clear-search-inline')
              .height($r('app.float.product_target_min')).type(ButtonType.Normal)
              .fontSize($r('app.float.product_label_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
              .backgroundColor(bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
              .borderRadius($r('app.float.product_radius_control'))
              .onClick(() => this.clearSearch())
          }
        }.width('100%')

        Column({ space: $r('app.float.product_space_8') }) {
          Row({ space: $r('app.float.product_space_8') }) {
            Button() {
              SymbolGlyph($r('sys.symbol.square_grid_2x2')).fontSize($r('app.float.product_body_size'))
                .fontColor([this.viewMode === 'grid' ? bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode) :
                  bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
            }
            .id('library-view-grid').width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
            .type(ButtonType.Normal).backgroundColor(this.viewMode === 'grid' ? bookshelfColor(this.bookshelfTheme, 'accentContainer', this.bookshelfDefaultMode) :
              Color.Transparent).borderRadius($r('app.float.product_radius_control'))
            .accessibilityText($r('app.string.library_view_grid'))
            .onClick(() => this.setViewMode('grid'))
            Button() {
              SymbolGlyph($r('sys.symbol.list_bullet')).fontSize($r('app.float.product_body_size'))
                .fontColor([this.viewMode === 'list' ? bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode) :
                  bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
            }
            .id('library-view-list').width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
            .type(ButtonType.Normal).backgroundColor(this.viewMode === 'list' ? bookshelfColor(this.bookshelfTheme, 'accentContainer', this.bookshelfDefaultMode) :
              Color.Transparent).borderRadius($r('app.float.product_radius_control'))
            .accessibilityText($r('app.string.library_view_list'))
            .onClick(() => this.setViewMode('list'))
            Blank().layoutWeight(1)
            Button(this.sortLabel()).id('library-sort').height($r('app.float.product_target_min'))
              .type(ButtonType.Normal).fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
              .backgroundColor(Color.Transparent)
              .borderRadius($r('app.float.product_radius_control')).bindMenu([
                { value: $r('app.string.library_sort_recent'), action: (): void => { this.sort = 'recent'; } },
                { value: $r('app.string.library_sort_title'), action: (): void => { this.sort = 'title'; } },
                { value: $r('app.string.library_sort_imported'), action: (): void => { this.sort = 'imported'; } }
              ])
            if (!this.compactLargeText()) {
              this.libraryImportButton(false)
            }
          }.width('100%')
          if (this.compactLargeText()) {
            this.libraryImportButton(true)
          }
        }.id('library-view-mode').width('100%')

        if (this.entries.length > 0) {
          if (this.selectionMode) {
            if (this.compactLargeText()) {
              Column({ space: $r('app.float.product_space_4') }) {
                Row() {
                  Text(`已选 ${this.selectedBookIds.length} 本`).id('library-selected-count-large')
                    .fontSize($r('app.float.product_body_small_size'))
                    .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1)
                  this.cancelSelectionButton()
                }.width('100%')
                Row({ space: $r('app.float.product_space_8') }) {
                  Blank().layoutWeight(1)
                  this.selectAllButton()
                  this.deleteSelectedButton()
                }.width('100%')
              }.width('100%').id('library-selection-toolbar-large')
            } else {
              Row({ space: $r('app.float.product_space_4') }) {
                Text(`已选 ${this.selectedBookIds.length} 本`).id('library-selected-count')
                  .fontSize($r('app.float.product_body_small_size'))
                  .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).layoutWeight(1).maxLines(1)
                this.selectAllButton()
                this.deleteSelectedButton()
                this.cancelSelectionButton()
              }.width('100%').id('library-selection-toolbar')
            }
          } else {
            Row() {
              Text(`共 ${this.filteredEntries().length} 本`)
                .fontSize($r('app.float.product_body_small_size'))
                .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)).layoutWeight(1)
              Button('多选').id('library-select-enter')
                .height($r('app.float.product_target_min')).type(ButtonType.Normal)
                .fontSize($r('app.float.product_label_size'))
                .fontColor(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
                .backgroundColor(Color.Transparent)
                .onClick((): void => { this.selectionMode = true; this.batchResults = []; })
            }.width('100%')
          }
        }

        if (this.batchResults.length > 0) {
          Column({ space: $r('app.float.product_space_4') }) {
            Text(`删除结果：成功 ${this.batchResults.filter((result: BookDeleteResult): boolean => result.succeeded).length} 本，失败 ${this.batchResults.filter((result: BookDeleteResult): boolean => !result.succeeded).length} 本。`)
              .fontSize($r('app.float.product_body_small_size'))
              .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode)).width('100%')
            List({ space: 4 }) {
              ForEach(this.batchResults, (result: BookDeleteResult) => {
                ListItem() {
                  Text(`${result.succeeded ? '已删除' : '删除失败，可重试'}：${this.batchBooks.find((book: Book): boolean => book.bookId === result.bookId)?.title ?? '书籍'}`)
                    .fontSize($r('app.float.product_caption_size'))
                    .fontColor(result.succeeded ? bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode) :
                      bookshelfColor(this.bookshelfTheme, 'error', this.bookshelfDefaultMode)).width('100%')
                }
              }, (result: BookDeleteResult) => result.bookId)
            }.width('100%').constraintSize({ maxHeight: 160 })
          }.id('library-batch-results').width('100%')
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

        if (this.loading) {
          ProductStatePanel({ kind: 'loading', title: $r('app.string.library_loading_title'),
            body: $r('app.string.library_loading_body'), bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode }).layoutWeight(1)
        } else if (this.entries.length === 0) {
          ProductStatePanel({ kind: 'empty', title: $r('app.string.library_empty_title'),
            body: $r('app.string.library_empty_body'), showAction: true,
            actionLabel: $r('app.string.library_empty_action'), actionId: 'library-import-empty',
            bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode,
            onAction: (): void => this.onImport() }).layoutWeight(1)
        } else if (this.filteredEntries().length === 0) {
          ProductStatePanel({ kind: 'no-results', title: $r('app.string.library_no_results_title'),
            body: $r('app.string.library_no_results_body'), showAction: true,
            actionLabel: $r('app.string.library_clear_search'), actionId: 'library-clear-search',
            bookshelfTheme: this.bookshelfTheme,
            bookshelfDefaultMode: this.bookshelfDefaultMode,
            onAction: (): void => this.clearSearch() }).layoutWeight(1)
        } else if (this.viewMode === 'grid') {
          Grid() {
            ForEach(this.filteredEntries(), (entry: LibraryEntry) => {
              GridItem() { this.gridCard(entry) }
            }, (entry: LibraryEntry) => this.entryRenderKey(entry))
          }
          .columnsTemplate(libraryGridColumnsTemplate(this.windowSnapshot, this.fontSizeScale))
          .columnsGap($r('app.float.product_space_16')).rowsGap($r('app.float.product_space_24'))
          .layoutWeight(1).width('100%')
        } else {
          List({ space: LIBRARY_LIST_GAP_VP }) {
            ForEach(this.filteredEntries(), (entry: LibraryEntry) => {
              ListItem() { this.listRow(entry) }
            }, (entry: LibraryEntry) => this.entryRenderKey(entry))
          }.layoutWeight(1).width('100%')
        }
        }.id('library-content').layoutWeight(1).width('100%')
          .padding($r('app.float.product_space_12'))
          .backgroundColor(bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode))
          .border({ width: this.bookshelfTheme === 'default' ? 1 : 0,
            color: bookshelfColor(this.bookshelfTheme, 'divider', this.bookshelfDefaultMode) })
      }
      .width('100%').height('100%').enabled(!this.batchConfirm)
      .padding({
        left: this.windowSnapshot.safeInsets.left + this.pageInsetVp(),
        right: this.windowSnapshot.safeInsets.right + this.pageInsetVp(),
        top: this.windowSnapshot.safeInsets.top + 20,
        bottom: this.windowSnapshot.safeInsets.bottom + 12
      })
      .backgroundColor(Color.Transparent)

      if (this.actionsEntry !== undefined) { this.actionsOverlay(this.actionsEntry) }
      if (this.bookmarkEntry !== undefined) { this.bookmarksOverlay(this.bookmarkEntry) }
      if (this.detailsEntry !== undefined) { this.detailsOverlay(this.detailsEntry) }
      if (this.renamingEntry !== undefined) { this.renameOverlay(this.renamingEntry) }
      if (this.pendingDelete !== undefined) { this.deleteOverlay(this.pendingDelete) }
      if (this.batchConfirm) { this.batchDeleteOverlay() }
    }.width('100%').height('100%')
  }
}
