import { DictionaryEntry, DictionaryLookupQuery, DictionaryMetadata } from './DictionaryModels';

export interface DictionaryProvider {
  getMetadata(): DictionaryMetadata;
  lookup(query: DictionaryLookupQuery): Promise<DictionaryEntry[]>;
}
