import { ReaderTheme } from '../domain/Models';

// Presentation only. ReaderPage retains error classification and dismissal state.
@Component
export struct ReaderErrorNotice {
  @Prop message: string = '';
  @Prop theme: ReaderTheme = 'light';
  @Prop dismissible: boolean = false;
  onDismiss: () => void = (): void => {};

  private color(role: string): Resource {
    return $r('app.color.reader_' + role + '_' + this.theme.replace('-', '_'));
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.exclamationmark_triangle')).fontSize(20).fontColor([this.color('error')])
        Text('阅读提示').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.color('text_primary')).layoutWeight(1)
        if (this.dismissible) {
          Button() {
            SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.color('text_secondary')])
          }.id('reader-error-dismiss').width(48).height(48).type(ButtonType.Circle)
            .buttonStyle(ButtonStyleMode.TEXTUAL).accessibilityText('关闭阅读提示')
            .onClick((): void => this.onDismiss())
        }
      }.width('100%')
      Text(this.message).fontSize(14).lineHeight(22).fontColor(this.color('text_primary')).width('100%')
    }.width('92%').constraintSize({ maxWidth: 420 }).padding(16).alignItems(HorizontalAlign.Start)
      .backgroundColor(this.color('error_container')).borderRadius(16)
      .onClick((): void => { if (this.dismissible) this.onDismiss(); })
  }
}
