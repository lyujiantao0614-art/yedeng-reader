/* One source owner, no Web/reader view. Uses the XML implementation already
 * bundled in pinned epub.js; no additional parser dependency or chapter slicing. */
self.window=self;
importScripts('jszip.min.js','epub.min.js');
let book,cached,limit,chapterSizes=[],chapterReads=0,packetHits=0,tail=Promise.resolve();
function stats(){return {lazy:true,worker:true,chapterCount:book?book.spine.length:0,chapterHrefs:book?book.spine.spineItems.map(section=>section.href):[],chapterCfiBases:book?book.spine.spineItems.map(section=>section.cfiBase):[],chapterSizes,chapterReads,packetHits,packets:cached?1:0,packetBytes:cached?new TextEncoder().encode(JSON.stringify(cached)).length:0};}
function identity(doc,base){
 // The bundled XML DOM exposes getAttribute but lacks browser Element.id.
 for(const element of Array.from(doc.getElementsByTagName('*')))Object.defineProperty(element,'id',{get(){return this.getAttribute('id')||'';},configurable:true});
 const body=doc.getElementsByTagName('body')[0];
 let chosen;
 function visit(node,excluded){
  if(chosen)return;
  const skip=excluded||node.nodeName==='script'||node.nodeName==='style';
  if(!skip&&node.nodeType===3&&node.data.trim()){chosen=node;return;}
  for(let child=node.firstChild;child;child=child.nextSibling)visit(child,skip);
 }
 visit(body,false);
 if(chosen)return new ePub.CFI({startContainer:chosen,startOffset:0,endContainer:chosen,endOffset:Math.min(8,chosen.length),collapsed:false,commonAncestorContainer:chosen},base).toString();
 const all=body.getElementsByTagName('*');
 for(let i=0;i<all.length;i++)if(all[i].localName==='img'||all[i].localName==='svg')return new ePub.CFI(all[i],base).toString();
 throw new Error('Empty chapter');
}
async function run(message){
 if(message.kind==='open'){
  if(book)book.destroy();cached=null;chapterReads=0;packetHits=0;
  const bounds=message.bounds;
  for(const name of ['archiveBytes','entryCount','entryBytes','expandedBytes','sectionBytes'])if(!Number.isSafeInteger(bounds[name])||bounds[name]<=0)throw new Error('Invalid source bounds');
  const input=message.bytes;if(input.byteLength>bounds.archiveBytes)throw new Error('Archive budget');
  let zip=await JSZip.loadAsync(input),entries=Object.values(zip.files),expanded=0;
  if(entries.length>bounds.entryCount)throw new Error('Entry budget');
  for(const entry of entries){const size=entry._data?entry._data.uncompressedSize:0;if(size>bounds.entryBytes)throw new Error('Entry budget');expanded+=size;if(expanded>bounds.expandedBytes)throw new Error('Expanded budget');}
  zip=null;entries=null;limit=message.limit;
  book=ePub(undefined,{replacements:'none'});book.replacements=()=>Promise.resolve();
  await book.open(input);await book.ready;
  chapterSizes=book.spine.spineItems.map(section=>{
    const entry=book.archive.zip.file(decodeURIComponent(section.url.slice(1)));
    if(!entry||!entry._data)throw new Error('Missing source declaration');
    if(entry._data.uncompressedSize>bounds.sectionBytes)throw new Error('Chapter budget');
    return entry._data.uncompressedSize;
  });
  const catalog=Object.values(book.packaging.manifest).map(item=>({path:decodeURIComponent(book.resolve(item.href).replace(/^\/+/,'')),type:item.type}));
  const toc=[];
  const stack=(book.navigation.toc||[]).map(item=>({item,depth:0})).reverse();
  while(stack.length && toc.length<2000){
   const {item,depth}=stack.pop();
   toc.push({id:String(item.id||item.href||toc.length),href:String(item.href||''),label:String(item.label||'Untitled'),depth});
   if(Array.isArray(item.subitems))for(let i=item.subitems.length-1;i>=0;i--)stack.push({item:item.subitems[i],depth:depth+1});
  }
  return {stats:stats(),catalog,toc};
 }
 if(message.kind==='packet'){
  const index=message.index;if(!Number.isInteger(index)||index<0||index>=book.spine.length)throw new Error('Chapter outside spine');
  if(cached&&cached.index===index){packetHits++;return {packet:cached,stats:stats()};}
  cached=null;chapterReads++;const start=Date.now();
  try {
   const section=book.spine.get(index);
   await section.load(book.load.bind(book));
   const original=await book.archive.getText(section.url);
   if(new TextEncoder().encode(original).length>chapterSizes[index])throw new Error('Source exceeds declaration');
   const packet={index,href:section.href,base:section.cfiBase,html:original,sourceBytes:new TextEncoder().encode(original).length,paragraphs:section.document.getElementsByTagName('p').length,originalCfi:identity(section.document,section.cfiBase)};
   packet.resourcePath=decodeURIComponent(section.url.replace(/^\/+/, '')).split('/').map(encodeURIComponent).join('/');
   // Pinned epub.js parses .html/.htm with the browser HTML parser. Its implied
   // elements (for example tbody) differ from the bundled XML DOM in a Worker.
   // Retain the untouched source for independent CFI verification in the target
   // renderer, and apply that same browser parse mode to the complete packet.
   if(/\.html?$/i.test(section.url)){
    packet.parseMode='text/html';
   }
   if(new TextEncoder().encode(JSON.stringify(packet)).length>limit)throw new Error('Source budget');
   cached=packet;return {packet,stats:stats(),sample:{index,start,end:Date.now()}};
  } finally {book.spine.get(index).unload();}
 }
 throw new Error('Unknown source command');
}
self.onmessage=event=>{
 const message=event.data;
 tail=tail.then(()=>run(message)).then(result=>self.postMessage({id:message.id,result}),()=>self.postMessage({id:message.id,failed:true}));
};
