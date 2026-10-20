(function (root) {
  'use strict';
  const QUOTE_LIMIT=32768, TEXT_LIMIT=2*1024*1024, NODE_LIMIT=20000;
  const maps=new WeakMap();
  function invalidate(doc) { maps.delete(doc); }
  function textMap(doc) {
    if(maps.has(doc))return maps.get(doc);
    const runs=[];let text='';
    function visit(node,depth,skip) {
      if(depth>64)throw new Error('Range DOM depth bound');
      skip=skip||/^(script|style)$/i.test(node.localName||'');
      if(skip)return;
      if(node.nodeType===3&&node.data.length) {
        if(runs.length>=NODE_LIMIT||text.length+node.data.length>TEXT_LIMIT)throw new Error('Range DOM text bound');
        const start=text.length;text+=node.data;runs.push({node,start,end:text.length});
      }
      for(const child of node.childNodes)visit(child,depth+1,false);
    }
    visit(doc.body,0,false);const map={text,runs};maps.set(doc,map);return map;
  }
  function evidence(contents,range,scope) {
    if(!range||range.collapsed||range.startContainer.nodeType!==3||range.endContainer.nodeType!==3)return null;
    const doc=contents.document;
    if(range.startContainer.ownerDocument!==doc||range.endContainer.ownerDocument!==doc)return null;
    let text=range.toString();if(!text||text.length>QUOTE_LIMIT)return null;
    if(scope!=='body') {
      const block=range.startContainer.parentElement.closest('p,li,h1,h2,h3,h4,h5,h6,blockquote,pre,figcaption,dt,dd');
      if(!block||!block.contains(range.endContainer)||block.textContent.length>TEXT_LIMIT||block.querySelector('script,style'))return null;
      const before=doc.createRange(),after=doc.createRange();
      before.selectNodeContents(block);before.setEnd(range.startContainer,range.startOffset);
      after.selectNodeContents(block);after.setStart(range.endContainer,range.endOffset);
      return {text,left:before.toString(),right:after.toString()};
    }
    const map=textMap(doc),a=map.runs.find(run=>run.node===range.startContainer),b=map.runs.find(run=>run.node===range.endContainer);
    if(!a||!b||range.startOffset<0||range.startOffset>a.node.length||range.endOffset<0||range.endOffset>b.node.length)return null;
    const start=a.start+range.startOffset,end=b.start+range.endOffset;
    if(start>=end||text!==map.text.slice(start,end))return null;
    return {text,left:map.text.slice(Math.max(0,start-64),start),right:map.text.slice(end,end+64)};
  }
  function valid(mark,href,base) {
    return mark&&mark.resourceHref===href&&typeof mark.cfi==='string'&&mark.cfi.startsWith('epubcfi(')&&
      mark.cfi.length<=4096&&mark.cfi.includes(base+'!')&&typeof mark.exactText==='string'&&
      mark.exactText.length>0&&mark.exactText.length<=QUOTE_LIMIT&&typeof mark.prefix==='string'&&mark.prefix.length<=64&&
      typeof mark.suffix==='string'&&mark.suffix.length<=64&&(mark.quoteScope===undefined||['block','body'].includes(mark.quoteScope));
  }
  function matches(contents,range,mark) {
    const value=evidence(contents,range,mark.quoteScope);
    return !!value&&value.text===mark.exactText&&value.left.endsWith(mark.prefix)&&value.right.startsWith(mark.suffix)&&
      (mark.prefix.length>0||value.left.length===0)&&(mark.suffix.length>0||value.right.length===0);
  }
  function verify(contents,mark,href,base) {
    if(!valid(mark,href,base))return false;
    try{return matches(contents,contents.range(mark.cfi),mark);}catch(_){return false;}
  }
  function fromOffsets(doc,map,start,end) {
    const a=map.runs.find(run=>start>=run.start&&start<run.end),b=map.runs.find(run=>end>run.start&&end<=run.end);
    if(!a||!b)return null;
    const range=doc.createRange();range.setStart(a.node,start-a.start);range.setEnd(b.node,end-b.start);return range;
  }
  function resolve(contents,mark,href,base) {
    if(!valid(mark,href,base))return {status:'orphaned',reason:'unavailable'};
    if(verify(contents,mark,href,base))return {status:'verified',cfi:mark.cfi};
    try {
      const doc=contents.document,map=textMap(doc);let candidate=null,attempts=0;
      for(let at=map.text.indexOf(mark.exactText);at>=0;at=map.text.indexOf(mark.exactText,at+1)) {
        if(++attempts>4096)return {status:'orphaned',reason:'unavailable'};
        const range=fromOffsets(doc,map,at,at+mark.exactText.length);
        if(!range||!matches(contents,range,mark))continue;
        if(candidate)return {status:'orphaned',reason:'ambiguous'};
        candidate=range;
      }
      if(!candidate)return {status:'orphaned',reason:'missing'};
      const cfi=contents.cfiFromRange(candidate);
      if(verify(contents,Object.assign({},mark,{cfi}),href,base))return {status:'recovered',cfi};
    }catch(_){return {status:'orphaned',reason:'unavailable'};}
    return {status:'orphaned',reason:'unavailable'};
  }
  function anchor(contents,range) {
    const value=evidence(contents,range,'body');if(!value)throw new Error('Range endpoint/quote bound');
    return {cfi:contents.cfiFromRange(range),exactText:value.text,prefix:Array.from(value.left).slice(-32).join(''),
      suffix:Array.from(value.right).slice(0,32).join(''),quoteScope:'body'};
  }
  function overlap(a,b) { return a.compareBoundaryPoints(1,b)>0&&a.compareBoundaryPoints(3,b)<0; }
  function components(ranges) {
    const result=[];
    for(const source of ranges) {
      const range=source.cloneRange();let changed=true;
      while(changed) {
        changed=false;
        for(let i=result.length-1;i>=0;i--) {
          const other=result[i];if(!overlap(range,other))continue;
          if(range.compareBoundaryPoints(0,other)>0)range.setStart(other.startContainer,other.startOffset);
          if(range.compareBoundaryPoints(2,other)<0)range.setEnd(other.endContainer,other.endOffset);
          result.splice(i,1);changed=true;
        }
      }
      result.push(range);
    }
    return result.sort((a,b)=>a.compareBoundaryPoints(0,b));
  }
  function display(contents,mark,href,base) {
    const notes=[],highlights=[],resolutions=[];
    if(Array.isArray(mark.noteAnchors)||Array.isArray(mark.highlightAnchors)) {
      const anchors=mark.noteAnchors||[];
      if(anchors.length>150)throw new Error('Note display bound');
      for(const item of anchors) {
        const resolved=resolve(contents,item,href,base);
        resolutions.push({noteId:item.noteId,revision:item.revision,status:item.provenance==='legacy-group'?'orphaned':resolved.status,
          reason:item.provenance==='legacy-group'?'unavailable':resolved.reason});
        // A labelled legacy group snapshot can retain its old display, but is
        // never represented as a recovered original selection or note jump.
        if(resolved.status!=='orphaned')notes.push(contents.range(resolved.cfi));
      }
      const retainedHighlights=mark.highlightAnchors||[];
      if(retainedHighlights.length>150)throw new Error('Highlight display bound');
      for(const item of retainedHighlights) {
        const resolved=resolve(contents,item,href,base);
        if(resolved.status!=='orphaned')highlights.push(contents.range(resolved.cfi));
      }
    } else {
      const resolved=resolve(contents,mark,href,base);
      if(resolved.status!=='orphaned') {
        if(mark.kind==='note')notes.push(contents.range(resolved.cfi));
        else if(mark.highlightActive!==false)highlights.push(contents.range(resolved.cfi));
      }
    }
    return {notes:components(notes),highlights:components(highlights),resolutions};
  }
  function union(contents,selected,marks,href,base,bookId,excludeId) {
    if(!Array.isArray(marks)||marks.length>150)throw new Error('Range batch bound');
    const range=selected.cloneRange(),remaining=[],members=[];
    for(const mark of marks) {
      if(!mark||mark.markId===excludeId||mark.bookId!==bookId||mark.resourceHref!==href)continue;
      if(typeof mark.markId!=='string'||!mark.markId||mark.markId.length>96||!Number.isSafeInteger(mark.revision)||mark.revision<1)throw new Error('Invalid range member');
      if(Array.isArray(mark.noteAnchors)||Array.isArray(mark.highlightAnchors)) {
        const coverage=display(contents,mark,href,base);
        for(const range of mark.kind==='highlight'?coverage.highlights:coverage.notes)remaining.push({mark,range});
      } else {
        const resolved=resolve(contents,mark,href,base);
        if(resolved.status!=='orphaned')remaining.push({mark,range:contents.range(resolved.cfi)});
      }
    }
    let changed=true;
    while(changed) {
      changed=false;
      for(let i=remaining.length-1;i>=0;i--) {
        const candidate=remaining[i];if(!overlap(range,candidate.range))continue;
        if(range.compareBoundaryPoints(0,candidate.range)>0)range.setStart(candidate.range.startContainer,candidate.range.startOffset);
        if(range.compareBoundaryPoints(2,candidate.range)<0)range.setEnd(candidate.range.endContainer,candidate.range.endOffset);
        if(!members.some(member=>member.markId===candidate.mark.markId))members.push({markId:candidate.mark.markId,revision:candidate.mark.revision});
        remaining.splice(i,1);changed=true;
      }
    }
    return Object.assign(anchor(contents,range),{resourceHref:href,members});
  }
  root.RangeAnchors={QUOTE_LIMIT,invalidate,evidence,verify,resolve,anchor,union,display};
})(globalThis);
