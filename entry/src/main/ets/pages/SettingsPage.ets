import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { DiagnosticExportAction, DiagnosticExportStatus } from '../application/DiagnosticExportApplication';
import { ReaderAppearanceApplication } from '../application/ReaderAppearanceApplication';
import { ProductTopBar } from '../components/ProductTopBar';
import { BookshelfBackground } from '../components/BookshelfBackground';
import { SettingsSectionCard } from '../components/SettingsSectionCard';
import { ReaderColumnMode, ReaderSettings } from '../domain/Models';
import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfColor, bookshelfOuterText } from '../layout/BookshelfThemePalette';
import { ReaderMotionPreference } from '../domain/AppearancePolicy';
import {
  AdaptiveWindowSnapshot,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT,
  SETTINGS_CONTENT_MAX_WIDTH_VP,
  adaptivePageInsetVp
} from '../layout/AdaptiveLayoutPolicy';

const PRIVACY_POLICY_URL: string = 'https://litepage.cn/s/yedeng/yedeng-privacy-policy';

export type SettingsRoute = 'root' | 'appearance' | 'reading' | 'privacy' | 'privacy-policy' | 'about' |
  'project-license' | 'third-party-notices';

export class SettingsPageController {
  private systemBackHandler?: () => boolean;
  private resetHandler?: () => void;

  bind(systemBackHandler: () => boolean, resetHandler: () => void): void {
    this.systemBackHandler = systemBackHandler;
    this.resetHandler = resetHandler;
  }

  unbind(): void {
    this.systemBackHandler = undefined;
    this.resetHandler = undefined;
  }

  handleSystemBack(): boolean {
    return this.systemBackHandler?.() ?? false;
  }

  resetToRoot(): void {
    this.resetHandler?.();
  }
}

@Component
export struct SettingsPage {
  readerAppearance?: ReaderAppearanceApplication;
  diagnosticExport?: DiagnosticExportAction;
  @Prop bookshelfTheme: BookshelfTheme = 'default';
  @Prop bookshelfDefaultMode: BookshelfDefaultMode = 'system';
  @Prop renderBackground: boolean = true;
  onThemeApplied: (theme: BookshelfTheme, mode: BookshelfDefaultMode) => boolean =
    (_theme: BookshelfTheme, _mode: BookshelfDefaultMode): boolean => false;
  @Prop windowSnapshot: AdaptiveWindowSnapshot = DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT;
  pageController: SettingsPageController = new SettingsPageController();
  onExit: () => void = (): void => {};

  @State private route: SettingsRoute = 'root';
  @State private previewTheme: BookshelfTheme = 'default';
  @State private previewMode: BookshelfDefaultMode = 'system';
  @State private legalText: string = '';
  @State private legalLoading: boolean = false;
  @State private columnMode: ReaderColumnMode = 'auto';
  @State private motionPreference: ReaderMotionPreference = 'system';
  @State private diagnosticExporting: boolean = false;
  @State private diagnosticExportStatus: DiagnosticExportStatus | undefined = undefined;

  aboutToAppear(): void {
    this.previewTheme = this.bookshelfTheme;
    this.previewMode = this.bookshelfDefaultMode;
    this.columnMode = this.readerAppearance?.loadSettings().columnMode ?? 'auto';
    this.motionPreference = this.readerAppearance?.motionPreference() ?? 'system';
    this.pageController.bind((): boolean => this.handleSystemBack(), (): void => this.resetToRoot());
  }

  aboutToDisappear(): void {
    this.pageController.unbind();
  }

  private resetToRoot(): void {
    this.route = 'root';
    this.legalText = '';
    this.legalLoading = false;
  }

  private pageInsetVp(): number {
    return adaptivePageInsetVp(this.windowSnapshot.sizeClass);
  }

  private displayTheme(): BookshelfTheme {
    return this.route === 'appearance' ? this.previewTheme : this.bookshelfTheme;
  }

  private displayMode(): BookshelfDefaultMode {
    return this.route === 'appearance' ? this.previewMode : this.bookshelfDefaultMode;
  }

  private applyTheme(theme: BookshelfTheme, mode: BookshelfDefaultMode): void {
    if (this.onThemeApplied(theme, mode)) {
      this.previewTheme = theme;
      this.previewMode = mode;
      try { this.getUIContext().getPromptAction().showToast({ message: '主题已应用' }); } catch (_) {}
    } else {
      try { this.getUIContext().getPromptAction().showToast({ message: '主题保存失败，请重试' }); } catch (_) {}
    }
  }

  private setColumnMode(mode: ReaderColumnMode): void {
    const current = this.readerAppearance?.loadSettings();
    if (current === undefined || current.columnMode === mode) return;
    const next: ReaderSettings = {
      fontScale: current.fontScale,
      lineSpacing: current.lineSpacing,
      pageMarginVp: current.pageMarginVp,
      theme: current.theme,
      columnMode: mode
    };
    this.columnMode = mode;
    this.readerAppearance?.saveLayoutDefaults(next);
  }

  private setMotionPreference(preference: ReaderMotionPreference): void {
    if (this.motionPreference === preference) return;
    this.readerAppearance?.saveMotionPreference(preference);
    this.motionPreference = preference;
  }

  private async exportDiagnostics(): Promise<void> {
    if (this.diagnosticExporting) return;
    this.diagnosticExportStatus = undefined;
    this.diagnosticExporting = true;
    let status: DiagnosticExportStatus = 'failed';
    try { status = await this.diagnosticExport?.export() ?? 'failed'; }
    finally { this.diagnosticExporting = false; }
    this.diagnosticExportStatus = status;
    const message = status === 'saved' ? $r('app.string.diagnostic_export_saved') :
      status === 'cancelled' ? $r('app.string.diagnostic_export_cancelled') :
        status === 'failed-partial-possible' ? $r('app.string.diagnostic_export_partial') :
          $r('app.string.diagnostic_export_failed');
    try { this.getUIContext().getPromptAction().showToast({ message: message }); }
    catch (_) {}
  }

  private openPrivacyPolicy(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(PRIVACY_POLICY_URL).catch((): void => {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.privacy_policy_open_failed') });
    });
  }

  private themeName(theme: BookshelfTheme): string {
    if (theme === 'starry') return '星月夜';
    if (theme === 'fan-kuan') return '谿山行旅图';
    if (theme === 'earthrise') return '地出';
    return '页灯';
  }

  private modeName(mode: BookshelfDefaultMode): string {
    if (mode === 'light') return '浅色';
    if (mode === 'dark') return '深色';
    return '跟随系统';
  }

  private themeSource(theme: BookshelfTheme): string {
    if (theme === 'starry') return '文森特·梵高《星月夜》；图像来源：Wikimedia Commons。';
    if (theme === 'fan-kuan') return '范宽《谿山行旅图》；原作参考：台北故宫。背景两侧为 AI 设计延展。';
    if (theme === 'earthrise') return 'NASA / Bill Anders《地出》；地球上移的设计合成，非原始纪实照片。';
    return '页灯原有配色；可跟随系统，或固定为浅色与深色。';
  }

  private themeNote(theme: BookshelfTheme): string {
    if (theme === 'starry') return '深蓝夜空与柔金色点缀。';
    if (theme === 'fan-kuan') return '墨色山水与绢纸留白。';
    if (theme === 'earthrise') return '深空与浅青色点缀。';
    return '书库与设置可跟随系统或固定深浅色；书内阅读外观仍可单独设置。';
  }

  private themeSourceUrl(theme: BookshelfTheme): string {
    if (theme === 'starry') return 'https://commons.wikimedia.org/wiki/File:Vincent_van_Gogh_Starry_Night.jpg';
    if (theme === 'fan-kuan') return 'https://digitalarchive.npm.gov.tw/Collection/Detail/1195?dep=P';
    if (theme === 'earthrise') return 'https://science.nasa.gov/resource/image-earthrise/';
    return '';
  }

  private openThemeSource(): void {
    const url = this.themeSourceUrl(this.previewTheme);
    if (url.length === 0) return;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    context.openLink(url).catch((): void => {
      try { this.getUIContext().getPromptAction().showToast({ message: '无法打开作品来源' }); } catch (_) {}
    });
  }

  private handleSystemBack(): boolean {
    if (this.route === 'privacy-policy') {
      this.route = 'privacy';
      this.legalText = '';
      return true;
    }
    if (this.route === 'project-license' || this.route === 'third-party-notices') {
      this.route = 'about';
      this.legalText = '';
      return true;
    }
    if (this.route !== 'root') {
      this.route = 'root';
      return true;
    }
    return false;
  }

  private backOrExit(): void {
    if (!this.handleSystemBack()) this.onExit();
  }

  private openRoute(route: SettingsRoute): void {
    if (route === 'appearance') {
      this.previewTheme = this.bookshelfTheme;
      this.previewMode = this.bookshelfDefaultMode;
    }
    this.route = route;
    if (route === 'project-license') this.loadProjectLegal().catch((): void => {});
    if (route === 'privacy-policy') {
      this.loadLegalFile('privacy/yedeng-privacy-policy.txt').catch((): void => {});
    }
    if (route === 'third-party-notices') {
      this.loadLegalFile('legal/THIRD_PARTY_NOTICES.md').catch((): void => {});
    }
  }

  private async rawText(path: string): Promise<string> {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = await context.resourceManager.getRawFileContent(path);
      return new util.TextDecoder('utf-8').decodeToString(bytes);
    } catch (_) {
      return '';
    }
  }

  private resourceText(resource: Resource): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return context.resourceManager.getStringSync(resource.id);
    } catch (_) {
      return '';
    }
  }

  private async loadProjectLegal(): Promise<void> {
    this.legalLoading = true;
    this.legalText = '';
    try {
      const license = await this.rawText('legal/LICENSE');
      const notice = await this.rawText('legal/NOTICE');
      if (license.length === 0 || notice.length === 0) throw new Error('Local legal resource is unavailable');
      this.legalText = `${license}\n\n${this.resourceText($r('app.string.legal_notice_heading'))}\n\n${notice}`;
    } catch (_) {
      this.legalText = this.resourceText($r('app.string.legal_project_load_error'));
    } finally {
      this.legalLoading = false;
    }
  }

  private async loadLegalFile(path: string): Promise<void> {
    this.legalLoading = true;
    this.legalText = '';
    try {
      const content = await this.rawText(path);
      if (content.length === 0) throw new Error('Local legal resource is unavailable');
      this.legalText = path.startsWith('privacy/') ? content.substring(content.indexOf('\n') + 1).trimStart() : content;
    } catch (_) {
      this.legalText = this.resourceText($r('app.string.legal_notices_load_error'));
    } finally {
      this.legalLoading = false;
    }
  }

  @Builder
  private sectionTitle(title: ResourceStr, subtitle: ResourceStr) {
    ProductTopBar({ title: title, subtitle: subtitle, showBack: true, backId: 'settings-back',
      bookshelfTheme: this.displayTheme(),
      bookshelfDefaultMode: this.displayMode(),
      onBack: (): void => this.backOrExit() })
  }

  @Builder
  private infoCard(title: ResourceStr, body: ResourceStr) {
    Column({ space: $r('app.float.product_space_8') }) {
      Text(title).fontSize($r('app.float.product_body_size')).fontWeight(FontWeight.Medium)
        .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).width('100%')
      Text(body).fontSize($r('app.float.product_body_small_size'))
        .fontColor(bookshelfColor(this.displayTheme(), 'secondary', this.displayMode())).width('100%')
    }
    .width('100%').padding({ top: $r('app.float.product_space_16'),
      bottom: $r('app.float.product_space_16') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private readerColumnModeCard() {
    Column({ space: $r('app.float.product_space_12') }) {
      Text($r('app.string.reader_column_mode')).fontSize($r('app.float.product_body_size'))
        .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).width('100%')
      Row({ space: $r('app.float.product_space_8') }) {
        Button($r('app.string.reader_column_mode_auto')).id('reader-column-mode-auto')
          .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
          .fontWeight(this.columnMode === 'auto' ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.columnMode === 'auto' ? bookshelfColor(this.displayTheme(), 'onAccent', this.displayMode()) :
            bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
          .backgroundColor(this.columnMode === 'auto' ? bookshelfColor(this.displayTheme(), 'accent', this.displayMode()) :
            bookshelfColor(this.displayTheme(), 'muted', this.displayMode()))
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilitySelected(this.columnMode === 'auto')
          .onClick((): void => this.setColumnMode('auto'))
        Button($r('app.string.reader_column_mode_single')).id('reader-column-mode-single')
          .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
          .fontWeight(this.columnMode === 'single' ? FontWeight.Bold : FontWeight.Medium)
          .fontColor(this.columnMode === 'single' ? bookshelfColor(this.displayTheme(), 'onAccent', this.displayMode()) :
            bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
          .backgroundColor(this.columnMode === 'single' ? bookshelfColor(this.displayTheme(), 'accent', this.displayMode()) :
            bookshelfColor(this.displayTheme(), 'muted', this.displayMode()))
          .borderRadius($r('app.float.product_radius_control'))
          .accessibilitySelected(this.columnMode === 'single')
          .onClick((): void => this.setColumnMode('single'))
      }.width('100%')
    }
    .id('reader-column-mode').width('100%').padding({ top: $r('app.float.product_space_16'),
      bottom: $r('app.float.product_space_16') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private motionChoice(preference: ReaderMotionPreference, label: ResourceStr, controlId: string) {
    Button(label).id(controlId)
      .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
      .fontSize($r('app.float.product_body_small_size'))
      .fontWeight(this.motionPreference === preference ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.motionPreference === preference ? bookshelfColor(this.displayTheme(), 'onAccent', this.displayMode()) :
        bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
      .backgroundColor(this.motionPreference === preference ? bookshelfColor(this.displayTheme(), 'accent', this.displayMode()) :
        bookshelfColor(this.displayTheme(), 'muted', this.displayMode()))
      .borderRadius($r('app.float.product_radius_control'))
      .accessibilitySelected(this.motionPreference === preference)
      .onClick((): void => this.setMotionPreference(preference))
  }

  @Builder
  private readerMotionCard() {
    Column({ space: $r('app.float.product_space_12') }) {
      Text($r('app.string.reader_motion_title')).fontSize($r('app.float.product_body_size'))
        .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).width('100%')
      if (this.windowSnapshot.sizeClass === 'compact') {
        Column({ space: $r('app.float.product_space_8') }) {
          Row({ space: $r('app.float.product_space_8') }) {
            this.motionChoice('system', $r('app.string.reader_motion_system'), 'reader-motion-system')
            this.motionChoice('enabled', $r('app.string.reader_motion_enabled'), 'reader-motion-enabled')
          }.width('100%')
          Row() {
            this.motionChoice('reduced', $r('app.string.reader_motion_reduced'), 'reader-motion-reduced')
          }.width('100%')
        }.width('100%')
      } else {
        Row({ space: $r('app.float.product_space_8') }) {
          this.motionChoice('system', $r('app.string.reader_motion_system'), 'reader-motion-system')
          this.motionChoice('enabled', $r('app.string.reader_motion_enabled'), 'reader-motion-enabled')
          this.motionChoice('reduced', $r('app.string.reader_motion_reduced'), 'reader-motion-reduced')
        }.width('100%')
      }
    }
    .id('reader-motion').width('100%').padding({ top: $r('app.float.product_space_16'),
      bottom: $r('app.float.product_space_16') })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private themeChoice(theme: BookshelfTheme, byline: string) {
    Button() {
      Row({ space: $r('app.float.product_space_12') }) {
        BookshelfBackground({ theme: theme, defaultMode: this.previewMode }).width(56).height(48)
          .borderRadius($r('app.float.product_radius_control')).clip(true)
        Column({ space: $r('app.float.product_space_4') }) {
          Text(this.themeName(theme)).fontSize($r('app.float.product_body_size'))
            .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
          Text(byline).fontSize($r('app.float.product_caption_size'))
            .fontColor(bookshelfColor(this.displayTheme(), 'secondary', this.displayMode()))
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.previewTheme === theme ? '预览中' : '预览')
          .fontSize($r('app.float.product_caption_size'))
          .fontColor(this.previewTheme === theme ? bookshelfColor(this.displayTheme(), 'accent', this.displayMode()) :
            bookshelfColor(this.displayTheme(), 'secondary', this.displayMode()))
      }.width('100%').padding({ top: $r('app.float.product_space_8'),
        bottom: $r('app.float.product_space_8') })
    }
    .id(`appearance-choice-${theme}`).width('100%').height('auto').type(ButtonType.Normal)
    .backgroundColor(this.previewTheme === theme ? bookshelfColor(this.displayTheme(), 'muted', this.displayMode()) : Color.Transparent)
    .borderRadius($r('app.float.product_radius_control'))
    .accessibilityText(`预览${this.themeName(theme)}`)
    .accessibilitySelected(this.previewTheme === theme)
    .onClick((): void => { this.previewTheme = theme; })
  }

  @Builder
  private defaultModeChoice(mode: BookshelfDefaultMode, label: string) {
    Button(label).id(`appearance-default-${mode}`)
      .height($r('app.float.product_target_min')).layoutWeight(1).type(ButtonType.Normal)
      .fontSize($r('app.float.product_body_small_size'))
      .fontWeight(this.previewMode === mode ? FontWeight.Bold : FontWeight.Medium)
      .fontColor(this.previewMode === mode ? bookshelfColor('default', 'onAccent', this.previewMode) :
        bookshelfColor('default', 'text', this.previewMode))
      .backgroundColor(this.previewMode === mode ? bookshelfColor('default', 'accent', this.previewMode) :
        bookshelfColor('default', 'muted', this.previewMode))
      .borderRadius($r('app.float.product_radius_control'))
      .accessibilitySelected(this.previewMode === mode)
      .onClick((): void => { this.previewMode = mode; })
  }

  @Builder
  private appearancePage() {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle('书库与设置主题', '背景、配色与作品说明')
      Scroll() {
        Column({ space: $r('app.float.product_space_16') }) {
          Text('「页灯」可跟随系统，也可固定浅色或深色；其余三个艺术主题各使用一套固定配色。书内阅读外观独立。')
            .id('appearance-mode-note').fontSize($r('app.float.product_body_small_size'))
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).width('100%')
            .padding($r('app.float.product_space_16'))
            .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
            .borderRadius($r('app.float.product_radius_card'))

          Column() {
            this.themeChoice('default', '经典配色 · 可选浅色／深色')
            Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
            this.themeChoice('starry', '梵高 · 油画')
            Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
            this.themeChoice('fan-kuan', '范宽 · 水墨山水')
            Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
            this.themeChoice('earthrise', 'NASA / Bill Anders · 摄影合成')
          }.width('100%').padding({ left: $r('app.float.product_space_12'),
            right: $r('app.float.product_space_12') })
            .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
            .borderRadius($r('app.float.product_radius_card'))

          Column({ space: $r('app.float.product_space_8') }) {
            Text(this.themeName(this.previewTheme)).fontSize($r('app.float.product_section_title_size'))
              .fontWeight(FontWeight.Bold).fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
            Text(this.themeNote(this.previewTheme)).fontSize($r('app.float.product_body_small_size'))
              .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
            Text(this.themeSource(this.previewTheme)).fontSize($r('app.float.product_caption_size'))
              .fontColor(bookshelfColor(this.displayTheme(), 'secondary', this.displayMode()))
            if (this.previewTheme === 'default') {
              Text('页灯显示方式').fontSize($r('app.float.product_body_small_size'))
                .fontWeight(FontWeight.Medium).fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
              Row({ space: $r('app.float.product_space_8') }) {
                this.defaultModeChoice('system', '跟随系统')
                this.defaultModeChoice('light', '浅色')
                this.defaultModeChoice('dark', '深色')
              }.id('appearance-default-mode').width('100%')
            }
            if (this.previewTheme !== 'default') {
              Button('查看作品来源').id('appearance-source').height($r('app.float.product_target_min'))
                .fontColor(bookshelfColor(this.displayTheme(), 'accent', this.displayMode()))
                .backgroundColor(Color.Transparent).onClick((): void => this.openThemeSource())
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding($r('app.float.product_space_16'))
            .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
            .borderRadius($r('app.float.product_radius_card'))

          Text(`当前使用：${this.themeName(this.bookshelfTheme)}${this.bookshelfTheme === 'default' ?
            ` · ${this.modeName(this.bookshelfDefaultMode)}` : ''}`)
            .id('appearance-applied').fontSize($r('app.float.product_body_small_size'))
            .fontColor(bookshelfOuterText(this.displayTheme(), false, this.displayMode())).width('100%')
          Button('应用到书库与设置').id('appearance-apply')
            .enabled(this.previewTheme !== this.bookshelfTheme ||
              (this.previewTheme === 'default' && this.previewMode !== this.bookshelfDefaultMode))
            .height($r('app.float.product_target_min')).width('100%')
            .fontColor(bookshelfColor(this.displayTheme(), 'onAccent', this.displayMode()))
            .backgroundColor(bookshelfColor(this.displayTheme(), 'accent', this.displayMode()))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.applyTheme(this.previewTheme, this.previewMode))
          Button('恢复页灯默认设置').id('appearance-reset')
            .enabled(this.bookshelfTheme !== 'default' || this.bookshelfDefaultMode !== 'system')
            .height($r('app.float.product_target_min')).width('100%')
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode()))
            .backgroundColor(bookshelfColor(this.displayTheme(), 'muted', this.displayMode()))
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.applyTheme('default', 'system'))
        }.width('100%').alignItems(HorizontalAlign.Start)
          .padding({ bottom: $r('app.float.product_space_16') })
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.id('settings-appearance').width('100%').height('100%')
  }

  @Builder
  private rootPage() {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle($r('app.string.settings_title'), $r('app.string.settings_subtitle'))
      Scroll() {
        Column() {
          SettingsSectionCard({ title: '书库与设置主题', description: '背景、配色与作品说明',
            symbol: $r('sys.symbol.square_grid_2x2'),
            accessibilityLabel: $r('app.string.settings_appearance_title'),
            controlId: 'settings-section-appearance', bookshelfTheme: this.displayTheme(),
            bookshelfDefaultMode: this.displayMode(),
            onOpen: (): void => this.openRoute('appearance') })
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          SettingsSectionCard({ title: $r('app.string.settings_reading_title'),
            description: $r('app.string.settings_reading_body'), symbol: $r('sys.symbol.list_book'),
            accessibilityLabel: $r('app.string.settings_reading_title'),
            controlId: 'settings-section-reading', bookshelfTheme: this.displayTheme(),
            bookshelfDefaultMode: this.displayMode(),
            onOpen: (): void => this.openRoute('reading') })
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          SettingsSectionCard({ title: $r('app.string.settings_privacy_title'),
            description: $r('app.string.settings_privacy_body'), symbol: $r('sys.symbol.lock'),
            accessibilityLabel: $r('app.string.settings_privacy_title'),
            controlId: 'settings-section-privacy', bookshelfTheme: this.displayTheme(),
            bookshelfDefaultMode: this.displayMode(),
            onOpen: (): void => this.openRoute('privacy') })
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          SettingsSectionCard({ title: $r('app.string.settings_about_title'),
            description: $r('app.string.settings_about_body'), symbol: $r('sys.symbol.info_circle'),
            accessibilityLabel: $r('app.string.settings_about_title'),
            controlId: 'settings-section-about', bookshelfTheme: this.displayTheme(),
            bookshelfDefaultMode: this.displayMode(),
            onOpen: (): void => this.openRoute('about') })
        }.width('100%').padding({ left: $r('app.float.product_space_16'),
          right: $r('app.float.product_space_16') })
          .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
          .border({ width: 1, color: bookshelfColor(this.displayTheme(), 'divider', this.displayMode()) })
          .borderRadius($r('app.float.product_radius_card'))
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.id('settings-root').width('100%').height('100%')
  }

  @Builder
  private readingPage() {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle($r('app.string.settings_reading_title'), $r('app.string.settings_reading_body'))
      Scroll() {
        Column() {
          this.readerColumnModeCard()
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          this.readerMotionCard()
        }.width('100%').padding({ left: $r('app.float.product_space_16'),
          right: $r('app.float.product_space_16') })
          .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
          .border({ width: 1, color: bookshelfColor(this.displayTheme(), 'divider', this.displayMode()) })
          .borderRadius($r('app.float.product_radius_card'))
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.id('settings-reading').width('100%').height('100%')
  }

  @Builder
  private privacyPage() {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle($r('app.string.settings_privacy_title'), $r('app.string.settings_privacy_body'))
      Scroll() {
        Column() {
          Button($r('app.string.privacy_policy_local_link')).id('settings-privacy-policy-local')
            .height($r('app.float.product_target_min')).width('100%').type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.openRoute('privacy-policy'))
          Button($r('app.string.privacy_policy_link')).id('settings-privacy-policy-link')
            .height($r('app.float.product_target_min')).width('100%').type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.product_radius_control'))
            .onClick((): void => this.openPrivacyPolicy())
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          this.infoCard($r('app.string.privacy_books_title'), $r('app.string.privacy_books_body'))
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          Column({ space: $r('app.float.product_space_12') }) {
            this.infoCard($r('app.string.diagnostic_export_title'), $r('app.string.diagnostic_export_body'))
            Button(this.diagnosticExporting ? $r('app.string.diagnostic_exporting') :
              $r('app.string.diagnostic_export_action')).id('settings-diagnostic-export')
              .enabled(!this.diagnosticExporting).height($r('app.float.product_target_min')).width('100%')
              .type(ButtonType.Normal)
              .fontColor(this.diagnosticExporting ? bookshelfColor(this.displayTheme(), 'secondary', this.displayMode()) :
                bookshelfColor(this.displayTheme(), 'onAccent', this.displayMode()))
              .backgroundColor(this.diagnosticExporting ? bookshelfColor(this.displayTheme(), 'muted', this.displayMode()) :
                bookshelfColor(this.displayTheme(), 'accent', this.displayMode()))
              .borderRadius($r('app.float.product_radius_control'))
              .onClick((): void => { this.exportDiagnostics().catch((): void => {}); })
            if (this.diagnosticExportStatus !== undefined) {
              Text(this.diagnosticExportStatus === 'saved' ? $r('app.string.diagnostic_export_saved') :
                this.diagnosticExportStatus === 'cancelled' ? $r('app.string.diagnostic_export_cancelled') :
                  this.diagnosticExportStatus === 'failed-partial-possible' ?
                    $r('app.string.diagnostic_export_partial') : $r('app.string.diagnostic_export_failed'))
                .id('settings-diagnostic-status').fontSize($r('app.float.product_body_small_size'))
                .fontColor(this.diagnosticExportStatus === 'saved' ? bookshelfColor(this.displayTheme(), 'success', this.displayMode()) :
                  this.diagnosticExportStatus === 'cancelled' ? bookshelfColor(this.displayTheme(), 'secondary', this.displayMode()) :
                    this.diagnosticExportStatus === 'failed-partial-possible' ?
                      bookshelfColor(this.displayTheme(), 'warning', this.displayMode()) : bookshelfColor(this.displayTheme(), 'error', this.displayMode()))
                .width('100%')
            }
          }.width('100%').alignItems(HorizontalAlign.Start)
            .padding({ bottom: $r('app.float.product_space_16') })
        }.width('100%').padding({ left: $r('app.float.product_space_16'),
          right: $r('app.float.product_space_16') })
          .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
          .border({ width: 1, color: bookshelfColor(this.displayTheme(), 'divider', this.displayMode()) })
          .borderRadius($r('app.float.product_radius_card'))
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.id('settings-privacy').width('100%').height('100%')
  }

  @Builder
  private aboutPage() {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle($r('app.string.settings_about_title'), $r('app.string.settings_about_body'))
      Scroll() {
        Column() {
          this.infoCard($r('app.string.legal_development_identity_title'),
            $r('app.string.legal_development_identity_body'))
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          Button($r('app.string.legal_project_license')).id('settings-project-license')
            .height($r('app.float.product_target_min')).width('100%').type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.openRoute('project-license'))
          Divider().color(bookshelfColor(this.displayTheme(), 'divider', this.displayMode()))
          Button($r('app.string.legal_third_party_notices')).id('settings-third-party-notices')
            .height($r('app.float.product_target_min')).width('100%').type(ButtonType.Normal)
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).backgroundColor(Color.Transparent)
            .borderRadius($r('app.float.product_radius_control'))
            .onClick(() => this.openRoute('third-party-notices'))
        }.width('100%').padding({ left: $r('app.float.product_space_16'),
          right: $r('app.float.product_space_16'), bottom: $r('app.float.product_space_16') })
          .backgroundColor(bookshelfColor(this.displayTheme(), 'surface', this.displayMode()))
          .border({ width: 1, color: bookshelfColor(this.displayTheme(), 'divider', this.displayMode()) })
          .borderRadius($r('app.float.product_radius_card'))
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.id('settings-about').width('100%').height('100%')
  }

  @Builder
  private legalPage(title: ResourceStr, subtitle: ResourceStr, id: string) {
    Column({ space: $r('app.float.product_space_12') }) {
      this.sectionTitle(title, subtitle)
      if (this.legalLoading) {
        LoadingProgress().width($r('app.float.product_space_32')).height($r('app.float.product_space_32'))
          .color(bookshelfColor(this.displayTheme(), 'accent', this.displayMode()))
      } else {
        Scroll() {
          Text(this.legalText).fontSize($r('app.float.product_caption_size'))
            .fontColor(bookshelfColor(this.displayTheme(), 'text', this.displayMode())).width('100%')
        }.layoutWeight(1).width('100%')
      }
    }.id(id).width('100%').height('100%')
  }

  build() {
    Stack({ alignContent: Alignment.Top }) {
      if (this.renderBackground || this.route === 'appearance') {
        BookshelfBackground({ theme: this.displayTheme(), defaultMode: this.displayMode() })
      }
      Column() {
        if (this.route === 'root') {
          this.rootPage()
        } else if (this.route === 'appearance') {
          this.appearancePage()
        } else if (this.route === 'reading') {
          this.readingPage()
        } else if (this.route === 'privacy') {
          this.privacyPage()
        } else if (this.route === 'privacy-policy') {
          this.legalPage($r('app.string.privacy_policy_title'), $r('app.string.privacy_policy_local_copy'),
            'settings-privacy-policy-page')
        } else if (this.route === 'about') {
          this.aboutPage()
        } else if (this.route === 'project-license') {
          this.legalPage($r('app.string.legal_project_license'), $r('app.string.legal_local_copy'),
            'settings-project-license-page')
        } else {
          this.legalPage($r('app.string.legal_third_party_notices'), $r('app.string.legal_local_copy'),
            'settings-third-party-notices-page')
        }
      }
      .width('100%').height('100%')
      .constraintSize({ maxWidth: SETTINGS_CONTENT_MAX_WIDTH_VP })
      .padding({
        left: this.pageInsetVp(),
        right: this.pageInsetVp(),
        top: this.windowSnapshot.safeInsets.top + 16,
        bottom: this.windowSnapshot.safeInsets.bottom + 16
      })
    }
    .width('100%').height('100%')
    .padding({ left: this.windowSnapshot.safeInsets.left, right: this.windowSnapshot.safeInsets.right })
    .backgroundColor(this.renderBackground || this.route === 'appearance' ?
      bookshelfColor(this.displayTheme(), 'canvas', this.displayMode()) : Color.Transparent)
  }
}
