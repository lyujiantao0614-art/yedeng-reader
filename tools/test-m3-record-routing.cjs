'use strict';
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),read=name=>fs.readFileSync(path.join(root,name),'utf8');
const surface=read('entry/src/main/resources/rawfile/web-reader-surfaces/surface.js');
const bridge=read('entry/src/main/ets/reader/ReaderFourSurfaceView.ets');
const page=read('entry/src/main/ets/pages/ReaderPage.ets');
const store=read('entry/src/main/ets/repositories/EncryptedBookmarkStore.ets');
assert.match(read('entry/src/main/resources/rawfile/web-reader-surfaces/index.html'),/src="range-anchors.js"/);
assert.equal((surface.match(/RangeAnchors\.invalidate\(doc\);\s*doc\.replaceChild\(/g)??[]).length,2,
  'Loading and releasing a chapter must invalidate its reused Document before replacing the root');
for(const action of ['union','verify','resolve'])assert.match(surface,new RegExp('RangeAnchors\\.'+action+'\\('));
assert.match(bridge,/context\.rangeUnion = combined/);assert.match(bridge,/quoteScope: value\.quoteScope/);
assert.match(bridge,/512 \* 1024/);assert.match(bridge,/1024 \* 1024/);
assert.doesNotMatch(surface,/exactText\.length\s*>\s*512|textRangeEvidence|rangesOverlap/);
assert.doesNotMatch(read('entry/src/main/resources/rawfile/web-reader-surfaces/range-anchors.js'),/\.cfi\.localeCompare|\.cfi\s*[<>]/);
for(const action of ['editNote','removeNote','addNote','setAnchorStatus'])assert.match(page,new RegExp('this\\.textMarks\\.'+action+'\\('));
assert.match(page,/ForEach\(this\.selectedNoteEntries\(\)/);
const entries=page.slice(page.indexOf('  private selectedNoteEntries('),page.indexOf('  private closeMarkDetail('));
assert.match(entries,/selectedTextMark\(\)\?\.notes/);
assert.match(entries,/slice\(\)\.sort/);assert.match(entries,/left\.createdAt - right\.createdAt/);
assert.match(page,/this\.editingNoteSnapshot = note === undefined \? undefined : copyEditingNote\(note\)/);
assert.match(page,/Text\(this\.noteOriginalQuote\)\.id\('reader-note-editor-original-quote'\)/);
assert.match(page,/this\.textMarks\.editNote\(note, draft\)/);
const app=read('entry/src/main/ets/application/TextMarkApplication.ets');
const save=app.slice(app.indexOf('  async save('),app.indexOf('  async remove('));
assert.match(save,/return await this\.encrypted\.replaceRanges/);
assert.doesNotMatch(save,/return \(await this\.list/);
const edit=store.slice(store.indexOf('  async editNote('),store.indexOf('  async removeNote('));
assert.match(edit,/new relationalStore\.RdbPredicates\('note_entries'\)/);
for(const field of ['book_id','note_id','range_id','revision'])assert.ok(edit.includes("equalTo('"+field+"'"));
assert.match(edit,/affected !== 1/);assert.doesNotMatch(edit,/listNotes\(/);
assert.match(page,/MenuItem\(\{ content: '移除独立高亮'/);
for(const field of ['reader-note-original-quote','reader-note-time','reader-note-origin-unavailable','onNoteAnchorResolution'])assert.ok(page.includes(field));
assert.match(store,/note_anchor_migration/);assert.match(store,/original_text/);assert.match(store,/anchor_provenance/);
assert.match(surface,/RangeAnchors\.display\(/);
assert.match(store,/range_migration/);assert.match(store,/EXCEPT/);assert.match(store,/stillCurrent/);
// Execute the current native action: an independent highlight must never pull
// note groups into a same-kind service union, including when their ranges overlap.
const ts=require('typescript');
const vm=require('node:vm');
const nativeAction=page.slice(page.indexOf('  private nativeSelectionAction('),page.indexOf('  private clearUncommittedSelection('));
const actionSource=`class NativeHarness {
 currentSurface='none';bookmarkBusy=false;nativeNoteToken='';nativeAdjustRequest:any;
 adjustingMarkId='';savedTextMarks:any[]=[];currentSessionId=7;calls:any[]=[];
 controller={requestSelectionContext:(...args:any[])=>this.calls.push(args)};
 getUIContext(){return {getPromptAction:()=>({showToast:()=>{}})};}
 ${nativeAction}
} globalThis.NativeHarness=NativeHarness;`;
const actionScope={readerTextMark:(mark)=>mark};
vm.runInNewContext(ts.transpileModule(actionSource,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,actionScope);
const native=new actionScope.NativeHarness();
native.savedTextMarks=[{markId:'owned-highlight',kind:'highlight',revision:2,cfi:'owned-cfi',exactText:'ABC'},
 {markId:'owned-note',kind:'note',revision:3},{markId:'other-highlight',kind:'highlight',revision:1}];
native.adjustingMarkId='owned-highlight';native.nativeSelectionAction('note','owned-token','123','owned-locator');
assert.deepEqual(Array.from(native.calls[0][2],mark=>mark.markId),['owned-highlight','other-highlight']);
assert.equal(native.calls[0][3],'owned-highlight');assert.equal(native.nativeAdjustRequest.revision,2);
native.adjustingMarkId='owned-note';native.nativeSelectionAction('note','owned-token','123','owned-locator');
assert.deepEqual(Array.from(native.calls[1][2],mark=>mark.markId),['owned-note']);
native.adjustingMarkId='';native.nativeSelectionAction('note','owned-token','123','owned-locator');
assert.deepEqual(Array.from(native.calls[2][2],mark=>mark.markId),['owned-note']);assert.equal(native.calls[2][3],undefined);
native.adjustingMarkId='missing-owned-mark';native.nativeSelectionAction('note','owned-token','123','owned-locator');
assert.equal(native.calls.length,3);assert.equal(native.nativeNoteToken,'');
console.log('M3 production DOM/native/storage/independent-note routing contracts and 4 native context cases passed. Native DOM and RDB oracles remain separate device gates.');

// Direct highlight still waits for the verified context and rejects changed navigation/selection.
const highlightMethods=bridge.slice(bridge.indexOf('  private revokeSelectionHighlight('),bridge.indexOf('  private adjustActionWidthVp('));
const highlightScope={TouchType:{Down:0,Cancel:3}};
vm.runInNewContext(ts.transpileModule(`class HighlightHarness {
 alive=true;ready=true;activeSession=7;nativeSelectionRevision=3;generation=2;navigationEpoch=4;
 currentSlot=1;slotVersions=[0,9,0,0];layoutRevision=6;relayouting=false;navigating=false;moving=false;
 selectionText='owned';selectionToken='token';selectionMenuMarks=[{kind:'note'},{kind:'highlight'}];
 selectionGate={canPublish:()=>true};highlightRevision=-1;highlightSession=-1;highlightText='';highlightToken='';
 highlightPresentationPending=false;highlightRequested=false;highlightContextPending=false;highlightContext:any;
 highlightGeneration=-1;highlightNavigationEpoch=-1;highlightSlot=-1;highlightSlotVersion=-1;highlightLayoutRevision=-1;
 requests:any[]=[];published:any[]=[];pending:any;
 callbacks={onSelectionMarkContext:(...args:any[])=>this.published.push(args)};
 requestSelectionContext(...args:any[]){this.requests.push(args);this.pending=args[4];}
 ${highlightMethods}
} globalThis.HighlightHarness=HighlightHarness;`,{compilerOptions:{target:ts.ScriptTarget.ES2021}}).outputText,highlightScope);
const highlight=new highlightScope.HighlightHarness();
highlight.selectionHighlightTouch({type:0}); highlight.saveSelectionHighlight();
assert.equal(highlight.published.length,0,'No write before async verification');
assert.deepEqual(Array.from(highlight.requests[0][2],mark=>mark.kind),['highlight']);
highlight.pending({rangeAnchor:{exactText:'owned'}}); assert.equal(highlight.published.length,1);
highlight.selectionHighlightTouch({type:0}); highlight.saveSelectionHighlight(); highlight.navigationEpoch++;
highlight.pending({rangeAnchor:{exactText:'owned'}}); assert.equal(highlight.published.length,1);
highlight.selectionHighlightTouch({type:0}); highlight.nativeSelectionRevision++;
highlight.saveSelectionHighlight(); assert.equal(highlight.published.length,1);
highlight.selectionHighlightTouch({type:0}); highlight.selectionHighlightTouch({type:3});
highlight.pending({rangeAnchor:{exactText:'owned'}}); assert.equal(highlight.published.length,1);
console.log('Direct highlight: verified async completion, same-kind marks, navigation/revision/cancel fences passed.');
