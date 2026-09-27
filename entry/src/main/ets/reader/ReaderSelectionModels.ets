export interface ReaderSelectionRect {
  left: number;
  top: number;
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
}

export interface ReaderSelectionGeometry {
  anchor: ReaderSelectionRect;
  fragments: ReaderSelectionRect[];
}
