import { DictionaryPartOfSpeech, NormalizedDictionaryTerm } from './DictionaryModels';

const MAX_SELECTED_FORM_LENGTH: number = 96;
const MAX_NORMALIZED_TERM_LENGTH: number = 64;
const EDGE_PUNCTUATION: string = '“”‘’\"\'.,!?;:()[]{}<>';
const SINGLE_WORD: RegExp = /^[a-z]+(?:['-][a-z]+)*$/;

function stripEdgePunctuation(value: string): string {
  let start = 0;
  let end = value.length;
  while (start < end && EDGE_PUNCTUATION.includes(value[start])) {
    start += 1;
  }
  while (end > start && EDGE_PUNCTUATION.includes(value[end - 1])) {
    end -= 1;
  }
  return value.substring(start, end);
}

export function normalizeSelectedWord(value: string): NormalizedDictionaryTerm | undefined {
  const selectedForm = value.trim();
  if (selectedForm.length === 0 || selectedForm.length > MAX_SELECTED_FORM_LENGTH) {
    return undefined;
  }
  let normalized = selectedForm.normalize('NFKC').toLowerCase()
    .replace(/’/g, "'").replace(/[‐‑‒–—−]/g, '-').trim();
  normalized = stripEdgePunctuation(normalized);
  if (normalized.endsWith("'s")) {
    normalized = normalized.substring(0, normalized.length - 2);
  }
  if (normalized.length === 0 || normalized.length > MAX_NORMALIZED_TERM_LENGTH ||
    !SINGLE_WORD.test(normalized)) {
    return undefined;
  }
  return { selectedForm: selectedForm, normalizedTerm: normalized };
}

function appendUnique(values: string[], value: string): void {
  if (value.length > 0 && !values.includes(value)) {
    values.push(value);
  }
}

export function regularLemmaCandidates(surface: string): string[] {
  const candidates: string[] = [];
  if (surface.endsWith('ies') && surface.length > 3) {
    appendUnique(candidates, `${surface.substring(0, surface.length - 3)}y`);
  }
  if (surface.endsWith('es') && surface.length > 2) {
    appendUnique(candidates, surface.substring(0, surface.length - 2));
    appendUnique(candidates, surface.substring(0, surface.length - 1));
  }
  if (surface.endsWith('s') && surface.length > 1) {
    appendUnique(candidates, surface.substring(0, surface.length - 1));
  }
  if (surface.endsWith('ed') && surface.length > 2) {
    appendUnique(candidates, surface.substring(0, surface.length - 2));
    appendUnique(candidates, surface.substring(0, surface.length - 1));
  }
  if (surface.endsWith('er') && surface.length > 2) {
    appendUnique(candidates, surface.substring(0, surface.length - 1));
    appendUnique(candidates, surface.substring(0, surface.length - 2));
  }
  if (surface.endsWith('est') && surface.length > 3) {
    appendUnique(candidates, surface.substring(0, surface.length - 2));
    appendUnique(candidates, surface.substring(0, surface.length - 3));
  }
  if (surface.endsWith('ing') && surface.length > 3) {
    const stem = surface.substring(0, surface.length - 3);
    appendUnique(candidates, stem);
    appendUnique(candidates, `${stem}e`);
    if (stem.length >= 2 && stem[stem.length - 1] === stem[stem.length - 2]) {
      appendUnique(candidates, stem.substring(0, stem.length - 1));
    }
  }
  return candidates;
}

export function dictionaryPartOfSpeech(value: string): DictionaryPartOfSpeech | undefined {
  if (value === 'n') return 'noun';
  if (value === 'v') return 'verb';
  if (value === 'a') return 'adjective';
  if (value === 'r') return 'adverb';
  return undefined;
}
