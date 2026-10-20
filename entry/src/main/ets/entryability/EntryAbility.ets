import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { display, window } from '@kit.ArkUI';
import { resourceManager } from '@kit.LocalizationKit';
import { readerSessionService } from '../services/ReaderSessionService';
import { SafeLog } from '../diagnostics/SafeLog';
import { readerApplicationLifecycle } from '../reader/ReaderApplicationLifecycle';
import { systemColorModeLifecycle } from '../reader/SystemColorModeLifecycle';
import {
  RawSafeInsetsPx,
  createAdaptiveWindowSnapshot,
  mergeRawSafeInsets
} from '../layout/AdaptiveLayoutPolicy';
import { adaptiveWindowLifecycle } from '../layout/AdaptiveWindowLifecycle';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private windowWidthPx: number = 390;
  private windowHeightPx: number = 844;
  private densityPixels: number = 1;
  private systemSafeInsetsPx: RawSafeInsetsPx = { top: 0, right: 0, bottom: 0, left: 0 };
  private cutoutSafeInsetsPx: RawSafeInsetsPx = { top: 0, right: 0, bottom: 0, left: 0 };
  private navigationSafeInsetsPx: RawSafeInsetsPx = { top: 0, right: 0, bottom: 0, left: 0 };
  private windowSizeChangeCallback = (size: window.Size): void => {
    this.windowWidthPx = size.width;
    this.windowHeightPx = size.height;
    this.publishAdaptiveWindowSnapshot();
  };
  private avoidAreaChangeCallback = (options: window.AvoidAreaOptions): void => {
    const insets = this.safeInsetsFromAvoidArea(options.area);
    if (options.type === window.AvoidAreaType.TYPE_SYSTEM) {
      this.systemSafeInsetsPx = insets;
    } else if (options.type === window.AvoidAreaType.TYPE_CUTOUT) {
      this.cutoutSafeInsetsPx = insets;
    } else if (options.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      this.navigationSafeInsetsPx = insets;
    } else {
      return;
    }
    this.publishAdaptiveWindowSnapshot();
  };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
      // A UIAbility resource manager may carry a local WithTheme override.
      // The application stays in system mode; read that unscoped source.
      this.publishInitialColorMode(this.context.getApplicationContext().resourceManager.getConfigurationSync().colorMode);
    } catch (_) {
      SafeLog.error('color-mode');
    }
    SafeLog.event('ability-created');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.publishUpdatedColorMode(newConfig.colorMode);
    this.refreshAdaptiveWindowSnapshot();
  }

  private publishInitialColorMode(mode: resourceManager.ColorMode): void {
    systemColorModeLifecycle.handleMode(mode === resourceManager.ColorMode.DARK ? 'dark' : 'light');
  }

  private publishUpdatedColorMode(mode?: ConfigurationConstant.ColorMode): void {
    if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
      systemColorModeLifecycle.handleMode('dark');
    } else if (mode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
      systemColorModeLifecycle.handleMode('light');
    }
  }

  private emptySafeInsets(): RawSafeInsetsPx {
    return { top: 0, right: 0, bottom: 0, left: 0 };
  }

  private safeInsetsFromAvoidArea(area: window.AvoidArea): RawSafeInsetsPx {
    if (!area.visible) return this.emptySafeInsets();
    return {
      top: area.topRect.height,
      right: area.rightRect.width,
      bottom: area.bottomRect.height,
      left: area.leftRect.width
    };
  }

  private readSafeInsets(type: window.AvoidAreaType): RawSafeInsetsPx {
    try {
      return this.mainWindow === undefined ? this.emptySafeInsets() :
        this.safeInsetsFromAvoidArea(this.mainWindow.getWindowAvoidArea(type));
    } catch (_) {
      return this.emptySafeInsets();
    }
  }

  private refreshAdaptiveWindowSnapshot(): void {
    try {
      const properties = this.mainWindow?.getWindowProperties();
      if (properties !== undefined) {
        this.windowWidthPx = properties.windowRect.width;
        this.windowHeightPx = properties.windowRect.height;
      }
      this.densityPixels = display.getDefaultDisplaySync().densityPixels;
    } catch (_) {
      SafeLog.error('adaptive-window-properties');
    }
    this.systemSafeInsetsPx = this.readSafeInsets(window.AvoidAreaType.TYPE_SYSTEM);
    this.cutoutSafeInsetsPx = this.readSafeInsets(window.AvoidAreaType.TYPE_CUTOUT);
    this.navigationSafeInsetsPx = this.readSafeInsets(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
    this.publishAdaptiveWindowSnapshot();
  }

  private publishAdaptiveWindowSnapshot(): void {
    const systemAndCutout = mergeRawSafeInsets(this.systemSafeInsetsPx, this.cutoutSafeInsetsPx);
    const systemCutoutAndNavigation = mergeRawSafeInsets(systemAndCutout, this.navigationSafeInsetsPx);
    adaptiveWindowLifecycle.handleSnapshot(createAdaptiveWindowSnapshot({
      widthPx: this.windowWidthPx,
      heightPx: this.windowHeightPx,
      densityPixels: this.densityPixels,
      safeInsetsPx: systemCutoutAndNavigation,
      foldOccluded: false
    }));
  }

  onDestroy(): void {
    readerSessionService.flush().catch((): void => {});
    SafeLog.event('ability-destroyed');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    SafeLog.event('window-created');

    let layoutReady: Promise<void> = Promise.resolve();
    try {
      this.mainWindow = windowStage.getMainWindowSync();
      layoutReady = this.mainWindow.setWindowLayoutFullScreen(true).catch((): void => {
        SafeLog.error('window-observer');
      });
      this.mainWindow.on('windowSizeChange', this.windowSizeChangeCallback);
      this.mainWindow.on('avoidAreaChange', this.avoidAreaChangeCallback);
      this.refreshAdaptiveWindowSnapshot();
    } catch (_) {
      SafeLog.error('window-observer');
    }

    layoutReady.then((): void => {
      this.refreshAdaptiveWindowSnapshot();
      windowStage.loadContent('pages/Index', (err) => {
        if (err.code) {
          SafeLog.error('content-load');
          return;
        }
        SafeLog.event('content-loaded');
      });
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    try {
      this.mainWindow?.off('windowSizeChange', this.windowSizeChangeCallback);
    } catch (_) {
      SafeLog.error('window-observer-stop');
    }
    try {
      this.mainWindow?.off('avoidAreaChange', this.avoidAreaChangeCallback);
    } catch (_) {
      SafeLog.error('window-observer-stop');
    }
    this.mainWindow = undefined;
    SafeLog.event('window-destroyed');
  }

  onForeground(): void {
    // Ability has brought to foreground
    try {
      this.publishInitialColorMode(this.context.getApplicationContext().resourceManager.getConfigurationSync().colorMode);
    } catch (_) { SafeLog.error('color-mode'); }
    readerApplicationLifecycle.handleForeground();
    SafeLog.event('foreground');
  }

  onBackground(): void {
    // Ability has back to background
    readerApplicationLifecycle.handleBackground();
    readerSessionService.flush().catch((): void => {});
    SafeLog.event('background');
  }
}
