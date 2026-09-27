import {
  DictionaryEntry, DictionaryLookupResult, DictionaryMatchKind, DictionaryPartOfSpeech
} from '../dictionary/DictionaryModels';

interface DictionarySenseRow {
  key: string;
  providerId: string;
  headword: string;
  matchKind: DictionaryMatchKind;
  partOfSpeech?: DictionaryPartOfSpeech;
  meanings: string[];
  firstForEntry: boolean;
}

@Component
export struct DictionarySheet {
  @Prop surfaceColor: Resource = $r('app.color.reader_surface_light');
  @Prop surfaceMutedColor: Resource = $r('app.color.reader_surface_muted_light');
  @Prop textPrimaryColor: Resource = $r('app.color.reader_text_primary_light');
  @Prop textSecondaryColor: Resource = $r('app.color.reader_text_secondary_light');
  @Prop dividerColor: Resource = $r('app.color.reader_divider_light');
  @Prop accentColor: Resource = $r('app.color.reader_accent_light');
  @Prop onAccentColor: Resource = $r('app.color.reader_on_accent_light');
  @Prop selectedColor: Resource = $r('app.color.reader_selected_light');
  @Prop errorColor: Resource = $r('app.color.reader_error_light');
  @Prop errorContainerColor: Resource = $r('app.color.reader_error_container_light');
  @Prop selectedForm: string = '';
  @Prop loading: boolean = false;
  @Prop result: DictionaryLookupResult | undefined = undefined;
  @Prop expanded: boolean = false;
  @Prop adjusting: boolean = false;
  @Prop darkTheme: boolean = false;
  onCopy: () => void = (): void => {};
  onHighlight: () => void = (): void => {};
  onNote: () => void = (): void => {};
  onSaveRange: () => void = (): void => {};
  onToggleExpanded: () => void = (): void => {};
  onDismiss: () => void = (): void => {};

  private sourceLabel(providerId: string): ResourceStr {
    return providerId.startsWith('cc-cedict') ? $r('app.string.reader_dictionary_source_cc_cedict') :
      $r('app.string.reader_dictionary_source_omw');
  }

  private matchLabel(matchKind: DictionaryMatchKind): ResourceStr {
    if (matchKind === 'inflection') return $r('app.string.reader_dictionary_match_inflection');
    if (matchKind === 'suffix') return $r('app.string.reader_dictionary_match_suffix');
    return $r('app.string.reader_dictionary_match_exact');
  }

  private partOfSpeechLabel(value?: DictionaryPartOfSpeech): ResourceStr {
    if (value === 'noun') return $r('app.string.reader_dictionary_pos_noun');
    if (value === 'verb') return $r('app.string.reader_dictionary_pos_verb');
    if (value === 'adjective') return $r('app.string.reader_dictionary_pos_adjective');
    if (value === 'adverb') return $r('app.string.reader_dictionary_pos_adverb');
    return $r('app.string.reader_dictionary_pos_definition');
  }

  private rows(expanded: boolean): DictionarySenseRow[] {
    if (this.result?.status !== 'found') return [];
    const rows: DictionarySenseRow[] = [];
    let omwGroups = 0;
    let fallbackMeanings = 0;
    this.result.entries.forEach((entry: DictionaryEntry, entryIndex: number): void => {
      let firstForEntry = true;
      entry.senses.forEach((sense, senseIndex: number): void => {
        if (entry.providerId.startsWith('cc-cedict')) {
          const remaining = expanded ? 8 - fallbackMeanings : 2 - fallbackMeanings;
          if (remaining <= 0) return;
          const meanings = sense.meanings.slice(0, remaining);
          if (meanings.length === 0) return;
          rows.push({
            key: `${entryIndex}:${senseIndex}:${entry.headword}`,
            providerId: entry.providerId,
            headword: entry.headword,
            matchKind: entry.matchKind,
            partOfSpeech: sense.partOfSpeech,
            meanings: meanings,
            firstForEntry: firstForEntry
          });
          fallbackMeanings += meanings.length;
          firstForEntry = false;
          return;
        }
        if (!expanded && omwGroups >= 3) return;
        if (expanded && omwGroups >= 12) return;
        rows.push({
          key: `${entryIndex}:${senseIndex}:${entry.headword}`,
          providerId: entry.providerId,
          headword: entry.headword,
          matchKind: entry.matchKind,
          partOfSpeech: sense.partOfSpeech,
          meanings: sense.meanings.slice(0, 8),
          firstForEntry: firstForEntry
        });
        omwGroups += 1;
        firstForEntry = false;
      });
    });
    return rows;
  }

  private rowValueCount(rows: DictionarySenseRow[]): number {
    let count = rows.length;
    rows.forEach((row: DictionarySenseRow): void => { count += row.meanings.length; });
    return count;
  }

  private hasMore(): boolean {
    return this.result?.status === 'found' &&
      this.rowValueCount(this.rows(true)) > this.rowValueCount(this.rows(false));
  }

  private statusTitle(): ResourceStr {
    if (this.result?.status === 'not-found') return $r('app.string.reader_dictionary_not_found_title');
    if (this.result?.status === 'invalid-selection') return $r('app.string.reader_dictionary_invalid_title');
    return $r('app.string.reader_dictionary_unavailable_title');
  }

  private statusDetail(): ResourceStr {
    if (this.result?.status === 'not-found') return $r('app.string.reader_dictionary_not_found_body');
    if (this.result?.status === 'invalid-selection') return $r('app.string.reader_dictionary_invalid_body');
    return $r('app.string.reader_dictionary_unavailable_body');
  }

  build() {
    Column({ space: $r('app.float.product_space_8') }) {
      Row({ space: $r('app.float.product_space_8') }) {
        Column({ space: $r('app.float.product_space_4') }) {
          Text(this.selectedForm.length > 0 ? this.selectedForm : $r('app.string.reader_dictionary_title'))
            .fontSize($r('app.float.product_surface_title_size')).fontWeight(FontWeight.Bold).fontColor(this.textPrimaryColor)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.reader_dictionary_offline_label')).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button($r('app.string.reader_close_glyph'))
          .id('reader-dictionary-dismiss')
          .type(ButtonType.Normal).fontColor(this.accentColor)
          .fontSize($r('app.float.product_surface_title_size'))
          .backgroundColor(Color.Transparent)
          .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
          .accessibilityText($r('app.string.reader_dictionary_close'))
          .onClick(() => this.onDismiss())
      }.width('100%')

      Divider().color(this.dividerColor)

      if (this.loading) {
        Row({ space: $r('app.float.product_space_12') }) {
          LoadingProgress().width($r('app.float.product_space_24')).height($r('app.float.product_space_24')).color(this.accentColor)
          Text($r('app.string.reader_dictionary_loading')).fontSize($r('app.float.product_body_small_size')).fontColor(this.textPrimaryColor)
        }
        .id('reader-dictionary-loading')
        .width('100%').justifyContent(FlexAlign.Center).layoutWeight(1)
      } else if (this.result?.status === 'found') {
        Scroll() {
          Column({ space: $r('app.float.product_space_8') }) {
            ForEach(this.rows(this.expanded), (row: DictionarySenseRow) => {
              Column({ space: $r('app.float.product_space_4') }) {
                if (row.firstForEntry) {
                  Row({ space: $r('app.float.product_space_8') }) {
                    Text(row.headword).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium).fontColor(this.textPrimaryColor)
                    Text(this.matchLabel(row.matchKind)).fontSize($r('app.float.product_caption_size')).fontColor(this.accentColor)
                      .padding($r('app.float.product_space_4'))
                      .backgroundColor(this.selectedColor).borderRadius($r('app.float.product_radius_control'))
                  }.width('100%')
                  Text(this.sourceLabel(row.providerId)).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                }
                Text(this.partOfSpeechLabel(row.partOfSpeech)).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                Text(row.meanings.join('；')).fontSize($r('app.float.product_body_small_size'))
                  .fontColor(this.textPrimaryColor).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (row: DictionarySenseRow) => row.key)
          }.width('100%').alignItems(HorizontalAlign.Start)
        }
        .id('reader-dictionary-found')
        .scrollBar(BarState.Auto).layoutWeight(1).width('100%')

      } else {
        Column({ space: $r('app.float.product_space_8') }) {
          Text(this.statusTitle()).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium)
            .fontColor(this.result?.status === 'not-found' ? this.textPrimaryColor : this.errorColor)
          Text(this.statusDetail()).fontSize($r('app.float.product_body_small_size')).fontColor(this.textSecondaryColor).textAlign(TextAlign.Center)
        }
        .id(this.result?.status === 'not-found' ? 'reader-dictionary-not-found' :
          (this.result?.status === 'invalid-selection' ? 'reader-dictionary-invalid-selection' :
            'reader-dictionary-unavailable'))
        .width('100%').padding($r('app.float.product_space_8'))
        .justifyContent(FlexAlign.Center).layoutWeight(1)
        .backgroundColor(this.result?.status === 'not-found' ? this.surfaceMutedColor : this.errorContainerColor)
        .borderRadius($r('app.float.product_radius_control'))
      }

      Row({ space: $r('app.float.product_space_8') }) {
        if (this.adjusting) {
          Button('✓').id('reader-dictionary-save-range')
            .type(ButtonType.Normal).height($r('app.float.product_target_min'))
            .accessibilityText('保存调整后的标记范围')
            .fontColor(this.onAccentColor).backgroundColor(this.accentColor)
            .layoutWeight(1).onClick(() => this.onSaveRange())
        } else {
          Button() {
            Image(this.darkTheme ? $r('app.media.reader_mark_highlight_dark') :
              $r('app.media.reader_mark_highlight')).width(24).height(24)
          }.id('reader-dictionary-highlight').type(ButtonType.Normal)
            .height($r('app.float.product_target_min')).layoutWeight(1)
            .accessibilityText('高亮所选单词')
            .backgroundColor(this.accentColor).borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.onHighlight())
          Button() {
            Image(this.darkTheme ? $r('app.media.reader_mark_note_dark') :
              $r('app.media.reader_mark_note')).width(24).height(24)
          }.id('reader-dictionary-note').type(ButtonType.Normal)
            .height($r('app.float.product_target_min')).layoutWeight(1)
            .accessibilityText('给所选单词写笔记')
            .backgroundColor(this.accentColor).borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.onNote())
        }
        Button() {
          SymbolGlyph($r('sys.symbol.square_and_square')).fontSize($r('app.float.product_body_size'))
            .fontColor([this.accentColor])
        }.id('reader-dictionary-copy').type(ButtonType.Normal)
          .constraintSize({ minHeight: $r('app.float.product_target_min') })
          .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
          .accessibilityText($r('app.string.reader_dictionary_copy'))
          .backgroundColor(this.surfaceColor)
          .border({ width: 1, color: this.textSecondaryColor }).borderRadius($r('app.float.product_radius_control'))
          .enabled(this.selectedForm.length > 0).onClick(() => this.onCopy())
        if (this.hasMore()) {
          Button(this.expanded ? $r('app.string.reader_dictionary_collapse') :
            $r('app.string.reader_dictionary_more'))
            .id('reader-dictionary-more').type(ButtonType.Normal)
            .constraintSize({ minHeight: $r('app.float.product_target_min') }).fontColor(this.accentColor)
            .fontSize($r('app.float.product_label_size')).backgroundColor(this.surfaceColor)
            .border({ width: 1, color: this.textSecondaryColor }).borderRadius($r('app.float.product_radius_control'))
            .layoutWeight(1).onClick(() => this.onToggleExpanded())
        }
      }.width('100%')
    }
    .id('reader-dictionary-panel').width('100%').height('100%')
    .padding($r('app.float.product_space_12')).backgroundColor(this.surfaceColor)
    .border({ width: 1, color: this.dividerColor })
    .borderRadius($r('app.float.product_radius_modal'))
  }
}
