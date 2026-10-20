// Presentation only. Index owns consent persistence, policy loading and exit behavior.
@Component
export struct PrivacyNotice {
  @Prop status: string = 'checking';
  @Prop showingFullPolicy: boolean = false;
  @Prop policyText: string = '';
  @Prop error: string = '';
  onAccept: () => void = (): void => {};
  onDecline: () => void = (): void => {};
  onReadPolicy: () => void = (): void => {};
  onBackToNotice: () => void = (): void => {};

  build() {
    Column() {
      if (this.showingFullPolicy) {
        Column({ space: 16 }) {
          Text('页灯隐私政策').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.product_text_primary')).width('100%')
          Scroll() {
            Text(this.policyText).fontSize(16).lineHeight(25)
              .fontColor($r('app.color.product_text_primary')).width('100%')
          }.id('privacy-full-policy').layoutWeight(1).width('100%')
          Button('返回隐私提示').id('privacy-policy-back').height($r('app.float.product_target_min'))
            .width('100%').buttonStyle(ButtonStyleMode.NORMAL)
            .fontColor($r('app.color.product_text_primary'))
            .backgroundColor($r('app.color.product_surface_muted'))
            .onClick((): void => { this.onBackToNotice(); })
        }.id('privacy-policy-dialog').width('90%').height('84%').constraintSize({ maxWidth: 600 })
          .padding(24).backgroundColor($r('app.color.product_surface')).borderRadius(20)
      } else {
        Column({ space: 16 }) {
          Text('隐私与本地阅读').fontSize(20).fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.product_text_primary')).width('100%')
          if (this.status === 'checking') {
            LoadingProgress().width(36).height(36).color($r('app.color.product_accent'))
            Text('正在准备隐私政策…').fontSize(16)
              .fontColor($r('app.color.product_text_secondary')).width('100%')
          } else if (this.status === 'unavailable') {
            Text('无法读取随应用提供的隐私政策，请退出后重试。').fontSize(16)
              .fontColor($r('app.color.product_error')).width('100%')
            Button('退出应用').id('privacy-exit').height($r('app.float.product_target_min'))
              .width('100%').buttonStyle(ButtonStyleMode.NORMAL)
              .onClick((): void => this.onDecline())
          } else {
            Text('页灯会在本机保存你导入的 EPUB 与 TXT、阅读进度、书签、划线和笔记；基础英汉查词在设备上完成。当前版本不申请互联网权限，不会自动上传书籍或阅读记录。')
              .fontSize(16).lineHeight(25).fontColor($r('app.color.product_text_primary')).width('100%')
            Text('你可以删除应用内书籍，原始文件仍保留在你选择的位置。请先阅读完整政策，再决定是否继续使用。')
              .fontSize(16).lineHeight(25).fontColor($r('app.color.product_text_secondary')).width('100%')
            Button('阅读完整隐私政策（离线）').id('privacy-read-policy')
              .height($r('app.float.product_target_min')).width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontColor($r('app.color.product_accent'))
              .onClick((): void => { this.onReadPolicy(); })
            if (this.error.length > 0) {
              Text(this.error).fontSize(14).fontColor($r('app.color.product_error')).width('100%')
            }
            Button('同意并开始使用').id('privacy-accept').height($r('app.float.product_target_min'))
              .width('100%').buttonStyle(ButtonStyleMode.EMPHASIZED)
              .fontColor($r('app.color.product_on_accent'))
              .backgroundColor($r('app.color.product_accent'))
              .onClick((): void => this.onAccept())
            Button('不同意并退出').id('privacy-decline').height($r('app.float.product_target_min'))
              .width('100%').buttonStyle(ButtonStyleMode.TEXTUAL)
              .fontColor($r('app.color.product_text_primary'))
              .onClick((): void => this.onDecline())
          }
        }.id('privacy-consent-dialog').width('90%').constraintSize({ maxWidth: 520, maxHeight: '90%' })
          .padding(24).backgroundColor($r('app.color.product_surface')).borderRadius(20)
      }
    }.width('100%').height('100%').justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
      .backgroundColor($r('app.color.product_canvas'))
  }
}
