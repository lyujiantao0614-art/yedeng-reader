'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const contracts = [
  'test-reader-panel-hit-test-contract.cjs',
  'test-reader-default-route-contract.cjs',
  'test-local-only-route-contract.cjs',
  'phase33-web-contract-assertions.cjs',
  'test-phase-3-m3-4-batch-ui-contract.cjs',
  'test-phase-3-m3-4-diagnostic-export-contract.cjs',
  'test-current-arkui-api-contract.cjs',
  'test-library-shape-contract.cjs'
];

for (const contract of contracts) {
  const result = spawnSync(process.execPath, [path.join(root, 'tools', contract)], {
    cwd: root,
    stdio: 'inherit'
  });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

console.log(`Public-source contract suite passed (${contracts.length} files).`);
