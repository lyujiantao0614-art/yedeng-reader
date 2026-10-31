'use strict';
const path=require('node:path');
const {spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const contracts=[
  "test-m4-library-grid.cjs",
  "test-m4-library-browse.cjs",
  "test-reading-records.cjs",
  "test-m4-interaction-feedback.cjs",
  "test-m4-reading-stability.cjs",
  "test-m4-non-reading-motion.cjs",
  "test-bookmark-navigation.cjs",
  "test-m3-record-routing.cjs",
  "test-m4-import-target.cjs",
  "test-native-overlay-material.cjs",
  "test-m4-mine.cjs",
  "test-book-layout-overrides.cjs",
  "test-b3-pagination-entry.cjs",
  "test-reader-panel-hit-test-contract.cjs",
  "test-reader-default-route-contract.cjs",
  "test-local-only-route-contract.cjs",
  "test-current-arkui-api-contract.cjs",
  "test-m4-e1-tablet-fixes.cjs"
];
for(const name of contracts){
 console.log('RUN '+name);
 const result=spawnSync(process.execPath,[path.join(root,'tools',name)],{cwd:root,stdio:'inherit'});
 if(result.error)throw result.error;
 if(result.status!==0)process.exit(result.status??1);
}
console.log('Public-source contracts passed ('+contracts.length+' entrypoints); SDK/device evidence remains separate.');
