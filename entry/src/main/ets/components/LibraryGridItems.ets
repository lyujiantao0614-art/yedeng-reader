import { common } from '@kit.AbilityKit';
import { nativeMenuOptions } from '../platform/NativeOverlayMaterial';
import { projectBookCard, FolderCardProjection, FolderCoverProjection } from '../application/LibraryCardProjection';
import { KeyCode } from '@kit.InputKit';
import { LibraryFolder } from '../domain/LibraryOrganization';
import { LibraryEntry } from '../services/LibraryQueryService';
import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfColor } from '../layout/BookshelfThemePalette';
import { LIBRARY_COVER_RADIUS_VP, LIBRARY_COVER_AREA_RATIO, LIBRARY_COVER_TITLE_GAP_VP, LIBRARY_TITLE_META_GAP_VP,
  LIBRARY_SYMBOL_SIZE_VP, LIBRARY_FOLDER_SYMBOL_SIZE_VP, LIBRARY_ZERO_PADDING_VP } from '../layout/LibraryGridLayout';

const LIBRARY_R2_4_VP: number = 4;
const LIBRARY_R2_8_VP: number = 8;
const LIBRARY_R2_16_VP: number = 16;
const LIBRARY_R2_24_VP: number = 24;
const LIBRARY_R2_32_VP: number = 32;
const LIBRARY_R2_40_VP: number = 40;

@Component
export struct LibraryBookGridCard {
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  @Prop entry: LibraryEntry | undefined = undefined;
  @Prop cellWidthVp: number = 104;
  @Prop theme: BookshelfTheme = 'default';
  @Prop defaultMode: BookshelfDefaultMode = 'system';
  @Prop selectionMode: boolean = false;
  @Prop selectedBook: boolean = false;
  @Prop organizationAvailable: boolean = false;
  @Prop progressText: string = '';
  onActivate: (bookId: string) => void = (_bookId: string): void => {};
  onSelect: (bookId: string) => void = (_bookId: string): void => {};
  onLongPress: (bookId: string) => void = (_bookId: string): void => {};
  onMoreSource: (id: string) => void = (_id: string): void => {};
  onSourceFocus: (id: string) => void = (_id: string): void => {};
  onSourceArea: (id: string) => void = (_id: string): void => {};
  onMoreDismiss: () => void = (): void => {};
  onDetails: (entry: LibraryEntry) => void = (_entry: LibraryEntry): void => {};
  onRename: (entry: LibraryEntry) => void = (_entry: LibraryEntry): void => {};
  onOrganization: (entry: LibraryEntry) => void = (_entry: LibraryEntry): void => {};
  onDelete: (entry: LibraryEntry) => void = (_entry: LibraryEntry): void => {};

  @State private moreMenuVisible: boolean = false;
  @State private failedCover: string = '';
  private openMore(): void { this.onMoreSource(this.moreId()); this.moreMenuVisible = true; }
  private moreKey(event: KeyEvent): boolean {
    if (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_SPACE) return false;
    event.stopPropagation();
    if (event.type === KeyType.Down) this.openMore();
    return true;
  }
  private dismissMore(): void { this.moreMenuVisible = false; this.onMoreDismiss(); }
  private moreId(): string { return 'library-more-book-' + (this.entry?.book.bookId ?? ''); }
  private invoke(action: (entry: LibraryEntry) => void): void {
    const current = this.entry;
    if (current !== undefined) action(current);
  }
  private stopKey(event: KeyEvent): boolean {
    if (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE) event.stopPropagation();
    return false;
  }
  private moreLabel(): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync($r('app.string.library_more_actions_for_book').id, this.entry?.book.title ?? '');
    } catch (_) { return ''; }
  }

  @Builder
  private bookMoreMenu() {
    Menu() {
      MenuItem({ content: $r('app.string.library_details') }).id('library-book-details').height(48)
        .onClick((): void => this.invoke(this.onDetails))
      MenuItem({ content: '编辑信息' }).id('library-book-rename').height(48)
        .onClick((): void => this.invoke(this.onRename))
      if (this.organizationAvailable) {
        MenuItem({ content: '移动' }).id('library-book-organization').height(48)
          .onClick((): void => this.invoke(this.onOrganization))
      }
      MenuItemGroup() {
        MenuItem({ content: '删除图书' }).id('library-book-delete').height(48)
          .contentFontColor(bookshelfColor(this.theme, 'error', this.defaultMode))
          .onClick((): void => this.invoke(this.onDelete))
      }
    }.id('library-book-actions-surface')
  }

  @Builder
  private bookActionButton() {
    if (this.selectionMode) {
      Button() {
        SymbolGlyph(this.selectedBook ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.circle'))
          .focusable(true).fontSize(LIBRARY_SYMBOL_SIZE_VP).fontColor([bookshelfColor(this.theme, 'accent', this.defaultMode)])
      }.id('library-book-select').width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
        .type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText((this.selectedBook ? '取消选择' : '选择') + (this.entry?.book.title ?? ''))
        .onClick((): void => {
          const current = this.entry;
          if (current !== undefined) this.onSelect(current.book.bookId);
        }).onKeyEvent((event: KeyEvent): boolean => this.stopKey(event))
    } else {
      Button() {
        Text('⋯').fontSize('20fp').fontColor(Color.White).opacity(0.7).width(18).height(24).textAlign(TextAlign.Center)
          .textShadow({ radius: 2, color: $r('app.color.library_cover_label_background') })
          .hitTestBehavior(HitTestMode.None)
      }.id(this.moreId()).width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
        .type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .stateEffect(true)
        .accessibilityText(this.moreLabel())
        .onClick((): void => this.openMore())
        .onFocus((): void => this.onSourceFocus(this.moreId()))
        .onAreaChange((): void => this.onSourceArea(this.moreId()))
        .onKeyEvent((event: KeyEvent): boolean => this.moreKey(event))
        .bindMenu(this.moreMenuVisible, this.bookMoreMenu(), nativeMenuOptions(this.menuMaterial, { onDisappear: (): void => this.dismissMore() }))
    }
  }

  @Builder
  private gridCover() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Stack() {
        if (this.entry?.book.coverRelativePath !== undefined && this.failedCover !== this.entry.book.coverRelativePath) {
          Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${this.entry.book.coverRelativePath}`)
            .width('100%').height('100%').objectFit(ImageFit.Contain).draggable(false)
            .sourceSize({ width: Math.ceil(this.getUIContext().vp2px(this.cellWidthVp)), height: Math.ceil(this.getUIContext().vp2px(this.cellWidthVp * LIBRARY_COVER_AREA_RATIO)) })
            .onError((): void => { this.failedCover = this.entry?.book.coverRelativePath ?? ''; })
        } else {
          Row() {
            Column() {}.width(3).height('100%').backgroundColor(bookshelfColor(this.theme, 'secondary', this.defaultMode)).opacity(0.25)
            Text(this.entry?.book.title ?? '').fontSize('16fp').lineHeight('24fp').maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .fontColor(bookshelfColor(this.theme, 'text', this.defaultMode)).layoutWeight(1)
              .padding({ left: 10, right: 10 })
          }.width('100%').height('100%').padding({ top: 36, bottom: 28 })
        }
      }.id('library-book-open-grid').width('100%').height('100%')
        .accessibilityText(this.entry?.book.title ?? '')
      Column() {
      Text(projectBookCard(this.entry!).formatLabel).fontSize('10fp').fontColor(Color.White)
        .padding({ left: 5, right: 5, top: 2, bottom: 2 }).backgroundColor($r('app.color.library_cover_label_background')).borderRadius(2)
        .margin(6)
      }.width('100%').height('100%').alignItems(HorizontalAlign.Start).hitTestBehavior(HitTestMode.None)
      Column() {
      Blank().layoutWeight(1)
      Row() {
        Text(this.progressText).id('library-book-progress').fontSize('11fp').fontColor(Color.White).maxLines(1)
        if (this.entry?.book.sourceState === 'missing') {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(12).fontColor([Color.White]).margin({ left: 4 })
        }
      }.width('100%').height(22).padding({ left: 6, right: 6 }).backgroundColor($r('app.color.library_cover_progress_background'))
      }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
      this.bookActionButton()
    }.width('100%').height(this.cellWidthVp * LIBRARY_COVER_AREA_RATIO)
      .backgroundColor(bookshelfColor(this.theme, 'muted', this.defaultMode))
      .borderRadius(LIBRARY_COVER_RADIUS_VP).clip(true)
  }

  build() {
    if (this.entry !== undefined) {
      Column({ space: LIBRARY_COVER_TITLE_GAP_VP }) {
        this.gridCover()
        Column({ space: LIBRARY_TITLE_META_GAP_VP }) {
          Button() {
            Text(this.entry.book.title || '未命名图书').id('library-book-title').focusable(true).fontSize('14fp').lineHeight('20fp').fontWeight(FontWeight.Regular)
              .height(40).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .align(Alignment.TopStart)
              .fontColor(bookshelfColor(this.theme, 'text', this.defaultMode)).width('100%')
          }.id('library-book-focus-' + this.entry.book.bookId).focusable(true)
            .width('100%').padding(LIBRARY_ZERO_PADDING_VP).type(ButtonType.Normal).backgroundColor(Color.Transparent)
            .onClick((): void => {
              if (this.entry !== undefined) this.onActivate(this.entry.book.bookId);
            })
            .onFocus((): void => this.onSourceFocus('library-source-grid-' + (this.entry?.book.bookId ?? '')))
            .onAreaChange((): void => this.onSourceArea('library-source-grid-' + (this.entry?.book.bookId ?? '')))
            .onKeyEvent((event: KeyEvent): boolean => {
              if (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_SPACE) return false;
              event.stopPropagation();
              if (event.type === KeyType.Up && this.entry !== undefined) this.onActivate(this.entry.book.bookId);
              return true;
            })
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.id('library-book-card').width('100%').alignItems(HorizontalAlign.Start)
        .priorityGesture(LongPressGesture({ duration: 500 }).onAction((): void => {
          const current = this.entry; if (current !== undefined) this.onLongPress(current.book.bookId);
        }))
    }
  }
}

@Component
export struct LibraryFolderGridCard {
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  @Prop folder: LibraryFolder | undefined = undefined;
  @Prop cellWidthVp: number = 104;
  @Prop theme: BookshelfTheme = 'default';
  @Prop defaultMode: BookshelfDefaultMode = 'system';
  @Prop selectionMode: boolean = false;
  @Prop selectedFolder: boolean = false;
  onSelect: (id: string) => void = (_id: string): void => {};
  onLongPress: (id: string) => void = (_id: string): void => {};
  @Prop directBooks: number = 0;
  @Prop directFolders: number = 0;
  @Prop preview: FolderCardProjection | undefined = undefined;
  @State private failedCovers: string[] = [];
  onMoreSource: (id: string) => void = (_id: string): void => {};
  onSourceFocus: (id: string) => void = (_id: string): void => {};
  onSourceArea: (id: string) => void = (_id: string): void => {};
  onMoreDismiss: () => void = (): void => {};
  onFolderAction: (folder: LibraryFolder, intent: string) => void = (_folder: LibraryFolder, _intent: string): void => {};

  @State private moreMenuVisible: boolean = false;
  private openMore(): void { this.onMoreSource(this.moreId()); this.moreMenuVisible = true; }
  private moreKey(event: KeyEvent): boolean {
    if (event.keyCode !== KeyCode.KEYCODE_ENTER && event.keyCode !== KeyCode.KEYCODE_SPACE) return false;
    event.stopPropagation();
    if (event.type === KeyType.Down) this.openMore();
    return true;
  }
  private dismissMore(): void { this.moreMenuVisible = false; this.onMoreDismiss(); }
  private moreId(): string { return 'library-more-folder-' + (this.folder?.folderId ?? ''); }
  private action(intent: string): void { const current = this.folder; if (current !== undefined) this.onFolderAction(current, intent); }
  private stopKey(event: KeyEvent): boolean {
    if (event.keyCode === KeyCode.KEYCODE_ENTER || event.keyCode === KeyCode.KEYCODE_SPACE) event.stopPropagation();
    return false;
  }
  @Builder
  private folderMoreMenu() {
    Menu() {
      MenuItem({ content: '重命名' }).id('library-folder-more-rename').height(48)
        .onClick((): void => this.action('rename'))
      MenuItem({ content: '移动' }).id('library-folder-more-move').height(48)
        .onClick((): void => this.action('move-folder'))
      MenuItemGroup() {
        MenuItem({ content: '删除文件夹' }).id('library-folder-more-remove').height(48)
          .contentFontColor(bookshelfColor(this.theme, 'error', this.defaultMode))
          .onClick((): void => this.action('remove'))
      }
    }.id('library-folder-actions-surface')
  }
  @Builder
  private previewCover(cover: FolderCoverProjection) {
    Stack() {
      if (cover.coverRelativePath !== undefined && !this.failedCovers.includes(cover.coverRelativePath)) {
        Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${cover.coverRelativePath}`)
          .width('100%').height('100%').objectFit(ImageFit.Contain).draggable(false)
          .sourceSize({ width: Math.ceil(this.getUIContext().vp2px(this.cellWidthVp / 2)), height: Math.ceil(this.getUIContext().vp2px(this.cellWidthVp * 0.75)) })
          .onError((): void => { this.failedCovers = [...this.failedCovers, cover.coverRelativePath ?? '']; })
      } else {
        SymbolGlyph($r('sys.symbol.list_book')).fontSize(LIBRARY_R2_16_VP)
          .fontColor([bookshelfColor(this.theme, 'secondary', this.defaultMode)])
      }
    }.width('100%').height('100%').hitTestBehavior(HitTestMode.None)
  }
  build() {
    if (this.folder !== undefined) {
      Column({ space: LIBRARY_COVER_TITLE_GAP_VP }) {
        // Align the visible thumbnail's bottom with book covers; do not stretch its painted surface.
        Stack({ alignContent: Alignment.Bottom }) {
        Stack({ alignContent: Alignment.TopEnd }) {
          Column() {
            if (this.preview !== undefined && this.preview.covers.length > 0) {
              Grid() {
                ForEach(this.preview.covers, (cover: FolderCoverProjection) => {
                  GridItem() { this.previewCover(cover) }
                }, (cover: FolderCoverProjection): string => cover.bookId)
              }.columnsTemplate(this.preview.covers.length === 1 ? '1fr' : '1fr 1fr')
                .rowsTemplate(this.preview.covers.length <= 2 ? '1fr' : '1fr 1fr').columnsGap(4).rowsGap(4)
                .width('100%').layoutWeight(1).hitTestBehavior(HitTestMode.None)
            } else {
              Column({ space: 4 }) {
                SymbolGlyph($r('sys.symbol.folder_fill')).fontSize(36)
                  .fontColor([bookshelfColor(this.theme, 'accent', this.defaultMode)]).opacity(0.65)
              }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
            }
          }.width('100%').height('100%').padding({ left: 14, right: 14, top: 28, bottom: 14 }).hitTestBehavior(HitTestMode.None)
          if (this.selectionMode) {
            Checkbox({ name: this.folder.folderId }).id('library-folder-select-' + this.folder.folderId)
              .select(this.selectedFolder).width(24).height(24).margin(12)
              .accessibilityText(this.folder.name + '，选择文件夹')
              .onChange((selected: boolean): void => { if (selected !== this.selectedFolder && this.folder) this.onSelect(this.folder.folderId); })
          } else {
          Button() {
            Text('⋯').fontSize('20fp').width(18).height(24).textAlign(TextAlign.Center)
              .fontColor(bookshelfColor(this.theme, 'secondary', this.defaultMode)).opacity(0.7)
              .hitTestBehavior(HitTestMode.None)
          }.id(this.moreId()).width(48).height(48).padding(LIBRARY_ZERO_PADDING_VP)
            .type(ButtonType.Circle).backgroundColor(Color.Transparent)
            .stateEffect(true)
            .accessibilityText(this.folder.name + '，更多操作')
            .onClick((): void => this.openMore())
            .onKeyEvent((event: KeyEvent): boolean => this.moreKey(event))
            .onFocus((): void => this.onSourceFocus(this.moreId()))
            .onAreaChange((): void => this.onSourceArea(this.moreId()))
            .bindMenu(this.moreMenuVisible, this.folderMoreMenu(), nativeMenuOptions(this.menuMaterial, { onDisappear: (): void => this.dismissMore() }))
          }
        }.id('library-folder-cover-' + this.folder.folderId).width('100%').height(this.cellWidthVp * 1.18)
          .backgroundColor(bookshelfColor(this.theme, 'surface', this.defaultMode))
          .border({ width: 0.5, color: bookshelfColor(this.theme, 'divider', this.defaultMode) }).borderRadius(12).clip(true)
        }.width('100%').height(this.cellWidthVp * LIBRARY_COVER_AREA_RATIO)
        Column({ space: 4 }) {
        Text(this.folder.name).id('library-folder-name-' + this.folder.folderId).fontSize('14fp').lineHeight('20fp').fontWeight(FontWeight.Regular)
          .height(40).maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          .align(Alignment.TopStart)
          .fontColor(bookshelfColor(this.theme, 'text', this.defaultMode)).width('100%')
        Text(this.directFolders > 0 ? `${this.directBooks}本 · ${this.directFolders}个子文件夹` : `${this.directBooks}本`)
          .id('library-folder-direct-counts').fontSize('10fp').lineHeight('16fp').maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .fontColor(bookshelfColor(this.theme, 'secondary', this.defaultMode)).width('100%').height(16)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(HorizontalAlign.Start)
        .priorityGesture(LongPressGesture({ duration: 500 }).onAction((): void => {
          if (this.folder) this.onLongPress(this.folder.folderId);
        }))
    }
  }
}
