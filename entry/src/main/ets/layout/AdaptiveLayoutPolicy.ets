export type AdaptiveWindowSizeClass = 'compact' | 'medium' | 'expanded';

export interface AdaptiveSafeInsets {
  top: number;
  right: number;
  bottom: number;
  left: number;
}

export interface RawSafeInsetsPx {
  top: number;
  right: number;
  bottom: number;
  left: number;
}


export interface AdaptiveWindowSnapshot {
  widthVp: number;
  heightVp: number;
  safeInsets: AdaptiveSafeInsets;
  usableWidthVp: number;
  usableHeightVp: number;
  sizeClass: AdaptiveWindowSizeClass;
  foldOccluded: boolean;
}

export interface AdaptiveWindowInput {
  widthPx: number;
  heightPx: number;
  densityPixels: number;
  safeInsetsPx: RawSafeInsetsPx;
  foldOccluded: boolean;
}

interface NormalizedInsetPair {
  first: number;
  second: number;
}

export const COMPACT_MAX_WIDTH_VP: number = 600;
export const MEDIUM_MAX_WIDTH_VP: number = 840;
export const READER_SIDE_PANEL_MIN_WIDTH_VP: number = 720;
export const SETTINGS_CONTENT_MAX_WIDTH_VP: number = 720;
export const READER_FOOTER_RESERVE_VP: number = 64;
export const READER_HEADER_RESERVE_VP: number = 64;

const COMPACT_PAGE_INSET_VP: number = 16;
const MEDIUM_PAGE_INSET_VP: number = 24;
const EXPANDED_PAGE_INSET_VP: number = 32;
const LIBRARY_GRID_GAP_VP: number = 12;
const LIBRARY_CARD_MIN_WIDTH_VP: number = 160;
const LIBRARY_CARD_LARGE_TEXT_MIN_WIDTH_VP: number = 220;
const LARGE_TEXT_SCALE_THRESHOLD: number = 1.3;

function finiteNonNegative(value: number): number {
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

function normalizedDensity(value: number): number {
  return Number.isFinite(value) && value > 0 ? value : 1;
}

function normalizeInsetPair(first: number, second: number, extent: number): NormalizedInsetPair {
  const safeFirst = finiteNonNegative(first);
  const safeSecond = finiteNonNegative(second);
  const safeExtent = finiteNonNegative(extent);
  const total = safeFirst + safeSecond;
  if (total <= safeExtent || total === 0) return { first: safeFirst, second: safeSecond };
  const scale = safeExtent / total;
  return { first: safeFirst * scale, second: safeSecond * scale };
}

export function classifyAdaptiveWindow(usableWidthVp: number): AdaptiveWindowSizeClass {
  const width = finiteNonNegative(usableWidthVp);
  if (width < COMPACT_MAX_WIDTH_VP) return 'compact';
  if (width < MEDIUM_MAX_WIDTH_VP) return 'medium';
  return 'expanded';
}

export function normalizeSafeInsets(widthVp: number, heightVp: number,
  densityPixels: number, raw: RawSafeInsetsPx): AdaptiveSafeInsets {
  const density = normalizedDensity(densityPixels);
  const horizontal = normalizeInsetPair(raw.left / density, raw.right / density, widthVp);
  const vertical = normalizeInsetPair(raw.top / density, raw.bottom / density, heightVp);
  return {
    top: vertical.first,
    right: horizontal.second,
    bottom: vertical.second,
    left: horizontal.first
  };
}

export function mergeRawSafeInsets(first: RawSafeInsetsPx, second: RawSafeInsetsPx): RawSafeInsetsPx {
  return {
    top: Math.max(finiteNonNegative(first.top), finiteNonNegative(second.top)),
    right: Math.max(finiteNonNegative(first.right), finiteNonNegative(second.right)),
    bottom: Math.max(finiteNonNegative(first.bottom), finiteNonNegative(second.bottom)),
    left: Math.max(finiteNonNegative(first.left), finiteNonNegative(second.left))
  };
}

export function adaptiveReaderColumnMode(snapshot: AdaptiveWindowSnapshot,
  requested: 'auto' | 'single'): 'auto' | 'single' {
  if (snapshot.foldOccluded) return 'single';
  return requested === 'single' ? 'single' : 'auto';
}

export function readerUsesSidePanel(snapshot: AdaptiveWindowSnapshot): boolean {
  return !snapshot.foldOccluded && finiteNonNegative(snapshot.usableWidthVp) >= READER_SIDE_PANEL_MIN_WIDTH_VP;
}

export function readerFooterReserveVp(availableHeightVp: number): number {
  const height = finiteNonNegative(availableHeightVp);
  return Math.min(READER_FOOTER_RESERVE_VP, Math.max(0, height - 240));
}

export function readerHeaderReserveVp(availableHeightVp: number): number {
  const height = finiteNonNegative(availableHeightVp);
  return Math.min(READER_HEADER_RESERVE_VP,
    Math.max(0, height - readerFooterReserveVp(height) - 240));
}

export function readerPublicationContentHeightVp(availableHeightVp: number): number {
  const height = finiteNonNegative(availableHeightVp);
  return height - readerHeaderReserveVp(height) - readerFooterReserveVp(height);
}

export function createAdaptiveWindowSnapshot(input: AdaptiveWindowInput): AdaptiveWindowSnapshot {
  const density = normalizedDensity(input.densityPixels);
  const widthVp = finiteNonNegative(input.widthPx) / density;
  const heightVp = finiteNonNegative(input.heightPx) / density;
  const safeInsets = normalizeSafeInsets(widthVp, heightVp, density, input.safeInsetsPx);
  const usableWidthVp = Math.max(0, widthVp - safeInsets.left - safeInsets.right);
  const usableHeightVp = Math.max(0, heightVp - safeInsets.top - safeInsets.bottom);
  return {
    widthVp: widthVp,
    heightVp: heightVp,
    safeInsets: safeInsets,
    usableWidthVp: usableWidthVp,
    usableHeightVp: usableHeightVp,
    sizeClass: classifyAdaptiveWindow(usableWidthVp),
    foldOccluded: input.foldOccluded
  };
}

export function adaptivePageInsetVp(sizeClass: AdaptiveWindowSizeClass): number {
  if (sizeClass === 'expanded') return EXPANDED_PAGE_INSET_VP;
  if (sizeClass === 'medium') return MEDIUM_PAGE_INSET_VP;
  return COMPACT_PAGE_INSET_VP;
}

export function libraryGridColumnCount(snapshot: AdaptiveWindowSnapshot, fontSizeScale: number): number {
  const pageInset = adaptivePageInsetVp(snapshot.sizeClass);
  const availableWidth = Math.max(0, snapshot.usableWidthVp - pageInset * 2);
  const effectiveScale = Number.isFinite(fontSizeScale) && fontSizeScale > 0 ? fontSizeScale : 1;
  const minimumWidth = effectiveScale >= LARGE_TEXT_SCALE_THRESHOLD ?
    LIBRARY_CARD_LARGE_TEXT_MIN_WIDTH_VP : LIBRARY_CARD_MIN_WIDTH_VP;
  const fittingColumns = Math.max(1, Math.floor((availableWidth + LIBRARY_GRID_GAP_VP) /
    (minimumWidth + LIBRARY_GRID_GAP_VP)));
  const visualMaximum = snapshot.sizeClass === 'expanded' ? 4 : (snapshot.sizeClass === 'medium' ? 3 : 2);
  return Math.min(fittingColumns, visualMaximum);
}

export function libraryGridColumnsTemplate(snapshot: AdaptiveWindowSnapshot, fontSizeScale: number): string {
  const count = libraryGridColumnCount(snapshot, fontSizeScale);
  let template = '1fr';
  for (let index = 1; index < count; index += 1) template += ' 1fr';
  return template;
}

export const DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT: AdaptiveWindowSnapshot = createAdaptiveWindowSnapshot({
  widthPx: 390,
  heightPx: 844,
  densityPixels: 1,
  safeInsetsPx: { top: 0, right: 0, bottom: 0, left: 0 },
  foldOccluded: false
});
