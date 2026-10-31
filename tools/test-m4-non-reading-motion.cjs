'use strict';
const assert=require('node:assert/strict'), fs=require('node:fs'), vm=require('node:vm');
const ts=require('typescript');
const read=p=>fs.readFileSync(p,'utf8');
function run(source,inject={}) {
 const exports={};const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021}}).outputText;
 vm.runInNewContext(js,{exports,Curve:{EaseOut:'ease-out'},...inject});return exports;
}
const motion=run(read('entry/src/main/ets/layout/NonReadingMotion.ets'),{
 TransitionEffect:{IDENTITY:{kind:'identity'},OPACITY:{kind:'opacity'},translate:options=>({kind:'translate',options,combine(other){this.other=other;return this;}})},
 ClickEffectLevel:{LIGHT:'light'}
});
for(const reduced of [true,false,undefined]) {
 const effect=motion.nonReadingPageTransition(reduced), press=motion.readingEntryClickEffect(reduced);
 if(reduced===true){assert.equal(effect.kind,'identity');assert.equal(press,null);}
 else {assert.equal(effect.kind,'translate');assert.equal(effect.options.x,16);assert.equal(effect.other.kind,'opacity');assert.equal(press.level,'light');assert.equal(press.scale,0.985);}
}
const index=read('entry/src/main/ets/pages/Index.ets');
const method=(source,start,end)=>source.slice(source.indexOf(start),source.indexOf(end,source.indexOf(start)));
const callbacks=method(index,'      onRecords: (kind: RecordKind): void => {','      onRetry:');
const body=callbacks.slice(callbacks.indexOf('{')+1,callbacks.lastIndexOf('}'));
const Harness=run('export class Harness { '+
 method(index,'  private openLibrarySettings(', '  private openReadingSettings(')+
 method(index,'  private closeReadingRecords(', '  private resolvedInterfaceMode(')+
 ' openRecords(kind:any) {'+body+'} }').Harness;
const h=new Harness();let begun=0, resets=0, animations=0;
let destination='mine', animationActive=false;
Object.defineProperty(h,'destination',{get:()=>destination,set(value){
 // A newly mounted Settings subtree must not inherit a global property animation.
 if(value==='settings')assert.equal(animationActive,false,'Settings creation must stay outside animateTo');
 destination=value;
}});
h.checkingBook=false;h.importing=false;
h.runtime={readingRecords:{begin(){begun++;}}};h.entries=[];
h.settingsPageController={resetToRoot(){resets++;}};h.updateShellBars=()=>{};
// The native animation has started but its completion callback never runs.
// Routing must still be immediate, repeatable and independent of that callback.
h.animateShell=(_,duration,action)=>{assert.ok(duration<=200);animations++;animationActive=true;try{action();}finally{animationActive=false;}};
h.openRecords('notes');h.openRecords('notes');assert.equal(begun,1);assert.equal(h.destination,'records');
h.closeReadingRecords();assert.equal(h.destination,'mine');h.openLibrarySettings();
h.openLibrarySettings();assert.equal(resets,1);assert.equal(h.destination,'settings');
h.closeReadingRecords();assert.equal(h.destination,'settings');assert.equal(animations,2);
const settings=read('entry/src/main/ets/pages/SettingsPage.ets');
const Settings=run('export class Settings {'+method(settings,'  private changeRoute(', '  private async loadLegal(')+'}').Settings;
for(const reduced of [true,false,undefined]) {
 const s=new Settings();let transactions=0;s.reducedMotion=reduced;s.entrySection=undefined;s.wide=()=>false;
 s.getUIContext=()=>({animateTo(options,action){transactions++;assert.ok(options.duration<=200);action();}});
 s.changeRoute('appearance',200);assert.equal(s.route,'appearance');s.changeRoute('root',160);assert.equal(s.route,'root');
 assert.equal(transactions,reduced===true?0:2);
 s.entrySection='reading';s.changeRoute('reading',200);assert.equal(transactions,reduced===true?0:2);
}
console.log('Non-reading motion PASS: reduced/ordinary/unknown; native bounded effects; repeated intents and navigation during unfinished animation; reader settings entry unchanged. SDK/device separate.');
