// Debug-only, on-demand geometry/state observation. No command, ID, query or book data.
export interface LibraryBrowseSnapshot {
  mounted: boolean;
  active: boolean;
  contentMeasured: boolean;
  contentWidthVp: number;
  gridMeasuredWidthVp: number;
  gridWidthVp: number;
  columns: number;
  savedOffsetVp: number;
  actualOffsetVp: number;
  restored: boolean;
  revealSettled: boolean;
  sourcePending: boolean;
  focusRejectedAncestor: boolean;
  sourceInFilteredEntries: boolean;
  entryCount: number;
  folderCount: number;
}
export class LibraryBrowseObservation {
  private reader?: () => LibraryBrowseSnapshot;
  bind(reader: () => LibraryBrowseSnapshot): void { this.reader = reader; }
  unbind(reader: () => LibraryBrowseSnapshot): void { if (reader === this.reader) this.reader = undefined; }
  read(): LibraryBrowseSnapshot | undefined { return this.reader?.(); }
}
export const libraryBrowseObservation: LibraryBrowseObservation = new LibraryBrowseObservation();
