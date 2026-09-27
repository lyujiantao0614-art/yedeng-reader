import { describe, it, expect } from '@ohos/hypium';
import {
  COMPACT_MAX_WIDTH_VP,
  DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT,
  MEDIUM_MAX_WIDTH_VP,
  READER_FOOTER_RESERVE_VP,
  SETTINGS_CONTENT_MAX_WIDTH_VP,
  adaptivePageInsetVp,
  adaptiveReaderColumnMode,
  classifyAdaptiveWindow,
  createAdaptiveWindowSnapshot,
  libraryGridColumnCount,
  libraryGridColumnsTemplate,
  mergeRawSafeInsets,
  normalizeSafeInsets,
  readerFooterReserveVp,
  readerPublicationContentHeightVp
} from '../main/ets/layout/AdaptiveLayoutPolicy';
import { validatedExternalLinkHost } from '../main/ets/reader/ReaderNetworkPolicy';
import { shouldDismissTransientSurfaceForLocation } from '../main/ets/reader/ReaderSurfaceState';
import {
  ReaderPopupViewport,
  placeSelectionPopup,
  selectionPopupOverlapsGeometry
} from '../main/ets/reader/SelectionPopupPlacementPolicy';
import { ReaderSelectionGeometry, ReaderSelectionRect } from '../main/ets/reader/ReaderSelectionModels';

export default function phase33LocalUnitTest() {
  describe('phase33AdaptiveAndInteractionContracts', () => {
    it('classifiesExactCompactMediumAndExpandedBoundaries', 0, () => {
      expect(COMPACT_MAX_WIDTH_VP).assertEqual(600);
      expect(MEDIUM_MAX_WIDTH_VP).assertEqual(840);
      expect(SETTINGS_CONTENT_MAX_WIDTH_VP).assertEqual(720);
      expect(classifyAdaptiveWindow(COMPACT_MAX_WIDTH_VP - 0.001)).assertEqual('compact');
      expect(classifyAdaptiveWindow(COMPACT_MAX_WIDTH_VP)).assertEqual('medium');
      expect(classifyAdaptiveWindow(MEDIUM_MAX_WIDTH_VP - 0.001)).assertEqual('medium');
      expect(classifyAdaptiveWindow(MEDIUM_MAX_WIDTH_VP)).assertEqual('expanded');
      expect(classifyAdaptiveWindow(Number.NaN)).assertEqual('compact');
      expect(classifyAdaptiveWindow(Number.POSITIVE_INFINITY)).assertEqual('compact');
      expect(classifyAdaptiveWindow(-1)).assertEqual('compact');
    });

    it('reservesAStableReaderFooterWithoutOverflowingShortWindows', 0, () => {
      expect(READER_FOOTER_RESERVE_VP).assertEqual(64);
      expect(readerFooterReserveVp(732)).assertEqual(64);
      expect(readerPublicationContentHeightVp(732)).assertEqual(668);
      expect(readerFooterReserveVp(300)).assertEqual(60);
      expect(readerPublicationContentHeightVp(300)).assertEqual(240);
      expect(readerFooterReserveVp(200)).assertEqual(0);
      expect(readerPublicationContentHeightVp(200)).assertEqual(200);
    });

    it('normalizesAndBoundsSafeInsetsInViewportUnits', 0, () => {
      const normalized = normalizeSafeInsets(100, 200, 2, {
        top: 10, right: 40, bottom: 30, left: 20
      });
      expect(normalized.top).assertEqual(5);
      expect(normalized.right).assertEqual(20);
      expect(normalized.bottom).assertEqual(15);
      expect(normalized.left).assertEqual(10);

      const bounded = normalizeSafeInsets(100, 80, 1, {
        top: 120, right: 150, bottom: 120, left: 150
      });
      expect(bounded.left).assertEqual(50);
      expect(bounded.right).assertEqual(50);
      expect(bounded.top).assertEqual(40);
      expect(bounded.bottom).assertEqual(40);

      const sanitized = normalizeSafeInsets(100, 80, 0, {
        top: -1, right: Number.NaN, bottom: -20, left: Number.POSITIVE_INFINITY
      });
      expect(sanitized.top).assertEqual(0);
      expect(sanitized.right).assertEqual(0);
      expect(sanitized.bottom).assertEqual(0);
      expect(sanitized.left).assertEqual(0);
    });

    it('mergesSafeRegionsWithoutAllowingNegativeOrNonFiniteInsets', 0, () => {
      const merged = mergeRawSafeInsets(
        { top: 8, right: -1, bottom: 16, left: Number.NaN },
        { top: 12, right: 20, bottom: 4, left: 6 }
      );
      expect(merged.top).assertEqual(12);
      expect(merged.right).assertEqual(20);
      expect(merged.bottom).assertEqual(16);
      expect(merged.left).assertEqual(6);
    });

    it('treatsHalfFoldAsTheFullWindowAndFoldedModeByActualWidth', 0, () => {
      const halfFolded = createAdaptiveWindowSnapshot({
        widthPx: 1800,
        heightPx: 2400,
        densityPixels: 2,
        safeInsetsPx: { top: 80, right: 20, bottom: 120, left: 20 },
        foldOccluded: false
      });
      expect(halfFolded.widthVp).assertEqual(900);
      expect(halfFolded.heightVp).assertEqual(1200);
      expect(halfFolded.usableWidthVp).assertEqual(880);
      expect(halfFolded.usableHeightVp).assertEqual(1100);
      expect(halfFolded.sizeClass).assertEqual('expanded');
      expect(halfFolded.foldOccluded).assertEqual(false);
      expect(adaptiveReaderColumnMode(halfFolded, 'auto')).assertEqual('auto');

      const folded = createAdaptiveWindowSnapshot({
        widthPx: 900,
        heightPx: 2000,
        densityPixels: 2,
        safeInsetsPx: { top: 80, right: 20, bottom: 120, left: 20 },
        foldOccluded: false
      });
      expect(folded.sizeClass).assertEqual('compact');
      expect(adaptiveReaderColumnMode(folded, 'auto')).assertEqual('auto');
    });

    it('usesBoundedInsetsAndLargeTextFallbackForLibraryColumns', 0, () => {
      expect(adaptivePageInsetVp('compact')).assertEqual(16);
      expect(adaptivePageInsetVp('medium')).assertEqual(24);
      expect(adaptivePageInsetVp('expanded')).assertEqual(32);
      expect(DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT.sizeClass).assertEqual('compact');
      expect(libraryGridColumnCount(DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, 1)).assertEqual(2);
      expect(libraryGridColumnsTemplate(DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, 1))
        .assertEqual('1fr 1fr');
      expect(libraryGridColumnCount(DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, 1.3)).assertEqual(1);
      expect(libraryGridColumnsTemplate(DEFAULT_ADAPTIVE_WINDOW_SNAPSHOT, 1.3))
        .assertEqual('1fr');
    });

    it('keepsLayoutSurfacesAndNormalizesRuntimeNullableExternalHostParts', 0, () => {
      expect(shouldDismissTransientSurfaceForLocation('layout')).assertEqual(false);
      expect(shouldDismissTransientSurfaceForLocation('navigation')).assertEqual(true);
      expect(validatedExternalLinkHost(undefined, 'example.invalid')).assertEqual('example.invalid');
      expect(validatedExternalLinkHost('', 'example.invalid')).assertEqual('example.invalid');
      expect(validatedExternalLinkHost('reader', 'example.invalid')).assertEqual('');
      expect(validatedExternalLinkHost(undefined, undefined)).assertEqual('');
      expect(validatedExternalLinkHost(undefined, 'x'.repeat(254))).assertEqual('');
    });

    it('placesSelectionSurfacesInsideSafeHostWithoutCoveringAllFragments', 0, () => {
      const viewport: ReaderPopupViewport = { left: 10, top: 40, width: 880, height: 1040 };
      const first: ReaderSelectionRect = {
        left: 80, top: 180, width: 220, height: 24, viewportWidth: 880, viewportHeight: 1040
      };
      const middle: ReaderSelectionRect = {
        left: 80, top: 420, width: 220, height: 24, viewportWidth: 880, viewportHeight: 1040
      };
      const anchor: ReaderSelectionRect = {
        left: 80, top: 700, width: 220, height: 24, viewportWidth: 880, viewportHeight: 1040
      };
      const geometry: ReaderSelectionGeometry = { anchor: anchor, fragments: [first, middle, anchor] };
      const placement = placeSelectionPopup(geometry, anchor, viewport, 252);
      expect(placement.x >= 22).assertEqual(true);
      expect(placement.y >= 52).assertEqual(true);
      expect(placement.x + placement.width <= 878).assertEqual(true);
      expect(placement.y + placement.height <= 1068).assertEqual(true);
      expect(selectionPopupOverlapsGeometry(placement, geometry, anchor, viewport, 10)).assertEqual(false);
    });

    it('usesTheOtherColumnWhenVerticalFragmentsBlockAnchorCandidates', 0, () => {
      const viewport: ReaderPopupViewport = { left: 0, top: 0, width: 880, height: 720 };
      const top: ReaderSelectionRect = {
        left: 60, top: 60, width: 250, height: 24, viewportWidth: 880, viewportHeight: 720
      };
      const middle: ReaderSelectionRect = {
        left: 60, top: 300, width: 250, height: 24, viewportWidth: 880, viewportHeight: 720
      };
      const anchor: ReaderSelectionRect = {
        left: 60, top: 590, width: 250, height: 24, viewportWidth: 880, viewportHeight: 720
      };
      const geometry: ReaderSelectionGeometry = { anchor: anchor, fragments: [top, middle, anchor] };
      const placement = placeSelectionPopup(geometry, anchor, viewport, 252);
      expect(placement.x >= 320).assertEqual(true);
      expect(selectionPopupOverlapsGeometry(placement, geometry, anchor, viewport, 10)).assertEqual(false);
    });

    it('fallsBackInsideViewportOnlyWhenSelectionLeavesNoFreePopupArea', 0, () => {
      const viewport: ReaderPopupViewport = { left: 12, top: 24, width: 360, height: 640 };
      const full: ReaderSelectionRect = {
        left: 0, top: 0, width: 360, height: 640, viewportWidth: 360, viewportHeight: 640
      };
      const geometry: ReaderSelectionGeometry = { anchor: full, fragments: [full] };
      const placement = placeSelectionPopup(geometry, full, viewport, 252);
      expect(placement.x >= 24).assertEqual(true);
      expect(placement.y >= 36).assertEqual(true);
      expect(placement.x + placement.width <= 360).assertEqual(true);
      expect(placement.y + placement.height <= 652).assertEqual(true);
      expect(selectionPopupOverlapsGeometry(placement, geometry, full, viewport)).assertEqual(true);
    });
  });
}
