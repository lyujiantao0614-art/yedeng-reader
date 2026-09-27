import { ReaderSelectionGeometry, ReaderSelectionRect } from './ReaderSelectionModels';

export interface ReaderPopupViewport {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface SelectionPopupPlacement {
  x: number;
  y: number;
  width: number;
  height: number;
}

interface NativeSelectionRect {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

const MAX_SELECTION_FRAGMENTS: number = 64;
const POPUP_MAX_WIDTH_VP: number = 320;
const COORDINATE_EPSILON: number = 0.5;

function finite(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, minimum: number, maximum: number): number {
  if (maximum <= minimum) return minimum;
  return Math.max(minimum, Math.min(maximum, value));
}

function mapSelectionRect(rect: ReaderSelectionRect | undefined,
  viewport: ReaderPopupViewport): NativeSelectionRect | undefined {
  if (rect === undefined || !Number.isFinite(rect.left) || !Number.isFinite(rect.top) ||
    !Number.isFinite(rect.width) || !Number.isFinite(rect.height) ||
    !Number.isFinite(rect.viewportWidth) || !Number.isFinite(rect.viewportHeight) ||
    rect.width <= 0 || rect.height <= 0 || rect.viewportWidth <= 0 || rect.viewportHeight <= 0) {
    return undefined;
  }
  const scaleX = viewport.width / rect.viewportWidth;
  const scaleY = viewport.height / rect.viewportHeight;
  const left = viewport.left + rect.left * scaleX;
  const top = viewport.top + rect.top * scaleY;
  return {
    left: left,
    top: top,
    right: left + rect.width * scaleX,
    bottom: top + rect.height * scaleY
  };
}

function addCoordinate(values: number[], value: number, minimum: number, maximum: number): void {
  const bounded = clamp(value, minimum, maximum);
  for (let index = 0; index < values.length; index += 1) {
    if (Math.abs(values[index] - bounded) <= COORDINATE_EPSILON) return;
  }
  values.push(bounded);
}

function intersectsWithGap(placement: SelectionPopupPlacement, rect: NativeSelectionRect,
  gap: number): boolean {
  return placement.x < rect.right + gap && placement.x + placement.width > rect.left - gap &&
    placement.y < rect.bottom + gap && placement.y + placement.height > rect.top - gap;
}

function overlapsAny(placement: SelectionPopupPlacement, fragments: NativeSelectionRect[],
  gap: number): boolean {
  for (let index = 0; index < fragments.length; index += 1) {
    if (intersectsWithGap(placement, fragments[index], gap)) return true;
  }
  return false;
}

function overlapArea(placement: SelectionPopupPlacement, fragments: NativeSelectionRect[]): number {
  let total = 0;
  for (let index = 0; index < fragments.length; index += 1) {
    const rect = fragments[index];
    const width = Math.max(0, Math.min(placement.x + placement.width, rect.right) -
      Math.max(placement.x, rect.left));
    const height = Math.max(0, Math.min(placement.y + placement.height, rect.bottom) -
      Math.max(placement.y, rect.top));
    total += width * height;
  }
  return total;
}

function distanceFromAnchor(placement: SelectionPopupPlacement, anchor: NativeSelectionRect): number {
  const popupCenterX = placement.x + placement.width / 2;
  const popupCenterY = placement.y + placement.height / 2;
  const anchorCenterX = (anchor.left + anchor.right) / 2;
  const anchorCenterY = (anchor.top + anchor.bottom) / 2;
  const deltaX = popupCenterX - anchorCenterX;
  const deltaY = popupCenterY - anchorCenterY;
  return deltaX * deltaX + deltaY * deltaY;
}

function placementAt(x: number, y: number, width: number, height: number): SelectionPopupPlacement {
  return { x: x, y: y, width: width, height: height };
}

export function selectionPopupOverlapsGeometry(placement: SelectionPopupPlacement,
  geometry: ReaderSelectionGeometry | undefined, legacyRect: ReaderSelectionRect | undefined,
  viewport: ReaderPopupViewport, gap: number = 0): boolean {
  const fragments: NativeSelectionRect[] = [];
  const source = geometry?.fragments ?? [];
  for (let index = 0; index < source.length && index < MAX_SELECTION_FRAGMENTS; index += 1) {
    const mapped = mapSelectionRect(source[index], viewport);
    if (mapped !== undefined) fragments.push(mapped);
  }
  if (fragments.length === 0) {
    const mapped = mapSelectionRect(geometry?.anchor ?? legacyRect, viewport);
    if (mapped !== undefined) fragments.push(mapped);
  }
  return overlapsAny(placement, fragments, Math.max(0, finite(gap, 0)));
}

export function placeSelectionPopup(geometry: ReaderSelectionGeometry | undefined,
  legacyRect: ReaderSelectionRect | undefined, viewport: ReaderPopupViewport,
  desiredHeight: number, margin: number = 12, gap: number = 10): SelectionPopupPlacement {
  const targetLeft = finite(viewport.left, 0);
  const targetTop = finite(viewport.top, 0);
  const targetWidth = Math.max(0, finite(viewport.width, 0));
  const targetHeight = Math.max(0, finite(viewport.height, 0));
  const boundedMarginX = Math.min(Math.max(0, finite(margin, 0)), targetWidth / 2);
  const boundedMarginY = Math.min(Math.max(0, finite(margin, 0)), targetHeight / 2);
  const popupGap = Math.max(0, finite(gap, 0));
  const popupWidth = Math.min(POPUP_MAX_WIDTH_VP, Math.max(0, targetWidth - boundedMarginX * 2));
  const popupHeight = Math.min(Math.max(0, finite(desiredHeight, 0)),
    Math.max(0, targetHeight - boundedMarginY * 2));
  const minimumX = targetLeft + boundedMarginX;
  const maximumX = targetLeft + targetWidth - boundedMarginX - popupWidth;
  const minimumY = targetTop + boundedMarginY;
  const maximumY = targetTop + targetHeight - boundedMarginY - popupHeight;

  const fallback = placementAt(clamp(targetLeft + (targetWidth - popupWidth) / 2, minimumX, maximumX),
    maximumY, popupWidth, popupHeight);
  const normalizedViewport: ReaderPopupViewport = {
    left: targetLeft, top: targetTop, width: targetWidth, height: targetHeight
  };
  const anchor = mapSelectionRect(geometry?.anchor ?? legacyRect, normalizedViewport);
  if (anchor === undefined || popupWidth <= 0 || popupHeight <= 0) return fallback;

  const fragments: NativeSelectionRect[] = [];
  const source = geometry?.fragments ?? [];
  for (let index = 0; index < source.length && index < MAX_SELECTION_FRAGMENTS; index += 1) {
    const mapped = mapSelectionRect(source[index], normalizedViewport);
    if (mapped !== undefined) fragments.push(mapped);
  }
  if (fragments.length === 0) fragments.push(anchor);

  const anchorCenterX = (anchor.left + anchor.right) / 2;
  const preferredX = clamp(anchorCenterX - popupWidth / 2, minimumX, maximumX);
  const preferredAbove = placementAt(preferredX,
    clamp(anchor.top - popupGap - popupHeight, minimumY, maximumY), popupWidth, popupHeight);
  if (preferredAbove.y + preferredAbove.height <= anchor.top - popupGap &&
    !overlapsAny(preferredAbove, fragments, popupGap)) return preferredAbove;
  const preferredBelow = placementAt(preferredX,
    clamp(anchor.bottom + popupGap, minimumY, maximumY), popupWidth, popupHeight);
  if (preferredBelow.y >= anchor.bottom + popupGap &&
    !overlapsAny(preferredBelow, fragments, popupGap)) return preferredBelow;

  const xValues: number[] = [];
  const yValues: number[] = [];
  addCoordinate(xValues, preferredX, minimumX, maximumX);
  addCoordinate(xValues, minimumX, minimumX, maximumX);
  addCoordinate(xValues, maximumX, minimumX, maximumX);
  addCoordinate(xValues, targetLeft + (targetWidth - popupWidth) / 2, minimumX, maximumX);
  addCoordinate(yValues, preferredAbove.y, minimumY, maximumY);
  addCoordinate(yValues, preferredBelow.y, minimumY, maximumY);
  addCoordinate(yValues, minimumY, minimumY, maximumY);
  addCoordinate(yValues, maximumY, minimumY, maximumY);
  addCoordinate(yValues, targetTop + (targetHeight - popupHeight) / 2, minimumY, maximumY);
  for (let index = 0; index < fragments.length; index += 1) {
    const rect = fragments[index];
    addCoordinate(xValues, rect.left - popupGap - popupWidth, minimumX, maximumX);
    addCoordinate(xValues, rect.right + popupGap, minimumX, maximumX);
    addCoordinate(yValues, rect.top - popupGap - popupHeight, minimumY, maximumY);
    addCoordinate(yValues, rect.bottom + popupGap, minimumY, maximumY);
  }

  for (let xIndex = 0; xIndex < xValues.length; xIndex += 1) {
    for (let yIndex = 0; yIndex < yValues.length; yIndex += 1) {
      const candidate = placementAt(xValues[xIndex], yValues[yIndex], popupWidth, popupHeight);
      if (!overlapsAny(candidate, fragments, popupGap)) return candidate;
    }
  }

  let bestFallback: SelectionPopupPlacement = fallback;
  let bestFallbackOverlap = overlapArea(fallback, fragments);
  let bestFallbackDistance = distanceFromAnchor(fallback, anchor);
  const baseXCount = Math.min(4, xValues.length);
  const baseYCount = Math.min(5, yValues.length);
  for (let xIndex = 0; xIndex < xValues.length; xIndex += 1) {
    for (let yIndex = 0; yIndex < baseYCount; yIndex += 1) {
      const candidate = placementAt(xValues[xIndex], yValues[yIndex], popupWidth, popupHeight);
      const overlap = overlapArea(candidate, fragments);
      const distance = distanceFromAnchor(candidate, anchor);
      if (overlap < bestFallbackOverlap ||
        (Math.abs(overlap - bestFallbackOverlap) <= COORDINATE_EPSILON && distance < bestFallbackDistance)) {
        bestFallback = candidate;
        bestFallbackOverlap = overlap;
        bestFallbackDistance = distance;
      }
    }
  }
  for (let xIndex = 0; xIndex < baseXCount; xIndex += 1) {
    for (let yIndex = baseYCount; yIndex < yValues.length; yIndex += 1) {
      const candidate = placementAt(xValues[xIndex], yValues[yIndex], popupWidth, popupHeight);
      const overlap = overlapArea(candidate, fragments);
      const distance = distanceFromAnchor(candidate, anchor);
      if (overlap < bestFallbackOverlap ||
        (Math.abs(overlap - bestFallbackOverlap) <= COORDINATE_EPSILON && distance < bestFallbackDistance)) {
        bestFallback = candidate;
        bestFallbackOverlap = overlap;
        bestFallbackDistance = distance;
      }
    }
  }
  return bestFallback;
}
