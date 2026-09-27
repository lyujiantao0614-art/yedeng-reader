import { ReaderSelectionGeometry, ReaderSelectionRect } from './ReaderSelectionModels';

export type ReadingSelectionKind = 'word' | 'passage';

export interface PassageSelectionCandidate {
  engine: string;
  selectionToken: string;
  characterCount: number;
  locator: string;
  geometry?: ReaderSelectionGeometry;
  // Retained while native surfaces migrate to fragment-aware placement.
  rect?: ReaderSelectionRect;
}

export interface ReadingRangeCandidate {
  resourceHref: string;
  cfi: string;
  exactText: string;
  prefix: string;
  suffix: string;
}

export interface ReadingSelectionContext {
  selectionToken: string;
  kind: ReadingSelectionKind;
  selectedText: string;
  bookTitle?: string;
  chapterTitle?: string;
  previousText?: string;
  currentText?: string;
  nextText?: string;
  rangeAnchor?: ReadingRangeCandidate;
  markConflict?: 'overlap' | 'unavailable';
}
