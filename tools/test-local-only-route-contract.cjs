'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

const manifest = read('entry/src/main/module.json5');
const runtime = read('entry/src/main/ets/application/ApplicationRuntime.ets');
const index = read('entry/src/main/ets/pages/Index.ets');
const settings = read('entry/src/main/ets/pages/SettingsPage.ets');
const reader = read('entry/src/main/ets/pages/ReaderPage.ets');
const dictionary = read('entry/src/main/ets/components/DictionarySheet.ets');
const passage = read('entry/src/main/ets/components/PassageActionSheet.ets');
const surfaces = read('entry/src/main/ets/reader/ReaderSurfaceState.ets');
const ability = read('entry/src/main/ets/entryability/EntryAbility.ets');
const strings = JSON.parse(read('entry/src/main/resources/base/element/string.json')).string;

assert.doesNotMatch(manifest, /ohos\.permission\.INTERNET|requestPermissions/);
assert.doesNotMatch(runtime, /AISettings|AIHttp|CredentialStore|NetworkKit/);
assert.doesNotMatch(index, /aiSettings|AIReadingActionSession|aiEnabled/);
assert.doesNotMatch(settings, /AISettingsPage|AISettingsActions|settings-section-ai|openRoute\('ai'\)/);
assert.doesNotMatch(reader, /AIReading|aiEnabled|reader-ai-cover|onTranslate|onAsk|onExplainContext/);
assert.doesNotMatch(dictionary, /aiEnabled|reader-dictionary-context|onExplainContext/);
assert.doesNotMatch(passage, /aiEnabled|reader-passage-translate|reader-passage-ask/);
assert.doesNotMatch(surfaces, /question|ai-result|translate/);
assert.doesNotMatch(ability, /aiRequestLifecycle|aiQuestionKeyboardLifecycle/);
assert.ok(strings.every(({ name }) => !/^(ai_|reader_ai_|settings_ai_)/.test(name)));

for (const retained of ['dictionaryService', 'bookmarks', 'textMarks', 'onExit']) {
  assert.ok(reader.includes(retained), `Local Reader lost ${retained}`);
}
assert.match(settings, /settings-section-privacy/);
assert.match(read('docs/public/privacy-policy/index.html'), /不申请互联网权限/);
const hostedPolicy = read('docs/public/privacy-policy/yedeng-privacy-policy.md');
const bundledPolicy = read('entry/src/main/resources/rawfile/privacy/yedeng-privacy-policy.txt');
const expectedBundledPolicy = hostedPolicy.replace(/^#{1,2} /gm, '')
  .replace(/\[([^\]]+)\]\(mailto:[^)]+\)/g, '$1');
assert.equal(bundledPolicy, expectedBundledPolicy, 'Bundled policy must match the hosted text');
assert.match(settings, /https:\/\/litepage\.cn\/s\/yedeng\/yedeng-privacy-policy/);
assert.match(index, /this\.preparePrivacy\(\)/);
assert.match(index, /if \(this\.privacyStatus !== 'accepted'\)/);
assert.match(index, /if \(this\.privacyStatus === 'accepted'\) this\.startRuntime\(\)/);
assert.match(index, /privacy-read-policy/);
assert.match(index, /privacy-accept/);
assert.match(index, /privacy-decline/);
const consent = read('entry/src/main/ets/application/PrivacyConsentApplication.ets');
assert.ok(consent.includes(`'2026-09-28'`));
assert.ok(hostedPolicy.includes('更新日期：2026 年 9 月 28 日'));
console.log('Local-only product route source contract passed.');
