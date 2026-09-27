import { BatchImportItemSnapshot, BatchImportSnapshot } from '../application/BatchImportCoordinator';
import { Book } from '../domain/Models';
import { AdaptiveWindowSnapshot, DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, adaptivePageInsetVp } from '../layout/AdaptiveLayoutPolicy';
import { ProductTopBar } from '../components/ProductTopBar';
import { TxtEncodingChoice, TxtPreview } from '../domain/TxtEncoding';

// API 21 List space requires a numeric vp value.
const BATCH_LIST_GAP_VP: number = 12;
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
  @State private editingId: number = 0;
  @State private selectedEncoding: TxtEncodingChoice = 'auto';
  @State private previewLoading: boolean = false;
  @State private preview: TxtPreview = { valid: false, excerpt: '', encoding: 'auto', message: '' };
  private previewRevision: number = 0;
  @Prop state: BatchImportSnapshot = { phase: 'idle', items: [], activeIndex: -1, limit: 4 };
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
    Column({ space: $r('app.float.product_space_12') }) {
      Text('文字预览').fontSize($r('app.float.product_page_title_size'))
        .fontColor($r('app.color.product_text_primary')).width('100%')
      Text(this.state.items.find((item: BatchImportItemSnapshot): boolean => item.id === this.editingId)?.label ?? '')
        .fontSize($r('app.float.product_body_size'))
        .fontColor($r('app.color.product_text_secondary')).width('100%').maxLines(2)
      Select(TXT_ENCODINGS.map((option: TxtEncodingOption): SelectOption => ({ value: option.label })))
        .id('txt-encoding-select').selected(TXT_ENCODINGS.findIndex(
          (option: TxtEncodingOption): boolean => option.code === this.selectedEncoding))
        .value(this.encodingLabel(this.selectedEncoding)).width('100%')
        .onSelect((index: number): void => {
          const option = TXT_ENCODINGS[index];
          if (option === undefined) return;
          this.selectedEncoding = option.code;
          this.loadPreview();
        })
      Text(this.previewLoading ? '正在读取预览…' :
        this.preview.valid ? `按 ${this.encodingLabel(this.selectedEncoding)} 读取：` : this.preview.message)
        .fontSize($r('app.float.product_label_size'))
        .fontColor(this.preview.valid ? $r('app.color.product_text_secondary') : $r('app.color.product_warning'))
        .width('100%')
      Scroll() {
        Text(this.preview.excerpt).id('txt-preview-text')
          .fontSize($r('app.float.product_body_size'))
          .fontColor($r('app.color.product_text_primary')).width('100%')
      }.layoutWeight(1).width('100%').padding($r('app.float.product_space_12'))
        .backgroundColor($r('app.color.product_surface'))
      Button('使用此编码').id('txt-encoding-confirm').width('100%')
        .height($r('app.float.product_target_min'))
        .fontColor($r('app.color.product_on_accent')).backgroundColor($r('app.color.product_accent'))
        .borderRadius($r('app.float.product_radius_control'))
        .enabled(this.preview.valid && !this.previewLoading)
        .onClick((): void => {
          this.onSetTextEncoding(this.editingId, this.selectedEncoding);
          this.closePreview();
        })
      Button('返回').id('txt-encoding-back').width('100%')
        .height($r('app.float.product_target_min')).type(ButtonType.Normal)
        .fontColor($r('app.color.product_text_primary'))
        .backgroundColor($r('app.color.product_surface_muted'))
        .borderRadius($r('app.float.product_radius_control'))
        .onClick((): void => this.closePreview())
    }.width('100%').height('100%').constraintSize({ maxWidth: BATCH_CONTENT_MAX_WIDTH_VP })
  }

  private title(): string {
    if (this.state.phase === 'running') return '正在导入';
    if (this.state.phase === 'results') return '导入结果';
    return '检查待导入书籍';
  }

  private subtitle(): string {
    if (this.state.phase === 'running') {
      return `第 ${this.state.activeIndex + 1} 本，共 ${this.state.items.length} 本`;
    }
    if (this.state.phase === 'results') return '选择一本书开始阅读。';
    return `已添加 ${this.state.items.length}/${this.state.limit} 本`;
  }

  private showImportTips(): void {
    this.getUIContext().showAlertDialog({
      title: '导入提示',
      message: '推荐 EPUB：通常自带目录和排版。\n\nTXT 只有纯文字，章节标题靠识别；目录可能不完整，也无法还原图片和原有样式。\n\n如果 TXT 预览出现乱码，点“预览 / 编码”选择其他编码。编码是文件保存文字的方式，预览正常后再导入。',
      primaryButton: { value: '知道了', action: (): void => {} }
    });
  }

  private statusLabel(status: string): string {
    if (status === 'active') return '正在处理';
    if (status === 'stored') return '已导入';
    if (status === 'restored') return '已恢复';
    if (status === 'duplicate') return '已有同一文件';
    if (status === 'rejected') return '未通过安全检查';
    if (status === 'failed') return '导入失败';
    if (status === 'cancelled') return '已取消';
    if (status === 'not-started') return '未开始';
    return '等待导入';
  }

  private statusColor(status: string): Resource {
    if (status === 'stored' || status === 'restored') return $r('app.color.product_success');
    if (status === 'duplicate' || status === 'cancelled') return $r('app.color.product_warning');
    if (status === 'rejected' || status === 'failed') return $r('app.color.product_error');
    return $r('app.color.product_text_secondary');
  }

  private requestPhaseFocus(id: string): void {
    try { this.getUIContext().getFocusController().requestFocus(id); } catch (_) {}
  }

  @Builder
  private itemRow(item: BatchImportItemSnapshot) {
    Column({ space: $r('app.float.product_space_8') }) {
      Row({ space: $r('app.float.product_space_12') }) {
        Column({ space: $r('app.float.product_space_4') }) {
          Text(item.label).fontSize($r('app.float.product_body_size'))
            .fontColor($r('app.color.product_text_primary')).maxLines(3).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.statusLabel(item.status)).fontSize($r('app.float.product_caption_size'))
            .fontColor(this.statusColor(item.status))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (this.state.phase === 'review') {
          Button('移除').id(`batch-remove-${item.id}`).height($r('app.float.product_target_min'))
            .type(ButtonType.Normal).fontColor($r('app.color.product_text_primary'))
            .backgroundColor($r('app.color.product_surface_muted'))
            .borderRadius($r('app.float.product_radius_control')).onClick(() => this.onRemove(item.id))
        } else if (this.state.phase === 'results' && item.book !== undefined &&
          (item.status === 'stored' || item.status === 'restored' || item.status === 'duplicate')) {
          Button('打开').id(`batch-open-${item.id}`).height($r('app.float.product_target_min'))
            .fontColor($r('app.color.product_on_accent')).backgroundColor($r('app.color.product_accent'))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.onOpen(item.book as Book))
        }
      }.width('100%')
      if (item.message !== undefined && item.message.length > 0) {
        Text(item.message).fontSize($r('app.float.product_caption_size'))
          .fontColor($r('app.color.product_text_secondary')).width('100%')
      }
      if (this.state.phase === 'review' && item.txtEncoding !== undefined) {
        Row({ space: $r('app.float.product_space_8') }) {
          Text(item.txtReady ? `编码：${this.encodingLabel(item.txtEncoding)}` :
            (item.txtMessage ?? '正在识别编码…'))
            .fontSize($r('app.float.product_caption_size'))
            .fontColor(item.txtReady ? $r('app.color.product_text_secondary') :
              $r('app.color.product_warning')).layoutWeight(1)
          Button('预览 / 编码').id(`txt-encoding-${item.id}`)
            .height($r('app.float.product_target_min')).type(ButtonType.Normal)
            .fontColor($r('app.color.product_text_primary'))
            .backgroundColor($r('app.color.product_surface_muted'))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.openPreview(item))
        }.width('100%')
      }
    }.id(`batch-item-${item.id}`).width('100%').padding($r('app.float.product_space_12'))
      .backgroundColor($r('app.color.product_surface'))
  }

  build() {
    Column() {
      if (this.editingId !== 0 && this.state.phase === 'review') {
        this.previewPanel()
      } else {
      Column({ space: $r('app.float.product_space_12') }) {
      ProductTopBar({ title: this.title(), subtitle: this.subtitle(), showSettings: false })
      if (this.state.phase === 'review') {
        Row() {
          Button('导入提示').id('batch-import-tips')
            .height($r('app.float.product_target_min')).type(ButtonType.Normal)
            .fontColor($r('app.color.product_text_primary'))
            .backgroundColor($r('app.color.product_surface_muted'))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.showImportTips())
        }.width('100%').justifyContent(FlexAlign.End)
      }
      Column({ space: $r('app.float.product_space_8') }) {
        if (this.state.message !== undefined && this.state.message.length > 0) {
          Row({ space: $r('app.float.product_space_8') }) {
            SymbolGlyph($r('sys.symbol.exclamationmark_triangle'))
              .fontSize($r('app.float.product_body_small_size'))
              .fontColor([$r('app.color.product_warning')])
            Text(this.state.message).id('batch-message').fontSize($r('app.float.product_label_size'))
              .fontColor($r('app.color.product_warning')).layoutWeight(1)
          }.width('100%').padding($r('app.float.product_space_12'))
            .backgroundColor($r('app.color.product_surface_muted'))
        }
        List({ space: BATCH_LIST_GAP_VP }) {
          ForEach(this.state.items, (item: BatchImportItemSnapshot) => {
            ListItem() { this.itemRow(item) }
          }, (item: BatchImportItemSnapshot): string =>
            `${this.state.phase}-${item.id}-${item.status}-${item.txtEncoding}-${item.txtReady}`)
        }.id('batch-items').layoutWeight(1).width('100%')
      }.layoutWeight(1).width('100%').padding($r('app.float.product_space_12'))
        .backgroundColor($r('app.color.product_surface'))
        .border({ width: 1, color: $r('app.color.product_divider') })

      if (this.state.phase === 'review') {
        Column({ space: $r('app.float.product_space_8') }) {
          Button('开始导入').id('batch-confirm').width('100%')
            .height($r('app.float.product_target_min')).focusable(true).defaultFocus(true)
            .fontColor($r('app.color.product_on_accent'))
            .backgroundColor($r('app.color.product_accent'))
            .borderRadius($r('app.float.product_radius_control'))
            .enabled(this.canConfirm()).onClick(() => this.onConfirm())
            .onAppear((): void => { this.requestPhaseFocus('batch-confirm'); })
          Button('继续添加').id('batch-continue').width('100%')
            .height($r('app.float.product_target_min')).type(ButtonType.Normal)
            .fontColor($r('app.color.product_text_primary')).backgroundColor($r('app.color.product_surface_muted'))
            .borderRadius($r('app.float.product_radius_control'))
            .enabled(this.state.items.length < this.state.limit).onClick(() => this.onContinueAdding())
          Button('取消').id('batch-review-cancel').width('100%')
            .height($r('app.float.product_target_min')).type(ButtonType.Normal)
            .fontColor($r('app.color.product_text_primary')).backgroundColor($r('app.color.product_surface_muted'))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.onCancelReview())
        }.width('100%')
      } else if (this.state.phase === 'running') {
        Button('取消剩余导入').id('batch-cancel-running').width('100%')
          .height($r('app.float.product_target_min')).focusable(true).defaultFocus(true)
          .fontColor($r('app.color.product_on_accent'))
          .backgroundColor($r('app.color.product_accent'))
          .borderRadius($r('app.float.product_radius_control')).onClick(() => this.onCancelRunning())
          .onAppear((): void => { this.requestPhaseFocus('batch-cancel-running'); })
      } else if (this.state.phase === 'results') {
        Button('完成').id('batch-done').width('100%').focusable(true).defaultFocus(true)
          .height($r('app.float.product_target_min')).fontColor($r('app.color.product_on_accent'))
          .backgroundColor($r('app.color.product_accent'))
          .borderRadius($r('app.float.product_radius_control')).onClick(() => this.onDone())
          .onAppear((): void => { this.requestPhaseFocus('batch-done'); })
      }
      }.width('100%').height('100%').constraintSize({ maxWidth: BATCH_CONTENT_MAX_WIDTH_VP })
      }
    }.id('batch-import-page').width('100%').height('100%').alignItems(HorizontalAlign.Center)
      .padding({
        left: this.windowSnapshot.safeInsets.left + adaptivePageInsetVp(this.windowSnapshot.sizeClass),
        right: this.windowSnapshot.safeInsets.right + adaptivePageInsetVp(this.windowSnapshot.sizeClass),
        top: this.windowSnapshot.safeInsets.top + 20,
        bottom: this.windowSnapshot.safeInsets.bottom + 12
      }).backgroundColor($r('app.color.product_canvas'))
  }
}
