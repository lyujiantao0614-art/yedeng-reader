'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const baselinePath = path.join(__dirname, 'arkts-warning-baseline.json');
const ansi = /\u001B\[[0-?]*[ -/]*[@-~]/g;

function normalizeSource(value) {
  return value.trim().replace(/\s+/g, ' ');
}

function fingerprint(entry) {
  return crypto.createHash('sha256')
    .update(JSON.stringify([entry.path, entry.warning, entry.source, entry.count]))
    .digest('hex');
}

function parseWarnings(logPath) {
  const log = fs.readFileSync(logPath, 'utf8').replace(ansi, '');
  const expression = /ArkTS:WARN File:\s*([^\r\n]+?):(\d+):(\d+)\r?\n\s*([^\r\n]+)/g;
  const grouped = new Map();
  let match;
  while ((match = expression.exec(log)) !== null) {
    const absolute = match[1].replace(/\\/g, '/');
    const marker = '/entry/src/main/';
    const markerIndex = absolute.toLowerCase().indexOf(marker);
    if (markerIndex < 0) continue;
    const relative = absolute.slice(markerIndex + 1);
    const lineNumber = Number(match[2]);
    const sourcePath = path.join(root, ...relative.split('/'));
    if (!fs.existsSync(sourcePath)) throw new Error(`Warning source does not exist: ${relative}`);
    const lines = fs.readFileSync(sourcePath, 'utf8').split(/\r?\n/);
    const source = normalizeSource(lines[lineNumber - 1] ?? '');
    if (source.length === 0) throw new Error(`Warning source line is empty: ${relative}:${lineNumber}`);
    const warning = normalizeSource(match[4]);
    const key = JSON.stringify([relative, warning, source]);
    const existing = grouped.get(key) ?? { path: relative, warning, source, count: 0 };
    existing.count += 1;
    grouped.set(key, existing);
  }
  return [...grouped.values()]
    .map((entry) => ({ ...entry, fingerprint: fingerprint(entry) }))
    .sort((left, right) => left.path.localeCompare(right.path) ||
      left.source.localeCompare(right.source) || left.warning.localeCompare(right.warning));
}

function readBaseline() {
  if (!fs.existsSync(baselinePath)) throw new Error('ArkTS warning baseline is missing');
  const original = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
  // Keep the SDK21 historical registry intact. Explicit source-only rebases
  // retain each diagnostic/category/count; they cannot add an allowance.
  const rebases = JSON.parse(fs.readFileSync(path.join(__dirname, 'arkts-warning-m4-source-rebase.json'), 'utf8'));
  for (const rebase of rebases.entries) {
    const entry = original.entries.find(item => item.fingerprint === rebase.previousFingerprint);
    assert.ok(entry, 'Unknown original warning in M4 source rebase');
    entry.source = rebase.source;
    entry.fingerprint = fingerprint(entry);
  }
  if (process.env.YEDENG_SDK26_WARNING_GATE !== 'exact-nine') return original;
  const registry = JSON.parse(fs.readFileSync(path.join(__dirname, 'arkts-warning-sdk26.json'), 'utf8'));
  const sdkRoot = process.env.DEVECO_SDK_HOME;
  if (!sdkRoot) throw new Error('Explicit SDK26 root required');
  const metadata = JSON.parse(fs.readFileSync(path.join(sdkRoot, 'default/openharmony/ets/oh-uni-package.json'), 'utf8'));
  assert.equal(metadata.version, registry.sdk);
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(sdkRoot,
    'default/openharmony/ets/api/@ohos.security.cryptoFramework.d.ts'))).digest('hex'), registry.declarationSha256);
  assert.equal(registry.entries.length, 9);
  assert.ok(registry.entries.every(entry => entry.count === 1));
  return { ...original, total: original.total + 9, entries: [...original.entries, ...registry.entries] };
}

function validateBaseline(baseline) {
  assert.equal(baseline.version, 1, 'Unsupported warning baseline version');
  assert.equal(baseline.node, '22.20.0', 'Warning baseline Node version is not pinned to 22.20.0');
  assert.ok(Array.isArray(baseline.entries), 'Warning baseline entries are missing');
  let total = 0;
  const seen = new Set();
  for (const entry of baseline.entries) {
    assert.match(entry.path, /^entry\/src\/main\//, `Non-production warning path: ${entry.path}`);
    assert.ok(Number.isInteger(entry.count) && entry.count > 0, `Invalid warning count: ${entry.path}`);
    assert.ok(!/deprecat/i.test(entry.warning), `Deprecated warning in baseline: ${entry.path}`);
    assert.equal(entry.fingerprint, fingerprint(entry), `Stale warning fingerprint: ${entry.path}`);
    assert.ok(!seen.has(entry.fingerprint), `Duplicate warning fingerprint: ${entry.path}`);
    seen.add(entry.fingerprint);
    const sourcePath = path.join(root, ...entry.path.split('/'));
    assert.ok(fs.existsSync(sourcePath), `Baseline source is missing: ${entry.path}`);
    const currentLines = fs.readFileSync(sourcePath, 'utf8').split(/\r?\n/).map(normalizeSource);
    assert.ok(currentLines.includes(entry.source), `Baseline source line is stale: ${entry.path}`);
    total += entry.count;
  }
  assert.equal(total, baseline.total, 'Warning baseline total does not equal entry counts');
}

function writeBaseline(logPath) {
  const entries = parseWarnings(logPath);
  if (entries.length === 0) throw new Error('No production ArkTS warnings found; refusing to write an empty baseline');
  const baseline = {
    version: 1,
    node: '22.20.0',
    scope: 'entry/src/main',
    policy: 'No new fingerprint, category, deprecation warning, occurrence, or total increase; reductions pass.',
    total: entries.reduce((sum, entry) => sum + entry.count, 0),
    entries
  };
  validateBaseline(baseline);
  fs.writeFileSync(baselinePath, `${JSON.stringify(baseline, null, 2)}\n`, 'utf8');
  console.log(`ArkTS warning baseline written: ${baseline.total} warnings, ${entries.length} fingerprints.`);
}

function checkLog(logPath) {
  const baseline = readBaseline();
  validateBaseline(baseline);
  const current = parseWarnings(logPath);
  const allowed = new Map(baseline.entries.map((entry) => [
    JSON.stringify([entry.path, entry.warning, entry.source]), entry
  ]));
  const failures = [];
  for (const entry of current) {
    if (/deprecat/i.test(entry.warning)) failures.push(`Deprecated warning: ${entry.path} — ${entry.warning}`);
    const key = JSON.stringify([entry.path, entry.warning, entry.source]);
    const expected = allowed.get(key);
    if (!expected) failures.push(`New warning fingerprint: ${entry.path} — ${entry.warning} — ${entry.source}`);
    else if (entry.count > expected.count) failures.push(`Warning occurrence increased: ${entry.path} (${expected.count} -> ${entry.count})`);
  }
  const total = current.reduce((sum, entry) => sum + entry.count, 0);
  if (total > baseline.total) failures.push(`Warning total increased: ${baseline.total} -> ${total}`);
  if (failures.length > 0) {
    console.error('ArkTS warning budget failed:');
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
  console.log(`ArkTS warning budget passed: ${total}/${baseline.total} warnings, ${current.length}/${baseline.entries.length} fingerprints.`);
}

const args = process.argv.slice(2);
if (args[0] === '--write-baseline') {
  if (!args[1]) throw new Error('Usage: check-arkts-warning-budget.cjs --write-baseline <build-log>');
  writeBaseline(path.resolve(args[1]));
} else if (args.length === 1) {
  checkLog(path.resolve(args[0]));
} else if (args.length === 0) {
  const baseline = readBaseline();
  validateBaseline(baseline);
  console.log(`ArkTS warning baseline contract passed (${baseline.total} warnings, ${baseline.entries.length} fingerprints).`);
} else {
  throw new Error('Usage: check-arkts-warning-budget.cjs [<build-log> | --write-baseline <build-log>]');
}
