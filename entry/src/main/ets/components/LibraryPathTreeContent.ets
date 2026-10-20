import { BookshelfDefaultMode } from '../domain/LibraryPresentation';
import { bookshelfColor } from '../layout/BookshelfThemePalette';

export interface LibraryPathTreeRow {
  folderId: string; name: string; depth: number; path: string;
  count: number; hasChildren: boolean;
}

// Presentation only. Index owns expansion, native visibility and committed navigation.
@Component
export struct LibraryPathTreeContent {
  @Prop currentPathLabel: string = '书架';
  @Prop currentFolderId: string = '';
  @Prop rootCount: number = 0;
  @Prop rows: LibraryPathTreeRow[] = [];
  @Prop expandedFolders: string[] = [];
  @Prop defaultMode: BookshelfDefaultMode = 'light';
  @Prop maxContentHeight: number = 480;
  onClose: () => void = (): void => {};
  onChoose: (id: string) => void = (_id: string): void => {};
  onToggle: (id: string) => void = (_id: string): void => {};

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('查看目录').fontSize(18).fontWeight(FontWeight.Medium).layoutWeight(1)
          .fontColor(bookshelfColor('default', 'text', this.defaultMode))
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18)
          .fontColor([bookshelfColor('default', 'secondary', this.defaultMode)]) }
          .id('library-path-close').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText('关闭目录').onClick((): void => this.onClose())
      }.width('100%')
      Scroll() {
        Column({ space: 4 }) {
          Text(this.currentPathLabel).id('library-full-path').fontSize(14).lineHeight(22).width('100%')
            .textAlign(TextAlign.Start).fontColor(bookshelfColor('default', 'secondary', this.defaultMode))
            .padding({ left: 12, right: 12, bottom: 8 })
            Button() {
              Row({ space: 12 }) {
                SymbolGlyph($r('sys.symbol.list_book')).fontSize(20).fontColor([bookshelfColor('default', 'secondary', this.defaultMode)])
                Text('书架').fontSize(15).fontWeight(this.currentFolderId ? FontWeight.Regular : FontWeight.Medium)
                  .fontColor(bookshelfColor('default', this.currentFolderId ? 'text' : 'accent', this.defaultMode)).layoutWeight(1)
                Text(this.rootCount + ' 本图书').fontSize(12).fontColor(bookshelfColor('default', 'secondary', this.defaultMode))
                if (!this.currentFolderId) {
                  SymbolGlyph($r('sys.symbol.checkmark')).fontSize(16).fontColor([bookshelfColor('default', 'accent', this.defaultMode)])
                }
              }.width('100%')
            }.id('library-path-root').width('100%').height(56).padding({ left: 16, right: 12 })
              .type(ButtonType.Normal).borderRadius(12).backgroundColor(this.currentFolderId ? Color.Transparent :
                bookshelfColor('default', 'accentContainer', this.defaultMode))
              .onClick((): void => this.onChoose(''))

          ForEach(this.rows, (folder: LibraryPathTreeRow) => {
              Row() {
                Button() {
                  // Retained ForEach rows must read reactive state, not a captured projection object.
                  SymbolGlyph(this.expandedFolders.includes(folder.folderId) ? $r('sys.symbol.chevron_down') : $r('sys.symbol.chevron_right')).fontSize(16)
                    .id('library-path-arrow-' + folder.folderId)
                    .fontColor([bookshelfColor('default', 'text', this.defaultMode)])
                }.id('library-path-expand-' + folder.folderId).width(48).height(48).type(ButtonType.Circle)
                  .backgroundColor(Color.Transparent)
                  .enabled(folder.hasChildren)
                  .accessibilityText(this.expandedFolders.includes(folder.folderId) ? '收起文件夹' : '展开文件夹')
                  .onClick((): void => this.onToggle(folder.folderId))
                Button() {
                  Column() {
                    Text(folder.name).fontSize(15).lineHeight(22).textAlign(TextAlign.Start)
                      .fontWeight(folder.folderId === this.currentFolderId ? FontWeight.Medium : FontWeight.Regular).width('100%')
                      .fontColor(bookshelfColor('default', 'text', this.defaultMode))
                    if (folder.depth > 4) {
                      Text(folder.path).fontSize(12).lineHeight(18).width('100%').textAlign(TextAlign.Start)

                        .fontColor(bookshelfColor('default', 'secondary', this.defaultMode))
                    }
                  }.width('100%').alignItems(HorizontalAlign.Start)
                }.id('library-path-folder-' + folder.folderId).layoutWeight(1).constraintSize({ minHeight: 56 })
                  .type(ButtonType.Normal).padding({ left: 0, right: 8, top: 12, bottom: 12 }).backgroundColor(Color.Transparent)
                  .accessibilitySelected(folder.folderId === this.currentFolderId).onClick((): void => this.onChoose(folder.folderId))
                Text(String(folder.count)).fontSize(12)
                  .fontColor(bookshelfColor('default', 'secondary', this.defaultMode))
                if (folder.folderId === this.currentFolderId) {
                  SymbolGlyph($r('sys.symbol.checkmark')).id('library-path-selected-marker').fontSize(16)
                    .fontColor([bookshelfColor('default', 'accent', this.defaultMode)]).margin({ left: 8 })
                }
              }.width('100%').borderRadius(12).padding({ left: Math.min(4, folder.depth) * 16, right: 8 })
                .backgroundColor(folder.folderId === this.currentFolderId ?
                  bookshelfColor('default', 'accentContainer', this.defaultMode) : Color.Transparent)

          }, (folder: LibraryPathTreeRow): string => folder.folderId)
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.id('library-path-list').width('100%')
        .constraintSize({ maxHeight: this.maxContentHeight }).align(Alignment.TopStart)
        .scrollBar(BarState.Auto).scrollBarWidth(2)
        .scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
    }.id('library-path-tree').width('100%').padding({ left: 20, right: 20, top: 8, bottom: 20 })
  }

}
