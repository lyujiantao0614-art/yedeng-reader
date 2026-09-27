import { BookshelfDefaultMode, BookshelfTheme } from '../domain/LibraryPresentation';
import { bookshelfColor } from '../layout/BookshelfThemePalette';

@Component
export struct BookshelfBackground {
  @Prop theme: BookshelfTheme = 'default';
  @Prop defaultMode: BookshelfDefaultMode = 'system';

  build() {
    Stack() {
      if (this.theme === 'starry') {
        Image($r('app.media.theme_starry')).width('100%').height('100%')
          .objectFit(ImageFit.Cover).scale({ x: 1.05, y: 1.05 }).accessibilityLevel('no')
      } else if (this.theme === 'fan-kuan') {
        Image($r('app.media.theme_fan_kuan')).width('100%').height('100%')
          .objectFit(ImageFit.Cover).accessibilityLevel('no')
      } else if (this.theme === 'earthrise') {
        Image($r('app.media.theme_earthrise')).width('100%').height('100%')
          .objectFit(ImageFit.Cover).accessibilityLevel('no')
      }
      if (this.theme === 'starry') {
        Column().width('100%').height('100%').backgroundColor('#66050B15')
      } else if (this.theme === 'earthrise') {
        Column().width('100%').height('100%').backgroundColor('#33050B15')
      } else if (this.theme === 'fan-kuan') {
        Column().width('100%').height('100%').backgroundColor('#22F5F0DF')
      }
    }
    .width('100%').height('100%').backgroundColor(bookshelfColor(this.theme, 'canvas', this.defaultMode))
    .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT],
      [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
