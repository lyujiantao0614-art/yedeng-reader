'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname,
  '../entry/src/main/ets/platform/NativeOverlayMaterial.ets'), 'utf8');
// Execute the actual adapter with controlled Kit/module boundaries, as other
// project source tests do. This does not claim native rendering or API21 device coverage.
const importLine = "const module = await import('@ohos.arkui.uiMaterial');";
assert.equal(source.split(importLine).length - 1, 1);
const script = ts.transpileModule(source.replace(/import deviceInfo[^\n]*\n/, '')
  .replace(importLine, 'const module = await loadMaterial();'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 }, reportDiagnostics: true
});
assert.ok(!script.diagnostics.some(d => d.category === ts.DiagnosticCategory.Error));

async function run() {
  for (const [api, available, supported, enabled] of [
    [21, true, true, false], [25, true, true, false],
    [26, false, true, false], [26, true, false, false], [26, true, true, true]
  ]) {
    let loads = 0, calls = 0;
    const exports = {};
    const native = {
      isImmersiveMaterialSupported: () => supported,
      ImmersiveStyle: { THICK: 3, ULTRA_THICK: 4 },
      ImmersiveMaterial: class { constructor(options) { this.style = options.style; } }
    };
    vm.runInNewContext(script.outputText, { exports, Promise,
      deviceInfo: { sdkApiVersion: api, apiAvailable: v => { assert.equal(v, '26.0.0'); return available; } },
      loadMaterial: async () => { loads++; return { default: native }; }
    });
    const materials = await exports.loadNativeOverlayMaterials();
    assert.equal(loads, api >= 26 && available ? 1 : 0);
    assert.equal(materials.menu !== undefined, enabled);
    assert.equal(materials.panel !== undefined, enabled);
    if (enabled) { assert.equal(materials.menu.style, 3); assert.equal(materials.panel.style, 4); }
    const material = {}; // Even a supplied object must not invoke an unavailable API.
    new exports.NativeSelectMenuMaterial(material).applyNormalAttribute({
      menuSystemMaterial: value => { assert.equal(value, material); calls++; }
    });
    assert.equal(calls, api >= 26 && available ? 1 : 0);
    for (const name of ['nativeMenuOptions', 'nativeAlertOptions', 'nativeSheetOptions']) {
      const callback = () => {}, button = { value: 'Delete', role: 'error', action: callback };
      const options = { onDisappear: callback, height: 200, secondaryButton: button, autoCancel: false };
      const result = exports[name](material, options);
      assert.equal(result, options);
      assert.equal(result.onDisappear, callback);
      assert.equal(result.height, 200);
      assert.equal(result.secondaryButton, button);
      assert.equal(result.secondaryButton.role, 'error');
      assert.equal(result.secondaryButton.action, callback);
      assert.equal(result.autoCancel, false);
      assert.equal(Object.hasOwn(result, 'systemMaterial'), api >= 26 && available);
      assert.equal(Object.hasOwn(exports[name](undefined, {}), 'systemMaterial'), false);
    }
  }
  console.log('Native overlay adapter PASS: API21/25 no module import or new native call; API26 unavailable/unsupported fallback; supported styles and callbacks preserved. SDK/device separate.');
}
run().catch(error => { console.error(error); process.exitCode = 1; });
