import { bundleManager } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { READER_BENCHMARK_ENABLED, READER_DIAGNOSTICS_ENABLED } from 'BuildProfile';
import { DiagnosticMetadata, DiagnosticDeviceClass } from '../diagnostics/DiagnosticExportContract';
import { DiagnosticMetadataProvider } from '../application/DiagnosticExportApplication';

function deviceClass(value: string): DiagnosticDeviceClass {
  if (value === 'default' || value === 'phone') return 'phone';
  if (value === 'tablet' || value === 'wearable' || value === 'liteWearable' ||
    value === 'tv' || value === 'car' || value === 'smartVision') return value;
  return 'unknown';
}

export class PlatformDiagnosticMetadata implements DiagnosticMetadataProvider {
  metadata(): DiagnosticMetadata {
    let appVersion = 'unknown';
    try {
      appVersion = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT).versionName;
    } catch (_) {}
    return {
      appVersion: appVersion,
      api: deviceInfo.sdkApiVersion,
      deviceClass: deviceClass(deviceInfo.deviceType),
      buildMode: READER_BENCHMARK_ENABLED ? 'benchmark' : READER_DIAGNOSTICS_ENABLED ? 'debug' : 'release'
    };
  }
}
