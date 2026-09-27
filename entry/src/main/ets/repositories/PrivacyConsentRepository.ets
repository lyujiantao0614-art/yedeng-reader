import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export class PrivacyConsentRepository {
  private store?: preferences.Preferences;

  initialize(context: common.UIAbilityContext): void {
    try { this.store = preferences.getPreferencesSync(context, { name: 'privacy_consent' }); }
    catch (_) { throw new Error('Privacy consent store is unavailable'); }
  }

  acceptedVersion(): string {
    if (this.store === undefined) throw new Error('Privacy consent store is unavailable');
    try {
      const value = this.store.getSync('accepted_version', '');
      return typeof value === 'string' ? value : '';
    } catch (_) { throw new Error('Privacy consent state could not be read'); }
  }

  saveAcceptedVersion(version: string): void {
    if (this.store === undefined) throw new Error('Privacy consent store is unavailable');
    try {
      this.store.putSync('accepted_version', version);
      this.store.flushSync();
    } catch (_) { throw new Error('Privacy consent state could not be saved'); }
  }
}
