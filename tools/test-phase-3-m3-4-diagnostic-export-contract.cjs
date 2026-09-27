'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8');

const contract = read('entry/src/main/ets/diagnostics/DiagnosticExportContract.ets');
const diagnostics = read('entry/src/main/ets/diagnostics/ReaderOpenDiagnostics.ets');
const destination = read('entry/src/main/ets/services/DiagnosticFileExport.ets');
const application = read('entry/src/main/ets/application/DiagnosticExportApplication.ets');
const runtime = read('entry/src/main/ets/application/ApplicationRuntime.ets');
const settings = read('entry/src/main/ets/pages/SettingsPage.ets');
const strings = read('entry/src/main/resources/base/element/string.json');

assert.match(contract, /DIAGNOSTIC_MAX_BYTES:\s*number\s*=\s*64\s*\*\s*1024/);
assert.match(contract, /DIAGNOSTIC_MAX_SUMMARIES:\s*number\s*=\s*128/);
assert.match(contract, /schemaVersion:[\s\S]*appVersion:[\s\S]*api:[\s\S]*deviceClass:[\s\S]*buildMode:[\s\S]*truncated:[\s\S]*errorCounts:[\s\S]*timingSummaries:/);
for (const prohibited of ['title:', 'author:', 'bookId:', 'path:', 'uri:', 'endpoint:', 'model:', 'credential:', 'selection:', 'locator:']) {
  assert.equal(contract.includes(prohibited), false, `Diagnostic encoder exposes prohibited field ${prohibited}`);
}
assert.match(diagnostics, /summaries\.length\s*>\s*DIAGNOSTIC_MAX_SUMMARIES/);
assert.match(diagnostics, /clearExportSnapshot\(\): void/);
assert.match(application, /finally\s*\{[\s\S]*bytes\.fill\(0\)[\s\S]*clearExportSnapshot\(\)/);
assert.match(destination, /DocumentViewPicker\(this\.context\)\.save/);
assert.match(destination, /finally\s*\{[\s\S]*fileSurface\.close\(fd\)/);
assert.equal(/\.unlink\(/.test(destination), false, 'Production export must not delete an unknown user destination');
assert.match(runtime, /new DiagnosticExportApplication\([\s\S]*readerOpenDiagnostics[\s\S]*new DiagnosticFileExport/);
assert.match(settings, /id\('settings-diagnostic-export'\)/);
for (const phrase of ['导出诊断信息', '不会包含书名', '不会上传', '可能是不完整文件']) {
  assert.ok(strings.includes(phrase), `Diagnostic product copy is missing: ${phrase}`);
}

console.log('Phase 3 Milestone 3.4 diagnostic export source contract passed.');
