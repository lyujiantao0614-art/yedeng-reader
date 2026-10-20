import { bundleManager, common } from '@kit.AbilityKit';
import { nonReadingPageTransition } from '../layout/NonReadingMotion';
import { KeyCode } from '@kit.InputKit';
import { util } from '@kit.ArkTS';
import { LengthMetrics } from '@kit.ArkUI';
import { NativeSelectMenuMaterial } from '../platform/NativeOverlayMaterial';
import { DiagnosticExportAction, DiagnosticExportStatus } from '../application/DiagnosticExportApplication';
import { LibraryPresentationApplication } from '../application/LibraryPresentationApplication';
import { ReaderAppearanceApplication } from '../application/ReaderAppearanceApplication';
import { ProductTopBar } from '../components/ProductTopBar';
import { ReaderColumnMode, ReaderSettings, DEFAULT_READER_SETTINGS } from '../domain/Models';
import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { BookshelfColorRole, bookshelfColor } from '../layout/BookshelfThemePalette';
import { ReaderThemePreference, SystemColorMode } from '../domain/AppearancePolicy';
import { AdaptiveWindowSnapshot, DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT } from '../layout/AdaptiveLayoutPolicy';

const PRIVACY_POLICY_URL: string = 'https://litepage.cn/s/yedeng/yedeng-privacy-policy';
export type SettingsSection = 'appearance' | 'reading' | 'dictionary' | 'privacy' | 'about';
export type SettingsRoute = 'root' | SettingsSection | 'privacy-policy' | 'project-license' | 'third-party-notices';
export type SettingsEntrySource = 'library' | 'reader';
interface SettingsEntryRequest { section: SettingsSection; source: SettingsEntrySource; }

// B native review calibration; spatial dimensions are vp, icon font size is fp.
const SETTINGS_GROUP_RADIUS_VP: number = 12;
const SETTINGS_CATEGORY_ICON_FP: number = 22;
const SETTINGS_ROOT_ICON_FP: number = 20;
const SETTINGS_CATEGORIES_ID: string = 'settings-categories';

export class SettingsPageController {
  private systemBackHandler?: () => boolean;
  private resetHandler?: () => void;
  private entryHandler?: (section: SettingsSection, source: SettingsEntrySource) => void;
  private pending?: SettingsEntryRequest;
  private source: SettingsEntrySource = 'library';

  bind(systemBackHandler: () => boolean, resetHandler: () => void,
    entryHandler?: (section: SettingsSection, source: SettingsEntrySource) => void): void {
    this.systemBackHandler = systemBackHandler; this.resetHandler = resetHandler; this.entryHandler = entryHandler;
    const request = this.pending;
    if (request !== undefined && entryHandler !== undefined) {
      this.pending = undefined; entryHandler(request.section, request.source);
    }
  }
  unbind(): void { this.systemBackHandler = undefined; this.resetHandler = undefined; this.entryHandler = undefined; }
  handleSystemBack(): boolean { return this.systemBackHandler?.() ?? false; }
  resetToRoot(): void { this.pending = undefined; this.source = 'library'; this.resetHandler?.(); }
  openSection(section: SettingsSection, source: SettingsEntrySource = 'library'): void {
    this.source = source;
    if (this.entryHandler !== undefined) this.entryHandler(section, source);
    else this.pending = { section: section, source: source };
  }
  entrySource(): SettingsEntrySource { return this.source; }
}

@Component
export struct SettingsPage {
  @Prop reducedMotion: boolean | undefined = undefined;
  @Prop menuMaterial: SystemUiMaterial | undefined = undefined;
  readerAppearance?: ReaderAppearanceApplication;
  libraryPresentation?: LibraryPresentationApplication;
  diagnosticExport?: DiagnosticExportAction;
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop systemColorMode: SystemColorMode = 'light';
  @Prop renderBackground: boolean = true;
  // Retained for existing composition compatibility; B mode-only changes never call it.
  onThemeApplied: (theme: BookshelfTheme, mode: BookshelfDefaultMode) => boolean =
    (_theme: BookshelfTheme, _mode: BookshelfDefaultMode): boolean => false;
  onInterfaceModeSaved: (mode: BookshelfDefaultMode) => void = (_mode: BookshelfDefaultMode): void => {};
  onReaderPreferenceSaved: () => void = (): void => {};
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  pageController: SettingsPageController = new SettingsPageController();
  onExit: (source: SettingsEntrySource) => void = (_source: SettingsEntrySource): void => {};

  @State private route: SettingsRoute = 'root';
  @State private interfaceMode: BookshelfDefaultMode = 'system';
  @State private layout: ReaderSettings = DEFAULT_READER_SETTINGS;
  @State private readerTheme: ReaderThemePreference = 'system';
  @State private showControlsButton: boolean = false;
  @State private hideControlsButton: boolean = false;
  @State private confirmedControlRevision: number = 0;
  @State private status: string = '';
  @State private legalText: string = '';
  @State private legalLoading: boolean = false;
  @State private dictionaryInfo: string = '正在加载词典信息…';
  @State private versionInfo: string = '正在读取版本';
  @State private diagnosticExporting: boolean = false;
  @State private diagnosticExportStatus: DiagnosticExportStatus | undefined = undefined;
  private entrySection?: SettingsSection;
  private focusAfterReturn: string = '';
  private legalRequest: number = 0;

  aboutToAppear(): void {
    this.reloadConfirmed();
    this.pageController.bind((): boolean => this.handleSystemBack(), (): void => this.resetToRoot(),
      (section: SettingsSection, source: SettingsEntrySource): void => {
        this.entrySection = source === 'reader' ? section : undefined;
        this.openRoute(section);
      });
    this.loadResources().catch((): void => {});
  }
  aboutToDisappear(): void { this.pageController.unbind(); this.legalRequest += 1; }
  private wide(): boolean { return this.windowSnapshot.usableWidthVp >= 840; }
  private color(role: BookshelfColorRole): ResourceColor {
    return bookshelfColor('default', role, this.interfaceMode === 'system' ? this.systemColorMode : this.interfaceMode);
  }
  private reloadConfirmed(): boolean {
    try {
      this.interfaceMode = this.libraryPresentation?.loadDefaultMode() ?? this.bookshelfDefaultMode;
      this.layout = this.readerAppearance?.loadSettings() ?? DEFAULT_READER_SETTINGS;
      this.readerTheme = this.readerAppearance?.persistentPreference() ?? 'system';
      this.showControlsButton = this.readerAppearance?.showControlsButton() ?? false;
      this.hideControlsButton = this.readerAppearance?.hideControlsButton() ?? false;
      return true;
    } catch (_) { this.status = '设置读取失败，请返回重试'; return false; }
  }
  private save(action: () => void, readerChange: boolean = true, restoreControlId: string = ''): void {
    try {
      action();
    } catch (_) {
      this.reloadConfirmed();
      if (restoreControlId.length > 0) {
        // A native Switch owns its checked state. Recreate only the failed control leaf
        // from the persisted value even when that value equals the previous @State.
        this.focusAfterReturn = restoreControlId; this.confirmedControlRevision++;
      }
      this.status = '保存失败，已保留上次确认值，请重试'; return;
    }
    if (!this.reloadConfirmed()) return;
    this.status = '';
    // Notification cannot precede successful persistence.
    if (readerChange) this.onReaderPreferenceSaved();
    else this.onInterfaceModeSaved(this.interfaceMode);
  }
  private setInterfaceMode(mode: BookshelfDefaultMode): void {
    const application = this.libraryPresentation;
    if (application === undefined) { this.status = '显示设置尚未就绪，请返回重试'; return; }
    this.save((): void => application.saveDefaultMode(mode), false);
  }
  private setReaderTheme(preference: ReaderThemePreference): void {
    const application = this.readerAppearance;
    if (application === undefined) { this.status = '阅读设置尚未就绪，请返回重试'; return; }
    this.save((): void => application.saveThemePreference(preference));
  }
  private setLayout(font: number, spacing: number, margin: number, column: ReaderColumnMode, commit: boolean = true): void {
    const application = this.readerAppearance;
    if (application === undefined) { this.status = '阅读设置尚未就绪，请返回重试'; return; }
    const next: ReaderSettings = { fontScale: font, lineSpacing: spacing, pageMarginVp: margin,
      columnMode: column, theme: this.layout.theme };
    if (!commit) { this.layout = next; return; }
    this.save((): void => application.saveLayoutDefaults(next));
  }
  private setControls(enabled: boolean, hide: boolean): void {
    const application = this.readerAppearance;
    if (application === undefined) { this.status = '阅读设置尚未就绪，请返回重试'; return; }
    this.save((): void => {
      if (hide) application.saveHideControlsButton(enabled);
      else application.saveShowControlsButton(enabled);
    }, true, hide ? 'reader-hide-controls-setting' : 'reader-show-controls-setting');
  }
  private resetToRoot(): void {
    this.route = 'root'; this.entrySection = undefined; this.legalRequest += 1;
    this.legalText = ''; this.legalLoading = false; this.focusAfterReturn = '';
  }
  private focus(id: string): void {
    try { this.getUIContext().getFocusController().requestFocus(id); } catch (_) {}
  }
  private handleSystemBack(): boolean {
    if (this.route === 'privacy-policy') {
      this.legalRequest += 1;
      this.focusAfterReturn = 'settings-privacy-policy-local'; this.changeRoute('privacy', 160); return true;
    }
    if (this.route === 'project-license' || this.route === 'third-party-notices') {
      this.focusAfterReturn = this.route === 'project-license' ? 'settings-project-license' : 'settings-third-party-notices';
      this.legalRequest += 1; this.changeRoute('about', 160); return true;
    }
    if (this.entrySection !== undefined && this.route === this.entrySection) return false;
    if (this.route !== 'root') {
      this.focusAfterReturn = 'settings-section-' + this.route;
      this.changeRoute('root', 160);
      if (this.wide()) this.focus(this.focusAfterReturn);
      return true;
    }
    return false;
  }
  private backOrExit(): void { if (!this.handleSystemBack()) this.onExit(this.pageController.entrySource()); }
  private restoreFocus(id: string): void {
    if (this.focusAfterReturn === id) { this.focus(id); this.focusAfterReturn = ''; }
  }
  private openRoute(route: SettingsRoute): void {
    this.legalRequest += 1; this.legalText = ''; this.legalLoading = false;
    this.changeRoute(route, 200);
    if (!this.wide()) this.focusAfterReturn = 'settings-back';
    if (route === 'privacy-policy') this.loadLegal(['privacy/yedeng-privacy-policy.txt'], true);
    if (route === 'project-license') this.loadLegal(['legal/LICENSE', 'legal/NOTICE']);
    if (route === 'third-party-notices') this.loadLegal(['legal/THIRD_PARTY_NOTICES.md']);
  }
  private changeRoute(route: SettingsRoute, duration: number): void {
    if (this.wide() || this.entrySection !== undefined || this.reducedMotion === true) {
      this.route = route; return;
    }
    this.getUIContext().animateTo({ duration, curve: Curve.EaseOut }, (): void => { this.route = route; });
  }
  private async loadLegal(paths: string[], privacy: boolean = false): Promise<void> {
    const request = this.legalRequest; this.legalLoading = true;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const texts: string[] = [];
      for (const path of paths) {
        const text = new util.TextDecoder('utf-8').decodeToString(await context.resourceManager.getRawFileContent(path));
        if (text.length === 0) throw new Error('Empty legal resource');
        texts.push(privacy ? text.substring(text.indexOf('\n') + 1).trimStart() : text);
      }
      if (request === this.legalRequest) this.legalText = texts.join('\n\n');
    } catch (_) { if (request === this.legalRequest) this.legalText = '随包说明读取失败，请返回重试'; }
    finally { if (request === this.legalRequest) this.legalLoading = false; }
  }
  private async loadResources(): Promise<void> {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionInfo = `${info.name} · ${info.versionName} (${info.versionCode})`;
    } catch (_) { this.versionInfo = '无法读取实际版本'; }
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      for (const path of ['dictionary/omw-en-zh.sqlite3', 'dictionary/cc-cedict-en-fallback.sqlite3']) {
        let opened = false;
        try {
          const descriptor = await context.resourceManager.getRawFd(path); opened = true;
          if (descriptor.length <= 0) throw new Error('Empty dictionary resource');
        } finally { if (opened) await context.resourceManager.closeRawFd(path); }
      }
      this.dictionaryInfo = '已内置离线词典，无需额外下载。';
    } catch (_) { this.dictionaryInfo = '暂时无法加载词典信息，离线查词可能不可用。'; }
  }
  private async exportDiagnostics(): Promise<void> {
    if (this.diagnosticExporting) return;
    this.diagnosticExportStatus = undefined; this.diagnosticExporting = true;
    let status: DiagnosticExportStatus = 'failed';
    try { status = await this.diagnosticExport?.export() ?? 'failed'; }
    catch (_) { status = 'failed'; }
    finally { this.diagnosticExporting = false; }
    this.diagnosticExportStatus = status;
  }
  private openPrivacyPolicy(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(PRIVACY_POLICY_URL).catch((): void => {
      try { this.getUIContext().getPromptAction().showToast({ backgroundColor: bookshelfColor(this.bookshelfTheme, 'surface', this.bookshelfDefaultMode), textColor: bookshelfColor(this.bookshelfTheme, 'text', this.bookshelfDefaultMode), message: $r('app.string.privacy_policy_open_failed') }); }
      catch (_) {}
    });
  }

  private scrollIndicatorColor(): string {
    return (this.interfaceMode === 'system' ? this.systemColorMode : this.interfaceMode) === 'dark' ? '#40FFFFFF' : '#33182431';
  }
  @Builder private header(title: ResourceStr, subtitle: ResourceStr = '', root: boolean = false) {
    ProductTopBar({ title: title, subtitle: subtitle, showBack: root || !this.wide(), backId: 'settings-back',
      bookshelfTheme: 'default', bookshelfDefaultMode: this.interfaceMode, onBack: (): void => this.backOrExit() })
      .onAppear((): void => this.restoreFocus('settings-back'))
  }
  @Builder private rootHeader() {
    Row({ space: 4 }) {
      Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(SETTINGS_ROOT_ICON_FP).fontColor([this.color('secondary')]) }
        .id('settings-back').width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.settings_back')).onClick((): void => this.backOrExit())
        .onAppear((): void => this.restoreFocus('settings-back'))
      Text('设置').id('settings-root-title').fontSize('20fp').fontWeight(FontWeight.Medium)
        .fontColor(this.color('text')).layoutWeight(1)
    }.width('100%').height(56)
  }
  @Builder private settingsDetailHeader(title: ResourceStr, backId: string = 'settings-back') {
    Row({ space: 4 }) {
      if (!this.wide()) {
        Button() { SymbolGlyph($r('sys.symbol.chevron_left')).fontSize(SETTINGS_ROOT_ICON_FP).fontColor([this.color('secondary')]) }
          .id(backId).width(48).height(48).type(ButtonType.Circle).backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.settings_back')).onClick((): void => this.backOrExit())
          .onAppear((): void => this.restoreFocus('settings-back'))
      }
      Text(title).fontSize('20fp').fontWeight(FontWeight.Medium).fontColor(this.color('text'))
        .layoutWeight(1).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').height(56)
  }
  @Builder private infoCard(title: ResourceStr, body: ResourceStr) {
    Column({ space: 6 }) {
      Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(this.color('text')).width('100%')
      Text(body).fontSize(14).fontColor(this.color('secondary')).lineSpacing(LengthMetrics.vp(4)).width('100%')
    }.width('100%').padding({ top: 14, bottom: 14, left: 16, right: 16 }).constraintSize({ minHeight: 64 })
      .alignItems(HorizontalAlign.Start)
  }
  @Builder private category(title: string, detail: string, section: SettingsSection, id: string, compact: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        SymbolGlyph(section === 'appearance' ? $r('sys.symbol.sun_max') :
          section === 'reading' ? $r('sys.symbol.textformat') :
          section === 'dictionary' ? $r('sys.symbol.list_book') :
          section === 'privacy' ? $r('sys.symbol.lock') : $r('sys.symbol.info_circle'))
          .fontSize(compact ? SETTINGS_ROOT_ICON_FP : SETTINGS_CATEGORY_ICON_FP).fontColor([this.color('secondary')])
        Column({ space: 4 }) {
          Text(title).fontSize(16).fontWeight(compact ? FontWeight.Regular : FontWeight.Medium).fontColor(this.color('text')).width('100%')
          Text(detail).fontSize($r('app.float.product_caption_size')).fontColor(this.color('secondary')).width('100%')
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        if (!this.wide()) {
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(compact ? 12 : 14).fontColor([this.color('secondary')])
        }
      }.width('100%').padding({ top: compact ? 10 : 14, bottom: compact ? 10 : 14 })
    }.id(id).width('100%').constraintSize({ minHeight: compact ? 64 : 72 }).padding({ left: 16, right: 16 })
      .borderRadius(compact ? 0 : SETTINGS_GROUP_RADIUS_VP)
      .backgroundColor(this.wide() && (this.route === section || (this.route === 'root' && section === 'appearance')) ?
        this.color('muted') : Color.Transparent)
      .accessibilityText(title).accessibilitySelected(this.wide() && (this.route === section || (this.route === 'root' && section === 'appearance')))
      .onClick((): void => this.openRoute(section)).onAppear((): void => this.restoreFocus(id))
  }
  @Builder private categories() {
    Scroll() {
      Column() {
        this.category('显示', '界面显示', 'appearance', 'settings-section-appearance')
        this.category('阅读偏好', 'EPUB/TXT排版、配色与辅助按钮', 'reading', 'settings-section-reading')
        this.category('本地词典', '随包词典与离线单词查询', 'dictionary', 'settings-section-dictionary')
        this.category('隐私与数据', '本地保存、隐私说明与诊断导出', 'privacy', 'settings-section-privacy')
        this.category('关于页灯', '版本、身份、许可与第三方声明', 'about', 'settings-section-about')
      }.width('100%').backgroundColor(this.color('surface')).borderRadius(SETTINGS_GROUP_RADIUS_VP)
    }.id(SETTINGS_CATEGORIES_ID).scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).width('100%').height('100%').align(Alignment.TopStart)
  }
  @Builder private rootCategories() {
    List({ space: 12 }) {
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() { this.category('显示', '界面显示', 'appearance', 'settings-section-appearance', true) }
        ListItem() { this.category('阅读偏好', 'EPUB/TXT排版、配色与辅助按钮', 'reading', 'settings-section-reading', true) }
        ListItem() { this.category('本地词典', '随包词典与离线单词查询', 'dictionary', 'settings-section-dictionary', true) }
      }.backgroundColor(this.color('surface'))
        .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 48, endMargin: 16 })
      ListItemGroup({ style: ListItemGroupStyle.CARD }) {
        ListItem() { this.category('隐私与数据', '本地保存、隐私说明与诊断导出', 'privacy', 'settings-section-privacy', true) }
        ListItem() { this.category('关于页灯', '版本、身份、许可与第三方声明', 'about', 'settings-section-about', true) }
      }.backgroundColor(this.color('surface'))
        .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 48, endMargin: 16 })
    }.id(SETTINGS_CATEGORIES_ID).scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).width('100%').height('100%').padding({ top: 8, bottom: 16 })
  }
  @Builder private selectRow(title: string, options: string[], selected: () => number, id: string, choose: (index: number) => void) {
    Row({ space: 12 }) {
      Text(title).fontSize(16).fontColor(this.color('text')).layoutWeight(1)
      // Read confirmed state inside the builder rather than capturing a stale
      // by-value index when an outer WithTheme updates the native control.
      Select(options.map((value: string): SelectOption => { return { value: value }; }))
        .id(id).selected(selected()).value(options[selected()]).font({ size: 15, weight: FontWeight.Regular })
        .fontColor(this.color('secondary')).backgroundColor(Color.Transparent)
        .selectedOptionFontColor(this.color('accent')).selectedOptionBgColor(this.color('accentContainer'))
        .attributeModifier(new NativeSelectMenuMaterial(this.menuMaterial))
        .constraintSize({ minHeight: 48 }).width(140).accessibilityText(title).onSelect(choose)
    }.width('100%').padding({ top: 8, bottom: 8, left: 16, right: 16 }).constraintSize({ minHeight: 64 })
  }
  @Builder private sliderRow(title: string, value: () => number, min: number, max: number,
    step: number, decimals: number, id: string, choose: (value: number, commit: boolean) => void) {
    Column() {
      Row({ space: 12 }) {
        Text(title).fontSize(16).fontColor(this.color('text')).layoutWeight(1)
        Text(value().toString().indexOf('.') >= 0 ? value().toString() : value().toFixed(decimals))
          .id(id + '-value').fontSize(14).fontColor(this.color('secondary'))
      }.width('100%')
      Slider({ value: value(), min: min, max: max, step: step, style: SliderStyle.OutSet })
        .id(id).width('100%').height(48).accessibilityText(title)
        .onChange((next: number, mode: SliderChangeMode): void => {
          choose(next, mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
        })
    }.width('100%').padding({ top: 12, bottom: 4, left: 16, right: 16 }).constraintSize({ minHeight: 84 })
      .alignItems(HorizontalAlign.Start)
  }
  @Builder private toggleRow(title: string, body: string, enabled: boolean, id: string, hide: boolean) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontColor(this.color('text')).width('100%')
        Text(body).fontSize($r('app.float.product_caption_size')).fontColor(this.color('secondary')).width('100%')
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      ForEach([this.confirmedControlRevision], (revision: number): void => {
        Toggle({ type: ToggleType.Switch, isOn: enabled }).id(id).width(64).height(48)
          .accessibilityText(title).onChange((next: boolean): void => {
            if (revision === this.confirmedControlRevision) this.setControls(next, hide);
          }).onAppear((): void => this.restoreFocus(id))
      }, (revision: number): string => id + '-' + revision)
    }.id(id + '-row').width('100%').padding({ top: 12, bottom: 12, left: 16, right: 16 })
      .constraintSize({ minHeight: 76 })
  }
  @Builder private appearancePage() {
    Column() {
      this.settingsDetailHeader('显示')
      List({ space: 12 }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            this.selectRow('界面显示', ['跟随系统', '浅色', '深色'], (): number => ['system','light','dark'].indexOf(this.interfaceMode),
              'settings-interface-mode', (index: number): void => this.setInterfaceMode(index === 1 ? 'light' : index === 2 ? 'dark' : 'system'))
          }
        }.backgroundColor(this.color('surface'))
        ListItem() {
          Text('阅读配色可在「阅读偏好」中单独设置。').fontSize(13).fontColor(this.color('secondary'))
            .width('100%').padding({ left: 16, right: 16 })
        }
      }.id('settings-appearance-list').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).layoutWeight(1).width('100%').padding({ top: 8, bottom: 16 })
    }.id('settings-appearance').width('100%').height('100%')
  }
  @Builder private readingPage() {
    Column() {
      this.settingsDetailHeader('阅读偏好')
      List({ space: 12 }) {
        ListItem() {
          Text('默认排版 · 适用于未单独调整的图书。阅读配色单独设置。').fontSize(13).fontColor(this.color('secondary'))
            .width('100%').padding({ left: 16, right: 16, top: 4, bottom: 4 })
        }
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            this.sliderRow('字号', (): number => this.layout.fontScale, 0.8, 1.6, 0.05, 2, 'settings-font-scale',
              (value: number, commit: boolean): void => this.setLayout(value, this.layout.lineSpacing, this.layout.pageMarginVp, this.layout.columnMode, commit))
          }
          ListItem() {
            this.sliderRow('行距', (): number => this.layout.lineSpacing, 1.2, 2.0, 0.1, 1, 'settings-line-spacing',
              (value: number, commit: boolean): void => this.setLayout(this.layout.fontScale, value, this.layout.pageMarginVp, this.layout.columnMode, commit))
          }
          ListItem() {
            this.sliderRow('左右留白', (): number => this.layout.pageMarginVp, 8, 40, 1, 0, 'settings-page-margin',
              (value: number, commit: boolean): void => this.setLayout(this.layout.fontScale, this.layout.lineSpacing, value, this.layout.columnMode, commit))
          }
          ListItem() {
            this.selectRow('分栏', ['自动', '单栏'], (): number => this.layout.columnMode === 'single' ? 1 : 0, 'reader-column-mode',
              (index: number): void => this.setLayout(this.layout.fontScale, this.layout.lineSpacing, this.layout.pageMarginVp, index === 1 ? 'single' : 'auto'))
          }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            this.selectRow('阅读配色', ['跟随系统', '浅色', '深色', '护眼'], (): number => ['system','light','dark','eye-comfort'].indexOf(this.readerTheme),
              'settings-reader-theme', (index: number): void => this.setReaderTheme(index === 1 ? 'light' : index === 2 ? 'dark' : index === 3 ? 'eye-comfort' : 'system'))
          }
        }.backgroundColor(this.color('surface'))
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            this.toggleRow('显示阅读控制按钮', '在正文上显示唤出控制的按钮。', this.showControlsButton, 'reader-show-controls-setting', false)
          }
          ListItem() {
            this.toggleRow('显示隐藏控制按钮', '在工具栏上显示隐藏按钮。', this.hideControlsButton, 'reader-hide-controls-setting', true)
          }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
      }.id('settings-reading-scroll').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).layoutWeight(1).width('100%').padding({ top: 8, bottom: 16 })
    }.id('settings-reading').width('100%').height('100%')
  }
  @Builder private dictionaryPage() {
    Column() {
      this.settingsDetailHeader('本地词典')
      List({ space: 12 }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() { this.infoCard('内置词典', this.dictionaryInfo) }
        }.backgroundColor(this.color('surface'))
        ListItem() {
          this.infoCard('离线单词查询', '阅读时选中一个英文单词，即可查看释义。未收录的单词会提示未找到。')
        }
      }.id('settings-dictionary-list').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).layoutWeight(1).width('100%').padding({ top: 8, bottom: 16 })
    }.id('settings-dictionary').width('100%').height('100%')
  }
  @Builder private action(title: Resource, id: string, callback: () => void, external: boolean = false) {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        Text(title).fontSize(16).fontColor(this.color('text')).layoutWeight(1).textAlign(TextAlign.Start)
        SymbolGlyph(external ? $r('sys.symbol.arrow_up_right') : $r('sys.symbol.chevron_right'))
          .fontSize(external ? 16 : 12).fontColor([this.color('secondary')])
      }.width('100%').padding({ top: 12, bottom: 12 })
    }.id(id).width('100%').constraintSize({ minHeight: 64 }).padding({ left: 16, right: 16 })
      .backgroundColor(Color.Transparent).accessibilityText(title)
      .onClick(callback).onAppear((): void => this.restoreFocus(id))
  }
  @Builder private privacyPage() {
    Column() {
      this.settingsDetailHeader('隐私与数据')
      List({ space: 12 }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() { this.infoCard($r('app.string.privacy_books_title'), $r('app.string.privacy_books_body')) }
          ListItem() {
            this.action($r('app.string.privacy_policy_local_link'), 'settings-privacy-policy-local', (): void => this.openRoute('privacy-policy'))
          }
          ListItem() {
            this.action($r('app.string.privacy_policy_link'), 'settings-privacy-policy-link', (): void => this.openPrivacyPolicy(), true)
          }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() { this.infoCard($r('app.string.diagnostic_export_title'), $r('app.string.diagnostic_export_body')) }
          ListItem() {
            Button({ type: ButtonType.Normal }) {
              Row({ space: 12 }) {
                Text(this.diagnosticExporting ? $r('app.string.diagnostic_exporting') : $r('app.string.diagnostic_export_action'))
                  .fontSize(16).fontColor(this.color('accent')).layoutWeight(1).textAlign(TextAlign.Start)
                if (this.diagnosticExporting) { LoadingProgress().width(20).height(20) }
              }.width('100%').padding({ top: 12, bottom: 12 })
            }.id('settings-diagnostic-export').width('100%').constraintSize({ minHeight: 64 })
            .padding({ left: 16, right: 16 }).backgroundColor(Color.Transparent).enabled(!this.diagnosticExporting)
            .onClick((): void => { this.exportDiagnostics().catch((): void => {}); })
          }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
        if (this.diagnosticExportStatus !== undefined) {
          ListItem() {
            Text(this.diagnosticExportStatus === 'saved' ? $r('app.string.diagnostic_export_saved') :
              this.diagnosticExportStatus === 'cancelled' ? $r('app.string.diagnostic_export_cancelled') :
                this.diagnosticExportStatus === 'failed-partial-possible' ? $r('app.string.diagnostic_export_partial') : $r('app.string.diagnostic_export_failed'))
              .id('settings-diagnostic-status').fontSize(14)
              .fontColor(this.color(this.diagnosticExportStatus === 'failed' || this.diagnosticExportStatus === 'failed-partial-possible' ? 'error' : 'secondary'))
              .lineSpacing(LengthMetrics.vp(4)).width('100%').padding({ left: 16, right: 16 })
          }
        }
      }.id('settings-privacy-list').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).layoutWeight(1).width('100%').padding({ top: 8, bottom: 16 })
    }.id('settings-privacy').width('100%').height('100%')
  }
  @Builder private aboutPage() {
    Column() {
      this.settingsDetailHeader('关于页灯')
      List({ space: 12 }) {
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() { this.infoCard($r('app.string.legal_development_identity_title'), $r('app.string.legal_development_identity_body')) }
          ListItem() { this.infoCard('版本', this.versionInfo) }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
        ListItemGroup({ style: ListItemGroupStyle.CARD }) {
          ListItem() {
            this.action($r('app.string.legal_project_license'), 'settings-project-license', (): void => this.openRoute('project-license'))
          }
          ListItem() {
            this.action($r('app.string.legal_third_party_notices'), 'settings-third-party-notices', (): void => this.openRoute('third-party-notices'))
          }
        }.backgroundColor(this.color('surface'))
          .divider({ strokeWidth: 0.5, color: this.color('divider'), startMargin: 16, endMargin: 16 })
      }.id('settings-about-list').scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor()).layoutWeight(1).width('100%').padding({ top: 8, bottom: 16 })
    }.id('settings-about').width('100%').height('100%')
  }
  @Builder private legalPage(title: ResourceStr, id: string) {
    Column() {
      this.settingsDetailHeader(title)
      if (this.legalLoading) { LoadingProgress().width(32).height(32) }
      else {
        Scroll() {
          Text(this.legalText).id('settings-legal-text').fontSize(14).fontColor(this.color('text')).lineSpacing(LengthMetrics.vp(4))
            .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 16 })
        }.layoutWeight(1).width('100%').align(Alignment.TopStart)
          .scrollBar(BarState.Auto).scrollBarWidth(2).scrollBarColor(this.scrollIndicatorColor())
      }
    }.id(id).width('100%').height('100%')
  }
  @Builder private detail() {
    if (this.route === 'root' || this.route === 'appearance') { this.appearancePage() }
    else if (this.route === 'reading') { this.readingPage() }
    else if (this.route === 'dictionary') { this.dictionaryPage() }
    else if (this.route === 'privacy') { this.privacyPage() }
    else if (this.route === 'about') { this.aboutPage() }
    else if (this.route === 'privacy-policy') { this.legalPage($r('app.string.privacy_policy_title'), 'settings-privacy-policy-page') }
    else if (this.route === 'project-license') { this.legalPage($r('app.string.legal_project_license'), 'settings-project-license-page') }
    else { this.legalPage($r('app.string.legal_third_party_notices'), 'settings-third-party-notices-page') }
  }
  build() {
    Column({ space: 12 }) {
      if (this.wide()) {
        this.header('设置', '', true)
        Row({ space: 16 }) {
          Column() { this.categories() }.width(240).height('100%')
          Divider().vertical(true).height('100%').color(this.color('divider'))
          Column() { this.detail() }.layoutWeight(1).constraintSize({ maxWidth: 640 }).height('100%')
        }.layoutWeight(1).width('100%')
      } else {
        Stack() {
          if (this.route === 'root') {
            Column({ space: 12 }) {
              this.rootHeader()
              Column() { this.rootCategories() }.layoutWeight(1).width('100%')
            }.width('100%').height('100%').transition(TransitionEffect.OPACITY)
          } else {
            Column() { this.detail() }.width('100%').height('100%')
              .transition(nonReadingPageTransition(this.reducedMotion))
          }
        }.layoutWeight(1).width('100%').clip(true)
      }
      if (this.status.length > 0) { Text(this.status).id('settings-save-status').fontSize(14).fontColor(this.color('text')).width('100%') }
    }.id('settings-root').width('100%').height('100%')
      .padding({ left: this.windowSnapshot.safeInsets.left + 16, right: this.windowSnapshot.safeInsets.right + 16,
        top: this.windowSnapshot.safeInsets.top + 12, bottom: this.windowSnapshot.safeInsets.bottom + 12 })
      .backgroundColor(this.renderBackground ? this.color('canvas') : Color.Transparent)
      .onKeyEvent((event: KeyEvent): boolean => {
        if (event.keyCode === KeyCode.KEYCODE_ESCAPE) {
          event.stopPropagation();
          if (event.type === KeyType.Down) this.backOrExit();
          return true;
        }
        return false;
      })
  }
}
