import deviceInfo from '@ohos.deviceInfo';
import promptAction from '@ohos.promptAction';

export interface NativeOverlayMaterials {
  menu?: SystemUiMaterial;
  panel?: SystemUiMaterial;
}

// Load once in the App shell. API21 never imports this API26 native module.
export async function loadNativeOverlayMaterials(): Promise<NativeOverlayMaterials> {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      const module = await import('@ohos.arkui.uiMaterial');
      if (module.default.isImmersiveMaterialSupported()) {
        return {
          menu: new module.default.ImmersiveMaterial({ style: module.default.ImmersiveStyle.THICK }),
          panel: new module.default.ImmersiveMaterial({ style: module.default.ImmersiveStyle.ULTRA_THICK })
        };
      }
    }
  }
  return {};
}

export class NativeSelectMenuMaterial implements AttributeModifier<SelectAttribute> {
  private material: SystemUiMaterial | undefined;
  constructor(material: SystemUiMaterial | undefined) { this.material = material; }
  applyNormalAttribute(instance: SelectAttribute): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.material !== undefined) instance.menuSystemMaterial(this.material);
      }
    }
  }
}

// Web keeps ownership of the native selection menu; only its custom content uses this material.
export class NativeSelectionMenuMaterial implements AttributeModifier<RowAttribute> {
  private material: SystemUiMaterial | undefined;
  private fallback: ResourceColor;
  constructor(material: SystemUiMaterial | undefined, fallback: ResourceColor) {
    this.material = material; this.fallback = fallback;
  }
  applyNormalAttribute(instance: RowAttribute): void {
    if (deviceInfo.sdkApiVersion >= 26) {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (this.material !== undefined) { instance.systemMaterial(this.material); return; }
      }
    }
    instance.backgroundColor(this.fallback).shadow(ShadowStyle.OUTER_DEFAULT_SM);
  }
}

export function nativeMenuOptions(material: SystemUiMaterial | undefined, options: MenuOptions = {}): MenuOptions {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (material !== undefined) options.systemMaterial = material;
    }
  }
  return options;
}

export function nativeSheetOptions(material: SystemUiMaterial | undefined, options: SheetOptions): SheetOptions {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (material !== undefined) options.systemMaterial = material;
    }
  }
  return options;
}

export function nativePromptDialogOptions(material: SystemUiMaterial | undefined,
  options: promptAction.ShowDialogOptions): promptAction.ShowDialogOptions {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (material !== undefined) options.systemMaterial = material;
    }
  }
  return options;
}

export function nativeAlertOptions(material: SystemUiMaterial | undefined,
  options: AlertDialogParamWithConfirm | AlertDialogParamWithButtons | AlertDialogParamWithOptions):
  AlertDialogParamWithConfirm | AlertDialogParamWithButtons | AlertDialogParamWithOptions {
  if (deviceInfo.sdkApiVersion >= 26) {
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (material !== undefined) options.systemMaterial = material;
    }
  }
  return options;
}

