import { normalizeSelectedWord } from './DictionaryLookup';
import { DictionaryLookupResult } from './DictionaryModels';
import { DictionaryProvider } from './DictionaryProvider';

export class DictionaryService {
  private provider: DictionaryProvider;
  private requestGeneration: number = 0;

  constructor(provider: DictionaryProvider) {
    this.provider = provider;
  }

  cancelPending(): void {
    this.requestGeneration += 1;
  }

  async lookup(selectedForm: string): Promise<DictionaryLookupResult | undefined> {
    const request = ++this.requestGeneration;
    const normalized = normalizeSelectedWord(selectedForm);
    if (normalized === undefined) {
      return {
        status: 'invalid-selection',
        selectedForm: selectedForm.trim().substring(0, 96),
        entries: []
      };
    }
    try {
      const entries = await this.provider.lookup({
        term: normalized.normalizedTerm,
        sourceLanguage: 'en',
        targetLanguage: 'zh-Hans'
      });
      if (request !== this.requestGeneration) {
        return undefined;
      }
      return {
        status: entries.length > 0 ? 'found' : 'not-found',
        selectedForm: normalized.selectedForm,
        entries: entries
      };
    } catch (_) {
      if (request !== this.requestGeneration) {
        return undefined;
      }
      return { status: 'unavailable', selectedForm: normalized.selectedForm, entries: [] };
    }
  }
}
