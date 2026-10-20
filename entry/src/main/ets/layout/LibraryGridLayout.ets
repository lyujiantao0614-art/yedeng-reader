// First redesign slice: native viewport review values, not owner acceptance.
export const LIBRARY_COLUMN_GAP_VP: number = 12;
export const LIBRARY_ROW_GAP_VP: number = 14;
export const LIBRARY_PAGE_INSET_VP: number = 16;
export const LIBRARY_COVER_RADIUS_VP: number = 4;
export const LIBRARY_COVER_AREA_RATIO: number = 1.4;
export const LIBRARY_COVER_TITLE_GAP_VP: number = 8;
export const LIBRARY_TITLE_META_GAP_VP: number = 0;
export const LIBRARY_SYMBOL_SIZE_VP: number = 22;
export const LIBRARY_FOLDER_SYMBOL_SIZE_VP: number = 52;
export const LIBRARY_ZERO_PADDING_VP: number = 0;
export interface LibraryGridGeometry {
  columns: number;
  cellWidthVp: number;
  gridWidthVp: number;
  columnsTemplate: string;
  columnGapVp: number;
  rowGapVp: number;
  pageInsetVp: number;
}
export function libraryGridGeometry(contentWidthVp: number, measuredTitleWidthVp: number,
  windowWidthVp: number = contentWidthVp): LibraryGridGeometry {
  const width = Number.isFinite(contentWidthVp) ? Math.max(1, contentWidthVp) : 1;
  const measured = Number.isFinite(measuredTitleWidthVp) ? Math.max(0, measuredTitleWidthVp) : 0;
  // The native six-character title probe grows with actual fp; it is never multiplied by a scale guess.
  const t = Math.max(0, Math.min(1, (windowWidthVp - 360) / 480));
  const gap = 12 + 4 * t;
  const minimum = Math.max(104 + 20 * t, measured + 20);
  const maximum = Math.max(minimum, 126 + 18 * t);
  const columns = Math.max(1, Math.floor((width + gap) / (minimum + gap)));
  const cellWidthVp = Math.min(maximum, (width - (columns - 1) * gap) / columns);
  let columnsTemplate = '1fr';
  for (let index = 1; index < columns; index++) columnsTemplate += ' 1fr';
  // Only this bounded Grid shares its width; unused outer width does not stretch books into bars.
  return { columns, cellWidthVp, gridWidthVp: cellWidthVp * columns + (columns - 1) * gap,
    columnsTemplate, columnGapVp: gap, rowGapVp: 14 + 4 * t, pageInsetVp: 16 + 16 * t };
}
