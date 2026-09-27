(function (root, factory) {
  'use strict';
  var contract = factory();
  if (typeof module === 'object' && module && module.exports) module.exports = contract;
  else root.HarmonyReaderLayoutContract = contract;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  var COLUMN_MODE_AUTO = 'auto';
  var COLUMN_MODE_SINGLE = 'single';
  var MAX_LOCATOR_FIELD_LENGTH = 4096;
  var MAX_LOCATOR_ENVELOPE_LENGTH = 16384;
  var MAX_HREF_LENGTH = 2048;
  var MAX_DISPLAYED_PAGE = 10000;

  function boundedNumber(value, fallback, minimum, maximum) {
    var number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.min(maximum, Math.max(minimum, number));
  }

  function normalizeColumnMode(value) {
    return value === COLUMN_MODE_SINGLE ? COLUMN_MODE_SINGLE : COLUMN_MODE_AUTO;
  }

  function minimumSpreadWidth(settings) {
    var value = settings && typeof settings === 'object' ? settings : {};
    var fontScale = boundedNumber(value.fontScale, 1, 0.8, 1.6);
    var pageMarginVp = boundedNumber(value.pageMarginVp, 20, 8, 40);
    var pageGap = pageMarginVp * 2;
    var minimumColumnWidth = Math.max(315, 300 * fontScale);
    return Math.ceil(2 * (minimumColumnWidth + pageGap));
  }

  function surfaceColumnGeometry(viewportWidth, settings) {
    var value = settings && typeof settings === 'object' ? settings : {};
    var gap = Math.round(boundedNumber(value.pageMarginVp, 20, 8, 40) * 2);
    var dual = value.columnMode !== COLUMN_MODE_SINGLE && viewportWidth >= minimumSpreadWidth(value);
    return {
      width: dual ? (viewportWidth - 2 * gap) / 2 : viewportWidth - gap,
      gap: gap
    };
  }

  function displayedPart(location, edge) {
    var part = location && location[edge] ? location[edge] : {};
    var displayed = part.displayed || {};
    return {
      href: String(part.href || ''),
      page: Number(displayed.page),
      total: Number(displayed.total)
    };
  }

  function pageIsVisible(location, href, page) {
    var targetHref = String(href || '');
    var targetPage = Number(page);
    var start = displayedPart(location, 'start');
    var end = displayedPart(location, 'end');
    if (!Number.isFinite(targetPage) || targetPage < 1) return false;
    if (targetHref && start.href !== targetHref && end.href !== targetHref) return false;
    if (!Number.isFinite(start.page) || !Number.isFinite(end.page)) return false;
    return targetPage >= Math.min(start.page, end.page) && targetPage <= Math.max(start.page, end.page);
  }

  function canNavigatePage(location, hasPreviousSpine, hasNextSpine, direction) {
    if (direction < 0) {
      if (location && location.atStart === true) return false;
      var start = displayedPart(location, 'start');
      return Number.isFinite(start.page) && Number.isFinite(start.total) && start.total > 0 &&
        (start.page > 1 || !!hasPreviousSpine);
    }
    if (direction > 0) {
      if (location && location.atEnd === true) return false;
      var end = displayedPart(location, 'end');
      return Number.isFinite(end.page) && Number.isFinite(end.total) && end.total > 0 &&
        (end.page < end.total || !!hasNextSpine);
    }
    return false;
  }

  function readingLocator(location) {
    var start = location && location.start ? location.start : {};
    var displayed = start.displayed || {};
    var page = Number(displayed.page);
    return JSON.stringify({
      version: 1,
      cfi: String(start.cfi || '').slice(0, MAX_LOCATOR_FIELD_LENGTH),
      href: String(start.href || '').slice(0, MAX_HREF_LENGTH - 1),
      page: Number.isFinite(page) && page >= 1 ? Math.min(MAX_DISPLAYED_PAGE, Math.floor(page)) : 1
    });
  }

  function parseReadingLocator(value) {
    if (typeof value !== 'string' || value.length === 0 || value.length > MAX_LOCATOR_ENVELOPE_LENGTH) {
      return { cfi: '', href: '', page: 1 };
    }
    if (value.charAt(0) !== '{') {
      return value.length <= MAX_LOCATOR_FIELD_LENGTH ?
        { cfi: value, href: '', page: 1 } : { cfi: '', href: '', page: 1 };
    }
    try {
      var parsed = JSON.parse(value);
      var page = Number(parsed.page);
      return {
        cfi: typeof parsed.cfi === 'string' && parsed.cfi.length <= MAX_LOCATOR_FIELD_LENGTH ? parsed.cfi : '',
        href: typeof parsed.href === 'string' && parsed.href.length < MAX_HREF_LENGTH ? parsed.href : '',
        page: Number.isFinite(page) && page >= 1 && page <= MAX_DISPLAYED_PAGE ? Math.floor(page) : 1
      };
    } catch (_) {
      return { cfi: '', href: '', page: 1 };
    }
  }

  function restoreTargetOrder(value) {
    var saved = parseReadingLocator(value);
    var targets = [];
    if (saved.cfi) targets.push({ kind: 'cfi', value: saved.cfi, page: 1 });
    if (saved.href) targets.push({ kind: 'href-page', value: saved.href, page: saved.page });
    if (targets.length === 0) targets.push({ kind: 'start', value: '', page: 1 });
    return targets;
  }

  return Object.freeze({
    COLUMN_MODE_AUTO: COLUMN_MODE_AUTO,
    COLUMN_MODE_SINGLE: COLUMN_MODE_SINGLE,
    MAX_LOCATOR_FIELD_LENGTH: MAX_LOCATOR_FIELD_LENGTH,
    MAX_LOCATOR_ENVELOPE_LENGTH: MAX_LOCATOR_ENVELOPE_LENGTH,
    normalizeColumnMode: normalizeColumnMode,
    minimumSpreadWidth: minimumSpreadWidth,
    surfaceColumnGeometry: surfaceColumnGeometry,
    pageIsVisible: pageIsVisible,
    canNavigatePage: canNavigatePage,
    readingLocator: readingLocator,
    parseReadingLocator: parseReadingLocator,
    restoreTargetOrder: restoreTargetOrder
  });
});
