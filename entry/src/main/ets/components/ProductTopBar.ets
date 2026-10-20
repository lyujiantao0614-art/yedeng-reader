import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfOuterText } from '../layout/BookshelfThemePalette';

@Component
export struct ProductTopBar {
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop title: ResourceStr = '';
  @Prop subtitle: ResourceStr = '';
  @Prop showBack: boolean = false;
  @Prop showSettings: boolean = false;
  @Prop backId: string = 'product-topbar-back';
  onBack: () => void = (): void => {};
  onSettings: () => void = (): void => {};

  build() {
    Row({ space: $r('app.float.product_space_12') }) {
      if (this.showBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize($r('app.float.product_section_title_size'))
            .fontColor([bookshelfOuterText(this.bookshelfTheme, false, this.bookshelfDefaultMode)])
        }
        .id(this.backId)
        .width($r('app.float.product_target_min'))
        .height($r('app.float.product_target_min'))
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.settings_back'))
        .onClick(() => this.onBack())
      }

      Column({ space: $r('app.float.product_space_4') }) {
        Text(this.title)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .fontColor(bookshelfOuterText(this.bookshelfTheme, false, this.bookshelfDefaultMode))
          .width('100%')
        if (this.subtitle !== '') {
          Text(this.subtitle)
            .fontSize($r('app.float.product_label_size'))
            .fontColor(bookshelfOuterText(this.bookshelfTheme, true, this.bookshelfDefaultMode))
            .width('100%')
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.showSettings) {
        Button() {
          SymbolGlyph($r('sys.symbol.gearshape'))
            .fontSize($r('app.float.product_section_title_size'))
            .fontColor([bookshelfOuterText(this.bookshelfTheme, false, this.bookshelfDefaultMode)])
        }
        .id('product-topbar-settings')
        .width($r('app.float.product_target_min'))
        .height($r('app.float.product_target_min'))
        .type(ButtonType.Circle)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.library_settings'))
        .onClick(() => this.onSettings())
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }
}
