import { PassageSelectionCandidate } from '../reader/ReadingSelectionModels';

export type PassageActionSheetStatus = 'candidate' | 'loading' | 'too-long' | 'unavailable' |
  'mark-conflict' | 'mark-unavailable';

@Component
export struct PassageActionSheet {
  @Prop surfaceColor: Resource = $r('app.color.reader_surface_light');
  @Prop textPrimaryColor: Resource = $r('app.color.reader_text_primary_light');
  @Prop textSecondaryColor: Resource = $r('app.color.reader_text_secondary_light');
  @Prop dividerColor: Resource = $r('app.color.reader_divider_light');
  @Prop accentColor: Resource = $r('app.color.reader_accent_light');
  @Prop onAccentColor: Resource = $r('app.color.reader_on_accent_light');
  @Prop selectedColor: Resource = $r('app.color.reader_selected_light');
  @Prop errorColor: Resource = $r('app.color.reader_error_light');
  @Prop errorContainerColor: Resource = $r('app.color.reader_error_container_light');
  @Prop candidate: PassageSelectionCandidate | undefined = undefined;
  @Prop status: PassageActionSheetStatus = 'candidate';
  @Prop rejectedCharacterCount: number = 0;
  @Prop detail: string = '';
  @Prop adjusting: boolean = false;
  @Prop darkTheme: boolean = false;
  onCopy: () => void = (): void => {};
  onHighlight: () => void = (): void => {};
  onNote: () => void = (): void => {};
  onSaveRange: () => void = (): void => {};
  onDismiss: () => void = (): void => {};

  private characterCount(): number {
    return this.candidate?.characterCount ?? this.rejectedCharacterCount;
  }

  private statusTitle(): ResourceStr {
    if (this.status === 'too-long') return $r('app.string.reader_passage_too_long_title');
    if (this.status === 'mark-conflict') return $r('app.string.reader_passage_mark_conflict_title');
    if (this.status === 'mark-unavailable') return $r('app.string.reader_passage_mark_unavailable_title');
    if (this.status === 'unavailable') return $r('app.string.reader_passage_unavailable_title');
    return $r('app.string.reader_passage_title');
  }

  build() {
    Column({ space: $r('app.float.product_space_8') }) {
      Row({ space: $r('app.float.product_space_12') }) {
        Column({ space: $r('app.float.product_space_4') }) {
          Text(this.statusTitle()).id('reader-passage-title')
            .fontSize($r('app.float.product_surface_title_size')).fontWeight(FontWeight.Medium)
            .fontColor(this.status === 'too-long' || this.status === 'unavailable' ||
              this.status === 'mark-unavailable' ?
              this.errorColor : this.textPrimaryColor)
          if (this.status !== 'mark-conflict' && this.status !== 'mark-unavailable') {
            if (this.characterCount() > 0) {
              Row() {
                Text($r('app.string.reader_passage_count_prefix'))
                  .fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                Text(`${this.characterCount()}`)
                  .fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                Text($r('app.string.reader_passage_count_suffix'))
                  .fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
              }.id('reader-passage-character-count')
            } else {
              Text($r('app.string.reader_passage_selection_label'))
                .fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
            }
          }
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (this.status === 'candidate') {
          Button() {
            SymbolGlyph($r('sys.symbol.square_and_square')).fontSize($r('app.float.product_body_size'))
              .fontColor([this.accentColor])
          }.id('reader-passage-copy')
            .type(ButtonType.Circle).backgroundColor(Color.Transparent)
            .constraintSize({ minHeight: $r('app.float.product_target_min') })
            .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
            .accessibilityText($r('app.string.reader_passage_copy')).onClick(() => this.onCopy())
        }
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(16).fontColor([this.textSecondaryColor]) }.id('reader-passage-dismiss')
          .type(ButtonType.Normal).fontColor(this.accentColor)
          .fontSize($r('app.float.product_surface_title_size')).backgroundColor(Color.Transparent)
          .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
          .accessibilityText($r('app.string.reader_passage_close')).onClick(() => this.onDismiss())
      }.width('100%')


      if (this.status === 'mark-conflict' || this.status === 'mark-unavailable') {
        Column() {
          Text(this.detail).fontSize($r('app.float.product_body_small_size'))
            .fontColor(this.textPrimaryColor).width('100%')
        }.id('reader-passage-mark-feedback').layoutWeight(1)
          .justifyContent(FlexAlign.Center).width('100%')
          .padding({ left: $r('app.float.product_space_8'), right: $r('app.float.product_space_8') })
      } else if (this.status === 'too-long') {
        Column({ space: $r('app.float.product_space_8') }) {
          Text($r('app.string.reader_passage_too_long_body'))
            .fontSize($r('app.float.product_body_small_size')).fontColor(this.textPrimaryColor).textAlign(TextAlign.Center)
        }.id('reader-passage-too-long').layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
          .padding($r('app.float.product_space_8')).backgroundColor(this.errorContainerColor)
          .borderRadius($r('app.float.product_radius_control'))
      } else if (this.status === 'loading') {
        Row({ space: $r('app.float.product_space_12') }) {
          LoadingProgress().width($r('app.float.product_space_24')).height($r('app.float.product_space_24')).color(this.accentColor)
          Text($r('app.string.reader_passage_loading')).fontSize($r('app.float.product_body_small_size')).fontColor(this.textPrimaryColor)
        }.id('reader-passage-loading').layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
      } else if (this.status === 'unavailable') {
        Column({ space: $r('app.float.product_space_8') }) {
          Text(this.detail.length > 0 ? this.detail : $r('app.string.reader_passage_unavailable_body'))
            .fontSize($r('app.float.product_body_small_size')).fontColor(this.textPrimaryColor).textAlign(TextAlign.Center)
        }.id('reader-passage-unavailable').layoutWeight(1).justifyContent(FlexAlign.Center).width('100%')
          .padding($r('app.float.product_space_8')).backgroundColor(this.errorContainerColor)
          .borderRadius($r('app.float.product_radius_control'))
      } else if (this.status === 'candidate') {
        Scroll() {
          Column({ space: $r('app.float.product_space_8') }) {
            Row({ space: $r('app.float.product_space_8') }) {
              if (this.adjusting) {
                Button('保存范围').id('reader-passage-save-range').layoutWeight(1)
                  .type(ButtonType.Normal).constraintSize({ minHeight: $r('app.float.product_target_min') })
                  .accessibilityText('保存调整后的标记范围')
                  .fontColor(this.onAccentColor).backgroundColor(this.accentColor)
                  .onClick(() => this.onSaveRange())
              } else {
                Button('高亮').id('reader-passage-highlight').layoutWeight(1).height(48)
                  .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(this.selectedColor).fontColor(this.accentColor)
                  .accessibilityText('高亮所选文字').onClick(() => this.onHighlight())
                Button('写笔记').id('reader-passage-note').layoutWeight(1).height(48)
                  .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(this.selectedColor).fontColor(this.accentColor)
                  .accessibilityText('给所选文字写笔记').onClick(() => this.onNote())
              }
            }.width('100%')
          }.width('100%').padding({ top: $r('app.float.product_space_4'), bottom: $r('app.float.product_space_4') })
        }.id('reader-passage-candidate').layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }

    }
    .id('reader-passage-panel').width('100%').height('100%')
    .padding(16).backgroundColor(this.surfaceColor).borderRadius(24).shadow(ShadowStyle.OUTER_DEFAULT_SM)
  }
}
