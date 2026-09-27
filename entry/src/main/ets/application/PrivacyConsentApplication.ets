import { common } from '@kit.AbilityKit';
import { PrivacyConsentRepository } from '../repositories/PrivacyConsentRepository';

export const PRIVACY_POLICY_VERSION: string = '2026-09-28';

export class PrivacyConsentApplication {
  private repository: PrivacyConsentRepository;

  constructor(repository: PrivacyConsentRepository) {
    this.repository = repository;
  }

  initialize(context: common.UIAbilityContext): void {
    this.repository.initialize(context);
  }

  hasAcceptedCurrentPolicy(): boolean {
    return this.repository.acceptedVersion() === PRIVACY_POLICY_VERSION;
  }

  acceptCurrentPolicy(): void {
    this.repository.saveAcceptedVersion(PRIVACY_POLICY_VERSION);
  }
}
