import { common } from '@kit.AbilityKit';
import { Book } from '../domain/Models';
import { BookshelfDefaultMode } from '../domain/LibraryPresentation';
import { MineLibrarySummary } from '../application/MineLibraryProjection';
import { bookshelfColor, BookshelfColorRole } from '../layout/BookshelfThemePalette';
import { RecordKind } from '../application/ReadingRecordsApplication';

@Component
export struct MinePage {
  @Prop reducedMotion: boolean | undefined = undefined;
  @Prop summary: MineLibrarySummary = { bookCount: 0, openedBookCount: 0 };
  @Prop defaultMode: BookshelfDefaultMode = 'system';
  @Prop loading: boolean = false;
  @Prop unavailable: boolean = false;
  @Prop notice: string = '';
  onOpen: (book: Book) => void = (_book: Book): void => {};
  onRepair: (book: Book) => void = (_book: Book): void => {};
  onLibrary: () => void = (): void => {};
  onSettings: () => void = (): void => {};
  onRetry: () => void = (): void => {};
  onRecords: (kind: RecordKind) => void = (_kind: RecordKind): void => {};
  @State private failedCover: string = '';

  private color(role: BookshelfColorRole): ResourceColor {
    return bookshelfColor('default', role, this.defaultMode);
  }

  @Builder
  private cover(book: Book) {
    Stack() {
      if (book.coverRelativePath && this.failedCover !== book.coverRelativePath) {
        Image(`file://${(this.getUIContext().getHostContext() as common.UIAbilityContext).filesDir}/${book.coverRelativePath}`)
          .id('mine-recent-cover').width('100%').height('100%').objectFit(ImageFit.Contain).draggable(false)
          .sourceSize({ width: Math.ceil(this.getUIContext().vp2px(88)), height: Math.ceil(this.getUIContext().vp2px(124)) })
          .onError((): void => { this.failedCover = book.coverRelativePath ?? ''; })
      } else {
        SymbolGlyph($r('sys.symbol.book')).fontSize(32).fontColor([this.color('secondary')])
      }
    }.width(88).height(124).borderRadius(6).clip(true).backgroundColor(this.color('muted'))
      .accessibilityLevel('no')
  }

  @Builder
  private recentBook(book: Book) {
    Button() {
      Row({ space: 20 }) {
        this.cover(book)
        Column({ space: 8 }) {
          Text(book.title).id('mine-recent-title').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor(this.color('text')).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          if (book.author) {
            Text(book.author).fontSize(14).fontColor(this.color('secondary')).maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis }).width('100%')
          }
          if (book.sourceState === 'missing') {
            Text('书籍文件缺失').id('mine-source-missing').fontSize(13).fontColor(this.color('secondary')).width('100%')
          }
          Row({ space: 6 }) {
            Text(book.sourceState === 'missing' ? '重新选择文件' : '继续阅读').fontSize(14).fontWeight(FontWeight.Medium)
              .fontColor(this.color('accent'))
            SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(12).fontColor([this.color('accent')])
          }.margin({ top: 6 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      }.width('100%').alignItems(VerticalAlign.Center)
    }.id('mine-continue').width('100%').padding(20).type(ButtonType.Normal).borderRadius(16)
      .backgroundColor(this.color('surface'))
      .accessibilityText((book.sourceState === 'missing' ? '重新选择文件，' : '继续阅读，') + book.title)
      .onClick((): void => { if (book.sourceState === 'missing') this.onRepair(book); else this.onOpen(book); })
  }

  @Builder
  private emptyReading() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.book')).fontSize(32).fontColor([this.color('secondary')])
      Text('从一本书开始').id('mine-empty').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.color('text'))
      Text('打开书架，选一本想读的书。').fontSize(14).fontColor(this.color('secondary')).textAlign(TextAlign.Center)
      Button('前往书架').id('mine-library').buttonStyle(ButtonStyleMode.TEXTUAL).height(48).fontSize(15)
        .fontColor(this.color('accent')).onClick((): void => this.onLibrary())
    }.width('100%').padding({ left: 20, right: 20, top: 28, bottom: 20 })
      .backgroundColor(this.color('surface')).borderRadius(16)
  }

  @Builder
  private count(value: number, label: string, id: string) {
    Column({ space: 6 }) {
      Text(String(value)).id(id).fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.color('text'))
      Text(label).fontSize(13).fontColor(this.color('secondary'))
    }.layoutWeight(1).alignItems(HorizontalAlign.Start).accessibilityText(`${label}，${value} 本`)
  }

  @Builder
  private settings() {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.gearshape')).fontSize(22).fontColor([this.color('secondary')])
        Text('设置').fontSize(16).fontColor(this.color('text')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.color('secondary')])
      }.width('100%')
    }.id('mine-settings').width('100%').height(64).padding({ left: 16, right: 16 }).type(ButtonType.Normal)
      .backgroundColor(this.color('surface')).borderRadius(12).margin({ top: 32 }).onClick((): void => this.onSettings())
  }

  @Builder
  private recordEntry(label: string, kind: RecordKind, symbol: Resource) {
    Button() {
      Row({ space: 12 }) {
        SymbolGlyph(symbol).fontSize(22).fontColor([this.color('secondary')])
        Text(label).fontSize(16).fontColor(this.color('text')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(16).fontColor([this.color('secondary')])
      }.width('100%')
    }.id('mine-records').width('100%').height(64).padding({ left: 16, right: 16 }).type(ButtonType.Normal)
      .backgroundColor(Color.Transparent).enabled(!this.loading && !this.unavailable).onClick((): void => this.onRecords(kind))
  }

  build() {
    Column() {
      Text('我的').id('mine-title').fontSize(22).fontWeight(FontWeight.Medium).width('100%').height(56)
        .fontColor(this.color('text')).padding({ left: 16, right: 16 })
      Scroll() {
        Column() {
          Text('继续阅读').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.color('text'))
            .width('100%').margin({ bottom: 16 })
          if (this.loading) {
            Row({ space: 12 }) {
              LoadingProgress().width(24).height(24).color(this.color('accent'))
              Text('正在读取书库…').fontSize(14).fontColor(this.color('secondary'))
            }.id('mine-loading').width('100%').padding({ top: 24, bottom: 24 })
          } else if (this.unavailable) {
            Column({ space: 8 }) {
              Text('暂时无法读取书库').id('mine-unavailable').fontSize(16).fontColor(this.color('text'))
              Text('图书和阅读记录未被更改，请重试。').fontSize(14).fontColor(this.color('secondary')).width('100%')
              Button('重试').id('mine-retry').buttonStyle(ButtonStyleMode.TEXTUAL).height(48)
                .onClick((): void => this.onRetry())
            }.width('100%').padding(20).backgroundColor(this.color('surface')).borderRadius(16)
          } else {
            if (this.summary.recentBook) { this.recentBook(this.summary.recentBook) } else { this.emptyReading() }
            Text('阅读记录').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.color('text'))
              .width('100%').margin({ top: 32, bottom: 16 })
            Column() {
              this.recordEntry('阅读记录', 'notes', $r('sys.symbol.square_and_pencil'))
            }.width('100%').backgroundColor(this.color('surface')).borderRadius(12).clip(true)
            Text('书库概况').fontSize(18).fontWeight(FontWeight.Medium).fontColor(this.color('text'))
              .width('100%').margin({ top: 32, bottom: 20 })
            Row() {
              this.count(this.summary.bookCount, '在库书籍', 'mine-book-count')
              this.count(this.summary.openedBookCount, '打开过的书', 'mine-opened-count')
            }.width('100%').padding({ left: 4, right: 4, bottom: 8 })
          }
          if (this.notice) {
            Text(this.notice).id('mine-notice').fontSize(14).fontColor(this.color('secondary'))
              .width('100%').margin({ top: 16 })
          }
          this.settings()
        }.width('100%').constraintSize({ maxWidth: 640 }).alignItems(HorizontalAlign.Start)
          .padding({ top: 20, bottom: 24 })
      }.id('mine-scroll').width('100%').layoutWeight(1).scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
        .align(Alignment.TopStart).padding({ left: 20, right: 20 })
    }.id('mine-page').width('100%').height('100%').transition(TransitionEffect.OPACITY)
  }
}
