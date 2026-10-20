'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const ts=require('typescript');
const read=p=>fs.readFileSync(p,'utf8');
const method=(s,a,b)=>s.slice(s.indexOf(a),s.indexOf(b,s.indexOf(a)));
function run(s){const exports={};vm.runInNewContext(ts.transpileModule(s,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,{exports});return exports;}
const settings=read('entry/src/main/ets/pages/SettingsPage.ets');
const H=run('export class H {'+method(settings,'  private setLayout(', '  private setControls(')+
  method(settings,'  private save(', '  private setInterfaceMode(')+'}').H;
const initial={fontScale:1,lineSpacing:1.5,pageMarginVp:20,columnMode:'auto',theme:'eye-comfort'};
const h=new H();let saved={...initial},writes=0,notifications=0,reject=false;
h.layout={...initial};h.readerAppearance={saveLayoutDefaults(next){writes++;if(reject)throw Error('owned failure');saved={...next};}};
h.reloadConfirmed=()=>{h.layout={...saved};return true;};h.onReaderPreferenceSaved=()=>notifications++;
for(let i=0;i<30;i++)h.setLayout(1+i/100,1.5,20,'auto',false);
assert.equal(writes,0);assert.equal(notifications,0);assert.equal(h.layout.fontScale,1.29);
h.setLayout(1.3,1.5,20,'auto',true);assert.equal(writes,1);assert.equal(saved.fontScale,1.3);assert.equal(notifications,1);
h.setLayout(1.4,1.5,20,'auto',false);reject=true;h.setLayout(1.4,1.5,20,'auto',true);
assert.equal(h.layout.fontScale,1.3);assert.equal(notifications,1);assert.equal(h.layout.theme,'eye-comfort');
assert.match(settings,/sliderRow\(title: string, value: \(\) => number/);
assert.match(settings,/choose\(next, mode === SliderChangeMode.End \|\| mode === SliderChangeMode.Click\)/);
const index=read('entry/src/main/ets/pages/Index.ets'),library=read('entry/src/main/ets/pages/LibraryPage.ets');
const tabs=index.indexOf('Tabs({ barPosition:');
assert.ok(tabs>index.indexOf('BookshelfBackground({ theme:'));
assert.ok(tabs<index.indexOf("if (this.readerHostBook !== undefined) {",tabs));
const retained=index.slice(tabs,index.indexOf('if (this.readerHostBook !== undefined)',tabs));
for(const name of ['visibility','enabled','hitTestBehavior','accessibilityLevel'])assert.ok(retained.includes('.'+name+'('));
assert.doesNotMatch(retained,/\.opacity\(/);
const Focus=run('export class Focus {'+method(library,'  private restoreSourceFocus(', '  private sourceFocused(')+'}').Focus;
const f=new Focus();f.sourceFocusPending=true;f.browse={sourceItemId:'owned'};f.restoredMode=f.viewMode='grid';f.mounted=true;
let frame,focused=0;f.hasOverlay=()=>false;f.getUIContext=()=>({postFrameCallback(cb){frame=cb;},getFocusController(){return{requestFocus(){focused++;}};}});
// A hidden retained Library may not schedule focus, or steal it from Reader.
f.active=false;f.restoreSourceFocus('owned');assert.equal(frame,undefined);
const Refresh=run('export class Refresh {'+method(index,'  private async refreshLibrary(', '  private updateMineSummary(')+'}').Refresh;
(async()=>{
 const r=new Refresh();r.mounted=true;r.libraryRequestGeneration=0;r.entries=[{owned:true}];
 let resolve;r.library={listEntries:()=>new Promise(yes=>{resolve=yes;})};
 const pending=r.refreshLibrary();assert.equal(r.entries.length,1);assert.equal(r.loading,false);
 resolve([{fresh:true}]);await pending;assert.equal(r.entries[0].fresh,true);
 r.library={listEntries:()=>Promise.reject(Error('owned rejection'))};await r.refreshLibrary();
 assert.equal(r.entries[0].fresh,true);assert.equal(r.libraryRefreshFailed,true);
 console.log('Reading stability PASS: preview without writes; commit/failure recovery; retained shell gating; hidden focus; refresh retention. SDK/device separate.');
})().catch(e=>{console.error(e.message);process.exitCode=1;});
