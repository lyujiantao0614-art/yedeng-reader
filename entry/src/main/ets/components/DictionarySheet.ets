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
  @Prop nativeContainer: boolean = false;
  @Prop maxContentHeight: number = 480;
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
  @Prop selectionActionsAvailable: boolean = true;
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
    Column({ space: 12 }) {
      Row({ space: $r('app.float.product_space_8') }) {
        Column({ space: $r('app.float.product_space_4') }) {
          Text(this.selectedForm.length > 0 ? this.selectedForm : $r('app.string.reader_dictionary_title'))
            .fontSize(26).fontWeight(FontWeight.Medium).fontColor(this.textPrimaryColor)
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text($r('app.string.reader_dictionary_offline_label')).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button() { SymbolGlyph($r('sys.symbol.square_and_square')).fontSize(18).fontColor([this.accentColor]) }
          .id('reader-dictionary-copy').type(ButtonType.Circle).width(48).height(48)
          .accessibilityText($r('app.string.reader_dictionary_copy')).backgroundColor(Color.Transparent)
          .enabled(this.selectedForm.length > 0).onClick(() => this.onCopy())
        Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(18).fontColor([this.textSecondaryColor]) }
          .id('reader-dictionary-dismiss')
          .type(ButtonType.Circle).fontColor(this.accentColor)
          .fontSize($r('app.float.product_surface_title_size'))
          .backgroundColor(Color.Transparent)
          .width($r('app.float.product_target_min')).height($r('app.float.product_target_min'))
          .accessibilityText($r('app.string.reader_dictionary_close'))
          .onClick(() => this.onDismiss())
      }.width('100%')

      Scroll() {
        Column({ space: 12 }) {
      if (this.loading) {
        Row({ space: $r('app.float.product_space_12') }) {
          LoadingProgress().width($r('app.float.product_space_24')).height($r('app.float.product_space_24')).color(this.accentColor)
          Text($r('app.string.reader_dictionary_loading')).fontSize($r('app.float.product_body_small_size')).fontColor(this.textPrimaryColor)
        }
        .id('reader-dictionary-loading')
        .width('100%').padding({ top: 12, bottom: 12 })
      } else if (this.result?.status === 'found') {
          Column({ space: $r('app.float.product_space_8') }) {
            ForEach(this.rows(this.expanded), (row: DictionarySenseRow) => {
              Column({ space: $r('app.float.product_space_4') }) {
                if (row.firstForEntry) {
                  Row({ space: $r('app.float.product_space_8') }) {
                    Text(row.headword).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium).fontColor(this.textPrimaryColor)
                    Text(this.matchLabel(row.matchKind)).fontSize($r('app.float.product_caption_size')).fontColor(this.accentColor)
                  }.width('100%')
                  Text(this.sourceLabel(row.providerId)).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                }
                Text(this.partOfSpeechLabel(row.partOfSpeech)).fontSize($r('app.float.product_caption_size')).fontColor(this.textSecondaryColor)
                Text(row.meanings.join('；')).fontSize(16).lineHeight(24)
                  .fontColor(this.textPrimaryColor).width('100%')
              }.width('100%').alignItems(HorizontalAlign.Start)
            }, (row: DictionarySenseRow) => row.key)
          }.width('100%').alignItems(HorizontalAlign.Start)
        .id('reader-dictionary-found')
        .width('100%')
        if (this.hasMore()) {
          Button(this.expanded ? $r('app.string.reader_dictionary_collapse') : $r('app.string.reader_dictionary_more'))
            .id('reader-dictionary-more').height(48).fontSize(14).type(ButtonType.Normal)
            .buttonStyle(ButtonStyleMode.TEXTUAL).fontColor(this.accentColor).backgroundColor(Color.Transparent)
            .padding({ left: 0, right: 12 }).onClick(() => this.onToggleExpanded())
        }

      } else {
        Column({ space: $r('app.float.product_space_8') }) {
          Text(this.statusTitle()).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium)
            .fontColor(this.result?.status === 'not-found' ? this.textPrimaryColor : this.errorColor)
          Text(this.statusDetail()).fontSize($r('app.float.product_body_small_size')).fontColor(this.textSecondaryColor)
        }
        .id(this.result?.status === 'not-found' ? 'reader-dictionary-not-found' :
          (this.result?.status === 'invalid-selection' ? 'reader-dictionary-invalid-selection' :
            'reader-dictionary-unavailable'))
        .width('100%').alignItems(HorizontalAlign.Start).padding({ top: 12, bottom: 16 })
      }
        }.width('100%').alignItems(HorizontalAlign.Start)
      }.id('reader-dictionary-scroll').width('100%').constraintSize({ maxHeight: this.maxContentHeight })
        .align(Alignment.TopStart).scrollBar(BarState.Auto).scrollBarWidth(2)
        .scrollBarColor(this.darkTheme ? '#40FFFFFF' : '#33182431')

      if (this.adjusting || this.selectionActionsAvailable) {
      Row({ space: 8 }) {
        if (this.adjusting) {
          Button('保存范围').id('reader-dictionary-save-range').height(48).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.EMPHASIZED).backgroundColor(this.accentColor).fontColor(this.onAccentColor)
            .accessibilityText('保存调整后的标记范围').onClick(() => this.onSaveRange())
        } else if (this.selectionActionsAvailable) {
          Button('高亮').id('reader-dictionary-highlight').height(48).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(this.surfaceMutedColor).fontColor(this.accentColor)
            .accessibilityText('高亮所选单词').onClick(() => this.onHighlight())
          Button('笔记').id('reader-dictionary-note').height(48).layoutWeight(1)
            .buttonStyle(ButtonStyleMode.NORMAL).backgroundColor(this.surfaceMutedColor).fontColor(this.accentColor)
            .accessibilityText('给所选单词写笔记').onClick(() => this.onNote())
        }
      }.width('100%')
      }
    }
    .id('reader-dictionary-panel').width('100%')
    .padding(this.nativeContainer ? 0 : 16).backgroundColor(this.nativeContainer ? Color.Transparent : this.surfaceColor)
    .borderRadius(this.nativeContainer ? 0 : 24)
  }
}
