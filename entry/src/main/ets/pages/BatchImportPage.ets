import { BookshelfDefaultMode } from '../domain/LibraryPresentation';
import { bookshelfColor, BookshelfColorRole } from '../layout/BookshelfThemePalette';
import { BatchImportItemSnapshot, BatchImportSnapshot } from '../application/BatchImportCoordinator';
import { Book } from '../domain/Models';
import { AdaptiveWindowSnapshot, DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, adaptivePageInsetVp } from '../layout/AdaptiveLayoutPolicy';
import { LengthMetrics } from '@kit.ArkUI';
import { NativeSelectMenuMaterial, nativeAlertOptions } from '../platform/NativeOverlayMaterial';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

// API 21 List space requires a numeric vp value.
const BATCH_CONTENT_MAX_WIDTH_VP: number = 720;

interface TxtEncodingOption {
  code: TxtEncodingChoice;
  label: string;
}

const TXT_ENCODINGS: TxtEncodingOption[] = [
  { code: 'auto', label: '自动识别' },
  { code: 'utf-8', label: 'UTF-8' },
  { code: 'utf-16le', label: 'UTF-16 小端' },
  { code: 'utf-16be', label: 'UTF-16 大端' },
  { code: 'gb18030', label: 'GB18030' },
  { code: 'gbk', label: 'GBK / GB2312' },
  { code: 'big5', label: 'Big5' },
  { code: 'shift_jis', label: 'Shift_JIS' },
  { code: 'euc-jp', label: 'EUC-JP' },
  { code: 'iso-2022-jp', label: 'ISO-2022-JP' },
  { code: 'euc-kr', label: 'EUC-KR' },
  { code: 'windows-1252', label: '西欧 Windows-1252' },
  { code: 'windows-1251', label: '西里尔 Windows-1251' },
  { code: 'windows-1250', label: '中欧 Windows-1250' }
];

export class BatchImportPageController {
  private backHandler?: () => boolean;

  bind(backHandler: () => boolean): void { this.backHandler = backHandler; }
  unbind(): void { this.backHandler = undefined; }
  handleSystemBack(): boolean { return this.backHandler?.() ?? false; }
}

@Component
export struct BatchImportPage {
  @Prop defaultMode: BookshelfDefaultMode = 'system';
  private color(role: BookshelfColorRole): ResourceColor { return bookshelfColor('default', role, this.defaultMode); }
  @Prop panelMaterial: SystemUiMaterial | undefined = undefined;
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  @State private editingId: number = 0;
  @State private selectedEncoding: TxtEncodingChoice = 'auto';
  @State private previewLoading: boolean = false;
  @State private preview: TxtPreview = { valid: false, excerpt: '', encoding: 'auto', message: '' };
  private previewRevision: number = 0;
  @Prop state: BatchImportSnapshot = { phase: 'idle', items: [], activeIndex: -1, limit: 4 };
  @Prop targetLabel: string = '书库';
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  pageController: BatchImportPageController = new BatchImportPageController();
  onContinueAdding: () => void = (): void => {};
  onRemove: (id: number) => void = (_id: number): void => {};
  onConfirm: () => void = (): void => {};
  onCancelReview: () => void = (): void => {};
  onCancelRunning: () => void = (): void => {};
  onDone: () => void = (): void => {};
  onOpen: (book: Book) => void = (_book: Book): void => {};
  onPreviewText: (id: number, encoding: TxtEncodingChoice) => Promise<TxtPreview> =
    async (_id: number, encoding: TxtEncodingChoice): Promise<TxtPreview> =>
      ({ valid: false, excerpt: '', encoding: encoding, message: '无法预览。' });
  onSetTextEncoding: (id: number, encoding: TxtEncodingChoice) => void =
    (_id: number, _encoding: TxtEncodingChoice): void => {};

  aboutToAppear(): void {
    this.pageController.bind((): boolean => {
      if (this.editingId === 0) return false;
      this.closePreview();
      return true;
    });
  }

  aboutToDisappear(): void { this.pageController.unbind(); }

  private encodingLabel(code: TxtEncodingChoice): string {
    return TXT_ENCODINGS.find((option: TxtEncodingOption): boolean => option.code === code)?.label ?? code;
  }

  private canConfirm(): boolean {
    return this.state.items.every((item: BatchImportItemSnapshot): boolean => item.txtReady !== false);
  }

  private openPreview(item: BatchImportItemSnapshot): void {
    this.editingId = item.id;
    this.selectedEncoding = item.txtEncoding ?? 'auto';
    this.loadPreview();
  }

  private loadPreview(): void {
    const id = this.editingId;
    const encoding = this.selectedEncoding;
    const revision = ++this.previewRevision;
    this.previewLoading = true;
    this.preview = { valid: false, excerpt: '', encoding: encoding, message: '' };
    this.onPreviewText(id, encoding).then((result: TxtPreview): void => {
      if (revision !== this.previewRevision || id !== this.editingId) return;
      this.preview = result;
      this.previewLoading = false;
    }).catch((): void => {
      if (revision !== this.previewRevision || id !== this.editingId) return;
      this.preview = { valid: false, excerpt: '', encoding: encoding, message: '无法读取这个文件。' };
      this.previewLoading = false;
    });
  }

  private closePreview(): void {
    this.previewRevision++;
    this.editingId = 0;
  }

  @Builder
  private previewPanel() {
    Column({ space: 12 }) {
      Row({ space: 4 }) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(20)
            .fontColor([this.color('secondary')])
        }.id('txt-encoding-back').width(48).height(48).type(ButtonType.Circle)
          .backgroundColor(Color.Transparent).accessibilityText('返回导入确认')
          .onClick((): void => this.closePreview())
        Text('文字预览').fontSize('20fp').fontWeight(FontWeight.Medium)
          .fontColor(this.color('text')).layoutWeight(1)
      }.width('100%').height(56)
      Text(this.state.items.find((item: BatchImportItemSnapshot): boolean => item.id === this.editingId)?.label ?? '')
        .fontSize('14fp').fontColor(this.color('secondary')).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).padding({ left: 16, right: 16 })
      Row({ space: 12 }) {
        Text('文字编码').fontSize('16fp').fontColor(this.color('text')).layoutWeight(1)
        Select(TXT_ENCODINGS.map((option: TxtEncodingOption): SelectOption => ({ value: option.label })))
          .attributeModifier(new NativeSelectMenuMaterial(this.menuMaterial))
          .id('txt-encoding-select').selected(TXT_ENCODINGS.findIndex(
            (option: TxtEncodingOption): boolean => option.code === this.selectedEncoding))
          .value(this.encodingLabel(this.selectedEncoding)).font({ size: 14, weight: FontWeight.Regular })
          .onSelect((index: number): void => {
            const option = TXT_ENCODINGS[index];
            if (option === undefined) return;
            this.selectedEncoding = option.code;
            this.loadPreview();
          })
      }.width('100%').constraintSize({ minHeight: 64 }).padding({ left: 16, right: 16 })
        .backgroundColor(this.color('surface')).borderRadius(12)
      Row({ space: 8 }) {
        if (this.previewLoading) { LoadingProgress().width(20).height(20) }
        Text(this.previewLoading ? '正在读取预览…' : this.preview.valid ?
          '文字显示正常后，即可使用此编码。' : this.preview.message)
          .id('txt-preview-status').fontSize('13fp').layoutWeight(1)
          .fontColor(this.previewLoading || this.preview.valid ?
            this.color('secondary') : this.color('warning'))
      }.width('100%').padding({ left: 16, right: 16 })
      Scroll() {
        Text(this.preview.excerpt).id('txt-preview-text').fontSize('16fp')
          .lineSpacing(LengthMetrics.vp(6)).fontColor(this.color('text')).width('100%')
          .padding(16)
      }.layoutWeight(1).width('100%').align(Alignment.TopStart)
        .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431')
        .backgroundColor(this.color('surface')).borderRadius(12)
      Button('使用此编码').id('txt-encoding-confirm').width('100%').height(48)
        .role(ButtonRole.NORMAL).buttonStyle(ButtonStyleMode.EMPHASIZED)
        .enabled(this.preview.valid && !this.previewLoading)
        .onClick((): void => {
          this.onSetTextEncoding(this.editingId, this.selectedEncoding);
          this.closePreview();
        })
    }.width('100%').height('100%').constraintSize({ maxWidth: BATCH_CONTENT_MAX_WIDTH_VP })
  }

  private title(): string {
    if (this.state.phase === 'running') return '正在导入';
    if (this.state.phase === 'results') return '导入结果';
    return '导入图书';
  }

  private subtitle(): string {
    if (this.state.phase === 'running') {
      return this.state.activeIndex < 0 ? '正在准备导入…' :
        `正在处理第 ${this.state.activeIndex + 1} 本，共 ${this.state.items.length} 本`;
    }
    if (this.state.phase === 'results') {
      const saved = this.state.items.filter((item: BatchImportItemSnapshot): boolean =>
        item.status === 'stored' || item.status === 'restored').length;
      const existing = this.state.items.filter((item: BatchImportItemSnapshot): boolean => item.status === 'duplicate').length;
      const failed = this.state.items.filter((item: BatchImportItemSnapshot): boolean =>
        item.status === 'failed' || item.status === 'rejected').length;
      const stopped = this.state.items.filter((item: BatchImportItemSnapshot): boolean =>
        item.status === 'cancelled' || item.status === 'not-started').length;
      const parts: string[] = [];
      if (saved > 0) parts.push(`已导入 ${saved} 本`);
      if (existing > 0) parts.push(`${existing} 本已在书库`);
      if (failed > 0) parts.push(`${failed} 本未能导入`);
      if (stopped > 0) parts.push(`${stopped} 本已取消或未开始`);
      return parts.length > 0 ? parts.join('，') : '本次没有导入图书。';
    }
    return `已添加 ${this.state.items.length}/${this.state.limit} 本`;
  }

  private showImportTips(): void {
    this.getUIContext().showAlertDialog(nativeAlertOptions(this.panelMaterial, {
      title: '导入提示',
      message: '推荐 EPUB：通常自带目录和排版。\n\nTXT 只有纯文字，章节标题靠识别；目录可能不完整，也无法还原图片和原有样式。\n\n如果 TXT 预览出现乱码，点“预览 / 编码”选择其他编码。编码是文件保存文字的方式，预览正常后再导入。',
      primaryButton: { value: '知道了', action: (): void => {} }
    }));
  }

  private statusLabel(status: string): string {
    if (status === 'active') return '正在处理';
    if (status === 'stored') return '已导入';
    if (status === 'restored') return '已恢复';
    if (status === 'duplicate') return '已有同一文件';
    if (status === 'rejected') return '未能导入';
    if (status === 'failed') return '导入失败';
    if (status === 'cancelled') return '已取消';
    if (status === 'not-started') return '未开始';
    return '等待导入';
  }

  private statusColor(status: string): ResourceColor {
    if (status === 'stored' || status === 'restored') return this.color('success');
    if (status === 'duplicate' || status === 'cancelled') return this.color('warning');
    if (status === 'rejected' || status === 'failed') return this.color('error');
    return this.color('secondary');
  }

  private requestPhaseFocus(id: string): void {
    try { this.getUIContext().getFocusController().requestFocus(id); } catch (_) {}
  }

  @Builder
  private itemRow(item: BatchImportItemSnapshot) {
    Row({ space: 12 }) {
      if (item.status === 'active') {
        LoadingProgress().width(24).height(24)
      } else {
        SymbolGlyph(item.status === 'stored' || item.status === 'restored' ? $r('sys.symbol.checkmark_circle') :
          item.status === 'failed' || item.status === 'rejected' ? $r('sys.symbol.exclamationmark_circle') :
          $r('sys.symbol.doc_text'))
          .fontSize(24).fontColor([this.statusColor(item.status)])
      }
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(item.label).fontSize('16fp').fontColor(this.color('text'))
            .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (this.state.phase === 'review') {
            Button() { SymbolGlyph($r('sys.symbol.xmark')).fontSize(14) }
              .id(`batch-remove-${item.id}`).width(48).height(48).type(ButtonType.Circle)
              .buttonStyle(ButtonStyleMode.TEXTUAL).accessibilityText('移除 ' + item.label)
              .onClick(() => this.onRemove(item.id))
          } else if (this.state.phase === 'results' && item.book !== undefined &&
            (item.status === 'stored' || item.status === 'restored' || item.status === 'duplicate')) {
            Button('打开').id(`batch-open-${item.id}`).height(40).fontSize('14fp')
              .buttonStyle(ButtonStyleMode.TEXTUAL).onClick(() => this.onOpen(item.book as Book))
          }
        }.width('100%')
        if (this.state.phase !== 'review') {
          Text(this.statusLabel(item.status)).fontSize('13fp').fontColor(this.statusColor(item.status)).width('100%')
        }
        if (item.message !== undefined && item.message.length > 0) {
          Text(item.message).fontSize('13fp').fontColor(this.color('secondary'))
            .lineSpacing(LengthMetrics.vp(3)).width('100%')
        }
        if (this.state.phase === 'review' && item.txtEncoding !== undefined) {
          Row({ space: 8 }) {
            Text(item.txtReady ? `编码：${this.encodingLabel(item.txtEncoding)}` :
              (item.txtMessage ?? '正在识别编码…')).fontSize('13fp').layoutWeight(1)
              .fontColor(item.txtReady ? this.color('secondary') : this.color('warning'))
            Button('预览 / 编码').id(`txt-encoding-${item.id}`).height(40).fontSize('14fp')
              .buttonStyle(ButtonStyleMode.TEXTUAL).onClick((): void => this.openPreview(item))
          }.width('100%')
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
    }.id(`batch-item-${item.id}`).width('100%').padding({ left: 16, right: 8, top: 12, bottom: 12 })
      .constraintSize({ minHeight: 76 }).alignItems(VerticalAlign.Top)
  }

  @Builder
  private phaseHeader() {
    Row({ space: 8 }) {
      Text(this.title()).fontSize('20fp').fontWeight(FontWeight.Medium)
        .fontColor(this.color('text')).layoutWeight(1)
      if (this.state.phase === 'review') {
        Button() { SymbolGlyph($r('sys.symbol.info_circle')).fontSize(20) }
          .id('batch-import-tips').width(48).height(48).type(ButtonType.Circle)
          .buttonStyle(ButtonStyleMode.TEXTUAL).accessibilityText('导入提示')
          .onClick((): void => this.showImportTips())
      }
    }.width('100%').height(56).padding({ left: 8 })
    Column({ space: 6 }) {
      Text(this.subtitle()).id('batch-summary').fontSize('15fp').fontColor(this.color('text')).width('100%')
      Text('导入到：' + this.targetLabel).id('batch-import-target').fontSize('13fp')
        .fontColor(this.color('secondary')).width('100%')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
      if (this.state.phase === 'running') {
        Progress({ value: this.state.items.filter((item: BatchImportItemSnapshot): boolean =>
          item.status !== 'pending' && item.status !== 'active').length, total: this.state.items.length, type: ProgressType.Linear })
          .id('batch-progress').width('100%').margin({ top: 6 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start).padding({ left: 16, right: 16, top: 4, bottom: 16 })
  }

  @Builder
  private phaseActions() {
    if (this.state.phase === 'review') {
      Row({ space: 12 }) {
        Button('取消').id('batch-review-cancel').height(48).layoutWeight(1)
          .role(ButtonRole.NORMAL).buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.onCancelReview())
        Column() {
          Button('开始导入').id('batch-confirm').width('100%').height(48).focusable(true).defaultFocus(true)
            .role(ButtonRole.NORMAL).buttonStyle(ButtonStyleMode.EMPHASIZED)
            .enabled(this.canConfirm()).onClick(() => this.onConfirm())
            .onAppear((): void => { this.requestPhaseFocus('batch-confirm'); })
        }.layoutWeight(1)
      }.width('100%')
    } else if (this.state.phase === 'running') {
      Text('已完成的图书会保留；仅停止当前未提交项和后续项目。').fontSize(13)
        .fontColor(this.color('secondary')).width('100%').padding({ bottom: 8 })
      Button('取消剩余导入').id('batch-cancel-running').width('100%').height(48).focusable(true).defaultFocus(true)
        .role(ButtonRole.NORMAL).buttonStyle(ButtonStyleMode.NORMAL).onClick(() => this.onCancelRunning())
        .onAppear((): void => { this.requestPhaseFocus('batch-cancel-running'); })
    } else if (this.state.phase === 'results') {
      Button('完成').id('batch-done').width('100%').height(48).focusable(true).defaultFocus(true)
        .role(ButtonRole.NORMAL).buttonStyle(ButtonStyleMode.EMPHASIZED).onClick(() => this.onDone())
        .onAppear((): void => { this.requestPhaseFocus('batch-done'); })
    }
  }

  build() {
    Column() {
      if (this.editingId !== 0 && this.state.phase === 'review') {
        this.previewPanel()
      } else {
        Column() {
          this.phaseHeader()
          if (this.state.message !== undefined && this.state.message.length > 0) {
            Text(this.state.message).id('batch-message').fontSize('13fp')
              .fontColor(this.state.phase === 'results' ? this.color('secondary') : this.color('warning'))
              .width('100%').padding({ left: 16, right: 16, bottom: 12 })
          }
          if (this.state.phase === 'results' && this.state.items.some((item: BatchImportItemSnapshot): boolean =>
            item.status === 'failed' || item.status === 'rejected')) {
            Text('已导入的图书会保留。未能导入的文件可返回书架重新选择后重试。').fontSize(13)
              .fontColor(this.color('secondary')).width('100%').padding({ left: 16, right: 16, bottom: 12 })
          }
          List({ space: 12 }) {
            ListItemGroup({ style: ListItemGroupStyle.CARD }) {
              ForEach(this.state.items, (item: BatchImportItemSnapshot) => {
                ListItem() { this.itemRow(item) }
              }, (item: BatchImportItemSnapshot): string =>
                `${this.state.phase}-${item.id}-${item.status}-${item.txtEncoding}-${item.txtReady}`)
            }.backgroundColor(this.color('surface'))
              .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 52, endMargin: 16 })
            if (this.state.phase === 'review') {
              ListItem() {
                Button('继续添加').id('batch-continue').width('100%').height(48)
                  .buttonStyle(ButtonStyleMode.TEXTUAL).enabled(this.state.items.length < this.state.limit)
                  .onClick(() => this.onContinueAdding())
              }
            }
          }.id('batch-items').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.defaultMode === 'dark' ? '#40FFFFFF' : '#33182431').layoutWeight(1).width('100%').padding({ bottom: 12 })
          this.phaseActions()
        }.width('100%').height('100%').constraintSize({ maxWidth: BATCH_CONTENT_MAX_WIDTH_VP })
      }
    }.id('batch-import-page').width('100%').height('100%').alignItems(HorizontalAlign.Center)
      .padding({
        left: this.windowSnapshot.safeInsets.left + adaptivePageInsetVp(this.windowSnapshot.sizeClass),
        right: this.windowSnapshot.safeInsets.right + adaptivePageInsetVp(this.windowSnapshot.sizeClass),
        top: this.windowSnapshot.safeInsets.top + 8,
        bottom: this.windowSnapshot.safeInsets.bottom + 12
      }).backgroundColor(this.color('canvas'))
  }
}
