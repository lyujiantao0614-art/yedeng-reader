import { CustomContentDialog } from '@ohos.arkui.advanced.Dialog';
import deviceInfo from '@ohos.deviceInfo';
import { NoteEntry } from '../domain/Models';
import { BookshelfDefaultMode } from '../domain/LibraryPresentation';
import { bookshelfColor, bookshelfThemeColorMode, BookshelfColorRole } from '../layout/BookshelfThemePalette';
import { ReadingRecordsApplication, ReadingRecordView, ReadingRecordRow, RecordKind, RecordPageAction, recordTime } from '../application/ReadingRecordsApplication';

export class ReadingRecordsPageController {
  private back?: () => boolean;
  bind(back: () => boolean): void { this.back = back; }
  unbind(): void { this.back = undefined; }
  handleBack(): boolean { return this.back?.() ?? false; }
}

@Component
export struct ReadingRecordsPage {
  @Prop @Watch('activeChanged') active: boolean = true;
  @Prop reducedMotion: boolean | undefined = undefined;
  application?: ReadingRecordsApplication;
  pageController: ReadingRecordsPageController = new ReadingRecordsPageController();
  @Prop initialKind: RecordKind = 'notes';
  @Prop defaultMode: BookshelfDefaultMode = 'system';
  @Prop panelMaterial: SystemUiMaterial | undefined = undefined;
  @Prop notice: string = '';
  onExit: () => void = (): void => {};
  onKindChange: (kind: RecordKind) => void = (_kind: RecordKind): void => {};
  onBookmark: (row: ReadingRecordRow) => void = (_row: ReadingRecordRow): void => {};
  @State private kind: RecordKind = 'notes';
  @State private view: ReadingRecordView = { rows: [], hasNext: false, hasPrevious: false, page: 1 };
  @State private notesView: ReadingRecordView = { rows: [], hasNext: false, hasPrevious: false, page: 1 };
  @State private bookmarksView: ReadingRecordView = { rows: [], hasNext: false, hasPrevious: false, page: 1 };
  @State private loading: boolean = false;
  @State private error: string = '';
  private lastAction: RecordPageAction = 'initial';
  private mounted: boolean = false;
  private request: number = 0;
  private detailOpen: boolean = false;
  private detailRequest: number = 0;
  @State private detailRow?: ReadingRecordRow = undefined;
  @State private detailNote?: NoteEntry = undefined;
  @State private detailError: string = '';
  @State private detailLoading: boolean = false;
  private detailDialog: CustomDialogController = this.createDetailDialog();
  private createDetailDialog(): CustomDialogController {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.panelMaterial !== undefined) {
          return new CustomDialogController({
            systemMaterial: this.panelMaterial,
          builder: CustomContentDialog({ contentBuilder: (): void => this.noteDetail(),
            themeColorMode: bookshelfThemeColorMode(this.defaultMode),
            theme: { colors: { brand: this.color('accent'), fontPrimary: this.color('text'),
              fontSecondary: this.color('secondary'), backgroundPrimary: this.color('surface') } } }),
          autoCancel: true, customStyle: false,
          onWillDismiss: (action: DismissDialogAction): void => { this.detailOpen = false; this.detailRequest++; action.dismiss(); }
          });
        }
      }
    }
    return new CustomDialogController({
      builder: CustomContentDialog({ contentBuilder: (): void => this.noteDetail(),
        themeColorMode: bookshelfThemeColorMode(this.defaultMode),
        theme: { colors: { brand: this.color('accent'), fontPrimary: this.color('text'),
          fontSecondary: this.color('secondary'), backgroundPrimary: this.color('surface') } } }),
      autoCancel: true, customStyle: false,
      onWillDismiss: (action: DismissDialogAction): void => { this.detailOpen = false; this.detailRequest++; action.dismiss(); }
    });
  }

  aboutToAppear(): void {
    this.mounted = true; this.kind = this.initialKind;
    this.pageController.bind((): boolean => { if (!this.detailOpen) return false; this.closeDetail(); return true; });
    this.load();
  }
  aboutToDisappear(): void {
    this.mounted = false; this.request++; this.closeDetail(); this.pageController.unbind();
  }
  private activeChanged(): void {
    if (!this.mounted) return;
    this.request++;
    if (this.active) { this.application?.resume(); this.load(); }
    else this.closeDetail();
  }
  private color(role: BookshelfColorRole): ResourceColor { return bookshelfColor('default', role, this.defaultMode); }
  private async load(action: RecordPageAction = 'initial'): Promise<void> {
    const request = ++this.request, kind = this.kind;
    this.loading = true; this.error = ''; this.lastAction = action;
    try {
      if (!this.application) throw new Error('Reading records unavailable');
      const view = await this.application.load(kind, action);
      if (this.mounted && this.active && this.request === request && this.kind === kind) {
        this.view = view;
        if (kind === 'notes') this.notesView = view; else this.bookmarksView = view;
      }
    } catch (_) {
      if (this.mounted && this.active && this.request === request) this.error = '读取记录失败，已有记录未被更改。请重试。';
    } finally { if (this.mounted && this.request === request) this.loading = false; }
  }
  private select(index: number): void {
    const kind: RecordKind = index === 0 ? 'notes' : 'bookmarks';
    if (kind === this.kind) return;
    this.kind = kind; this.onKindChange(kind);
    this.view = kind === 'notes' ? this.notesView : this.bookmarksView; this.load();
  }
  private async openNote(row: ReadingRecordRow): Promise<void> {
    this.detailRow = row; this.detailNote = undefined; this.detailError = ''; this.detailLoading = true;
    const request = ++this.detailRequest;
    this.detailDialog = this.createDetailDialog();
    this.detailOpen = true; this.detailDialog.open();
    try {
      const note = await this.application?.noteDetail(row);
      if (this.mounted && this.detailOpen && request === this.detailRequest) {
        if (note) this.detailNote = note;
        else this.detailError = '暂时无法读取这条笔记，请关闭后刷新重试。已有列表和记录仍保留。';
      }
    } catch (_) {
      if (this.mounted && this.detailOpen && request === this.detailRequest) this.detailError = '读取笔记失败，记录未被更改。请关闭后重试。';
    } finally { if (this.mounted && request === this.detailRequest) this.detailLoading = false; }
  }
  private closeDetail(): void {
    this.detailRequest++;
    if (this.detailOpen) { this.detailOpen = false; this.detailDialog.close(); }
  }

  @Builder private noteDetail() {
    Column({ space: 12 }) {
      Row() {
        Text('笔记详情').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.color('text')).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.color('secondary')]) }
          .id('records-detail-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('关闭详情').onClick((): void => this.closeDetail())
      }.width('100%')
      Scroll() {
        Column({ space: 16 }) {
          Text(this.detailRow?.book?.title ?? '书籍信息暂不可用').fontSize(13).fontColor(this.color('secondary')).width('100%')
          if (this.detailLoading) { LoadingProgress().id('records-detail-loading').width(24).height(24) }
          if (this.detailError) { Text(this.detailError).id('records-detail-error').fontSize(14).fontColor(this.color('secondary')).width('100%') }
          if (this.detailNote) {
            Column({ space: 6 }) {
              Text('原文').fontSize(12).fontColor(this.color('secondary')).width('100%')
              Text(this.detailNote.originalAnchor.exactText || '原文引用暂不可用').id('records-detail-quote')
                .fontSize(15).lineHeight(24).fontColor(this.color('text')).width('100%')
            }.width('100%').padding(12).backgroundColor(this.color('muted')).borderRadius(12)
            Text(this.detailNote.body || '笔记内容暂不可用').id('records-detail-body').fontSize(17).lineHeight(27).fontColor(this.color('text')).width('100%')
            Text(this.detailNote.updatedAt > this.detailNote.createdAt ?
              '创建于 ' + recordTime(this.detailNote.createdAt) + '\n修改于 ' + recordTime(this.detailNote.updatedAt) :
              '创建于 ' + recordTime(this.detailNote.createdAt))
              .fontSize(12).fontColor(this.color('secondary')).width('100%')
            if (this.detailRow?.book?.sourceState === 'missing' || this.detailNote.anchorProvenance === 'legacy-group' ||
              this.detailNote.anchorStatus !== 'verified') {
              Text('原文位置暂未核对，引用和笔记仍保留。').fontSize(13).fontColor(this.color('secondary')).width('100%')
            }
          }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.width('100%').constraintSize({ maxHeight: 420 }).align(Alignment.TopStart)
        .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
    }.id('records-note-detail').width('100%')
  }

  @Builder private row(row: ReadingRecordRow, kind: RecordKind) {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph(kind === 'notes' ? $r('sys.symbol.square_and_pencil') : $r('sys.symbol.bookmark'))
          .fontSize(22).fontColor([this.color('secondary')])
        Column({ space: 8 }) {
          Text(row.book?.title ?? '书籍信息暂不可用').id('records-book-title').fontSize(15).fontWeight(FontWeight.Medium)
            .fontColor(this.color('text')).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (row.book?.sourceState === 'missing' || !row.book) {
            Text(row.book ? '书籍文件缺失，记录仍保留' : '暂无法关联在库图书，记录仍保留').fontSize(12)
              .fontColor(this.color('secondary')).width('100%')
          }
          Text(row.quote || (kind === 'notes' ? '原文引用暂不可用' : '书签位置暂不可用')).id('records-quote')
            .fontSize(13).fontColor(this.color('secondary')).width('100%').maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (kind === 'notes') {
            Text(row.excerpt || '笔记内容暂不可用').id('records-note-excerpt').fontSize(15).fontColor(this.color('text'))
              .width('100%').maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          Text((kind === 'notes' ? '修改于 ' : '创建于 ') + recordTime(row.time)).id('records-time').fontSize(12)
            .fontColor(this.color('secondary')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(14).fontColor([this.color('secondary')])
      }.width('100%').alignItems(VerticalAlign.Top)
    }.id('records-row-' + row.id).width('100%').padding(16).type(ButtonType.Normal).borderRadius(16)
      .backgroundColor(this.color('surface')).onClick((): void => {
        if (kind === 'notes') this.openNote(row); else this.onBookmark(row);
      })
  }
  private listView(kind: RecordKind): ReadingRecordView { return kind === 'notes' ? this.notesView : this.bookmarksView; }
  @Builder private list(kind: RecordKind) {
      Column({ space: 12 }) {
        Row() {
          Text(kind === 'notes' ? '按最近修改排列' : '按创建时间排列').fontSize(12).fontColor(this.color('secondary')).layoutWeight(1)
          Button('刷新').id(kind === this.kind ? 'records-refresh' : 'records-inactive-refresh').height(48).buttonStyle(ButtonStyleMode.TEXTUAL).enabled(!this.loading)
            .onClick((): void => { this.load('refresh'); })
        }.width('100%')
        if (kind === this.kind && this.notice) { Text(this.notice).id(kind === this.kind ? 'records-notice' : 'records-inactive-notice').fontSize(14).fontColor(this.color('secondary')).width('100%') }
        if (kind === this.kind && this.error) {
          Text(this.error).id(kind === this.kind ? 'records-error' : 'records-inactive-error').fontSize(14).fontColor(this.color('secondary')).width('100%')
          Button('重试').id(kind === this.kind ? 'records-retry' : 'records-inactive-retry').height(48).buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => { this.load(this.lastAction); })
        }
        if (kind === this.kind && this.loading && this.listView(kind).rows.length === 0) { LoadingProgress().id(kind === this.kind ? 'records-loading' : 'records-inactive-loading').width(28).height(28) }
        if (!this.loading && !this.error && this.listView(kind).rows.length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph(kind === 'notes' ? $r('sys.symbol.square_and_pencil') : $r('sys.symbol.bookmark')).fontSize(32)
              .fontColor([this.color('secondary')])
            Text(kind === 'notes' ? '暂无笔记' : '暂无书签').id(kind === this.kind ? 'records-empty' : 'records-inactive-empty').fontSize(16).fontColor(this.color('text'))
            Text(kind === 'notes' ? '阅读时写下的笔记，会汇集在这里。' : '阅读时添加的书签，会汇集在这里。')
              .fontSize(14).fontColor(this.color('secondary')).textAlign(TextAlign.Center)
          }.width('100%').padding({ top: 40, bottom: 24 })
        }
        List({ space: 8 }) {
          ForEach(this.listView(kind).rows, (row: ReadingRecordRow) => { ListItem() { this.row(row, kind) } }, (row: ReadingRecordRow): string => row.id)
        }.id('records-list-' + kind).width('100%').layoutWeight(1)
          .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
        if (this.listView(kind).hasNext || this.listView(kind).hasPrevious) {
          Row({ space: 12 }) {
            Button('上一页').id(kind === this.kind ? 'records-previous' : 'records-inactive-previous').height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.listView(kind).hasPrevious && !this.loading).onClick((): void => { this.load('previous'); })
            Text('第 ' + this.listView(kind).page + ' 页').id(kind === this.kind ? 'records-page-number' : 'records-inactive-page-number').fontSize(12).fontColor(this.color('secondary')).layoutWeight(1).textAlign(TextAlign.Center)
            Button('下一页').id(kind === this.kind ? 'records-next' : 'records-inactive-next').height(48).buttonStyle(ButtonStyleMode.TEXTUAL)
              .enabled(this.listView(kind).hasNext && !this.loading).onClick((): void => { this.load('next'); })
          }.width('100%')
        }
      }.width('100%').height('100%').padding({ left: 16, right: 16, bottom: 12 })
  }
  build() {
    Column() {
      Row({ space: 8 }) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20).fontColor([this.color('text')]) }
          .id('records-back').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('返回我的').onClick((): void => this.onExit())
        Text('阅读记录').fontSize(20).fontWeight(FontWeight.Medium).fontColor(this.color('text')).layoutWeight(1)
      }.height(56).width('100%').padding({ left: 4, right: 16 })
      Tabs({ index: this.kind === 'notes' ? 0 : 1 }) {
        TabContent() { this.list('notes') }.tabBar('笔记').id('records-tab-notes')
        TabContent() { this.list('bookmarks') }.tabBar('书签').id('records-tab-bookmarks')
      }.barMode(BarMode.Fixed).barHeight(48).scrollable(true).width('100%').layoutWeight(1).animationDuration(this.reducedMotion === true ? 0 : 200)
        .onChange((index: number): void => this.select(index))
    }.id('reading-records-page').width('100%').height('100%')
  }
}
