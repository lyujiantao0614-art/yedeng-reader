import { ReaderTheme } from '../domain/Models';

// Presentation only. Index retains opening readiness, cancellation and lifecycle ownership.
@Component
export struct BookOpeningOverlay {
  @Prop theme: ReaderTheme = 'light';
  @Prop checking: boolean = false;
  onCancel: () => void = (): void => {};

  private color(role: 'canvas' | 'text_primary' | 'text_secondary' | 'accent' | 'surface_muted'): Resource {
    return $r('app.color.reader_' + role + '_' + this.theme.replace('-', '_'));
  }

  build() {
    Column({ space: 24 }) {
      LoadingProgress().id('library-opening-spinner').width(40).height(40).color(this.color('accent'))
      Column({ space: 8 }) {
        Text('正在打开图书').fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.color('text_primary'))
        Text(this.checking ? $r('app.string.library_checking_book') : $r('app.string.reader_preparing_text'))
          .fontSize(14).fontColor(this.color('text_secondary')).textAlign(TextAlign.Center)
      }.width('100%')
      Button($r('app.string.library_cancel_open')).id('library-cancel-open-check')
        .height(48).constraintSize({ minWidth: 128 }).fontSize(15).defaultFocus(true)
        .buttonStyle(ButtonStyleMode.NORMAL).fontColor(this.color('text_primary'))
        .backgroundColor(this.color('surface_muted')).onClick(() => this.onCancel())
    }.id('library-open-check').width('100%').height('100%').padding(24)
      .justifyContent(FlexAlign.Center).backgroundColor(this.color('canvas'))
  }
}
