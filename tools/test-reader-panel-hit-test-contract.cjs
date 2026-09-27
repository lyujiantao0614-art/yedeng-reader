const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const readerPage = fs.readFileSync(
  path.join(root, 'entry', 'src', 'main', 'ets', 'pages', 'ReaderPage.ets'), 'utf8');
const buildStart = readerPage.indexOf('  build() {');
const scrimStart = readerPage.indexOf(
  "if (this.currentSurface === 'toc' || this.currentSurface === 'appearance')", buildStart);
const tocStart = readerPage.indexOf("if (this.currentSurface === 'toc') {", scrimStart);
const appearanceStart = readerPage.indexOf(
  "if (this.currentSurface === 'appearance') {", tocStart);
const errorStart = readerPage.indexOf('if (this.errorText.length > 0)', appearanceStart);

assert(buildStart >= 0 && scrimStart > buildStart && tocStart > scrimStart &&
  appearanceStart > tocStart && errorStart > appearanceStart,
  'Reader panel regions must remain discoverable');

const scrim = readerPage.slice(scrimStart, tocStart);
const tocPanel = readerPage.slice(tocStart, appearanceStart);
const appearancePanel = readerPage.slice(appearanceStart, errorStart);

assert.doesNotMatch(scrim, /&&\s*!this\.isSideReaderPanel\(\)/,
  'Side Reader panels must retain an outside-tap owner');
assert.match(scrim, /isSideReaderPanel\(\)\s*\?\s*Color\.Transparent/,
  'The side-panel outside-tap owner must remain visually transparent');
assert.match(scrim, /hitTestBehavior\(HitTestMode\.Block\)/,
  'The full-screen scrim must consume outside taps');
assert.match(scrim, /dismissReaderPanel\(true\)/,
  'The full-screen scrim must dismiss the active Reader panel and return focus');
assert.match(tocPanel, /ListItem\(\)[\s\S]*?onClick\([\s\S]*?controller\.goToChapter/,
  'TOC items must retain their chapter action');
assert.match(tocPanel, /hitTestBehavior\(HitTestMode\.Default\)/,
  'The TOC panel must allow child items to receive taps');
assert.doesNotMatch(tocPanel, /hitTestBehavior\(HitTestMode\.Block\)/,
  'The TOC panel must not block its child items');
assert.match(tocPanel, /height\(this\.isSideReaderPanel\(\)\s*\?\s*['"]auto['"]/,
  'The side TOC panel must fit its content');
assert.match(tocPanel,
  /layoutGravity\(this\.isSideReaderPanel\(\)\s*\?\s*LocalizedAlignment\.TOP_END\s*:\s*LocalizedAlignment\.CENTER\)/,
  'The TOC panel must use Stack child gravity for side placement');
assert.match(tocPanel, /maxHeight:[\s\S]*?readerViewportHeightVp\(\)\s*-\s*32/,
  'The expanded TOC panel must remain bounded by the Reader viewport');
assert.match(appearancePanel,
  /reader-font-scale-decrease[\s\S]*?reader-line-spacing-decrease[\s\S]*?reader-page-margin-decrease[\s\S]*?reader-theme-eye-comfort/,
  'Appearance controls must remain present');
assert.match(appearancePanel, /hitTestBehavior\(HitTestMode\.Default\)/,
  'The appearance panel must allow child controls to receive taps');
assert.doesNotMatch(appearancePanel, /hitTestBehavior\(HitTestMode\.Block\)/,
  'The appearance panel must not block its child controls');
assert.match(appearancePanel, /height\(this\.isSideReaderPanel\(\)\s*\?\s*['"]auto['"]/,
  'The side appearance panel must fit its content');
assert.match(appearancePanel,
  /layoutGravity\(this\.isSideReaderPanel\(\)\s*\?\s*LocalizedAlignment\.TOP_END\s*:\s*LocalizedAlignment\.CENTER\)/,
  'The appearance panel must use Stack child gravity for side placement');
assert.match(appearancePanel, /maxHeight:[\s\S]*?readerViewportHeightVp\(\)\s*-\s*32/,
  'The expanded appearance panel must remain bounded by the Reader viewport');

console.log('Reader panel hit-test contract passed.');
