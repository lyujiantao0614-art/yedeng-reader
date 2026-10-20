(function(root){
  'use strict';
  function extract(packet){
    const mode=packet.parseMode||'application/xhtml+xml';
    const doc=new DOMParser().parseFromString(packet.html,mode);
    if(doc.querySelector('parsererror')||!doc.body)throw new Error('Invalid section document');
    const runs=[];let text='';
    function visit(node,path,excluded){
      if(path.length>64)throw new Error('Text tree depth bound');
      const skip=excluded||/^(script|style)$/i.test(node.localName||'');
      if(!skip&&node.nodeType===3&&node.data.length){
        if(runs.length>=20000||text.length+node.data.length>2*1024*1024)throw new Error('Text map bound');
        const start=text.length;text+=node.data;runs.push({path,start,end:text.length});
      }
      if(skip)return;
      for(let i=0;i<node.childNodes.length;i++)visit(node.childNodes[i],path.concat(i),skip);
    }
    const bodyPath=Array.from(doc.documentElement.childNodes).indexOf(doc.body);
    if(bodyPath<0)throw new Error('Body path unavailable');
    visit(doc.body,[bodyPath],false);
    return {version:1,extractor:'body-text-1',index:packet.index,href:packet.href,parserMode:mode,text,runs};
  }
  function endpoint(section,offset,end){
    if(!Number.isSafeInteger(offset)||offset<0||offset>section.text.length)throw new Error('Text offset outside section');
    const run=section.runs.find(run=>end?offset>run.start&&offset<=run.end:offset>=run.start&&offset<run.end);
    if(!run)throw new Error('Text endpoint unavailable');
    return {path:run.path.slice(),offset:offset-run.start};
  }
  function offset(section,path,nodeOffset){
    const run=section.runs.find(run=>JSON.stringify(run.path)===JSON.stringify(path));
    if(!run||!Number.isSafeInteger(nodeOffset)||nodeOffset<0||nodeOffset>run.end-run.start)throw new Error('Node offset unavailable');
    return run.start+nodeOffset;
  }
  root.SectionTextMap={extract,endpoint,offset};
  if(typeof module!=='undefined')module.exports=root.SectionTextMap;
})(globalThis);
