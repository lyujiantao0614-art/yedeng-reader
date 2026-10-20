import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfColor } from '../layout/BookshelfThemePalette';

export type ProductStateKind = 'loading' | 'empty' | 'no-results' | 'error' | 'recovery';

@Component
export struct ProductStatePanel {
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop kind: ProductStateKind = 'empty';
  @Prop title: ResourceStr = '';
  @Prop body: ResourceStr = '';
  @Prop showAction: boolean = false;
  @Prop actionLabel: ResourceStr = '';
  @Prop actionId: string = '';
  onAction: () => void = (): void => {};

  private symbol(): Resource {
    if (this.kind === 'loading') return $r('sys.symbol.hourglass');
    if (this.kind === 'error') return $r('sys.symbol.exclamationmark_triangle');
    if (this.kind === 'recovery') return $r('sys.symbol.wrench_and_screwdriver');
    if (this.kind === 'no-results') return $r('sys.symbol.magnifyingglass');
    return $r('sys.symbol.list_book');
  }

  build() {
    Column({ space: $r('app.float.product_space_12') }) {
      if (this.kind === 'loading') {
        LoadingProgress()
          .width($r('app.float.product_space_32'))
          .height($r('app.float.product_space_32'))
          .color(bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
      } else {
        SymbolGlyph(this.symbol())
          .fontSize($r('app.float.product_space_32'))
          .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
      }
      Text(this.title)
        .fontSize('16fp')
        .fontWeight(FontWeight.Medium)
        .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
        .textAlign(TextAlign.Center)
      Text(this.body)
        .fontSize('14fp').lineHeight('22fp')
        .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
        .textAlign(TextAlign.Center)
        .width('100%').constraintSize({ maxWidth: 360 })
      if (this.showAction) {
        Button(this.actionLabel)
          .id(this.actionId)
          .height(48).fontSize('16fp').padding({ left: 24, right: 24 }).margin({ top: 8 })
          .buttonStyle(this.kind === 'empty' ? ButtonStyleMode.EMPHASIZED : ButtonStyleMode.NORMAL)
          .fontColor(this.kind === 'empty' ? bookshelfColor(this.bookshelfTheme, 'onAccent', this.bookshelfDefaultMode) :
            bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode))
          .backgroundColor(this.kind === 'empty' ? bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode) :
            bookshelfColor(this.bookshelfTheme, 'muted', this.bookshelfDefaultMode))
          .onClick(() => this.onAction())
      }
    }
    .width('100%')
    .padding($r('app.float.product_space_24'))
    .justifyContent(FlexAlign.Center)
  }
}
