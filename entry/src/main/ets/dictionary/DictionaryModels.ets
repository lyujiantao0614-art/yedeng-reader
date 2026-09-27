export type DictionaryMatchKind = 'exact' | 'inflection' | 'suffix';
export type DictionaryPartOfSpeech = 'noun' | 'verb' | 'adjective' | 'adverb';
export type DictionaryLookupStatus = 'found' | 'not-found' | 'invalid-selection' | 'unavailable';

export interface DictionaryLookupQuery {
  term: string;
  sourceLanguage?: 'en';
  targetLanguage?: 'zh-Hans';
}

export interface DictionarySense {
  partOfSpeech?: DictionaryPartOfSpeech;
  meanings: string[];
}

export interface DictionaryEntry {
  providerId: string;
  headword: string;
  matchKind: DictionaryMatchKind;
  senses: DictionarySense[];
}

export interface DictionaryMetadata {
  providerId: string;
  version: string;
  sourceLanguage: 'en';
  targetLanguage: 'zh-Hans';
  offline: boolean;
}

export interface DictionaryLookupResult {
  status: DictionaryLookupStatus;
  selectedForm: string;
  entries: DictionaryEntry[];
}

export interface NormalizedDictionaryTerm {
  selectedForm: string;
  normalizedTerm: string;
}
