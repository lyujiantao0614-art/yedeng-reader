import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfColor } from '../layout/BookshelfThemePalette';

@Component
export struct SettingsSectionCard {
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop title: ResourceStr = '';
  @Prop description: ResourceStr = '';
  @Prop symbol: Resource = $r('sys.symbol.textformat');
  @Prop accessibilityLabel: Resource = $r('app.string.settings_title');
  @Prop controlId: string = '';
  onOpen: () => void = (): void => {};

  build() {
    Button() {
      Row({ space: $r('app.float.product_space_12') }) {
        SymbolGlyph(this.symbol)
          .fontSize($r('app.float.product_section_title_size'))
          .fontColor([bookshelfColor(this.bookshelfTheme, 'accent', this.bookshelfDefaultMode)])
        Column({ space: $r('app.float.product_space_4') }) {
          Text(this.title)
            .fontSize($r('app.float.product_body_size'))
            .fontWeight(FontWeight.Medium)
            .fontColor(bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode))
            .width('100%')
          Text(this.description)
            .fontSize($r('app.float.product_caption_size'))
            .fontColor(bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize($r('app.float.product_body_size'))
          .fontColor([bookshelfColor(this.bookshelfTheme, 'secondary', this.bookshelfDefaultMode)])
      }
      .width('100%')
      .padding({ top: $r('app.float.product_space_16'), bottom: $r('app.float.product_space_16') })
    }
    .id(this.controlId)
    .width('100%')
    .height('auto')
    .type(ButtonType.Normal)
    .backgroundColor(Color.Transparent)
    .borderRadius($r('app.float.product_radius_control'))
    .accessibilityText(this.accessibilityLabel)
    .onClick(() => this.onOpen())
  }
}
