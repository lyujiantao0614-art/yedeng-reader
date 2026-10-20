'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('typescript');
const base=path.resolve(__dirname,'..');
const read=name=>fs.readFileSync(path.join(base,name),'utf8');
function execute(source, inject={}){
  const exports={};
  const result=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
  if(result.diagnostics.some(d=>d.category===ts.DiagnosticCategory.Error))throw Error('6A pure source parse failed');
  vm.runInNewContext(result.outputText,{exports,require:()=>({}),Promise,Map,Number,Math,Error,...inject});
  return exports;
}
const query=execute(read('entry/src/main/ets/services/LibraryQueryService.ets'));
const state=execute(read('entry/src/main/ets/shell/LibraryBrowseState.ets'));
const entry=(id,title,author,imported=1)=>({book:{bookId:id,title,author,importedAt:imported},percentage:0});
const entries=[entry('a','Root title','Root author'),entry('b','Child title','Target author'),entry('c','Other title','Target author'),entry('d','Root second','No match',2)];
const memberships=[{bookId:'b',folderId:'child'},{bookId:'c',folderId:'other'}];
// Real fresh progress and recent metadata must not reorder the returning viewport.
const pageSource=read('entry/src/main/ets/pages/LibraryPage.ets');
const methodStart=pageSource.indexOf('  private filteredEntries()'),methodEnd=pageSource.indexOf('  private filteredFolders()',methodStart);
assert.ok(methodStart>=0&&methodEnd>methodStart);
const ReturnHarness=execute('export class ReturnHarness { gridSource:any={update(items:any[]){this.items=items;}}; entries:any[]=[]; browse:any={memberships:[],folderId:"",query:"",sort:"recent"}; '+pageSource.slice(methodStart,methodEnd)+' }').ReturnHarness;
// Use the production method with its real query dependency, not a copied sort implementation.
const returnJs=ts.transpileModule('export class ReturnHarness { gridSource:any={update(items:any[]){this.items=items;}}; entries:any[]=[]; browse:any={memberships:[],folderId:"",query:"",sort:"recent"}; '+pageSource.slice(methodStart,methodEnd)+' }',{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText;
const returnExports={};vm.runInNewContext(returnJs,{exports:returnExports,filterAndSortLibraryLevel:query.filterAndSortLibraryLevel,
  filterLibraryChildFolders:query.filterLibraryChildFolders,LibraryGridItem:class {constructor(folder,entry){this.folder=folder;this.entry=entry;}},
  LibraryGridSource:class {constructor(items){this.items=items;}},Map});
const returning=new returnExports.ReturnHarness();returning.browse.folders=[];
returning.entries=[entry('older','Older','Author',1),entry('newer','Newer','Author',2)];
assert.deepEqual(Array.from(returning.filteredEntries(),e=>e.book.bookId),['newer','older']);
returning.browse.readerReturnBookOrder=['newer','older'];returning.entries[0].book.lastOpenedAt=100;
returning.entries[0].percentage=42;
assert.deepEqual(Array.from(returning.filteredEntries(),e=>e.book.bookId),['newer','older']);
assert.equal(returning.filteredEntries()[1].percentage,42);assert.equal(returning.filteredEntries()[1].book.lastOpenedAt,100);
returning.browse.readerReturnBookOrder=undefined;
assert.deepEqual(Array.from(returning.filteredEntries(),e=>e.book.bookId),['older','newer']);
const folders=[{folderId:'z',parentId:'',name:'Zeta'},{folderId:'a',parentId:'',name:'Alpha'},
  {folderId:'deep',parentId:'a',name:'Alpha descendant'},{folderId:'foreign',parentId:'z',name:'Alpha foreign'}];
let cases=0;
assert.deepEqual(Array.from(query.filterAndSortLibraryLevel(entries,memberships,'','Target','title'),e=>e.book.bookId),[]);cases++;
assert.deepEqual(Array.from(query.filterAndSortLibraryLevel(entries,memberships,'child','tArGeT','recent'),e=>e.book.bookId),['b']);cases++;
assert.deepEqual(Array.from(query.filterAndSortLibraryLevel(entries,memberships,'','   ','recent'),e=>e.book.bookId),['d','a']);cases++;
assert.deepEqual(Array.from(query.filterLibraryChildFolders(folders,'','alpha'),f=>f.folderId),['a']);cases++;
assert.deepEqual(Array.from(query.filterLibraryChildFolders(folders,'',''),f=>f.folderId),['a','z']);cases++;
assert.deepEqual(entries.map(e=>e.book.bookId),['a','b','c','d']);assert.deepEqual(folders.map(f=>f.folderId),['z','a','deep','foreign']);cases++;
const browse=state.createLibraryBrowseState();browse.query='Alpha';browse.sort='title';browse.gridOffsetY=182; browse.listOffsetY=224;
browse.gridSourceTopVp=37.25;
const child=state.enterLibraryFolder(browse,'a','library-folder-a');child.query='inside';
const parent=state.returnLibraryParent(child,'');
assert.equal(parent.query,'Alpha');assert.equal(parent.sort,'title');assert.equal(parent.gridOffsetY,182);assert.equal(parent.listOffsetY,224);assert.equal(parent.sourceItemId,'library-folder-a');cases++;
assert.equal(parent.gridSourceTopVp,37.25);assert.equal(child.gridSourceTopVp,undefined);cases++;
const copy=state.copyLibraryBrowseState(child);copy.parents[0].query='changed';assert.equal(child.parents[0].query,'Alpha');cases++;
child.folders=folders; child.folderId='deep';
const reconciled=state.reconcileLibraryFolder(child,folders.filter(f=>f.folderId!=='deep'));
assert.equal(reconciled.folderId,'a');assert.equal(reconciled.query,'inside');cases++;
const unchanged=state.reconcileLibraryFolder(parent,folders);assert.equal(unchanged,parent);cases++;

const source=read('entry/src/main/ets/pages/LibraryPage.ets');
function method(start,end){return source.slice(source.indexOf(start),source.indexOf(end));}
const methods=method('  private reloadOrganization(): void {','  private saveBrowsePosition(): void {')+
  method('  private async organizationAction(action: string): Promise<void> {','  private filteredEntries(): LibraryEntry[] {');
const Harness=execute(`export class Harness {
  mounted:boolean=true; organizationReadGeneration:number=0;organizationActionGeneration:number=0;
  organizationReadFailed:boolean=false;organizationBusy:boolean=false;organizationMessage:string='';organizationName:string='owned';
  organizationTarget:string='target';seriesName:string='owned';volumeOrder:string='1';organizationBook:any=undefined;
  browse:any;organization:any;organizationFolder:any=undefined;published:number=0;
  selectedEntries():any[]{return [];}
  publishBrowse():void{this.published++;}
  refreshFolderCards():void{}
  resetBrowsePosition():void{this.browse.gridOffsetY=0;this.browse.listOffsetY=0;this.browse.sourceItemId='';}
  ${methods}
}`,{reconcileLibraryFolder:state.reconcileLibraryFolder}).Harness;
const deferred=()=>{let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return{promise,resolve,reject};};
const tick=()=>new Promise(resolve=>setImmediate(resolve));
async function run(){
  const loadingHarness=new Harness();loadingHarness.loading=true;
  loadingHarness.organization={folders:()=>{throw Error('Premature repository read');},memberships:()=>{throw Error('Premature repository read');}};
  loadingHarness.reloadOrganization();assert.equal(loadingHarness.organizationReadFailed,false);assert.equal(loadingHarness.published,0);cases++;
  const oldFolders=deferred(),newFolders=deferred(),oldMembers=deferred(),newMembers=deferred();
  const f=[oldFolders,newFolders],m=[oldMembers,newMembers];const harness=new Harness();harness.browse=state.createLibraryBrowseState();
  harness.organization={folders:()=>f.shift().promise,memberships:()=>m.shift().promise};
  harness.reloadOrganization();harness.reloadOrganization();
  newFolders.resolve([{folderId:'new',parentId:'',name:'New'}]);newMembers.resolve([{bookId:'new',folderId:'new'}]);await tick();
  oldFolders.resolve([{folderId:'old',parentId:'',name:'Old'}]);oldMembers.resolve([{bookId:'old',folderId:'old'}]);await tick();
  assert.equal(harness.browse.folders[0].folderId,'new');assert.equal(harness.browse.memberships[0].bookId,'new');assert.equal(harness.published,1);cases++;
  const staleFolders=deferred(),staleMembers=deferred();harness.organization={folders:()=>staleFolders.promise,memberships:()=>staleMembers.promise};
  harness.reloadOrganization();harness.mounted=false;harness.organizationReadGeneration++;
  staleFolders.resolve([]);staleMembers.resolve([]);await tick();assert.equal(harness.browse.folders[0].folderId,'new');assert.equal(harness.published,1);cases++;
  harness.mounted=true;harness.browse.folderId='new';harness.browse.query='kept';harness.browse.gridOffsetY=90;
  harness.organization={folders:()=>Promise.reject(Error('owned rejection')),memberships:()=>Promise.resolve([])};
  harness.reloadOrganization();await tick();assert.equal(harness.organizationReadFailed,true);assert.equal(harness.browse.query,'kept');assert.equal(harness.browse.gridOffsetY,90);assert.equal(harness.browse.folders[0].folderId,'new');cases++;
  const removed=deferred();harness.browse.folderId='removed';let deletedId='';
  harness.organization={remove:async id=>{deletedId=id;await removed.promise;},folders:()=>Promise.resolve([{folderId:'new',parentId:'',name:'New'}]),memberships:()=>Promise.resolve([])};
  const operation=harness.organizationAction('remove');harness.browse.folderId='new';removed.resolve();await operation;await tick();
  assert.equal(deletedId,'removed');assert.equal(harness.browse.folderId,'new');assert.equal(harness.organizationBusy,false);cases++;
  const index=read('entry/src/main/ets/pages/Index.ets');
  assert.match(index,/@State private libraryBrowse: LibraryBrowseState/);
  assert.match(index,/generation !== this\.libraryRequestGeneration/);
  assert.match(source,/@Prop browse: LibraryBrowseState/);
  assert.doesNotMatch(source,/@State private (query|sort|folderId):/);
  assert.doesNotMatch(index+source,/setTimeout|setInterval/);
  assert.match(source,/scroller\.scrollTo\(\{ xOffset: 0/);
  assert.match(source,/\.onAreaChange\(\(_old: Area, area: Area\): void => \{[\s\S]*?this\.gridMeasuredWidthVp = width;[\s\S]*?this\.restoreBrowsePosition\('grid'\)/);
  console.log('M4 6A current source pure/async checks PASS cases='+cases+'; no ArkTS SDK or device claim.');
}
run().catch(error=>{console.error(error.message);process.exitCode=1;});
