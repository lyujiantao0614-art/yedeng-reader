'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require('typescript');
const base=path.resolve(__dirname,'..'),root=base;
const read=n=>fs.readFileSync(path.join(base,n),'utf8');
function execute(source,inject={}){
  const exports={};
  const result=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021},reportDiagnostics:true});
  assert.ok(!result.diagnostics.some(d=>d.category===ts.DiagnosticCategory.Error));
  vm.runInNewContext(result.outputText,{exports,require:()=>({}),Promise,Map,Number,Math,Error,...inject});return exports;
}
const page=read('entry/src/main/ets/pages/LibraryPage.ets');
const items=read('entry/src/main/ets/components/LibraryGridItems.ets');
const layout=execute(read('entry/src/main/ets/layout/LibraryGridLayout.ets'));
let cases=0;
for(const width of [320,358,640,632,1024,1600]){
  const g=layout.libraryGridGeometry(width,84);
  assert.ok(g.gridWidthVp<=width+0.001);
  const t=Math.max(0,Math.min(1,(width-360)/480)), gap=12+4*t;
  assert.ok(g.cellWidthVp>=104+20*t && g.cellWidthVp<=126+18*t);
  assert.equal(g.columns,Math.floor((width+gap)/(104+20*t+gap)));
  assert.equal(g.columnsTemplate.split(' ').length,g.columns);cases++;
}
const wide=layout.libraryGridGeometry(1600,84);assert.ok(wide.columns>4);cases++;
const large=layout.libraryGridGeometry(640,122);assert.ok(large.columns<layout.libraryGridGeometry(640,84).columns);
assert.ok(large.cellWidthVp>=142);cases++;
const narrow=layout.libraryGridGeometry(92,84);assert.equal(narrow.columns,1);assert.equal(narrow.cellWidthVp,92);cases++;
const trailing=layout.libraryGridGeometry(300,84);assert.equal(trailing.cellWidthVp,126);assert.equal(trailing.gridWidthVp,264);cases++;
for(const title of [84,122,160]){
 let previous=0;
 for(let w=320;w<=1800;w++){
  const t=Math.max(0,Math.min(1,(w-360)/480)), inset=16+16*t;
  const g=layout.libraryGridGeometry(w-2*inset,title,w);
  assert.ok(g.columns>=previous,'Widening reduced columns at '+w);previous=g.columns;
  assert.ok(g.gridWidthVp<=w-2*inset+0.001);
 }
 cases++;
}
const section=(start,end)=>page.slice(page.indexOf(start),page.indexOf(end,page.indexOf(start)));
const focus=section('  private restoreSourceFocus(','  private activateBook(');
assert.doesNotMatch(section('  private restoreSourceFocus(','  private sourceFocused('),/sourceFocusPending = false/);
assert.match(focus,/private sourceFocused[\s\S]*sourceFocusPending = false/);
assert.match(focus,/if \(this.hasOverlay\(\)\) return/);cases++;
const card=items.slice(items.indexOf('  build() {'),items.indexOf('@Component\nexport struct LibraryFolderGridCard'));
assert.match(card,/height\(40\)\.maxLines\(2\)/);assert.doesNotMatch(card,/library-book-author/);
assert.match(items,/ImageFit\.Contain/);assert.match(items,/formatLabel/);
assert.match(card,/fontSize\('14fp'\)/);assert.match(items,/library-book-progress/);cases++;
const grid=page.slice(page.indexOf("Grid(this.gridScroller)"));
assert.match(grid,/LazyForEach\(this\.gridSource/);
assert.ok(grid.indexOf('item.folder')<grid.indexOf('item.entry'));
assert.equal((page.match(/Grid\(this.gridScroller\)/g)||[]).length,1);
assert.doesNotMatch(page,/library-view-grid|library-view-list|saveViewMode\(|private listRow|private actionsOverlay/);
assert.match(page,/legacyViewMode = this.presentation\?\.loadViewMode\(\)/);cases++;
const bookMenu=items.slice(items.indexOf('  private bookMoreMenu('),items.indexOf('  private bookActionButton('));
assert.ok(bookMenu.indexOf('library_details')<bookMenu.indexOf('编辑信息'));
assert.ok(bookMenu.indexOf('编辑信息')<bookMenu.indexOf("content: '移动'"));
assert.ok(bookMenu.indexOf("content: '移动'")<bookMenu.indexOf('删除图书'));cases++;
const folderStart=items.indexOf('  private folderMoreMenu(');
const folderMenu=items.slice(folderStart,items.indexOf('  build() {',folderStart));
assert.ok(folderMenu.indexOf("content: '重命名'")<folderMenu.indexOf("content: '移动'"));
assert.ok(folderMenu.indexOf("content: '移动'")<folderMenu.indexOf('删除文件夹'));cases++;
// The stable ID owns the item; current parent state explicitly supplies its Props.
assert.match(page,/LibraryFolderGridCard\(\{ folder: this\.currentFolder\(folder\.folderId\)/);
assert.match(page,/LibraryBookGridCard\(\{ entry: this\.currentEntry\(entry\.book\.bookId\)/);
assert.match(page,/\(entry: LibraryEntry\): string => entry\.book\.bookId\)/);
assert.doesNotMatch(page,/entryRenderKey|bookId\}:\$\{entry\.book\.title/);
assert.match(items,/@Prop folder: LibraryFolder \| undefined/);
assert.match(items,/@Prop entry: LibraryEntry \| undefined/);
// Native click gestures are exclusive by default: child Buttons own their action.
assert.equal((items.match(/\.onClick\(\(\): void => this\.openMore\(\)\)/g)||[]).length,2);
assert.match(items,/library-book-select[\s\S]{0,550}\.onClick\(\(\): void => \{[\s\S]{0,100}this\.onSelect\(current\.book\.bookId\)/);
assert.match(page,/library-details-repair/);
assert.match(page,/sourceState === 'missing'[\s\S]{0,300}this\.onRepair\(/);
assert.doesNotMatch(items,/ClickEvent/);
// Explicit native menu visibility is shared by touch and keyboard; Enter/Space
// never bubbles into the parent book/folder activation. Exercise the actual methods.
for(const name of ['LibraryBookGridCard','LibraryFolderGridCard']){
 const start=items.indexOf('export struct '+name),next=items.indexOf('@Component',start+1);
 const card=items.slice(start,next<0?undefined:next),from=card.indexOf('  private openMore('),to=card.indexOf('  private moreId(',from);
 assert.ok(from>=0&&to>from);
 const Harness=execute('export class MenuHarness { moreMenuVisible=false; opened=0; dismissed=0; moreId(){return "owned-more";} onMoreSource(id){if(id!=="owned-more")throw Error("Source mismatch");this.opened++;} onMoreDismiss(){this.dismissed++;} '+card.slice(from,to)+'}',{KeyCode:{KEYCODE_ENTER:1,KEYCODE_SPACE:2},KeyType:{Down:0,Up:1}}).MenuHarness;
 const h=new Harness();let stopped=0;
 h.openMore();assert.equal(h.moreMenuVisible,true);assert.equal(h.opened,1);
 h.dismissMore();assert.equal(h.moreMenuVisible,false);assert.equal(h.dismissed,1);
 for(const code of [1,2]){
  assert.equal(h.moreKey({keyCode:code,type:0,stopPropagation(){stopped++;}}),true);
  assert.equal(h.moreMenuVisible,true);const opened=h.opened;
  assert.equal(h.moreKey({keyCode:code,type:1,stopPropagation(){stopped++;}}),true);assert.equal(h.opened,opened);h.dismissMore();
 }
 assert.equal(h.moreKey({keyCode:3,type:0,stopPropagation(){stopped++;}}),false);assert.equal(stopped,4);
 assert.match(card,/\.bindMenu\(this\.moreMenuVisible, this\.(book|folder)MoreMenu\(\), nativeMenuOptions\(this\.menuMaterial, \{ onDisappear: \(\): void => this\.dismissMore\(\) \}\)\)/);
 cases++;
}
assert.doesNotMatch(page + items,/parallelGesture\(|priorityGesture\(TapGesture/);
assert.match(page,/\.id\('library-source-grid-' \+ entry\.book\.bookId\)[\s\S]{0,260}\.onClick\(\(\): void => this\.activateBookId\(entry\.book\.bookId\)\)/);
assert.match(page,/\.id\('library-folder-' \+ folder\.folderId\)[\s\S]{0,240}\.onClick\(\(\): void => this\.enterFolder\(folder\.folderId\)\)/);cases++;
const detail=section('  private detailsSheet(','  private deleteOverlay(');
assert.match(detail,/library-bookmarks-open/);assert.match(detail,/library-details-series/);assert.match(detail,/Scroll\(\)/);cases++;

const query=execute(fs.readFileSync(path.join(root,'entry/src/main/ets/services/LibraryQueryService.ets'),'utf8'));
const action=section('  private async organizationAction(','  private filteredEntries(');
const counts=section('  private directFolderBooks(','  private openCreateFolder(');
const Harness=execute(`export class Harness {
 mounted=true;organizationActionGeneration=0;organizationBusy=false;organizationMessage='';organizationName='Name';
 organizationTarget='target';organizationFolder:any={folderId:'managed'};organizationBook:any=undefined;
 seriesName='';volumeOrder='';selectedBookIds=['a','b'];entries:any[]=[];
 browse:any={folderId:'browsed',memberships:[],folders:[]};organization:any;refreshed=0;
 selectedEntries():any[]{return this.entries.filter(e=>this.selectedBookIds.includes(e.book.bookId));}
 reloadOrganization():void{this.refreshed++;}
 ${action}${counts}
}`,{filterAndSortLibraryLevel:query.filterAndSortLibraryLevel}).Harness;
async function run(){
 const SearchHarness=execute(`export class SearchHarness {
   browse:any={query:'owned',gridOffsetY:200,sourceItemId:'owned-source'};
   selectedBookIds=['owned'];batchResults=['owned'];published=0;
   resetBrowsePosition(){this.browse.gridOffsetY=0;this.browse.sourceItemId='';}
   publishBrowse(){this.published++;}
   ${section('  private changeSearch(', '  private progressLabel(')}
 }`).SearchHarness;
 const search=new SearchHarness();search.changeSearch('owned');
 assert.equal(search.browse.gridOffsetY,200);assert.equal(search.browse.sourceItemId,'owned-source');
 assert.equal(search.published,0);assert.equal(search.selectedBookIds.length,1);
 search.changeSearch('changed');assert.equal(search.browse.gridOffsetY,0);
 assert.equal(search.browse.sourceItemId,'');assert.equal(search.published,1);assert.equal(search.selectedBookIds.length,0);cases++;
 const disappear=section('  aboutToDisappear(): void {','  private publishBrowse(): void');
 const LeaveHarness=execute(`export class LeaveHarness {
   mounted=true;organizationReadGeneration=2;organizationActionGeneration=4;
   closeBookmarkToast():void{}
   bookmarkClosed=0;bookmarkDialog={close:()=>{this.bookmarkClosed++;}};
   onSelectionChange():void{} unsubscribeSystemMotion:any=undefined;
   browse:any={gridOffsetY:200};pageController={unbind:()=>{}};
   saveBrowsePosition():void{this.browse.gridOffsetY=0;}
   ${disappear}
 }`,{libraryBrowseObservation:{unbind:()=>{}}}).LeaveHarness;
 const leaving=new LeaveHarness();leaving.aboutToDisappear();
 assert.equal(leaving.bookmarkClosed,1);
 assert.equal(leaving.browse.gridOffsetY,200);assert.equal(leaving.mounted,false);
 assert.equal(leaving.organizationReadGeneration,3);assert.equal(leaving.organizationActionGeneration,5);cases++;
 const restore=section('  private restoreBrowsePosition(','  private restoreSourceFocus(');
 const reveal=section('  private revealGrid(','  private selectionChanged(');
 const RestoreHarness=execute(`export class RestoreHarness {
   mounted=true;restoredMode='';viewMode='grid';sourceFocusPending=false;requested=0;
   gridContentMeasured=true;gridMeasuredWidthVp=260;gridGeometry={gridWidthVp:260};
   browse:any={gridOffsetY:200,listOffsetY:0,sourceItemId:''};gridScroller:any;
   filteredEntries():any[]{return [];}
   filteredFolders():any[]{return new Array(240);}
   publishBrowse():void{} restoreSourceFocus():void{this.requested++;}
   saveBrowsePosition():void{this.browse.gridOffsetY=this.gridScroller.currentOffset().yOffset;}
   gridRevealGeneration=0;gridRevealSettled=false;systemReducedMotion=undefined;
   getUIContext():any{return {animateTo:(options:any,action:()=>void)=>{action();options.onFinish();}};}
   ${reveal}
   ${restore}
 }`,{Curve:{EaseOut:0}}).RestoreHarness;
 const restoring=new RestoreHarness();let actual=0,ended=false,lastTarget=-1;
 restoring.gridScroller={scrollTo:(o)=>{lastTarget=o.yOffset;},currentOffset:()=>({yOffset:actual}),isAtEnd:()=>ended};
 restoring.gridContentMeasured=false;restoring.restoreBrowsePosition('grid',7);
 assert.equal(lastTarget,-1);assert.equal(restoring.restoredMode,'');cases++;
 restoring.gridContentMeasured=true;restoring.gridMeasuredWidthVp=1;restoring.restoreBrowsePosition('grid',7);
 assert.equal(lastTarget,-1);assert.equal(restoring.restoredMode,'');cases++;
 restoring.gridMeasuredWidthVp=260;
 restoring.restoreBrowsePosition('grid',7);
 assert.equal(lastTarget,200);assert.equal(restoring.restoredMode,'');assert.equal(restoring.browse.gridOffsetY,200);
 assert.equal(restoring.requested,0);
 actual=200;restoring.restoreBrowsePosition('grid',15);
 assert.equal(restoring.restoredMode,'grid');assert.equal(restoring.requested,1);cases++;
 restoring.restoredMode='';actual=120;ended=true;restoring.restoreBrowsePosition('grid',239);
 assert.equal(restoring.restoredMode,'grid');assert.equal(restoring.browse.gridOffsetY,120);cases++;
 const h=new Harness();let target='';
 h.organization={rename:async(id)=>{target=id;}};await h.organizationAction('rename');
 assert.equal(target,'managed');assert.equal(h.browse.folderId,'browsed');cases++;
 h.managementComplete=false;h.organization={create:async(_,id)=>{target=id;}};await h.organizationAction('create');assert.equal(target,'browsed');cases++;
 h.entries=[{book:{bookId:'a',title:'A',importedAt:1}},{book:{bookId:'b',title:'B',importedAt:1}},{book:{bookId:'c',title:'C',importedAt:1}}];
 h.browse.memberships=[{bookId:'a',folderId:'managed'},{bookId:'b',folderId:'deep'},{bookId:'c',folderId:'managed'}];
 h.browse.folders=[{folderId:'deep',parentId:'managed'},{folderId:'deeper',parentId:'deep'}];
 assert.equal(h.directFolderBooks('managed'),2);assert.equal(h.directSubfolders('managed'),1);cases++;
 h.managementComplete=false;const moves=[];h.selectedBookIds=['a','b'];
 h.organization={moveBook:async(id,folder)=>{moves.push([id,folder]);if(id==='b')throw Error('owned boundary');}};
 await h.organizationAction('move-selected');assert.deepEqual(moves,[['a','target'],['b','target']]);
 assert.deepEqual(Array.from(h.selectedBookIds),['b']);assert.equal(h.organizationBusy,false);
 assert.match(h.organizationMessage,/已移动 1 本；1 本未移动/);cases++;
 const Source=execute(page.slice(page.indexOf('class LibraryGridItem'),page.indexOf('interface LibraryDeleteResult'))+'\nexports.Source=LibraryGridSource;').Source;
 const source=new Source([{key:'a'},{key:'b'},{key:'c'}]);let reloads=0;
 const listener={onDataReloaded:()=>reloads++};source.registerDataChangeListener(listener);source.registerDataChangeListener(listener);
 source.update([{key:'b'},{key:'c'}]);assert.equal(source.totalCount(),2);assert.equal(source.getData(0).key,'b');assert.equal(reloads,1);
 source.unregisterDataChangeListener(listener);source.update([]);assert.equal(reloads,1);cases++;
 const selection=execute(read('entry/src/main/ets/domain/LibraryOrganization.ets'));
 const folders=[{folderId:'p',parentId:''},{folderId:'c',parentId:'p'},{folderId:'g',parentId:'c'},{folderId:'s',parentId:''}];
 assert.deepEqual(Array.from(selection.topLevelSelectedFolders(folders,['','p','c','g','p','missing','s']),f=>f.folderId),['p','s']);cases++;
 const scope=selection.libraryDeletionScope(folders,[{bookId:'inside',folderId:'g'},{bookId:'outside',folderId:''}],['p','c','g'],['inside','outside','inside']);
 assert.deepEqual(Array.from(scope.roots,r=>r.folderId),['p']);assert.equal(scope.folders.length,3);
 assert.deepEqual(Array.from(scope.bookIds),['inside','outside']);assert.throws(()=>selection.libraryDeletionScope(folders,[],[''],[]));cases++;

 const Batch=execute('exports.Batch=class Batch {'+page.slice(page.indexOf('  private selectedCount()'),page.indexOf('  private keepBatchFocus'))+'}',{folderSubtree:selection.folderSubtree}).Batch;
 const batch=new Batch(),toasts=[],removed=[];
 Object.assign(batch,{mounted:true,batchBusy:false,batchBooks:[{bookId:'one',title:'One'},{bookId:'two',title:'Two'}],batchScopeFolders:[{folderId:'p',parentId:''}],batchFolders:[{folderId:'p',name:'Parent'}],
 onDeleteSelected:async()=>[{bookId:'one',succeeded:true},{bookId:'two',succeeded:false}],organization:{remove:async id=>removed.push(id)},
 reloadOrganization:()=>{},getUIContext:()=>({getPromptAction:()=>({showToast:o=>toasts.push(o.message)})})});
 await batch.confirmSelectedDeletion();assert.deepEqual(Array.from(batch.selectedBookIds),['two']);assert.deepEqual(Array.from(batch.selectedFolderIds),[]);
 assert.deepEqual(Array.from(batch.batchResults,r=>r.id),['two']);assert.deepEqual(removed,['p']);assert.equal(toasts.length,0);cases++;
 batch.batchBooks=[{bookId:'two',title:'Two'}];batch.batchFolders=[];batch.onDeleteSelected=async()=>{throw Error('owned failure');};
 await batch.confirmSelectedDeletion();assert.equal(batch.batchResults.length,1);assert.equal(batch.selectedBookIds[0],'two');cases++;
 batch.onDeleteSelected=async()=>[{bookId:'two',succeeded:true}];await batch.confirmSelectedDeletion();
 assert.equal(batch.batchResults.length,0);assert.equal(batch.selectionMode,false);assert.equal(toasts.length,1);cases++;
 const indexSource=read('entry/src/main/ets/pages/Index.ets');
 const IndexDelete=execute('exports.IndexDelete=class IndexDelete {'+indexSource.slice(indexSource.indexOf('  private async deleteBook('),indexSource.indexOf('  private async renameBook('))+'}').IndexDelete;
 const owner=new IndexDelete();Object.assign(owner,{checkingBook:false,importing:false,entries:[{book:{bookId:'ok'}},{book:{bookId:'fail'}}],message:'old',
  library:{delete:async b=>{if(b.bookId==='fail')throw Error('owned failure');}},refreshLibrary:async()=>{}});
 const deleted=await owner.deleteSelectedBooks([{bookId:'ok'},{bookId:'fail'}]);
 assert.deepEqual(Array.from(deleted,r=>r.succeeded),[true,false]);assert.deepEqual(Array.from(owner.entries,e=>e.book.bookId),['fail']);
 assert.equal(owner.message,'','batch owns one dismissible failure surface');
 assert.equal(await owner.deleteBook({bookId:'fail'}),false);assert.match(owner.message,/删除未完成/);cases++;
 console.log('M4 B Library Grid current source checks PASS cases='+cases+'; no SDK/device claim.');
}
run().catch(e=>{console.error(e.message);process.exitCode=1;});
