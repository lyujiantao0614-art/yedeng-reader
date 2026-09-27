(function (root, factory) {
  'use strict';
  var contract = factory();
  if (typeof module === 'object' && module && module.exports) module.exports = contract;
  else root.HarmonyReaderNavigationContract = contract;
})(typeof globalThis === 'object' ? globalThis : this, function () {
  'use strict';

  var MAX_LINK_LENGTH = 2048;
  var MAX_RETURN_LOCATOR_LENGTH = 16384;
  var MAX_RETURN_DEPTH = 16;
  var MAX_SELECTION_FRAGMENTS = 64;
  var TOUCH_CLICK_GUARD_MS = 700;

  function hasToken(value, token) {
    return String(value || '').toLowerCase().split(/\s+/).indexOf(token) >= 0;
  }

  function normalizeInternalPath(path) {
    var segments = String(path || '').split('/');
    var normalized = [];
    for (var index = 0; index < segments.length; index += 1) {
      var segment = segments[index];
      if (!segment || segment === '.') continue;
      if (segment === '..') {
        if (normalized.length === 0) return '';
        normalized.pop();
      } else {
        normalized.push(segment);
      }
    }
    return normalized.join('/');
  }

  function classifyLink(rawHref, currentHref, epubType, role) {
    if (typeof rawHref !== 'string') return { type: 'invalid', href: '' };
    var href = rawHref.trim();
    if (href.length === 0 || href.length >= MAX_LINK_LENGTH || /[\u0000-\u001f\\]/.test(href)) {
      return { type: 'invalid', href: '' };
    }
    if (/^https?:\/\//i.test(href)) return { type: 'external', href: href };
    if (/^(?:[a-z][a-z0-9+.-]*:|\/\/|\/)/i.test(href) || /%(?:2e|2f|5c)/i.test(href)) {
      return { type: 'invalid', href: '' };
    }

    var hashIndex = href.indexOf('#');
    var relativePath = hashIndex >= 0 ? href.slice(0, hashIndex) : href;
    var fragment = hashIndex >= 0 ? href.slice(hashIndex) : '';
    var currentPath = String(currentHref || '').split('#')[0].split('?')[0];
    var baseSegments = currentPath.split('/');
    baseSegments.pop();
    var combined = relativePath ? baseSegments.concat(relativePath.split('/')).join('/') : currentPath;
    var normalized = normalizeInternalPath(combined);
    if (!normalized) return { type: 'invalid', href: '' };
    var footnote = hasToken(epubType, 'noteref') || hasToken(role, 'doc-noteref');
    return { type: 'internal', href: normalized + fragment, kind: footnote ? 'footnote' : 'internal' };
  }

  function validReturnEntry(entry) {
    return entry && typeof entry.locator === 'string' && entry.locator.length > 0 &&
      entry.locator.length <= MAX_RETURN_LOCATOR_LENGTH &&
      (entry.kind === undefined || entry.kind === 'internal' || entry.kind === 'footnote');
  }

  function createReturnStack(maximumDepth) {
    var parsedDepth = Number(maximumDepth);
    var limit = Number.isSafeInteger(parsedDepth) && parsedDepth > 0 ?
      Math.min(MAX_RETURN_DEPTH, parsedDepth) : MAX_RETURN_DEPTH;
    var entries = [];
    return Object.freeze({
      push: function (entry) {
        if (!validReturnEntry(entry)) return false;
        if (entries.length === limit) entries.shift();
        entries.push({ locator: entry.locator, kind: entry.kind });
        return true;
      },
      pop: function () {
        var entry = entries.pop();
        return entry ? { locator: entry.locator, kind: entry.kind } : undefined;
      },
      peek: function () {
        var entry = entries.length > 0 ? entries[entries.length - 1] : undefined;
        return entry ? { locator: entry.locator, kind: entry.kind } : undefined;
      },
      clear: function () { entries = []; },
      size: function () { return entries.length; },
      canReturn: function () { return entries.length > 0; }
    });
  }

  function keyboardAction(key, editable, hasSelection, altKey, ctrlKey, metaKey, shiftKey) {
    if (editable || hasSelection || altKey || ctrlKey || metaKey || shiftKey) return 'none';
    if (key === 'ArrowLeft' || key === 'PageUp') return 'previous-page';
    if (key === 'ArrowRight' || key === 'PageDown' || key === ' ') return 'next-page';
    if (key === 'Escape') return 'back';
    return 'none';
  }

  function readerClickAction(ratio, button, hasSelection, isLink) {
    if (button !== 0 || hasSelection || isLink || !Number.isFinite(ratio)) return 'none';
    if (ratio < 0.28) return 'previous-page';
    if (ratio > 0.72) return 'next-page';
    return 'toggle-controls';
  }

  function suppressClickAfterTouch(lastTouchAt, currentTime, guardMs) {
    var guard = Number.isFinite(guardMs) && guardMs > 0 ? guardMs : TOUCH_CLICK_GUARD_MS;
    return Number.isFinite(lastTouchAt) && lastTouchAt > 0 && Number.isFinite(currentTime) &&
      currentTime >= lastTouchAt && currentTime - lastTouchAt <= guard;
  }

  function finiteRect(rect, viewportWidth, viewportHeight) {
    if (!rect) return undefined;
    var values = [rect.left, rect.top, rect.width, rect.height, viewportWidth, viewportHeight];
    if (!values.every(function (value) { return typeof value === 'number' && Number.isFinite(value); }) ||
      rect.width <= 0 || rect.height <= 0 || viewportWidth <= 0 || viewportHeight <= 0 ||
      viewportWidth > 10000 || viewportHeight > 10000 || rect.left < -1 || rect.top < -1 ||
      rect.left + rect.width > viewportWidth + 1 || rect.top + rect.height > viewportHeight + 1) {
      return undefined;
    }
    return {
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight
    };
  }

  function boundedFragments(rects) {
    if (rects.length <= MAX_SELECTION_FRAGMENTS) return rects;
    return rects.slice(0, MAX_SELECTION_FRAGMENTS - 1).concat(rects[rects.length - 1]);
  }

  function normalizeSelectionGeometry(fragmentRects, anchorRect, viewportWidth, viewportHeight) {
    if (!Array.isArray(fragmentRects)) return undefined;
    var fragments = boundedFragments(fragmentRects.map(function (rect) {
      return finiteRect(rect, viewportWidth, viewportHeight);
    }).filter(Boolean));
    if (fragments.length === 0) return undefined;
    var anchor = finiteRect(anchorRect, viewportWidth, viewportHeight) || fragments[fragments.length - 1];
    return { anchor: anchor, fragments: fragments };
  }
  function exactSelectionMatches(expectedText, expectedCharacterCount, actualText) {
    return typeof expectedText === 'string' && expectedText.length > 0 && expectedText.length <= 4000 &&
      Number.isSafeInteger(expectedCharacterCount) && expectedCharacterCount === expectedText.length &&
      typeof actualText === 'string' && actualText.trim() === expectedText;
  }

  function relocationSelectionAction(cause, hadSelection, selectionRestored) {
    if (cause === 'navigation') return 'clear';
    if (cause !== 'layout') return 'clear';
    if (hadSelection && !selectionRestored) return 'clear';
    return 'preserve';
  }


  return Object.freeze({
    MAX_RETURN_DEPTH: MAX_RETURN_DEPTH,
    MAX_SELECTION_FRAGMENTS: MAX_SELECTION_FRAGMENTS,
    TOUCH_CLICK_GUARD_MS: TOUCH_CLICK_GUARD_MS,
    classifyLink: classifyLink,
    createReturnStack: createReturnStack,
    keyboardAction: keyboardAction,
    readerClickAction: readerClickAction,
    suppressClickAfterTouch: suppressClickAfterTouch,
    normalizeSelectionGeometry: normalizeSelectionGeometry,
    exactSelectionMatches: exactSelectionMatches,
    relocationSelectionAction: relocationSelectionAction
  });
});
