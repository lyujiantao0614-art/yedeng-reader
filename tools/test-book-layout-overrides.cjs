'use strict';
const fs=require('fs'),path=require('path'),vm=require('vm'),assert=require('node:assert/strict');
const ts=require('typescript');
const disk=new Map(),cache=new Map();let failFlush=0;
const preferences={getPreferencesSync(_context,{name}){
  if(!disk.has(name))disk.set(name,new Map());
  const values=new Map(disk.get(name));cache.set(name,values);
  return {getSync:(key,fallback)=>values.has(key)?values.get(key):fallback,hasSync:key=>values.has(key),
    putSync:(key,value)=>values.set(key,value),deleteSync:key=>values.delete(key),flushSync(){
      if(failFlush-->0)throw Error('owned flush failure');disk.set(name,new Map(values));
    }};
}};
const modules=new Map();
function load(file){
 file=path.resolve(file);if(modules.has(file))return modules.get(file);
 const exports={};modules.set(file,exports);
 const require=name=>name==='@kit.ArkData'?{preferences}:name.includes('SystemMotionSignal')?{}:
   name.startsWith('@')?{}:load(path.resolve(path.dirname(file),name)+'.ets');
 vm.runInNewContext(ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,{exports,require});
 return exports;
}
const {ReaderSettingsRepository}=load('entry/src/main/ets/repositories/ReaderSettingsRepository.ets');
const {ReaderAppearanceApplication}=load('entry/src/main/ets/application/ReaderAppearanceApplication.ets');
const A='a'.repeat(64),B='b'.repeat(64),name='owned-layout';
function open(){const repo=new ReaderSettingsRepository({storeName:name});repo.initialize({});
 return {repo,app:new ReaderAppearanceApplication(repo,{mode:()=> 'light'})};}
let {repo,app}=open();assert.equal(app.loadSettings(A).lineSpacing,1.5);assert.equal(disk.get(name).size,0);
repo.saveLayoutDefaults({fontScale:1,lineSpacing:1.5,pageMarginVp:20,columnMode:'single',theme:'light'});
app.saveBookLayoutParameter(A,'fontScale',1.4);
assert.equal(app.loadSettings().fontScale,1);assert.equal(app.loadSettings(B).fontScale,1);
assert.equal(app.loadSettings(A).fontScale,1.4);
assert.deepEqual(JSON.parse(JSON.stringify(app.bookLayoutOverrides(A))),{fontScale:1.4});
repo.saveLayoutDefaults({fontScale:1.1,lineSpacing:1.8,pageMarginVp:28,columnMode:'auto',theme:'light'});
assert.equal(app.loadSettings(A).fontScale,1.4);assert.equal(app.loadSettings(A).lineSpacing,1.8);
assert.equal(app.loadSettings(A).pageMarginVp,28);assert.equal(app.loadSettings(B).fontScale,1.1);
({repo,app}=open());assert.equal(app.loadSettings(A).fontScale,1.4);assert.equal(app.loadSettings(A).lineSpacing,1.8);
app.saveBookLayoutParameter(A,'lineSpacing',1.6);app.saveBookLayoutParameter(A,'pageMarginVp',32);
assert.equal(app.loadSettings(B).lineSpacing,1.8);assert.equal(app.loadSettings().pageMarginVp,28);
assert.throws(()=>app.saveBookLayoutParameter(A,'lineSpacing',99));assert.equal(app.loadSettings(A).lineSpacing,1.6);
failFlush=1;assert.throws(()=>app.saveBookLayoutParameter(A,'fontScale',1.5));assert.equal(app.loadSettings(A).fontScale,1.4);
failFlush=1;assert.throws(()=>app.clearBookLayoutOverrides(A));assert.equal(app.loadSettings(A).fontScale,1.4);
({repo,app}=open());assert.equal(app.loadSettings(A).fontScale,1.4);
app.clearBookLayoutOverrides(A);assert.equal(disk.get(name).has('book_layout_v1_'+A),false);
assert.equal(app.loadSettings(A).fontScale,1.1);assert.equal(app.loadSettings(A).lineSpacing,1.8);
repo.saveLayoutDefaults({fontScale:1.2,lineSpacing:1.9,pageMarginVp:30,columnMode:'single',theme:'light'});
assert.equal(app.loadSettings(A).fontScale,1.2);assert.equal(app.loadSettings(A).columnMode,'single');
app.saveThemePreference('eye-comfort');assert.equal(app.loadSettings(A).theme,'eye-comfort');
assert.equal(app.loadSettings(B).theme,'eye-comfort');assert.equal(app.bookLayoutOverrides(A).theme,undefined);
assert.throws(()=>app.saveBookLayoutParameter('../bad','fontScale',1));
const page=fs.readFileSync('entry/src/main/ets/pages/ReaderPage.ets','utf8');
assert.match(page,/application\.loadSettings\(this\.currentBook\.bookId\)/);
assert.doesNotMatch(page,/appearanceApplication\?\.saveLayoutDefaults/);
assert.match(page,/if \(geometryChanged \|\| themeChanged\) this\.controller\.applySettings/);
const begin=page.indexOf('  private syncConfirmedPreferences('),end=page.indexOf('  private selectReaderTheme(',begin);
const scope={exports:{},animateReaderMotion:()=>true};
vm.runInNewContext(ts.transpileModule('export class Page {'+page.slice(begin,end)+'}',{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,scope);
const p=new scope.exports.Page();let reflows=0;
Object.assign(p,{appearanceApplication:app,hasReaderSession:true,exiting:false,currentBook:{bookId:A},settings:app.loadSettings(A),
 effectiveReaderSettings:s=>s,controller:{applySettings(){reflows++;}},onThemeChange(){},updateSystemBars(){}});
p.updateLayoutSettings('fontScale',1.2);assert.equal(reflows,0,'equal effective value may become explicit without reflow');
p.resetBookLayout();assert.equal(reflows,0,'equal effective reset must not reflow');
p.updateLayoutSettings('fontScale',1.4);assert.equal(reflows,1);
failFlush=1;p.updateLayoutSettings('lineSpacing',1.5);assert.equal(reflows,1);assert.equal(p.settings.lineSpacing,1.9);assert.ok(p.appearanceMessage);
const deletion=fs.readFileSync('entry/src/main/ets/services/BookDeletionService.ets','utf8');
const dstart=deletion.indexOf('  async continueDelete('),dend=deletion.indexOf('  private requireEncrypted(',dstart);
const dscope={exports:{}};
vm.runInNewContext(ts.transpileModule('export class Delete {'+deletion.slice(dstart,dend)+'}',{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,dscope);
const del=new dscope.exports.Delete();let completed=0;
Object.assign(del,{repository:{bookmarkAuthority:async()=> 'source',textRecordsEnabled:async()=>false,completeDelete:async()=>completed++},
 readerSettings:repo});
(async()=>{
 failFlush=1;await assert.rejects(del.continueDelete({kind:'delete',state:'files_removed',operationId:'owned',bookId:A}));assert.equal(completed,0);
 await del.continueDelete({kind:'delete',state:'files_removed',operationId:'owned',bookId:A});assert.equal(completed,1);
 assert.equal(app.bookLayoutOverrides(A).fontScale,undefined);
 console.log('Book deletion PASS: failed preference cleanup retains deletion journal; retry clears only owned overrides before catalogue completion.');
})().catch(error=>{console.error(error);process.exitCode=1;});
console.log('Book layout PASS: sparse independent overrides, A/B/global isolation, dynamic inheritance, restart, validation, failed save/reset rollback, delete-on-reset, unchanged theme/columns and guarded reflow.');
