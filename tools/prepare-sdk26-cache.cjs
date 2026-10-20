'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const root = path.resolve(__dirname, '..');
const tool = path.resolve(process.argv[2], 'hvigor');
// Wrapper performs its package-manager preflight even when vendor packages are cached.
// Reuse the already installed, approved pnpm cache; never fetch a second runtime.
const home = path.join(root, '.hvigor/major-development/sdk26-main-user-home');
const manager = path.join(home, 'wrapper/tools/10.28.2/node_modules');
if (!fs.existsSync(path.join(manager, 'pnpm/bin/pnpm.cjs'))) {
  const configured = process.env.YEDENG_HVIGOR_CACHE;
  if (!configured) throw new Error('Provide -HvigorCache for an already configured SDK26 Hvigor user-home, or build in DevEco Studio.');
  const installed = path.join(path.resolve(configured), 'wrapper/tools/10.28.2/node_modules');
  if (!fs.existsSync(path.join(installed, 'pnpm/bin/pnpm.cjs'))) throw new Error('Installed approved pnpm cache unavailable');
  fs.mkdirSync(path.dirname(manager), { recursive: true });
  fs.symlinkSync(installed, manager, 'junction');
}
for (const name of ['hvigor', 'hvigor-ohos-plugin']) {
  const vendor = path.join(tool, name);
  const metadata = JSON.parse(fs.readFileSync(path.join(vendor, 'package.json'), 'utf8'));
  if (metadata.version !== '6.26.8') throw new Error('Approved bundled Hvigor/plugin 6.26.8 required');
  const key = crypto.createHash('sha256').update(root + ':6.26.8').digest('hex').slice(0, 32);
  const workspace = path.join(root, '.hvigor/major-development/sdk26-main-user-home/project_caches', key,
    'workspace/node_modules/@ohos');
  fs.mkdirSync(workspace, { recursive: true });
  const link = path.join(workspace, name);
  if (fs.existsSync(link)) {
    if (fs.realpathSync(link) !== fs.realpathSync(vendor)) throw new Error('SDK26 cache package differs');
  } else fs.symlinkSync(vendor, link, 'junction');
}
console.log('SDK26 project cache uses installed bundled packages; no dependency download.');
