const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const reader = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ReaderPage.ets'), 'utf8');
const settings = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/SettingsPage.ets'), 'utf8');
const policy = fs.readFileSync(path.join(root, 'entry/src/main/ets/domain/AppearancePolicy.ets'), 'utf8');
const motionBody = policy.match(/export function animateReaderMotion\(systemReduced\?: boolean\): boolean \{([^}]+)\}/);
assert(motionBody, 'Only the observed system signal controls the motion policy');
const animate = new Function('systemReduced', motionBody[1]);
assert.equal(animate(true), false); assert.equal(animate(false), true); assert.equal(animate(undefined), true);
assert.doesNotMatch(reader, /\.motionPreference\(|\.saveMotionPreference\(/, 'Legacy values cannot control production Reader');
assert.doesNotMatch(settings, /settings-motion|setMotion\(|motionPreference|saveMotionPreference/, 'No application motion setting or save path');
const buildStart = reader.indexOf('  build() {');
const scrimStart = reader.indexOf("if (this.isAuxiliaryPanel() && !this.isNativeReaderSheet(this.currentSurface)", buildStart);
const errorStart = reader.indexOf('if (this.errorText.length > 0)', scrimStart);
const contentStart = reader.indexOf('  private auxiliaryContent()');
const panelStart = reader.indexOf('  private auxiliaryPanel()');
assert(buildStart > 0 && scrimStart > buildStart && errorStart > scrimStart && contentStart > 0 && panelStart > contentStart,
  'The shared B panel and actual content must be discoverable');
const scrim = reader.slice(scrimStart, errorStart);
const content = reader.slice(contentStart, panelStart);
const panel = reader.slice(panelStart, buildStart);
assert.match(scrim, /isSideReaderPanel\(\)\s*\?\s*Color\.Transparent/);
assert.match(scrim, /hitTestBehavior\(HitTestMode\.Block\)/, 'Outside taps are consumed on wide and narrow windows');
assert.match(scrim, /dismissReaderPanel\(true\)/, 'Outside close returns focus to the actual trigger');
assert.match(panel, /hitTestBehavior\(HitTestMode\.Default\)/, 'The panel passes taps to child actions');
assert.doesNotMatch(panel, /HitTestMode\.Block/);
assert.match(reader, /CustomContentDialog\([\s\S]*?contentBuilder:.*markDetailContent/);
assert.match(reader, /id\('reader-note-entries'\)[^\n]*(?:\r?\n\s*)?\.constraintSize\(/);
assert.match(reader, /confirmNoteDeletion\(note/);
assert.match(panel, /height\(this\.panelHeight\(\)\)/, 'Overlay height remains bounded independently of the Web viewport');
assert.match(panel, /layoutGravity\(this\.isSideReaderPanel\(\) \? LocalizedAlignment\.TOP_END : LocalizedAlignment\.BOTTOM\)/);
assert.match(reader, /private panelWidth\(\)[^\n]*readerViewportWidthVp/);
assert.match(reader, /private panelHeight\(\)[^\n]*readerViewportHeightVp/);
assert.match(content, /ListItem\(\)[\s\S]*?controller\.goToChapter\(chapter\.href\)/, 'TOC keeps the real engine command');
assert.match(reader.slice(reader.indexOf('  private appearanceContent()'), contentStart), /'reader-font-scale'[\s\S]*'reader-line-spacing'[\s\S]*'reader-page-margin'[\s\S]*reader-theme-eye-comfort/);
assert.match(reader, /ReaderFourSurfaceView\([\s\S]*?height\(this\.readerPublicationHeightVp\(\)\)/);
assert.doesNotMatch(reader.slice(reader.indexOf('  private readerPublicationHeightVp()'), reader.indexOf('  private readerPublicationHeightVp()') + 400), /controlsVisible|currentSurface/,
  'Panel/chrome visibility must not choose the publication viewport height');
assert.equal((reader.match(/@State (?:@Watch\('[^']+'\) )?private currentSurface:/g) ?? []).length, 1, 'Only one current auxiliary layer');
assert.match(reader, /KEYCODE_F8[^\n]*currentSurface === 'note-editor'/, 'F8 does not take input editor keys');
console.log('B shared Reader panel hit-test/viewport contract passed; actual ArkWeb/device evidence is separate.');

assert.match(reader, /bindSheet\(\$\$this\.readerSheetVisible/);
assert.match(reader, /surface === 'progress' \|\| \(\(surface === 'toc' \|\| surface === 'notes' \|\| surface === 'appearance'\) && !this\.isSideReaderPanel\(\)\)/,
  'Compact progress and narrow TOC share native ownership; wide TOC retains its sidebar');
assert.doesNotMatch(reader, /readerSheetSurface === 'bookmarks' \? SheetSize\.LARGE/);
assert.match(reader, /panelRecords\('bookmarks'\)/);
assert.match(reader, /panelRecords\('notes'\)/);
assert.match(reader, /\.initialOffset\(\{ xOffset: 0, yOffset: this\.notesInitialOffset \}\)/);
assert.match(reader, /readerSheetSurface !== 'none' && this\.readerSheetSurface !== this\.currentSurface/,
  'A native surface handoff waits for the outgoing layer');
assert.match(reader, /onWillDismiss:[\s\S]*requestCloseNoteEditor\(\(\): void => action\.dismiss\(\)\)/);
assert.doesNotMatch(reader, /reader-mark-scrim|noteEditorTopVp/);
assert.match(reader, /if \(surface === 'toc' && !this\.isSideReaderPanel\(\)\) this\.prepareTocInitialOffset\(\)/);
assert.match(reader, /\.initialOffset\(\{ xOffset: 0, yOffset: this\.tocInitialOffset \}\)/);
assert.doesNotMatch(reader, /positionTocChapter|tocScroller|tocCurrentOffset|tocPositioned/,
  'TOC must not jump with a measured callback after the native sheet starts appearing');
